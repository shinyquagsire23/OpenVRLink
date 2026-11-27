// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bitmask flags for controller render model sets served by `driver_openvrlink` and sent in `oxModels`.
public enum ControllerModels {
    /// Settings key in `driver_openvrlink` storing the bitmask of installed controller model sets.
    public static let settingsKey = "controllerModels"
    public static let playForDream: UInt32 = 1 << 0, galaxyXR: UInt32 = 1 << 1
}

/// Converts glTF controller assets uploaded from a user's headset into SteamVR render models
/// (`GLTFControllerModel`) and installs them under `driver_openvrlink/resources/rendermodels`.
public enum HeadsetModel {
    /// Render model directory names for Samsung Galaxy XR controllers.
    public static let galaxyXR = ["galaxy_xr_controller_left", "galaxy_xr_controller_right"]

    static func isPresent(_ models: [String], inDriver driver: URL) -> Bool {
        models.allSatisfy { Steam.isFile(PlayForDreamModel.folder(inDriver: driver).appendingPathComponent($0).appendingPathComponent("\($0).json")) }
    }

    /// Returns the `ControllerModels` bitmask for all render model sets currently installed in `driver`.
    public static func setsPresent(inDriver driver: URL) -> UInt32 {
        (PlayForDreamModel.isPresent(inDriver: driver) ? ControllerModels.playForDream : 0)
            | (isPresent(galaxyXR, inDriver: driver) ? ControllerModels.galaxyXR : 0)
    }

    /// Converts the left and right Galaxy XR glTF controller models and their adjacent `.bin` and texture files,
    /// writes them into `driver`, and updates `controllerModels` in `default.vrsettings`. Returns the installed
    /// model directories.
    @discardableResult
    public static func installGalaxyXR(left: URL, right: URL, toDriver driver: URL) throws -> [URL] {
        var converted: [(folder: String, files: [(path: String, data: Data)])] = []
        for (source, side, name) in [(left, GLTFControllerModel.Side.left, galaxyXR[0]), (right, .right, galaxyXR[1])] {
            let gltf = try Data(contentsOf: source)
            var files: [String: Data] = [:]
            for file in GLTFControllerModel.references(of: gltf) {
                files[file] = try? Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent(file))
            }
            converted.append((name, try GLTFControllerModel.convert(gltf: gltf, files: files, side: side, name: name, place: GLTFControllerModel.galaxyXRPlace(side))))
        }
        // Convert both sides before writing to disk so a conversion error leaves any existing models intact.
        let manager = FileManager.default
        var written: [URL] = []
        for model in converted {
            let place = PlayForDreamModel.folder(inDriver: driver).appendingPathComponent(model.folder)
            if manager.fileExists(atPath: place.path) { try manager.removeItem(at: place) }
            try manager.createDirectory(at: place, withIntermediateDirectories: true)
            for file in model.files { try file.data.write(to: place.appendingPathComponent(file.path)) }
            written.append(place)
        }
        try noteSets(inDriver: driver)
        return written
    }

    /// Returns the staging directory where `driver_openvrlink` writes uploaded controller model files. Each
    /// model set gets its own subdirectory with a `complete` marker file once all files arrive.
    static func incoming(inDriver driver: URL) -> URL { driver.appendingPathComponent("incoming") }

    /// Converts any completed uploads under `incoming/` into SteamVR render models. Uploaded source files are
    /// kept afterward so future companion updates can re-run conversion. Returns the installed directories,
    /// skipping any set that fails to convert.
    @discardableResult
    public static func convertPending(inDriver driver: URL) -> [URL] {
        let sent = incoming(inDriver: driver).appendingPathComponent("galaxy_xr")
        guard Steam.isFile(sent.appendingPathComponent("complete")) else { return [] }
        func model(_ side: String) -> URL? {
            let folder = sent.appendingPathComponent(side)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.sorted().first { $0.lowercased().hasSuffix(".gltf") }.map { folder.appendingPathComponent($0) }
        }
        guard let left = model("Left"), let right = model("Right") else { return [] }
        return (try? installGalaxyXR(left: left, right: right, toDriver: driver)) ?? []
    }

    /// Updates `controllerModels` in `default.vrsettings` to match the model sets present on disk.
    static func noteSets(inDriver driver: URL) throws {
        let file = driver.appendingPathComponent("resources/settings/default.vrsettings")
        guard let text = try? String(contentsOf: file, encoding: .utf8), var defaults = try? JSON(parsing: text) else { return }
        defaults[Install.section]?[ControllerModels.settingsKey] = .of(Double(setsPresent(inDriver: driver)))
        try defaults.text.write(to: file, atomically: true, encoding: .utf8)
    }
}
