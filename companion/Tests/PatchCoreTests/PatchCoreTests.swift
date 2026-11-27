// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import PatchCore

final class ScanTests: XCTestCase {
    func testSignaturesMatchWithWildcards() {
        let bytes: [UInt8] = [0x90, 0x48, 0x89, 0x54, 0x24, 0x10, 0x90, 0x48, 0x89, 0x11, 0x24, 0x10]
        bytes.view { view in
            let region = Scan.Region(address: 0x1000, bytes: view)
            XCTAssertEqual(Scan.findSignature(in: region, Scan.parseSignature("48 89 ?? 24 10")), [0x1001, 0x1007])
            XCTAssertEqual(Scan.findSignature(in: region, Scan.parseSignature("48 89 54 24 10")), [0x1001])
            XCTAssertEqual(Scan.findSignature(in: region, Scan.parseSignature("48 89 54 24 11")), [])
        }
    }

    func testCallAndJumpSitesAreFoundByDestination() {
        // 0x2000: call 0x2100 ; 0x2005: jmp 0x2100 ; 0x200a: call 0x2200
        var bytes: [UInt8] = [0xE8, 0xFB, 0x00, 0x00, 0x00, 0xE9, 0xF6, 0x00, 0x00, 0x00, 0xE8, 0xF1, 0x01, 0x00, 0x00]
        bytes += [UInt8](repeating: 0x90, count: 0x300 - bytes.count)
        bytes.view { view in
            let regions = [Scan.Region(address: 0x2000, bytes: view)]
            XCTAssertEqual(Scan.findSites(in: regions, calling: 0x2100),
                           [Scan.Site(displacementAt: 0x2001, isCall: true), Scan.Site(displacementAt: 0x2006, isCall: false)])
            XCTAssertEqual(Scan.findSites(in: regions, calling: 0x2200).count, 1)
            XCTAssertEqual(Scan.findSites(in: regions, calling: 0x2300), [])
        }
    }

    func testASignatureMustMatchExactlyOneCalledFunction() {
        let target = Scan.Target(name: "t", peSignatures: ["55 53 41 54"])
        var bytes = [UInt8](repeating: 0x90, count: 0x40)
        bytes.replaceSubrange(0x10..<0x14, with: [0x55, 0x53, 0x41, 0x54])
        func resolve() -> Scan.Resolution { bytes.view { Scan.resolve(bySignature: target, in: [Scan.Region(address: 0, bytes: $0)]) } }
        XCTAssertEqual(resolve(), .missing(.neverCalledDirectly))
        bytes[0x20] = 0xE8
        withUnsafeBytes(of: Int32(0x10 - 0x25).littleEndian) { bytes.replaceSubrange(0x21..<0x25, with: $0) }
        XCTAssertEqual(resolve(), .found(Scan.Found(function: 0x10, sites: [Scan.Site(displacementAt: 0x21, isCall: true)])))
        bytes.replaceSubrange(0x30..<0x34, with: [0x55, 0x53, 0x41, 0x54])
        XCTAssertEqual(resolve(), .missing(.ambiguous(2)))
        XCTAssertEqual(Scan.resolve(bySignature: Scan.updateConstants, in: []), .missing(.notForThisPlatform))
        // On Linux a build without symbols is searched by signature instead.
        XCTAssertEqual(bytes.view { Scan.resolve(inELF: Scan.Target(name: "t", elfSymbol: "absent", elfSignatures: ["55 53 41 54"]), in: [Scan.Region(address: 0, bytes: $0)], symbols: nil, slide: 0) }, .missing(.ambiguous(2)))
        XCTAssertFalse(Scan.updateConstants.applies(toELF: false))
        XCTAssertTrue(Scan.updateConstantsD3D.applies(toELF: false))
    }

