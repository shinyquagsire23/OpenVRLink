// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Stores per-headset rendering and decoder workarounds for behavior that OpenXR and MediaCodec do not report.
///
/// Defaults follow ALVR's OpenXR client (`alvr/system_info` and `alvr/client_openxr/src/stream.rs`). Each
/// setting can be overridden at runtime via `apply(_:)`, which on Android reads `debug.openvrlink.*` system
/// properties so device behavior can be tested over `adb` without rebuilding:
///
///     adb shell setprop debug.openvrlink.float_target 1
///     adb shell setprop debug.openvrlink.float_encoded 0
public struct HeadsetQuirks: Equatable {
    public enum Headset: String {
        case quest1, quest2, quest3, quest3S, questPro, quest
        case pico, galaxyXR, lynx, vive, yvr, playForDream
        /// Valve's Steam Frame, where Android apps run in its Lepton container.
        case steamFrame
        case unknown
    }

    public enum VideoRange: String {
        /// Limited/studio video range (16...235 for 8-bit YCbCr).
        case narrow
        case full
    }

    public var headset: Headset

    /// Prefer 16-bit float swapchains when offered by the runtime. Disabled by default because the video stream
    /// is 8-bit and 8-bit sRGB swapchains behave consistently across runtimes.
    public var floatTarget = false
    /// Whether the compositor interprets a float swapchain as sRGB-encoded (`true`) or linear (`false`). OpenXR
    /// leaves this unspecified; Pico and Galaxy XR expect sRGB-encoded values.
    public var floatTargetIsEncoded = false
    /// Render to sRGB swapchains through 8-bit UNORM image views (`XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT`) so the
    /// fragment shader can write sRGB-encoded values directly instead of converting each pixel to linear light for
    /// the GPU to re-encode. Alpha blending then operates on sRGB-encoded values.
    public var encodedTarget = false
    /// Overrides the YCbCr range for decoders that misreport it, or `nil` to use the decoder's reported range.
    public var videoRange: VideoRange?
    /// Request host encoding gamma (`HostExtensions.Features.encodingGamma`), inverted in the client fragment shader.
    public var encodingGamma = true
    /// Set full-range BT.2020 color keys on `AMediaFormat` when configuring the decoder, matching `vrlink`.
    public var decoderColorKeys = true
    /// Probe the hardware decoder and Vulkan Y'CbCr sampler at startup with `ColorProbe` and apply the
    /// resulting inverse color matrix. Falls back to `shaderColorConversion` and `undoRangeStretch` when
    /// disabled or when no known behavior matches.
    public var measureColors = true
    /// Bypass the GPU driver's Y'CbCr sampler conversion (`RGB_IDENTITY`) and convert full-range BT.2020 Y'CbCr
    /// to RGB in the fragment shader.
    public var shaderColorConversion = false
    /// Color space declared to the OpenXR runtime via `XR_FB_color_space` (`rec709` to match SteamVR's sRGB
    /// rendering and ALVR, `rec2020`, `p3`, or `unmanaged` to leave the runtime default). Leaving wide-gamut
    /// displays unmanaged oversaturates colors.
    public var colorSpace = "rec709"
    public static let colorSpaces = ["rec709", "p3", "rec2020", "unmanaged"]
    /// Projection layer scaling filter requested via `XR_FB_composition_layer_settings` when supported:
    /// `none` for the runtime default, `sharpen` or `sharpen_quality` when upscaling layers to the display,
    /// `supersample` or `supersample_quality` when downscaling, or `auto` to let the runtime choose.
    public var layerFilter = "none"
    public static let layerFilters = ["none", "sharpen", "sharpen_quality", "supersample", "supersample_quality", "auto"]
    /// Overrides the environment blend mode and layer alpha flags to test Galaxy XR compositor downscaling
    /// during passthrough. Setting `env` uses alpha-blend environment mode on opaque frames, `flag` sets the
    /// source-alpha blend flag on opaque layers, and `both` turns on both overrides. Setting `no_env` keeps
    /// opaque environment mode on transparent frames (hiding passthrough), and `no_flag` clears the
    /// source-alpha blend flag on transparent layers.
    public var blendTest = "none"
    public static let blendTests = ["none", "env", "flag", "both", "no_env", "no_flag"]
    /// Quirk option keys that apply immediately at runtime via `XRDisplay.layerChoices` without restarting the app.
    public static let liveKeys: Set<String> = ["blend_test", "empty_top_layer", "skip_empty_projection", "stream_quads", "quad_distance", "reuse_frames", "sharp_when_transparent"]
    /// Omit the projection layer when no stream frame is available. On Galaxy XR, submitting a projection layer
    /// while passthrough is visible causes the compositor to downscale all layers, including the UI panel.
    public var skipEmptyProjection = false
    /// Controls when stream views are submitted as per-eye quad layers instead of projection layers. Can be
    /// `never`, `always`, or `room` (which uses quads only while passthrough is visible to avoid Galaxy XR's
    /// projection-layer downscaling). Each quad is placed `quadDistance` meters in front of the eye.
    public var streamQuads = "never"
    /// When no new video frame has arrived on a display refresh, resubmit the previously rendered swapchain
    /// images for the compositor to reproject instead of re-rendering. Because compositor reprojection is
    /// rotation-only, `XRDisplay` still re-renders every refresh when stereo depth warping is active to avoid
    /// translational judder, unless GPU draw time exceeds 60% of the refresh period.
    public var reuseFrames = true
    /// Keep rendering the sharp foveal layer when the stream is transparent (during room view or chroma keying).
    /// Chroma keying adds per-pixel shader work and passthrough adds compositor GPU overhead, so slower headsets
    /// like Quest Pro drop frames when the sharp layer stays enabled.
    public var sharpWhenTransparent = true
    public static let streamQuadChoices = ["never", "room", "always"]
    /// Distance in meters from the eye to the quad plane when `streamQuads` is active. Using 50 m minimizes
    /// parallax error during translational head movement compared to `vrlink`'s ~2 m distance.
    public var quadDistance: Float = 50
    /// Invert narrow-range expansion (16...235 to 0...255) applied by the decoder or GPU driver to full-range
    /// video, preventing crushed and tinted shadows (matching ALVR's range fix on standalone headsets).
    public var undoRangeStretch = false
    /// Fallback initial resolution passed to `AMediaCodec_configure` when dimensions cannot be parsed from
    /// parameter sets beforehand. Some hardware decoders fail to start if the initial size differs too much from
    /// the stream.
    public var decoderWidth = 2048, decoderHeight = 2048
    /// Enables low-latency decoding flags (Android 11 `low-latency` and Qualcomm's vendor extension).
    public var decoderLowLatency = true
    /// Wait on the frame's GPU fence before releasing swapchain images to the OpenXR runtime. OpenXR does not
    /// specify whether `xrReleaseSwapchainImage` synchronizes with pending GPU work, so out-of-process
    /// compositors could otherwise display an unfinished or stale swapchain image. Disabled on headsets whose
    /// runtimes synchronize swapchain images internally, which lets the CPU prepare the next frame while the GPU
    /// renders the current one at the cost of a few milliseconds of extra predicted latency.
    public var waitForGPU = true
    /// Target frame rate passed to the decoder (`operating-rate`), or 0 to leave it unset. Qualcomm decoders
    /// scale clocks from this hint and default to 30 fps without it; 32767 matches ALVR's maximum-rate setting.
    public var decoderOperatingRate = 32767
    /// Width and height in pixels of the secondary per-eye swapchain used to render the stream's high-density
    /// region (such as the foveal tile) on its own projection layer, or 0 to render into a single eye layer.
    public var sharpLayerPixels = 2048
    /// Ratio of the display's center pixel density to the runtime's recommended eye swapchain size. Multiplied
    /// into the eye resolution reported to foveating hosts (WiVRn) when the sharp layer is enabled.
    public var eyeDetail: Float = 1.4
    /// Request sustained high CPU and GPU performance levels via `XR_EXT_performance_settings`.
    public var sustainedPerformance = true
    /// Request `XR_PERF_SETTINGS_LEVEL_BOOST_EXT` instead of `SUSTAINED_HIGH` for the GPU. Useful for testing
    /// headsets where GPU draw time approaches the refresh period, such as Quest Pro at 90 Hz, though runtimes
    /// may cap how long boost stays active and it increases heat and battery drain.
    public var boostGPU = false
    /// Start sessions with a reduced uplink packet rate (sending hand data once per video frame). On Galaxy XR,
    /// Wi-Fi begins rejecting outgoing packets once the Wi-Fi thermal sensor exceeds ~75 °C.
    public var leanUplink = false
    /// Whether the OpenXR compositor honors per-layer poses and fields of view. When false (YVR and Play For
    /// Dream render every projection layer full-screen at the current head pose), `XRDisplay` renders every
    /// frame for the current display view and disables the sharp layer, sub-rect eye rendering, and layer reuse.
    public var compositorPlacesLayers = true
    /// Use an `XR_FB_passthrough` layer for passthrough even when `XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND` is
    /// advertised. Runtimes without alpha-blend mode use `XR_FB_passthrough` automatically.
    public var passthroughLayer = false
    /// Submit a small transparent quad backed by an Android `Surface` swapchain (`XR_KHR_android_surface_swapchain`)
    /// on top of all other layers. On Galaxy XR, the compositor downscales projection layers unless the frame
    /// includes a `Surface`-backed layer; Angelo Pascuzzi's `xr-porting-hub` Steam Link patches use the same workaround.
    public var emptyTopLayer = false

