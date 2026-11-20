// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if os(Windows)
import WinSDK
#endif

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

        /// A candidate Steam installation root and its associated config and data directories.
        /// Sandboxed Linux builds of Steam (Snap and Flatpak) run with private home directories
        /// and cannot read hidden directories in `$HOME`, so `openvrpaths.vrpath` and installed
        /// drivers must be placed inside that sandbox's directories.
        public struct Installation {
            public var root: URL
            /// Candidate config directories that may contain `openvr/openvrpaths.vrpath`, ordered by priority.
            public var configHomes: [URL]
            /// Base data directory where OpenVRLink installs its drivers.
            public var dataHome: URL
        }

        /// Returns candidate Linux Steam installations for `home` and `environment`, checking
        /// native Steam paths first, followed by the Snap and Flatpak sandboxes.
        public static func linuxInstallations(home: URL, environment: [String: String]) -> [Installation] {
            func folder(_ variable: String) -> URL? {
                environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            }
            let dataHome = folder("XDG_DATA_HOME") ?? home.appendingPathComponent(".local/share")
            let configHome = folder("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")
            var list: [Installation] = []
            let native = [dataHome.appendingPathComponent("Steam")]
                + [".local/share/Steam", ".steam/steam", ".steam/root", ".steam/debian-installation"].map { home.appendingPathComponent($0) }
            for root in native { list.append(Installation(root: root, configHomes: [configHome], dataHome: dataHome)) }
            let snap = home.appendingPathComponent("snap/steam/common")
            list.append(Installation(root: snap.appendingPathComponent(".local/share/Steam"),
                                     configHomes: [snap.appendingPathComponent(".config")], dataHome: snap.appendingPathComponent(".local/share")))
            let flatpak = home.appendingPathComponent(".var/app/com.valvesoftware.Steam")
            for root in [".local/share/Steam", "data/Steam"] {
                list.append(Installation(root: flatpak.appendingPathComponent(root),
                                         configHomes: [flatpak.appendingPathComponent(".config"), flatpak.appendingPathComponent("config")],
                                         dataHome: flatpak.appendingPathComponent(".local/share")))
            }
            return list
        }

        /// Selects the active Steam installation for OpenVR config and driver storage while
        /// keeping all candidate Steam roots for library discovery. Prefers the first
        /// installation with SteamVR installed, falling back to the first with an existing
        /// `openvrpaths.vrpath`, the first existing Steam root, or the first candidate.
        public static func choosing(among installations: [Installation], dataFolder: String) -> Places {
            precondition(!installations.isEmpty)
            func exists(_ installation: Installation) -> Bool { isFolder(installation.root.appendingPathComponent("steamapps")) }
            func config(_ installation: Installation) -> URL? {
                installation.configHomes.first { isFile($0.appendingPathComponent("openvr/openvrpaths.vrpath")) }
            }
            func hasSteamVR(_ installation: Installation) -> Bool {
                libraries(ofRoot: installation.root).contains { isFolder($0.appendingPathComponent("steamapps/common/SteamVR/drivers")) }
            }
            let present = installations.filter(exists)
            let chosen = present.first(where: hasSteamVR) ?? present.first { config($0) != nil } ?? present.first ?? installations[0]
            return Places(openVRConfig: (config(chosen) ?? chosen.configHomes[0]).appendingPathComponent("openvr"),
                          steamRoots: installations.map(\.root),
                          data: chosen.dataHome.appendingPathComponent(dataFolder))
        }

        public static func ofThisMachine() -> Places {
            let environment = ProcessInfo.processInfo.environment
            func folder(_ variable: String) -> URL? {
                environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            }
            #if os(Windows)
            let local = folder("LOCALAPPDATA") ?? URL(fileURLWithPath: ".")
            var roots = [registryFolder(HKEY_CURRENT_USER, "Software\\Valve\\Steam", "SteamPath"),
                         registryFolder(HKEY_LOCAL_MACHINE, "SOFTWARE\\Valve\\Steam", "InstallPath")].compactMap { $0 }
            roots += ["ProgramFiles(x86)", "ProgramFiles"].compactMap { folder($0)?.appendingPathComponent("Steam") }
            return Places(openVRConfig: local.appendingPathComponent("openvr"), steamRoots: roots, data: local.appendingPathComponent("OpenVRLink"))
            #else
            let home = folder("HOME") ?? URL(fileURLWithPath: ".")
            return choosing(among: linuxInstallations(home: home, environment: environment), dataFolder: "openvrlink")
            #endif
        }

        #if os(Windows)
        /// Reads a directory path from a `REG_SZ` registry value, checking both 64-bit and 32-bit registry views.
        private static func registryFolder(_ root: HKEY, _ key: String, _ value: String) -> URL? {
            for view in [RRF_SUBKEY_WOW6464KEY, RRF_SUBKEY_WOW6432KEY] {
                var buffer = [WCHAR](repeating: 0, count: 1024)
                var size = DWORD(buffer.count * MemoryLayout<WCHAR>.size)
                let status = key.withCString(encodedAs: UTF16.self) { key in
                    value.withCString(encodedAs: UTF16.self) { value in
                        RegGetValueW(root, key, value, DWORD(RRF_RT_REG_SZ) | DWORD(view), nil, &buffer, &size)
                    }
                }
                guard status == ERROR_SUCCESS else { continue }
                let text = String(decodingCString: buffer, as: UTF16.self)
                if !text.isEmpty { return URL(fileURLWithPath: text, isDirectory: true) }
            }
            return nil
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

    static func isFolder(_ url: URL) -> Bool { OS.isFolder(url.path) }

    static func isFile(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) && !OS.isFolder(url.path) }

    /// The path as this system writes it (backslashes on Windows), for files other programs read.
    public static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    /// Whether two paths name the same place, however they are spelled.
    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            #if os(Windows)
            return path.lowercased().replacing("\\", with: "/")
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

    /// Returns all existing Steam library folders for `root` (starting with `root` itself),
    /// or an empty array if `root` does not contain `steamapps`.
    static func libraries(ofRoot root: URL) -> [URL] {
        guard isFolder(root.appendingPathComponent("steamapps")) else { return [] }
        var libraries = [root]
        for list in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(list), encoding: .utf8) else { continue }
            libraries += libraryPaths(inVDF: text).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return libraries.filter { isFolder($0.appendingPathComponent("steamapps")) }
    }

    public static func find(_ places: Places) -> Found {
        var found = Found()
        for root in places.steamRoots {
            for library in libraries(ofRoot: root) where !found.libraries.contains(where: { samePlace($0, library) }) {
                found.libraries.append(library)
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