    func testHookPointsResolveInRealDrivers() throws {
        var checked = 0
        for variable in ["OVRL_TEST_VRLINK_SO", "OVRL_TEST_VRLINK_SO_STRIPPED", "OVRL_TEST_VRLINK_DLL"] {
            guard let url = RealFiles.path(variable) else { continue }
            let file = try RealFiles.bytes(url)
            file.view { view in
                let resolved = Scan.resolveAll(inFile: view)
                var names: [String] = []
                for (target, resolution) in resolved {
                    guard case .found(let found) = resolution else { continue }
                    names.append("\(target.name)")
                    print("\(variable) \(target.name): 0x\(String(found.function, radix: 16)), \(found.sites.count) site(s)")
                }
                // A Linux build has one of the two shapes of the constants function, never both.
                let expected = Scan.isELF64(view) ? ["kv-parse", "kv-populate", "load-spirv"] : ["kv-parse", "kv-populate", "encode-constants-d3d"]
                XCTAssertEqual(names.filter { !$0.hasPrefix("encode-constants") || $0 == "encode-constants-d3d" }, expected)
                if Scan.isELF64(view) { XCTAssertEqual(names.filter { $0 == "encode-constants" || $0 == "encode-constants-wide" }.count, 1) }
                if Scan.isPE(view) {
                    XCTAssertNotNil(Scan.peImportSlot(view, mapped: false, library: "D3DCOMPILER_47.dll", function: "D3DReadFileToBlob"))
                    XCTAssertNotNil(Scan.peImportSlot(view, mapped: false, library: "d3dcompiler_47.DLL", function: "D3DReadFileToBlob"))
                    XCTAssertNil(Scan.peImportSlot(view, mapped: false, library: "D3DCOMPILER_47.dll", function: "D3DCompile"))
                    XCTAssertNil(Scan.peImportSlot(view, mapped: false, library: "nothing.dll", function: "D3DReadFileToBlob"))
                    let regions = Scan.peRegions(view, mapped: false)
                    let place = Scan.resolve(edit: Scan.keepFloorPerimeter, in: regions)
                    XCTAssertNotNil(place)
                    // Verify the patch targets the 6-byte call through vtable slot 69.
                    if let place, let region = regions.first(where: { $0.address <= place && place < $0.address + UInt64($0.bytes.count) }) {
                        let at = Int(place - region.address)
                        XCTAssertEqual(Array(region.bytes[at..<at + 6]), [0xFF, 0x92, 0x28, 0x02, 0x00, 0x00])
                        XCTAssertEqual(Scan.keepFloorPerimeter.replacement.count, 6)
                    }
                }
            }
            checked += 1
        }
        try XCTSkipIf(checked == 0, "no real driver files were named")
    }
}