    /// Derive head or controller velocities from finite differences between two predicted poses instead of
    /// using the runtime's reported velocity vectors. Pico, Vive, and YVR runtimes report velocities in the
    /// wrong coordinate frame, causing misdirected host pose prediction (matching ALVR's `get_head_data` and
    /// controller motion workarounds in `interaction.rs`).
    public var headVelocityFromPoses = false, controllerVelocityFromPoses = false

    /// Local transform applied to the left controller's reported grip pose (+X right, +Y up, +Z back), in meters
    /// and degrees of X, Y, Z Euler rotation, mirrored across X for the right controller. Since controllers are
    /// reported to the host as Quest Touch, this aligns another headset's grip pose with Quest's.
    public var gripOffset = GripOffset()

    public struct GripOffset: Equatable {
        public var x: Float = 0, y: Float = 0, z: Float = 0
        public var pitch: Float = 0, yaw: Float = 0, roll: Float = 0

        public init(x: Float = 0, y: Float = 0, z: Float = 0, pitch: Float = 0, yaw: Float = 0, roll: Float = 0) {
            (self.x, self.y, self.z, self.pitch, self.yaw, self.roll) = (x, y, z, pitch, yaw, roll)
        }

        public var isNone: Bool { self == GripOffset() }

        /// Converts the offset into a local-space `Pose`, mirroring across the X axis for the right hand.
        public func pose(for side: Side) -> Pose {
            let flip: Float = side == .left ? 1 : -1, radians = Float.pi / 180
            return Pose(position: Vec3(x * flip, y, z), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
                .turned(by: Vec3(pitch * radians, 0, 0)).turned(by: Vec3(0, yaw * radians * flip, 0))
                .turned(by: Vec3(0, 0, roll * radians * flip))
        }

        /// Computes the grip transform from `headset` to Quest Touch by composing ALVR's per-headset grip offset
        /// with the inverse of ALVR's Quest offset (`get_controller_offset` in `alvr/client_openxr/src/interaction.rs`).
        static func towardQuest(from headset: Headset) -> GripOffset {
            let quest = GripOffset(x: -0.005, y: -0.005, pitch: -15)
            let own: GripOffset
            switch headset {
            case .quest1: own = GripOffset(x: -0.013, y: -0.005, pitch: -20)
            case .pico: own = GripOffset(x: -0.01, y: -0.035, pitch: -6, yaw: 6)
            case .vive: own = GripOffset(z: -0.02)
            case .galaxyXR: own = GripOffset(z: 0.055)
            case .quest, .quest2, .quest3, .quest3S, .questPro: return GripOffset()
            // Play For Dream controllers use a dedicated host-side grip offset in ControllerState.gripOffset.
            case .lynx, .yvr, .playForDream, .steamFrame, .unknown: return GripOffset()
            }
            // Apply the headset's offset to ALVR's common grip pose, then the inverse of Quest's offset.
            let identity = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
            let pose = own.pose(for: .left).placing(quest.pose(for: .left).relative(identity))
            // Extract fixed-axis X, Y, Z Euler angles from the resulting rotation.
            let back = pose.forward * -1
            let yaw = -asin(max(-1, min(1, pose.right.z)))
            let pitch = atan2(pose.up.z, back.z), roll = atan2(pose.right.y, pose.right.x)
            let degrees = 180 / Float.pi
            return GripOffset(x: pose.position.x, y: pose.position.y, z: pose.position.z,
                              pitch: pitch * degrees, yaw: yaw * degrees, roll: roll * degrees)
        }
    }

