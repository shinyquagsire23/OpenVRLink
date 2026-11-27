// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import CompanionKit

/// A fresh empty folder under the system's temporary folder, removed after the test.
private func scratch(_ test: XCTestCase) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ovrl-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder.resolvingSymlinksInPath()
}

private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

final class JSONTests: XCTestCase {
    func testADocumentSurvivesARoundTripWithOrderAndNumbersKept() throws {
        let text = "{\n\t\"runtime\" : [\n\t\t\"C:\\\\Steam\\\\SteamVR\"\n\t],\n\t\"version\" : 1,\n\t\"scale\" : 1.50,\n\t\"empty\" : [],\n\t\"on\" : true\n}\n"
        let value = try JSON(parsing: text)
        XCTAssertEqual(value["runtime"]?.array?.first?.string, "C:\\Steam\\SteamVR")
        XCTAssertEqual(value.text, text)
    }

    func testValvesLooseCommasAreAccepted() throws {
        XCTAssertEqual(try JSON(parsing: "\u{FEFF}[ {\"a\": 1,}, ,{\"b\": [1,2,],} ]").array?.count, 2)
        XCTAssertThrowsError(try JSON(parsing: "{\"a\": }"))
        XCTAssertThrowsError(try JSON(parsing: "[1] 2"))
    }

    func testSettingReplacesInPlaceOrAppends() throws {
        var value = try JSON(parsing: "{\"a\": 1, \"b\": 2}")
        value["a"] = .bool(true)
        value["c"] = .string("x")
        XCTAssertEqual(value, .object(["a": .bool(true), "b": .number("2"), "c": .string("x")]))
        XCTAssertEqual(JSON.of(1.8).text, "1.8\n")
        XCTAssertEqual(JSON.of(2).text, "2\n")
    }
}

final class SteamTests: XCTestCase {
    func testLibraryPathsComeOutOfTheVDFUnescaped() {
        let vdf = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\"\n\t\t\"label\"\t\t\"\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\Games\"\n\t}\n}\n"
        XCTAssertEqual(Steam.libraryPaths(inVDF: vdf), ["C:\\Program Files (x86)\\Steam", "D:\\Games"])
    }

    func testSteamVRIsFoundInASecondLibraryAndDriversAreRegisteredOnce() throws {
        let root = try scratch(self)
        let steam = root.appendingPathComponent("Steam"), second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: second.appendingPathComponent("steamapps/common/SteamVR/drivers/vrlink"), withIntermediateDirectories: true)
        let escaped = second.path.replacingOccurrences(of: "\\", with: "\\\\")
        try write("\"libraryfolders\" { \"1\" { \"path\" \"\(escaped)\" } }", to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let places = Steam.Places(openVRConfig: root.appendingPathComponent("openvr"), steamRoots: [steam, root.appendingPathComponent("missing")],
                                  data: root.appendingPathComponent("data"))

        let found = Steam.find(places)
        XCTAssertEqual(found.libraries.count, 2)
        XCTAssertTrue(Steam.samePlace(try XCTUnwrap(found.steamVR), second.appendingPathComponent("steamapps/common/SteamVR")))
        XCTAssertTrue(Steam.isFolder(try XCTUnwrap(found.vrlink)))

        let driver = places.drivers.appendingPathComponent("openvrlink")
        try FileManager.default.createDirectory(at: driver, withIntermediateDirectories: true)
        XCTAssertFalse(try Steam.setExternalDriver(driver, present: false, in: places))
        XCTAssertTrue(try Steam.setExternalDriver(driver, present: true, in: places))
        XCTAssertFalse(try Steam.setExternalDriver(driver, present: true, in: places))
        XCTAssertEqual(Steam.find(places).externalDrivers.count, 1)
        XCTAssertTrue(Steam.samePlace(Steam.find(places).externalDrivers[0], driver))
        XCTAssertTrue(try Steam.setExternalDriver(driver, present: false, in: places))
        XCTAssertEqual(Steam.find(places).externalDrivers.count, 0)
    }

    func testOtherEntriesInOpenVRPathsAreKept() throws {
        let root = try scratch(self)
        let places = Steam.Places(openVRConfig: root, steamRoots: [], data: root.appendingPathComponent("data"))
        try write("{\"config\":[\"c\"],\"external_drivers\":[\"/other/driver\"],\"runtime\":[\"r\"],\"version\":1}", to: places.openVRPathsFile)
        try Steam.setExternalDriver(URL(fileURLWithPath: "/ours"), present: true, in: places)
        let paths = try JSON(parsing: String(contentsOf: places.openVRPathsFile, encoding: .utf8))
        XCTAssertEqual(paths["external_drivers"]?.array?.compactMap(\.string), ["/other/driver", Steam.nativePath(URL(fileURLWithPath: "/ours"))])
        XCTAssertEqual(paths["config"]?.array?.compactMap(\.string), ["c"])
        XCTAssertEqual(paths["version"], .number("1"))
    }
}

final class SenseModelTests: XCTestCase {
    private func fakeModels(in renderModels: URL) throws {
        for model in SenseModel.models {
            let folder = renderModels.appendingPathComponent(model)
            try write("{\"components\":{\"trigger\":{\"component_path\":\"/input/r2\"},\"sensor\":{\"component_path\":\"/input/r2_sensor\"},\"x\":{\"path\":\"/input/cross/click\"},\"ps\":{\"path\":\"/input/ps/click\"}}}",
                      to: folder.appendingPathComponent("\(model).json"))
            try write("png", to: folder.appendingPathComponent("textures/body.png"))
        }
    }

