// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class MulticastDNSTests: XCTestCase {
    /// Encodes a name without compression.
    private func name(_ text: String) -> Bytes {
        text.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Bytes($0.utf8) } + [0]
    }

    private func record(_ owner: Bytes, type: UInt16, data: Bytes) -> Bytes {
        owner + [UInt8(type >> 8), UInt8(type & 0xFF), 0x80, 1, 0, 0, 0, 120, UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data
    }

    func testQueryAsksOneQuestion() {
        let query = MulticastDNS.query("_wivrn._tcp.local", kind: .pointer)
        XCTAssertEqual(Array(query[0..<12]), [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(query[12...]), name("_wivrn._tcp.local") + [0, 12, 0, 1])
    }

    func testJoinsPointerServiceAndAddressRecords() {
        // Build an Avahi-style mDNS response with a PTR answer and SRV and A additional records, compressing
        // the service type as a pointer to offset 12.
        let type = name("_wivrn._tcp.local")
        let instance: Bytes = [9] + Bytes("My Tower!".utf8) + [0xC0, 12]
        let host = name("tower.local")
        var message: Bytes = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 2]
        message += record(type, type: 12, data: instance)
        message += record(instance, type: 33, data: [0, 0, 0, 0, 0x26, 0x1D] + host)
        message += record(host, type: 1, data: [192, 168, 4, 77])
        let records = MulticastDNS.parse(message)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(MulticastDNS.services(of: "_wivrn._tcp.local", in: records),
                       [FoundService(name: "My Tower!", host: "192.168.4.77", port: 9757)])
    }

    func testFallsBackToTheHostNameWithoutAnAddress() {
        let type = name("_wivrn._tcp.local"), instance = name("Box._wivrn._tcp.local")
        var message: Bytes = [0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0]
        message += record(type, type: 12, data: instance)
        message += record(instance, type: 33, data: [0, 0, 0, 0, 0x23, 0x28] + name("Box.local"))
        XCTAssertEqual(MulticastDNS.services(of: "_wivrn._tcp.local", in: MulticastDNS.parse(message)),
                       [FoundService(name: "Box", host: "box.local", port: 9000)])
    }

    func testIgnoresQueriesAndSurvivesNonsense() {
        XCTAssertEqual(MulticastDNS.parse(MulticastDNS.query("_wivrn._tcp.local", kind: .pointer)), [])
        XCTAssertEqual(MulticastDNS.parse([0, 0, 0x84, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0xC0, 0x0C]), [])     // a name pointing at itself
        XCTAssertEqual(MulticastDNS.parse([1, 2, 3]), [])
        // Ignore PTR records that lack a matching SRV record.
        var message: Bytes = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        message += record(name("_wivrn._tcp.local"), type: 12, data: name("Gone._wivrn._tcp.local"))
        XCTAssertEqual(MulticastDNS.services(of: "_wivrn._tcp.local", in: MulticastDNS.parse(message)), [])
    }
}

final class ClientModelTests: XCTestCase {
    private final class Services: ServiceFinder {
        var report: (([FoundService]) -> Void)?
        var restarts = 0
        func start(onChange: @escaping ([FoundService]) -> Void) { report = onChange }
        func restart() { restarts += 1 }
    }

    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("client-model-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTargetsReadFromText() {
        XCTAssertEqual(ClientModel.Target(parsing: " 192.168.1.2\n"), ClientModel.Target(kind: .steam, address: "192.168.1.2"))
        XCTAssertEqual(ClientModel.Target(parsing: "steam://tower.local", kind: .wivrn), ClientModel.Target(kind: .steam, address: "tower.local"))
        XCTAssertEqual(ClientModel.Target(parsing: "wivrn://10.0.0.5:9000"), ClientModel.Target(kind: .wivrn, address: "10.0.0.5", port: 9000))
        XCTAssertEqual(ClientModel.Target(parsing: "10.0.0.5", kind: .wivrn), ClientModel.Target(kind: .wivrn, address: "10.0.0.5"))
        XCTAssertNil(ClientModel.Target(parsing: "  "))
        XCTAssertNil(ClientModel.Target(parsing: "wivrn://"))
    }