    public init(_ headset: Headset = .unknown) {
        self.headset = headset
        gripOffset = GripOffset.towardQuest(from: headset)
        floatTargetIsEncoded = headset == .pico || headset == .galaxyXR
        encodedTarget = [.quest, .quest2, .quest3, .quest3S, .questPro].contains(headset)
        waitForGPU = ![.quest, .quest2, .quest3, .quest3S, .questPro, .galaxyXR].contains(headset)
        // Galaxy XR upscales 1856 x 2160 swapchains to 3552 x 3840 panels with a soft default filter unless
        // sharpening is requested.
        // Quest Pro's foveal region is ~1152 px per side, so a 1280 px sharp swapchain avoids allocating unused memory.
        if headset == .questPro { sharpLayerPixels = 1280; sharpWhenTransparent = false }
        if headset == .galaxyXR { eyeDetail = 1.9; leanUplink = true; layerFilter = "sharpen_quality"; emptyTopLayer = true
            skipEmptyProjection = true; streamQuads = "room"
        }
        // Match ALVR's workarounds for YVR and Play For Dream (`use_custom_reprojection` and `passthrough_fb.rs`).
        if headset == .yvr || headset == .playForDream {
            compositorPlacesLayers = false
            passthroughLayer = true
            sharpLayerPixels = 0
        }
        // Lepton has only Android's software video decoders. Asked for low latency, its HEVC one refuses to
        // configure, and the media framework then crashes the app while cleaning up after the refusal.
        if headset == .steamFrame { decoderLowLatency = false }
        if [.pico, .vive, .yvr, .playForDream].contains(headset) { headVelocityFromPoses = true }
        if headset == .pico || headset == .vive { controllerVelocityFromPoses = true }
        // Play For Dream's decoder/sampler path applies narrow-range expansion to full-range frames, crushing blacks.
        if headset == .playForDream { undoRangeStretch = true }
    }

