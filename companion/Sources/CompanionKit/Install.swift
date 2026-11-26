// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import PatchCore

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
    public static let defaultGamma = 1.6

    /// Native `(model, manufacturer)` pairs used by OpenVRLink clients when `driver_openvrlink` is installed.
    /// Must match `Server.headsetSections` in `driver_openvrlink`.
    public static let headsets = [("Apple Vision Pro (OpenVRLink)", "Apple"), ("OpenVRLink Headset", "OpenVRLink")]

    /// Builds a `vrlink_<model>` default settings section for an unrecognized HMD model
    /// (`docs/svl-values/static-and-power-props.md`). Setting `enable` enables 10-bit video
    /// and eye tracking, but also causes `driver_vrlink` to override six static HMD string
    /// properties and the render resolution from settings; we repeat the strings OpenVRLink
    /// sends and set `recommendedRenderWidth`/`Height` to `-1` so `driver_vrlink` keeps the
    /// client's requested resolution (omitting them or passing `0` falls back to 2064 x 2208).
    static func headsetSection(model: String, manufacturer: String) -> JSON {
        .object([
            "enable": .bool(true), "serialNumber": .string("OpenVRLink-HMD"),
            "supports10bit": .bool(true), "supportsEyeTracking": .bool(true),
            "recommendedRenderWidth": .number("-1"), "recommendedRenderHeight": .number("-1"),
            "modelNumber": .string(model), "manufacturerName": .string(manufacturer),
            "trackingSystemName": .string("oculus"), "resourceRoot": .string("vrlink"),
            "inputProfilePath": .string("{oculus}/input/rift_profile.json"), "controllerType": .string("rift"),
        ])
    }
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
                // Only gate visibility on `gammaAvailable`. Adding `encodingGamma: true` to `requires`
                // hid the slider completely in SteamVR 2.19.4 even when the toggle was enabled.
                "requires": .object([setting(gammaAvailableKey): .bool(true)]),
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

    /// Writes the `driver_openvrlink` directory, including its manifest, default settings,
    /// primary driver binary, and any companion runtime libraries. When `ownTab` is true,
    /// writes a standalone OpenVRLink settings schema instead of using the VR Link tab.
    public static func writeDriver(to driver: URL, library: Data, beside: [URL] = [], windows: Bool, ownTab: Bool) throws {
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
        var defaults = JSON.object([section: .object([
            "enable": .bool(true), gammaOnKey: .bool(true), gammaValueKey: .of(defaultGamma), gammaAvailableKey: .bool(false),
            statusKey: .string("not loaded"), PlayForDreamModel.settingsKey: .bool(true),
        ])])
        // Write the controller models before default.vrsettings advertises them.
        try PlayForDreamModel.write(toDriver: driver)
        // SteamVR merges default.vrsettings across all active drivers, so driver_vrlink reads these vrlink_<model> sections too.
        for (model, manufacturer) in headsets { defaults["vrlink_\(model)"] = headsetSection(model: model, manufacturer: manufacturer) }
        try defaults.text.write(to: settings.appendingPathComponent("default.vrsettings"), atomically: true, encoding: .utf8)
        let schema = ownTabSchema(inDriver: driver)
        if ownTab {
            // Set `show_without_hmd` so SteamVR displays this tab even though the active headset
            // belongs to `driver_vrlink` rather than `driver_openvrlink`.
            let tab = JSON.array([.object(["title": .string("OpenVRLink"), "show_without_hmd": .bool(true), "values": .array(menuEntries)])])
            try tab.text.write(to: schema, atomically: true, encoding: .utf8)
        } else if files.fileExists(atPath: schema.path) {
            try files.removeItem(at: schema)
        }
        // Clean up any `.replaced-*` binaries from previous updates once they are no longer locked.
        for stale in (try? OS.entries(in: bin)) ?? [] where stale.lastPathComponent.contains(replacedMark) {
            try? files.removeItem(at: stale)
        }
        /// Frees a target path in `bin`. On Windows, `steam.exe` keeps `driver_openvrlink.dll`
        /// mapped while Steam is open (`Platform.pinThisLibrary`); locked DLLs cannot be
        /// deleted, so rename the existing file if deletion fails.
        func free(_ target: URL) throws {
            guard files.fileExists(atPath: target.path) else { return }
            do {
                try files.removeItem(at: target)
            } catch {
                try files.moveItem(at: target, to: bin.appendingPathComponent("\(target.lastPathComponent)\(replacedMark)\(UUID().uuidString)"))
            }
        }
        let target = libraryFile(inDriver: driver, windows: windows)
        if (try? Data(contentsOf: target)) != library {
            try free(target)
            try library.write(to: target)
        }
        for other in beside {
            let target = bin.appendingPathComponent(other.lastPathComponent)
            try free(target)
            try files.copyItem(at: other, to: target)
        }
    }

    /// Path to the primary driver binary inside an installed driver directory.
    public static func libraryFile(inDriver driver: URL, windows: Bool) -> URL {
        let place = libraryPlace(windows: windows)
        return driver.appendingPathComponent("bin").appendingPathComponent(place.platform).appendingPathComponent(place.name)
    }

    /// Path to the standalone settings schema created when `ownTab` is enabled.
    public static func ownTabSchema(inDriver driver: URL) -> URL { driver.appendingPathComponent("resources/settings/settingsschema.vrsettings") }

    /// Compatibility check results for patching a `driver_vrlink` binary.
    public struct PatchReport: Equatable {
        /// Whether the extension handshake functions can be hooked.
        public var handshake: Bool
        /// Whether the encode shaders and constant-buffer updates can also be patched.
        public var gamma: Bool

        public var summary: String {
            switch (handshake, gamma) {
            case (true, true): return "Compatible with the installed SteamVR VR Link build."
            case (true, false): return "Partially compatible with this SteamVR VR Link build (encoding gamma is unavailable)."
            default: return "Incompatible with this SteamVR VR Link build; the driver will stay inactive."
            }
        }
    }

    /// Checks which hook targets resolve in `bytes`, returning `nil` if `bytes` is not a PE or ELF64 binary.
    public static func patchReport(vrlinkLibrary bytes: [UInt8]) -> PatchReport? {
        bytes.withUnsafeBufferPointer { view -> PatchReport? in
            guard Scan.isELF64(view) || Scan.isPE(view) else { return nil }
            var foundNames: Set<String> = []
            for (target, resolution) in Scan.resolveAll(inFile: view) {
                if case .found = resolution { foundNames.insert("\(target.name)") }
            }
            func has(_ target: Scan.Target) -> Bool { foundNames.contains("\(target.name)") }
            let handshake = has(Scan.parseRecords) && has(Scan.populateRecords)
            let shaders: Bool
            if Scan.isPE(view) {
                shaders = has(Scan.updateConstantsD3D)
                    && Scan.peImportSlot(view, mapped: false, library: Scan.shaderReadImport.library, function: Scan.shaderReadImport.function) != nil
            } else {
                shaders = has(Scan.loadSPIRV) && (has(Scan.updateConstants) || has(Scan.updateConstantsWide))
            }
            return PatchReport(handshake: handshake, gamma: handshake && shaders)
        }
    }
}
