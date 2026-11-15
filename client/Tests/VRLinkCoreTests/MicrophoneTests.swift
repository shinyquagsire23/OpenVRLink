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
        XCTAssertEqual(Bytes(rebuilt.prefix(300)), Bytes(packets[1].value))
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

    func testAPairMayBeSplitAcrossTwoTakings() {
        // Draining an odd number of packets saves the first packet and emits the parity packet once the second arrives.
        let uplink = MicrophoneUplink()
        uplink.capture(Bytes(repeating: 1, count: 960))
        XCTAssertEqual(uplink.takePackets().map(\.id), [0])
        uplink.capture(Bytes(repeating: 2, count: 960))
        let rest = uplink.takePackets()
        XCTAssertEqual(rest.map(\.id), [1, 2])
        XCTAssertEqual(Bytes(rest[1].value), Bytes(repeating: 3, count: 960))      // 1 xor 2
    }

    func testAStalledSessionLeavesNoMoreThanASecondForAStreamHost() {
        let uplink = MicrophoneUplink()
        // Capture 3 seconds of audio in 10 ms chunks without draining.
        for _ in 0..<300 { uplink.capture(Bytes(repeating: 0, count: 960)) }
        let packets = uplink.takePackets()
        // Only the last 1 second (100 data packets + 50 parity packets) is kept, with sequence numbers starting at 0 since dropped chunks were not packetized yet.
        XCTAssertEqual(packets.count, 150)
        XCTAssertEqual(packets.map(\.id), Array(0..<150))
    }

    // MARK: MicrophoneQueue

    func testWhatIsCapturedIsCutToPackets() {
        let queue = MicrophoneQueue(largestPacket: 1200, most: 48_000)
        queue.capture(Bytes((0..<3000).map { UInt8($0 & 0xFF) }))
        queue.capture([1, 2])
        let packets = queue.take()
        XCTAssertEqual(packets.map(\.count), [1200, 1200, 600, 2])
        XCTAssertEqual(packets[2].first, UInt8(2400 & 0xFF))                       // bytes stay in order without gaps
        XCTAssertEqual(packets[3], [1, 2])
        XCTAssertTrue(queue.take().isEmpty)
        queue.capture([])
        XCTAssertTrue(queue.take().isEmpty)
    }

    func testTheOldestGoesWhenTooMuchWaits() {
        let queue = MicrophoneQueue(largestPacket: 1000, most: 2500)
        for value in UInt8(1)...4 { queue.capture(Bytes(repeating: value, count: 1000)) }
        // Drops whole chunks from the front until the buffered byte count is within the limit.
        XCTAssertEqual(queue.take().map(\.first), [3, 4])
        // Draining resets the buffered byte count for subsequent captures.
        queue.capture(Bytes(repeating: 5, count: 2000))
        XCTAssertEqual(queue.take().map(\.count), [1000, 1000])
    }

    func testItMayBeFedFromOneThreadAndTakenFromAnother() {
        let queue = MicrophoneQueue(largestPacket: 100, most: 1_000_000)
        let fed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for _ in 0..<2000 { queue.capture(Bytes(repeating: 7, count: 250)) }
            fed.signal()
        }
        var taken = 0
        while fed.wait(timeout: .now()) != .success { taken += queue.take().reduce(0) { $0 + $1.count } }
        taken += queue.take().reduce(0) { $0 + $1.count }
        XCTAssertEqual(taken, 2000 * 250)
    }
}