    func testInputsAreRenamedWithoutTouchingLongerNames() {
        let renamed = SenseModel.renamingInputs(in: "[\"/input/r2\", \"/input/r2_sensor\", \"/input/cross/click\", \"/input/ps/click\", \"/input/r2\"]")
        XCTAssertEqual(renamed.text, "[\"/input/trigger\", \"/input/r2_sensor\", \"/input/a/click\", \"/input/ps/click\", \"/input/trigger\"]")
        XCTAssertEqual(renamed.kinds, 2)
    }

    func testTheModelsAreFoundInSonysAppAndBuiltIntoADriver() throws {
        let root = try scratch(self)
        let library = root.appendingPathComponent("Library")
        let sony = library.appendingPathComponent("steamapps/common/PlayStation VR2 App/SteamVR_Plug-In/resources/rendermodels")
        try fakeModels(in: sony)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("steamapps/common/Some Game/data"), withIntermediateDirectories: true)
        let steamVR = root.appendingPathComponent("SteamVR")
        let found = Steam.Found(libraries: [library], steamVR: steamVR)
        let source = try XCTUnwrap(SenseModel.findSource(found))
        XCTAssertTrue(Steam.samePlace(source, sony), source.path)

        let driver = root.appendingPathComponent("data/drivers").appendingPathComponent(SenseModel.driverName)
        let report = try SenseModel.build(from: source, to: driver)
        XCTAssertEqual(report.map(\.model), SenseModel.models)
        XCTAssertEqual(report.map(\.kinds), [2, 2])
        XCTAssertTrue(try String(contentsOf: driver.appendingPathComponent("driver.vrdrivermanifest"), encoding: .utf8).contains("\"resourceOnly\" : true"))
        let model = SenseModel.models[0]
        let built = try String(contentsOf: driver.appendingPathComponent("resources/rendermodels/\(model)/\(model).json"), encoding: .utf8)
        XCTAssertTrue(built.contains("\"/input/trigger\"") && built.contains("\"/input/r2_sensor\"") && !built.contains("\"/input/r2\""))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("resources/rendermodels/\(SenseModel.models[1])/textures/body.png")))
        // Source files remain unmodified, and rebuilding overwrites the existing driver output.
        XCTAssertTrue(try String(contentsOf: sony.appendingPathComponent("\(model)/\(model).json"), encoding: .utf8).contains("\"/input/r2\""))
        XCTAssertNoThrow(try SenseModel.build(from: source, to: driver))
        // Falls back to ALVR's models in SteamVR when Sony's PlayStation VR2 App is absent, and prefers Sony's models when both exist.
        let alvr = steamVR.appendingPathComponent("drivers/playstation_vr2/resources/rendermodels")
        try fakeModels(in: alvr)
        XCTAssertTrue(Steam.samePlace(try XCTUnwrap(SenseModel.findSource(found)), sony))
        XCTAssertTrue(Steam.samePlace(try XCTUnwrap(SenseModel.findSource(Steam.Found(steamVR: steamVR))), alvr))
        // A folder without the models is refused, and the built driver is never its own source.
        XCTAssertThrowsError(try SenseModel.build(from: root.appendingPathComponent("nowhere"), to: driver))
        XCTAssertNil(SenseModel.findSource(Steam.Found(externalDrivers: [driver])))
    }
}

final class InstallTests: XCTestCase {
    static let vrlinkSchema = """
        [ { "title": "#{vrlink}Settings_Title", "values": [
        { "name": "/settings/driver_vrlink/enableEncryption", "control": "toggle", "label": "#{vrlink}Setting_enableEncryption", "requires_restart": true },
        { "name": "/driver_vrlink/client_version", "control": "label", "label": "#{vrlink}Setting_clientVersion", "advanced_only": false },
        { "name": "/settings/driver_vrlink/*", "type": "wildcard" } ] } ]
        """

    private func names(_ schema: String) throws -> [String] {
        try XCTUnwrap(JSON(parsing: schema).array?.first?["values"]?.array).compactMap { $0["name"]?.string }
    }

    func testEntriesGoBeforeTheWildcardOnceAndComeOutAgain() throws {
        let added = try XCTUnwrap(Install.editingVRLinkSchema(InstallTests.vrlinkSchema, present: true))
        XCTAssertEqual(try names(added), [
            "/settings/driver_vrlink/enableEncryption", "/driver_vrlink/client_version",
            "/settings/driver_openvrlink/encodingGamma", "/settings/driver_openvrlink/encodingGammaValue",
            "/settings/driver_openvrlink/status", "/settings/driver_openvrlink/*", "/settings/driver_vrlink/*",
        ])
        // Valve's own entries are carried over untouched.
        XCTAssertTrue(added.contains("\"requires_restart\" : true") && added.contains("#{vrlink}Settings_Title"))
        XCTAssertNil(try Install.editingVRLinkSchema(added, present: true))
        let removed = try XCTUnwrap(Install.editingVRLinkSchema(added, present: false))
        XCTAssertEqual(try JSON(parsing: removed), try JSON(parsing: InstallTests.vrlinkSchema))
        XCTAssertNil(try Install.editingVRLinkSchema(InstallTests.vrlinkSchema, present: false))
    }

    func testASchemaOfAnotherShapeIsLeftAlone() {
        XCTAssertThrowsError(try Install.editingVRLinkSchema("{\"title\": \"x\"}", present: true))
        XCTAssertThrowsError(try Install.editingVRLinkSchema("[ { \"title\": \"x\" } ]", present: true))
        XCTAssertThrowsError(try Install.editingVRLinkSchema("not json", present: true))
    }

