// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Installs the `openvrlink` SteamVR driver (`driver_openvrlink`, which patches
/// `driver_vrlink` in memory) and registers its SteamVR settings controls.
///
/// Settings are stored under a dedicated `driver_openvrlink` section so `driver_vrlink`
/// never sees unrecognized keys. By default, UI controls are inserted into
/// `driver_vrlink`'s `settingsschema.vrsettings`; those entries stay hidden when
/// `driver_openvrlink` is not loaded, and if a SteamVR update overwrites the file,
/// running `openvrlink-companion install` restores them.
public enum Install {
    public static let driverName = "openvrlink"
    /// Settings section for `driver_openvrlink` (mirrored in `Sources/driver_openvrlink/Server.swift`).
    public static let section = "driver_openvrlink"
    /// User option: apply the encoding gamma for clients that can undo it.
    public static let gammaOnKey = "encodingGamma"
    /// User option: the gamma to apply.
    public static let gammaValueKey = "encodingGammaValue"
    /// Written by the driver: whether this `driver_vrlink` build could be patched for gamma.
    public static let gammaAvailableKey = "gammaAvailable"
    /// Written by the driver: one line on what it managed to patch.
    public static let statusKey = "status"
    public static let defaultGamma = 1.8
    /// Marks a library that was in use when a newer one took its name.
    static let replacedMark = ".replaced-"

    /// Name of the driver library and of its folder under `bin`, per host platform.
    public static func libraryPlace(windows: Bool) -> (platform: String, name: String) {
        windows ? ("win64", "driver_openvrlink.dll") : ("linux64", "driver_openvrlink.so")
    }

    public struct SchemaError: Error, CustomStringConvertible {
        public let description: String
    }

    static func setting(_ key: String) -> String { "/settings/\(section)/\(key)" }

    /// The entries shown in SteamVR's settings. The gamma controls are hidden unless the
    /// driver has reported that the patch applied.
    public static var menuEntries: [JSON] {
        [
            .object([
                "name": .string(setting(gammaOnKey)), "control": .string("toggle"),
                "label": .string("OpenVRLink: brighten dark detail for encoding"),
                "requires": .object([setting(gammaAvailableKey): .bool(true)]),
            ]),
            .object([
                "name": .string(setting(gammaValueKey)), "control": .string("slider"), "label": .string("OpenVRLink: encoding gamma"),
                "min": .number("1"), "max": .number("2.5"), "step": .number("0.05"), "decimals": .number("2"),
                "requires": .object([setting(gammaAvailableKey): .bool(true), setting(gammaOnKey): .bool(true)]),
            ]),
            .object([
                "name": .string(setting(statusKey)), "control": .string("label"), "label": .string("OpenVRLink patches"),
                "advanced_only": .bool(true),
            ]),
            .object(["name": .string(setting("*")), "type": .string("wildcard")]),
        ]
    }

    private static func isOurs(_ entry: JSON) -> Bool { entry["name"]?.string?.hasPrefix(setting("")) ?? false }

    /// Adds (or, with `present` false, removes) our entries in the text of the VR Link
    /// driver's settings schema. They go just before the tab's closing wildcard entry.
    /// `nil` means the text is already as asked.
    public static func editingVRLinkSchema(_ schema: String, present: Bool) throws -> String? {
        guard case .array(var sections) = try JSON(parsing: schema), !sections.isEmpty, let before = sections[0]["values"]?.array
        else { throw SchemaError(description: "the schema is not a list of sections with values") }
        var values = before.filter { !isOurs($0) }
        if present {
            let at = values.firstIndex { $0["type"]?.string == "wildcard" } ?? values.count
            values.insert(contentsOf: menuEntries, at: at)
        }
        guard values != before else { return nil }
        sections[0]["values"] = .array(values)
        return JSON.array(sections).text
    }

    static func schemaFile(inVRLink vrlink: URL) -> URL { vrlink.appendingPathComponent("resources/settings/settingsschema.vrsettings") }

    /// Applies `editingVRLinkSchema` to the file in a VR Link driver folder. Returns
    /// whether the file changed.
    @discardableResult
    public static func setVRLinkMenu(present: Bool, inVRLink vrlink: URL) throws -> Bool {
        let file = schemaFile(inVRLink: vrlink)
        guard let edited = try editingVRLinkSchema(try String(contentsOf: file, encoding: .utf8), present: present) else { return false }
        try edited.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Whether the VR Link settings tab currently carries our entries.
    public static func vrlinkMenuPresent(inVRLink vrlink: URL) -> Bool {
        guard let text = try? String(contentsOf: schemaFile(inVRLink: vrlink), encoding: .utf8) else { return false }
        return ((try? editingVRLinkSchema(text, present: false)) ?? nil) != nil
    }

    /// Writes the driver folder: manifest, default settings, the library and any
    /// libraries it needs beside it. With `ownTab`, the options get a settings tab of
    /// their own instead of the entries in the VR Link tab.
    public static func writeDriver(to driver: URL, libraries: [URL], windows: Bool, ownTab: Bool) throws {
        let files = FileManager.default
        let place = libraryPlace(windows: windows)
        let settings = driver.appendingPathComponent("resources/settings"), bin = driver.appendingPathComponent("bin").appendingPathComponent(place.platform)
        try files.createDirectory(at: settings, withIntermediateDirectories: true)
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let manifest = JSON.object([
            "alwaysActivate": .bool(true), "name": .string(driverName), "directory": .string(""), "resourceOnly": .bool(false),
            "hmd_presence": .array([]),
        ])
        try manifest.text.write(to: driver.appendingPathComponent("driver.vrdrivermanifest"), atomically: true, encoding: .utf8)
        let defaults = JSON.object([section: .object([
            "enable": .bool(true), gammaOnKey: .bool(true), gammaValueKey: .of(defaultGamma), gammaAvailableKey: .bool(false),
            statusKey: .string("not loaded"),
        ])])
        try defaults.text.write(to: settings.appendingPathComponent("default.vrsettings"), atomically: true, encoding: .utf8)
        let schema = settings.appendingPathComponent("settingsschema.vrsettings")
        if ownTab {
            let tab = JSON.array([.object(["title": .string("OpenVRLink"), "values": .array(menuEntries)])])
            try tab.text.write(to: schema, atomically: true, encoding: .utf8)
        } else if files.fileExists(atPath: schema.path) {
            try files.removeItem(at: schema)
        }
        // Clean up any `.replaced-*` binaries from previous updates once they are no longer locked.
        for stale in (try? files.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? [] where stale.lastPathComponent.contains(replacedMark) {
            try? files.removeItem(at: stale)
        }
        for (index, library) in libraries.enumerated() {
            // Rename the primary driver binary to match what SteamVR expects, and keep companion library filenames as-is.
            let target = bin.appendingPathComponent(index == 0 ? place.name : library.lastPathComponent)
            if files.fileExists(atPath: target.path) {
                // On Windows, `steam.exe` keeps `driver_openvrlink.dll` mapped while Steam is open
                // (`Platform.pinThisLibrary`). Locked DLLs cannot be deleted on Windows, so move
                // the existing file aside if `removeItem` fails.
                do {
                    try files.removeItem(at: target)
                } catch {
                    try files.moveItem(at: target, to: bin.appendingPathComponent("\(target.lastPathComponent)\(replacedMark)\(UUID().uuidString)"))
                }
            }
            try files.copyItem(at: library, to: target)
        }
    }
}
