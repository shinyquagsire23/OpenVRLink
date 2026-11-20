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
        XCTAssertNotNil(entries[1]["requires"]?["/settings/driver_openvrlink/encodingGamma"])
    }

    func testTheDriverFolderIsLaidOutForSteamVR() throws {
        let root = try scratch(self)
        let library = root.appendingPathComponent("built.so"), runtime = root.appendingPathComponent("libruntime.so")
        try write("library", to: library)
        try write("runtime", to: runtime)
        let driver = root.appendingPathComponent(Install.driverName)
        try Install.writeDriver(to: driver, libraries: [library, runtime], windows: false, ownTab: true)
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("bin/linux64/driver_openvrlink.so")))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("bin/linux64/libruntime.so")))
        let manifest = try JSON(parsing: String(contentsOf: driver.appendingPathComponent("driver.vrdrivermanifest"), encoding: .utf8))
        XCTAssertEqual(manifest["name"]?.string, "openvrlink")
        let defaults = try JSON(parsing: String(contentsOf: driver.appendingPathComponent("resources/settings/default.vrsettings"), encoding: .utf8))
        XCTAssertEqual(defaults[Install.section]?[Install.gammaAvailableKey], .bool(false))
        XCTAssertEqual(defaults[Install.section]?[Install.gammaValueKey], .number("1.8"))
        XCTAssertTrue(Steam.isFile(driver.appendingPathComponent("resources/settings/settingsschema.vrsettings")))
        try Install.writeDriver(to: driver, libraries: [library], windows: true, ownTab: false)
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