    /// Identifies a headset from Android's `Build` fields (`ro.product.manufacturer`, `.model`, `.device`,
    /// and `.name`).
    public static func identify(manufacturer: String, model: String, device: String, product: String) -> Headset {
        switch (manufacturer.lowercased(), device.lowercased()) {
        case ("oculus", "monterey"): return .quest1
        case ("oculus", "hollywood"): return .quest2
        case ("oculus", "eureka"): return .quest3
        case ("oculus", "panther"): return .quest3S
        case ("oculus", "seacliff"): return .questPro
        case ("oculus", _), ("meta", _): return .quest
        case ("pico", _): return .pico
        case ("htc", _): return .vive
        case ("yvr", _): return .yvr
        case ("play for dream", _): return .playForDream
        case ("samsung", "xrvst2"): return .galaxyXR
        case ("valve", _): return .steamFrame
        default: break
        }
        // Match Lynx headsets loosely by manufacturer/model/product until exact Build fields are confirmed.
        if [manufacturer, model, product].contains(where: { $0.lowercased().contains("lynx") }) { return .lynx }
        return .unknown
    }

    /// Overrides settings from a key-value lookup supporting `float_target`, `float_encoded`,
    /// `decoder_low_latency`, `wait_for_gpu`, `sustained_performance`, `lean_uplink`, `compositor_places_layers`,
    /// `passthrough_layer`, `measure_colors`, `decoder_color_keys`, `encoding_gamma`, `shader_color_conversion`, `undo_range_stretch`, `head_velocity_from_poses`, and
    /// `controller_velocity_from_poses` (0 or 1), `color_space` (`rec709`, `p3`, `rec2020`, or `unmanaged`), `video_range` (`narrow`, `full`, or `auto`),
    /// `decoder_width` and `decoder_height`, `decoder_operating_rate` (0 to leave unset), `sharp_layer` (pixels,
    /// 0 for none), `eye_detail` (1 to 4), and `grip_offset`
    /// (six comma-separated floats for the left hand: x, y, z in meters and pitch, yaw, roll in degrees).
    public mutating func apply(_ override: (String) -> String?) {
        func flag(_ name: String) -> Bool? {
            switch override(name) {
            case "1", "true": return true
            case "0", "false": return false
            default: return nil
            }
        }
        if let value = flag("float_target") { floatTarget = value }
        if let value = flag("float_encoded") { floatTargetIsEncoded = value }
        if let value = flag("encoded_target") { encodedTarget = value }
        if let value = flag("decoder_low_latency") { decoderLowLatency = value }
        if let value = flag("wait_for_gpu") { waitForGPU = value }
        if let value = flag("sustained_performance") { sustainedPerformance = value }
        if let value = flag("boost_gpu") { boostGPU = value }
        if let value = flag("lean_uplink") { leanUplink = value }
        if let value = flag("compositor_places_layers") { compositorPlacesLayers = value }
        if let value = flag("passthrough_layer") { passthroughLayer = value }
        if let value = flag("empty_top_layer") { emptyTopLayer = value }
        if let value = flag("shader_color_conversion") { shaderColorConversion = value }
        if let value = flag("undo_range_stretch") { undoRangeStretch = value }
        if let value = flag("measure_colors") { measureColors = value }
        if let value = flag("decoder_color_keys") { decoderColorKeys = value }
        if let value = flag("encoding_gamma") { encodingGamma = value }
        if let value = override("color_space"), HeadsetQuirks.colorSpaces.contains(value) { colorSpace = value }
        if let value = override("layer_filter"), HeadsetQuirks.layerFilters.contains(value) { layerFilter = value }
        if let value = override("blend_test"), HeadsetQuirks.blendTests.contains(value) { blendTest = value }
        if let value = flag("skip_empty_projection") { skipEmptyProjection = value }
        if let value = flag("reuse_frames") { reuseFrames = value }
        if let value = flag("sharp_when_transparent") { sharpWhenTransparent = value }
        if let value = override("stream_quads"), HeadsetQuirks.streamQuadChoices.contains(value) { streamQuads = value }
        if let value = override("quad_distance").flatMap({ Float($0) }), (0.5...100).contains(value) { quadDistance = value }
        if let value = flag("head_velocity_from_poses") { headVelocityFromPoses = value }
        if let value = flag("controller_velocity_from_poses") { controllerVelocityFromPoses = value }
        if let value = override("video_range") {
            if value == "auto" { videoRange = nil } else if let range = VideoRange(rawValue: value) { videoRange = range }
        }
        if let value = override("decoder_width").flatMap({ Int($0) }), (64...8192).contains(value) { decoderWidth = value }
        if let value = override("sharp_layer").flatMap({ Int($0) }), value == 0 || (256...8192).contains(value) { sharpLayerPixels = value }
        if let value = override("eye_detail").flatMap({ Float($0) }), (1...4).contains(value) { eyeDetail = value }
        if let value = override("decoder_operating_rate").flatMap({ Int($0) }), (0...32767).contains(value) { decoderOperatingRate = value }
        if let numbers = override("grip_offset")?.split(separator: ",").map({ Float($0.trimmingCharacters(in: .whitespaces)) }),
           numbers.count == 6, !numbers.contains(nil) {
            let n = numbers.compactMap { $0 }
            gripOffset = GripOffset(x: n[0], y: n[1], z: n[2], pitch: n[3], yaw: n[4], roll: n[5])
        }
        if let value = override("decoder_height").flatMap({ Int($0) }), (64...8192).contains(value) { decoderHeight = value }
    }

