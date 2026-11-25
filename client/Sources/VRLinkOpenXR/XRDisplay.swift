// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Drives an OpenXR session and renders decoded VR stream frames, analogous to `CompositorDisplay` on visionOS.
///
/// Each frame, `XRDisplay` waits for the runtime's predicted display timestamp, locates both eye views,
/// renders the latest decoded frame's world-space quads into per-eye swapchains, and submits a single
/// `XrCompositionLayerProjection` for late-stage reprojection. It also reports frame presentation times
/// and refresh intervals back to the active `StreamingSession`.
///
/// Stream lifecycle follows the OpenXR session state: once the session begins and eye geometry is
/// measured, `onReady` delivers a `DeviceProfile` so the app can connect. When the session stops (for
/// example, when the headset is removed or another app takes focus), `onPaused` disconnects the stream
/// until the session restarts.
public final class XRDisplay<Graphics: XRGraphics> {
    public let instance: XRInstance
    public let graphics: Graphics
    /// Tracks head, controller, and hand poses sampled at each frame's predicted display time.
    public let input: XRInput

    /// Returns the active streaming session that receives frame timing telemetry.
    public var streamingSession: () -> (any StreamingSession)? = { nil }
    /// Returns the current chroma-key configuration for each frame.
    public var chromaKey: () -> ChromaKey? = { nil }
    /// Invoked on the render thread once the session starts and initial eye geometry is measured.
    public var onReady: ((DeviceProfile) -> Void)?
    /// Invoked on the render thread when the OpenXR session stops or exits.
    public var onPaused: (() -> Void)?

    /// Reference space used for pose tracking and projection layer submission.
    public enum Origin: String {
        /// Floor-level origin at the center of the user's configured guardian/stage play area.
        case stage
        /// Floor-level origin beneath the initial headset position.
        case localFloor = "local floor"
        /// Eye-level origin at the initial headset position (floor height will appear elevated to the host).
        case local
    }
    public let origin: Origin
    /// The in-headset panel, when the shell has one.
    public let panel: XRPanelLayer?

    private let frames: DisplayQueue<Graphics.Frame>
    private let log: (String) -> Void
    private let session: XrSession
    private var space: XrSpace?
    private var headSpace: XrSpace?
    private var swapchains: [XRSwapchain] = []
    private var recommended: (width: Int, height: Int) = (0, 0)
    private var blendModes: [XrEnvironmentBlendMode] = []
    private var refreshRates: [Float] = []

    private let lock = NSLock()
    private var quitting = false
    private var running = false
    private var finished = false
    private var measured = false
    private var described = false
    private var latestDisplayTime: XrTime = 0

