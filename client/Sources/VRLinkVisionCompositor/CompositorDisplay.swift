// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import CompositorServices
import Metal
import QuartzCore
import SwiftUI
import VRLinkAppleSession
import VRLinkCore
import VRLinkVisionTracking
import VRLinkMetal
import VRLinkVideoToolbox
import simd

/// The headset's side of the display seam: for every refresh it asks the
/// compositor where the two eyes will be and when the frame will be seen,
/// draws the newest decoded frame's quads from there, and tells the session
/// what it did.
public final class CompositorDisplay {
    private let layerRenderer: LayerRenderer
    private let connection: Connection
    private let head: HeadTracking
    private let controllers: ControllerTracking
    private let hands: HandJoints
    private let settings: SettingsStore
    private let pinches = PinchRays()
    private let measured: MeasuredDisplay
    /// When true this display only measures (see `MeasuredDisplay`): it never connects.
    private let measureOnly: Bool
    private let gaze = GazeFromFoveation()
    private let queue: MTLCommandQueue
    private let renderer: QuadRenderer

    private var profile: DeviceProfile?
    /// Recent display times, to measure the refresh period, which visionOS
    /// changes on its own (45 to 120 Hz).
    private var presentationTimes: [TimeInterval] = []
    /// The last device anchor ARKit gave, for our own geometry on the rare
    /// frame it gives none. Never handed back to the compositor.
    private var lastOriginFromDevice = matrix_identity_float4x4

    private var describedFirstFrame = false
    private var eyeMidpoint = Vec3(0, 0, 0)
    private var framesShown = 0
    /// The gaze last written to the log, so that it is only written when it moves.
    private var gazeNoted: (Float, Float) = (9, 9)
    /// Frames of display timing collected before connecting, so the host is
    /// told the display's real refresh rate from the start.
    private static let framesBeforeConnecting = 8
    /// For the first seconds of a space visionOS is still working out where
    /// the eyes are behind the lenses, and moves the views by millimeters
    /// (3.7 mm was seen). A stream follows that (`followEyes`); a measurement
    /// for the RealityKit renderer, which cannot follow anything, is taken
    /// only when the middle of the eyes has stayed within `settledWithin`
    /// meters for `settledFrames` frames, or after `longestSettling` frames.
    private static let settledWithin: Float = 0.0002, settledFrames = 45, longestSettling = 600
    private var settling: (midpoint: SIMD4<Float>, frames: Int, total: Int)?

    public init?(_ layerRenderer: LayerRenderer, connection: Connection, head: HeadTracking,
          controllers: ControllerTracking, hands: HandJoints, settings: SettingsStore,
          measured: MeasuredDisplay, measureOnly: Bool = false) {
        guard let queue = layerRenderer.device.makeCommandQueue(),
              let renderer = QuadRenderer(device: layerRenderer.device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          eyeCount: layerRenderer.properties.viewCount,
                                          linearOutput: true)
        else { return nil }
        self.layerRenderer = layerRenderer
        self.connection = connection
        self.head = head
        self.controllers = controllers
        self.hands = hands
        self.settings = settings
        self.measured = measured
        self.measureOnly = measureOnly
        renderer.chromaKey = settings.current.chromaKeying(inGame: false)
        // Pinches made at a distance arrive here, with where the eyes looked.
        layerRenderer.onSpatialEvent = { [pinches] in pinches.handle($0) }
        self.queue = queue
        self.renderer = renderer
    }

    /// The compositor must be driven from a thread of its own, never the main one.
    public func start() {
        let thread = Thread { [self] in loop() }
        thread.name = "compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func loop() {
        while true {
            switch layerRenderer.state {
            case .invalidated:
                // The immersive space is gone.
                if !measureOnly {
                    connection.stop()
                    DispatchQueue.main.async { [connection] in connection.immersed = false }
                }
                return
            case .paused:
                // Crown pressed or headset taken off: let go of the stream,
                // and ask for a new one when the space is running again.
                if !measureOnly { connection.stop() }
                pinches.forgetAll()
                profile = nil
                presentationTimes = []
                layerRenderer.waitUntilRunning()
            default:
                autoreleasepool { renderFrame() }
            }
        }
    }

