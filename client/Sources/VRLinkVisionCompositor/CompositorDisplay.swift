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

/// Drives the visionOS `CompositorServices` render loop. On each display
/// refresh, it queries predicted eye views and presentation timing from the
/// compositor, renders the latest decoded frame's quads, and reports refresh
/// and presentation timestamps back to the streaming session.
public final class CompositorDisplay {
    private let layerRenderer: LayerRenderer
    private let connection: Connection
    private let head: HeadTracking
    private let controllers: ControllerTracking
    private let hands: HandJoints
    private let settings: SettingsStore
    private let inputs: StreamInputs
    private let measured: MeasuredDisplay
    /// When `true`, this instance only captures display metrics (see `MeasuredDisplay`) and never starts a stream.
    private let measureOnly: Bool
    private let queue: MTLCommandQueue
    private let renderer: QuadRenderer

    /// Whether the compositor layer has entered the `.running` state at least once.
    private var hasRun = false
    /// Whether a measurement-only display pass has finished recording `MeasuredDisplay`.
    private var hasMeasured = false
    /// Recent presentation timestamps used to estimate the current refresh
    /// period, which visionOS adjusts dynamically between 45 and 120 Hz.
    private var presentationTimes: [TimeInterval] = []
    /// Cached transform from the most recent ARKit device anchor, used as a
    /// fallback for quad projection if ARKit returns `nil` for a frame. We
    /// never pass a stale anchor back to `drawable.deviceAnchor`.
    private var lastOriginFromDevice = matrix_identity_float4x4

