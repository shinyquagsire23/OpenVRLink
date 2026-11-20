// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Executable metadata, bundled driver discovery, HTTPS downloads, and self-update helpers
// shared by the CLI and Windows GUI.

import CompanionKit
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if os(Windows)
import WinAPI
import WinSDK
#endif

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

#if os(Windows)
let onWindows = true
#else
let onWindows = false
#endif

enum Machine {
    /// Path to the running `openvrlink-companion` executable.
    static let executable: URL = {
        #if os(Windows)
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        if length > 0 { return URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF16.self)) }
        return URL(fileURLWithPath: CommandLine.arguments[0])
        #else
        return URL(fileURLWithPath: OS.executablePath() ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        #endif
    }()

    #if os(Windows)
    /// Loads an `RT_RCDATA` resource embedded in the executable by `pack`.
    static func resource(_ name: String) -> Data? {
        guard let found = FindResourceW(nil, name.wide, UnsafePointer<WCHAR>(bitPattern: 10 /* RT_RCDATA */)),
              let loaded = LoadResource(nil, found), let bytes = LockResource(loaded) else { return nil }
        return Data(bytes: bytes, count: Int(SizeofResource(nil, found)))
    }
    #endif

    /// Build version string, reading the embedded `VERSION` resource if stamped by `pack --version`
    /// or falling back to `Release.sourceVersion`.
    static let version: String = {
        #if os(Windows)
        if let stamped = resource("VERSION"), let text = String(data: stamped, encoding: .utf8), !text.isEmpty { return text }
        #endif
        return Release.sourceVersion
    }()

    /// Loads `driver_openvrlink` from `explicit`, from the embedded `DRIVER` resource on
    /// Windows, or from sibling/package directories (`../lib/openvrlink`, `../share/openvrlink`).
    static func driverLibrary(named explicit: URL?) throws -> (library: Data, beside: [URL])? {
        let name = Install.libraryPlace(windows: onWindows).name
        if let explicit {
            do { return (try Data(contentsOf: explicit), runtimeLibraries(beside: explicit)) } catch { throw Failure("\(explicit.path): \(OS.describe(error))") }
        }
        #if os(Windows)
        if let packed = resource("DRIVER") { return (packed, []) }
        #endif
        let folder = executable.deletingLastPathComponent()
        let candidates = [name, "lib" + name, "../lib/openvrlink/" + name, "../share/openvrlink/" + name].map { folder.appendingPathComponent($0).standardizedFileURL }
        for file in candidates {
            if let data = try? Data(contentsOf: file) { return (data, runtimeLibraries(beside: file)) }
        }
        return nil
    }

    /// Finds Swift runtime libraries next to `library` for dynamically linked builds.
    private static func runtimeLibraries(beside library: URL) -> [URL] {
        let beside = (try? OS.entries(in: library.deletingLastPathComponent())) ?? []
        return beside.filter { ["dll", "so"].contains($0.pathExtension) && $0.lastPathComponent.lowercased().hasPrefix(onWindows ? "swift" : "libswift") }
    }

    /// Runs `program` and returns its stdout when it exits with status 0, or `nil` on failure.
    static func output(of program: URL, _ arguments: [String]) -> String? {
        guard let ran = OS.run(Steam.nativePath(program), arguments), ran.status == 0 else { return nil }
        return ran.output
    }
}

/// Downloads URLs over HTTPS using WinHTTP on Windows and `curl` on Linux/macOS so
/// `openvrlink-companion` does not need to link an external HTTP library.
enum Web {
    static let agent = "openvrlink-companion"

    /// Optional local JSON path (`OVRL_RELEASE_LIST`) used to test self-updates without
    /// querying GitHub; when set, asset URLs may also be local file paths.
    static let rehearsalList = ProcessInfo.processInfo.environment["OVRL_RELEASE_LIST"].flatMap { $0.isEmpty ? nil : $0 }

