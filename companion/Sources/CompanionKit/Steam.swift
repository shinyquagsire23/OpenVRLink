// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Locates Steam libraries and the SteamVR runtime, and updates the external driver list
/// in `openvrpaths.vrpath` (the same registry file managed by `vrpathreg adddriver`).
public enum Steam {
    /// Filesystem locations to search. Use `Places.ofThisMachine()` on a real host, or
    /// construct directly in tests.
    public struct Places {
        /// Folder holding `openvrpaths.vrpath`.
        public var openVRConfig: URL
        /// Folders that may be a Steam installation.
        public var steamRoots: [URL]
        /// Folder the companion keeps its own drivers in.
        public var data: URL

        public init(openVRConfig: URL, steamRoots: [URL], data: URL) {
            self.openVRConfig = openVRConfig
            self.steamRoots = steamRoots
            self.data = data
        }

        public var openVRPathsFile: URL { openVRConfig.appendingPathComponent("openvrpaths.vrpath") }
        public var drivers: URL { data.appendingPathComponent("drivers") }

        public static func ofThisMachine() -> Places {
            let environment = ProcessInfo.processInfo.environment
            func folder(_ variable: String) -> URL? {
                environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            }
            #if os(Windows)
            let local = folder("LOCALAPPDATA") ?? URL(fileURLWithPath: ".")
            var roots = [steamPathFromRegistry()].compactMap { $0 }
            roots += ["ProgramFiles(x86)", "ProgramFiles"].compactMap { folder($0)?.appendingPathComponent("Steam") }
            return Places(openVRConfig: local.appendingPathComponent("openvr"), steamRoots: roots, data: local.appendingPathComponent("OpenVRLink"))
            #else
            var home = folder("HOME") ?? URL(fileURLWithPath: ".")
            // The Steam snap runs with its own home folder and cannot see hidden folders in
            // the real one, so SteamVR's configuration and our drivers both belong inside it.
            let snap = home.appendingPathComponent("snap/steam/common")
            if isFolder(snap.appendingPathComponent(".local/share/Steam/steamapps")) { home = snap }
            let roots = [".steam/steam", ".steam/root", ".local/share/Steam", ".steam/debian-installation",
                         ".var/app/com.valvesoftware.Steam/.local/share/Steam", "snap/steam/common/.local/share/Steam"]
                .map { home.appendingPathComponent($0) }
            let inSnap = home.path == snap.path
            return Places(openVRConfig: ((inSnap ? nil : folder("XDG_CONFIG_HOME")) ?? home.appendingPathComponent(".config")).appendingPathComponent("openvr"),
                          steamRoots: roots,
                          data: ((inSnap ? nil : folder("XDG_DATA_HOME")) ?? home.appendingPathComponent(".local/share")).appendingPathComponent("openvrlink"))
            #endif
        }

        #if os(Windows)
        private static func steamPathFromRegistry() -> URL? {
            let query = Process()
            let output = Pipe()
            query.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\reg.exe")
            query.arguments = ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"]
            query.standardOutput = output
            query.standardError = Pipe()
            guard (try? query.run()) != nil else { return nil }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            query.waitUntilExit()
            guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("SteamPath") }),
                  let range = line.range(of: "REG_SZ") else { return nil }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        }
        #endif
    }

    /// What was found on this machine.
    public struct Found {
        /// Steam libraries (folders with a `steamapps` inside).
        public var libraries: [URL] = []
        /// The SteamVR runtime folder (the one containing `drivers`).
        public var steamVR: URL?
        /// External drivers registered with SteamVR.
        public var externalDrivers: [URL] = []

        public init(libraries: [URL] = [], steamVR: URL? = nil, externalDrivers: [URL] = []) {
            self.libraries = libraries
            self.steamVR = steamVR
            self.externalDrivers = externalDrivers
        }

        /// The VR Link driver's folder inside the runtime.
        public var vrlink: URL? { steamVR?.appendingPathComponent("drivers").appendingPathComponent("vrlink") }
    }

    static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && !folder.boolValue
    }

    /// The path as this system writes it (backslashes on Windows), for files other programs read.
    public static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    /// Whether two paths name the same place, however they are spelled.
    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            #if os(Windows)
            return path.lowercased().replacingOccurrences(of: "\\", with: "/")
            #else
            return path
            #endif
        }
        return canonical(a) == canonical(b)
    }

    /// The `"path"` values in a `libraryfolders.vdf`.
    public static func libraryPaths(inVDF vdf: String) -> [String] {
        var tokens: [String] = []
        var characters = vdf.makeIterator()
        while let character = characters.next() {
            guard character == "\"" else { continue }
            var token = ""
            while let character = characters.next(), character != "\"" {
                if character == "\\" { if let escaped = characters.next() { token.append(escaped) } } else { token.append(character) }
            }
            tokens.append(token)
        }
        return zip(tokens, tokens.dropFirst()).filter { $0.0 == "path" }.map(\.1)
    }

    private static func openVRPaths(_ places: Places) -> JSON? {
        (try? String(contentsOf: places.openVRPathsFile, encoding: .utf8)).flatMap { try? JSON(parsing: $0) }
    }

    private static func folders(_ value: JSON?) -> [URL] {
        (value?.array ?? []).compactMap(\.string).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func find(_ places: Places) -> Found {
        var found = Found()
        func add(_ library: URL) {
            guard isFolder(library.appendingPathComponent("steamapps")), !found.libraries.contains(where: { samePlace($0, library) }) else { return }
            found.libraries.append(library)
        }
        for root in places.steamRoots where isFolder(root.appendingPathComponent("steamapps")) {
            add(root)
            for list in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
                guard let text = try? String(contentsOf: root.appendingPathComponent(list), encoding: .utf8) else { continue }
                for path in libraryPaths(inVDF: text) { add(URL(fileURLWithPath: path, isDirectory: true)) }
            }
        }
        let paths = openVRPaths(places)
        found.externalDrivers = folders(paths?["external_drivers"])
        let installed = found.libraries.map { $0.appendingPathComponent("steamapps/common/SteamVR") }
        found.steamVR = (folders(paths?["runtime"]) + installed).first { isFolder($0.appendingPathComponent("drivers")) }
        return found
    }

    /// Adds or removes a folder in SteamVR's external driver list. Returns whether the
    /// file changed. The file is created if SteamVR has not yet made it.
    @discardableResult
    public static func setExternalDriver(_ driver: URL, present: Bool, in places: Places) throws -> Bool {
        let file = places.openVRPathsFile
        var paths: JSON
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            paths = try JSON(parsing: text)
        } else if present {
            paths = .object([])
        } else {
            return false
        }
        guard case .object = paths else { throw JSON.ParseError(description: "\(file.path) is not a JSON object") }
        let before = paths["external_drivers"]?.array ?? []
        var list = before.filter { entry in !(entry.string.map { samePlace(URL(fileURLWithPath: $0), driver) } ?? false) }
        let wasPresent = list.count != before.count
        guard wasPresent != present else { return false }
        if present { list.append(.string(nativePath(driver))) }
        paths["external_drivers"] = .array(list)
        try FileManager.default.createDirectory(at: places.openVRConfig, withIntermediateDirectories: true)
        try paths.text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }
}