    private var describedFirstFrame = false
    private var framesShown = 0
    /// Last logged gaze tangents, used to throttle log messages until gaze moves noticeably.
    private var gazeNoted: (Float, Float) = (9, 9)
    /// Estimates scene depth from stereo disparity when `Settings.depthFromPicture` is enabled.
    private let depth: DepthEstimator
    private var depthNoted: Double = 0
    /// Retained so the debug depth overlay setting can toggle diagnostic image dumps.
    private let shrink: StereoShrink?
    /// Number of presentation timestamps to collect before measuring display
    /// parameters so we report an accurate refresh rate from the start.
    private static let framesBeforeMeasuring = 8
    /// During the first few seconds after opening an immersive space, visionOS
    /// refines its IPD/eye-relief estimate and shifts the view transforms by
    /// several millimeters (up to ~3.7 mm observed). An active compositor
    /// stream tracks those shifts continuously via `followEyes`, whereas a
    /// one-shot measurement (also used by the RealityKit renderer, which cannot
    /// query live eye transforms) waits until the eye midpoint stays within
    /// `settledWithin` meters for `settledFrames` consecutive frames, or until
    /// `longestSettling` total frames have elapsed.
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
        // Hardware-decoded VideoToolbox buffers use lossless compression that only the GPU sampler can read,
        // so downsampling and stereo matching run on Metal.
        let shrink = StereoShrink(device: layerRenderer.device)
        self.shrink = shrink
        depth = DepthEstimator(measure: shrink.map { shrink in { shrink.measure($0, done: $1) } } ?? { $1(nil) })
        renderer.chromaKey = settings.current.chromaKeying(inGame: false)
        // Forward system spatial pinch events (including their gaze-targeted rays) to PinchRays.
        layerRenderer.onSpatialEvent = { [pinches = inputs.pinches] in pinches.handle($0) }
        self.queue = queue
        self.renderer = renderer
    }

    /// Starts the dedicated high-priority render thread required by `LayerRenderer` (which cannot run on the main thread).
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
                // The immersive space has closed.
                if !measureOnly {
                    connection.stop()
                    DispatchQueue.main.async { [connection] in connection.immersed = false }
                }
                return
            case .paused:
                // If the user presses the Digital Crown or removes the headset
                // after the layer has started running, stop the current stream
                // and reconnect once the layer resumes. (Ignore an initial
                // `.paused` state before the first frame, since that stream was
                // just requested.)
                let interrupted = hasRun && !measureOnly
                if interrupted { connection.stop() }
                inputs.pinches.forgetAll()
                presentationTimes = []
                layerRenderer.waitUntilRunning()
                // Reconnect directly since the immersive space is already open.
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

    /// Extracts frustum half-angle tangents from a compositor projection matrix.
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

    /// Records display metrics into `MeasuredDisplay` once eye positions have settled in measurement-only mode.
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

    /// Returns `true` once the eye midpoint has stayed within `settledWithin` long enough (or timed out).
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

    /// Computes current display metrics from `drawable`: an unscaled
    /// `DeviceProfile` for the host, the eye midpoint relative to the device
    /// anchor, and each eye's actual canted pose relative to that midpoint.
    private func measure(_ drawable: LayerRenderer.Drawable, period: Double)
        -> (profile: DeviceProfile, midpoint: SIMD4<Float>, turnedEyes: [Pose]) {
        // Report the head pose at the midpoint between the eyes (matching OpenXR
        // convention) rather than at ARKit's device anchor, with eye offsets
        // expressed relative to that midpoint. Vision Pro's displays are canted
        // outward and upward by roughly one degree, but we report parallel
        // forward-facing eyes with expanded asymmetric frusta that enclose the
        // canted views so games assuming parallel eyes render stereo depth
        // accurately. Local quad rendering still uses the true canted view transforms.
        let left = drawable.views[0].transform.columns.3, right = drawable.views[1].transform.columns.3
        let midpoint = (left + right) * 0.5
        var profile = DeviceProfile()
        profile.systemName = SystemVersion.name
        profile.clientVersion = SystemVersion.client
        profile.refreshHz = Float((1 / period).rounded())
        // Choose the per-eye recommended render resolution (`DeviceProfile.eyePixels`).
        // visionOS does not expose physical panel resolution directly; instead,
        // the rasterization rate map reports the uncompressed virtual screen size,
        // which at full render quality is ~2.25x the panel per axis on M5 Vision Pro
        // (6886x5522) and just over 2x on M2 Vision Pro (6262x5020). Halving that
        // virtual size approximates native panel resolution on both models and gives
        // SteamVR a sensible 100% baseline. When foveation is disabled, fall back
        // to the drawable viewport size.
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

    /// Starts a streaming connection configured with the latest measured display
    /// profile for presentation in a compositor layer (which does not need to be
    /// open yet). Returns `false` if the display has not been measured yet.
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
                                // Estimate gaze from the compositor's rasterization rate map.
                                // (Persona face tracking and calibrated eye gaze require the experimental RealityKit renderer.)
                                gazeProvider: { [gaze = inputs.gaze] in gaze.current() },
                                faceProvider: { nil },
                                onHaptic: { [controllers = inputs.controllers] in controllers.vibrate($0) })
        return true
    }

    private func renderFrame() {
        // CompositorServices enforces this exact call order: ending a submission
        // without encoding a present, or calling `startSubmission()` before
        // `queryDrawables()`, terminates the process.
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
        // Active device profile for the current stream, whether connected before or after the layer opened.
        let profile = measureOnly ? nil : connection.profile
        if profile != nil { followEyes(first) }
        // Refresh `MeasuredDisplay` roughly once per second so subsequent
        // connections and the RealityKit renderer (which cannot query compositor
        // views directly) use settled display metrics.
        if !measureOnly, framesShown % 90 == 0, first.views.count == 2, let period = refreshPeriod() {
            let now = measure(first, period: period)
            measured.set(profile: now.profile, eyeMidpoint: simd_make_float3(now.midpoint))
        }
        // Sampling the rasterization rate map takes ~128 coordinate lookups, so update gaze every 6 frames.
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
        // Apply current chroma-key settings each frame so UI slider adjustments appear live.
        renderer.chromaKey = settings.current.chromaKeying(inGame: connection.session?.sceneApplicationRunning ?? false)

        // Predict the headset pose at the frame's presentation timestamp.
        let anchor = head.anchor(at: displayTime)
        if let anchor { lastOriginFromDevice = anchor.originFromAnchorTransform }

        let picked = connection.frames.next()
        followDepth(picked, at: displayTime)
        if let session = connection.session, let period = refreshPeriod() {
            // Convert presentation timestamps from the CACurrentMediaTime() clock to monotonic system uptime.
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
        // During dynamic render-quality transitions, `queryDrawables()` can
        // return multiple drawables; all of them must be rendered and presented.
        for drawable in drawables {
            // Attach the predicted anchor so the compositor can reproject for
            // late head motion (`nil` is accepted when tracking is unavailable).
            drawable.deviceAnchor = anchor
            draw(picked?.frame, profile: profile, into: drawable, commands: commands)
            drawable.encodePresent(commandBuffer: commands)
        }
        commands.commit()
        frame.endSubmission()
    }

    /// Submits newly decoded frames to the depth estimator while `Settings.depthFromPicture`
    /// is enabled and logs summary statistics every few seconds.
    private func followDepth(_ picked: (frame: DecodedFrame, isNew: Bool)?, at seconds: Double) {
        guard settings.current.depthFromPicture, !measureOnly else {
            if depthNoted != 0 {
                depthNoted = 0
                depth.forget()
            }
            return
        }
        shrink?.savesPictures = settings.current.showDepth
        if let picked, picked.isNew { depth.offer(picked.frame) }
        if depthNoted == 0 { depthNoted = seconds }
        guard seconds - depthNoted > 5 else { return }
        depthNoted = seconds
        guard let report = depth.report else {
            Log.note("depth: no depth estimate available yet")
            return
        }
        Log.note(String(format: "depth: %.0f%% coverage; center %.2f m, nearest %.2f m; "
                            + "%.1f ms latency, %d frames processed, %d skipped",
                        report.measured * 100, 1 / max(0.001, report.ahead), 1 / max(0.001, report.nearest),
                        report.behind, report.taken, report.passed))
    }

    /// Updates the tracked head offset to follow live eye-view shifts.
    /// visionOS shifts each eye's view transform by a few millimeters as the
    /// pupil rotates around the center of the eyeball. Updating per-eye offsets
    /// mid-session causes SteamVR to hitch, so instead we update the head
    /// midpoint each frame. Conjugate eye motion (both eyes looking in the same
    /// direction) is then reflected in the head pose; only vergence changes on
    /// near objects are omitted.
    private func followEyes(_ drawable: LayerRenderer.Drawable) {
        guard drawable.views.count == 2 else { return }
        let midpoint = (drawable.views[0].transform.columns.3 + drawable.views[1].transform.columns.3) * 0.5
        head.setEyeMidpoint(simd_make_float3(midpoint), atConnect: false)
    }

    /// Distance in meters for the opaque black backdrop quad placed behind
    /// unkeyed video frames (farther than video quads, inside the far clip plane).
    private static let backdropDistance: Float = 90

    private func draw(_ frame: DecodedFrame?, profile: DeviceProfile?, into drawable: LayerRenderer.Drawable,
                      commands: MTLCommandBuffer) {
        let views = drawable.views
        // Opaque, unkeyed streams surround the video with black margins (visible
        // when the user reduces the FOV scale), whereas chroma-keyed, alpha-channel,
        // or empty frames leave passthrough visible behind the quads. Simply
        // clearing color to black leaves depth at 0, which visionOS treats as
        // passthrough regardless of color, so we draw an explicit black backdrop
        // quad that writes depth behind the video quads.
        let roomBehind = frame == nil || profile == nil || renderer.chromaKey != nil || frame?.layout.transparent == true
        let field = settings.current.depthFromPicture ? depth.field : nil
        let shownDepth = settings.current.showDepth ? field : nil
        let eyes = drawQuads(into: drawable, commands: commands, renderer: renderer, frame: frame,
                             originFromDevice: lastOriginFromDevice,
                             behind: MTLClearColor(red: 0, green: 0, blue: 0, alpha: roomBehind ? 0 : 1)) { eye, view in
            guard let frame, let profile else { return [] }
            let picture = Composition.quads(for: eye, layout: frame.layout, depth: field)
                + (shownDepth.map { Composition.picture(of: $0, for: eye, layout: frame.layout) } ?? [])
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
