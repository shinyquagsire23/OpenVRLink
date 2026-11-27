// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(Darwin)
import DriverABI
import Foundation
import PatchCore
import XCTest
@testable import driver_openvrlink

/// Tests `driver_openvrlink`'s data-link client against a local mock TCP server that validates the session
/// token and serves controller model files, using a mock `ovr_settings` vtable.
final class LinkTests: XCTestCase {
    nonisolated(unsafe) static var folder: [CChar] = []

    private static let settings: UnsafeMutablePointer<ovr_settings> = {
        let vtable = UnsafeMutablePointer<ovr_settings_vtable>.allocate(capacity: 1)
        vtable.initialize(to: ovr_settings_vtable(
            error_name: { _, _ in nil },
            set_bool: { _, _, _, _, _ in }, set_int32: { _, _, _, _, _ in }, set_float: { _, _, _, _, _ in }, set_string: { _, _, _, _, _ in },
            get_bool: { _, _, _, error in error?.pointee = 1; return false },
            get_int32: { _, _, _, error in error?.pointee = 1; return 0 },
            get_float: { _, _, _, error in error?.pointee = 1; return 0 },
            get_string: { _, _, key, value, size, error in
                // Return only the `folder` setting and omit `companion` so the test does not spawn a subprocess.
                guard let key, let value, strcmp(key, "folder") == 0, Int(size) > LinkTests.folder.count else {
                    error?.pointee = 1
                    return
                }
                LinkTests.folder.withUnsafeBufferPointer { value.update(from: $0.baseAddress!, count: $0.count) }
            }))
        let object = UnsafeMutablePointer<ovr_settings>.allocate(capacity: 1)
        object.initialize(to: ovr_settings(vtable: vtable))
        return object
    }()

    private func observe(_ host: inout HostSide, _ values: [(StaticString, Double)], at now: UInt64) {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: values.count * Handshake.recordSize, alignment: 8)
        defer { memory.deallocate() }
        for (index, value) in values.enumerated() { Handshake.write(memory + index * Handshake.recordSize, key: value.0, value: value.1, time: 0) }
        host.observe(memory, count: values.count, atMilliseconds: now)
    }

    func testDriverDownloadsControllerModelsOverDataLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ovrl-link-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        LinkTests.folder = Array(root.path.utf8CString)
        Server.settings = LinkTests.settings
        defer { Server.settings = nil }

        // Start a mock client listener that checks the token and responds to wantModels(1) with two files.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var own = sockaddr_in()
        own.sin_family = sa_family_t(AF_INET)
        own.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertTrue(withUnsafeMutablePointer(to: &own) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &length) == 0 }
        })
        let port = UInt16(bigEndian: own.sin_port)
        let token: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        let big = [UInt8]((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let heard = expectation(description: "received result message from driver")
        nonisolated(unsafe) var result: [UInt8] = []
        Thread.detachNewThread {
            let peer = accept(listener, nil, nil)
            defer { close(peer) }
            func read(_ count: Int) -> [UInt8] {
                var out = [UInt8](repeating: 0, count: count), have = 0
                while have < count {
                    let got = out.withUnsafeMutableBytes { recv(peer, $0.baseAddress! + have, count - have, 0) }
                    if got <= 0 { return [] }
                    have += got
                }
                return out
            }
            func write(_ bytes: [UInt8]) { var sent = 0; while sent < bytes.count { let wrote = bytes.withUnsafeBytes { send(peer, $0.baseAddress! + sent, bytes.count - sent, 0) }; if wrote <= 0 { return }; sent += wrote } }
            guard read(DataLink.helloSize) == DataLink.hello(token: token), read(DataLink.headerSize + 1) == DataLink.message(.wantModels, [1]) else { return heard.fulfill() }
            let name = Array("Left/LeftController.gltf".utf8), other = Array("Left/big.bin".utf8)
            write(DataLink.message(.file, [1, UInt8(name.count)] + name + Array("{}".utf8)))
            write(DataLink.message(.file, [1, UInt8(other.count)] + other + big))
            write(DataLink.message(.done, [1, 0]))
            result = read(DataLink.headerSize + 2)
            heard.fulfill()
        }

        var host = HostSide()
        let keys: [(StaticString, Double)] = [("oxAddr", Double(0x7F00_0001)), ("oxPort", Double(port)), ("oxKey0", Double(0x0605_0403_0201)),
                                              ("oxKey1", Double(0x0C0B_0A09_0807)), ("oxOffer", 2)]
        observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: 0))] + keys, at: 0)
        observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: 500))] + keys, at: 500)
        Platform.lock()
        Shared.host = host
        Platform.unlock()
        defer { Shared.host = nil }

        var now: UInt64 = 600
        let marker = root.appendingPathComponent("incoming/galaxy_xr/complete")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Link.work(now: now)
            now += 1
            Thread.sleep(forTimeInterval: 0.001)
        }
        wait(for: [heard], timeout: 5)
        XCTAssertEqual(result, DataLink.message(.result, [1, 0]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("incoming/galaxy_xr/Left/LeftController.gltf")), Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("incoming/galaxy_xr/Left/big.bin")), Data(big))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Once converted render model files exist on disk, Link.converted() reports the set without restarting.
        XCTAssertEqual(Link.converted(), 0)
        let model = root.appendingPathComponent("resources/rendermodels/galaxy_xr_controller_left")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("galaxy_xr_controller_left.json"))
        XCTAssertEqual(Link.converted(), 2)
    }
}
#endif
