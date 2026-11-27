// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import ControllerModels

/// Play For Dream MR controller render models bundled in `openvrlink-companion` (redistributed with Play For
/// Dream's permission) and installed into `driver_openvrlink/resources/rendermodels` as
/// `{openvrlink}pfd_mr_controller_left` and `{openvrlink}pfd_mr_controller_right`.
///
/// Extracted from the `vrlink_pfd_mr` resource driver in Play For Dream's "MR SteamLink Driver" 1.0.1.0
/// installer. (The `yvr_d1_*` models placed in `SteamVR/drivers/pfd` by older Play For Dream software belong to
/// an earlier YVR headset.) Because the component JSON files already animate from Oculus Touch input paths
/// (`/input/trigger`, `/input/joystick`, `/input/a/click`, ...), they require no input remapping.
public enum PlayForDreamModel {
    public static let models = ["pfd_mr_controller_left", "pfd_mr_controller_right"]
    /// Legacy YVR D1 controller model directories cleaned up during installation.
    static let retired = ["yvr_d1_left_controller", "yvr_d1_right_controller"]

    /// Returns all bundled model files with their paths relative to `resources/rendermodels`.
    public static var files: [(path: String, data: Data)] {
        (0..<Int(ovrl_pfd_model_file_count())).compactMap { index in
            guard let file = ovrl_pfd_model_file(Int32(index)) else { return nil }
            return (String(cString: file.pointee.path), Data(bytes: file.pointee.bytes, count: Int(file.pointee.size)))
        }
    }

    static func folder(inDriver driver: URL) -> URL { driver.appendingPathComponent("resources/rendermodels") }

    /// Returns true if `driver` contains every bundled model file with the expected byte size.
    public static func isPresent(inDriver driver: URL) -> Bool {
        let folder = folder(inDriver: driver)
        return (0..<Int(ovrl_pfd_model_file_count())).allSatisfy { index in
            guard let file = ovrl_pfd_model_file(Int32(index)) else { return false }
            let place = folder.appendingPathComponent(String(cString: file.pointee.path))
            // Memory-map the file to check its byte length without reading its contents into heap memory
            // (FileManager file-size attribute types differ across platforms and FoundationEssentials).
            let length = (try? Data(contentsOf: place, options: .alwaysMapped))?.count
            return length.map { UInt64($0) } == file.pointee.size
        }
    }

    /// Writes the controller render models into `driver`, replacing any existing copies.
    public static func write(toDriver driver: URL) throws {
        let files = FileManager.default, folder = folder(inDriver: driver)
        for model in models + retired {
            let place = folder.appendingPathComponent(model)
            if files.fileExists(atPath: place.path) { try files.removeItem(at: place) }
            if models.contains(model) { try files.createDirectory(at: place, withIntermediateDirectories: true) }
        }
        for file in self.files { try file.data.write(to: folder.appendingPathComponent(file.path)) }
    }
}
