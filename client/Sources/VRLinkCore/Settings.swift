// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Persistent user settings stored in `settings.json` inside `DataDirectory`.
/// All platforms share the same file format and ignore settings that do not
/// apply to them.
public struct Settings: Codable, Equatable {
    /// Composite the user's real hands over the streamed view on headsets that
    /// support hand segmentation (such as visionOS upper-limb visibility).
    public var showHandsOverlaid = true
    /// Hide persistent system UI overlays (such as the visionOS palm-up menu
    /// indicator) during an active stream.
    public var hideSystemOverlays = true
    /// Tap the two controllers together twice in front of the headset to
    /// toggle between controller input and hand tracking.
    public var clackSwitchesToHands = false
    /// Aim hand-tracking rays toward the user's eye gaze direction when a
    /// pinch begins, rather than projecting from the shoulder through the hand.
    public var gazePinchRays = false
    /// Send the microphone to the host.
    public var microphone = false
    /// Experimental: advertise PlayStation VR2 Sense controller render models
    /// to SteamVR (`DeviceProfile.senseControllerModels`); requires the PS VR2
    /// driver on the host.
    public var senseControllerModels = false
    /// Dismiss the 2D launcher window when entering an immersive stream.
    /// Reopening the app brings the window back.
    public var closeWindowOnEntry = true

    /// Whether color chroma keying is enabled or disabled
    public var chromaKey = false
    /// Chroma keyed color (RGB, 0~1)
    public var chromaKeyColor: [Float] = [16.0 / 255, 124.0 / 255, 16.0 / 255] // chroma-key green
    /// Color-distance thresholds for chroma keying: pixels closer than
    /// `chromaKeyNear` become fully transparent, pixels beyond `chromaKeyFar`
    /// stay opaque, and values in between smoothly interpolate alpha.
    public var chromaKeyNear: Float = 0.35
    public var chromaKeyFar: Float = 0.7
    /// Disable chroma keying while a scene application is running on the host
    /// so passthrough only applies in SteamVR's empty grid. Because the host
    /// only reports a boolean running state, this cannot be configured per game.
    public var chromaKeyOffInGames = false

    /// Horizontal and vertical multipliers applied to the display's field of
    /// view when configuring a new session. Values above 1 add over-render
    /// margin for fast head rotation; values below 1 concentrate the encoded
    /// resolution into a narrower, sharper view.
    public var fovScaleHorizontal: Float = 1
    public var fovScaleVertical: Float = 1

    /// Experimental: estimate facial expressions (and eye gaze when calibrated)
    /// from a face camera feed, such as the Spatial Persona avatar camera on visionOS.
    public var faceFromCamera = false
    /// Saved mapping from pupil landmarks to gaze direction produced by user
    /// gaze calibration.
    public var gazeCalibration: GazeCalibration?
    /// Continuously refine `gazeCalibration` during streaming using the known
    /// gaze target at each pinch (`GazeCalibration.tuned`).
    public var continuousGazeCalibration = false
    /// Per-expression baseline and range captured during user face calibration;
    /// when nil, fixed heuristic ranges are used.
    public var faceCalibration: FaceCalibration?
    /// Show a debug preview of the face camera feed and detected landmarks in
    /// the corner of the view on supported platforms.
    public var showFaceCameraPicture = false
    /// Experimental (visionOS): render the stream in a RealityKit space instead
    /// of a Metal compositor layer. This adds latency and disables hardware
    /// foveation, but is required to keep the Spatial Persona camera active
    /// (docs/client-architecture.md, "Experiments").
    public var realityKitRenderer = false
    /// Experimental (visionOS): estimate scene depth from stereo disparity
    /// between the left and right eye images and warp the video quads to match
    /// (`DepthField`) instead of projecting onto a flat plane at 10 m. This
    /// reduces swim on nearby surfaces like the floor when head-pose prediction overshoots.
    public var depthFromPicture = true
    /// Overlay a translucent color-coded depth grid (red near, blue far) to visualize `depthFromPicture`.
    public var showDepth = false

    /// Step the display refresh rate down during thermal throttling and restore it once the headset cools.
    /// This is off by default because changing refresh rates causes a brief hitch and resets the host's video encoder.
    public var lowerRateWhenHot = false

    /// Per-option `HeadsetQuirks` overrides keyed by `HeadsetQuirks.options` key, formatted for
    /// `HeadsetQuirks.apply`. Omitted keys use the headset's defaults; changes take effect on next app launch.
    public var quirkOverrides: [String: String] = [:]

    public static let fovScaleRange: ClosedRange<Float> = 0.2...1.6

    public init() {}