    public init(applicationName: String, graphics: Graphics, frames: DisplayQueue<Graphics.Frame>, panel: XRPanelLayer? = nil,
                process: XRProcess = XRProcess(), log: @escaping (String) -> Void) throws {
        self.graphics = graphics
        self.panel = panel
        self.frames = frames
        self.log = log
        let instance = try XRInstance(applicationName: applicationName, required: Graphics.extensions, process: process, log: log)
        self.instance = instance
        let calls = instance.calls
        log("openxr: \(instance.runtimeName), headset \"\(instance.systemName())\"")
        log("openxr: extensions \(instance.extensions.sorted().joined(separator: " "))")

        try graphics.prepare(instance: instance)
        var made: XrSession?
        try graphics.withSessionBinding { binding in
            var info = XrSessionCreateInfo()
            info.type = XR_TYPE_SESSION_CREATE_INFO
            info.next = binding
            info.systemId = instance.system
            _ = try check(calls.createSession(instance.handle, &info, &made), "xrCreateSession")
        }
        guard let made else { throw XRFailure.call("xrCreateSession", XR_ERROR_RUNTIME_FAILURE) }
        session = made

        // Prefer STAGE for guardian bounds and floor height, falling back to LOCAL_FLOOR and then LOCAL.
        var count: UInt32 = 0
        try check(calls.enumerateReferenceSpaces(made, 0, &count, nil), "xrEnumerateReferenceSpaces")
        var kinds = [XrReferenceSpaceType](repeating: XR_REFERENCE_SPACE_TYPE_VIEW, count: Int(count))
        try check(calls.enumerateReferenceSpaces(made, count, &count, &kinds), "xrEnumerateReferenceSpaces")
        let choices: [(XrReferenceSpaceType, Origin)] = [
            (XR_REFERENCE_SPACE_TYPE_STAGE, .stage), (XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR, .localFloor),
            (XR_REFERENCE_SPACE_TYPE_LOCAL, .local),
        ]
        guard let chosen = choices.first(where: { kinds.contains($0.0) }) else { throw XRFailure.unsupported("a local reference space") }
        origin = chosen.1
        var place = XrReferenceSpaceCreateInfo()
        place.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO
        place.poseInReferenceSpace = .identity
        place.referenceSpaceType = chosen.0
        try check(calls.createReferenceSpace(made, &place, &space), "xrCreateReferenceSpace")
        place.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW
        try check(calls.createReferenceSpace(made, &place, &headSpace), "xrCreateReferenceSpace(view)")
        log("openxr: tracking in the \(origin.rawValue) space")

        input = try XRInput(instance: instance, session: made, log: log)

        let stereo = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
        try check(calls.enumerateViewConfigurationViews(instance.handle, instance.system, stereo, 0, &count, nil),
                  "xrEnumerateViewConfigurationViews")
        var blank = XrViewConfigurationView()
        blank.type = XR_TYPE_VIEW_CONFIGURATION_VIEW
        var views = [XrViewConfigurationView](repeating: blank, count: Int(count))
        try check(calls.enumerateViewConfigurationViews(instance.handle, instance.system, stereo, count, &count, &views),
                  "xrEnumerateViewConfigurationViews")
        guard views.count == 2 else { throw XRFailure.unsupported("stereo view configuration (runtime reported \(views.count) views)") }
        recommended = (Int(views[0].recommendedImageRectWidth), Int(views[0].recommendedImageRectHeight))

        try check(calls.enumerateSwapchainFormats(made, 0, &count, nil), "xrEnumerateSwapchainFormats")
        var formats = [Int64](repeating: 0, count: Int(count))
        try check(calls.enumerateSwapchainFormats(made, count, &count, &formats), "xrEnumerateSwapchainFormats")
        guard let format = graphics.chooseFormat(among: formats)
        else { throw XRFailure.unsupported("compatible swapchain pixel format (offered: \(formats))") }
        for view in views {
            var info = XrSwapchainCreateInfo()
            info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO
            info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT
            info.format = format
            info.sampleCount = 1
            info.width = view.recommendedImageRectWidth
            info.height = view.recommendedImageRectHeight
            info.faceCount = 1
            info.arraySize = 1
            info.mipCount = 1
            var swapchain: XrSwapchain?
            try check(calls.createSwapchain(made, &info, &swapchain), "xrCreateSwapchain")
            guard let swapchain else { throw XRFailure.call("xrCreateSwapchain", XR_ERROR_RUNTIME_FAILURE) }
            swapchains.append(XRSwapchain(handle: swapchain, format: format, width: Int(info.width), height: Int(info.height)))
        }
        try graphics.adopt(swapchains, instance: instance)
        if let panel {
            if let panelFormat = graphics.choosePanelFormat(among: formats) {
                var info = XrSwapchainCreateInfo()
                info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO
                info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT
                    | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT
                info.format = panelFormat
                info.sampleCount = 1
                info.width = UInt32(panel.width)
                info.height = UInt32(panel.height)
                info.faceCount = 1
                info.arraySize = 1
                info.mipCount = 1
                var swapchain: XrSwapchain?
                try check(calls.createSwapchain(made, &info, &swapchain), "xrCreateSwapchain(panel)")
                guard let swapchain else { throw XRFailure.call("xrCreateSwapchain(panel)", XR_ERROR_RUNTIME_FAILURE) }
                let wrapped = XRSwapchain(handle: swapchain, format: panelFormat, width: panel.width, height: panel.height)
                try graphics.adoptPanel(wrapped, instance: instance)
                panel.swapchain = wrapped
            } else {
                log("openxr: no swapchain format for the panel (offered: \(formats)); it will not be shown")
            }
        }
        log("openxr: drawing \(recommended.width) x \(recommended.height) per eye in format \(format)")

        try check(calls.enumerateEnvironmentBlendModes(instance.handle, instance.system, stereo, 0, &count, nil),
                  "xrEnumerateEnvironmentBlendModes")
        blendModes = [XrEnvironmentBlendMode](repeating: XR_ENVIRONMENT_BLEND_MODE_OPAQUE, count: Int(count))
        try check(calls.enumerateEnvironmentBlendModes(instance.handle, instance.system, stereo, count, &count, &blendModes),
                  "xrEnumerateEnvironmentBlendModes")

        if let enumerate = calls.enumerateDisplayRefreshRates, instance.extensions.contains("XR_FB_display_refresh_rate"),
           enumerate(made, 0, &count, nil).rawValue >= 0 {
            var rates = [Float](repeating: 0, count: Int(count))
            if enumerate(made, count, &count, &rates).rawValue >= 0 { refreshRates = rates }
        }
    }