    func testTheGammaControlsNeedThePatchToHaveApplied() {
        let entries = Install.menuEntries
        XCTAssertEqual(entries[0]["requires"]?["/settings/driver_openvrlink/gammaAvailable"], .bool(true))
        XCTAssertEqual(entries[1]["requires"]?["/settings/driver_openvrlink/gammaAvailable"], .bool(true))
        XCTAssertNil(entries[1]["requires"]?["/settings/driver_openvrlink/encodingGamma"])
    }

    func testTheDriverFolderIsLaidOutForSteamVR() throws {
        let root = try scratch(self)
        let runtime = root.appendingPathComponent("libruntime.so")
        try write("runtime", to: runtime)
        let driver = root.appendingPathComponent(Install.driverName)
        try Install.writeDriver(to: driver, library: Data("library".utf8), beside: [runtime], windows: false, ownTab: true)
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("bin/linux64/driver_openvrlink.so")))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("bin/linux64/libruntime.so")))
        let manifest = try JSON(parsing: String(contentsOf: driver.appendingPathComponent("driver.vrdrivermanifest"), encoding: .utf8))
        XCTAssertEqual(manifest["name"]?.string, "openvrlink")
        let defaults = try JSON(parsing: String(contentsOf: driver.appendingPathComponent("resources/settings/default.vrsettings"), encoding: .utf8))
        XCTAssertEqual(defaults[Install.section]?[Install.gammaAvailableKey], .bool(false))
        XCTAssertEqual(defaults[Install.section]?[Install.gammaValueKey], .number("1.6"))
        // Default vrlink_<model> sections are enabled and preserve the client's requested render size (-1).
        for name in ["vrlink_Apple Vision Pro (OpenVRLink)", "vrlink_OpenVRLink Headset"] {
            XCTAssertEqual(defaults[name]?["enable"], .bool(true), name)
            XCTAssertEqual(defaults[name]?["supportsEyeTracking"], .bool(true), name)
            XCTAssertEqual(defaults[name]?["supports10bit"], .bool(true), name)
            XCTAssertEqual(defaults[name]?["recommendedRenderWidth"], .number("-1"), name)
            XCTAssertEqual(defaults[name]?["recommendedRenderHeight"], .number("-1"), name)
            for key in ["modelNumber", "manufacturerName", "trackingSystemName", "resourceRoot", "inputProfilePath", "controllerType", "serialNumber"] {
                XCTAssertFalse(defaults[name]?[key]?.string?.isEmpty ?? true, "\(name) \(key)")
            }
        }
        XCTAssertEqual(defaults["vrlink_Apple Vision Pro (OpenVRLink)"]?["modelNumber"], .string("Apple Vision Pro (OpenVRLink)"))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("resources/settings/settingsschema.vrsettings")))
        // Installing the driver writes the Play For Dream controller models and sets controllerModels in defaults.
        XCTAssertEqual(defaults[Install.section]?[ControllerModels.settingsKey], .number("1"))
        XCTAssertTrue(PlayForDreamModel.isPresent(inDriver: driver))
        for model in PlayForDreamModel.models {
            let folder = driver.appendingPathComponent("resources/rendermodels").appendingPathComponent(model)
            let parts = try JSON(parsing: String(contentsOf: folder.appendingPathComponent("\(model).json"), encoding: .utf8))
            // Verify every component mesh referenced in the model JSON and the shared joystick texture exist on disk.
            guard case .object(let components)? = parts["components"] else { return XCTFail("\(model): no components") }
            for (name, component) in components {
                if let file = component["filename"]?.string { XCTAssertTrue(Steam.isFile(folder.appendingPathComponent(file)), "\(model) \(name)") }
            }
            XCTAssertTrue(Steam.isFile(folder.appendingPathComponent("\(model).obj")), model)
            XCTAssertTrue(Steam.isFile(folder.appendingPathComponent("pfd_mr_controller_joystick.tga")), model)
        }
        try FileManager.default.removeItem(at: driver.appendingPathComponent("resources/rendermodels/pfd_mr_controller_left/pfd_mr_controller_joystick.tga"))
        XCTAssertFalse(PlayForDreamModel.isPresent(inDriver: driver))
        try Install.writeDriver(to: driver, library: Data("library".utf8), windows: true, ownTab: false)
        XCTAssertTrue(PlayForDreamModel.isPresent(inDriver: driver))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("bin/win64/driver_openvrlink.dll")))
        XCTAssertFalse(Steam.isFile(driver.appendingPathComponent("resources/settings/settingsschema.vrsettings")))
    }

    func testTheRealVRLinkSchemaTakesTheEntriesAndGivesThemBack() throws {
        guard let path = ProcessInfo.processInfo.environment["OVRL_TEST_VRLINK_SCHEMA"] else { throw XCTSkip("no real schema named") }
        // The file may be an installed one that already carries the entries.
        let installed = try String(contentsOfFile: path, encoding: .utf8)
        let stock = try Install.editingVRLinkSchema(installed, present: false) ?? installed
        let added = try XCTUnwrap(Install.editingVRLinkSchema(stock, present: true))
        XCTAssertEqual(try JSON(parsing: try XCTUnwrap(Install.editingVRLinkSchema(added, present: false))), try JSON(parsing: stock))
    }
}