    /// Quirk exposed in the in-headset panel's Quirks tab, keyed by the `apply(_:)` / `debug.openvrlink.*` name.
    public struct Option {
        public enum Kind {
            case flag
            case choice([String])
            case number(ClosedRange<Float>, step: Float)
        }
        public var key: String
        public var title: String
        public var kind: Kind
    }

    /// Quirks shown in the panel's Quirks tab (`grip_offset` and initial decoder dimensions remain `setprop`-only).
    public static let options: [Option] = [
        Option(key: "encoding_gamma", title: "Use host encoding gamma", kind: .flag),
        Option(key: "decoder_color_keys", title: "Set full-range BT.2020 color keys on decoder", kind: .flag),
        Option(key: "measure_colors", title: "Probe and correct video colors at startup (overrides the two below)", kind: .flag),
        Option(key: "shader_color_conversion", title: "Convert video colors in shader", kind: .flag),
        Option(key: "undo_range_stretch", title: "Undo narrow-range stretch on video colors", kind: .flag),
        Option(key: "color_space", title: "Display color space", kind: .choice(colorSpaces)),
        Option(key: "layer_filter", title: "Compositor layer filter", kind: .choice(layerFilters)),
        Option(key: "skip_empty_projection", title: "Skip projection layer when not streaming", kind: .flag),
        Option(key: "stream_quads", title: "Submit stream as quad layers", kind: .choice(streamQuadChoices)),
        Option(key: "quad_distance", title: "Quad layer distance (m)", kind: .number(0.5...100, step: 0.5)),
        Option(key: "reuse_frames", title: "Reproject unchanged frames in compositor", kind: .flag),
        Option(key: "sharp_when_transparent", title: "Keep sharp layer during passthrough", kind: .flag),
        Option(key: "blend_test", title: "Blend test (sharpness)", kind: .choice(blendTests)),
        Option(key: "video_range", title: "Video range", kind: .choice(["auto", "narrow", "full"])),
        Option(key: "compositor_places_layers", title: "Use compositor layer placement", kind: .flag),
        Option(key: "sharp_layer", title: "Sharp layer size (0 for none)", kind: .number(0...4096, step: 256)),
        Option(key: "eye_detail", title: "Eye resolution scale for foveating hosts", kind: .number(1...4, step: 0.1)),
        Option(key: "head_velocity_from_poses", title: "Compute head velocity from poses", kind: .flag),
        Option(key: "controller_velocity_from_poses", title: "Compute controller velocity from poses", kind: .flag),
        Option(key: "passthrough_layer", title: "Use passthrough composition layer", kind: .flag),
        Option(key: "empty_top_layer", title: "Add transparent Android Surface overlay", kind: .flag),
        Option(key: "float_target", title: "Render to 16-bit float swapchains", kind: .flag),
        Option(key: "float_encoded", title: "Float swapchains expect sRGB-encoded values", kind: .flag),
        Option(key: "encoded_target", title: "Write sRGB-encoded values directly to sRGB swapchains", kind: .flag),
        Option(key: "wait_for_gpu", title: "Wait for GPU fence before releasing frames", kind: .flag),
        Option(key: "decoder_low_latency", title: "Low-latency decoding", kind: .flag),
        Option(key: "sustained_performance", title: "Request sustained high performance", kind: .flag),
        Option(key: "boost_gpu", title: "Request boost GPU performance level (experimental)", kind: .flag),
        Option(key: "lean_uplink", title: "Reduce uplink packet rate", kind: .flag),
    ]