final class HostSideTests: XCTestCase {
    /// `count` records, each `(key, value)` with timestamp 9.
    private func records(_ contents: [(StaticString, Double)]) -> UnsafeMutableRawPointer {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: contents.count * Handshake.recordSize, alignment: 1)
        for (index, content) in contents.enumerated() {
            Handshake.write(memory + index * Handshake.recordSize, key: content.0, value: content.1, time: 9)
        }
        return memory
    }

    private func observe(_ host: inout HostSide, _ contents: [(StaticString, Double)], at now: UInt64) {
        let memory = records(contents)
        defer { memory.deallocate() }
        host.observe(memory, count: contents.count, atMilliseconds: now)
    }

    func testARecordMatchesWholeKeysOnly() {
        let memory = records([("oxGamma", 1.5), ("exactly-twenty-chars", 2)])
        defer { memory.deallocate() }
        XCTAssertTrue(Handshake.record(memory, hasKey: "oxGamma"))
        XCTAssertFalse(Handshake.record(memory, hasKey: "oxGamm"))
        XCTAssertFalse(Handshake.record(memory, hasKey: "oxGamma2"))
        XCTAssertTrue(Handshake.record(memory + 32, hasKey: "exactly-twenty-chars"))
        XCTAssertEqual(Handshake.value(of: memory), 1.5)
        XCTAssertEqual(Handshake.time(of: memory + 32), 9)
    }

    func testNothingIsActiveOrSentForAClientThatNeverSpeaks() {
        var host = HostSide(available: 1, enabled: 1, gamma: 1.8)
        let out = records([("dCurBW", 100), ("dCurBW", 100)])
        defer { out.deallocate() }
        for call in 0..<20 {
            observe(&host, [("cPingMS", 1)], at: UInt64(call * 10))
            host.fill(out, count: 2, atMilliseconds: UInt64(call * 10))
        }
        XCTAssertEqual(host.active(atMilliseconds: 200), 0)
        XCTAssertEqual(host.activeGamma(atMilliseconds: 200), 1)
        XCTAssertTrue(Handshake.record(out, hasKey: "dCurBW"))
    }

    /// Unpatched clients can echo stale `oxClient` keys left in `driver_vrlink`'s table
    /// from an earlier session, repeating a static heartbeat value.
    func testAnEchoedHeartbeatThatNeverChangesIsNotAClient() {
        var host = HostSide(available: 1, enabled: 1, gamma: 1.8)
        for step in 0..<40 {
            observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: 0)), ("oxWant", 1)], at: UInt64(step * 100))
        }
        XCTAssertFalse(host.clientPresent(atMilliseconds: 4000))
        XCTAssertEqual(host.active(atMilliseconds: 4000), 0)
    }

    func testReadsClientDataLinkEndpointWhenHeartbeatAdvances() {
        var host = HostSide()
        let keys: [(StaticString, Double)] = [("oxAddr", Double(0xC0A8_0432)), ("oxPort", 40123), ("oxKey0", Double(0x0605_0403_0201)), ("oxKey1", 7), ("oxOffer", 2)]
        // Ignore echoed data-link keys when the client heartbeat is not advancing.
        for step in 0..<10 { observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: 0))] + keys, at: UInt64(step * 100)) }
        XCTAssertNil(host.link(atMilliseconds: 1000))
        for step in 10..<20 {
            let now = UInt64(step * 100)
            observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: now))] + keys, at: now)
        }
        let link = host.link(atMilliseconds: 1900)
        XCTAssertEqual(link?.address, 0xC0A8_0432)
        XCTAssertEqual(link?.port, 40123)
        XCTAssertEqual(link?.token, [1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 0])
        XCTAssertEqual(link?.offer, 2)
        // Reject out-of-range TCP port numbers.
        observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: 2000)), ("oxPort", 70000)], at: 2000)
        XCTAssertNil(host.link(atMilliseconds: 2000))
    }

    func testDataLinkParserReassemblesMessagesAndSkipsUnknownKinds() {
        XCTAssertEqual(DataLink.hello(token: Array(1...12)).count, DataLink.helloSize)
        XCTAssertNil(DataLink.token(-1, 0))
        XCTAssertNil(DataLink.token(0, 281_474_976_710_656))
        let name = Array("Left/a.bin".utf8)
        let stream = DataLink.message(.file, [1, UInt8(name.count)] + name + [9, 8, 7]) + [0xFF, 0x7F, 0, 0, 1, 0, 0, 0, 5] + DataLink.message(.done, [1, 0])
        var parser = DataLink.Parser()
        var got: [(DataLink.Kind, [UInt8])] = []
        // Feed the stream one byte at a time and verify that unknown message kinds are skipped.
        for byte in stream {
            [byte].withUnsafeBytes { parser.add($0) }
            while let message = parser.next() { got.append((message.kind, message.payload)) }
        }
        XCTAssertEqual(got.map(\.0), [.file, .done])
        let file = DataLink.file(in: got[0].1)
        XCTAssertEqual(file?.set, 1)
        XCTAssertEqual(file.map { Array($0.name) }, name)
        XCTAssertEqual(file.map { Array($0.bytes) }, [9, 8, 7])
        // Reject messages whose declared payload length exceeds longestMessage.
        var greedy = DataLink.Parser()
        [UInt8]([2, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]).withUnsafeBytes { greedy.add($0) }
        XCTAssertNil(greedy.next())
        XCTAssertTrue(greedy.failed)
    }

    func testDataLinkRejectsUnsafeFileNames() {
        for good in ["a.bin", "Left/LeftController.gltf", "Normal_OpenGL.png", "a-b/c.d"] { XCTAssertTrue(DataLink.isSafe(name: Array(good.utf8)[...]), good) }
        for bad in ["", "..", "../a", "a/../b", "/a", "a/", "a//b", "a/b/c", ".hidden", "a/.b", "a\\b", "C:a", "a b", String(repeating: "a", count: 97)] {
            XCTAssertFalse(DataLink.isSafe(name: Array(bad.utf8)[...]), bad)
        }
        XCTAssertNil(DataLink.file(in: [1, 3] + Array("../".utf8)))
        XCTAssertNil(DataLink.file(in: [1, 9, 0x61]))
    }

    func testALiveClientGetsGammaAndTheHostKeys() {
        var host = HostSide(available: 1, enabled: 1, gamma: 1.8)
        host.models = 2
        var seen: [String: Double] = [:]
        for step in 0..<40 {
            let now = UInt64(step * 100)
            observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: now)), ("oxWant", 1)], at: now)
            let out = records([("dCurBW", 100), ("dCurBW", 100), ("dCurBW", 100)])
            defer { out.deallocate() }
            host.fill(out, count: 3, atMilliseconds: now)
            XCTAssertTrue(Handshake.record(out + 32, hasKey: "dCurBW") && Handshake.record(out + 64, hasKey: "dCurBW"))
            XCTAssertEqual(Handshake.time(of: out), 9)
            for key in ["oxHost", "oxAvail", "oxOn", "oxGamma", "oxModels"] as [StaticString] where Handshake.record(out, hasKey: key) {
                seen["\(key)"] = Handshake.value(of: out)
            }
        }
        XCTAssertEqual(host.active(atMilliseconds: 3900), Handshake.gammaFeature)
        XCTAssertEqual(host.activeGamma(atMilliseconds: 3900), 1.8, accuracy: 1e-6)
        XCTAssertEqual(seen["oxModels"], 2)
        XCTAssertEqual(seen["oxAvail"], 1)
        XCTAssertEqual(seen["oxOn"], 1)
        XCTAssertEqual(seen["oxGamma"] ?? 0, 1.8, accuracy: 1e-6)
        XCTAssertEqual(seen["oxHost"].flatMap(Handshake.version(ofHeartbeat:)), Handshake.version)
        // The client goes away: everything is off again once its heartbeat stops.
        XCTAssertEqual(host.active(atMilliseconds: 3900 + Handshake.alive + 1), 0)
    }

    func testAFeatureNeedsThePatchTheSettingAndTheClient() {
        for (available, enabled, wants, expected) in [(1, 1, 1.0, 1), (0, 1, 1.0, 0), (1, 0, 1.0, 0), (1, 1, 0.0, 0)] as [(UInt32, UInt32, Double, UInt32)] {
            var host = HostSide(available: available, enabled: enabled, gamma: 2)
            for now in [0, 300, 600] as [UInt64] {
                observe(&host, [("oxClient", Handshake.heartbeat(atMilliseconds: now)), ("oxWant", wants)], at: now)
            }
            XCTAssertEqual(host.active(atMilliseconds: 600), expected)
        }
        XCTAssertEqual(Handshake.clamped(gamma: .nan), 1)
        XCTAssertEqual(Handshake.clamped(gamma: 0.2), 1)
        XCTAssertEqual(Handshake.clamped(gamma: 9), 3)
    }
}