    deinit {
        let calls = instance.calls
        for swapchain in swapchains + [panel?.swapchain].compactMap({ $0 }) { _ = calls.destroySwapchain(swapchain.handle) }
        for space in [space, headSpace] { if let space { _ = calls.destroySpace(space) } }
        _ = calls.destroySession(session)
    }

    /// Requests that the OpenXR session exit, causing `run()` to return once shutdown completes. Thread-safe.
    public func quit() {
        lock.lock()
        quitting = true
        lock.unlock()
    }

    /// Requests a display refresh rate of `hz` when `XR_FB_display_refresh_rate` supports it. Thread-safe.
    public func requestRefreshRate(_ hz: Float) {
        guard let request = instance.calls.requestDisplayRefreshRate, refreshRates.contains(hz) else { return }
        _ = request(session, hz)
    }

    /// Returns the four corners of the stage play-area rectangle when using `.stage` with valid bounds.
    public func boundary() -> [Point2] {
        guard origin == .stage else { return [] }
        var size = XrExtent2Df()
        guard instance.calls.getReferenceSpaceBoundsRect(session, XR_REFERENCE_SPACE_TYPE_STAGE, &size) == XR_SUCCESS,
              size.width > 0, size.height > 0
        else { return [] }
        let x = size.width / 2, z = size.height / 2
        return [Point2(-x, -z), Point2(x, -z), Point2(x, z), Point2(-x, z)]
    }

    /// Runs the blocking OpenXR event and frame loop until the session exits or `quit()` is called.
    public func run() throws {
        while !finished {
            try pollEvents()
            lock.lock()
            let leave = quitting
            quitting = false
            lock.unlock()
            if leave {
                // Request a clean exit so a running session transitions through STOPPING and EXITING.
                if running { _ = instance.calls.requestExitSession(session) } else { finished = true }
            }
            if running { try frame() } else { Thread.sleep(forTimeInterval: 0.05) }
        }
    }

    private func pollEvents() throws {
        let calls = instance.calls
        while true {
            var event = XrEventDataBuffer()
            event.type = XR_TYPE_EVENT_DATA_BUFFER
            guard calls.pollEvent(instance.handle, &event) == XR_SUCCESS else { return }
            switch event.type {
            case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED:
                let change = withUnsafeBytes(of: &event) { $0.load(as: XrEventDataSessionStateChanged.self) }
                try stateChanged(to: change.state)
            case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
                log("openxr: instance loss pending")
                finished = true
            case XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED:
                input.noteControllers()
            case XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING:
                // TODO: Update the play-space transform across reference-space changes like RoomTracker on visionOS.
                log("openxr: \(origin.rawValue) reference space change pending")
            case XR_TYPE_EVENT_DATA_DISPLAY_REFRESH_RATE_CHANGED_FB:
                let change = withUnsafeBytes(of: &event) { $0.load(as: XrEventDataDisplayRefreshRateChangedFB.self) }
                log("openxr: display refresh rate changed from \(change.fromDisplayRefreshRate) to \(change.toDisplayRefreshRate) Hz")
            default:
                break
            }
        }
    }

