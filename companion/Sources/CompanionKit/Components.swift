// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Host components managed by `openvrlink-companion`. Each component can be installed,
/// updated, and uninstalled independently.
public enum Component: String, CaseIterable {
    /// Adapted PlayStation VR2 Sense controller render models (`openvrlink_sense`).
    case models
    /// SteamVR driver that applies OpenVRLink extensions to `driver_vrlink` (`driver_openvrlink`).
    case driver

    public var title: String {
        switch self {
        case .models: return "Sense controller models"
        case .driver: return "VR Link extensions driver"
        }
    }

    var driverName: String {
        switch self {
        case .models: return SenseModel.driverName
        case .driver: return Install.driverName
        }
    }
}

public struct ComponentState: Equatable {
    public enum Kind: Equatable {
        /// Not installed, and no valid source or binary is available to install.
        case unavailable
        case notInstalled
        case installed
        /// Installed, with a newer build, better model source, or missing schema entry to apply.
        case updateAvailable
    }

    public var kind: Kind
    /// Human-readable status summary shown in the CLI and GUI.
    public var detail: String

    public var isInstalled: Bool { kind == .installed || kind == .updateAvailable }
    /// Button/action label (`"Install"` or `"Update"`), or `nil` when no action is available.
    public var action: String? {
        switch kind {
        case .notInstalled: return "Install"
        case .updateAvailable: return "Update"
        case .installed, .unavailable: return nil
        }
    }
}

/// Detected host paths and bundled driver assets used by both the CLI and GUI to inspect,
/// install, and uninstall components.
public struct Setup {
    public var places: Steam.Places
    public var found: Steam.Found
    /// True when targeting Windows path layouts and `.dll` naming.
    public var windows: Bool
    /// Bundled `driver_openvrlink` binary bytes, if available.
    public var driverLibrary: Data?
    /// Companion runtime libraries to copy alongside `driver_openvrlink` (used for dynamic stdlib builds).
    public var besideDriver: [URL] = []
    /// Explicit directory to load Sense controller models from instead of auto-discovering them.
    public var modelsFolder: URL?
    /// Whether to place settings in a dedicated OpenVRLink tab (`true` or `nil`, the default)
    /// or in SteamVR's VR Link tab (`false`). SteamVR 2.19.4+ uses a built-in settings page for
    /// `driver_vrlink` that ignores custom schema entries, so only older builds display them there.
    public var ownTab: Bool?

    public init(places: Steam.Places, found: Steam.Found, windows: Bool, driverLibrary: Data? = nil) {
        self.places = places
        self.found = found
        self.windows = windows
        self.driverLibrary = driverLibrary
    }

    public static let notFoundSteamVR = "SteamVR was not found on this PC."

    public func folder(of component: Component) -> URL { places.drivers.appendingPathComponent(component.driverName) }

    private func isRegistered(_ component: Component) -> Bool {
        let folder = folder(of: component)
        return found.externalDrivers.contains { Steam.samePlace($0, folder) }
    }

    // Sense models

    /// Incremented whenever the Sense model remapping changes so existing installations show an available update.
    static let modelRecipe = 1
    static let modelMarker = "openvrlink-companion.json"

    private var modelSource: URL? {
        if let modelsFolder { return SenseModel.locate(in: modelsFolder) }
        return SenseModel.findSource(found)
    }

    private func installedModelSource() -> (source: String?, recipe: Int)? {
        let marker = folder(of: .models).appendingPathComponent(Setup.modelMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8), let json = try? JSON(parsing: text) else { return nil }
        return (json["source"]?.string, json["recipe"]?.number.flatMap { Int($0) } ?? 0)
    }

    /// Returns a display name for a Sense model source directory.
    private func name(ofSource source: URL) -> String {
        source.path.lowercased().contains("playstation vr2 app") ? "Sony's PlayStation VR2 App" : Steam.nativePath(source)
    }

