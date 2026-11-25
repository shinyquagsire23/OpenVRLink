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
    /// Overrides the YCbCr range for decoders that misreport it, or `nil` to use the decoder's reported range.
    public var videoRange: VideoRange?
    /// Fallback initial resolution passed to `AMediaCodec_configure` when dimensions cannot be parsed from
    /// parameter sets beforehand. Some hardware decoders fail to start if the initial size differs too much from
    /// the stream.
    public var decoderWidth = 2048, decoderHeight = 2048
    /// Enables low-latency decoding flags (Android 11 `low-latency` and Qualcomm's vendor extension).
    public var decoderLowLatency = true
    /// Wait on the frame's GPU fence before releasing swapchain images to the OpenXR runtime. OpenXR does not
    /// specify whether `xrReleaseSwapchainImage` synchronizes with pending GPU work, so out-of-process
    /// compositors could otherwise display an unfinished or stale swapchain image.
    public var waitForGPU = true
    /// Target frame rate passed to the decoder (`operating-rate`), or 0 to leave it unset. Qualcomm decoders
    /// scale clocks from this hint and default to 30 fps without it; 32767 matches ALVR's maximum-rate setting.
    public var decoderOperatingRate = 32767

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
            case .lynx, .yvr, .playForDream, .unknown: return GripOffset()
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
        default: break
        }
        // Match Lynx headsets loosely by manufacturer/model/product until exact Build fields are confirmed.
        if [manufacturer, model, product].contains(where: { $0.lowercased().contains("lynx") }) { return .lynx }
        return .unknown
    }

    /// Overrides settings from a key-value lookup supporting `float_target`, `float_encoded`,
    /// `decoder_low_latency`, and `wait_for_gpu` (0 or 1), `video_range` (`narrow`, `full`, or `auto`),
    /// `decoder_width` and `decoder_height`, `decoder_operating_rate` (0 to leave unset), and `grip_offset`
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
        if let value = flag("decoder_low_latency") { decoderLowLatency = value }
        if let value = flag("wait_for_gpu") { waitForGPU = value }
        if let value = override("video_range") {
            if value == "auto" { videoRange = nil } else if let range = VideoRange(rawValue: value) { videoRange = range }
        }
        if let value = override("decoder_width").flatMap({ Int($0) }), (64...8192).contains(value) { decoderWidth = value }
        if let value = override("decoder_operating_rate").flatMap({ Int($0) }), (0...32767).contains(value) { decoderOperatingRate = value }
        if let numbers = override("grip_offset")?.split(separator: ",").map({ Float($0.trimmingCharacters(in: .whitespaces)) }),
           numbers.count == 6, !numbers.contains(nil) {
            let n = numbers.compactMap { $0 }
            gripOffset = GripOffset(x: n[0], y: n[1], z: n[2], pitch: n[3], yaw: n[4], roll: n[5])
        }
        if let value = override("decoder_height").flatMap({ Int($0) }), (64...8192).contains(value) { decoderHeight = value }
    }

    /// Single-line summary of active quirks for startup logging.
    public var summary: String {
        "\(headset.rawValue): float target \(floatTarget ? "on" : "off") (taken as \(floatTargetIsEncoded ? "sRGB-encoded" : "linear")), "
            + "video range \(videoRange?.rawValue ?? "as reported"), decoder starts at \(decoderWidth) x \(decoderHeight), "
            + "low latency \(decoderLowLatency ? "on" : "off"), operating rate \(decoderOperatingRate == 0 ? "unset" : String(decoderOperatingRate))"
            + (waitForGPU ? "" : ", waitForGPU off")
            + (gripOffset.isNone ? "" : String(format: ", grip offset %.3f,%.3f,%.3f m %.1f,%.1f,%.1f deg", gripOffset.x, gripOffset.y,
                                               gripOffset.z, gripOffset.pitch, gripOffset.yaw, gripOffset.roll))
    }
}
