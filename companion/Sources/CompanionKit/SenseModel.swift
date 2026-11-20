// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Builds the `openvrlink_sense` resource-only SteamVR driver by copying PlayStation VR2
/// Sense controller render models and remapping their input bindings for OpenVRLink.
///
/// `driver_vrlink` only accepts controller types it recognizes, so OpenVRLink registers
/// Sense controllers as Oculus Touch controllers with Touch input paths (`/input/trigger`,
/// `/input/a`, etc.). Stock Sense render models bind their animations to PS VR2 input
/// paths (`/input/r2`, `/input/cross`, etc.), which would prevent triggers, buttons, and
/// thumbsticks from animating. `SenseModel` copies the models from an existing installation
/// and rewrites the input names in the copied JSON without modifying the source files.
public enum SenseModel {
    public static let driverName = "openvrlink_sense"
    public static let models = ["playstation_vr2_sense_left", "playstation_vr2_sense_right"]

    /// Maps PS VR2 input paths to the corresponding Oculus Touch input paths.
    /// Finger-proximity sensors and the right-hand Options button have no Touch
    /// equivalents and keep their original names. The PS button is also left unmapped
    /// because visionOS reserves it for the system, and mapping it to `/input/system/click`
    /// alongside Create would animate both buttons whenever Create is pressed.
    static let renames: KeyValuePairs<String, String> = [
        "/input/r2": "/input/trigger", "/input/l2": "/input/trigger",
        "/input/r1": "/input/grip", "/input/l1": "/input/grip",
        "/input/right_stick": "/input/joystick", "/input/left_stick": "/input/joystick",
        "/input/cross/click": "/input/a/click", "/input/circle/click": "/input/b/click",
        "/input/square/click": "/input/x/click", "/input/triangle/click": "/input/y/click",
        "/input/create/click": "/input/system/click",
    ]

    static let manifest = "{\n\t\"alwaysActivate\": false,\n\t\"name\" : \"openvrlink_sense\",\n\t\"directory\" : \"\",\n\t\"resourceOnly\" : true,\n\t\"hmd_presence\" : []\n}\n"

    public struct NoModels: Error, CustomStringConvertible {
        let folder: URL
        public var description: String { "\(folder.path) does not hold the Sense controller models" }
    }

    /// Rewrites the input names in a model's JSON. Names are matched with their quotes,
    /// so `/input/r2` does not also match inside `/input/r2_sensor`. Returns the text and
    /// how many kinds of input were renamed.
    public static func renamingInputs(in modelJSON: String) -> (text: String, kinds: Int) {
        var text = modelJSON, kinds = 0
        for (from, to) in renames where text.contains("\"\(from)\"") {
            text = text.replacing("\"\(from)\"", with: "\"\(to)\"")
            kinds += 1
        }
        return (text, kinds)
    }

    static func holdsModels(_ renderModels: URL) -> Bool {
        models.allSatisfy { Steam.isFile(renderModels.appendingPathComponent($0).appendingPathComponent("\($0).json")) }
    }

    /// Accepts a `rendermodels` folder, a driver's `resources` folder, or a driver's own
    /// folder, and returns the `rendermodels` folder with both models.
    public static func locate(in folder: URL) -> URL? {
        [folder, folder.appendingPathComponent("rendermodels"), folder.appendingPathComponent("resources/rendermodels")].first(where: holdsModels)
    }

    /// Most folders looked at below one Steam app while searching for the models.
    static let mostFolders = 4000

    private static func search(_ folder: URL, depth: Int, budget: inout Int) -> URL? {
        if let found = locate(in: folder) { return found }
        guard depth > 0, let entries = try? OS.entries(in: folder) else { return nil }
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard budget > 0 else { return nil }
            budget -= 1
            if Steam.isFolder(entry), entry.lastPathComponent != driverName, let found = search(entry, depth: depth - 1, budget: &budget) {
                return found
            }
        }
        return nil
    }

    private static func apps(in library: URL, sonys: Bool) -> [URL] {
        let common = library.appendingPathComponent("steamapps/common")
        let entries = (try? OS.entries(in: common)) ?? []
        return entries.filter { $0.lastPathComponent.lowercased().contains("playstation") == sonys }.sorted { $0.path < $1.path }
    }

    /// Searches for an installed copy of the Sense controller models. Prefers Sony's
    /// PlayStation VR2 App because it ships complete render models, followed by
    /// registered external drivers, SteamVR's `playstation_vr2` driver directory (where
    /// ALVR places sparse models), and finally any other installed Steam app.
    public static func findSource(_ found: Steam.Found) -> URL? {
        for library in found.libraries {
            for app in apps(in: library, sonys: true) {
                var budget = mostFolders
                if let models = search(app, depth: 4, budget: &budget) { return models }
            }
        }
        for driver in found.externalDrivers where driver.lastPathComponent != driverName {
            if let models = locate(in: driver) { return models }
        }
        if let steamVR = found.steamVR {
            for folder in [steamVR.appendingPathComponent("drivers/playstation_vr2"), steamVR.appendingPathComponent("resources")] {
                if let models = locate(in: folder) { return models }
            }
        }
        for library in found.libraries {
            // SteamVR itself was looked at above, and its drivers folder may hold our own output.
            for app in apps(in: library, sonys: false) where !(found.steamVR.map { Steam.samePlace($0, app) } ?? false) {
                var budget = mostFolders
                if let models = search(app, depth: 4, budget: &budget) { return models }
            }
        }
        return nil
    }

    /// Writes the resource driver to `driver` (replacing an earlier one) from the models
    /// in `renderModels`. Returns, per model, how many kinds of input were renamed.
    @discardableResult
    public static func build(from renderModels: URL, to driver: URL) throws -> [(model: String, kinds: Int)] {
        guard holdsModels(renderModels) else { throw NoModels(folder: renderModels) }
        let files = FileManager.default
        if files.fileExists(atPath: driver.path) { try files.removeItem(at: driver) }
        let target = driver.appendingPathComponent("resources/rendermodels")
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        try manifest.write(to: driver.appendingPathComponent("driver.vrdrivermanifest"), atomically: true, encoding: .utf8)
        var report: [(model: String, kinds: Int)] = []
        for model in models {
            try files.copyItem(at: renderModels.appendingPathComponent(model), to: target.appendingPathComponent(model))
            let file = target.appendingPathComponent(model).appendingPathComponent("\(model).json")
            let renamed = renamingInputs(in: try String(contentsOf: file, encoding: .utf8))
            try renamed.text.write(to: file, atomically: true, encoding: .utf8)
            report.append((model, renamed.kinds))
        }
        return report
    }
}
