// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Command-line installer and diagnostic tool for OpenVRLink's SteamVR host drivers.

import CompanionKit
import Foundation
import PatchCore

let usage = """
    OpenVRLink companion

      openvrlink-companion status
          Show what was found on this PC and what is installed.

      openvrlink-companion install [options]
          Build the PlayStation VR2 Sense controller models for OpenVRLink and
          install the driver that adds the OpenVRLink extensions to VR Link.
            --steamvr DIR    SteamVR's folder, if it is not found automatically
            --models DIR     take the Sense models from this folder
            --driver FILE    the built driver_openvrlink library (default: beside this program)
            --no-patches     install the controller models only
            --own-tab        show the options in an OpenVRLink settings tab
                             instead of adding them to the VR Link tab

      openvrlink-companion uninstall
          Remove everything `install` set up.

      openvrlink-companion check FILE
          Report which patches would apply to a driver_vrlink.dll / driver_vrlink.so.

      openvrlink-companion patch-shader IN OUT
          Write a gamma-patched copy of one of VR Link's encode shaders
          (a Linux .spv or a Windows .fxo).

    """

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var steamVR: URL?, models: URL?, driver: URL?
    var patches = true, ownTab = false
    var rest: [String] = []

    init(_ arguments: [String]) throws {
        var arguments = arguments[...]
        while let argument = arguments.popFirst() {
            func path() throws -> URL {
                guard let value = arguments.popFirst() else { throw Failure("\(argument) needs a path") }
                return URL(fileURLWithPath: value)
            }
            switch argument {
            case "--steamvr": steamVR = try path()
            case "--models": models = try path()
            case "--driver": driver = try path()
            case "--no-patches": patches = false
            case "--own-tab": ownTab = true
            case _ where argument.hasPrefix("--"): throw Failure("unknown option \(argument)")
            default: rest.append(argument)
            }
        }
    }
}

#if os(Windows)
let onWindows = true
#else
let onWindows = false
#endif

func bytes(of file: URL) throws -> [UInt8] {
    do { return [UInt8](try Data(contentsOf: file)) } catch { throw Failure("\(file.path): \(error.localizedDescription)") }
}

func describe(_ missing: Scan.Missing) -> String {
    switch missing {
    case .notForThisPlatform: return "not for this platform"
    case .notFound: return "function not found in this build"
    case .ambiguous(let count): return "signature matches \(count) places"
    case .neverCalledDirectly: return "function found but nothing calls it directly"
    case .tooManyCallers(let count): return "\(count) call sites, more than expected"
    }
}

func found(_ places: Steam.Places, _ options: Options) -> Steam.Found {
    var found = Steam.find(places)
    if let steamVR = options.steamVR { found.steamVR = steamVR }
    return found
}

func vrlinkLibrary(_ found: Steam.Found) -> URL? {
    let name = onWindows ? "driver_vrlink.dll" : "driver_vrlink.so"
    let file = found.vrlink?.appendingPathComponent("bin").appendingPathComponent(Install.libraryPlace(windows: onWindows).platform).appendingPathComponent(name)
    return file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
}

func check(_ file: URL) throws {
    let contents = try bytes(of: file)
    try contents.withUnsafeBufferPointer { view in
        guard Scan.isELF64(view) || Scan.isPE(view) else { throw Failure("\(file.path) is not a Windows or Linux library") }
        let resolved = Scan.resolveAll(inFile: view)
        // The Linux constants function has one of two shapes by build; show the one this build has.
        let constants = ["encode-constants", "encode-constants-wide"]
        let hasConstants = resolved.contains { constants.contains("\($0.target.name)") && $0.resolution != .missing(.notFound) }
        for (target, resolution) in resolved {
            if hasConstants, constants.contains("\(target.name)"), resolution == .missing(.notFound) { continue }
            let name = "\(target.name)".padding(toLength: 22, withPad: " ", startingAt: 0)
            switch resolution {
            case .found(let found): print("  \(name)found, \(found.sites.count) call site(s)")
            case .missing(let missing): print("  \(name)\(describe(missing))")
            }
        }
        if Scan.isPE(view) {
            let slot = Scan.peImportSlot(view, mapped: false, library: Scan.shaderReadImport.library, function: Scan.shaderReadImport.function)
            print("  \("shader-read import".padding(toLength: 22, withPad: " ", startingAt: 0))\(slot == nil ? "not found" : "found")")
        }
    }
}

func status(_ places: Steam.Places, _ options: Options) {
    let found = found(places, options)
    print("SteamVR: \(found.steamVR?.path ?? "not found (pass --steamvr DIR)")")
    if let source = SenseModel.findSource(found) {
        print("Sense controller models: available from \(source.path)")
    } else {
        print("Sense controller models: no installed copy found")
    }
    for name in [SenseModel.driverName, Install.driverName] {
        let driver = places.drivers.appendingPathComponent(name)
        let registered = found.externalDrivers.contains { $0.standardizedFileURL.path == driver.standardizedFileURL.path }
        let state: String
        switch (FileManager.default.fileExists(atPath: driver.path), registered) {
        case (true, true): state = "installed"
        case (true, false): state = "present but not registered with SteamVR"
        case (false, true): state = "registered with SteamVR but missing"
        case (false, false): state = "not installed"
        }
        print("\(name): \(state)")
    }
    if let vrlink = found.vrlink {
        print("Options in the VR Link settings tab: \(Install.vrlinkMenuPresent(inVRLink: vrlink) ? "yes" : "no")")
    }
    if let library = vrlinkLibrary(found) {
        print("Patches against \(library.path):")
        do { try check(library) } catch { print("  \(error)") }
    }
}

