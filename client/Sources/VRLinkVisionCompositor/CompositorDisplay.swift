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
import VRLinkAppleNetwork
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
    private let inputs: StreamInputs
    private let measured: MeasuredDisplay
    /// When true this display only measures (see `MeasuredDisplay`): it never connects.
    private let measureOnly: Bool
    private let queue: MTLCommandQueue
    private let renderer: QuadRenderer

    /// Whether the layer has been running at all.
    private var hasRun = false
    /// Whether this display, opened only to measure, has done so.
    private var hasMeasured = false
    /// Recent display times, to measure the refresh period, which visionOS
    /// changes on its own (45 to 120 Hz).
    private var presentationTimes: [TimeInterval] = []
    /// The last device anchor ARKit gave, for our own geometry on the rare
    /// frame it gives none. Never handed back to the compositor.
    private var lastOriginFromDevice = matrix_identity_float4x4

    private var describedFirstFrame = false
    private var framesShown = 0
    /// The gaze last written to the log, so that it is only written when it moves.
    private var gazeNoted: (Float, Float) = (9, 9)
    /// Frames of display timing collected before measuring, so the host is
    /// told the display's real refresh rate from the start.
    private static let framesBeforeMeasuring = 8
    /// For the first seconds of a space visionOS is still working out where
    /// the eyes are behind the lenses, and moves the views by millimeters
    /// (3.7 mm was seen). A stream follows that (`followEyes`); a measurement
    /// for the RealityKit renderer, which cannot follow anything, is taken
    /// only when the middle of the eyes has stayed within `settledWithin`
    /// meters for `settledFrames` frames, or after `longestSettling` frames.
    private static let settledWithin: Float = 0.0002, settledFrames = 45, longestSettling = 600
    private var settling: (midpoint: SIMD4<Float>, frames: Int, total: Int)?

    public init?(_ layerRenderer: LayerRenderer, inputs: StreamInputs, measureOnly: Bool = false) {
        let (connection, head, controllers, hands) = (inputs.connection, inputs.head, inputs.controllers, inputs.hands)
        let (settings, measured) = (inputs.settings, inputs.measured)
        guard let queue = layerRenderer.device.makeCommandQueue(),
              let renderer = QuadRenderer(device: layerRenderer.device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          eyeCount: layerRenderer.properties.viewCount,
                                          linearOutput: true)
        else { return nil }
        self.layerRenderer = layerRenderer
        self.inputs = inputs
        self.connection = connection
        self.head = head
        self.controllers = controllers
        self.hands = hands
        self.settings = settings
        self.measured = measured
        self.measureOnly = measureOnly
        renderer.chromaKey = settings.current.chromaKeying(inGame: false)
        // Pinches made at a distance arrive here, with where the eyes looked.
        layerRenderer.onSpatialEvent = { [pinches = inputs.pinches] in pinches.handle($0) }
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
                // (Not a layer that has yet to run: its stream was only just asked for.)
                let interrupted = hasRun && !measureOnly
                if interrupted { connection.stop() }
                inputs.pinches.forgetAll()
                presentationTimes = []
                layerRenderer.waitUntilRunning()
                // The space is still open, so the stream is asked for from within it.
                if interrupted, layerRenderer.state == .running { CompositorDisplay.connect(inputs) }
            default:
                hasRun = true
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

    /// A display opened only to measure: keep what the compositor reports, once it has settled.
    private func measureIfReady(_ drawable: LayerRenderer.Drawable) {
        guard measureOnly, !hasMeasured, presentationTimes.count >= CompositorDisplay.framesBeforeMeasuring,
              drawable.views.count == 2, let period = refreshPeriod()
        else { return }
        let (profile, midpoint, _) = measure(drawable, period: period)
        guard hasSettled(midpoint) else { return }
        measured.set(profile: profile, eyeMidpoint: simd_make_float3(midpoint))
        Log.note(String(format: "display: measured after %d frames: eye midpoint (%.1f, %.1f, %.1f) mm from the device anchor, eyes %.1f mm apart",
                        settling?.total ?? 0, midpoint.x * 1000, midpoint.y * 1000, midpoint.z * 1000,
                        (profile.eyesInHead[1].position.x - profile.eyesInHead[0].position.x) * 1000))
        hasMeasured = true
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
        profile.systemName = SystemVersion.name
        profile.clientVersion = SystemVersion.client
        profile.refreshHz = Float((1 / period).rounded())
        // How many pixels the host should have applications draw per eye
        // (`DeviceProfile.eyePixels`): the display's own size. visionOS
        // has no plain answer: what it gives is the size the picture would
        // be with the variable-rate map (foveation) undone, which at full
        // render quality is about 2.25 times the panel each way on the M5
        // headset (6886 x 5522) and a little over twice on the M2 (6262 x
        // 5020). Half of that is near the panel on both, and gives SteamVR
        // a sensible size to call 100%. With no map, the drawable's own size.
        if let map = drawable.rasterizationRateMaps.first {
            profile.eyePixels = (map.screenSize.width / 2, map.screenSize.height / 2)
        } else {
            let viewport = drawable.views[0].textureMap.viewport
            profile.eyePixels = (Int(viewport.width), Int(viewport.height))
        }
        if let pixels = profile.eyePixels { Log.note("display: asking the host for a render target of \(pixels.width) x \(pixels.height) per eye") }
        let turnedEyes = (0..<2).map { index -> Pose in
            var deviceFromEye = drawable.views[index].transform
            deviceFromEye.columns.3 -= SIMD4(midpoint.x, midpoint.y, midpoint.z, 0)
            return HeadTracking.pose(deviceFromEye)
        }
        profile.eyesInHead = turnedEyes.map {
            Pose(position: $0.position, right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        }
        profile.eyeFrusta = (0..<2).map {
            CompositorDisplay.frustum(drawable.computeProjection(viewIndex: $0)).enclosing(turnedAs: turnedEyes[$0])
        }
        return (profile, midpoint, turnedEyes)
    }

    /// Describe the display to the host as it was last measured, and ask
    /// for a stream to show in a compositor layer. The layer need not be
    /// open yet. False if the display has not been measured.
    @discardableResult
    public static func connect(_ inputs: StreamInputs) -> Bool {
        guard let measured = inputs.measured.value, let profile = inputs.profileForHost() else { return false }
        let chosen = inputs.settings.current
        let midpoint = measured.eyeMidpoint
        inputs.head.setEyeMidpoint(midpoint, atConnect: true)
        inputs.controllers.gripsAsRendered = true
        Log.note(String(format: "display: %.0f Hz, eye midpoint (%.1f, %.1f, %.1f) mm from the device anchor, field of view scaled %.2f across, %.2f up-down",
                     profile.refreshHz, midpoint.x * 1000, midpoint.y * 1000, midpoint.z * 1000,
                     chosen.fovScaleHorizontal, chosen.fovScaleVertical))
        inputs.connection.start(profile: profile, microphone: chosen.microphone,
                                headProvider: { [head = inputs.head] in head.trackedHead() },
                                handsProvider: { [inputs] in inputs.handsNow() },
                                // The gaze from where the display is sharpest. (Face and
                                // calibrated gaze need the RealityKit renderer, an experiment.)
                                gazeProvider: { [gaze = inputs.gaze] in gaze.current() },
                                faceProvider: { nil },
                                onHaptic: { [controllers = inputs.controllers] in controllers.vibrate($0) })
        return true
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
        // The stream being shown was asked for with this, before or after this layer opened.
        let profile = measureOnly ? nil : connection.profile
        if profile != nil { followEyes(first) }
        // Kept for the next connection, and for the RealityKit renderer,
        // which cannot ask for any of this: once a second, so both have the
        // display as it is after settling.
        if !measureOnly, framesShown % 90 == 0, first.views.count == 2, let period = refreshPeriod() {
            let now = measure(first, period: period)
            measured.set(profile: now.profile, eyeMidpoint: simd_make_float3(now.midpoint))
        }
        // Reading the rate map costs a few hundred calls; eyes do not need it every frame.
        framesShown += 1
        if framesShown % 6 == 0 {
            inputs.gaze.update(from: first) { CompositorDisplay.frustum(first.computeProjection(viewIndex: $0)) }
            if let look = inputs.gaze.current() {
                let tangents = (look.x / -look.z, look.y / -look.z)
                if abs(tangents.0 - gazeNoted.0) > 0.1 || abs(tangents.1 - gazeNoted.1) > 0.1 {
                    gazeNoted = tangents
                    Log.note(String(format: "gaze: the rate map is densest %.2f right, %.2f up (tangents), %.1f m away",
                                    tangents.0, tangents.1, -look.z))
                }
            }
        }
        measureIfReady(first)
        // The chroma key as it is set right now, so a slider shows its effect as it moves.
        renderer.chromaKey = settings.current.chromaKeying(inGame: connection.session?.sceneApplicationRunning ?? false)

        // Where the headset will be when this frame is seen.
        let anchor = head.anchor(at: displayTime)
        if let anchor { lastOriginFromDevice = anchor.originFromAnchorTransform }

        let picked = connection.frames.next()
        if let session = connection.session, let period = refreshPeriod() {
            // The display's times are on the media clock; the session wants the system's uptime.
            func uptime(_ time: TimeInterval) -> UInt64 {
                UInt64(max(0, Double(Uptime.nanoseconds) + (time - CACurrentMediaTime()) * 1e9))
            }
            session.displayRefreshes(at: uptime(displayTime + period), period: period)
            if let picked, picked.isNew {
                session.frameShown(picked.frame.frameID, at: uptime(displayTime))
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
            draw(picked?.frame, profile: profile, into: drawable, commands: commands)
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
        guard drawable.views.count == 2 else { return }
        let midpoint = (drawable.views[0].transform.columns.3 + drawable.views[1].transform.columns.3) * 0.5
        head.setEyeMidpoint(simd_make_float3(midpoint), atConnect: false)
    }

    /// How far away the black behind an unkeyed picture is, in meters:
    /// beyond the picture, within what the compositor draws.
    private static let backdropDistance: Float = 90

    private func draw(_ frame: DecodedFrame?, profile: DeviceProfile?, into drawable: LayerRenderer.Drawable,
                      commands: MTLCommandBuffer) {
        let views = drawable.views
        // Behind a picture that is not keyed there is black, not the room:
        // a picture narrower than the display (the field-of-view setting)
        // then has a black margin. With keying, or with no picture, nothing
        // is drawn behind and the room shows. Clearing to black is not
        // enough: visionOS shows the room wherever no depth was written,
        // whatever the color there, so the black is a quad of its own,
        // far behind the picture.
        // A frame with transparency of its own shows the room through it.
        let roomBehind = frame == nil || profile == nil || renderer.chromaKey != nil || frame?.layout.transparent == true
        let eyes = drawQuads(into: drawable, commands: commands, renderer: renderer, frame: frame,
                             originFromDevice: lastOriginFromDevice,
                             behind: MTLClearColor(red: 0, green: 0, blue: 0, alpha: roomBehind ? 0 : 1)) { eye, view in
            guard let frame, let profile else { return [] }
            let picture = Composition.quads(for: eye, layout: frame.layout)
            guard !roomBehind else { return picture }
            return [Quad.backdrop(for: view, distance: CompositorDisplay.backdropDistance, color: [0, 0, 0, 1])] + picture
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
