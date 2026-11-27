// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Stores loaders that read raw controller model files on the headset so the host can convert them into
/// SteamVR render models. Platform code registers a loader for its `ControllerModelSet` at startup, and the
/// files are read on demand when the host requests them.
public enum ControllerModelSource {
    public typealias Files = [(name: String, data: Data)]
    private static let lock = NSLock()
    private static var sources: [ControllerModelSet: () -> Files?] = [:]

    public static func register(_ set: ControllerModelSet, _ load: @escaping () -> Files?) {
        lock.lock()
        sources[set] = load
        lock.unlock()
    }

    static func source(of set: ControllerModelSet) -> (() -> Files?)? {
        lock.lock()
        defer { lock.unlock() }
        return sources[set]
    }

    /// Extracts the left and right Galaxy XR controller `.gltf`, `.bin`, and base color `.png` files from
    /// Samsung's system APK, returning paths under `Left/` and `Right/`.
    public static func galaxyXR(apk: String = "/system/priv-app/ImmersiveAvatarEditor/ImmersiveAvatarEditor.apk") -> Files? {
        guard let archive = ZipArchive(path: apk) else { return nil }
        var files: Files = []
        for side in ["Left", "Right"] {
            let folder = "assets/models/\(side)/"
            guard let gltf = archive.read("\(folder)\(side)Controller.gltf"),
                  let document = (try? JSONSerialization.jsonObject(with: gltf)) as? [String: Any] else { return nil }
            files.append(("\(side)/\(side)Controller.gltf", gltf))
            var wanted = ((document["buffers"] as? [[String: Any]]) ?? []).compactMap { $0["uri"] as? String }
            // Pick the base color texture from the first opaque material (skipping the transparent LED material).
            let images = (document["images"] as? [[String: Any]]) ?? [], textures = (document["textures"] as? [[String: Any]]) ?? []
            for material in (document["materials"] as? [[String: Any]]) ?? [] where material["alphaMode"] == nil {
                guard let texture = ((material["pbrMetallicRoughness"] as? [String: Any])?["baseColorTexture"] as? [String: Any])?["index"] as? Int,
                      textures.indices.contains(texture), let image = textures[texture]["source"] as? Int, images.indices.contains(image),
                      let uri = images[image]["uri"] as? String else { continue }
                wanted.append(uri)
                break
            }
            for name in wanted where DataLink.isSafe(name: "\(side)/\(name)") {
                guard let data = archive.read(folder + name) else { return nil }
                files.append(("\(side)/\(name)", data))
            }
        }
        return files
    }
}

/// Listens on TCP so the headset can send controller model assets that are too large for the SVLRoot
/// key/value channel.
///
/// `DataLink` binds to the session's local IPv4 address on an ephemeral port and publishes its address,
/// port, offered model bitmask, and a single-use 96-bit token in the encrypted session's `ox*` records.
/// `driver_openvrlink` connects out from the host, authenticates with that token, and requests any missing
/// controller model sets.
public final class DataLink {
    static let version: UInt8 = 1, helloSize = 20, headerSize = 8
    static let longestMessage = 32 << 20
    enum Kind: UInt16 { case wantModels = 1, file = 2, done = 3, result = 4 }

