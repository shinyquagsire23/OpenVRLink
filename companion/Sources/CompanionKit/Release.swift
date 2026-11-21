// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Version comparison and GitHub release lookup for `openvrlink-companion` self-updates.
///
/// Queries GitHub releases in the OpenVRLink repository (tagged e.g. `v0.1.0-8`) and looks
/// for a platform-matching asset: `openvrlink-companion-windows-x86_64.exe` on Windows or
/// `openvrlink-companion-linux-<arch>.tar.gz` on Linux.
public enum Release {
    /// Fallback version string (`<version>-<build>`) used when no `VERSION` resource is stamped
    /// by `pack --version`. Keep this in sync with `version.json` at the repository root
    /// (verified by `ReleaseTests`).
    public static let sourceVersion = "0.1.0-8"
    public static let repository = "shinyquagsire23/OpenVRLink"
    public static var listURL: String { "https://api.github.com/repos/\(repository)/releases?per_page=20" }

    /// Parses the numeric components of a version tag (for example, `"v0.1.0-8"` -> `[0, 1, 0, 8]`).
    public static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    public static func isNewer(_ version: String, than current: String) -> Bool {
        let a = numbers(version), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func assetName(windows: Bool, architecture: String) -> String {
        windows ? "openvrlink-companion-windows-\(architecture).exe" : "openvrlink-companion-linux-\(architecture).tar.gz"
    }

    public static var thisArchitecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }

    public struct Offer: Equatable {
        public var version: String
        public var url: String
        public var size: Int?
    }

    /// Finds the highest-versioned non-draft, non-prerelease entry in a GitHub releases JSON
    /// array that includes `asset`. Returns `nil` if no matching release is found.
    public static func newest(inReleaseList text: String, asset: String, allowingFiles: Bool = false) throws -> Offer? {
        guard let releases = try JSON(parsing: text).array else { throw JSON.ParseError(description: "release list JSON is not an array") }
        var best: Offer?
        for release in releases where release["draft"] != .bool(true) && release["prerelease"] != .bool(true) {
            guard let tag = release["tag_name"]?.string,
                  let file = release["assets"]?.array?.first(where: { $0["name"]?.string == asset }),
                  let url = file["browser_download_url"]?.string, url.hasPrefix("https://") || allowingFiles else { continue }
            if best.map({ isNewer(tag, than: $0.version) }) ?? true {
                best = Offer(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url, size: file["size"]?.number.flatMap { Int($0) })
            }
        }
        return best
    }

    /// Fetches the release list via `get` and returns an `Offer` if a release newer than `current` is available.
    public static func update(from current: String, windows: Bool, allowingFiles: Bool = false, get: (String) throws -> Data) throws -> Offer? {
        let list = String(decoding: try get(listURL), as: UTF8.self)
        guard let offer = try newest(inReleaseList: list, asset: assetName(windows: windows, architecture: thisArchitecture), allowingFiles: allowingFiles),
              isNewer(offer.version, than: current) else { return nil }
        return offer
    }
}

/// Stages and swaps a new executable in place of the currently running binary.
///
/// Windows prevents overwriting a running `.exe` but allows renaming it. `swap` renames the
/// active binary to `<name>.old-<id>` and moves the staged binary to `<name>`; the next
/// launch calls `clearLeftovers` to delete any leftover `.old-*` files.
public enum SelfUpdate {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Builds a sibling path named `<stem>.<mark>-<id>[.<extension>]`, preserving `.exe` so
    /// staged binaries can be executed on Windows before swapping.
    static func sibling(of file: URL, mark: String) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        return file.deletingLastPathComponent().appendingPathComponent("\(stem).\(mark)-\(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : "." + ext)")
    }

    /// Checks that `data` has a valid PE or ELF header and a plausible size.
    public static func looksRunnable(_ data: Data, windows: Bool) -> Bool {
        let head = [UInt8](data.prefix(4))
        return data.count > 4096 && (windows ? head.starts(with: [0x4D, 0x5A]) : head == [0x7F, 0x45, 0x4C, 0x46])
    }

    /// Writes `replacement` to a temporary `.new-*` file next to `file` so it can be verified
    /// before replacing `file`.
    public static func stage(_ replacement: Data, beside file: URL) throws -> URL {
        let staged = sibling(of: file, mark: "new")
        do {
            try replacement.write(to: staged)
            #if !os(Windows)
            OS.makeExecutable(staged.path)
            #endif
        } catch {
            throw Failure(description: "cannot write to \(file.deletingLastPathComponent().path) (\(OS.describe(error))); move openvrlink-companion to a writable folder or update it through your package manager")
        }
        return staged
    }

    /// Replaces `file` with `staged`, moving any existing file to `<stem>.old-<id>` first.
    public static func swap(_ staged: URL, into file: URL) throws {
        let files = FileManager.default
        let old = sibling(of: file, mark: "old")
        let existed = files.fileExists(atPath: file.path)
        do {
            if existed { try files.moveItem(at: file, to: old) }
            do {
                try files.moveItem(at: staged, to: file)
            } catch {
                if existed { try? files.moveItem(at: old, to: file) }
                throw error
            }
        } catch {
            try? files.removeItem(at: staged)
            throw Failure(description: "could not replace \(file.path): \(OS.describe(error))")
        }
        // On non-Windows platforms the unlinked binary can be deleted immediately.
        try? files.removeItem(at: old)
    }

    /// Deletes leftover `.old-*` and `.new-*` files next to `file`. Returns `true` if all
    /// temporary files were removed (`false` if a previous process is still exiting on Windows).
    @discardableResult
    public static func clearLeftovers(beside file: URL) -> Bool {
        let files = FileManager.default
        let stem = file.deletingPathExtension().lastPathComponent
        var clear = true
        for entry in (try? OS.entries(in: file.deletingLastPathComponent())) ?? [] {
            let name = entry.lastPathComponent
            guard name.hasPrefix(stem + ".old-") || name.hasPrefix(stem + ".new-") else { continue }
            if (try? files.removeItem(at: entry)) == nil { clear = false }
        }
        return clear
    }
}
