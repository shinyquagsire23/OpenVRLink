// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Entry point for `openvrlink-companion`. Opens the Win32 GUI when launched without
// arguments on Windows, or runs the command-line interface otherwise.

import CompanionKit
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import PatchCore

let usage = """
    OpenVRLink companion \(Machine.version)

      openvrlink-companion status
          Show detected SteamVR paths and the status of each component.

      openvrlink-companion install [models] [driver] [options]
          Install or update the specified components (defaults to both):
            models   PlayStation VR2 Sense controller models for OpenVRLink
            driver   SteamVR driver that adds OpenVRLink extensions to VR Link
          Options:
            --steamvr DIR    Path to SteamVR if not detected automatically
            --models DIR     Copy Sense controller models from DIR
            --driver FILE    Path to driver_openvrlink binary (defaults to bundled copy)
            --own-tab        Place settings in a separate OpenVRLink tab instead of
                             modifying the VR Link settings tab

      openvrlink-companion uninstall [models] [driver]
          Uninstall the specified components (defaults to both) and clean up settings.

      openvrlink-companion update [--check]
          Update openvrlink-companion from GitHub releases, or pass --check to only
          check whether a newer version is available.

      openvrlink-companion check FILE
          Report which patches apply to a driver_vrlink.dll or driver_vrlink.so binary.

      openvrlink-companion patch-shader IN OUT
          Write a gamma-patched copy of a VR Link encode shader (.spv or .fxo).

    """

struct Options {
    var steamVR: URL?, models: URL?, driver: URL?, version: String?, snapshot: URL?
    var ownTab: Bool?, checkOnly = false
    var rest: [String] = []

    init(_ arguments: [String]) throws {
        var arguments = arguments[...]
        while let argument = arguments.popFirst() {
            func value() throws -> String {
                guard let value = arguments.popFirst() else { throw Failure("\(argument) needs a value") }
                return value
            }
            switch argument {
            case "--steamvr": steamVR = URL(fileURLWithPath: try value())
            case "--models": models = URL(fileURLWithPath: try value())
            case "--driver": driver = URL(fileURLWithPath: try value())
            case "--snapshot": snapshot = URL(fileURLWithPath: try value())
            case "--version": version = try value()
            case "--own-tab": ownTab = true
            case "--check": checkOnly = true
            case _ where argument.hasPrefix("--"): throw Failure("unknown option \(argument)")
            default: rest.append(argument)
            }
        }
    }
}

/// Builds a `Setup` from detected host paths and CLI option overrides.
func makeSetup(_ options: Options = try! Options([])) throws -> Setup {
    let places = Steam.Places.ofThisMachine()
    var found = Steam.find(places)
    if let steamVR = options.steamVR { found.steamVR = steamVR }
    var setup = Setup(places: places, found: found, windows: onWindows)
    if let carried = try Machine.driverLibrary(named: options.driver) {
        setup.driverLibrary = carried.library
        setup.besideDriver = carried.beside
    }
    setup.modelsFolder = options.models
    setup.ownTab = options.ownTab
    return setup
}

func bytes(of file: URL) throws -> [UInt8] {
    do { return [UInt8](try Data(contentsOf: file)) } catch { throw Failure("\(file.path): \(OS.describe(error))") }
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
            let name = "\(target.name)".padded(to: 22)
            switch resolution {
            case .found(let found): print("  \(name)found, \(found.sites.count) call site(s)")
            case .missing(let missing): print("  \(name)\(describe(missing))")
            }
        }
        if Scan.isPE(view) {
            let slot = Scan.peImportSlot(view, mapped: false, library: Scan.shaderReadImport.library, function: Scan.shaderReadImport.function)
            print("  \("shader-read import".padded(to: 22))\(slot == nil ? "not found" : "found")")
        }
    }
}