    private func modelsState() -> ComponentState {
        let folder = folder(of: .models)
        let present = SenseModel.locate(in: folder) != nil
        let source = modelSource
        guard present else {
            guard found.steamVR != nil else { return ComponentState(kind: .unavailable, detail: Setup.notFoundSteamVR) }
            guard let source else {
                return ComponentState(kind: .unavailable, detail: "No Sense controller models found. Install Sony's PlayStation VR2 App from Steam and try again.")
            }
            return ComponentState(kind: .notInstalled, detail: "Not installed. Models will be copied from \(name(ofSource: source)).")
        }
        guard isRegistered(.models) else { return ComponentState(kind: .updateAvailable, detail: "Files are present, but the driver is not registered with SteamVR.") }
        guard let source else { return ComponentState(kind: .installed, detail: "Installed.") }
        guard let installed = installedModelSource() else {
            return ComponentState(kind: .updateAvailable, detail: "Installed by an older version. Update to rebuild models from \(name(ofSource: source)).")
        }
        if installed.recipe != Setup.modelRecipe { return ComponentState(kind: .updateAvailable, detail: "Installed; an update is available with updated input mappings.") }
        if installed.source.map({ !Steam.samePlace(URL(fileURLWithPath: $0), source) }) ?? true {
            return ComponentState(kind: .updateAvailable, detail: "Installed; a better model source is available from \(name(ofSource: source)).")
        }
        return ComponentState(kind: .installed, detail: "Installed from \(name(ofSource: source)).")
    }

    private func installModels() throws -> [String] {
        guard let source = modelSource else {
            throw Failure(modelsFolder.map { "\($0.path) does not contain the Sense controller models" }
                ?? "no installed Sense controller models found; install Sony's PlayStation VR2 App from Steam, or pass --models DIR with playstation_vr2_sense_left and playstation_vr2_sense_right")
        }
        let driver = folder(of: .models)
        var lines = try SenseModel.build(from: source, to: driver).map { "\($0.model): \($0.kinds) kinds of input renamed" }
        let marker = JSON.object(["source": .string(Steam.nativePath(source)), "recipe": .number("\(Setup.modelRecipe)")])
        try marker.text.write(to: driver.appendingPathComponent(Setup.modelMarker), atomically: true, encoding: .utf8)
        try Steam.setExternalDriver(driver, present: true, in: places)
        // Remove any legacy `openvrlink_sense` folder left in `SteamVR/drivers` by `tools/install-sense-model.ps1`.
        if let old = found.steamVR?.appendingPathComponent("drivers").appendingPathComponent(SenseModel.driverName),
           Steam.isFile(old.appendingPathComponent("driver.vrdrivermanifest")) {
            do {
                try FileManager.default.removeItem(at: old)
                lines.append("Removed legacy driver copy at \(old.path)")
            } catch {
                lines.append("Could not remove legacy driver copy at \(old.path): \(OS.describe(error))")
            }
        }
        return lines + ["Sense controller models from \(Steam.nativePath(source))", "  installed to \(Steam.nativePath(driver))"]
    }

    // Extensions driver

    /// Path to SteamVR's installed `driver_vrlink` binary, if present.
    public var vrlinkLibrary: URL? {
        let name = windows ? "driver_vrlink.dll" : "driver_vrlink.so"
        let file = found.vrlink?.appendingPathComponent("bin").appendingPathComponent(Install.libraryPlace(windows: windows).platform).appendingPathComponent(name)
        return file.flatMap { Steam.isFile($0) ? $0 : nil }
    }

    private func patchSummary() -> String? {
        guard let file = vrlinkLibrary, let bytes = try? Data(contentsOf: file) else { return nil }
        return Install.patchReport(vrlinkLibrary: [UInt8](bytes))?.summary
    }

    /// True if the installed driver uses a standalone OpenVRLink settings schema.
    private var installedOwnTab: Bool { Steam.isFile(Install.ownTabSchema(inDriver: folder(of: .driver))) }

