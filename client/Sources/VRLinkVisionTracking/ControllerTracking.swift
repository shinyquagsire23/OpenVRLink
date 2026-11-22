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

/// Tracks spatial handheld controllers (such as PlayStation VR2 Sense).
///
/// visionOS splits spatial controller state across two frameworks:
/// GameController provides button and thumbstick inputs, while ARKit accessory
/// tracking provides 6DoF poses. `ControllerTracking` pairs both sources by
/// chirality and produces one `ControllerState` per hand.
public final class ControllerTracking {
    public init() {}

    private let session = ARKitSession()
    /// Manages claiming and monitoring the controller Home (PS) button, which requires user permission in Settings.
    public let homeButton = HomeButton()
    private var sourcesNoted: Set<String> = []
    private let lock = NSLock()
    /// ARKit aborts the app if two threads ask it for a prediction at once
    /// ("concurrent API call detected - caller must serialize").
    private let oneCallerAtATime = NSLock()
    private var provider: AccessoryTrackingProvider?
    /// Latest ARKit accessory anchor and `GCController` instance for each hand.
    private var anchors: [Side: AccessoryAnchor] = [:]
    private var gamepads: [Side: GCController] = [:]
    private var updates: Task<Void, Never>?
    /// Lazily created Core Haptics engine for each hand.
    private var engines: [Side: CHHapticEngine] = [:]
    /// Prediction lookahead in seconds (`0` because client-side lookahead is disabled).
    /// The host extrapolates controller poses from sample time to target display time
    /// using the reported velocities (`docs/svl-tracking-input/poses.md`), so any
    /// lookahead added here would double-predict. We still query ARKit at `now`
    /// because the most recently delivered anchor is slightly behind current time.
    private static let prediction: TimeInterval = 0

    /// Selects between ARKit's `.rendered` and `.none` (raw tracked) grip pose
    /// corrections. Both share the same orientation, but `.rendered` adds an
    /// offset matching where visionOS renders virtual controllers.
    ///
    /// Under the CompositorServices (Metal) renderer, `.rendered` aligns the
    /// host's virtual controller with the physical controller in passthrough,
    /// so we send `.rendered`. Under the RealityKit renderer, `.rendered`
    /// drifts over time (starting around 36 mm, settling to 6 mm over ~30 s,
    /// and creeping back up after walking into another room). Because head and
    /// hand poses use raw tracking, that drift offsets the controllers toward
    /// the user's eyes relative to their hands. RealityKit therefore disables
    /// `.rendered` and applies the static settled offset `renderedShiftAtRest`
    /// to the raw tracked pose.
    ///
    /// Configured by each display backend when connecting.
    public var gripsAsRendered: Bool {
        get { lock.lock(); defer { lock.unlock() }; return asRendered }
        set { lock.lock(); asRendered = newValue; lock.unlock() }
    }
    private var asRendered = true
    /// Static local-space offset (in meters along the grip axes) added to the
    /// raw tracked grip pose when `gripsAsRendered` is `false`. Defined for the
    /// right controller; the X component is negated for the left controller.
    /// Tuned visually on Vision Pro starting from the settled `.rendered` offset
    /// `(-0.002, 0.008, -0.001)`, shifted 1 cm lower in Y (+X runs from the
    /// thumbstick toward the circle button).
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

    /// Restarts ARKit accessory tracking for the currently connected spatial controllers.
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

    /// Returns the current controller state for `[left, right]`, using `nil`
    /// for any hand without an actively tracked controller.
    ///
    /// When `clackSwitching` is enabled, tapping the controllers together twice
    /// in front of `head` toggles controller reporting off (falling back to
    /// bare-hand tracking) until they are tapped together twice again.
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

            // World-space grip pose at the center of the handle (see `gripsAsRendered`).
            var originFromGrip = anchor.coordinateSpace(for: .grip, correction: asRendered ? .rendered : .none)
                .ancestorFromSpaceTransformFloat().matrix
            if !asRendered {
                var shift = ControllerTracking.renderedShiftAtRest
                if side == .left { shift.x = -shift.x }
                originFromGrip.columns.3 += originFromGrip.columns.0 * shift.x + originFromGrip.columns.1 * shift.y
                    + originFromGrip.columns.2 * shift.z
            }
            var grip = TrackedPose(pose: HeadTracking.pose(originFromGrip))
            // ARKit reports linear and angular velocity in the controller's local
            // coordinate space (undocumented, matching the ALVR visionOS client).
            // Rotate linear velocity from grip space into world space for the host.
            let v = anchor.velocity, pose = grip.pose
            grip.linearVelocity = pose.right * v.x + pose.up * v.y + pose.forward * -v.z
            grip.angularVelocity = Vec3(anchor.angularVelocity.x, anchor.angularVelocity.y, anchor.angularVelocity.z)
            var state = ControllerState(grip: grip)
            // Populate the OpenXR aim pose (pointer ray origin and orientation) for hosts that consume it.
            state.aim = HeadTracking.pose(anchor.coordinateSpace(for: .aim, correction: asRendered ? .rendered : .none)
                .ancestorFromSpaceTransformFloat().matrix)
            guard let gamepad = gamepads[side] else { return state }
            if let battery = gamepad.battery, battery.batteryState != .unknown {
                state.power = PowerState(level: battery.batteryLevel,
                                         charging: battery.batteryState == .charging || battery.batteryState == .full)
            }
            // GCController exposes inputs through both `input` (live capture) and the
            // older `physicalInputProfile`. On Sense controllers, visionOS builds have
            // inconsistently populated digital buttons in one API and analog axes in
            // the other, so read each control from whichever source reports activity.
            let live = gamepad.input.capture()
            let profile = gamepad.physicalInputProfile
            func pressed(_ name: String) -> Bool {
                (live.buttons[name]?.pressedInput.isPressed ?? false) || (profile.buttons[name]?.isPressed ?? false)
            }
            func touched(_ name: String) -> Bool {
                (live.buttons[name]?.touchedInput?.isTouched ?? false) || (profile.buttons[name]?.isTouched ?? false)
            }
            /// Returns whichever reading has the larger magnitude.
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
            // (cross, square) and "Button B" is the upper (circle, triangle).
            state.lowerButton = pressed("Button A")
            state.upperButton = pressed("Button B")
            // Create and Options both map to "Button Menu". Oculus Touch only has a
            // menu button on the left controller, so the core forwards only the left side (`ControllerState.menuButton`).
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

            // DIAGNOSTIC: log once per control which input API reported its first activation.
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

    /// Plays a host-requested haptic pulse on the target hand's controller.
    public func vibrate(_ pulse: HapticPulse) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if engines[pulse.side] == nil, let engine = gamepads[pulse.side]?.haptics?.createEngine(withLocality: .default) {
                // Drop stopped or reset engines so they are recreated on the next pulse.
                engine.stoppedHandler = { [weak self] _ in self?.forgetEngine(pulse.side) }
                engine.resetHandler = { [weak self] in self?.forgetEngine(pulse.side) }
                try engine.start()
                engines[pulse.side] = engine
            }
            guard let engine = engines[pulse.side] else { return }
            // Map the host pulse frequency (50-300 Hz) onto Core Haptics sharpness (0-1).
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