final class PlacesTests: XCTestCase {
    private func steam(_ root: URL, withSteamVR: Bool = false) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(withSteamVR ? "steamapps/common/SteamVR/drivers" : "steamapps"), withIntermediateDirectories: true)
    }

    func testNativeSteamUsesDefaultHomeDirectories() throws {
        let home = try scratch(self)
        try steam(home.appendingPathComponent(".local/share/Steam"), withSteamVR: true)
        let places = Steam.Places.choosing(among: Steam.Places.linuxInstallations(home: home, environment: [:]), dataFolder: "openvrlink")
        XCTAssertEqual(places.openVRConfig.path, home.appendingPathComponent(".config/openvr").path)
        XCTAssertEqual(places.data.path, home.appendingPathComponent(".local/share/openvrlink").path)
        XCTAssertNotNil(Steam.find(places).steamVR)
    }

    func testNativeSteamRespectsXDGEnvironmentVariables() throws {
        let home = try scratch(self)
        let data = home.appendingPathComponent("elsewhere/data")
        try steam(data.appendingPathComponent("Steam"))
        let installations = Steam.Places.linuxInstallations(home: home, environment: ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": home.appendingPathComponent("cfg").path])
        let places = Steam.Places.choosing(among: installations, dataFolder: "openvrlink")
        XCTAssertEqual(places.openVRConfig.path, home.appendingPathComponent("cfg/openvr").path)
        XCTAssertEqual(places.data.path, data.appendingPathComponent("openvrlink").path)
        XCTAssertEqual(Steam.find(places).libraries.count, 1)
    }

    func testSandboxedSteamUsesSandboxDirectories() throws {
        let home = try scratch(self)
        let snap = home.appendingPathComponent("snap/steam/common")
        try steam(snap.appendingPathComponent(".local/share/Steam"), withSteamVR: true)
        var places = Steam.Places.choosing(among: Steam.Places.linuxInstallations(home: home, environment: [:]), dataFolder: "openvrlink")
        XCTAssertEqual(places.openVRConfig.path, snap.appendingPathComponent(".config/openvr").path)
        XCTAssertEqual(places.data.path, snap.appendingPathComponent(".local/share/openvrlink").path)

        // Prefer the Snap installation with SteamVR over a native Steam folder without SteamVR.
        try steam(home.appendingPathComponent(".steam/steam"))
        places = Steam.Places.choosing(among: Steam.Places.linuxInstallations(home: home, environment: [:]), dataFolder: "openvrlink")
        XCTAssertEqual(places.data.path, snap.appendingPathComponent(".local/share/openvrlink").path)
        XCTAssertEqual(Steam.find(places).libraries.count, 2)

        // Support both `.config` and `config` OpenVR config paths inside the Steam Flatpak.
        let other = try scratch(self)
        let flatpak = other.appendingPathComponent(".var/app/com.valvesoftware.Steam")
        try steam(flatpak.appendingPathComponent("data/Steam"))
        try write("{}", to: flatpak.appendingPathComponent("config/openvr/openvrpaths.vrpath"))
        places = Steam.Places.choosing(among: Steam.Places.linuxInstallations(home: other, environment: [:]), dataFolder: "openvrlink")
        XCTAssertEqual(places.openVRConfig.path, flatpak.appendingPathComponent("config/openvr").path)
        XCTAssertEqual(places.data.path, flatpak.appendingPathComponent(".local/share/openvrlink").path)
    }
}

final class ComponentTests: XCTestCase {
    /// Creates a mock host directory with SteamVR and Sony's PlayStation VR2 App installed.
    private func machine() throws -> (root: URL, setup: Setup) {
        let root = try scratch(self)
        let library = root.appendingPathComponent("Steam")
        let vrlink = library.appendingPathComponent("steamapps/common/SteamVR/drivers/vrlink")
        try write(InstallTests.vrlinkSchema, to: vrlink.appendingPathComponent("resources/settings/settingsschema.vrsettings"))
        for model in SenseModel.models {
            try write("{\"x\":\"/input/r2\"}", to: library.appendingPathComponent("steamapps/common/PlayStation VR2 App/resources/rendermodels/\(model)/\(model).json"))
        }
        let places = Steam.Places(openVRConfig: root.appendingPathComponent("openvr"), steamRoots: [library], data: root.appendingPathComponent("data"))
        return (root, Setup(places: places, found: Steam.find(places), windows: false, driverLibrary: Data("driver 1".utf8)))
    }

    private func again(_ setup: Setup) -> Setup {
        var next = setup
        next.found = Steam.find(setup.places)
        return next
    }