    func testConnectingStreamingAndStopping() {
        let services = Services()
        let model = ClientModel(finder: HostFinder(services: services), folder: folder)
        var started: [ClientModel.Target] = [], stopped: [Bool] = []
        var changes = 0
        model.startStream = { started.append($0) }
        model.stopStream = { stopped.append($0) }
        model.onChange = { changes += 1 }

        let host = FoundHost(name: "Tower", address: "192.168.1.9", kind: .wivrn, port: 9000)
        model.connect(to: host)
        XCTAssertEqual(started, [ClientModel.Target(kind: .wivrn, address: "192.168.1.9", port: 9000, name: "Tower")])
        XCTAssertEqual(model.state.phase, .connecting)
        // Ignore duplicate connect calls while already connecting.
        model.connect(to: ClientModel.Target(kind: .steam, address: "elsewhere"))
        XCTAssertEqual(started.count, 1)

        model.show("Reaching Tower")
        XCTAssertEqual(model.state.status, "Reaching Tower")
        model.streamStarted()
        XCTAssertEqual(model.state.phase, .streaming)
        // Pausing the session retains `target` so streaming can resume.
        model.streamPaused()
        XCTAssertEqual(model.state.phase, .connecting)
        XCTAssertEqual(model.state.target?.address, "192.168.1.9")
        model.streamStarted()

        model.stop()
        XCTAssertEqual(stopped, [true])
        XCTAssertEqual(model.state.phase, .choosing)
        XCTAssertNil(model.state.target)
        XCTAssertEqual(services.restarts, 1)
        // Calling `stop()` when already idle should not invoke `stopStream`.
        model.stop()
        XCTAssertEqual(stopped, [true])
        XCTAssertGreaterThan(changes, 4)
    }

    func testFailureReturnsToTheListWithTheReason() {
        let model = ClientModel(finder: HostFinder(services: nil), folder: folder)
        model.connect(to: ClientModel.Target(kind: .steam, address: "192.168.1.9"))
        model.streamEnded("Could not connect: no answer")
        XCTAssertEqual(model.state.phase, .choosing)
        XCTAssertEqual(model.state.status, "Could not connect: no answer")
        XCTAssertNil(model.state.target)
    }

    func testPinIsAskedAndAnswered() {
        let model = ClientModel(finder: HostFinder(services: nil), folder: folder)
        let answered = expectation(description: "answered")
        Thread.detachNewThread {
            XCTAssertEqual(model.askPin { false }, "246810")
            answered.fulfill()
        }
        while !model.state.askingForPin { Thread.sleep(forTimeInterval: 0.005) }
        model.answerPin("246810")
        wait(for: [answered], timeout: 2)
        XCTAssertFalse(model.state.askingForPin)

        // Stopping while the prompt is up cancels it.
        let canceled = expectation(description: "canceled")
        model.connect(to: ClientModel.Target(kind: .wivrn, address: "192.168.1.9"))
        Thread.detachNewThread {
            XCTAssertNil(model.askPin { false })
            canceled.fulfill()
        }
        while !model.state.askingForPin { Thread.sleep(forTimeInterval: 0.005) }
        model.stop()
        wait(for: [canceled], timeout: 2)
    }