func status(_ setup: Setup) {
    print("SteamVR: \(setup.found.steamVR.map { Steam.nativePath($0) } ?? "not found (pass --steamvr DIR)")")
    for component in Component.allCases {
        let state = setup.state(of: component)
        print("\(component.title): \(state.detail)\(state.action.map { " [\($0.lowercased()) available]" } ?? "")")
    }
    if let library = setup.vrlinkLibrary {
        print("Patches against \(Steam.nativePath(library)):")
        do { try check(library) } catch { print("  \(error)") }
    }
}

func components(_ names: [String]) throws -> [Component] {
    if names.isEmpty { return Component.allCases }
    return try names.map { name in
        guard let component = Component(rawValue: name) else { throw Failure("\(name) is not a component (models, driver)") }
        return component
    }
}

func update(checkOnly: Bool) throws {
    guard let offer = try Updater.check() else { return print("openvrlink-companion \(Machine.version) is already up to date.") }
    print("Version \(offer.version) is available (current: \(Machine.version)).")
    if checkOnly { return }
    let staged = try Updater.fetch(offer)
    try Updater.finish(staged)
    print("Updated \(Steam.nativePath(Machine.executable)) to \(offer.version).")
    print("Run `openvrlink-companion install` to update installed SteamVR components.")
}

func patchShader(from: URL, to: URL) throws {
    let stock = try bytes(of: from)
    let patched: [UInt8]
    do {
        patched = try stock.withUnsafeBufferPointer { view in
            DXBC.container(view) != nil ? try DXBC.patchGamma(view) : try SPIRV.patchGamma(view).bytes
        }
    } catch {
        throw Failure("\(from.path): failed to patch shader (\(error))")
    }
    try Data(patched).write(to: to)
}

func run(_ arguments: [String]) throws {
    guard let command = arguments.first else {
        #if os(Windows)
        return try runWindow(snapshot: nil)
        #else
        return print(usage, terminator: "")
        #endif
    }
    #if os(Windows)
    Console.attach()
    #endif
    let options = try Options(Array(arguments.dropFirst()))
    switch (command, options.rest.count) {
    case ("version", 0), ("--version", 0): print(Machine.version)
    case ("status", 0): status(try makeSetup(options))
    case ("install", _):
        let setup = try makeSetup(options)
        setup.clearLeftovers()
        for component in try components(options.rest) {
            // Fail if an explicitly requested component is unavailable; when installing all
            // components by default, skip unavailable ones with a notice.
            let state = setup.state(of: component)
            if options.rest.isEmpty, state.kind == .unavailable, setup.found.steamVR != nil {
                print("\(component.title): skipped. \(state.detail)")
                continue
            }
            for line in try setup.install(component) { print(line) }
        }
        print("Restart SteamVR for the changes to take effect.")
    case ("uninstall", _):
        let setup = try makeSetup(options)
        setup.clearLeftovers()
        for component in try components(options.rest) {
            for line in try setup.uninstall(component) { print(line) }
        }
    case ("update", 0):
        Updater.clearLeftovers(patiently: false)
        try update(checkOnly: options.checkOnly)
    case ("check", 1): try check(URL(fileURLWithPath: options.rest[0]))
    case ("patch-shader", 2): try patchShader(from: URL(fileURLWithPath: options.rest[0]), to: URL(fileURLWithPath: options.rest[1]))
    #if os(Windows)
    case ("window", 0), ("after-update", 0): try runWindow(snapshot: options.snapshot, afterUpdate: command == "after-update")
    case ("pack", 1):
        guard let driver = options.driver else { throw Failure("pack needs --driver FILE") }
        try pack(to: URL(fileURLWithPath: options.rest[0]), driver: driver, version: options.version)
    #else
    case ("after-update", 0): Updater.clearLeftovers(patiently: true)
    #endif
    default:
        print(usage, terminator: "")
        throw Failure("unrecognized command")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    OS.printError("error: \(error)")
    OS.quit(1)
}