final class ShaderPatchTests: XCTestCase {
    func testAContainerComesApartAndGoesBackTogether() {
        let parts = [DXBC.Chunk(tag: DXBC.tag("RDEF"), data: [1, 2, 3, 4]), DXBC.Chunk(tag: DXBC.tag("SHEX"), data: Array(0..<200))]
        let file = DXBC.build(parts)
        file.view { view in
            XCTAssertEqual(DXBC.chunks(view), parts)
            XCTAssertEqual(Array(file[4..<20]), DXBC.checksum(view))
        }
        XCTAssertNil(Array(file.dropLast()).view { DXBC.chunks($0) })
        XCTAssertNil(Array("not a shader, though long enough to be one".utf8).view { DXBC.chunks($0) })
        (file + Array("trailing".utf8)).view { XCTAssertEqual(DXBC.container($0).map(Array.init), file) }
    }

    func testThingsThatAreNotTheEncodeShadersAreRefused() {
        XCTAssertThrowsError(try Array("not a shader".utf8).view { try DXBC.patchGamma($0) }) { XCTAssertEqual($0 as? DXBC.PatchError, .notAShader) }
        let plain = DXBC.build([DXBC.Chunk(tag: DXBC.tag("RDEF"), data: Array("g_other\0".utf8)), DXBC.Chunk(tag: DXBC.tag("SHEX"), data: [UInt8](repeating: 0, count: 8))])
        XCTAssertThrowsError(try plain.view { try DXBC.patchGamma($0) }) { XCTAssertEqual($0 as? DXBC.PatchError, .noSpareConstant) }
        XCTAssertThrowsError(try Array("not spirv at all, no".utf8).view { try SPIRV.patchGamma($0) }) { XCTAssertEqual($0 as? SPIRV.PatchError, .notSPIRV) }
        let empty: [UInt8] = [0x03, 0x02, 0x23, 0x07, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try empty.view { try SPIRV.patchGamma($0) }) { XCTAssertEqual($0 as? SPIRV.PatchError, .missingFloatType) }
    }