    func testEncodingSizeWritesAndRemovesSteamVRSettings() throws {
        var (root, setup) = try machine()
        setup.steamVRRunning = { false }
        let file = root.appendingPathComponent("Steam/config/steamvr.vrsettings")
        XCTAssertEqual(setup.settingsFile?.path, file.path)
        XCTAssertEqual(setup.state(of: .encodingSize).kind, .notInstalled)
        XCTAssertEqual(setup.state(of: .encodingSize).action, "Apply")
        XCTAssertFalse(Component.installedByDefault.contains(.encodingSize))

        try write(#"{"steamvr":{"ipd":0.063},"driver_vrlink":{"targetBandwidth":240,"automaticStreamFormatWidth":true,"streamFormatWidth":1024}}"#, to: file)
        _ = try setup.install(.encodingSize)
        var settings = try JSON(parsing: String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(settings["driver_vrlink"]?["streamFormatWidth"], .number("3200"))
        XCTAssertEqual(settings["driver_vrlink"]?["automaticStreamFormatWidth"], .bool(false))
        XCTAssertEqual(settings["driver_vrlink"]?["targetBandwidth"], .number("240"))
        XCTAssertEqual(settings["steamvr"]?["ipd"], .number("0.063"))
        XCTAssertEqual(setup.state(of: .encodingSize).kind, .installed)
        XCTAssertNil(setup.state(of: .encodingSize).action)

        // Refuse to modify steamvr.vrsettings while SteamVR is running, since it overwrites the file on exit.
        setup.steamVRRunning = { true }
        XCTAssertThrowsError(try setup.uninstall(.encodingSize))
        XCTAssertEqual(setup.state(of: .encodingSize).kind, .installed)
        setup.steamVRRunning = { false }
        _ = try setup.uninstall(.encodingSize)
        settings = try JSON(parsing: String(contentsOf: file, encoding: .utf8))
        XCTAssertNil(settings["driver_vrlink"]?["streamFormatWidth"])
        XCTAssertNil(settings["driver_vrlink"]?["automaticStreamFormatWidth"])
        XCTAssertEqual(settings["driver_vrlink"]?["targetBandwidth"], .number("240"))
        XCTAssertEqual(setup.state(of: .encodingSize).kind, .notInstalled)
    }

    func testComponentsInstallUpdateAndUninstallIndependently() throws {
        var (_, setup) = try machine()
        XCTAssertEqual(Component.installedByDefault.map { setup.state(of: $0).kind }, [.notInstalled, .notInstalled])
        XCTAssertEqual(setup.state(of: .driver).action, "Install")

        // By default, settings go in a dedicated OpenVRLink tab without modifying VR Link's schema.
        _ = try setup.install(.driver)
        XCTAssertEqual(again(setup).state(of: .driver).kind, .installed)
        XCTAssertFalse(Install.vrlinkMenuPresent(inVRLink: try XCTUnwrap(setup.found.vrlink)))
        let tab = try JSON(parsing: String(contentsOf: Install.ownTabSchema(inDriver: setup.folder(of: .driver)), encoding: .utf8))
        XCTAssertEqual(tab.array?.first?["show_without_hmd"], .bool(true))

        // Test the remaining cases with settings placed in VR Link's tab.
        setup.ownTab = false
        _ = try setup.install(.driver)
        setup = again(setup)
        setup.ownTab = false
        XCTAssertEqual(setup.state(of: .driver).kind, .installed)
        XCTAssertNil(setup.state(of: .driver).action)
        XCTAssertEqual(setup.state(of: .models).kind, .notInstalled)
        XCTAssertTrue(Install.vrlinkMenuPresent(inVRLink: try XCTUnwrap(setup.found.vrlink)))

        // Flag an available update when the bundled driver binary differs from the installed copy.
        setup.driverLibrary = Data("driver 2".utf8)
        XCTAssertEqual(setup.state(of: .driver).kind, .updateAvailable)
        _ = try setup.install(.driver)
        XCTAssertEqual(again(setup).state(of: .driver).kind, .installed)
        XCTAssertEqual(try Data(contentsOf: Install.libraryFile(inDriver: setup.folder(of: .driver), windows: false)), Data("driver 2".utf8))

        // Flag an update if a SteamVR update overwrites settingsschema.vrsettings, and restore it on install.
        let schema = try XCTUnwrap(setup.found.vrlink).appendingPathComponent("resources/settings/settingsschema.vrsettings")
        try write(InstallTests.vrlinkSchema, to: schema)
        XCTAssertEqual(setup.state(of: .driver).kind, .updateAvailable)
        _ = try setup.install(.driver)
        XCTAssertEqual(again(setup).state(of: .driver).kind, .installed)

        _ = try setup.install(.models)
        setup = again(setup)
        XCTAssertEqual(setup.state(of: .models).kind, .installed)
        XCTAssertEqual(setup.found.externalDrivers.count, 2)

        _ = try setup.uninstall(.driver)
        setup = again(setup)
        XCTAssertEqual(setup.state(of: .driver).kind, .notInstalled)
        XCTAssertEqual(setup.state(of: .models).kind, .installed)
        XCTAssertFalse(Install.vrlinkMenuPresent(inVRLink: try XCTUnwrap(setup.found.vrlink)))
        _ = try setup.uninstall(.models)
        setup = again(setup)
        XCTAssertEqual(setup.state(of: .models).kind, .notInstalled)
        XCTAssertEqual(setup.found.externalDrivers.count, 0)
    }

    func testModelsOfferUpdateWhenPlayStationVR2AppIsInstalled() throws {
        var (root, setup) = try machine()
        let sony = root.appendingPathComponent("Steam/steamapps/common/PlayStation VR2 App")
        let hidden = root.appendingPathComponent("hidden")
        try FileManager.default.moveItem(at: sony, to: hidden)
        XCTAssertEqual(setup.state(of: .models).kind, .unavailable)
        for model in SenseModel.models {
            try write("{}", to: try XCTUnwrap(setup.found.steamVR).appendingPathComponent("drivers/playstation_vr2/resources/rendermodels/\(model)/\(model).json"))
        }
        XCTAssertEqual(setup.state(of: .models).kind, .notInstalled)
        _ = try setup.install(.models)
        setup = again(setup)
        XCTAssertEqual(setup.state(of: .models).kind, .installed)
        try FileManager.default.moveItem(at: hidden, to: sony)
        XCTAssertEqual(setup.state(of: .models).kind, .updateAvailable)
        _ = try setup.install(.models)
        XCTAssertEqual(again(setup).state(of: .models).kind, .installed)
    }

    func testComponentsAreUnavailableWithoutSteamVROrDriver() throws {
        var (_, setup) = try machine()
        setup.driverLibrary = nil
        XCTAssertEqual(setup.state(of: .driver).kind, .unavailable)
        XCTAssertThrowsError(try setup.install(.driver))
        setup.found.steamVR = nil
        XCTAssertEqual(setup.state(of: .models).kind, .unavailable)
        XCTAssertThrowsError(try setup.install(.models))
    }
}

final class ReleaseTests: XCTestCase {
    func testSourceVersionMatchesRepositoryVersionJson() throws {
        // Walk up from companion/Tests/CompanionKitTests/<file> to the repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent("version.json"), encoding: .utf8) else {
            throw XCTSkip("version.json not found above package root")
        }
        let json = try JSON(parsing: text)
        let version = try XCTUnwrap(json["version"]?.string), build = try XCTUnwrap(json["build"]?.number)
        XCTAssertEqual(Release.sourceVersion, "\(version)-\(build)",
                       "the version compiled in is not version.json's")
    }

    func testIconResourceExtraction() throws {
        // Construct a 2-image ICO: a 16x16 entry (5 bytes) and a 256x256 entry encoded with width/height 0 (3 bytes).
        var file: [UInt8] = [0, 0, 1, 0, 2, 0]
        file += [16, 16, 0, 0, 1, 0, 32, 0, 5, 0, 0, 0, 38, 0, 0, 0]
        file += [0, 0, 0, 0, 1, 0, 32, 0, 3, 0, 0, 0, 43, 0, 0, 0]
        file += [1, 2, 3, 4, 5, 9, 8, 7]
        let parts = try XCTUnwrap(WindowsResources.icon(fromICO: file))
        XCTAssertEqual(parts.images.map(\.id), [1, 2])
        XCTAssertEqual(parts.images.map(\.data), [[1, 2, 3, 4, 5], [9, 8, 7]])
        XCTAssertEqual(parts.group, [0, 0, 1, 0, 2, 0,
                                     16, 16, 0, 0, 1, 0, 32, 0, 5, 0, 0, 0, 1, 0,
                                     0, 0, 0, 0, 1, 0, 32, 0, 3, 0, 0, 0, 2, 0])
        XCTAssertNil(WindowsResources.icon(fromICO: Array(file.dropLast())))
        XCTAssertNil(WindowsResources.icon(fromICO: [0, 0, 2, 0, 1, 0]))
        // Verify the checked-in companion icon parses cleanly.
        let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/openvrlink-companion.ico")
        let real = try XCTUnwrap(WindowsResources.icon(fromICO: [UInt8](try Data(contentsOf: icon))))
        XCTAssertEqual(real.images.count, 9)
        XCTAssertEqual(real.group.count, 6 + 14 * 9)
    }

    func testVersionInfoBinaryLayout() {
        let info = WindowsResources.versionInfo(version: "1.2.3-45")
        func word(_ at: Int) -> Int { Int(info[at]) | Int(info[at + 1]) << 8 }
        func long(_ at: Int) -> Int { word(at) | word(at + 2) << 16 }
        func text(_ at: Int, _ count: Int) -> String { String(decoding: (0..<count).map { UInt16(word(at + $0 * 2)) }, as: UTF16.self) }
        XCTAssertEqual(word(0), info.count)
        XCTAssertEqual(word(2), 52)
        XCTAssertEqual(word(4), 0)
        XCTAssertEqual(text(6, 15), "VS_VERSION_INFO")
        // VS_FIXEDFILEINFO follows the 6-byte header and 32-byte UTF-16 key+NUL, padded from offset 38 to 40.
        XCTAssertEqual(long(40), 0xFEEF04BD)
        XCTAssertEqual(long(48), 1 << 16 | 2)
        XCTAssertEqual(long(52), 3 << 16 | 45)
        XCTAssertEqual(long(56), 1 << 16 | 2)
        XCTAssertEqual(long(60), 3 << 16 | 45)
        // StringFileInfo follows the 52-byte VS_FIXEDFILEINFO block at offset 92.
        XCTAssertEqual(text(92 + 6, 14), "StringFileInfo")
        let whole = String(decoding: stride(from: 0, to: info.count - 1, by: 2).map { UInt16(word($0)) }, as: UTF16.self)
        for expected in ["040904B0", "ProductName", "OpenVRLink Companion", "FileVersion", "1.2.3.45", "ProductVersion", "1.2.3-45", "VarFileInfo", "Translation"] {
            XCTAssertTrue(whole.contains(expected), expected)
        }
        XCTAssertEqual(Array(info.suffix(4)), [0x09, 0x04, 0xB0, 0x04])
        // Versions with fewer than four numeric components pad remaining components with zeros.
        XCTAssertEqual(WindowsResources.versionInfo(version: "2").count % 2, 0)
    }

    func testNumericVersionComparison() {
        XCTAssertEqual(Release.numbers("v0.1.0-8"), [0, 1, 0, 8])
        XCTAssertTrue(Release.isNewer("v0.1.0-10", than: "0.1.0-9"))
        XCTAssertTrue(Release.isNewer("0.2.0", than: "0.1.0-9"))
        XCTAssertTrue(Release.isNewer("0.1.0-1", than: "0.1.0"))
        XCTAssertFalse(Release.isNewer("v0.1.0-8", than: "0.1.0-8"))
        XCTAssertFalse(Release.isNewer("0.1.0-7", than: "0.1.0-8"))
    }

    func testSelectsLatestPublishedReleaseWithMatchingAsset() throws {
        let asset = Release.assetName(windows: true, architecture: Release.thisArchitecture)
        func release(_ tag: String, _ assets: [String], flags: String = "") -> String {
            let files = assets.map { "{\"name\": \"\($0)\", \"size\": 123, \"browser_download_url\": \"https://example.com/\(tag)/\($0)\"}" }.joined(separator: ",")
            return "{\"tag_name\": \"\(tag)\", \(flags) \"assets\": [\(files)]}"
        }
        let list = "[" + [
            release("v0.3.0", [asset], flags: "\"prerelease\": true,"),
            release("v0.2.1", ["OpenVRLink.ipa"]),
            release("v0.1.0-9", [asset, "other.zip"]),
            release("v0.2.0", [asset], flags: "\"draft\": false, \"prerelease\": false,"),
        ].joined(separator: ",") + "]"
        XCTAssertEqual(try Release.newest(inReleaseList: list, asset: asset),
                       Release.Offer(version: "0.2.0", url: "https://example.com/v0.2.0/\(asset)", size: 123))
        XCTAssertEqual(try Release.update(from: "0.1.0-9", windows: true) { _ in Data(list.utf8) }?.version, "0.2.0")
        XCTAssertNil(try Release.update(from: "0.2.0", windows: true) { _ in Data(list.utf8) })
        XCTAssertNil(try Release.newest(inReleaseList: "[]", asset: asset))
        XCTAssertThrowsError(try Release.newest(inReleaseList: "{\"message\": \"rate limited\"}", asset: asset))
    }

    func testSwapMovesExistingExecutableAside() throws {
        let folder = try scratch(self)
        let program = folder.appendingPathComponent("companion.exe")
        try write("old", to: program)
        let staged = try SelfUpdate.stage(Data("new".utf8), beside: program)
        XCTAssertEqual(staged.pathExtension, "exe")
        XCTAssertEqual(try String(contentsOf: program, encoding: .utf8), "old")
        try SelfUpdate.swap(staged, into: program)
        XCTAssertEqual(try String(contentsOf: program, encoding: .utf8), "new")
        try write("left", to: folder.appendingPathComponent("companion.old-1234.exe"))
        try write("keep", to: folder.appendingPathComponent("companion-notes.txt"))
        XCTAssertTrue(SelfUpdate.clearLeftovers(beside: program))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["companion-notes.txt", "companion.exe"])
        XCTAssertFalse(SelfUpdate.looksRunnable(Data("<html>".utf8), windows: true))
    }

