// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class DataLinkTests: XCTestCase {
    /// Minimal test APK matching Galaxy XR's `ImmersiveAvatarEditor` layout, with DEFLATE-compressed glTF/bin
    /// entries, stored PNGs, and a transparent LED material preceding the controller body material.
    private static let archive = Data(base64Encoded: [
        "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",
        "TzRh9t/EP1BLAwQUAAAAAAAAACE6fBjn/B0AAAAdAAAAIQAAAGFzc2V0cy9tb2RlbHMvUmlnaHQvQmFzZUNvbG9yLnBuZ4lQTkdSaWdodFJpZ2h0UmlnaHRSaWdodFJpZ2h0UEsDBBQAAAAAAAAAIT",
        "rkaIUhBgAAAAYAAAAlAAAAYXNzZXRzL21vZGVscy9SaWdodC9Ob3JtYWxfT3BlbkdMLnBuZ25vcm1hbFBLAQIUAxQAAAAIAAAAITp631ogGAAAABYAAAAUAAAAAAAAAAAAAACAAQAAAABNRVRBLUlO",
        "Ri9NQU5JRkVTVC5NRlBLAQIUAxQAAAAIAAAAITpR0sVx2wAAANoCAAAmAAAAAAAAAAAAAACAAUoAAABhc3NldHMvbW9kZWxzL0xlZnQvTGVmdENvbnRyb2xsZXIuZ2x0ZlBLAQIUAxQAAAAIAAAAIT",
        "pncISQcQMAALgLAAAlAAAAAAAAAAAAAACAAWkBAABhc3NldHMvbW9kZWxzL0xlZnQvTGVmdENvbnRyb2xsZXIuYmluUEsBAhQDFAAAAAAAAAAhOoPZaHUYAAAAGAAAACAAAAAAAAAAAAAAAIABHQUA",
        "AGFzc2V0cy9tb2RlbHMvTGVmdC9CYXNlQ29sb3IucG5nUEsBAhQDFAAAAAAAAAAhOuRohSEGAAAABgAAACQAAAAAAAAAAAAAAIABcwUAAGFzc2V0cy9tb2RlbHMvTGVmdC9Ob3JtYWxfT3BlbkdMLn",
        "BuZ1BLAQIUAxQAAAAIAAAAIToN5Sof3AAAANsCAAAoAAAAAAAAAAAAAACAAbsFAABhc3NldHMvbW9kZWxzL1JpZ2h0L1JpZ2h0Q29udHJvbGxlci5nbHRmUEsBAhQDFAAAAAgAAAAhOmdwhJBxAwAA",
        "uAsAACcAAAAAAAAAAAAAAIAB3QYAAGFzc2V0cy9tb2RlbHMvUmlnaHQvUmlnaHRDb250cm9sbGVyLmJpblBLAQIUAxQAAAAAAAAAITp8GOf8HQAAAB0AAAAhAAAAAAAAAAAAAACAAZMKAABhc3NldH",
        "MvbW9kZWxzL1JpZ2h0L0Jhc2VDb2xvci5wbmdQSwECFAMUAAAAAAAAACE65GiFIQYAAAAGAAAAJQAAAAAAAAAAAAAAgAHvCgAAYXNzZXRzL21vZGVscy9SaWdodC9Ob3JtYWxfT3BlbkdMLnBuZ1BL",
        "BQYAAAAACQAJANYCAAA4CwAAAAA=",
    ].joined())!

    private func archiveFile() throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ovrl-zip-\(UInt32.random(in: 0...UInt32.max)).apk")
        try DataLinkTests.archive.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    func testInflateUnpacksStoredAndCodedBlocks() {
        let text = Bytes("hello hello hello hello".utf8)
        XCTAssertEqual(Inflate.inflate(Bytes(Data(base64Encoded: "ARcA6P9oZWxsbyBoZWxsbyBoZWxsbyBoZWxsbw==")!), size: text.count), text)
        XCTAssertEqual(Inflate.inflate(Bytes(Data(base64Encoded: "y0jNyclXyEAnAQ==")!), size: text.count), text)
        // Reject mismatched output sizes and truncated streams.
        XCTAssertNil(Inflate.inflate(Bytes(Data(base64Encoded: "y0jNyclXyEAnAQ==")!), size: text.count - 1))
        XCTAssertNil(Inflate.inflate(Bytes(Data(base64Encoded: "y0jNyclXyEAnAQ==")!.prefix(5)), size: text.count))
        XCTAssertNil(Inflate.inflate([], size: 0))
    }

    func testZipArchiveReadsIndividualEntries() throws {
        let archive = try XCTUnwrap(ZipArchive(path: try archiveFile()))
        XCTAssertEqual(archive.entries.count, 9)
        // Verify reading both dynamic-Huffman DEFLATE entries and uncompressed stored entries.
        XCTAssertEqual(archive.read("assets/models/Left/LeftController.bin").map { Bytes($0) }, (0..<3000).map { UInt8(($0 * 7 + $0 / 13) % 251) })
        XCTAssertEqual(archive.read("assets/models/Right/BaseColor.png"), Data([0x89] + Bytes("PNGRightRightRightRightRight".utf8)))
        XCTAssertNil(archive.read("assets/models/Left/missing"))
        XCTAssertNil(ZipArchive(path: "/nonexistent.zip"))
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("ovrl-junk-\(UInt32.random(in: 0...UInt32.max))")
        try Data(repeating: 7, count: 100).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertNil(ZipArchive(path: junk.path))
    }

    func testGalaxyXRSourceExtractsGLTFBufferAndBaseColor() throws {
        let files = try XCTUnwrap(ControllerModelSource.galaxyXR(apk: try archiveFile()))
        // Includes only the glTF, binary buffer, and opaque body base-color PNG (skipping the LED and normal map).
        XCTAssertEqual(files.map(\.name), ["Left/LeftController.gltf", "Left/LeftController.bin", "Left/BaseColor.png",
                                           "Right/RightController.gltf", "Right/RightController.bin", "Right/BaseColor.png"])
        XCTAssertEqual(files[1].data.count, 3000)
        XCTAssertNil(ControllerModelSource.galaxyXR(apk: "/nonexistent.apk"))
    }

    /// Extracts models from a real `ImmersiveAvatarEditor.apk` when `OVRL_TEST_GALAXY_APK` is set.
    func testExtractsModelsFromSystemAPK() throws {
        guard let apk = ProcessInfo.processInfo.environment["OVRL_TEST_GALAXY_APK"] else { throw XCTSkip("no APK named") }
        let files = try XCTUnwrap(ControllerModelSource.galaxyXR(apk: apk))
        XCTAssertEqual(files.count, 6)
        for file in files where file.name.hasSuffix(".gltf") { XCTAssertNotNil(try? JSONSerialization.jsonObject(with: file.data), file.name) }
        for file in files where file.name.hasSuffix(".png") { XCTAssertEqual(Bytes(file.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], file.name) }
        if let out = ProcessInfo.processInfo.environment["OVRL_TEST_GALAXY_OUT"] {
            for file in files {
                let place = URL(fileURLWithPath: out).appendingPathComponent(file.name)
                try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: place)
            }
        }
    }

    func testDataLinkValidatesRelativeFileNames() {
        for good in ["a.bin", "Left/LeftController.gltf", "a-b/c_d.e"] { XCTAssertTrue(DataLink.isSafe(name: good), good) }
        for bad in ["", "../a", "a/../b", "/a", "a/", "a/b/c", ".a", "a/.b", "a b", "a\\b", String(repeating: "a", count: 97)] { XCTAssertFalse(DataLink.isSafe(name: bad), bad) }
    }

    /// Reads exactly `count` bytes from a test connection.
    private func read(_ socket: TCPSocket, _ count: Int, within seconds: Double = 5) -> Bytes? {
        var out = Bytes()
        let deadline = Date().addingTimeInterval(seconds)
        while out.count < count, Date() < deadline {
            if let more = socket.receiveAvailable(), !more.isEmpty { out += more } else { Thread.sleep(forTimeInterval: 0.01) }
        }
        return out.count >= count ? out : nil
    }

    func testDataLinkRequiresSingleUseTokenAndServesModels() throws {
        ControllerModelSource.register(.galaxyXR) { [("Left/a.gltf", Data([1, 2, 3])), ("Left/a.bin", Data(repeating: 9, count: 70_000))] }
        var said: [String] = []
        let saidLock = NSLock()
        let link = try XCTUnwrap(DataLink(address: [127, 0, 0, 1], offers: [.galaxyXR]) { line in
            saidLock.lock()
            said.append(line)
            saidLock.unlock()
        })
        defer { link.stop() }
        func record(_ key: String) -> Double { link.records.first { $0.key == key }?.value ?? -1 }
        XCTAssertEqual(record("oxAddr"), Double(0x7F00_0001))
        XCTAssertEqual(record("oxPort"), Double(link.port))
        XCTAssertEqual(record("oxOffer"), 2)
        func token() -> Bytes {
            [record("oxKey0"), record("oxKey1")].flatMap { value in (0..<6).map { UInt8(truncatingIfNeeded: UInt64(value) >> (8 * UInt64($0))) } }
        }
        let hello: Bytes = [0x4F, 0x56, 0x52, 0x4C, 1, 0, 0, 0]

        // Connections with an invalid token are closed without a response.
        let stranger = try XCTUnwrap(TCPSocket(address: "127.0.0.1", port: link.port))
        XCTAssertTrue(stranger.send(hello + Bytes(repeating: 0, count: 12) + DataLink.message(.wantModels, [1])))
        XCTAssertNil(read(stranger, 1, within: 0.5))
        stranger.shutDown()

        let first = token()
        let host = try XCTUnwrap(TCPSocket(address: "127.0.0.1", port: link.port))
        XCTAssertTrue(host.send(hello + first + DataLink.message(.wantModels, [1])))
        // Expect two file messages plus a done message (24 + 70,020 + 10 bytes).
        let expected = 24 + 70_020 + 10
        let got = try XCTUnwrap(read(host, expected))
        XCTAssertEqual(Array(got[0..<8]), [2, 0, 0, 0, 16, 0, 0, 0])
        XCTAssertEqual(Array(got[8..<24]), [1, 11] + Bytes("Left/a.gltf".utf8) + [1, 2, 3])
        XCTAssertEqual(Array(got[(expected - 10)...]), [3, 0, 0, 0, 2, 0, 0, 0, 1, 0])
        // Requesting an unoffered model set returns a non-zero done status.
        XCTAssertTrue(host.send(DataLink.message(.wantModels, [0])))
        XCTAssertEqual(read(host, 10), [3, 0, 0, 0, 2, 0, 0, 0, 0, 1])
        XCTAssertTrue(host.send(DataLink.message(.result, [1, 0])))
        host.shutDown()

        // Each token is single-use; replaying the previous token is rejected.
        XCTAssertNotEqual(token(), first)
        let replay = try XCTUnwrap(TCPSocket(address: "127.0.0.1", port: link.port))
        XCTAssertTrue(replay.send(hello + first + DataLink.message(.wantModels, [1])))
        XCTAssertNil(read(replay, 1, within: 0.5))
        replay.shutDown()
        saidLock.lock()
        XCTAssertTrue(said.contains { $0.contains("sending Galaxy XR controller models (2 files, 70003 bytes)") }, "\(said)")
        XCTAssertTrue(said.contains { $0.contains("host saved controller models") }, "\(said)")
        XCTAssertEqual(said.filter { $0.contains("invalid token") }.count, 2, "\(said)")
        saidLock.unlock()
    }
}