func installModels(_ places: Steam.Places, _ found: Steam.Found, _ options: Options) throws {
    let source: URL?
    if let folder = options.models {
        guard let located = SenseModel.locate(in: folder) else { throw Failure("\(folder.path) does not hold the Sense controller models") }
        source = located
    } else {
        source = SenseModel.findSource(found)
    }
    guard let source else {
        print("Sense controller models: no installed copy found, skipped.")
        print("  Install Sony's PlayStation VR2 App from Steam, or pass --models DIR with a folder")
        print("  holding playstation_vr2_sense_left and playstation_vr2_sense_right.")
        return
    }
    let driver = places.drivers.appendingPathComponent(SenseModel.driverName)
    for (model, kinds) in try SenseModel.build(from: source, to: driver) { print("\(model): \(kinds) kinds of input renamed") }
    try Steam.setExternalDriver(driver, present: true, in: places)
    // Remove any legacy `openvrlink_sense` folder created inside `SteamVR/drivers` by `tools/install-sense-model.ps1`.
    if let old = found.steamVR?.appendingPathComponent("drivers").appendingPathComponent(SenseModel.driverName),
       FileManager.default.fileExists(atPath: old.appendingPathComponent("driver.vrdrivermanifest").path) {
        do {
            try FileManager.default.removeItem(at: old)
            print("Removed legacy driver copy at \(old.path)")
        } catch {
            print("Could not remove legacy driver copy at \(old.path): \(error.localizedDescription)")
        }
    }
    print("Sense controller models from \(source.path)")
    print("  installed to \(driver.path)")
}

/// The driver library beside this program, with any other libraries built beside it
/// (the Swift runtime, when the driver is not linked statically).
func builtLibraries(_ options: Options) -> [URL]? {
    let name = Install.libraryPlace(windows: onWindows).name
    let folder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let candidates = [options.driver].compactMap { $0 } + [name, "lib" + name].map { folder.appendingPathComponent($0) }
    guard let library = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
    let beside = (try? FileManager.default.contentsOfDirectory(at: library.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    let runtime = beside.filter { ["dll", "so"].contains($0.pathExtension) && $0.lastPathComponent.lowercased().hasPrefix(onWindows ? "swift" : "libswift") }
    return [library] + runtime
}

func installPatches(_ places: Steam.Places, _ found: Steam.Found, _ options: Options) throws {
    guard let libraries = builtLibraries(options) else {
        print("VR Link extensions: \(Install.libraryPlace(windows: onWindows).name) was not found beside this program, skipped (pass --driver FILE).")
        return
    }
    let driver = places.drivers.appendingPathComponent(Install.driverName)
    try Install.writeDriver(to: driver, libraries: libraries, windows: onWindows, ownTab: options.ownTab)
    try Steam.setExternalDriver(driver, present: true, in: places)
    print("VR Link extension driver installed to \(driver.path)")
    if let vrlink = found.vrlink {
        do {
            try Install.setVRLinkMenu(present: !options.ownTab, inVRLink: vrlink)
            print(options.ownTab ? "Options are in SteamVR's settings under OpenVRLink." : "Options added to SteamVR's VR Link settings tab.")
        } catch {
            print("Could not update the VR Link settings schema (\(error)); pass --own-tab to install a separate OpenVRLink settings tab.")
        }
    }
    if let library = vrlinkLibrary(found) {
        print("Patches against the installed VR Link driver:")
        try check(library)
    }
}

func uninstall(_ places: Steam.Places, _ options: Options) throws {
    let found = found(places, options)
    for name in [SenseModel.driverName, Install.driverName] {
        let driver = places.drivers.appendingPathComponent(name)
        try Steam.setExternalDriver(driver, present: false, in: places)
        if FileManager.default.fileExists(atPath: driver.path) {
            try FileManager.default.removeItem(at: driver)
            print("Removed \(driver.path)")
        }
    }
    if let vrlink = found.vrlink, (try? Install.setVRLinkMenu(present: false, inVRLink: vrlink)) == true {
        print("Removed the options from the VR Link settings tab.")
    }
}

func patchShader(from: URL, to: URL) throws {
    let stock = try bytes(of: from)
    let patched: [UInt8]
    do {
        patched = try stock.withUnsafeBufferPointer { view in
            DXBC.container(view) != nil ? try DXBC.patchGamma(view) : try SPIRV.patchGamma(view).bytes
        }
    } catch {
        throw Failure("\(from.path): the shader was not patched (\(error))")
    }
    try Data(patched).write(to: to)
}

func run(_ arguments: [String]) throws {
    guard let command = arguments.first else { return print(usage, terminator: "") }
    let options = try Options(Array(arguments.dropFirst()))
    let places = Steam.Places.ofThisMachine()
    switch (command, options.rest.count) {
    case ("status", 0): status(places, options)
    case ("install", 0):
        let found = found(places, options)
        guard found.steamVR != nil else { throw Failure("SteamVR was not found; pass --steamvr DIR") }
        try installModels(places, found, options)
        if options.patches { try installPatches(places, found, options) }
        print("Restart SteamVR for the changes to take effect.")
    case ("uninstall", 0): try uninstall(places, options)
    case ("check", 1): try check(URL(fileURLWithPath: options.rest[0]))
    case ("patch-shader", 2): try patchShader(from: URL(fileURLWithPath: options.rest[0]), to: URL(fileURLWithPath: options.rest[1]))
    default:
        print(usage, terminator: "")
        throw Failure("unrecognized command")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