    private func stateChanged(to state: XrSessionState) throws {
        let calls = instance.calls
        switch state {
        case XR_SESSION_STATE_READY:
            var info = XrSessionBeginInfo()
            info.type = XR_TYPE_SESSION_BEGIN_INFO
            info.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
            try check(calls.beginSession(session, &info), "xrBeginSession")
            running = true
            measured = false
            log("openxr: session started")
        case XR_SESSION_STATE_STOPPING:
            running = false
            onPaused?()
            try check(calls.endSession(session), "xrEndSession")
            log("openxr: session stopped")
        case XR_SESSION_STATE_EXITING, XR_SESSION_STATE_LOSS_PENDING:
            if running { onPaused?() }
            running = false
            finished = true
        case XR_SESSION_STATE_FOCUSED:
            input.noteControllers()
        default:
            break
        }
    }

    /// Queries stereo `XrView` poses and fields of view at `time` in `base`, or returns `nil` if untracked.
    private func locateViews(at time: XrTime, in base: XrSpace?) -> [XrView]? {
        var which = XrViewLocateInfo()
        which.type = XR_TYPE_VIEW_LOCATE_INFO
        which.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
        which.displayTime = time
        which.space = base
        var state = XrViewState()
        state.type = XR_TYPE_VIEW_STATE
        var blank = XrView()
        blank.type = XR_TYPE_VIEW
        var views = [XrView](repeating: blank, count: 2)
        var count: UInt32 = 0
        guard instance.calls.locateViews(session, &which, &state, 2, &count, &views).rawValue >= 0, count == 2 else { return nil }
        let needed = XR_VIEW_STATE_POSITION_VALID_BIT | XR_VIEW_STATE_ORIENTATION_VALID_BIT
        return state.viewStateFlags & needed == needed ? views : nil
    }

