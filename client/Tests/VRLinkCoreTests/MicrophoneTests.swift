// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class MicrophoneTests: XCTestCase {
    func testPacketsComeInPairsWithParity() {
        let uplink = MicrophoneUplink()
        uplink.capture(Bytes(repeating: 0x11, count: 1024 + 300))     // two packets: 1024 and 300 bytes
        let packets = uplink.takePackets()
        XCTAssertEqual(packets.map(\.id), [0, 1, 2])
        XCTAssertEqual(packets.map(\.value.count), [1024, 300, 1024])
        XCTAssertEqual(packets[0].index, 0x4B00)                      // 48 kHz mono
        XCTAssertEqual(packets[2].index, 300)                         // the shorter packet's length
        // The parity gives back either packet from the other.
        var rebuilt = packets[2].value
        for index in packets[0].value.indices { rebuilt[index] ^= packets[0].value[index] }
        XCTAssertEqual(Bytes(rebuilt.prefix(300)), packets[1].value)
        XCTAssertTrue(uplink.takePackets().isEmpty)
    }

    func testTheHostsReceiverLogicAcceptsThem() {
        // Our own receiver implements the same scheme: feed it A and the parity, and it rebuilds B.
        let uplink = MicrophoneUplink()
        uplink.capture(Bytes((0..<1024).map { UInt8($0 & 0xFF) }) + Bytes(repeating: 7, count: 512))
        let packets = uplink.takePackets()
        let receiver = AudioReceiver()
        receiver.accept(packets[0])
        receiver.accept(packets[2])
        XCTAssertEqual(receiver.recovered, 1)
    }
}