    func testSettingsAndTypedAddressAreKept() {
        var model = ClientModel(finder: HostFinder(services: nil), folder: folder)
        var told: [Settings] = []
        model.onSettings = { told.append($0) }
        var settings = model.settings
        settings.microphone = true
        settings.fovScaleHorizontal = 99          // tidied to the range
        model.settings = settings
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(model.settings.fovScaleHorizontal, Settings.fovScaleRange.upperBound)
        var remembered = model.remembered
        remembered.address = "10.1.2.3"
        remembered.kind = .wivrn
        model.remembered = remembered

        // Saving happens in the background; wait for both files.
        for _ in 0..<200 where !(FileManager.default.fileExists(atPath: folder.appendingPathComponent("settings.json").path)
                                   && FileManager.default.fileExists(atPath: folder.appendingPathComponent("panel.json").path)) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        model = ClientModel(finder: HostFinder(services: nil), folder: folder)
        XCTAssertTrue(model.settings.microphone)
        XCTAssertEqual(model.remembered.address, "10.1.2.3")
        var asked: [ClientModel.Target] = []
        model.startStream = { asked.append($0) }
        model.connectToTyped()
        XCTAssertEqual(asked, [ClientModel.Target(kind: .wivrn, address: "10.1.2.3")])
    }

    func testFinderListsWiVRnHostsAfterSteamOnes() {
        let services = Services()
        let finder = HostFinder(services: services)
        // Drive the `ServiceFinder` callback directly without starting UDP broadcasts.
        var lists: [[FoundHost]] = []
        finder.onChange = { lists.append($0) }
        services.start { _ in }
        let model = ClientModel(finder: finder, folder: folder)
        finder.onChange?([FoundHost(name: "A", address: "1.1.1.1", kind: .steam), FoundHost(name: "B", address: "b.local", kind: .wivrn)])
        XCTAssertEqual(model.state.hosts.map(\.title), ["A", "B (WiVRn)"])
        XCTAssertEqual(model.state.hosts.map(\.id), ["steam 1.1.1.1", "wivrn b.local"])
    }

    func testStreamInterruptedPreservesTargetWhileStreamEndedClearsIt() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("model-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ClientModel(finder: HostFinder(services: nil), folder: folder)
        let target = ClientModel.Target(kind: .steam, address: "192.0.2.1", name: "PC")
        // Ignore streamInterrupted while in .choosing when no host is selected.
        model.streamInterrupted("lost")
        XCTAssertEqual(model.state.phase, .choosing)
        model.connect(to: target)
        model.streamStarted()
        XCTAssertEqual(model.state.phase, .streaming)
        model.streamInterrupted("no packets from host")
        XCTAssertEqual(model.state.phase, .connecting)
        XCTAssertEqual(model.state.target, target)
        XCTAssertEqual(model.state.status, "no packets from host")
        model.streamEnded("could not connect")
        XCTAssertEqual(model.state.phase, .choosing)
        XCTAssertNil(model.state.target)
    }

    func testResettingSettingsKeepsCalibrationsAndQuirks() {
        var settings = Settings()
        XCTAssertFalse(settings.differsFromDefaults)
        settings.chromaKey = true
        settings.fovScaleHorizontal = 1.3
        settings.microphone = true
        settings.quirkOverrides = ["video_range": "narrow"]
        XCTAssertTrue(settings.differsFromDefaults)
        let fresh = settings.resetToDefaults()
        XCTAssertFalse(fresh.chromaKey)
        XCTAssertEqual(fresh.fovScaleHorizontal, 1)
        XCTAssertFalse(fresh.microphone)
        XCTAssertEqual(fresh.quirkOverrides, ["video_range": "narrow"])
        XCTAssertFalse(fresh.differsFromDefaults)
        // Quirk overrides alone do not mark standard settings as modified.
        var onlyQuirks = Settings()
        onlyQuirks.quirkOverrides = ["wait_for_gpu": "0"]
        XCTAssertFalse(onlyQuirks.differsFromDefaults)
    }