    /// Downloads `address` over HTTPS, invoking `progress` with `(bytesRead, totalBytes)` as data arrives.
    static func get(_ address: String, progress: ((Int, Int?) -> Void)? = nil) throws -> Data {
        if rehearsalList != nil, !address.hasPrefix("https://") {
            let body = try Data(contentsOf: URL(fileURLWithPath: address))
            progress?(body.count, body.count)
            return body
        }
        guard let url = URL(string: address), url.scheme == "https", let host = url.host else { throw Failure("\(address) is not an https address") }
        #if os(Windows)
        func failed(_ step: String) -> Failure { Failure("\(host): \(step) failed (error \(GetLastError()))") }
        guard let session = WinHttpOpen(agent.wide, 4 /* WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY */, nil, nil, 0) else { throw failed("WinHTTP initialization") }
        defer { WinHttpCloseHandle(session) }
        guard let connection = WinHttpConnect(session, host.wide, INTERNET_PORT(url.port ?? 443), 0) else { throw failed("connection") }
        defer { WinHttpCloseHandle(connection) }
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        guard let request = WinHttpOpenRequest(connection, "GET".wide, path.wide, nil, nil, nil, DWORD(WINHTTP_FLAG_SECURE)) else { throw failed("HTTP request") }
        defer { WinHttpCloseHandle(request) }
        guard WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0), WinHttpReceiveResponse(request, nil) else { throw failed("HTTP request") }
        func number(_ header: Int32) -> Int? {
            var value: DWORD = 0, size = DWORD(MemoryLayout<DWORD>.size)
            return WinHttpQueryHeaders(request, DWORD(header) | DWORD(WINHTTP_QUERY_FLAG_NUMBER), nil, &value, &size, nil) ? Int(value) : nil
        }
        let status = number(WINHTTP_QUERY_STATUS_CODE) ?? 0
        guard status == 200 else { throw Failure("\(host) returned HTTP \(status)") }
        let total = number(WINHTTP_QUERY_CONTENT_LENGTH)
        var body = Data(), chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            var read: DWORD = 0
            guard WinHttpReadData(request, &chunk, DWORD(chunk.count), &read) else { throw failed("reading response") }
            if read == 0 { break }
            body.append(contentsOf: chunk[..<Int(read)])
            progress?(body.count, total)
        }
        if let total, body.count != total { throw Failure("\(host): download truncated") }
        return body
        #else
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ovrl-get-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--user-agent", agent, "--output", file.path, address]
        guard let curl = OS.run("curl", arguments, searching: true, mergingErrors: true) else { throw Failure("could not run curl to download from \(host)") }
        guard curl.status == 0 else { throw Failure(curl.output.trimmed.isEmpty ? "curl failed while downloading from \(host)" : curl.output.trimmed) }
        let body = try Data(contentsOf: file)
        progress?(body.count, body.count)
        return body
        #endif
    }
}

/// Checks for, downloads, stages, and applies `openvrlink-companion` updates.
enum Updater {
    static func check() throws -> Release.Offer? {
        try Release.update(from: Machine.version, windows: onWindows, allowingFiles: Web.rehearsalList != nil) {
            try Web.rehearsalList.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? Web.get($0)
        }
    }

    /// Downloads `offer`, stages the new binary (and `driver_openvrlink.so` on Linux) next
    /// to the current executable, and verifies that `openvrlink-companion version` reports
    /// `offer.version`.
    static func fetch(_ offer: Release.Offer, progress: ((Int, Int?) -> Void)? = nil) throws -> [(staged: URL, target: URL)] {
        let download = try Web.get(offer.url, progress: progress)
        let folder = Machine.executable.deletingLastPathComponent()
        var staged: [(staged: URL, target: URL)] = []
        do {
            if onWindows {
                guard SelfUpdate.looksRunnable(download, windows: true) else { throw Failure("downloaded file is not a valid Windows executable") }
                staged.append((try SelfUpdate.stage(download, beside: Machine.executable), Machine.executable))
            } else {
                // Extract openvrlink-companion and driver_openvrlink.so from the Linux release tarball.
                let unpacked = folder.appendingPathComponent(".ovrl-update-\(UUID().uuidString.prefix(8))")
                do { try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false) } catch {
                    throw Failure("cannot write to \(folder.path) (\(OS.describe(error))); if openvrlink-companion was installed via a package manager, update it there")
                }
                defer { try? FileManager.default.removeItem(at: unpacked) }
                let archive = unpacked.appendingPathComponent("release.tar.gz")
                try download.write(to: archive)
                guard OS.run("tar", ["-xzf", archive.path, "-C", unpacked.path], searching: true)?.status == 0 else { throw Failure("could not extract the release archive with tar") }
                func find(_ name: String) -> Data? {
                    return OS.files(below: unpacked).first { $0.lastPathComponent == name }.flatMap { try? Data(contentsOf: $0) }
                }
                guard let program = find("openvrlink-companion"), SelfUpdate.looksRunnable(program, windows: false) else { throw Failure("release archive does not contain a valid openvrlink-companion binary") }
                staged.append((try SelfUpdate.stage(program, beside: Machine.executable), Machine.executable))
                let library = Install.libraryPlace(windows: false).name
                if let driver = find(library) {
                    let target = folder.appendingPathComponent(library)
                    staged.append((try SelfUpdate.stage(driver, beside: target), target))
                }
            }
            let said = Machine.output(of: staged[0].staged, ["version"])?.trimmed
            guard said == offer.version else { throw Failure("downloaded binary failed verification (expected version \(offer.version))") }
        } catch {
            for file in staged { try? FileManager.default.removeItem(at: file.staged) }
            throw error
        }
        return staged
    }

    /// Swaps all staged update files into their target paths.
    static func finish(_ staged: [(staged: URL, target: URL)]) throws {
        for file in staged { try SelfUpdate.swap(file.staged, into: file.target) }
    }

    /// Launches the newly installed `openvrlink-companion` binary.
    static func relaunch() {
        OS.launch(Steam.nativePath(Machine.executable), ["after-update"])
    }

    /// Removes leftover `.old-*` binaries from a previous update, retrying briefly if
    /// `patiently` is true while the old process exits.
    static func clearLeftovers(patiently: Bool) {
        for attempt in 0..<(patiently ? 10 : 1) {
            if attempt > 0 { OS.sleep(milliseconds: 200) }
            if SelfUpdate.clearLeftovers(beside: Machine.executable) { return }
        }
    }
}