    private static func seconds(_ instant: LayerRenderer.Clock.Instant) -> TimeInterval {
        // Display times are on the same clock as CACurrentMediaTime().
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: instant).components
        return TimeInterval(duration.seconds) + TimeInterval(duration.attoseconds) * 1e-18
    }

    /// The tangents of a view's frustum, read off its projection matrix.
    private static func frustum(_ projection: simd_float4x4) -> Frustum {
        let xScale = projection.columns.0.x, yScale = projection.columns.1.y
        let xShift = projection.columns.2.x, yShift = projection.columns.2.y
        return Frustum(left: (-1 + xShift) / xScale, right: (1 + xShift) / xScale,
                       down: (-1 + yShift) / yScale, up: (1 + yShift) / yScale)
    }

    private func refreshPeriod() -> Double? {
        let gaps = zip(presentationTimes.dropFirst(), presentationTimes).map { $0 - $1 }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    /// Describe this display to the host from what the compositor reports,
    /// and connect.
    private func connectIfReady(_ drawable: LayerRenderer.Drawable) {
        guard profile == nil, presentationTimes.count >= CompositorDisplay.framesBeforeConnecting,
              drawable.views.count == 2, let period = refreshPeriod()
        else { return }
        let (profile, midpoint, turnedEyes) = measure(drawable, period: period)
        if measureOnly {
            guard hasSettled(midpoint) else { return }
            measured.set(profile: profile, eyeMidpoint: simd_make_float3(midpoint))
            Log.note(String(format: "display: measured for RealityKit after %d frames: eye midpoint (%.1f, %.1f, %.1f) mm from the device anchor, eyes %.1f mm apart",
                            settling?.total ?? 0, midpoint.x * 1000, midpoint.y * 1000, midpoint.z * 1000,
                            (profile.eyesInHead[1].position.x - profile.eyesInHead[0].position.x) * 1000))
            self.profile = profile
            return
        }
        connect(profile, midpoint: midpoint, turnedEyes: turnedEyes)
    }

    /// Whether the middle of the eyes has stopped moving (see `settledWithin`).
    private func hasSettled(_ midpoint: SIMD4<Float>) -> Bool {
        var state = settling ?? (midpoint, 0, 0)
        if simd_distance(midpoint, state.midpoint) > CompositorDisplay.settledWithin {
            state.midpoint = midpoint
            state.frames = 0
        }
        state.frames += 1
        state.total += 1
        settling = state
        return state.frames >= CompositorDisplay.settledFrames || state.total >= CompositorDisplay.longestSettling
    }

    /// What this display is like right now: the profile the host is given
    /// (frusta unscaled), the middle of the eyes from the device anchor,
    /// and each eye as its display is really turned.
    private func measure(_ drawable: LayerRenderer.Drawable, period: Double)
        -> (profile: DeviceProfile, midpoint: SIMD4<Float>, turnedEyes: [Pose]) {
        // The head the host is told about is the point midway between the
        // eyes (the OpenXR convention), which is not where the device anchor
        // is. Each eye is described from that point. The displays are turned
        // outwards and up by about a degree, but the host is told eyes that
        // face straight ahead, with frusta widened to cover what the turned
        // displays show: games that assume parallel eyes then still render
        // the right depth. The picture is drawn through the real, turned
        // views either way.
        let left = drawable.views[0].transform.columns.3, right = drawable.views[1].transform.columns.3
        let midpoint = (left + right) * 0.5
        var profile = DeviceProfile()
        profile.refreshHz = Float((1 / period).rounded())
        let turnedEyes = (0..<2).map { index -> Pose in
            var deviceFromEye = drawable.views[index].transform
            deviceFromEye.columns.3 -= SIMD4(midpoint.x, midpoint.y, midpoint.z, 0)
            return HeadTracking.pose(deviceFromEye)
        }
        profile.eyesInHead = turnedEyes.map {
            Pose(position: $0.position, right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        }
        // The person may ask for more or less than the display shows
        // (the field-of-view setting). The picture is still drawn where the
        // host rendered it: a wider one runs off the edge of the display, a
        // narrower one leaves the room showing around it.
        profile.eyeFrusta = (0..<2).map {
            CompositorDisplay.frustum(drawable.computeProjection(viewIndex: $0)).enclosing(turnedAs: turnedEyes[$0])
        }
        return (profile, midpoint, turnedEyes)
    }

    private func connect(_ measuredProfile: DeviceProfile, midpoint: SIMD4<Float>, turnedEyes: [Pose]) {
        var profile = measuredProfile
        let chosen = settings.current
        profile.eyeFrusta = profile.eyeFrusta.map {
            $0.scaled(horizontal: chosen.fovScaleHorizontal, vertical: chosen.fovScaleVertical)
        }
        head.setEyeMidpoint(simd_make_float3(midpoint), atConnect: true)
        controllers.gripsAsRendered = true
        eyeMidpoint = Vec3(midpoint.x, midpoint.y, midpoint.z)
        self.profile = profile
        for (name, eye) in zip(["left", "right"], turnedEyes) {
            // How far the eye's display is turned outwards and tilted, in degrees.
            let outwards = atan2(eye.forward.x, -eye.forward.z) * 180 / .pi
            let upwards = asin(eye.forward.y) * 180 / .pi
            Log.note(String(format: "display: %@ eye at (%.1f, %.1f, %.1f) mm from the middle, its display turned %.2f deg to the right, %.2f deg up (the host is told straight ahead)",
                         name, eye.position.x * 1000, eye.position.y * 1000, eye.position.z * 1000, outwards, upwards))
        }
        Log.note(String(format: "display: %.0f Hz, eye midpoint (%.1f, %.1f, %.1f) mm from the device anchor, field of view scaled %.2f across, %.2f up-down",
                     profile.refreshHz, midpoint.x * 1000, midpoint.y * 1000, midpoint.z * 1000,
                     chosen.fovScaleHorizontal, chosen.fovScaleVertical))
        connection.start(profile: profile, microphone: chosen.microphone,
                         headProvider: { [head] in head.trackedHead() },
                         handsProvider: { [controllers, hands, head, settings, pinches] in
                             // A hand holding a tracked controller is that controller; otherwise it is itself.
                             let chosen = settings.current
                             let held = controllers.states(clackSwitching: chosen.clackSwitchesToHands, head: head.latestHead())
                             let bare = hands.hands()
                             return Side.allCases.map { side in
                                 if let controller = held[side.rawValue] { return .controller(controller) }
                                 guard var hand = bare[side.rawValue] else { return nil }
                                 // The system's pinches, aimed by the eyes, in place of ours aimed by the arm.
                                 if chosen.gazePinchRays { hand.systemPinch = pinches.pinch(side) }
                                 return .hand(hand)
                             }
                         },
                         // The gaze from where the display is sharpest. (Face and
                         // calibrated gaze need the RealityKit renderer, an experiment.)
                         gazeProvider: { [gaze] in gaze.current() },
                         faceProvider: { nil },
                         onHaptic: { [controllers] in controllers.vibrate($0) })
    }

    private func renderFrame() {
        // The order of these calls matters: ending a submission that presented
        // nothing, or starting one before asking for drawables, aborts the app.
        guard let frame = layerRenderer.queryNextFrame() else { return }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        let drawables = frame.queryDrawables()
        guard let first = drawables.first else { return }
        frame.startSubmission()

        let displayTime = CompositorDisplay.seconds(first.frameTiming.presentationTime)
        presentationTimes.append(displayTime)
        if presentationTimes.count > 16 { presentationTimes.removeFirst() }
        followEyes(first)
        // Kept for the RealityKit renderer, which cannot ask for any of
        // this: once a second, so it has the display as it is after settling.
        if !measureOnly, profile != nil, framesShown % 90 == 0, first.views.count == 2, let period = refreshPeriod() {
            let now = measure(first, period: period)
            measured.set(profile: now.profile, eyeMidpoint: simd_make_float3(now.midpoint))
        }
        // Reading the rate map costs a few hundred calls; eyes do not need it every frame.
        framesShown += 1
        if framesShown % 6 == 0 {
            gaze.update(from: first) { CompositorDisplay.frustum(first.computeProjection(viewIndex: $0)) }
            if let look = gaze.current() {
                let tangents = (look.x / -look.z, look.y / -look.z)
                if abs(tangents.0 - gazeNoted.0) > 0.1 || abs(tangents.1 - gazeNoted.1) > 0.1 {
                    gazeNoted = tangents
                    Log.note(String(format: "gaze: the rate map is densest %.2f right, %.2f up (tangents), %.1f m away",
                                    tangents.0, tangents.1, -look.z))
                }
            }
        }
        connectIfReady(first)
        // The chroma key as it is set right now, so a slider shows its effect as it moves.
        renderer.chromaKey = settings.current.chromaKeying(inGame: connection.session?.sceneApplicationRunning ?? false)

        // Where the headset will be when this frame is seen.
        let anchor = head.anchor(at: displayTime)
        if let anchor { lastOriginFromDevice = anchor.originFromAnchorTransform }

        let picked = connection.frames.next()
        if let session = connection.session, let period = refreshPeriod() {
            func sessionTime(_ time: TimeInterval) -> Int32 {
                session.now() &+ Int32((time - CACurrentMediaTime()) * 1_000_000)
            }
            session.displayWillRefresh(at: sessionTime(displayTime + period), period: period)
            if let picked, picked.isNew {
                session.frameDisplayed(picked.frame.frameID, displayTime: sessionTime(displayTime))
            }
        }

        guard let commands = queue.makeCommandBuffer() else {
            frame.endSubmission()
            return
        }
        // While the system changes render quality there can be more than one
        // drawable; every one has to be drawn and presented.
        for drawable in drawables {
            // The compositor corrects for head movement between now and
            // display using this anchor; nil is an answer it understands.
            drawable.deviceAnchor = anchor
            draw(picked?.frame, into: drawable, commands: commands)
            drawable.encodePresent(commandBuffer: commands)
        }
        commands.commit()
        frame.endSubmission()
    }

    /// visionOS moves each view a few millimeters as the eye behind it
    /// turns, because a pupil swings around the middle of its eyeball. The
    /// host cannot be given new eye positions mid-session (SteamVR hitches),
    /// but it can be given a head that moves with the eyes: the head pose
    /// sent is always the current middle of the two views. What both eyes do
    /// together is then rendered correctly; only what they do differently
    /// (converging on something near) is left out.
    private func followEyes(_ drawable: LayerRenderer.Drawable) {
        guard profile != nil, drawable.views.count == 2 else { return }
        let midpoint = (drawable.views[0].transform.columns.3 + drawable.views[1].transform.columns.3) * 0.5
        head.setEyeMidpoint(simd_make_float3(midpoint), atConnect: false)
        eyeMidpoint = Vec3(midpoint.x, midpoint.y, midpoint.z)
    }

    private func draw(_ frame: DecodedFrame?, into drawable: LayerRenderer.Drawable, commands: MTLCommandBuffer) {
        let views = drawable.views
        // Nothing is drawn behind the picture: where it is not, the room shows.
        let eyes = drawQuads(into: drawable, commands: commands, renderer: renderer, frame: frame,
                             originFromDevice: lastOriginFromDevice) { eye, _ in
            guard let frame, let profile else { return [] }
            return Composition.quads(for: eye, metadata: frame.metadata, profile: profile)
        }
        guard eyes.count == 2 else { return }
        if !describedFirstFrame {
            describedFirstFrame = true
            let f = eyes[0].frustum, e = eyes[0].eye
            Log.note("compositor: \(views.count) views, color \(drawable.colorTextures.count) texture(s) "
                  + "\(drawable.colorTextures[0].width)x\(drawable.colorTextures[0].height) "
                  + "array length \(drawable.colorTextures[0].arrayLength), depth range near \(drawable.depthRange.y) "
                  + "far \(drawable.depthRange.x), rate maps \(drawable.rasterizationRateMaps.count)")
            Log.note(String(format: "compositor: left eye at (%.2f, %.2f, %.2f) m looking (%.2f, %.2f, %.2f), "
                         + "tangents left %.2f right %.2f down %.2f up %.2f",
                         e.position.x, e.position.y, e.position.z, e.forward.x, e.forward.y, e.forward.z,
                         f.left, f.right, f.down, f.up))
        }
    }
}
#endif