    func testSettingsFormShowsWhatThePlatformHas() {
        XCTAssertEqual(SettingsForm.sections(for: []).map(\.title), ["Field of view"])
        let android = SettingsForm.sections(for: [.microphone, .chromaKey])
        XCTAssertEqual(android.map(\.title), ["Audio", "Chroma key", "Field of view"])
        XCTAssertEqual(android[1].items.count, 5)
        let everything = SettingsForm.sections(for: [.microphone, .handsOverlay, .systemOverlays, .controllersAndHands, .gazePinch,
                                                      .chromaKey, .window, .senseControllers])
        XCTAssertEqual(everything.flatMap(\.items).count, 14)
        // Each control reads and writes the setting it names.
        var settings = Settings()
        for item in everything.flatMap(\.items) {
            if case .toggle(let field) = item.control { settings[keyPath: field].toggle() }
        }
        XCTAssertNotEqual(settings, Settings())
        XCTAssertTrue(settings.microphone)
    }
}

final class HeadsetQuirksTests: XCTestCase {
    func testIdentifiesHeadsetsFromBuildFields() {
        func identify(_ manufacturer: String, _ model: String, _ device: String, _ product: String = "") -> HeadsetQuirks.Headset {
            HeadsetQuirks.identify(manufacturer: manufacturer, model: model, device: device, product: product)
        }
        XCTAssertEqual(identify("Oculus", "Quest 3", "eureka"), .quest3)
        XCTAssertEqual(identify("Oculus", "Quest", "somethingnew"), .quest)
        XCTAssertEqual(identify("samsung", "SM-I610", "xrvst2"), .galaxyXR)
        XCTAssertEqual(identify("samsung", "SM-S928B", "e3q"), .unknown)
        XCTAssertEqual(identify("Pico", "A8110", "PICO 4"), .pico)
        XCTAssertEqual(identify("Lynx Mixed Reality", "Lynx-R1", "lynx"), .lynx)
        XCTAssertEqual(identify("", "", ""), .unknown)
    }

    func testDefaultsFollowTheHeadsetAndOverridesWin() {
        XCTAssertTrue(HeadsetQuirks(.galaxyXR).floatTargetIsEncoded)
        XCTAssertTrue(HeadsetQuirks(.pico).floatTargetIsEncoded)
        // YVR and Play For Dream disable compositor layer placement and use XR_FB_passthrough.
        for headset in [HeadsetQuirks.Headset.yvr, .playForDream] {
            let quirks = HeadsetQuirks(headset)
            XCTAssertFalse(quirks.compositorPlacesLayers)
            XCTAssertTrue(quirks.passthroughLayer)
            XCTAssertEqual(quirks.sharpLayerPixels, 0)
        }
        XCTAssertTrue(HeadsetQuirks(.galaxyXR).compositorPlacesLayers)
        // Verify every panel option round-trips through `value(of:)` and `apply(_:)`.
        let usual = HeadsetQuirks(.galaxyXR)
        for option in HeadsetQuirks.options {
            let value = try? XCTUnwrap(usual.value(of: option.key), option.key)
            XCTAssertEqual(usual.overridden(by: [option.key: value ?? ""]), usual, option.key)
            if case .flag = option.kind {
                let flipped = usual.overridden(by: [option.key: value == "1" ? "0" : "1"])
                XCTAssertEqual(flipped.value(of: option.key), value == "1" ? "0" : "1", option.key)
            }
        }
        XCTAssertEqual(usual.overridden(by: ["video_range": "narrow", "sharp_layer": "0"]).videoRange, .narrow)
        XCTAssertEqual(usual.overridden(by: ["sharp_layer": "0"]).sharpLayerPixels, 0)
        var overridden = HeadsetQuirks(.playForDream)
        overridden.apply { ["compositor_places_layers": "1", "passthrough_layer": "0"][$0] }
        XCTAssertTrue(overridden.compositorPlacesLayers)
        XCTAssertFalse(overridden.passthroughLayer)
        XCTAssertFalse(HeadsetQuirks(.quest3).floatTargetIsEncoded)
        XCTAssertFalse(HeadsetQuirks(.quest3).floatTarget)

        var quirks = HeadsetQuirks(.quest3)
        let given = ["float_target": "1", "float_encoded": "true", "video_range": "full", "decoder_width": "1920",
                     "decoder_height": "99999", "decoder_low_latency": "0"]
        quirks.apply { given[$0] }
        XCTAssertTrue(quirks.floatTarget)
        XCTAssertTrue(quirks.floatTargetIsEncoded)
        XCTAssertEqual(quirks.videoRange, .full)
        XCTAssertEqual(quirks.decoderWidth, 1920)
        XCTAssertEqual(quirks.decoderHeight, 2048)        // out of range, ignored
        XCTAssertFalse(quirks.decoderLowLatency)
    }

