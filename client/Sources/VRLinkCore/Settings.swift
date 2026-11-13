// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Persistent user settings, kept between runs as `settings.json` in the
/// data folder (`DataDirectory`).
/// Every client reads the same file, clients ignore settings its platform has no use for.
public struct Settings: Codable, Equatable {
    /// Draw the wearer's real hands over the picture (a headset that can cut
    /// them out of its cameras' view).
    public var showHandsOverlaid = true
    /// Keep the system's own always-there controls (on visionOS, the menu
    /// that appears when looking at a raised palm) away while streaming.
    public var hideSystemOverlays = true
    /// Knocking the two controllers together twice, in front of the face,
    /// switches between controllers and bare hands.
    public var clackSwitchesToHands = false
    /// A bare hand points where the eyes look at the moment it pinches,
    /// instead of along the line from the shoulder through the hand.
    public var gazePinchRays = false
    /// Send the microphone to the host.
    public var microphone = false
    /// Experiment: have SteamVR draw PlayStation VR2 Sense controllers
    /// (`DeviceProfile.senseControllerModels`), which needs their model on the host.
    public var senseControllerModels = false
    /// Put the app's window away when streaming starts. (It comes back
    /// when the app is opened again.)
    public var closeWindowOnEntry = true

    /// Whether color chroma keying is enabled or disabled
    public var chromaKey = false
    /// Chroma keyed color (RGB, 0~1)
    public var chromaKeyColor: [Float] = [16.0 / 255, 124.0 / 255, 16.0 / 255] // chroma-key green
    /// How far from the color a pixel may be: nearer than `chromaKeyNear` it is all transparent, 
    /// further than `chromaKeyFar` all opaque, in-between the alpha is interpolated.
    public var chromaKeyNear: Float = 0.35
    public var chromaKeyFar: Float = 0.7
    /// Leave the chroma key off while an application is running on the host,
    /// so that it only applies in SteamVR's own grid. (The host says that
    /// one is running, not which: this cannot be chosen per game.)
    public var chromaKeyOffInGames = false

    /// How much of the display's field of view the host is asked to render,
    /// across and up-down: above 1 leaves a margin for fast head turns,
    /// below 1 spends the same pixels on a smaller, sharper picture. Read
    /// when a session starts.
    public var fovScaleHorizontal: Float = 1
    public var fovScaleVertical: Float = 1

    /// Experiment: face expressions, and with a calibration the gaze, read
    /// off a camera picture of the wearer's face (on visionOS, the Spatial
    /// Persona).
    public var faceFromCamera = false
    /// The fit from pupil positions to gaze direction, once the wearer has
    /// run the calibration.
    public var gazeCalibration: GazeCalibration?
    /// With that calibration: keep fitting it while streaming, from where
    /// the eyes are known to look at each pinch (`GazeCalibration.tuned`).
    public var continuousGazeCalibration = false
    /// The wearer's own range for each expression, once they have run the
    /// face calibration; without it fixed rules of thumb are used.
    public var faceCalibration: FaceCalibration?
    /// With that experiment: show the camera's picture, with the landmarks
    /// found in it, in a corner of the view (where the platform can).
    public var showFaceCameraPicture = false
    /// Experiment, visionOS: show the stream with RealityKit instead of a
    /// compositor layer. Slower, and without the display's own foveation,
    /// but it is the only way to keep the Persona's camera in front of the
    /// face (docs/client-architecture.md, "Experiments").
    public var realityKitRenderer = false

    public static let fovScaleRange: ClosedRange<Float> = 0.2...1.6

    public init() {}

    /// A file written by an older or newer build may lack or add settings:
    /// each one is read if it is there and otherwise keeps its default.
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
        if let found = try? saved.decodeIfPresent(GazeCalibration.self, forKey: .gazeCalibration) { gazeCalibration = found }
        self = tidied()
    }

    /// The same settings with every number inside what the client can use.
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

    /// The chroma key as a renderer wants it right now, or nil when it is
    /// off. `inGame`: whether the host says an application is running
    /// (`StreamSession.sceneApplicationRunning`).
    public func chromaKeying(inGame: Bool) -> ChromaKey? {
        guard chromaKey, !(chromaKeyOffInGames && inGame) else { return nil }
        return ChromaKey(color: chromaKeyColor, near: chromaKeyNear, far: chromaKeyFar)
    }

    public static var file: URL { DataDirectory.url.appendingPathComponent("settings.json") }

    /// The saved settings, or the defaults when there are none that can be read.
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

/// One color of the picture to see through, for a graphics backend.
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

    /// The color in linear light.
    public var linearColor: [Float] {
        color.map { $0 <= 0.04045 ? $0 / 12.92 : Float(pow(Double(($0 + 0.055) / 1.055), 2.4)) }
    }
}
