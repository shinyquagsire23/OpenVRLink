// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Lightweight Win32 and POSIX wrappers for process execution, directory traversal, error
// formatting, and string utilities so `openvrlink-companion` only needs `FoundationEssentials`.
//
// Importing full `Foundation` statically links ICU's 34 MB Unicode data table into the
// binary. On macOS (used to run unit tests), `FoundationEssentials` is not exposed as a
// separate module, so `Foundation` is imported instead.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if os(Windows)
import WinSDK
import CRT
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

extension String {
    /// Returns the string with leading and trailing whitespace and newlines removed.
    public var trimmed: String {
        var view = self[...]
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }

    /// Truncates or right-pads the string with spaces to `length` characters.
    public func padded(to length: Int) -> String {
        count >= length ? String(prefix(length)) : self + String(repeating: " ", count: length - count)
    }

    #if os(Windows)
    /// Null-terminated UTF-16 code units for Win32 wide-string APIs.
    public var wide: [UInt16] { Array(utf16) + [0] }
    #endif
}

public enum OS {
    /// Formats `error` as a concise message without relying on Foundation's localized error tables.
    public static func describe(_ error: Error) -> String {
        if let error = error as? CocoaError {
            switch error.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return "file not found"
            case .fileReadNoPermission, .fileWriteNoPermission: return "permission denied"
            case .fileWriteOutOfSpace: return "disk is full"
            case .fileWriteFileExists: return "file already exists"
            case .fileWriteVolumeReadOnly: return "volume is read-only"
            default: return "file error \(error.code.rawValue)"
            }
        }
        return "\(error)"
    }

    public static func isFolder(_ path: String) -> Bool {
        #if canImport(FoundationEssentials)
        var folder = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder
        #else
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
        #endif
    }

    /// Lists the direct contents of `folder` as URLs.
    public static func entries(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).map { folder.appendingPathComponent($0) }
    }

    /// Recursively lists all regular files under `folder`.
    public static func files(below folder: URL) -> [URL] {
        var files: [URL] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let entry = folder.appendingPathComponent(name)
            if isFolder(entry.path) { files += OS.files(below: entry) } else { files.append(entry) }
        }
        return files
    }

    public static func sleep(milliseconds: Int) {
        #if os(Windows)
        Sleep(DWORD(milliseconds))
        #else
        usleep(UInt32(milliseconds) * 1000)
        #endif
    }

    public static func quit(_ status: Int32) -> Never {
        exit(status)
    }

    public static func printError(_ text: String) {
        fputs(text + "\n", stderr)
    }

    #if !os(Windows)
    public static func makeExecutable(_ path: String) {
        chmod(path, 0o755)
    }

    /// Returns the path to the currently running executable.
    public static func executablePath() -> String? {
        #if os(Linux)
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = readlink("/proc/self/exe", &buffer, buffer.count - 1)
        return length > 0 ? String(cString: buffer) : nil
        #else
        var size: UInt32 = 4096
        var buffer = [CChar](repeating: 0, count: Int(size))
        return _NSGetExecutablePath(&buffer, &size) == 0 ? String(cString: buffer) : nil
        #endif
    }
    #endif

    public struct Ran {
        /// Process exit code.
        public var status: Int32
        /// Captured stdout text (plus stderr when `mergingErrors` is true).
        public var output: String
    }

    #if os(Windows)
    /// Quotes a command-line argument according to Windows `CommandLineToArgvW` rules.
    static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return argument }
        var out = "\"", slashes = 0
        for character in argument {
            if character == "\\" {
                slashes += 1
            } else if character == "\"" {
                out += String(repeating: "\\", count: slashes * 2 + 1) + "\""
                slashes = 0
            } else {
                out += String(repeating: "\\", count: slashes) + String(character)
                slashes = 0
            }
        }
        return out + String(repeating: "\\", count: slashes * 2) + "\""
    }
    #endif

    /// Runs `program` to completion and returns its exit status and stdout, or `nil` if the
    /// process could not be spawned. Set `searching` to resolve `program` via `PATH`, and
    /// `mergingErrors` to include stderr in `output` instead of discarding it.
    public static func run(_ program: String, _ arguments: [String], searching: Bool = false, mergingErrors: Bool = false) -> Ran? {
        start(program, arguments, searching: searching, mergingErrors: mergingErrors, waiting: true)
    }

    /// Spawns `program` asynchronously without waiting for it to exit. Returns true if it started.
    @discardableResult
    public static func launch(_ program: String, _ arguments: [String]) -> Bool {
        start(program, arguments, searching: false, mergingErrors: false, waiting: false) != nil
    }

    private static func start(_ program: String, _ arguments: [String], searching: Bool, mergingErrors: Bool, waiting: Bool) -> Ran? {
        #if os(Windows)
        var command = ([program] + arguments).map(quoted).joined(separator: " ").wide
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var process = PROCESS_INFORMATION()
        guard waiting else {
            guard CreateProcessW(searching ? nil : program.wide, &command, nil, nil, false, 0, nil, nil, &startup, &process) else { return nil }
            CloseHandle(process.hThread)
            CloseHandle(process.hProcess)
            return Ran(status: 0, output: "")
        }
        var inherit = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        var readEnd: HANDLE?, writeEnd: HANDLE?
        guard CreatePipe(&readEnd, &writeEnd, &inherit, 0) else { return nil }
        SetHandleInformation(readEnd, DWORD(HANDLE_FLAG_INHERIT), 0)
        let null = CreateFileW("NUL".wide, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &inherit, DWORD(OPEN_EXISTING), 0, nil)
        defer { CloseHandle(readEnd); CloseHandle(null) }
        startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.hStdInput = null
        startup.hStdOutput = writeEnd
        startup.hStdError = mergingErrors ? writeEnd : null
        let started = CreateProcessW(searching ? nil : program.wide, &command, nil, nil, true, DWORD(CREATE_NO_WINDOW), nil, nil, &startup, &process)
        CloseHandle(writeEnd)
        guard started else { return nil }
        var output: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            var read: DWORD = 0
            guard ReadFile(readEnd, &chunk, DWORD(chunk.count), &read, nil), read > 0 else { break }
            output += chunk[..<Int(read)]
        }
        WaitForSingleObject(process.hProcess, INFINITE)
        var status: DWORD = 1
        GetExitCodeProcess(process.hProcess, &status)
        CloseHandle(process.hThread)
        CloseHandle(process.hProcess)
        return Ran(status: Int32(bitPattern: status), output: String(decoding: output, as: UTF8.self))
        #else
        var ends: [Int32] = [-1, -1]
        if waiting { guard pipe(&ends) == 0 else { return nil } }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if waiting {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, ends[1], 1)
            if mergingErrors { posix_spawn_file_actions_adddup2(&actions, ends[1], 2) } else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
            posix_spawn_file_actions_addclose(&actions, ends[0])
            posix_spawn_file_actions_addclose(&actions, ends[1])
        }
        var argv: [UnsafeMutablePointer<CChar>?] = ([program] + arguments).map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        #if canImport(Darwin)
        let environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil   // macOS: unchanged
        #else
        let environment = environ
        #endif
        var pid: pid_t = 0
        let failed = searching ? posix_spawnp(&pid, program, &actions, nil, &argv, environment) : posix_spawn(&pid, program, &actions, nil, &argv, environment)
        if waiting { close(ends[1]) }
        guard failed == 0 else {
            if waiting { close(ends[0]) }
            return nil
        }
        guard waiting else { return Ran(status: 0, output: "") }
        var output: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(ends[0], &chunk, chunk.count)
            if count > 0 { output += chunk[..<count] } else if count == 0 || errno != EINTR { break }
        }
        close(ends[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // Extract the normal exit status, or map signal termination to 128 + signal.
        let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return Ran(status: code, output: String(decoding: output, as: UTF8.self))
        #endif
    }
}