    func testGripOffsetTakesAHeadsetsGripToAQuests() {
        XCTAssertTrue(HeadsetQuirks(.quest3).gripOffset.isNone)
        // ALVR pitches Quest's grip -15 deg and leaves Galaxy XR's unrotated (+5.5 cm in Z), so mapping Galaxy XR
        // to Quest pitches +15 deg and shifts +5.5 cm along Z.
        let offset = HeadsetQuirks(.galaxyXR).gripOffset
        XCTAssertEqual(offset.pitch, 15, accuracy: 0.01)
        XCTAssertEqual(offset.yaw, 0, accuracy: 0.01)
        XCTAssertEqual(offset.roll, 0, accuracy: 0.01)
        let left = offset.pose(for: .left), right = offset.pose(for: .right)
        XCTAssertEqual(left.position.x, -right.position.x, accuracy: 1e-6)
        XCTAssertEqual(left.position.z, right.position.z, accuracy: 1e-6)
        XCTAssertGreaterThan(left.position.z, 0.05)
        // Composing with ALVR's Quest offset recovers ALVR's common pose for Galaxy XR.
        let quest = HeadsetQuirks.GripOffset(x: -0.005, y: -0.005, pitch: -15).pose(for: .left)
        let common = left.placing(quest)
        XCTAssertEqual(common.position.x, 0, accuracy: 1e-5)
        XCTAssertEqual(common.position.y, 0, accuracy: 1e-5)
        XCTAssertEqual(common.position.z, 0.055, accuracy: 1e-5)
        XCTAssertEqual(common.forward.z, -1, accuracy: 1e-5)

        var quirks = HeadsetQuirks(.quest3)
        quirks.apply { $0 == "grip_offset" ? "0.01, 0, -0.02, 5, 0, 0" : nil }
        XCTAssertEqual(quirks.gripOffset, HeadsetQuirks.GripOffset(x: 0.01, z: -0.02, pitch: 5))
        // Rotating around +Y produces tangential linear velocity for an offset child pose.
        var tracked = TrackedPose(pose: Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)))
        tracked.angularVelocity = Vec3(0, 1, 0)
        let moved = tracked.placing(Pose(position: Vec3(0, 0, 0.1), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)))
        XCTAssertEqual(moved.linearVelocity.x, 0.1, accuracy: 1e-5)
        XCTAssertEqual(moved.angularVelocity.y, 1, accuracy: 1e-5)
        quirks.apply { $0 == "video_range" ? "auto" : nil }
        XCTAssertNil(quirks.videoRange)
        XCTAssertTrue(quirks.summary.contains("quest3"))
    }
}

final class PictureSizeTests: XCTestCase {
    private func bytes(_ hex: String) -> Bytes {
        var out: Bytes = []
        var rest = Substring(hex)
        while rest.count >= 2 {
            out.append(UInt8(rest.prefix(2), radix: 16)!)
            rest = rest.dropFirst(2)
        }
        return out
    }

    /// Writes bits most significant first, with Exp-Golomb codes, to build parameter sets for the tests.
    private struct Writer {
        var bits: [Int] = []
        mutating func put(_ value: Int, _ count: Int) { for shift in (0..<count).reversed() { bits.append(value >> shift & 1) } }
        mutating func unsigned(_ value: Int) {
            let code = value + 1, length = Int.bitWidth - code.leadingZeroBitCount
            put(0, length - 1)
            put(code, length)
        }
        var bytes: Bytes {
            var padded = bits + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { at in UInt8(padded[at..<at + 8].reduce(0) { $0 << 1 | $1 }) }
        }
    }

