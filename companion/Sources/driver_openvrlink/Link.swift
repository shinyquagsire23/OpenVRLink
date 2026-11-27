// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import DriverABI
import PatchCore

/// Connects from `driver_openvrlink` to the headset's TCP data link without spawning background threads,
/// polling a non-blocking socket from `vrserver`'s frame callback.
///
/// When a live OpenVRLink client offers a controller model set that is not yet installed, `Link` connects to
/// the headset, downloads the files into `incoming/<set>/` inside the driver directory, writes a `complete`
/// marker file, and runs `openvrlink-companion import-models pending` to convert them into SteamVR render
/// models.
enum Link {
    /// Returns the subdirectory name under `incoming/` for a downloadable `oxModels` bit index. Play For Dream
    /// models are bundled with `openvrlink-companion`, so bit 0 is not downloaded.
    static func folder(ofSet set: UInt8) -> StaticString? { set == 1 ? "galaxy_xr" : nil }

    /// Settings keys written by `openvrlink-companion` with paths to the driver directory and companion binary.
    static let folderKey: StaticString = "folder", companionKey: StaticString = "companion"
    /// Connection and transfer timeout in milliseconds.
    static let patience: UInt64 = 60_000
    /// Maximum bytes read from the socket during a single `vrserver` frame callback.
    static let perFrame = 4 << 20
    static let mostFiles = 32, mostBytes = 64 << 20

    private enum Stage { case connecting, receiving }
    private static var socket: Int = -1
    private static var stage = Stage.connecting
    private static var began: UInt64 = 0, lastTry: UInt64 = 0
    private static var parser = DataLink.Parser()
    private static var set: UInt8 = 0
    private static var token: [UInt8] = []
    private static var files = 0, bytes = 0
    /// Bitmask of model sets already requested during this `vrserver` session so each set is attempted at most once.
    private static var asked: UInt32 = 0
    private static var buffer: UnsafeMutableRawPointer?

    /// Called every server frame.
    static func work(now: UInt64) {
        if socket >= 0 { return advance(now: now) }
        // Check for newly offered model sets at most twice per second.
        guard now &- lastTry >= 500 else { return }
        lastTry = now
        Platform.lock()
        let link = Shared.host?.link(atMilliseconds: now), have = Shared.host?.models ?? 0
        Platform.unlock()
        guard let link else { return }
        let missing = link.offer & ~have & ~asked
        guard missing != 0 else { return }
        let wanted = UInt8(missing.trailingZeroBitCount)
        asked |= 1 << UInt32(wanted)
        guard let name = folder(ofSet: wanted), let place = path(to: name, nil) else { return }
        // Skip re-downloading if a previous run already saved the complete set and only needs conversion.
        if exists(place.adding("/complete")) {
            Server.say(Message("converting previously downloaded controller models for ").adding(name))
            return convert()
        }
        let opened = ovrl_link_connect(link.address, link.port)
        guard opened >= 0 else { return Server.say("data link: failed to initiate connection to headset") }
        socket = opened
        stage = .connecting
        began = now
        parser = DataLink.Parser()
        set = wanted
        token = link.token
        files = 0
        bytes = 0
        Server.say(Message("data link: requesting controller models from headset (").adding(name).adding(")"))
    }

    private static func end(_ why: StaticString? = nil) {
        if socket >= 0 { ovrl_link_close(socket) }
        socket = -1
        parser = DataLink.Parser()
        if let why { Server.say(Message("data link: ").adding(why)) }
    }

    /// Writes `bytes` in a single non-blocking send (all outgoing messages here are small control frames).
    private static func send(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { ovrl_link_send(socket, $0.baseAddress, $0.count) } == bytes.count
    }