    /// Formats the current value of `key` in the representation expected by `apply(_:)`.
    public func value(of key: String) -> String? {
        func flag(_ on: Bool) -> String { on ? "1" : "0" }
        switch key {
        case "measure_colors": return flag(measureColors)
        case "decoder_color_keys": return flag(decoderColorKeys)
        case "encoding_gamma": return flag(encodingGamma)
        case "shader_color_conversion": return flag(shaderColorConversion)
        case "undo_range_stretch": return flag(undoRangeStretch)
        case "color_space": return colorSpace
        case "layer_filter": return layerFilter
        case "blend_test": return blendTest
        case "skip_empty_projection": return flag(skipEmptyProjection)
        case "stream_quads": return streamQuads
        case "reuse_frames": return flag(reuseFrames)
        case "sharp_when_transparent": return flag(sharpWhenTransparent)
        case "quad_distance": return String(format: "%.1f", quadDistance)
        case "video_range": return videoRange?.rawValue ?? "auto"
        case "compositor_places_layers": return flag(compositorPlacesLayers)
        case "sharp_layer": return String(sharpLayerPixels)
        case "eye_detail": return String(format: "%.1f", eyeDetail)
        case "head_velocity_from_poses": return flag(headVelocityFromPoses)
        case "controller_velocity_from_poses": return flag(controllerVelocityFromPoses)
        case "passthrough_layer": return flag(passthroughLayer)
        case "empty_top_layer": return flag(emptyTopLayer)
        case "float_target": return flag(floatTarget)
        case "float_encoded": return flag(floatTargetIsEncoded)
        case "encoded_target": return flag(encodedTarget)
        case "wait_for_gpu": return flag(waitForGPU)
        case "decoder_low_latency": return flag(decoderLowLatency)
        case "sustained_performance": return flag(sustainedPerformance)
        case "boost_gpu": return flag(boostGPU)
        case "lean_uplink": return flag(leanUplink)
        default: return nil
        }
    }