    /// Decodes each known setting individually so missing or newly added keys
    /// fall back to their default values.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let found = try? saved.decodeIfPresent(T.self, forKey: key) { value = found }
        }
        read(.showHandsOverlaid, into: &showHandsOverlaid)
        read(.hideSystemOverlays, into: &hideSystemOverlays)
        read(.clackSwitchesToHands, into: &clackSwitchesToHands)
        read(.gazePinchRays, into: &gazePinchRays)
        read(.microphone, into: &microphone)
        read(.senseControllerModels, into: &senseControllerModels)
        read(.chromaKey, into: &chromaKey)
        read(.chromaKeyColor, into: &chromaKeyColor)
        read(.chromaKeyNear, into: &chromaKeyNear)
        read(.chromaKeyFar, into: &chromaKeyFar)
        read(.chromaKeyOffInGames, into: &chromaKeyOffInGames)
        read(.fovScaleHorizontal, into: &fovScaleHorizontal)
        read(.fovScaleVertical, into: &fovScaleVertical)
        read(.faceFromCamera, into: &faceFromCamera)
        read(.showFaceCameraPicture, into: &showFaceCameraPicture)
        read(.continuousGazeCalibration, into: &continuousGazeCalibration)
        if let found = try? saved.decodeIfPresent(FaceCalibration.self, forKey: .faceCalibration) { faceCalibration = found }
        read(.closeWindowOnEntry, into: &closeWindowOnEntry)
        read(.realityKitRenderer, into: &realityKitRenderer)
        read(.depthFromPicture, into: &depthFromPicture)
        read(.showDepth, into: &showDepth)
        read(.lowerRateWhenHot, into: &lowerRateWhenHot)
        read(.quirkOverrides, into: &quirkOverrides)
        if let found = try? saved.decodeIfPresent(GazeCalibration.self, forKey: .gazeCalibration) { gazeCalibration = found }
        self = tidied()
    }

    /// Returns a copy with all standard settings reset to their defaults while keeping eye and face calibrations
    /// and per-headset quirk overrides.
    public func resetToDefaults() -> Settings {
        var fresh = Settings()
        fresh.gazeCalibration = gazeCalibration
        fresh.faceCalibration = faceCalibration
        fresh.quirkOverrides = quirkOverrides
        return fresh
    }

    /// Whether any setting affected by `resetToDefaults()` differs from its default value.
    public var differsFromDefaults: Bool { self != resetToDefaults() }

    /// Returns a copy with all numeric settings clamped to valid ranges.
    public func tidied() -> Settings {
        var out = self
        if out.chromaKeyColor.count != 3 { out.chromaKeyColor = Settings().chromaKeyColor }
        out.chromaKeyColor = out.chromaKeyColor.map { max(0, min(1, $0)) }
        out.chromaKeyFar = max(0.001, min(1, out.chromaKeyFar))
        out.chromaKeyNear = max(0, min(out.chromaKeyFar - 0.001, out.chromaKeyNear))
        out.fovScaleHorizontal = max(Settings.fovScaleRange.lowerBound, min(Settings.fovScaleRange.upperBound, out.fovScaleHorizontal))
        out.fovScaleVertical = max(Settings.fovScaleRange.lowerBound, min(Settings.fovScaleRange.upperBound, out.fovScaleVertical))
        return out
    }

    /// Returns the active `ChromaKey` parameters for the renderer, or nil when
    /// chroma keying is disabled (including when suppressed by
    /// `chromaKeyOffInGames` while `inGame` is true).
    public func chromaKeying(inGame: Bool) -> ChromaKey? {
        guard chromaKey, !(chromaKeyOffInGames && inGame) else { return nil }
        return ChromaKey(color: chromaKeyColor, near: chromaKeyNear, far: chromaKeyFar)
    }

    public static var file: URL { DataDirectory.url.appendingPathComponent("settings.json") }

    /// Loads settings from disk, falling back to defaults if the file is missing or unreadable.
    public static func load(from file: URL = Settings.file) -> Settings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    public func save(to file: URL = Settings.file) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self).write(to: file, options: .atomic)
        } catch {
            Log.note("settings: could not be saved: \(error)")
        }
    }
}

/// Chroma-key color and distance thresholds passed to the renderer.
public struct ChromaKey: Equatable {
    /// Red, green, blue, 0 ... 1, sRGB-encoded.
    public var color: [Float]
    /// Distances from the color (see `Settings.chromaKeyNear`).
    public var near, far: Float

    public init(color: [Float], near: Float, far: Float) {
        self.color = color
        self.near = near
        self.far = far
    }

    /// `color` converted from sRGB to linear light.
    public var linearColor: [Float] {
        color.map { $0 <= 0.04045 ? $0 / 12.92 : Float(pow(Double(($0 + 0.055) / 1.055), 2.4)) }
    }
}
