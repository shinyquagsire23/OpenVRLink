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
    /// Returns whether stereo depth estimation (`use`) and the debug depth overlay (`show`) are enabled.
    public var depthFromPicture: () -> (use: Bool, show: Bool) = { (false, false) }
    /// Returns whether thermal refresh-rate stepping is enabled (`Settings.lowerRateWhenHot`).
    public var lowersRateWhenHot: () -> Bool = { false }
    /// True when the runtime offers multiple display refresh rates.
    public var canStepRefreshRate: Bool { refreshRates.count > 1 }
    /// Invoked on the render thread once the session starts and initial eye geometry is measured.
    public var onReady: ((DeviceProfile) -> Void)?
    /// Invoked on the render thread when the OpenXR session stops or exits.
    public var onPaused: (() -> Void)?
    /// Invoked on the render thread when a pending OpenXR reference-space or boundary change takes effect.
    public var onSpaceChanged: (() -> Void)?
    /// Optional directory path where `XRModelDump` saves OpenXR controller model binaries; set before calling `run()`.
    public var keepControllerModelsIn: String?
    private var modelDump: XRModelDump?
    /// Invoked on the render thread when a system-initiated recenter is detected while tracking in stage
    /// space, passing the updated `LOCAL` origin in stage coordinates (`followSystemRecenter`).
    public var onRecentered: ((Pose) -> Void)?

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
    /// Projection layer scaling filter chained via `XR_FB_composition_layer_settings`, or `nil` for the runtime default.
    private var layerFilter: UnsafeMutablePointer<XrCompositionLayerSettingsFB>?
    private let layerFilterName: String
    /// Initial layer configuration passed at startup.
    private let layerChoicesAtStart: XRLayerChoices
    /// Returns the current live layer configuration each frame so panel changes take effect immediately.
    /// Called on the render thread.
    public var layerChoices: (() -> XRLayerChoices)?
    private var layerChoicesNoted: XRLayerChoices?
    /// Exponential moving average of GPU draw time in seconds, and whether the GPU has headroom to re-render
    /// every display refresh.
    private var drawTakes: Double = 0, drawsEveryRefresh = true
    /// `LOCAL` reference space and its last observed pose in stage coordinates, used by `followSystemRecenter`.
    private var localSpace: XrSpace?
    private var localSeen: Pose?, localChecked: UInt64 = 0
    /// Per-eye base swapchains, followed by the two sharp-layer swapchains when enabled.
    private var swapchains: [XRSwapchain] = []
    private var hasSharpLayer: Bool { swapchains.count == 4 }
    /// Android `Surface` swapchain and `ANativeWindow` for the transparent overlay quad (`HeadsetQuirks.emptyTopLayer`),
    /// and whether the initial transparent buffer has been posted.
    private var topLayer: XrSwapchain?, topLayerWindow: UnsafeMutableRawPointer?, topLayerFilled = false
    private var topLayerTried = false
    private let javaVM: UnsafeMutableRawPointer?
    private let eyeDetail: Float
    /// Host-requested refresh rate and active thermal refresh-rate cap. Guarded by `lock`.
    private var wantedHz: Float?, heatCapHz: Float?
    /// Display refreshes per video frame (2 during half-rate thermal throttling, 1 otherwise). Guarded by `lock`.
    private var picturesEvery = 1
    /// Highest reported `XR_EXT_performance_settings` thermal level (0 normal, 25 warning, 75 impaired) and timestamp of its onset.
    private var heat: Int32 = 0, heatSince: UInt64 = 0, heatChecked: UInt64 = 0
    private var heatByDomain: [UInt32: Int32] = [:]
    private let sustainedPerformance: Bool
    /// Request `XR_PERF_SETTINGS_LEVEL_BOOST_EXT` instead of `SUSTAINED_HIGH` for the GPU (`HeadsetQuirks.boostGPU`); set before calling `run()`.
    public var boostGPU = false
    private let compositorPlacesLayers: Bool
    /// Active `XR_FB_passthrough` instance and layer handle when passthrough uses a composition layer.
    private var passthrough: XrPassthroughFB?, passthroughLayer: XrPassthroughLayerFB?
    private var passthroughRunning = false
    private var sharpShown = false
    /// Previously rendered projection views cached for resubmission on display refreshes with no new video frame.
    private var drawnFor: (eyes: [XrCompositionLayerProjectionView], sharp: [XrCompositionLayerProjectionView], sharpAlone: Bool,
                           key: ChromaKey?, transparent: Bool)?
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
    private var pace = FramePace()
    private var face: (any FaceSource)?
    private let tracking: TrackingThread
    /// Whether face tracking is active for this session.
    public var tracksFace: Bool { face != nil }
    /// Latest face expression weights, or `nil` when face tracking is unavailable or untracked. Thread-safe.
    public func faceExpressions() -> FaceExpressions? { face?.expressions() }
    /// Whether face tracking is supported by the runtime but awaiting system face calibration. Thread-safe.
    public var faceNeedsCalibration: Bool { face?.needsCalibration ?? false }
    private lazy var depth = StereoDepthEstimator<Graphics.Frame>(measure: graphics.measure) { [graphics] in
        graphics.shrink($0, width: $1, done: $2)
    }
    private var depthInUse = false
    private var depthNoted: UInt64 = 0
    /// Timestamp (`XrTime`) at which a pending reference-space change takes effect.
    private var spaceChangesAt: XrTime?

    /// - Parameters:
    ///   - sharpLayerPixels: Width and height in pixels of a secondary swapchain per eye used to submit the
    ///     stream's high-density region (`FrameLayout.Sharp`) on its own projection layer, or 0 to disable.
    ///   - eyeDetail: Ratio of the display's center pixel density to the recommended eye swapchain size,
    ///     reported to foveating hosts (`DeviceProfile.detailEyePixels`) when the sharp layer is enabled.
    ///   - compositorPlacesLayers: Whether the runtime honors per-layer poses and fields of view
    ///     (`HeadsetQuirks.compositorPlacesLayers`). When false, the sharp layer and frame reuse are disabled.
    ///   - passthroughLayer: Prefer an `XR_FB_passthrough` layer over alpha-blend environment mode.
    ///   - emptyTopLayer: Submit a transparent Android `Surface` overlay quad on top of all other layers (`HeadsetQuirks.emptyTopLayer`).
    ///   - colorSpace: Color space declared via `XR_FB_color_space` (`rec709`, `rec2020`, `p3`, or `unmanaged`).
    public init(applicationName: String, graphics: Graphics, frames: DisplayQueue<Graphics.Frame>, panel: XRPanelLayer? = nil,
                process: XRProcess = XRProcess(), sharpLayerPixels: Int = 0, eyeDetail: Float = 1,
                sustainedPerformance: Bool = true, compositorPlacesLayers: Bool = true, passthroughLayer: Bool = false,
                emptyTopLayer: Bool = false,
                colorSpace: String = "rec709", layerFilter: String = "none", blendTest: String = "none",
                skipEmptyProjection: Bool = false, streamQuads: String = "never", quadDistance: Float = 50,
                reuseFrames: Bool = true,
                log: @escaping (String) -> Void) throws {
        self.eyeDetail = eyeDetail
        self.compositorPlacesLayers = compositorPlacesLayers
        self.layerFilterName = layerFilter
        self.javaVM = process.javaVM
        var atStart = XRLayerChoices()
        atStart.blendTest = blendTest
        atStart.topLayer = emptyTopLayer
        atStart.skipEmptyProjection = skipEmptyProjection
        atStart.streamQuads = streamQuads
        atStart.quadDistance = quadDistance
        atStart.reuseFrames = reuseFrames
        layerChoicesAtStart = atStart
        self.sustainedPerformance = sustainedPerformance
        self.graphics = graphics
        self.panel = panel
        self.frames = frames
        self.log = log
        let instance = try XRInstance(applicationName: applicationName, required: Graphics.extensions,
                                      unlisted: emptyTopLayer ? ["XR_KHR_android_surface_swapchain"] : [], process: process, log: log)
        self.instance = instance
        let calls = instance.calls
        log("openxr: \(instance.runtimeName), headset \"\(instance.systemName())\"")
        log("openxr: extensions \(instance.extensions.sorted().joined(separator: " "))")
        log("openxr: also offered \(instance.offered.subtracting(instance.extensions).sorted().joined(separator: " "))")

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

        // Declare the stream's sRGB/Rec.709 color primaries so wide-gamut displays do not oversaturate colors.
        let spaces = ["rec709": XR_COLOR_SPACE_REC709_FB, "rec2020": XR_COLOR_SPACE_REC2020_FB, "p3": XR_COLOR_SPACE_P3_FB]
        if instance.extensions.contains("XR_FB_color_space"), let set = calls.setColorSpace, let space = spaces[colorSpace] {
            let result = set(made, space)
            log("openxr: color space set to \(colorSpace)" + (result.rawValue < 0 ? " refused (\(XRFailure.name(of: result)))" : ""))
        }

        // Request projection layer sharpening or supersampling when configured (matching `vrlink`).
        let filters: [String: XrCompositionLayerSettingsFlagsFB] = [
            "sharpen": XR_COMPOSITION_LAYER_SETTINGS_NORMAL_SHARPENING_BIT_FB,
            "sharpen_quality": XR_COMPOSITION_LAYER_SETTINGS_QUALITY_SHARPENING_BIT_FB,
            "supersample": XR_COMPOSITION_LAYER_SETTINGS_NORMAL_SUPER_SAMPLING_BIT_FB,
            "supersample_quality": XR_COMPOSITION_LAYER_SETTINGS_QUALITY_SUPER_SAMPLING_BIT_FB,
            "auto": XR_COMPOSITION_LAYER_SETTINGS_AUTO_LAYER_FILTER_BIT_META,
        ]
        if let flags = filters[layerFilter] {
            if instance.extensions.contains("XR_FB_composition_layer_settings") {
                let settings = UnsafeMutablePointer<XrCompositionLayerSettingsFB>.allocate(capacity: 1)
                settings.initialize(to: XrCompositionLayerSettingsFB())
                settings.pointee.type = XR_TYPE_COMPOSITION_LAYER_SETTINGS_FB
                settings.pointee.layerFlags = flags
                self.layerFilter = settings
                log("openxr: layer filter set to \(layerFilter)")
            } else {
                log("openxr: layer filter \(layerFilter) unavailable (missing XR_FB_composition_layer_settings)")
            }
        }

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
        if origin == .stage, kinds.contains(XR_REFERENCE_SPACE_TYPE_LOCAL) {
            place.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL
            _ = calls.createReferenceSpace(made, &place, &localSpace)
        }
        log("openxr: tracking in the \(origin.rawValue) space")

        input = try XRInput(instance: instance, session: made, log: log)
        face = makeFaceSource(instance: instance, session: made, log: log)
        tracking = TrackingThread(input: input, face: face)

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
        // Request mutable format on all eye swapchains, or fall back to standard swapchains for all of them.
        var mutable = graphics.wantsMutableFormat
        let usage = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT
        for view in views {
            var info = XrSwapchainCreateInfo()
            info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO
            info.usageFlags = usage | (mutable ? XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT : 0)
            info.format = format
            info.sampleCount = 1
            info.width = view.recommendedImageRectWidth
            info.height = view.recommendedImageRectHeight
            info.faceCount = 1
            info.arraySize = 1
            info.mipCount = 1
            var swapchain: XrSwapchain?
            if mutable, swapchains.isEmpty, calls.createSwapchain(made, &info, &swapchain).rawValue < 0 {
                log("openxr: runtime rejected XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT; falling back to standard swapchains")
                mutable = false
                info.usageFlags = usage
                swapchain = nil
            }
            if swapchain == nil { try check(calls.createSwapchain(made, &info, &swapchain), "xrCreateSwapchain") }
            guard let swapchain else { throw XRFailure.call("xrCreateSwapchain", XR_ERROR_RUNTIME_FAILURE) }
            swapchains.append(XRSwapchain(handle: swapchain, format: format, width: Int(info.width), height: Int(info.height),
                                          mutableFormat: mutable))
        }
        // The sharp layer's swapchains come after the eyes' so a draw's `eye` index picks either.
        let sharpSide = !compositorPlacesLayers ? 0 : min(sharpLayerPixels, Int(min(views[0].maxImageRectWidth, views[0].maxImageRectHeight)))
        if sharpSide >= 256 {
            for _ in views {
                var info = XrSwapchainCreateInfo()
                info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO
                info.usageFlags = usage | (mutable ? XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT : 0)
                info.format = format
                info.sampleCount = 1
                info.width = UInt32(sharpSide)
                info.height = UInt32(sharpSide)
                info.faceCount = 1
                info.arraySize = 1
                info.mipCount = 1
                var swapchain: XrSwapchain?
                guard calls.createSwapchain(made, &info, &swapchain).rawValue >= 0, let swapchain else {
                    log("openxr: no swapchain for the sharp layer; drawing each eye on one layer")
                    swapchains.removeLast(swapchains.count - 2)
                    break
                }
                swapchains.append(XRSwapchain(handle: swapchain, format: format, width: sharpSide, height: sharpSide, mutableFormat: mutable))
            }
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
        log("openxr: drawing \(recommended.width) x \(recommended.height) per eye in format \(format) (at most "
            + "\(views[0].maxImageRectWidth) x \(views[0].maxImageRectHeight))"
            + (hasSharpLayer ? ", and the stream's sharpest part again at \(sharpSide) x \(sharpSide)" : ""))

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

        // Create an XR_FB_passthrough layer when alpha-blend environment mode is unavailable or overridden by passthroughLayer.
        if instance.extensions.contains("XR_FB_passthrough"), passthroughLayer || !blendModes.contains(XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND),
           let create = calls.createPassthrough, let createLayer = calls.createPassthroughLayer {
            var info = XrPassthroughCreateInfoFB()
            info.type = XR_TYPE_PASSTHROUGH_CREATE_INFO_FB
            var result = create(made, &info, &passthrough)
            if result.rawValue >= 0, let passthrough {
                var layerInfo = XrPassthroughLayerCreateInfoFB()
                layerInfo.type = XR_TYPE_PASSTHROUGH_LAYER_CREATE_INFO_FB
                layerInfo.passthrough = passthrough
                layerInfo.flags = XR_PASSTHROUGH_IS_RUNNING_AT_CREATION_BIT_FB
                layerInfo.purpose = XR_PASSTHROUGH_LAYER_PURPOSE_RECONSTRUCTION_FB
                result = createLayer(made, &layerInfo, &self.passthroughLayer)
            }
            if result.rawValue < 0 || self.passthroughLayer == nil {
                log("openxr: no passthrough layer (\(XRFailure.name(of: result)))")
                if let passthrough { _ = calls.destroyPassthrough?(passthrough) }
                passthrough = nil
                self.passthroughLayer = nil
            } else {
                log("openxr: using XR_FB_passthrough layer for passthrough")
            }
        }
    }

    /// Starts or pauses passthrough camera capture to match frame transparency.
    private func runPassthrough(_ wanted: Bool) {
        guard let passthrough, wanted != passthroughRunning else { return }
        // Explicitly call xrPassthroughStartFB because the YVR runtime ignores XR_PASSTHROUGH_IS_RUNNING_AT_CREATION_BIT_FB.
        let result = wanted ? instance.calls.passthroughStart?(passthrough) : instance.calls.passthroughPause?(passthrough)
        passthroughRunning = wanted
        if let result, result.rawValue < 0 { log("openxr: could not \(wanted ? "start" : "pause") passthrough (\(XRFailure.name(of: result)))") }
    }

    deinit {
        tracking.stop()
        let calls = instance.calls
        for swapchain in swapchains + [panel?.swapchain].compactMap({ $0 }) { _ = calls.destroySwapchain(swapchain.handle) }
        if let topLayer { _ = calls.destroySwapchain(topLayer) }
        #if os(Android)
        if let topLayerWindow { ovrl_xr_release_window(topLayerWindow) }
        #endif
        if let passthroughLayer { _ = calls.destroyPassthroughLayer?(passthroughLayer) }
        if let passthrough { _ = calls.destroyPassthrough?(passthrough) }
        for space in [space, headSpace, localSpace] { if let space { _ = calls.destroySpace(space) } }
        layerFilter?.deallocate()
        _ = calls.destroySession(session)
    }

    /// Whether the headset supports `XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND` passthrough, required for chroma
    /// keying and alpha-blended streams.
    public var canShowRoom: Bool { passthroughLayer != nil || blendModes.contains(XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND) }

    /// Requests that the OpenXR session exit, causing `run()` to return once shutdown completes. Thread-safe.
    public func quit() {
        lock.lock()
        quitting = true
        lock.unlock()
    }

    /// Requests a display refresh rate of `hz` when `XR_FB_display_refresh_rate` supports it. Thread-safe.
    public func requestRefreshRate(_ hz: Float) {
        guard refreshRates.contains(hz) else { return }
        lock.lock()
        // Ignore host rate requests while thermal throttling restricts the advertised rate list.
        if heatCapHz == nil { wantedHz = hz }
        lock.unlock()
        applyRefreshRate()
    }

    /// Applies `wantedHz` clamped to any active thermal refresh-rate cap.
    private func applyRefreshRate() {
        guard let request = instance.calls.requestDisplayRefreshRate else { return }
        lock.lock()
        let wanted = wantedHz, cap = heatCapHz
        lock.unlock()
        guard let top = wanted ?? refreshRates.max() else { return }
        let steps = rateSteps
        guard let step = steps.filter({ $0.shown <= min(top, cap ?? top) + 0.5 }).max(by: { $0.shown < $1.shown })
                ?? steps.min(by: { $0.shown < $1.shown }) else { return }
        _ = request(session, step.display)
        lock.lock()
        let changed = picturesEvery != step.every
        picturesEvery = step.every
        lock.unlock()
        if changed { log("openxr: asking the host for a picture every \(step.every == 1 ? "frame" : "\(step.every) frames") (\(step.shown) a second)") }
    }

    /// Available target frame rates sorted highest-first: all native display refresh rates, plus half of the
    /// lowest native refresh rate (keeping the display at its lowest rate and requesting a video frame every
    /// second refresh).
    ///
    /// Half-rates of higher refresh rates (such as 45 fps at 90 Hz or 36 fps at 72 Hz) are omitted because
    /// reaching them from 60 Hz increases display clocks while hot and triggers extra host encoder resets.
    private var rateSteps: [(shown: Float, display: Float, every: Int)] {
        guard let slowest = refreshRates.min() else { return [] }
        return (refreshRates.map { (shown: $0, display: $0, every: 1) } + [(shown: slowest / 2, display: slowest, every: 2)])
            .sorted { $0.shown > $1.shown }
    }

    /// Steps the refresh rate down while `XR_EXT_performance_settings` reports thermal impairment (`75`), and
    /// steps it back up once thermal state returns to normal (`0`).
    private func followHeat(at now: UInt64) {
        guard refreshRates.count > 1, now >= heatChecked + 1_000_000_000 else { return }
        heatChecked = now
        lock.lock()
        let holding = heatCapHz
        lock.unlock()
        // Re-apply the cap once per second so newly connected sessions pick up an active thermal cap.
        streamingSession()?.holdRefreshRates(to: holding)
        let seconds = Double(now - heatSince) / 1e9
        lock.lock()
        let cap = heatCapHz, wanted = wantedHz
        lock.unlock()
        var hz: Float = 0
        _ = instance.calls.getDisplayRefreshRate?(session, &hz)
        let current = cap ?? (hz > 0 ? hz : wanted ?? refreshRates.max() ?? 0)
        let rates = rateSteps.map(\.shown)
        var next = cap
        if !lowersRateWhenHot() {
            // When thermal stepping is disabled, clear any active thermal cap immediately.
            guard cap != nil else { return }
            next = nil
        } else if heat >= 75, seconds >= (cap == nil ? 3 : XRDisplay.heatStep), let lower = rates.filter({ $0 < current - 0.5 }).max() {
            next = lower
        } else if heat < 25, seconds >= XRDisplay.heatStep, let cap {
            let higher = rates.filter { $0 > cap + 0.5 }.min()
            next = higher.flatMap { $0 >= (wanted ?? refreshRates.max() ?? $0) - 0.5 ? nil : $0 }
        } else {
            return
        }
        guard next != cap else { return }
        heatSince = now
        lock.lock()
        // Record the baseline refresh rate before throttling so we can restore it once temperatures drop.
        if wantedHz == nil, hz > 0 { wantedHz = hz }
        heatCapHz = next
        lock.unlock()
        // Update the session's advertised rate list before changing the frame interval so the host does not
        // immediately re-request the previous rate.
        streamingSession()?.holdRefreshRates(to: next)
        log(next.map { "openxr: heat level \(heat); holding the stream to \($0) pictures a second" } ?? "openxr: heat back to normal; rate no longer held down")
        applyRefreshRate()
    }

    /// Detects system-initiated recenters (such as holding the headset's home button) while tracking in stage
    /// space.
    ///
    /// Because stage space stays fixed to the physical room, a system recenter only moves the runtime's
    /// `LOCAL` space rather than the stage poses sent to the host. Polling `LOCAL` inside stage space twice
    /// per second detects shifts larger than 5 cm or ~3 degrees and forwards the updated origin via
    /// `onRecentered`. Reference-space change events are not used because runtime behavior varies (for
    /// example, Android XR posts change events for all spaces, including stage, on every recenter).
    private func followSystemRecenter(at time: XrTime, now: UInt64) {
        guard let localSpace, let space, now >= localChecked + 500_000_000 else { return }
        localChecked = now
        var location = XrSpaceLocation()
        location.type = XR_TYPE_SPACE_LOCATION
        let needed = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT
        guard instance.calls.locateSpace(localSpace, space, time, &location).rawValue >= 0, location.locationFlags & needed == needed
        else { return }
        let found = Pose(location.pose)
        defer { localSeen = found }
        guard let before = localSeen else { return }
        let moved = found.position - before.position
        // Ignore tracking drift below 5 cm horizontally or ~3 degrees of yaw.
        guard (moved.x * moved.x + moved.z * moved.z).squareRoot() > 0.05 || found.forward.dot(before.forward) < 0.9986 else { return }
        log(String(format: "openxr: system recenter detected: local origin at (%.2f, %.2f) m in stage, forward (%.2f, %.2f)",
                   found.position.x, found.position.z, found.forward.x, found.forward.z))
        onRecentered?(found)
    }

    /// Interval in seconds between thermal refresh-rate adjustments.
    static var heatStep: Double { 30 }

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
                let change = withUnsafeBytes(of: &event) { $0.load(as: XrEventDataReferenceSpaceChangePending.self) }
                let kinds = [XR_REFERENCE_SPACE_TYPE_VIEW: "view", XR_REFERENCE_SPACE_TYPE_LOCAL: "local", XR_REFERENCE_SPACE_TYPE_STAGE: "stage",
                             XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR: "local floor"]
                log("openxr: \(kinds[change.referenceSpaceType] ?? "type \(change.referenceSpaceType.rawValue)") reference space change pending"
                    + " (tracking in the \(origin.rawValue) space)")
                spaceChangesAt = max(spaceChangesAt ?? 0, change.changeTime)
            case XR_TYPE_EVENT_DATA_RECOMMENDED_RESOLUTION_CHANGED_ANDROID:
                // Log Android XR's dynamic swapchain resolution recommendation (allocated swapchains keep their initial size).
                var count: UInt32 = 0
                var blank = XrViewConfigurationView()
                blank.type = XR_TYPE_VIEW_CONFIGURATION_VIEW
                var views = [XrViewConfigurationView](repeating: blank, count: 2)
                if calls.enumerateViewConfigurationViews(instance.handle, instance.system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                                         2, &count, &views).rawValue >= 0 {
                    log("openxr: the system now suggests \(views[0].recommendedImageRectWidth) x \(views[0].recommendedImageRectHeight) per eye"
                        + " (drawing \(recommended.width) x \(recommended.height))")
                }
            case XR_TYPE_EVENT_DATA_PERF_SETTINGS_EXT:
                // Log CPU/GPU performance and thermal state transitions (0 normal, 25 warning, 75 impaired).
                let change = withUnsafeBytes(of: &event) { $0.load(as: XrEventDataPerfSettingsEXT.self) }
                let part = change.domain == XR_PERF_SETTINGS_DOMAIN_GPU_EXT ? "GPU" : "CPU"
                let what: String
                switch change.subDomain {
                case XR_PERF_SETTINGS_SUB_DOMAIN_COMPOSITING_EXT: what = "compositing"
                case XR_PERF_SETTINGS_SUB_DOMAIN_RENDERING_EXT: what = "rendering"
                default: what = "heat"
                }
                log("openxr: \(part) \(what) went from level \(change.fromLevel.rawValue) to \(change.toLevel.rawValue) (0 normal, 25 warning, 75 impaired)")
                if change.subDomain == XR_PERF_SETTINGS_SUB_DOMAIN_THERMAL_EXT {
                    heatByDomain[change.domain.rawValue] = Int32(change.toLevel.rawValue)
                    let worst = heatByDomain.values.max() ?? 0
                    if worst != heat {
                        heat = worst
                        heatSince = Uptime.nanoseconds
                    }
                }
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
            // Request sustained high CPU and GPU clock levels rather than default power-saving clocks.
            if sustainedPerformance, let setLevel = calls.setPerformanceLevel {
                for domain in [XR_PERF_SETTINGS_DOMAIN_CPU_EXT, XR_PERF_SETTINGS_DOMAIN_GPU_EXT] {
                    let boost = boostGPU && domain == XR_PERF_SETTINGS_DOMAIN_GPU_EXT
                    let result = setLevel(session, domain, boost ? XR_PERF_SETTINGS_LEVEL_BOOST_EXT : XR_PERF_SETTINGS_LEVEL_SUSTAINED_HIGH_EXT)
                    if boost { log("openxr: requested boost GPU performance level") }
                    if result.rawValue < 0 { log("openxr: could not set the performance level (XrResult \(result.rawValue))") }
                }
            }
        case XR_SESSION_STATE_STOPPING:
            running = false
            onPaused?()
            // Wait for any in-flight tracking poll to finish before ending the OpenXR session.
            runPassthrough(false)
            _ = try tracking.whileIdle { try check(calls.endSession(session), "xrEndSession") }
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
        if hasSharpLayer, eyeDetail > 1 {
            // Round dimensions to multiples of 32 pixels for hardware video encoders.
            func finer(_ side: Int) -> Int { Int((Float(side) * eyeDetail / 32).rounded()) * 32 }
            profile.detailEyePixels = (finer(recommended.width), finer(recommended.height))
        }
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
        let began = Uptime.nanoseconds
        try check(calls.waitFrame(session, nil, &timing), "xrWaitFrame")
        let waited = Uptime.nanoseconds
        try check(calls.beginFrame(session, nil), "xrBeginFrame")
        let time = timing.predictedDisplayTime
        let period = timing.predictedDisplayPeriod > 0 ? Double(timing.predictedDisplayPeriod) / 1e9 : 1.0 / 90
        latestDisplayTime = time

        // Poll controllers, hands, eye gaze, and face on TrackingThread (~10 ms via IPC on Android XR) so input
        // queries do not stall the render loop.
        if let space { tracking.sample(at: time, in: space) }
        if let changes = spaceChangesAt, time >= changes {
            spaceChangesAt = nil
            // Reset the panel pose so it is placed in front of the user in the updated reference space.
            panel?.pose = nil
            onSpaceChanged?()
        }
        if !measured, let profile = measure(at: time, period: period) {
            measured = true
            onReady?(profile)
        }
        // Record per-stage pre-draw timings for FramePace.
        var stepBegan = Uptime.nanoseconds
        pace.note("tracking", stepBegan - waited)
        func stepDone(_ name: String) {
            let now = Uptime.nanoseconds
            pace.note(name, now - stepBegan)
            stepBegan = now
        }

        followHeat(at: waited)
        followSystemRecenter(at: time, now: waited)
        if let folder = keepControllerModelsIn {
            if modelDump == nil { modelDump = XRModelDump(instance: instance, session: session, folder: folder, log: log) }
            modelDump?.save(now: waited)
        }
        let picked = frames.next()
        if let stream = streamingSession() {
            // Fall back to one refresh period ahead when XR_KHR_convert_timespec_time is unavailable.
            let shown = uptime(of: time) ?? Uptime.nanoseconds + UInt64(period * 1e9)
            // At a half rate the host is told a frame lasts two of the display's.
            lock.lock()
            let every = picturesEvery
            lock.unlock()
            stream.displayRefreshes(at: shown + UInt64(period * 1e9), period: period * Double(every))
            if let picked, picked.isNew { stream.frameShown(picked.frame.frameID, at: shown) }
        }

        stepDone("picking a picture")
        let field = followDepth(picked)
        stepDone("depth")
        let key = chromaKey()
        if graphics.chromaKey != key { graphics.chromaKey = key }
        let frame = picked?.frame
        // Enable passthrough only when the background can show through (before the first frame arrives, when
        // client chroma keying is enabled, or when the frame has alpha or a host chroma key).
        let transparent = frame == nil || key != nil || frame?.layout.transparent == true
        // Use alpha blending for passthrough when the stream is transparent and the headset supports it;
        // otherwise use the runtime's preferred blend mode.
        let choices = layerChoices?() ?? layerChoicesAtStart
        if choices.topLayer, !topLayerTried { makeTopLayer() }
        if layerChoicesNoted != choices {
            layerChoicesNoted = choices
            log("openxr: surface overlay quad \(choices.topLayer ? (topLayer == nil ? "unavailable" : "on") : "off"), "
                + "empty projection layer \(choices.skipEmptyProjection ? "omitted" : "submitted"), stream quads \(choices.streamQuads) "
                + "at \(choices.quadDistance) m, blend test \(choices.blendTest), "
                + (choices.reuseFrames ? "reusing unchanged frames" : "re-rendering every refresh")
                + (choices.sharpWhenTransparent ? "" : ", sharp layer disabled while transparent"))
        }
        let blendTest = choices.blendTest
        let alphaBlend = XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND
        let opaque = blendModes.contains(XR_ENVIRONMENT_BLEND_MODE_OPAQUE) ? XR_ENVIRONMENT_BLEND_MODE_OPAQUE : blendModes.first
        let blend = passthroughLayer != nil ? (opaque ?? XR_ENVIRONMENT_BLEND_MODE_OPAQUE)
            : (transparent && blendTest != "no_env" || blendTest == "env" || blendTest == "both") && blendModes.contains(alphaBlend)
            ? alphaBlend : (blendTest == "no_env" ? opaque : blendModes.first) ?? XR_ENVIRONMENT_BLEND_MODE_OPAQUE
        runPassthrough(transparent && timing.shouldRender != 0)

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

        stepDone("panel and views")
        var draws: [XREyeDraw] = []
        var projected: [XrCompositionLayerProjectionView] = []
        var sharpProjected: [XrCompositionLayerProjectionView] = []
        // Whether the sharp layer renders a standalone alpha-feathered tile over a transparent background.
        var sharpAlone = true
        var acquired: [XRSwapchain] = []
        // Reuse the previous frame's swapchain images and render poses when no new video frame has arrived so
        // the OpenXR compositor can reproject them. When stereo depth warping is active, we re-render every
        // refresh because compositor reprojection is rotation-only and mixing it with depth-warped frames causes
        // translational judder. However, if GPU draw time exceeds 60% of the refresh period (such as during
        // passthrough on a warm Galaxy XR), we fall back to compositor frame reuse to avoid dropped refreshes.
        if drawsEveryRefresh ? drawTakes > period * 0.6 : drawTakes < period * 0.4 {
            drawsEveryRefresh.toggle()
            log(String(format: "openxr: GPU draw time %.1f ms / %.1f ms refresh; ", drawTakes * 1000, period * 1000)
                + (drawsEveryRefresh ? "resuming per-refresh rendering" : "reusing unchanged frames"))
        }
        let reuse = compositorPlacesLayers && choices.reuseFrames && picked?.isNew == false && drawnFor != nil && field.show == nil
            && (field.use == nil || !drawsEveryRefresh)
            && drawnFor?.key == key && drawnFor?.transparent == transparent
        if reuse {
            projected = drawnFor?.eyes ?? []
            sharpProjected = drawnFor?.sharp ?? []
            sharpAlone = drawnFor?.sharpAlone ?? true
            pace.note("share of frames handed over undrawn", 1_000_000)   // averages to a fraction, not milliseconds
        }
        let eyeViews = Eye.allCases.map { EyeView(eye: Pose(views[$0.rawValue].pose), frustum: Frustum(views[$0.rawValue].fov)) }
        // Compute per-eye sharp-layer frusta (enabled for both eyes together or neither).
        var sharp: [Frustum] = []
        if !reuse, hasSharpLayer, choices.sharpWhenTransparent || !transparent, let frame {
            sharp = Eye.allCases.compactMap { Composition.sharpFrustum(for: $0, layout: frame.layout, from: eyeViews[$0.rawValue]) }
            if sharp.count != 2 { sharp = [] }
        }
        var allQuads: [[Quad]] = []
        for eye in (reuse ? [] : Eye.allCases) {
            let swapchain = swapchains[eye.rawValue]
            var image: UInt32 = 0
            try check(calls.acquireSwapchainImage(swapchain.handle, nil, &image), "xrAcquireSwapchainImage")
            var wait = XrSwapchainImageWaitInfo()
            wait.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO
            wait.timeout = XR_INFINITE_DURATION
            try check(calls.waitSwapchainImage(swapchain.handle, &wait), "xrWaitSwapchainImage")

            stepDone("swapchain images")
            let view = eyeViews[eye.rawValue]
            var quads: [Quad] = []
            if let frame {
                quads = Composition.quads(for: eye, layout: frame.layout, depth: field.use)
                if let shown = field.show { quads += Composition.picture(of: shown, for: eye, layout: frame.layout) }
            }
            allQuads.append(quads)
            // When the sharp layer draws a standalone foveal tile, omit that tile from the base eye layer and
            // render the base layer into a sub-rect sized to 1.25x the peripheral tile dimensions.
            var size: (width: Int, height: Int)?
            if !sharp.isEmpty, let region = frame?.layout.views[eye.rawValue].sharp, let tile = region.tile, let rest = region.rest,
               quads.indices.contains(tile), field.show == nil {
                quads.remove(at: tile)
                size = (min(swapchain.width, max(256, rest.width * 5 / 4)), min(swapchain.height, max(256, rest.height * 5 / 4)))
            }
            draws.append(XREyeDraw(eye: eye.rawValue, image: Int(image), view: view, quads: quads, size: size))
            stepDone("quads")
            var layerView = XrCompositionLayerProjectionView()
            layerView.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW
            layerView.pose = views[eye.rawValue].pose
            layerView.fov = views[eye.rawValue].fov
            layerView.subImage.swapchain = swapchain.handle
            layerView.subImage.imageRect.extent = XrExtent2Di(width: Int32(size?.width ?? swapchain.width),
                                                              height: Int32(size?.height ?? swapchain.height))
            projected.append(layerView)
            acquired.append(swapchain)
        }
        // Render the high-density region into the sharp-layer swapchains through its enclosing sub-frustum.
        if !reuse, hasSharpLayer, let frame {
            if sharp.count == 2 {
                for eye in Eye.allCases {
                    let swapchain = swapchains[2 + eye.rawValue]
                    var image: UInt32 = 0
                    try check(calls.acquireSwapchainImage(swapchain.handle, nil, &image), "xrAcquireSwapchainImage(sharp)")
                    var wait = XrSwapchainImageWaitInfo()
                    wait.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO
                    wait.timeout = XR_INFINITE_DURATION
                    try check(calls.waitSwapchainImage(swapchain.handle, &wait), "xrWaitSwapchainImage(sharp)")
                    acquired.append(swapchain)
                    let window = sharp[eye.rawValue]
                    // Clamp to the source region's pixel size; when a single tile covers the region, draw only
                    // that tile onto a transparent attachment so its feathered border blends over the base layer.
                    let region = frame.layout.views[eye.rawValue].sharp
                    let size = (width: min(swapchain.width, max(64, region?.width ?? swapchain.width)),
                                height: min(swapchain.height, max(64, region?.height ?? swapchain.height)))
                    var quads = allQuads[eye.rawValue]
                    if let tile = region?.tile, quads.indices.contains(tile) { quads = [quads[tile]] } else { sharpAlone = false }
                    draws.append(XREyeDraw(eye: 2 + eye.rawValue, image: Int(image),
                                           view: EyeView(eye: draws[eye.rawValue].view.eye, frustum: window), quads: quads,
                                           size: size, clear: region?.tile != nil))
                    var layerView = projected[eye.rawValue]
                    layerView.fov = XrFovf(angleLeft: atan(window.left), angleRight: atan(window.right),
                                           angleUp: atan(window.up), angleDown: atan(window.down))
                    layerView.subImage.swapchain = swapchain.handle
                    layerView.subImage.imageRect.extent = XrExtent2Di(width: Int32(size.width), height: Int32(size.height))
                    sharpProjected.append(layerView)
                }
            }
            if sharpShown != (sharp.count == 2) {
                sharpShown = sharp.count == 2
                if sharpShown, let first = frame.layout.views.first?.sharp {
                    let window = sharp[0]
                    log(String(format: "openxr: sharp layer on: the stream's densest part is %d x %d pixels over %.1f x %.1f degrees, "
                               + "%.0f pixels per degree against the eye layer's %.0f",
                               first.width, first.height,
                               (atan(window.right) - atan(window.left)) * 180 / .pi, (atan(window.up) - atan(window.down)) * 180 / .pi,
                               Float(first.width) / ((atan(first.frustum.right) - atan(first.frustum.left)) * 180 / .pi),
                               Float(recommended.width) / ((atan(draws[0].view.frustum.right) - atan(draws[0].view.frustum.left)) * 180 / .pi)))
                } else {
                    log("openxr: sharp layer off: the stream has no denser part in view")
                }
            }
        }
        stepDone("swapchain images")
        let drawBegan = Uptime.nanoseconds
        if !reuse {
            graphics.draw(draws, frame: frame, transparent: transparent)
            pace.note("waiting for the GPU", graphics.lastGPUWait)
            for step in graphics.lastDrawSteps { pace.note(step.name, step.nanoseconds) }
            drawTakes += (Double(graphics.lastGPUWait) / 1e9 - drawTakes) / 20
            drawnFor = frame == nil ? nil : (projected, sharpProjected, sharpAlone, key, transparent)
        }
        let drawn = Uptime.nanoseconds
        for swapchain in acquired {
            try check(calls.releaseSwapchainImage(swapchain.handle, nil), "xrReleaseSwapchainImage")
        }
        if !described, !draws.isEmpty {
            described = true
            let eye = draws[0].view.eye
            log(String(format: "openxr: first frame, left eye at (%.2f, %.2f, %.2f) m looking (%.2f, %.2f, %.2f), blend mode %d",
                       eye.position.x, eye.position.y, eye.position.z, eye.forward.x, eye.forward.y, eye.forward.z,
                       blend.rawValue))
        }

        var layer = XrCompositionLayerProjection()
        layer.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION
        layer.space = space
        if transparent && blendTest != "no_flag" || blendTest == "flag" || blendTest == "both" { layer.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT }
        var room = XrCompositionLayerPassthroughFB()
        room.type = XR_TYPE_COMPOSITION_LAYER_PASSTHROUGH_FB
        room.flags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
        room.layerHandle = passthroughLayer
        if let layerFilter { layer.next = UnsafeRawPointer(layerFilter) }
        var sharpLayer = layer
        if sharpAlone { sharpLayer.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT }
        // Post a single transparent buffer to the Android Surface swapchain on its first rendered frame.
        #if os(Android)
        if let topLayerWindow, !topLayerFilled, choices.topLayer {
            if ovrl_xr_fill_window(topLayerWindow, 2, 2) == 0 {
                topLayerFilled = true
            } else {
                log("openxr: failed to post transparent buffer to Android Surface overlay; disabling")
                ovrl_xr_release_window(topLayerWindow)
                self.topLayerWindow = nil
            }
        }
        #endif
        var topQuad = XrCompositionLayerQuad()
        topQuad.type = XR_TYPE_COMPOSITION_LAYER_QUAD
        topQuad.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
        topQuad.space = headSpace
        topQuad.eyeVisibility = XR_EYE_VISIBILITY_BOTH
        topQuad.subImage.swapchain = topLayer
        topQuad.subImage.imageRect.extent = XrExtent2Di(width: 2, height: 2)
        topQuad.pose.orientation.w = 1
        topQuad.pose.position.z = -1
        topQuad.size = XrExtent2Df(width: 0.001, height: 0.001)
        // On Galaxy XR, submitting a projection layer during passthrough causes the compositor to downscale all
        // layers, whereas quad layers remain sharp. When `streamQuads` is active, convert each eye's projection
        // view into an equivalent quad layer placed `quadDistance` meters ahead of the eye.
        let onQuads = frame != nil && (choices.streamQuads == "always" || choices.streamQuads == "room" && transparent)
        var streamQuads: [XrCompositionLayerQuad] = []
        if onQuads {
            for (views, like) in [(projected, layer), (sharpProjected, sharpLayer)] {
                for (eye, view) in views.enumerated() {
                    streamQuads.append(XRDisplay.quad(showing: view, eye: eye, like: like, metersAhead: choices.quadDistance))
                }
            }
        }
        try streamQuads.withUnsafeBufferPointer { streamQuads in
        try projected.withUnsafeBufferPointer { views in
            layer.viewCount = UInt32(views.count)
            layer.views = views.baseAddress
            try sharpProjected.withUnsafeBufferPointer { sharpViews in
            sharpLayer.viewCount = UInt32(sharpViews.count)
            sharpLayer.views = sharpViews.baseAddress
            try withUnsafeBytes(of: &topQuad) { topBytes in
            try withUnsafeBytes(of: &sharpLayer) { sharpBytes in
            try withUnsafeBytes(of: &layer) { bytes in
                try withUnsafeBytes(of: &quad) { quadBytes in
                try withUnsafeBytes(of: &room) { roomBytes in
                    var layers = [bytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)]
                    // Omit the projection layer when rendering stream views as quads or when idle with skipEmptyProjection.
                    if onQuads || choices.skipEmptyProjection && frame == nil { layers.removeAll() }
                    // The room goes under everything, seen wherever the picture over it is see-through.
                    if passthroughLayer != nil, transparent {
                        layers.insert(roomBytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self), at: 0)
                    }
                    // The sharp layer goes over the eye layer and shows the same picture, only finer.
                    if onQuads {
                        for index in streamQuads.indices {
                            layers.append(UnsafeRawPointer(streamQuads.baseAddress! + index).assumingMemoryBound(to: XrCompositionLayerBaseHeader.self))
                        }
                    } else if !sharpProjected.isEmpty {
                        layers.append(sharpBytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self))
                    }
                    // Composite the panel quad in front of the projection layer.
                    if panelShown != nil { layers.append(quadBytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)) }
                    // Submit the transparent Android Surface overlay quad on top of all other layers.
                    if topLayer != nil, topLayerFilled, choices.topLayer { layers.append(topBytes.baseAddress?.assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)) }
                    try layers.withUnsafeBufferPointer {
                        end.layerCount = UInt32($0.count)
                        end.layers = $0.baseAddress
                        _ = try check(calls.endFrame(session, &end), "xrEndFrame")
                    }
                }
                }
            }
            }
            }
            }
        }
        }
        if frame != nil {
            let ended = Uptime.nanoseconds
            pace.add(new: picked?.isNew == true, wait: waited - began, prepare: drawBegan - waited, draw: drawn - drawBegan,
                     end: ended - drawn, at: ended)
            if let line = pace.report(at: ended, period: period) { log(line) }
        }
    }

    /// Creates the 2 x 2 Android `Surface` swapchain for `HeadsetQuirks.emptyTopLayer` on first use. On Galaxy XR,
    /// including a `Surface`-backed layer prevents the compositor from downscaling opaque projection layers.
    /// Creation is deferred until enabled so other headsets never call `xrCreateSwapchainAndroidSurfaceKHR`.
    private func makeTopLayer() {
        topLayerTried = true
        #if os(Android)
        let calls = instance.calls
        do {
            if instance.extensions.contains(XR_KHR_ANDROID_SURFACE_SWAPCHAIN_EXTENSION_NAME),
               let create = try? instance.function("xrCreateSwapchainAndroidSurfaceKHR", as: PFN_xrCreateSwapchainAndroidSurfaceKHR.self) {
                // XR_KHR_android_surface_swapchain requires format and sample/face/array/mip counts to be zero.
                var info = XrSwapchainCreateInfo()
                info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO
                info.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT
                info.width = 2
                info.height = 2
                var swapchain: XrSwapchain?
                var surface: jobject?
                let result = create(session, &info, &swapchain, &surface)
                if result.rawValue >= 0, let swapchain, let surface, let window = ovrl_xr_window(javaVM, surface) {
                    topLayer = swapchain
                    topLayerWindow = window
                    log("openxr: created Android Surface swapchain for transparent overlay quad")
                } else {
                    log("openxr: failed to create Android Surface swapchain (\(XRFailure.name(of: result)))")
                    if let swapchain { _ = calls.destroySwapchain(swapchain) }
                }
            } else {
                log("openxr: XR_KHR_android_surface_swapchain is unavailable; skipping overlay quad")
            }
        }
        #endif
    }

    /// Builds a single-eye `XrCompositionLayerQuad` matching a projection view by intersecting the view frustum
    /// with a plane `metersAhead` in front of the eye, preserving the projection layer's space, flags, and settings.
    private static func quad(showing view: XrCompositionLayerProjectionView, eye: Int, like layer: XrCompositionLayerProjection,
                             metersAhead: Float) -> XrCompositionLayerQuad {
        let left = tan(view.fov.angleLeft), right = tan(view.fov.angleRight), up = tan(view.fov.angleUp), down = tan(view.fov.angleDown)
        // Quad center in eye space rotated into layer space via v + 2w(q x v) + 2q x (q x v).
        let middle = (x: metersAhead * (left + right) / 2, y: metersAhead * (up + down) / 2, z: -metersAhead)
        let q = view.pose.orientation
        let once = (x: q.y * middle.z - q.z * middle.y, y: q.z * middle.x - q.x * middle.z, z: q.x * middle.y - q.y * middle.x)
        let twice = (x: q.y * once.z - q.z * once.y, y: q.z * once.x - q.x * once.z, z: q.x * once.y - q.y * once.x)
        var quad = XrCompositionLayerQuad()
        quad.type = XR_TYPE_COMPOSITION_LAYER_QUAD
        quad.next = layer.next
        quad.layerFlags = layer.layerFlags
        quad.space = layer.space
        quad.eyeVisibility = eye == 0 ? XR_EYE_VISIBILITY_LEFT : XR_EYE_VISIBILITY_RIGHT
        quad.subImage = view.subImage
        quad.pose.orientation = q
        quad.pose.position = XrVector3f(x: view.pose.position.x + middle.x + 2 * (q.w * once.x + twice.x),
                                        y: view.pose.position.y + middle.y + 2 * (q.w * once.y + twice.y),
                                        z: view.pose.position.z + middle.z + 2 * (q.w * once.z + twice.z))
        quad.size = XrExtent2Df(width: metersAhead * (right - left), height: metersAhead * (up - down))
        return quad
    }

    /// Feeds newly decoded frames to the stereo depth estimator when enabled and returns the reprojected depth
    /// field for the current frame (plus the debug overlay field when requested).
    private func followDepth(_ picked: (frame: Graphics.Frame, isNew: Bool)?) -> (use: DepthField?, show: DepthField?) {
        let wanted = depthFromPicture()
        guard wanted.use, graphics.supportsDepth else {
            if depthInUse {
                depthInUse = false
                depthNoted = 0
                depth.forget()
            }
            return (nil, nil)
        }
        depthInUse = true
        guard let picked else { return (nil, nil) }
        if picked.isNew {
            // Sample depth densely around the hands or controllers and straight ahead.
            let hands = input.hands().compactMap { hand -> Vec3? in
                switch hand {
                case .controller(let state)?: return state.grip.pose.position
                case .hand(let tracked)?: return tracked.joints.first?.position
                case nil: return nil
                }
            }
            depth.offer(picked.frame, interests: DepthSampling.interests(layout: picked.frame.layout, hands: hands))
        }
        let now = Uptime.nanoseconds
        if depthNoted == 0 { depthNoted = now }
        if now - depthNoted > 5_000_000_000 {
            depthNoted = now
            if let report = depth.report {
                log(String(format: "depth: %.0f%% coverage; center %.2f m, nearest %.2f m; %.1f ms to match, %.1f ms latency, "
                               + "%d frames processed, %d skipped",
                           report.measured * 100, 1 / max(0.001, report.ahead), 1 / max(0.001, report.nearest), report.milliseconds,
                           report.behind, report.taken, report.passed))
            } else {
                log("depth: no depth estimate available yet")
            }
        }
        let field = depth.field?.fitted(to: picked.frame.layout)
        return (field, wanted.show ? field : nil)
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
        // Reposition the panel if the user has walked away from it or the tracking origin shifted.
        if let pose = panel.pose, let head = input.head()?.pose {
            let away = pose.position - head.position
            if away.dot(away).squareRoot() > panel.metersAway * 2.5 { panel.pose = nil }
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

/// Polls `XRInput` and `FaceSource` on a dedicated thread using the latest predicted display timestamp.
///
/// If a sample takes longer than one frame interval, intermediate timestamps are coalesced so only the newest
/// requested timestamp runs next without blocking the render loop.
final class TrackingThread: @unchecked Sendable {
    private let input: XRInput
    private let face: (any FaceSource)?
    private let lock = NSLock()
    /// Held while a sample is being taken.
    private let busy = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var wanted: (time: XrTime, space: XrSpace)?
    private var started = false, stopped = false

    init(input: XRInput, face: (any FaceSource)?) {
        self.input = input
        self.face = face
    }

    /// Asks for a sample at `time`, replacing any not yet begun.
    func sample(at time: XrTime, in space: XrSpace) {
        lock.lock()
        let waiting = wanted != nil
        wanted = (time, space)
        let start = !started
        started = true
        lock.unlock()
        if start {
            let thread = Thread { [self] in run() }
            thread.name = "OpenVRLink tracking"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        if !waiting { wake.signal() }
    }

    private func run() {
        while true {
            wake.wait()
            lock.lock()
            let next = wanted
            wanted = nil
            let leave = stopped
            lock.unlock()
            if leave { return }
            guard let next else { continue }
            busy.lock()
            input.update(at: next.time, in: next.space)
            face?.update(at: next.time)
            busy.unlock()
        }
    }

    /// Runs `body` while no sample is being taken.
    func whileIdle<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        wanted = nil
        lock.unlock()
        busy.lock()
        defer { busy.unlock() }
        return try body()
    }

    /// Ends the thread, returning once any sample in progress is done.
    func stop() {
        lock.lock()
        stopped = true
        wanted = nil
        lock.unlock()
        wake.signal()
        busy.lock()
        busy.unlock()
    }
}

/// Accumulates per-stage frame-loop timings during streaming and formats a periodic summary log line.
struct FramePace {
    static let every = 5.0

    private var since: UInt64 = 0, last: UInt64 = 0
    private var frames = 0, new = 0, late = 0
    private var wait: UInt64 = 0, prepare: UInt64 = 0, draw: UInt64 = 0, end: UInt64 = 0
    private var longestDraw: UInt64 = 0, longestGap: UInt64 = 0
    private var steps: [String: UInt64] = [:]

    /// Adds `nanoseconds` to the running total of a named step within a frame.
    mutating func note(_ step: String, _ nanoseconds: UInt64) {
        steps[step, default: 0] += nanoseconds
    }

    /// Records timing for one displayed frame (in nanoseconds) across `xrWaitFrame`, frame preparation, GPU draw
    /// submission, and `xrEndFrame`.
    mutating func add(new isNew: Bool, wait: UInt64, prepare: UInt64, draw: UInt64, end: UInt64, at now: UInt64) {
        if since == 0 { since = now }
        if last != 0 { longestGap = max(longestGap, now - last) }
        last = now
        frames += 1
        if isNew { new += 1 }
        self.wait += wait
        self.prepare += prepare
        self.draw += draw
        self.end += end
        longestDraw = max(longestDraw, draw)
    }

    /// Formats and resets the accumulated metrics once `every` seconds have elapsed. `period` is the display
    /// refresh period in seconds.
    mutating func report(at now: UInt64, period: Double) -> String? {
        let seconds = Double(now - since) / 1e9
        guard since != 0, seconds >= FramePace.every, frames > 0 else { return nil }
        func each(_ total: UInt64) -> Double { Double(total) / Double(frames) / 1e6 }
        let line = String(format: "openxr: showed %.0f frames/s of %.0f (%.0f new pictures/s); each frame waited %.1f ms, "
                              + "prepared %.1f, drew %.1f (longest %.1f), ended %.1f; longest between frames %.1f ms",
                          Double(frames) / seconds, 1 / period, Double(new) / seconds, each(wait), each(prepare), each(draw),
                          Double(longestDraw) / 1e6, each(end), Double(longestGap) / 1e6)
        // Steps that average a quarter millisecond or more, longest first.
        let parts = steps.filter { each($0.value) >= 0.25 }.sorted { $0.value > $1.value }
            .map { String(format: "%@ %.1f", $0.key, each($0.value)) }.joined(separator: ", ")
        self = FramePace()
        return parts.isEmpty ? line : line + "; of which " + parts
    }
}