    /// Builds a `DeviceProfile` from head-relative eye views, swapchain resolution, and display refresh rate.
    private func measure(at time: XrTime, period: Double) -> DeviceProfile? {
        guard let views = locateViews(at: time, in: headSpace) else { return nil }
        var profile = DeviceProfile()
        // Report parallel forward-facing eye poses to the host with frusta widened to enclose canted displays
        // (matching CompositorDisplay.measure), while rendering still uses the exact canted XrView poses.
        let turned = views.map { Pose($0.pose) }
        profile.eyesInHead = turned.map { Pose(position: $0.position, right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)) }
        profile.eyeFrusta = zip(views, turned).map { Frustum($0.fov).enclosing(turnedAs: $1) }
        profile.eyePixels = recommended
        var hz: Float = 0
        if let current = instance.calls.getDisplayRefreshRate, current(session, &hz).rawValue >= 0, hz > 0 {
            profile.refreshHz = hz
            profile.otherRefreshRates = refreshRates.filter { $0 != hz }
        } else {
            profile.refreshHz = Float((1 / period).rounded())
        }
        let apart = (turned[1].position.x - turned[0].position.x) * 1000
        log(String(format: "openxr: eyes %.1f mm apart, left eye tangents left %.2f right %.2f down %.2f up %.2f, %.0f Hz",
                   apart, profile.eyeFrusta[0].left, profile.eyeFrusta[0].right, profile.eyeFrusta[0].down,
                   profile.eyeFrusta[0].up, profile.refreshHz))
        return profile
    }

    /// Converts an OpenXR `XrTime` to `Uptime.nanoseconds` via `CLOCK_MONOTONIC` when
    /// `XR_KHR_convert_timespec_time` is available.
    private func uptime(of time: XrTime) -> UInt64? {
        guard let convert = instance.calls.convertTimeToTimespecTime else { return nil }
        var then = timespec(), now = timespec()
        guard convert(instance.handle, time, &then).rawValue >= 0 else { return nil }
        clock_gettime(CLOCK_MONOTONIC, &now)
        let ahead = Int64(then.tv_sec - now.tv_sec) * 1_000_000_000 + Int64(then.tv_nsec - now.tv_nsec)
        return UInt64(max(0, Int64(Uptime.nanoseconds) + ahead))
    }

    private func frame() throws {
        let calls = instance.calls
        var timing = XrFrameState()
        timing.type = XR_TYPE_FRAME_STATE
        try check(calls.waitFrame(session, nil, &timing), "xrWaitFrame")
        try check(calls.beginFrame(session, nil), "xrBeginFrame")
        let time = timing.predictedDisplayTime
        let period = timing.predictedDisplayPeriod > 0 ? Double(timing.predictedDisplayPeriod) / 1e9 : 1.0 / 90
        latestDisplayTime = time

        if let space { input.update(at: time, in: space) }
        if !measured, let profile = measure(at: time, period: period) {
            measured = true
            onReady?(profile)
        }

        let picked = frames.next()
        if let stream = streamingSession() {
            // Fall back to one refresh period ahead when XR_KHR_convert_timespec_time is unavailable.
            let shown = uptime(of: time) ?? Uptime.nanoseconds + UInt64(period * 1e9)
            stream.displayRefreshes(at: shown + UInt64(period * 1e9), period: period)
            if let picked, picked.isNew { stream.frameShown(picked.frame.frameID, at: shown) }
        }

        let key = chromaKey()
        if graphics.chromaKey != key { graphics.chromaKey = key }
        let frame = picked?.frame
        let transparent = frame == nil || key != nil || frame?.layout.transparent == true
        // Use alpha blending for passthrough when the stream is transparent and the headset supports it;
        // otherwise use the runtime's preferred blend mode.
        let alphaBlend = XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND
        let blend = transparent && blendModes.contains(alphaBlend) ? alphaBlend : (blendModes.first ?? XR_ENVIRONMENT_BLEND_MODE_OPAQUE)

        var end = XrFrameEndInfo()
        end.type = XR_TYPE_FRAME_END_INFO
        end.displayTime = time
        end.environmentBlendMode = blend
        let panelShown = try panelLayer()
        var quad = panelShown ?? XrCompositionLayerQuad()
        guard timing.shouldRender != 0, let views = locateViews(at: time, in: space) else {
            try check(calls.endFrame(session, &end), "xrEndFrame")
            return
        }

        var draws: [XREyeDraw] = []
        var projected: [XrCompositionLayerProjectionView] = []
        for eye in Eye.allCases {
            let swapchain = swapchains[eye.rawValue]
            var image: UInt32 = 0
            try check(calls.acquireSwapchainImage(swapchain.handle, nil, &image), "xrAcquireSwapchainImage")
            var wait = XrSwapchainImageWaitInfo()
            wait.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO
            wait.timeout = XR_INFINITE_DURATION
            try check(calls.waitSwapchainImage(swapchain.handle, &wait), "xrWaitSwapchainImage")

            let view = EyeView(eye: Pose(views[eye.rawValue].pose), frustum: Frustum(views[eye.rawValue].fov))
            draws.append(XREyeDraw(eye: eye.rawValue, image: Int(image), view: view,
                                   quads: frame.map { Composition.quads(for: eye, layout: $0.layout) } ?? []))
            var layerView = XrCompositionLayerProjectionView()
            layerView.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW
            layerView.pose = views[eye.rawValue].pose
            layerView.fov = views[eye.rawValue].fov
            layerView.subImage.swapchain = swapchain.handle
            layerView.subImage.imageRect.extent = XrExtent2Di(width: Int32(swapchain.width), height: Int32(swapchain.height))
            projected.append(layerView)
        }
        graphics.draw(draws, frame: frame, transparent: transparent)
        for swapchain in swapchains {
            try check(calls.releaseSwapchainImage(swapchain.handle, nil), "xrReleaseSwapchainImage")
        }
        if !described {
            described = true
            let eye = draws[0].view.eye
            log(String(format: "openxr: first frame, left eye at (%.2f, %.2f, %.2f) m looking (%.2f, %.2f, %.2f), blend mode %d",
                       eye.position.x, eye.position.y, eye.position.z, eye.forward.x, eye.forward.y, eye.forward.z,
                       blend.rawValue))
        }

        var layer = XrCompositionLayerProjection()
        layer.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION
        layer.space = space
        if transparent { layer.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT }
        try projected.withUnsafeBufferPointer { views in
            layer.viewCount = UInt32(views.count)
            layer.views = views.baseAddress
            try withUnsafeBytes(of: &layer) { bytes in
                try withUnsafeBytes(of: &quad) { quadBytes in
                    var layers = [bytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)]
                    // Composite the panel quad in front of the projection layer.
                    if panelShown != nil { layers.append(quadBytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)) }
                    try layers.withUnsafeBufferPointer {
                        end.layerCount = UInt32($0.count)
                        end.layers = $0.baseAddress
                        _ = try check(calls.endFrame(session, &end), "xrEndFrame")
                    }
                }
            }
        }
    }

    /// Updates the panel for this frame (positioning, pointer input, and swapchain upload) and returns its
    /// composition layer, or `nil` when hidden or before the first image is uploaded.
    private func panelLayer() throws -> XrCompositionLayerQuad? {
        guard let panel, let swapchain = panel.swapchain else { return nil }
        let calls = instance.calls
        // Fire `onMenuHeld` once when the menu button has been held for `holdSeconds`.
        let menu = input.hands().contains { hand in
            if case .controller(let state)? = hand { return state.menuButton }
            return false
        }
        if !menu {
            panel.menuHeldSince = nil
            panel.menuReported = false
        } else if let since = panel.menuHeldSince {
            if !panel.menuReported, Double(Uptime.nanoseconds &- since) / 1e9 >= XRPanelLayer.holdSeconds {
                panel.menuReported = true
                panel.onMenuHeld?()
            }
        } else {
            panel.menuHeldSince = Uptime.nanoseconds
        }
        guard panel.isWanted?() ?? panel.visible else {
            panel.pose = nil
            return nil
        }
        if panel.pose == nil {
            guard let head = input.head() else { return nil }
            panel.pose = XRPanelLayer.placed(before: head.pose, metersAway: panel.metersAway)
        }
        if let pixels = panel.update?(panel.pointer(from: input.pointers())) {
            var image: UInt32 = 0
            try check(calls.acquireSwapchainImage(swapchain.handle, nil, &image), "xrAcquireSwapchainImage(panel)")
            var wait = XrSwapchainImageWaitInfo()
            wait.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO
            wait.timeout = XR_INFINITE_DURATION
            try check(calls.waitSwapchainImage(swapchain.handle, &wait), "xrWaitSwapchainImage(panel)")
            graphics.drawPanel(pixels, image: Int(image))
            try check(calls.releaseSwapchainImage(swapchain.handle, nil), "xrReleaseSwapchainImage(panel)")
            panel.hasPicture = true
        }
        guard panel.hasPicture, let pose = panel.pose else { return nil }
        var quad = XrCompositionLayerQuad()
        quad.type = XR_TYPE_COMPOSITION_LAYER_QUAD
        quad.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
        quad.space = space
        quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH
        quad.subImage.swapchain = swapchain.handle
        quad.subImage.imageRect.extent = XrExtent2Di(width: Int32(swapchain.width), height: Int32(swapchain.height))
        // `Pose.forward` corresponds to -Z in `XrPosef`, so the quad's +Z front face points toward the user.
        quad.pose = pose.xr
        quad.size = XrExtent2Df(width: panel.metersWide, height: panel.metersWide * Float(panel.height) / Float(panel.width))
        return quad
    }
}
