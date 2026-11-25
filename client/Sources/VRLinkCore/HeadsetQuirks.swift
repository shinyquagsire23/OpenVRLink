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
    /// Frames per second the decoder is told to be ready for (`operating-rate`), or 0 to leave it unset.
    /// Qualcomm decoders clock themselves from this and otherwise assume 30; the default is the "as fast as
    /// possible" value ALVR uses.
    public var decoderOperatingRate = 32767

    public init(_ headset: Headset = .unknown) {
        self.headset = headset
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

    /// Overrides settings from a key-value lookup supporting `float_target`, `float_encoded`, and
    /// `decoder_low_latency` (0 or 1), `video_range` (`narrow`, `full`, or `auto`), `decoder_width` and
    /// `decoder_height`, and `decoder_operating_rate` (0 to leave unset).
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
        if let value = override("video_range") {
            if value == "auto" { videoRange = nil } else if let range = VideoRange(rawValue: value) { videoRange = range }
        }
        if let value = override("decoder_width").flatMap({ Int($0) }), (64...8192).contains(value) { decoderWidth = value }
        if let value = override("decoder_operating_rate").flatMap({ Int($0) }), (0...32767).contains(value) { decoderOperatingRate = value }
        if let value = override("decoder_height").flatMap({ Int($0) }), (64...8192).contains(value) { decoderHeight = value }
    }

    /// Single-line summary of active quirks for startup logging.
    public var summary: String {
        "\(headset.rawValue): float target \(floatTarget ? "on" : "off") (taken as \(floatTargetIsEncoded ? "sRGB-encoded" : "linear")), "
            + "video range \(videoRange?.rawValue ?? "as reported"), decoder starts at \(decoderWidth) x \(decoderHeight), "
            + "low latency \(decoderLowLatency ? "on" : "off"), operating rate \(decoderOperatingRate == 0 ? "unset" : String(decoderOperatingRate))"
    }
}