    func testHEVCSizeFromASteamHost() {
        // HEVC SPS captured from SteamVR for a 2048x8192 stream (stacked stereo views with foveation bands).
        let sps = bytes("4201012220000003009000000300000300b7a0010020008004d965d29084645d50c051848200020000030002000003009010")
        let size = PictureSize.hevc(sps)
        XCTAssertEqual(size?.width, 2048)
        XCTAssertEqual(size?.height, 8192)

        // Verify that `PictureSize.of` finds the SPS inside an Annex B access unit after the VPS.
        let unit: Bytes = [0, 0, 0, 1] + bytes("40010c01ffff2220000003009000000300000300b7970240") + [0, 0, 0, 1] + sps
            + [0, 0, 0, 1] + bytes("4401c1f3c0cc90") + [0, 0, 1, 0x26, 0x01, 0xAF, 0x00]
        let found = unit.withUnsafeBufferPointer { PictureSize.of(keyframe: $0, codec: .hevc) }
        XCTAssertEqual(found?.width, 2048)
        XCTAssertEqual(found?.height, 8192)
        XCTAssertNil(unit.withUnsafeBufferPointer { PictureSize.of(keyframe: $0, codec: .h264) })
    }

    func testH264SizeWithCropping() {
        // Build a High-profile 4:2:0 SPS for 1920x1080 (120x68 macroblocks with 8 luma rows cropped off the bottom).
        var writer = Writer()
        writer.put(0x67, 8)             // NAL header: sequence parameter set
        writer.put(100, 8)              // profile_idc: High
        writer.put(0, 8)
        writer.put(42, 8)               // level_idc
        writer.unsigned(0)              // seq_parameter_set_id
        writer.unsigned(1)              // chroma_format_idc
        writer.unsigned(0)
        writer.unsigned(0)
        writer.put(0, 1)
        writer.put(0, 1)                // no scaling matrix
        writer.unsigned(0)              // log2_max_frame_num_minus4
        writer.unsigned(0)              // pic_order_cnt_type
        writer.unsigned(2)
        writer.unsigned(1)              // max_num_ref_frames
        writer.put(0, 1)
        writer.unsigned(119)            // pic_width_in_mbs_minus1
        writer.unsigned(67)             // pic_height_in_map_units_minus1
        writer.put(1, 1)                // frame_mbs_only_flag
        writer.put(1, 1)
        writer.put(1, 1)                // frame_cropping_flag
        writer.unsigned(0)
        writer.unsigned(0)
        writer.unsigned(0)
        writer.unsigned(4)              // four chroma rows, eight luma rows
        let size = PictureSize.h264(writer.bytes)
        XCTAssertEqual(size?.width, 1920)
        XCTAssertEqual(size?.height, 1080)
    }

    func testTruncatedSetsAreRefused() {
        XCTAssertNil(PictureSize.hevc(bytes("42010122200000")))
        XCTAssertNil(PictureSize.h264([0x67, 100, 0, 42]))
        XCTAssertNil(([] as Bytes).withUnsafeBufferPointer { PictureSize.of(keyframe: $0, codec: .hevc) })
    }

    func testEmulationPreventionBytesAreSkipped() {
        var bits = PictureSize.Bits(nal: [0xFF, 0x00, 0x00, 0x03, 0x01, 0x80], headerBytes: 1)
        XCTAssertEqual(bits.bits(24), 0x000001)
        XCTAssertEqual(bits.unsigned(), 0)
        XCTAssertFalse(bits.ranOut)
        bits.skip(8)
        XCTAssertTrue(bits.ranOut)
    }
}