    /// Returns a copy of these quirks with saved user overrides (`Settings.quirkOverrides`) applied.
    public func overridden(by overrides: [String: String]) -> HeadsetQuirks {
        var out = self
        out.apply { overrides[$0] }
        return out
    }

    /// Single-line summary of active quirks for startup logging.
    public var summary: String {
        "\(headset.rawValue): float target \(floatTarget ? "on" : "off") (taken as \(floatTargetIsEncoded ? "sRGB-encoded" : "linear")), "
            + "video range \(videoRange?.rawValue ?? "as reported")\(shaderColorConversion ? ", shader color conversion" : "")\(undoRangeStretch ? ", range stretch undone" : ""), decoder starts at \(decoderWidth) x \(decoderHeight), "
            + "low latency \(decoderLowLatency ? "on" : "off"), operating rate \(decoderOperatingRate == 0 ? "unset" : String(decoderOperatingRate))"
            + (waitForGPU ? "" : ", waitForGPU off")
            + ", sustained performance \(sustainedPerformance ? "on" : "off")" + (leanUplink ? ", lean uplink" : "")
            + (headVelocityFromPoses ? ", head velocity from poses" : "") + (controllerVelocityFromPoses ? ", controller velocity from poses" : "")
            + (compositorPlacesLayers ? "" : ", layers drawn for the current view only") + (passthroughLayer ? ", passthrough layer" : "")
            + (emptyTopLayer ? ", surface overlay quad" : "")
            + (sharpLayerPixels == 0 ? ", no sharp layer" : ", sharp layer \(sharpLayerPixels), eye detail \(eyeDetail)")
            + (gripOffset.isNone ? "" : String(format: ", grip offset %.3f,%.3f,%.3f m %.1f,%.1f,%.1f deg", gripOffset.x, gripOffset.y,
                                               gripOffset.z, gripOffset.pitch, gripOffset.yaw, gripOffset.roll))
    }
}