    func testRealCompiledShadersCarryTheChecksumComputedHere() throws {
        let folder = try XCTUnwrap(RealFiles.path("OVRL_TEST_FXO_DIR") ?? RealFiles.path("OVRL_TEST_VRLINK_FXO").map { $0 }, "no shader folder named").self
        var checked = 0
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "fxo" {
            let file = try RealFiles.bytes(url)
            file.view { whole in
                guard let container = DXBC.container(whole), let chunks = DXBC.chunks(whole) else { return XCTFail(url.lastPathComponent) }
                XCTAssertEqual(Array(container[4..<20]), DXBC.checksum(container), url.lastPathComponent)
                XCTAssertEqual(DXBC.build(chunks), Array(container), url.lastPathComponent)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testTheRealCopyViewShadersPatch() throws {
        guard let folder = RealFiles.path("OVRL_TEST_VRLINK_FXO") else { throw XCTSkip("no Windows shader folder named") }
        for name in ["genforencode_ps_copy_view.fxo", "genforencode_ps_copy_view_cas.fxo", "genforencode_cs_copy_view.fxo", "genforencode_cs_copy_view_cas.fxo"] {
            let stock = try RealFiles.bytes(folder.appendingPathComponent(name))
            let patched = try stock.view { try DXBC.patchGamma($0) }
            // Eight instructions, 49 words, are added and nothing else changes size.
            XCTAssertEqual(patched.count, stock.view { DXBC.container($0)!.count } + 49 * 4, name)
            patched.view { XCTAssertEqual(Array(patched[4..<20]), DXBC.checksum($0)) }
            XCTAssertThrowsError(try patched.view { try DXBC.patchGamma($0) }) { XCTAssertEqual($0 as? DXBC.PatchError, .alreadyPatched) }
            try RealFiles.save(patched, as: name)
        }
        // The shaders after the copy pass have no sRGB conversion and are refused.
        let other = try RealFiles.bytes(folder.appendingPathComponent("encode_rgb_to_yuv_ps_y.fxo"))
        XCTAssertThrowsError(try other.view { try DXBC.patchGamma($0) })
    }

    /// Tests patching against both the July 2026 SPIR-V shaders (`OVRL_TEST_VRLINK_SHADERS`,
    /// unstripped) and the October 2026 shaders (`OVRL_TEST_VRLINK_SHADERS_STRIPPED`, stripped).
    func testTheRealVulkanShadersPatch() throws {
        var checked = 0
        for (variable, prefix, carrier) in [("OVRL_TEST_VRLINK_SHADERS", "genforencode_comp_", 12), ("OVRL_TEST_VRLINK_SHADERS_STRIPPED", "genforencode_cs_", 30)] {
            guard let folder = RealFiles.path(variable) else { continue }
            for kind in ["rgb", "luma", "chroma"] {
                let name = "\(prefix)\(kind).spv"
                let stock = try RealFiles.bytes(folder.appendingPathComponent(name))
                let patched = try stock.view { try SPIRV.patchGamma($0) }
                XCTAssertGreaterThan(patched.bytes.count, stock.count)
                // The spare float the shaders leave unread: `g_GameTexSize` in July, the last member since.
                XCTAssertEqual(patched.gammaConstant, carrier, name)
                XCTAssertThrowsError(try patched.bytes.view { try SPIRV.patchGamma($0) }) { XCTAssertEqual($0 as? SPIRV.PatchError, .alreadyPatched) }
                try RealFiles.save(patched.bytes, as: name)
                checked += 1
            }
        }
        try XCTSkipIf(checked == 0, "no Linux shader folder named")
    }
}
