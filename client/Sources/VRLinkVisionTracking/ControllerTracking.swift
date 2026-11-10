// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import CoreHaptics
import GameController
import QuartzCore
import Spatial
import VRLinkCore
import simd

/// Hand-held controllers (PlayStation VR2 Sense and other spatial gamepads).
///
/// visionOS splits one controller across two frameworks: GameController has
/// its buttons, ARKit accessory tracking has where it is. This class joins
/// them by the hand each belongs to and answers with one `ControllerState`
/// per hand.
public final class ControllerTracking {
    public init() {}

    private let session = ARKitSession()
    /// The Home (PS) button, which needs the system's and the person's leave.
    public let homeButton = HomeButton()
    private var sourcesNoted: Set<String> = []
    private let lock = NSLock()
    /// ARKit aborts the app if two threads ask it for a prediction at once
    /// ("concurrent API call detected - caller must serialize").
    private let oneCallerAtATime = NSLock()
    private var provider: AccessoryTrackingProvider?
    /// The newest anchor ARKit has given for each hand, and that hand's buttons.
    private var anchors: [Side: AccessoryAnchor] = [:]
    private var gamepads: [Side: GCController] = [:]
    private var updates: Task<Void, Never>?
    /// One running haptic engine per hand, made the first time it is needed.
    private var engines: [Side: CHHapticEngine] = [:]
    /// How far ahead of now controllers are predicted, in seconds: not at
    /// all. The host carries every pose forward itself, by its velocities,
    /// from the time it was sampled to the time the client reports frames
    /// reaching the display (docs/svl-tracking-input/poses.md, "the host
    /// predicts to the reported display time"), so anything added here is
    /// added twice. ARKit is still asked for the pose as it is now, since
    /// the newest anchor it has handed over is already a little old.
    private static let prediction: TimeInterval = 0

    /// ARKit gives a controller's place two ways: as tracked, and "as
    /// rendered", which is turned the same way but shifted to where the
    /// system would draw it.
    ///
    /// Under the compositor (Metal) renderer the rendered one lines the
    /// host's controller up with the real one, and is what is sent. Under
    /// the RealityKit renderer it cannot be used: the shift wanders there
    /// (seen on the headset, 2026-11-11: 36 mm, sinking to 6 mm over half a
    /// minute, then creeping up again; worst after walking into another
    /// room), and since the head and hands are sent as tracked, the
    /// controller then sits off from them by that much, lifted towards the
    /// eyes. There the tracked place is sent, moved by the shift as it was
    /// once it had come to rest (`renderedShiftAtRest`).
    ///
    /// Each display sets this when it connects.
    public var gripsAsRendered: Bool {
        get { lock.lock(); defer { lock.unlock() }; return asRendered }
        set { lock.lock(); asRendered = newValue; lock.unlock() }
    }
    private var asRendered = true
    /// What is added to the tracked grip there, along the grip's own axes,
    /// in meters, for the right controller; the left one's is its mirror
    /// image (x the other way). Tuned by eye on the headset, starting from
    /// the rendered shift read at rest in that session, (-0.002, 0.008,
    /// -0.001): a centimeter down from that. (x is the line the stick and
    /// the circle button sit on, positive towards the circle button; 2 and
    /// 4 cm that way were tried and were worse.)
    private static let renderedShiftAtRest = SIMD3<Float>(-0.002, -0.002, -0.001)