    /// Builds a minimal two-part glTF fixture with a static body mesh and a trigger node that rotates 10 deg around X.
    private func smallController() -> (gltf: Data, files: [String: Data]) {
        var bytes = Data()
        func floats(_ values: [Float]) { for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } } }
        floats([0, 0, 0, 0.01, 0, 0, 0, 0.01, 0])            // positions, at 0
        floats([0, 0, 1, 0, 0, 1, 0, 0, 1])                  // normals, at 36
        floats([0, 0, 1, 0, 0, 1])                           // texture coordinates, at 72
        for index: UInt16 in [0, 1, 2] { withUnsafeBytes(of: index.littleEndian) { bytes.append(contentsOf: $0) } }   // at 96
        bytes.append(contentsOf: [0, 0])
        floats([0, 1])                                       // times, at 104
        let half = Float(5 * Double.pi / 180)
        floats([0, 0, 0, 1, sin(half), 0, 0, cos(half)])     // rotations, at 112
        let gltf = """
        {"asset":{"version":"2.0"},"buffers":[{"uri":"c.bin","byteLength":\(bytes.count)}],
         "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},
            {"buffer":0,"byteOffset":72,"byteLength":24},{"buffer":0,"byteOffset":96,"byteLength":6},
            {"buffer":0,"byteOffset":104,"byteLength":8},{"buffer":0,"byteOffset":112,"byteLength":32}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"},{"bufferView":3,"componentType":5123,"count":3,"type":"SCALAR"},
            {"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR"},{"bufferView":5,"componentType":5126,"count":2,"type":"VEC4"}],
         "images":[{"uri":"color.png"}],"textures":[{"source":0}],
         "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":3,"material":0}]}],
         "nodes":[{"name":"body","mesh":0},{"name":"t","mesh":0},{"name":"Trigger","children":[1],"translation":[0,0.02,0.03]},
                  {"name":"Root","children":[0,2]}],
         "animations":[{"name":"Trigger_Press","channels":[{"sampler":0,"target":{"node":2,"path":"rotation"}}],
                        "samplers":[{"input":4,"output":5,"interpolation":"LINEAR"}]}]}
        """
        return (Data(gltf.utf8), ["c.bin": bytes, "color.png": Data([1, 2, 3])])
    }

    func testConvertsGLTFControllerModelToSteamVRRenderModel() throws {
        let source = smallController()
        XCTAssertEqual(GLTFControllerModel.references(of: source.gltf), ["c.bin", "color.png"])
        // Using an identity placement transform preserves the glTF's local coordinates.
        let files = try GLTFControllerModel.convert(gltf: source.gltf, files: source.files, side: .left, name: "m", place: .init())
        XCTAssertEqual(Set(files.map(\.path)), ["m.obj", "m.mtl", "m_body.obj", "m_body.mtl", "m_trigger.obj", "m_trigger.mtl", "m.png", "m.json"])
        let trigger = String(decoding: try XCTUnwrap(files.first { $0.path == "m_trigger.obj" }).data, as: UTF8.self)
        // Trigger vertices include the node translation, and V texture coordinates are flipped for OBJ.
        XCTAssertTrue(trigger.contains("v 0.010000 0.020000 0.030000\n"), trigger)
        XCTAssertTrue(trigger.contains("vt 0.000000 0.000000\n") && trigger.contains("vt 0.000000 1.000000\n"))
        XCTAssertTrue(trigger.contains("f 1/1/1 2/2/2 3/3/3\n"))
        let whole = String(decoding: try XCTUnwrap(files.first { $0.path == "m.obj" }).data, as: UTF8.self)
        XCTAssertTrue(whole.contains("f 4/4/4 5/5/5 6/6/6\n"))
        let described = try JSON(parsing: String(decoding: try XCTUnwrap(files.first { $0.path == "m.json" }).data, as: UTF8.self))
        let motion = try XCTUnwrap(described["components"]?["trigger"]?["motion"])
        XCTAssertEqual(motion["type"], .string("rotate"))
        XCTAssertEqual(motion["trigger_path"], .string("/input/trigger"))
        XCTAssertEqual(motion["pivot"], .array([.number("0"), .number("0.02"), .number("0.03")]))
        XCTAssertEqual(motion["axis"], .array([.number("1"), .number("0"), .number("0")]))
        XCTAssertEqual(motion["value_mapping"]?.array?.last?.number.flatMap(Double.init) ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(described["components"]?["body"]?["filename"], .string("m_body.obj"))
        XCTAssertNotNil(described["components"]?["openxr_grip"])

        // Default placement maps the glTF origin onto the Quest 2 model's openxr_grip transform.
        let placed = try GLTFControllerModel.convert(gltf: source.gltf, files: source.files, side: .left, name: "m")
        let body = String(decoding: try XCTUnwrap(placed.first { $0.path == "m_body.obj" }).data, as: UTF8.self)
        XCTAssertTrue(body.contains("v 0.007000 -0.001829 0.101948\n"), body)

        // galaxyXRPlace inverts the client's GripOffset.towardQuest transform (+5 mm X, +5 mm Y, +56 mm Z, and
        // +15 deg pitch relative to galaxyXRGrip) so the adjusted grip pose lands on questGrip.
        let galaxy = GLTFControllerModel.galaxyXRPlace(.left), quest = GLTFControllerModel.questGrip(.left)
        let pitch = GLTFControllerModel.Transform(degrees: [15, 0, 0], translation: [0, 0, 0])
        // Offset of Samsung's reported grip pose along the handle axis in glTF coordinates.
        let grip = GLTFControllerModel.galaxyXRGrip(.left)
        XCTAssertEqual(grip, [-0.008, 0, -0.014])
        for (got, expected) in zip(galaxy.applied(to: [0.005 + grip[0], 0.005 + grip[1], 0.056 + grip[2]]), quest.applied(to: [0, 0, 0])) { XCTAssertEqual(got, expected, accuracy: 1e-9) }
        for (got, expected) in zip(galaxy.turned(pitch.turned([0, 0, -1])), quest.turned([0, 0, -1])) { XCTAssertEqual(got, expected, accuracy: 1e-9) }
        XCTAssertEqual(GLTFControllerModel.galaxyXRPlace(.right).translation[0], -galaxy.translation[0], accuracy: 1e-9)

        // Truncated buffers and empty glTF documents throw an error instead of reading out of bounds.
        XCTAssertThrowsError(try GLTFControllerModel.convert(gltf: source.gltf, files: ["c.bin": Data(count: 40)], side: .left, name: "m"))
        XCTAssertThrowsError(try GLTFControllerModel.convert(gltf: Data("{}".utf8), files: [:], side: .left, name: "m"))
    }

    func testInstallingControllerModelsUpdatesDriverDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ovrl-models-\(UInt32.random(in: 0...UInt32.max))")
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("driver"), sources = root.appendingPathComponent("from")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Install.writeDriver(to: driver, library: Data([1]), windows: true, ownTab: true)
        let source = smallController()
        for name in ["L.gltf", "R.gltf"] { try source.gltf.write(to: sources.appendingPathComponent(name)) }
        for (name, data) in source.files { try data.write(to: sources.appendingPathComponent(name)) }
        XCTAssertEqual(HeadsetModel.setsPresent(inDriver: driver), ControllerModels.playForDream)
        try HeadsetModel.installGalaxyXR(left: sources.appendingPathComponent("L.gltf"), right: sources.appendingPathComponent("R.gltf"), toDriver: driver)
        XCTAssertEqual(HeadsetModel.setsPresent(inDriver: driver), ControllerModels.playForDream | ControllerModels.galaxyXR)
        func noted() throws -> JSON? {
            try JSON(parsing: String(contentsOf: driver.appendingPathComponent("resources/settings/default.vrsettings"), encoding: .utf8))[Install.section]?[ControllerModels.settingsKey]
        }
        XCTAssertEqual(try noted(), .number("3"))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("resources/rendermodels/galaxy_xr_controller_right/galaxy_xr_controller_right_trigger.obj")))
        // Completed uploads in incoming/ are converted during driver installation while keeping the source files.
        let other = root.appendingPathComponent("other"), sent = other.appendingPathComponent("incoming/galaxy_xr")
        for side in ["Left", "Right"] {
            try FileManager.default.createDirectory(at: sent.appendingPathComponent(side), withIntermediateDirectories: true)
            try source.gltf.write(to: sent.appendingPathComponent("\(side)/\(side)Controller.gltf"))
            for (name, data) in source.files { try data.write(to: sent.appendingPathComponent("\(side)/\(name)")) }
        }
        try Install.writeDriver(to: other, library: Data([1]), windows: true, ownTab: true)
        XCTAssertEqual(HeadsetModel.setsPresent(inDriver: other), ControllerModels.playForDream, "incomplete upload should be skipped until complete marker exists")
        try Data("1\n".utf8).write(to: sent.appendingPathComponent("complete"))
        try Install.writeDriver(to: other, library: Data([1]), windows: true, ownTab: true)
        XCTAssertEqual(HeadsetModel.setsPresent(inDriver: other), ControllerModels.playForDream | ControllerModels.galaxyXR)
        XCTAssertTrue(Steam.isFile(sent.appendingPathComponent("Left/LeftController.gltf")))
        let told = try JSON(parsing: String(contentsOf: other.appendingPathComponent("resources/settings/default.vrsettings"), encoding: .utf8))[Install.section]
        XCTAssertEqual(told?["folder"], .string(Steam.nativePath(other)))
        XCTAssertEqual(told?[ControllerModels.settingsKey], .number("3"))
        // Reinstalling the driver preserves converted headset models and their controllerModels bitmask.
        try Install.writeDriver(to: driver, library: Data([2]), windows: true, ownTab: true)
        XCTAssertEqual(try noted(), .number("3"))
    }
}