    private static func advance(now: UInt64) {
        guard now &- began <= patience else { return end("timed out waiting for headset") }
        switch stage {
        case .connecting:
            let ready = ovrl_link_ready(socket)
            guard ready >= 0 else { return end("headset refused connection") }
            guard ready > 0 else { return }
            guard send(DataLink.hello(token: token)), send(DataLink.message(.wantModels, [set])) else { return end("failed to send request to headset") }
            stage = .receiving
        case .receiving:
            let capacity = 256 << 10
            if buffer == nil { buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16) }
            guard let buffer else { return }
            var taken = 0
            while taken < perFrame {
                let got = ovrl_link_receive(socket, buffer, capacity)
                if got < 0 { return end("connection closed before transfer completed") }
                if got == 0 { break }
                taken += got
                bytes += got
                guard bytes <= mostBytes else { return end("transfer exceeded 64 MiB limit") }
                parser.add(UnsafeRawBufferPointer(start: buffer, count: got))
                while let message = parser.next() {
                    guard handle(message.kind, message.payload) else { return }
                }
                if parser.failed { return end("invalid message header from headset") }
            }
        }
    }

    /// Returns false once the connection has been ended.
    private static func handle(_ kind: DataLink.Kind, _ payload: [UInt8]) -> Bool {
        switch kind {
        case .file:
            guard let file = DataLink.file(in: payload), file.set == set, let name = folder(ofSet: set), files < mostFiles else {
                end("rejected unexpected or invalid file")
                return false
            }
            files += 1
            guard write(file.bytes, named: file.name, inSet: name) else {
                _ = send(DataLink.message(.result, [set, 2]))
                end("failed to write incoming model file (check driver folder setting)")
                return false
            }
            return true
        case .done:
            guard payload.count >= 2, payload[0] == set, let name = folder(ofSet: set) else {
                end("unexpected done message from headset")
                return false
            }
            guard payload[1] == 0, files > 0 else {
                end("headset reported controller models unavailable")
                return false
            }
            // Write the completion marker last so partial transfers are ignored.
            let marked = write([UInt8]("1\n".utf8)[...], named: [UInt8]("complete".utf8)[...], inSet: name)
            _ = send(DataLink.message(.result, [set, marked ? 0 : 2]))
            Server.say(Message("data link: ").adding(files).adding(" controller model files received (").adding(bytes).adding(" bytes)"))
            end()
            if marked { convert() }
            return false
        case .wantModels, .result:
            return true
        }
    }

    /// Returns `oxModels` bits for any controller model sets converted on disk since `vrserver` started, so the
    /// headset can use them on its next streaming session without restarting SteamVR.
    static func converted() -> UInt32 {
        guard var model = Server.string(folderKey) else { return 0 }
        model.add("/resources/rendermodels/galaxy_xr_controller_left/galaxy_xr_controller_left.json")
        return exists(model) ? 1 << 1 : 0
    }

    /// Builds the path `<driver>/incoming/<set>[/<name>]`, or returns `nil` if the driver folder setting is unset.
    private static func path(to set: StaticString, _ name: ArraySlice<UInt8>?) -> Message? {
        guard var path = Server.string(folderKey) else { return nil }
        path.add("/incoming/")
        path.add(set)
        if let name {
            path.characters.append(0x2F)
            path.characters.append(contentsOf: name.map { CChar(bitPattern: $0) })
        }
        return path
    }

    private static func exists(_ path: Message) -> Bool {
        var text = path.characters + [0]
        guard let file = fopen(&text, "rb") else { return false }
        fclose(file)
        return true
    }

    private static func write(_ bytes: ArraySlice<UInt8>, named name: ArraySlice<UInt8>, inSet set: StaticString) -> Bool {
        guard var root = Server.string(folderKey), let folder = path(to: set, nil), let place = path(to: set, name) else { return false }
        // Ensure incoming/, incoming/<set>/, and any single subdirectory in name exist.
        root.add("/incoming")
        var made = [root, folder]
        if let slash = name.firstIndex(of: 0x2F), let inner = path(to: set, name[..<slash]) { made.append(inner) }
        for folder in made {
            var text = folder.characters + [0]
            guard ovrl_make_folder(&text) == 0 else { return false }
        }
        var text = place.characters + [0]
        guard let file = fopen(&text, "wb") else { return false }
        let written = bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
        return fclose(file) == 0 && written == bytes.count
    }

    /// Spawns `openvrlink-companion import-models pending` to convert downloaded controller models.
    private static func convert() {
        guard let program = Server.string(companionKey), !program.characters.isEmpty else {
            return Server.say("run `openvrlink-companion import-models pending` to convert downloaded controller models")
        }
        var text = program.characters + [0]
        let started = ovrl_start_program(&text, Server.cString("import-models"), Server.cString("pending")) == 0
        Server.say(started ? "started openvrlink-companion to convert controller models for the next session"
                           : "failed to start openvrlink-companion; run `openvrlink-companion import-models pending` manually")
    }
}
