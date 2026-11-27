// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class HostExtensionsTests: XCTestCase {
    /// Feeds a patched host's four keys, with its heartbeat advancing every 250 ms.
    private func hear(_ extensions: inout HostExtensions, from: UInt64, to: UInt64, active: Double = 1, gamma: Double = 1.8) {
        for now in stride(from: from, through: to, by: 100) {
            extensions.receive(key: "oxHost", value: 65536 + Double(now / 250), atMilliseconds: now)
            extensions.receive(key: "oxAvail", value: 1, atMilliseconds: now)
            extensions.receive(key: "oxOn", value: active, atMilliseconds: now)
            extensions.receive(key: "oxGamma", value: gamma, atMilliseconds: now)
        }
    }

    func testAvailableFeaturesWaitForOxAvailRecord() {
        var extensions = HostExtensions()
        extensions.receive(key: "oxHost", value: 65536 + 1, atMilliseconds: 0)
        extensions.receive(key: "oxHost", value: 65536 + 2, atMilliseconds: 250)
        XCTAssertTrue(extensions.hostPresent(atMilliseconds: 250))
        XCTAssertFalse(extensions.availableHeard)
        extensions.receive(key: "oxAvail", value: 3, atMilliseconds: 300)
        XCTAssertTrue(extensions.availableHeard)
        XCTAssertEqual(extensions.available, [.encodingGamma, .headsetSettings])
    }

    /// Reads manufacturer (string 2) and model (string 3) from the nine 128-byte strings following the 4-byte mask.
    private func names(_ profile: DeviceProfile) -> (manufacturer: String, model: String) {
        let props = profile.startupValues()[DeviceProfile.ValueID.staticHMD] ?? []
        func text(_ index: Int) -> String {
            String(decoding: props[(4 + index * 128)..<(4 + (index + 1) * 128)].prefix { $0 != 0 }, as: UTF8.self)
        }
        return (text(2), text(3))
    }

    func testReportsNativeHeadsetModelWhenHostSupportsIt() {
        var profile = DeviceProfile()
        profile.systemName = "visionOS"
        XCTAssertEqual(names(profile).model, "OpenVRLink Headset")
        profile.tracksEyesOrFace = true
        XCTAssertEqual(names(profile).model, "Vive Focus Vision")
        profile.hostKnowsHeadset = true
        XCTAssertEqual(names(profile).model, "Apple Vision Pro (OpenVRLink)")
        XCTAssertEqual(names(profile).manufacturer, "Apple")
        profile.tracksEyesOrFace = false
        XCTAssertEqual(names(profile).model, "Apple Vision Pro (OpenVRLink)")
        profile.systemName = "macOS"
        XCTAssertEqual(names(profile).model, "OpenVRLink Headset")
    }

    func testReceivesHostControllerModelsBitmask() {
        var extensions = HostExtensions()
        XCTAssertNil(extensions.controllerModels)
        extensions.receive(key: "oxModels", value: 3, atMilliseconds: 0)
        XCTAssertEqual(extensions.controllerModels, 3)
        XCTAssertEqual(ControllerModelSet.playForDream.bit, 1)
        XCTAssertEqual(ControllerModelSet.galaxyXR.bit, 2)
    }

    func testReportsCustomControllerModelsOnlyWhenHostSupportsThem() {
        func model(_ profile: DeviceProfile, _ side: Side) -> String {
            // The render model is the fifth of the 128-byte strings after the 4-byte mask.
            let props = profile.handValues(side, isController: true)[DeviceProfile.ValueID.staticController(side)] ?? []
            return String(decoding: props[(4 + 4 * 128)..<(4 + 5 * 128)].prefix { $0 != 0 }, as: UTF8.self)
        }
        var profile = DeviceProfile()
        profile.ownControllerModels = .playForDream
        XCTAssertEqual(model(profile, .left), "oculus_quest2_controller_left")
        // Having a different headset's model set on the host falls back to Quest 2 Touch.
        profile.hostControllerModels = ControllerModelSet.galaxyXR.bit
        XCTAssertEqual(model(profile, .left), "oculus_quest2_controller_left")
        profile.hostControllerModels = ControllerModelSet.galaxyXR.bit | ControllerModelSet.playForDream.bit
        XCTAssertEqual(model(profile, .left), "{openvrlink}pfd_mr_controller_left")
        XCTAssertEqual(model(profile, .right), "{openvrlink}pfd_mr_controller_right")
        // Non-Play For Dream headsets keep Quest 2 Touch models regardless of host support.
        profile.ownControllerModels = .galaxyXR
        XCTAssertEqual(model(profile, .right), "{openvrlink}galaxy_xr_controller_right")
        profile.ownControllerModels = nil
        XCTAssertEqual(model(profile, .right), "oculus_quest2_controller_right")
    }

    func testControllersAreDescribedAsVRLinkDescribesThem() {
        // Matches `staticProps` and `poseAction` in vrlink's controller_config.json.
        XCTAssertEqual(ControllerModel.touchPro.staticStrings(.left),
                       ["oculus", "VRLINKQP_Controller_Left", "Oculus", "Oculus Quest Pro (Left Controller)", "oculus_quest_pro_controller_left",
                        "vrlink", "{oculus}/input/touch_profile.json", "oculus_touch", "oculus/VRLINKQP_Controller_Left"])
        XCTAssertEqual(ControllerModel.touchPlus.staticStrings(.right)[4], "oculus_quest_plus_controller_right")
        XCTAssertEqual(ControllerModel.pico4.staticStrings(.right),
                       ["pico", "VRLINKP4_Controller_Right", "PICO", "PICO 4 (Right Controller)", "pico_4_controller_right", "vrlink",
                        "{vrlink}/input/pico_controller_profile.json", "pico_controller", "PICO/VRLINKP4_Controller_Right"])
        XCTAssertEqual(ControllerModel.viveFocus3.staticStrings(.left)[8], "HTC/VRLINKVIVE_FOCUS3_Controller_Left")
        // Matches vrlink's Quest Touch grip offset, mirrored across X for the right hand.
        for (got, wanted) in zip(ControllerModel.touch.gripOffset(.left), [-0.007, -0.0342, -0.0961, 0.9839, -0.1788, 0, 0] as [Float]) {
            XCTAssertEqual(got, wanted, accuracy: 0.0001)
        }
        XCTAssertEqual(ControllerModel.touchPro.gripOffset(.right)[0], 0.007, accuracy: 1e-6)
        XCTAssertEqual(ControllerModel.picoNeo3.gripOffset(.right)[0], -0.003, accuracy: 1e-6)
        // Reported controller properties follow the active ControllerModel regardless of headset.
        func model(_ profile: DeviceProfile, _ kind: ControllerModel) -> String {
            let props = profile.handValues(.left, isController: true, model: kind)[DeviceProfile.ValueID.staticController(.left)] ?? []
            return String(decoding: props[(4 + 4 * 128)..<(4 + 5 * 128)].prefix { $0 != 0 }, as: UTF8.self)
        }
        XCTAssertEqual(model(DeviceProfile(), .touchPro), "oculus_quest_pro_controller_left")
        XCTAssertEqual(model(DeviceProfile(), .touch), "oculus_quest2_controller_left")
    }

    func testKnownHostsPersistsPerHost() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-hosts-\(UUID().uuidString)/hosts.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertFalse(KnownHosts(file: file).knowsHeadset(7))
        KnownHosts(file: file).set(7, knowsHeadset: true)
        KnownHosts(file: file).set(UInt64.max, knowsHeadset: false)
        XCTAssertTrue(KnownHosts(file: file).knowsHeadset(7))
        XCTAssertFalse(KnownHosts(file: file).knowsHeadset(UInt64.max))
        // Updating one per-host flag preserves the other.
        KnownHosts(file: file).set(7, controllerModels: 3)
        XCTAssertTrue(KnownHosts(file: file).knowsHeadset(7))
        XCTAssertEqual(KnownHosts(file: file).controllerModels(7), 3)
        XCTAssertEqual(KnownHosts(file: file).controllerModels(UInt64.max), 0)
        KnownHosts(file: file).set(7, knowsHeadset: false)
        XCTAssertFalse(KnownHosts(file: file).knowsHeadset(7))
        XCTAssertEqual(KnownHosts(file: file).controllerModels(7), 3)
        // Older hosts.json files without controllerModels still decode cleanly.
        try? Data(#"{"9":{"knowsHeadset":true}}"#.utf8).write(to: file)
        XCTAssertTrue(KnownHosts(file: file).knowsHeadset(9))
        XCTAssertEqual(KnownHosts(file: file).controllerModels(9), 0)
    }

    func testTheClientAnnouncesItselfWithAnAdvancingHeartbeat() {
        let extensions = HostExtensions()
        let first = extensions.records(atMilliseconds: 1000), later = extensions.records(atMilliseconds: 1250)
        XCTAssertEqual(first.map(\.key), ["oxClient", "oxWant"])
        XCTAssertEqual(first[0].value, 65536 + 4)
        XCTAssertEqual(later[0].value, 65536 + 5)
        XCTAssertEqual(first[1].value, 1)
        XCTAssertTrue(first.allSatisfy { HostExtensions.isExtensionKey($0.key) && $0.key.utf8.count <= 20 })
    }

    func testAStockHostLeavesFramesAlone() {
        var extensions = HostExtensions()
        extensions.receive(key: "dCurBW", value: 120, atMilliseconds: 10)
        XCTAssertFalse(extensions.hostPresent(atMilliseconds: 20))
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 20), 1)
        XCTAssertNil(extensions.hostVersion)
    }

    func testAPatchedHostSwitchesGammaOnAndOff() {
        var extensions = HostExtensions()
        hear(&extensions, from: 0, to: 1000)
        XCTAssertTrue(extensions.hostPresent(atMilliseconds: 1000))
        XCTAssertEqual(extensions.hostVersion, 1)
        XCTAssertEqual(extensions.available, [.encodingGamma])
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 1000), 1.8, accuracy: 1e-6)
        // The user switches it off in SteamVR.
        hear(&extensions, from: 1100, to: 1400, active: 0, gamma: 1)
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 1400), 1)
        // If the client clears encodingGamma from wants, encodingGamma() returns 1 even while the host reports it active.
        hear(&extensions, from: 1500, to: 1800)
        extensions.wants = []
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 1800), 1)
        XCTAssertEqual(extensions.records(atMilliseconds: 1800)[1].value, 0)
    }

    /// An unpatched host can echo stale `ox*` keys without advancing `oxHost`; those echoes must not mark the host as present.
    func testEchoedHostKeysAreNotAPatchedHost() {
        var extensions = HostExtensions()
        for now in stride(from: UInt64(0), through: 3000, by: 100) {
            extensions.receive(key: "oxHost", value: 65536 + 7, atMilliseconds: now)
            extensions.receive(key: "oxOn", value: 1, atMilliseconds: now)
            extensions.receive(key: "oxGamma", value: 2, atMilliseconds: now)
        }
        XCTAssertFalse(extensions.hostPresent(atMilliseconds: 3000))
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 3000), 1)
    }

    func testGammaStopsWhenTheHostGoesQuietAndStaysInRange() {
        var extensions = HostExtensions()
        hear(&extensions, from: 0, to: 1000, gamma: 50)
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 1000), 3)
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 1000 + HostExtensions.alive + 1), 1)
        extensions.receive(key: "oxGamma", value: .nan, atMilliseconds: 1000)
        extensions.receive(key: "oxHost", value: 12, atMilliseconds: 1000)
        XCTAssertEqual(extensions.encodingGamma(atMilliseconds: 1000), 3)
    }

    func testAFrameDescriptorYieldsOnlyTheHandshakeRecords() {
        // 0x20 header bytes, 0xF0 metadata, then the trailer: version 3, two records, no events, no value bytes.
        var value = Bytes(repeating: 0, count: 0x20 + 0xF0 + 0x10)
        value[0x16] = 0xF0
        value[0x20 + 0xF0 + 0x0C] = 3
        value[0x20 + 0xF0 + 0x0D] = 2
        for (key, number) in [("dCurBW", 100.0), ("oxGamma", 1.5)] {
            value.append(text: key, fieldSize: 20)
            value.append(double: number)
            value.append(integer: Int32(9))
        }
        let descriptor = FrameDescriptor(SVLElement(.frameDescriptor, value: value))
        XCTAssertEqual(descriptor.extensionRecords.map(\.key), ["oxGamma"])
        XCTAssertEqual(descriptor.extensionRecords.first?.value, 1.5)
        XCTAssertTrue(descriptor.valueTransportBytes.isEmpty)
    }
}