    private func driverState() -> ComponentState {
        let folder = folder(of: .driver)
        let library = Install.libraryFile(inDriver: folder, windows: windows)
        let compatibility = patchSummary().map { " " + $0 } ?? ""
        guard Steam.isFile(library) else {
            guard found.steamVR != nil else { return ComponentState(kind: .unavailable, detail: Setup.notFoundSteamVR) }
            guard driverLibrary != nil else {
                return ComponentState(kind: .unavailable, detail: "\(Install.libraryPlace(windows: windows).name) was not found alongside openvrlink-companion.")
            }
            return ComponentState(kind: .notInstalled, detail: "Not installed." + compatibility)
        }
        guard isRegistered(.driver) else { return ComponentState(kind: .updateAvailable, detail: "Files are present, but the driver is not registered with SteamVR.") }
        if let driverLibrary, (try? Data(contentsOf: library)) != driverLibrary {
            return ComponentState(kind: .updateAvailable, detail: "Installed; openvrlink-companion includes a different driver build." + compatibility)
        }
        if driverLibrary != nil, !installedOwnTab, let vrlink = found.vrlink, !Install.vrlinkMenuPresent(inVRLink: vrlink) {
            return ComponentState(kind: .updateAvailable, detail: "Installed, but its controls are missing from SteamVR's VR Link settings (likely overwritten by a SteamVR update).")
        }
        return ComponentState(kind: .installed, detail: "Installed." + compatibility)
    }

    private func installDriver() throws -> [String] {
        guard let driverLibrary else {
            throw Failure("\(Install.libraryPlace(windows: windows).name) was not found alongside openvrlink-companion (pass --driver FILE)")
        }
        let driver = folder(of: .driver)
        let ownTab = self.ownTab ?? true
        try Install.writeDriver(to: driver, library: driverLibrary, beside: besideDriver, windows: windows, ownTab: ownTab)
        try Steam.setExternalDriver(driver, present: true, in: places)
        var lines = ["VR Link extensions driver installed to \(Steam.nativePath(driver))"]
        if let vrlink = found.vrlink {
            do {
                try Install.setVRLinkMenu(present: !ownTab, inVRLink: vrlink)
                lines.append(ownTab ? "Options are in SteamVR's settings under OpenVRLink." : "Options added to SteamVR's VR Link settings tab.")
            } catch {
                lines.append("Could not update the VR Link settings schema (\(error)); leaving the VR Link settings tab unchanged.")
            }
        }
        if let summary = patchSummary() { lines.append(summary) }
        return lines
    }

    // Shared component operations

    public func state(of component: Component) -> ComponentState {
        switch component {
        case .models: return modelsState()
        case .driver: return driverState()
        }
    }

    /// Installs or updates `component` and returns status log lines.
    public func install(_ component: Component) throws -> [String] {
        guard found.steamVR != nil else { throw Failure(Setup.notFoundSteamVR) }
        switch component {
        case .models: return try installModels()
        case .driver: return try installDriver()
        }
    }

    /// Uninstalls `component` and cleans up its driver registration and settings schema entries.
    public func uninstall(_ component: Component) throws -> [String] {
        var lines: [String] = []
        let driver = folder(of: component)
        try Steam.setExternalDriver(driver, present: false, in: places)
        if FileManager.default.fileExists(atPath: driver.path) {
            try remove(driver)
            lines.append("Removed \(Steam.nativePath(driver))")
        }
        if component == .driver, let vrlink = found.vrlink, (try? Install.setVRLinkMenu(present: false, inVRLink: vrlink)) == true {
            lines.append("Removed the options from the VR Link settings tab.")
        }
        return lines
    }

    /// Staging directory for locked binaries awaiting deletion. On Windows, `steam.exe`
    /// keeps `driver_openvrlink.dll` mapped while Steam is open, so locked files can be
    /// moved aside during uninstall and deleted on a later run.
    private var inUse: URL { places.data.appendingPathComponent("in-use") }

    /// Deletes any previously staged files in `in-use` that are no longer locked.
    public func clearLeftovers() {
        let files = FileManager.default
        guard let entries = try? OS.entries(in: inUse) else { return }
        for entry in entries { try? files.removeItem(at: entry) }
        if ((try? files.contentsOfDirectory(atPath: inUse.path)) ?? []).isEmpty { try? files.removeItem(at: inUse) }
    }

    private func remove(_ folder: URL) throws {
        let files = FileManager.default
        if (try? files.removeItem(at: folder)) != nil { return }
        // If directory removal fails because a binary is still mapped, delete unlocked files and move locked ones to `in-use`.
        try files.createDirectory(at: inUse, withIntermediateDirectories: true)
        for file in OS.files(below: folder) {
            if (try? files.removeItem(at: file)) == nil {
                try files.moveItem(at: file, to: inUse.appendingPathComponent("\(UUID().uuidString)-\(file.lastPathComponent)"))
            }
        }
        try files.removeItem(at: folder)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