    /// Returns true if `name` is a valid relative file path accepted by the host (one or two `/` components of
    /// ASCII letters, digits, `_`, `-`, and `.`, with no leading dots).
    static func isSafe(name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return name.utf8.count <= 96 && (1...2).contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && part.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E
            }
        }
    }

    static func message(_ kind: Kind, _ payload: Bytes) -> Bytes {
        var out = Bytes()
        out.append(integer: kind.rawValue)
        out.append(integer: UInt16(0))
        out.append(integer: UInt32(payload.count))
        return out + payload
    }

    private let listener: Int32
    private let address: UInt32
    public let port: UInt16
    private let offers: [ControllerModelSet]
    private let log: (String) -> Void
    private let lock = NSLock()
    private var token: Bytes
    private var stopped = false

    /// Opens a TCP listener on `address` (4-byte network-order IPv4), or returns `nil` if binding fails.
    public init?(address: Bytes, offers: [ControllerModelSet], log: @escaping (String) -> Void) {
        guard address.count == 4 else { return nil }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var own = sockaddr_in()
        own.sin_family = sa_family_t(AF_INET)
        own.sin_port = 0
        own.sin_addr.s_addr = address.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &own) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && listen(descriptor, 2) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            return nil
        }
        listener = descriptor
        self.address = UInt32(address[0]) << 24 | UInt32(address[1]) << 16 | UInt32(address[2]) << 8 | UInt32(address[3])
        port = UInt16(bigEndian: own.sin_port)
        self.offers = offers
        self.log = log
        token = DataLink.freshToken()
        let thread = Thread { [self] in serve() }
        thread.name = "data link"
        thread.start()
    }

    private static func freshToken() -> Bytes {
        var generator = SystemRandomNumberGenerator()
        return (0..<12).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// Returns the `ox*` key/value records advertising this listener's address, port, token, and offered sets.
    public var records: [(key: String, value: Double)] {
        lock.lock()
        let token = token
        lock.unlock()
        func half(_ bytes: ArraySlice<UInt8>) -> Double { Double(bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) }
        return [("oxAddr", Double(address)), ("oxPort", Double(port)), ("oxKey0", half(token[0..<6])), ("oxKey1", half(token[6..<12])),
                ("oxOffer", Double(offers.reduce(UInt32(0)) { $0 | $1.bit }))]
    }

    public func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if !already { close(listener) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        log("data link: listening on port \(port) (\(offers.map(\.title).joined(separator: ", ")) controller models)")
        while !isStopped {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 500) > 0, !isStopped else { continue }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { continue }
            var wait = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            #if canImport(Darwin)
            var quiet: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
            #endif
            talk(to: peer)
            close(peer)
        }
    }

    private func receive(_ peer: Int32, _ count: Int) -> Bytes? {
        var out = Bytes(repeating: 0, count: count), have = 0
        while have < count {
            let got = out.withUnsafeMutableBytes { recv(peer, $0.baseAddress! + have, count - have, 0) }
            guard got > 0 else { return nil }
            have += got
        }
        return out
    }

    private func write(_ peer: Int32, _ bytes: Bytes) -> Bool {
        var sent = 0
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { send(peer, $0.baseAddress! + sent, bytes.count - sent, flags) }
            guard wrote > 0 else { return false }
            sent += wrote
        }
        return true
    }

    private func talk(to peer: Int32) {
        // Verify the magic header and compare all 12 token bytes in constant time before replying.
        guard let hello = receive(peer, DataLink.helloSize), Array(hello[0..<5]) == [0x4F, 0x56, 0x52, 0x4C, DataLink.version] else { return }
        lock.lock()
        let expected = token
        lock.unlock()
        guard zip(hello[8..<20], expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return log("data link: rejected connection with invalid token") }
        lock.lock()
        token = DataLink.freshToken()
        lock.unlock()
        while !isStopped, let header = receive(peer, DataLink.headerSize) {
            let length = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
            guard length <= DataLink.longestMessage, let payload = receive(peer, length) else { return }
            switch Kind(rawValue: UInt16(header[0]) | UInt16(header[1]) << 8) {
            case .wantModels:
                guard let number = payload.first else { return }
                guard let set = ControllerModelSet(rawValue: Int(number)), offers.contains(set), let files = ControllerModelSource.source(of: set)?(),
                      !files.isEmpty, files.allSatisfy({ DataLink.isSafe(name: $0.name) && $0.data.count + 98 <= DataLink.longestMessage }) else {
                    log("data link: could not load requested controller model set \(number)")
                    _ = write(peer, DataLink.message(.done, [number, 1]))
                    continue
                }
                log("data link: sending \(set.title) controller models (\(files.count) files, \(files.reduce(0) { $0 + $1.data.count }) bytes)")
                for file in files {
                    guard write(peer, DataLink.message(.file, [number, UInt8(file.name.utf8.count)] + Bytes(file.name.utf8) + Bytes(file.data))) else {
                        return log("data link: connection closed while sending controller models")
                    }
                }
                guard write(peer, DataLink.message(.done, [number, 0])) else { return }
            case .result:
                guard payload.count >= 2 else { return }
                log(payload[1] == 0 ? "data link: host saved controller models; they will be used starting next session once converted"
                                    : "data link: host failed to save controller models (status \(payload[1]))")
            default:
                break
            }
        }
    }
}