    public func start() {
        guard AccessoryTrackingProvider.isSupported else {
            print("controllers: accessory tracking is not supported here")
            return
        }
        // Controllers come and go; track whichever are connected now.
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.trackConnectedControllers()
            }
        }
        trackConnectedControllers()
    }

    private static func side(_ accessory: Accessory) -> Side? {
        switch accessory.inherentChirality {
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }

    /// Start accessory tracking over with the spatial controllers connected now.
    private func trackConnectedControllers() {
        updates?.cancel()
        let spatial = GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
        updates = Task { [weak self] in
            guard let self else { return }
            var accessories: [Accessory] = []
            var gamepads: [Side: GCController] = [:]
            for controller in spatial {
                do {
                    let accessory = try await Accessory(device: controller)
                    guard let side = ControllerTracking.side(accessory) else { continue }
                    accessories.append(accessory)
                    gamepads[side] = controller
                    print("controllers: \(side) hand holds \(accessory.name)")
                    self.homeButton.claim(controller, side: side)
                } catch {
                    print("controllers: \(controller.vendorName ?? "controller") cannot be tracked: \(error)")
                }
            }
            let provider = AccessoryTrackingProvider(accessories: accessories)
            self.lock.lock()
            self.provider = accessories.isEmpty ? nil : provider
            self.gamepads = gamepads
            self.anchors = [:]
            self.engines = [:]
            self.lock.unlock()
            guard !accessories.isEmpty else {
                self.session.stop()
                return
            }
            do {
                try await self.session.run([provider])
            } catch {
                print("controllers: could not start accessory tracking: \(error)")
                return
            }
            for await update in provider.anchorUpdates {
                guard let side = ControllerTracking.side(update.anchor.accessory) else { continue }
                self.lock.lock()
                self.anchors[side] = update.event == .removed ? nil : update.anchor
                self.lock.unlock()
            }
        }
    }

    /// Both hands as they are right now: left then right, nil for a hand
    /// whose controller is not being tracked.
    ///
    /// With `clackSwitching`, knocking the controllers together twice in
    /// front of `head` makes this answer "no controllers" (so the bare hands
    /// are used) until they are knocked together twice again.
    public func states(clackSwitching: Bool, head: Pose?) -> [ControllerState?] {
        oneCallerAtATime.lock()
        defer { oneCallerAtATime.unlock() }
        let tracked = trackedStates()
        guard clackSwitching else {
            clack.reset()
            return tracked
        }
        if let left = tracked[0], let right = tracked[1], let head,
           clack.update(left: left.grip, right: right.grip, head: head, seconds: CACurrentMediaTime()) {
            Log.note("controllers: knocked together twice, now using \(clack.handsWanted ? "hands" : "controllers")")
        }
        return clack.handsWanted ? [nil, nil] : tracked
    }

    private var clack = ClackDetector()

    private func trackedStates() -> [ControllerState?] {
        lock.lock()
        let provider = self.provider, anchors = self.anchors, gamepads = self.gamepads, asRendered = self.asRendered
        lock.unlock()
        guard let provider else { return [nil, nil] }
        let now = CACurrentMediaTime()
        return Side.allCases.map { side in
            guard let latest = anchors[side], latest.isTracked else { return nil }
            let anchor = provider.predictAnchor(for: latest, at: now + ControllerTracking.prediction) ?? latest

            // The grip pose: the middle of the handle, in world space (see `gripsAsRendered`).
            var originFromGrip = anchor.coordinateSpace(for: .grip, correction: asRendered ? .rendered : .none)
                .ancestorFromSpaceTransformFloat().matrix
            if !asRendered {
                var shift = ControllerTracking.renderedShiftAtRest
                if side == .left { shift.x = -shift.x }
                originFromGrip.columns.3 += originFromGrip.columns.0 * shift.x + originFromGrip.columns.1 * shift.y
                    + originFromGrip.columns.2 * shift.z
            }
            var grip = TrackedPose(pose: HeadTracking.pose(originFromGrip))
            // ARKit gives both velocities along the controller's own axes
            // (undocumented; this is how the ALVR visionOS client reads them).
            // The host wants the linear one along the world's axes: so many
            // meters per second along each of the grip's axes, added up.
            let v = anchor.velocity, pose = grip.pose
            grip.linearVelocity = pose.right * v.x + pose.up * v.y + pose.forward * -v.z
            grip.angularVelocity = Vec3(anchor.angularVelocity.x, anchor.angularVelocity.y, anchor.angularVelocity.z)
            var state = ControllerState(grip: grip)
            guard let gamepad = gamepads[side] else { return state }
            if let battery = gamepad.battery, battery.batteryState != .unknown {
                state.power = PowerState(level: battery.batteryLevel,
                                         charging: battery.batteryState == .charging || battery.batteryState == .full)
            }
            // A controller can be read from two places: its live input, and
            // the older "physical input profile". For the Sense controllers
            // the two do not always agree (some builds have had the buttons
            // only in one and the analog values only in the other), so every
            // control is taken from whichever of the two reports it.
            let live = gamepad.input.capture()
            let profile = gamepad.physicalInputProfile
            func pressed(_ name: String) -> Bool {
                (live.buttons[name]?.pressedInput.isPressed ?? false) || (profile.buttons[name]?.isPressed ?? false)
            }
            func touched(_ name: String) -> Bool {
                (live.buttons[name]?.touchedInput?.isTouched ?? false) || (profile.buttons[name]?.isTouched ?? false)
            }
            /// The one of two readings that is further from rest.
            func stronger(_ a: Float, _ b: Float) -> Float { abs(a) >= abs(b) ? a : b }
            let liveTrigger = live.buttons["Trigger"]?.pressedInput.value ?? 0
            let profileTrigger = profile.buttons["Trigger"]?.value ?? 0
            let liveStick = (x: live.dpads["Thumbstick"]?.xAxis.value ?? 0, y: live.dpads["Thumbstick"]?.yAxis.value ?? 0)
            // The profile has the stick as a pad on some systems and as four direction buttons on others.
            let pad = profile.dpads["Thumbstick"]
            let profileStick = (
                x: pad?.xAxis.value ?? ((profile.buttons["Thumbstick Right"]?.value ?? 0) - (profile.buttons["Thumbstick Left"]?.value ?? 0)),
                y: pad?.yAxis.value ?? ((profile.buttons["Thumbstick Up"]?.value ?? 0) - (profile.buttons["Thumbstick Down"]?.value ?? 0)))

            // On a Sense controller "Button A" is the lower face button
            // (cross, square) and "Button B" the upper (circle, triangle).
            state.lowerButton = pressed("Button A")
            state.upperButton = pressed("Button B")
            // Create and Options both arrive as "Button Menu". The host's
            // Touch controller has one such button, on the left hand, so
            // only the left one is sent (ControllerState.menuButton).
            state.menuButton = pressed("Button Menu") || HomeButton.isPressed(gamepad)
            state.stickClick = pressed("Thumbstick Button")
            state.lowerButtonTouched = touched("Button A")
            state.upperButtonTouched = touched("Button B")
            state.triggerTouched = touched("Trigger")
            state.stickTouched = touched("Thumbstick Button")
            state.trigger = stronger(liveTrigger, profileTrigger)
            state.squeeze = pressed("Grip") ? 1 : 0            // the grip button is not analog
            state.stickX = stronger(liveStick.x, profileStick.x)
            state.stickY = stronger(liveStick.y, profileStick.y)

            // DIAGNOSTIC: when a control is first used, say which source reported it.
            func note(_ control: String, live: Bool, profile: Bool) {
                guard live || profile, !sourcesNoted.contains("\(side) \(control)") else { return }
                sourcesNoted.insert("\(side) \(control)")
                Log.note("inputs: \(side) \(control) reported by " + (live && profile ? "both" : live ? "the live input only" : "the profile only"))
            }
            note("trigger", live: liveTrigger > 0.5, profile: profileTrigger > 0.5)
            note("stick", live: abs(liveStick.x) + abs(liveStick.y) > 0.5, profile: abs(profileStick.x) + abs(profileStick.y) > 0.5)
            for name in ["Button A", "Button B", "Button Menu", "Grip", "Thumbstick Button"] {
                note(name, live: live.buttons[name]?.pressedInput.isPressed ?? false, profile: profile.buttons[name]?.isPressed ?? false)
            }
            return state
        }
    }

    /// Play a vibration the host asked for on that hand's controller.
    public func vibrate(_ pulse: HapticPulse) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if engines[pulse.side] == nil, let engine = gamepads[pulse.side]?.haptics?.createEngine(withLocality: .default) {
                // An engine the system has stopped is dropped and made again on the next pulse.
                engine.stoppedHandler = { [weak self] _ in self?.forgetEngine(pulse.side) }
                engine.resetHandler = { [weak self] in self?.forgetEngine(pulse.side) }
                try engine.start()
                engines[pulse.side] = engine
            }
            guard let engine = engines[pulse.side] else { return }
            // Core Haptics has "sharpness" where the host has a frequency:
            // 0 at 50 Hz and below, 1 at 300 Hz and above.
            let sharpness = max(0, min(1, (pulse.frequency - 50) / 250))
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, pulse.amplitude)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0, duration: TimeInterval(pulse.seconds))
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            engines[pulse.side] = nil
        }
    }

    private func forgetEngine(_ side: Side) {
        lock.lock()
        engines[side] = nil
        lock.unlock()
    }
}
#endif
