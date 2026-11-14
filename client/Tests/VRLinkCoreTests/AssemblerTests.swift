// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class AssemblerTests: XCTestCase {
    /// A made-up keyframe: HEVC parameter sets, an IDR slice start, then filler that never looks like a start code.
    private func frame(bytes count: Int, seed: UInt8) -> Bytes {
        var out: Bytes = [0, 0, 0, 1, 0x40, 0x01, 0x0C, 0, 0, 0, 1, 0x42, 0x01, 0x01, 0, 0, 0, 1, 0x44, 0x01, 0xC0, 0, 0, 0, 1, 0x26, 0x01]
        var value = seed
        while out.count < count {
            value = value &* 73 &+ 41
            out.append(value | 0x02)
        }
        return out
    }

    /// The frame as the host would send it: 1024-byte data packets, and P and Q parity per stripe of eight.
    private func packets(_ data: Bytes, id: UInt16) -> (data: [SVLElement], parity: [SVLElement]) {
        let count = (data.count + 1023) / 1024
        var dataPackets: [SVLElement] = [], parity: [SVLElement] = []
        for index in 0..<count {
            dataPackets.append(SVLElement(.videoPacket, id: id, index: UInt16(index), value: Bytes(data[index * 1024..<min(data.count, index * 1024 + 1024)])))
        }
        for stripe in 0..<(count + 7) / 8 {
            let blocks: [Bytes] = (0..<8).map { slot in
                let index = stripe * 8 + slot
                guard index < count else { return Bytes(repeating: 0, count: 1024) }
                var block = Bytes(dataPackets[index].value)
                block.append(zeros: 1024 - block.count)
                return block
            }
            let (p, q) = FEC.encode(blocks)
            parity.append(SVLElement(.videoPacket, id: id, index: UInt16(0x800 + stripe * 2), value: p))
            parity.append(SVLElement(.videoPacket, id: id, index: UInt16(0x800 + stripe * 2 + 1), value: q))
        }
        return (dataPackets, parity)
    }

    private func descriptor(id: UInt16, size: Int) -> FrameDescriptor {
        var value = Bytes(repeating: 0, count: 0x20 + 0xF0)
        for index in 0..<4 { value[0x08 + index] = UInt8(truncatingIfNeeded: size >> (index * 8)) }
        return FrameDescriptor(SVLElement(.frameDescriptor, id: id, value: value))
    }

    func testFrameComesOutByteForByteWithTwoPacketsLostPerStripe() {
        let original = frame(bytes: 20 * 1024 + 300, seed: 5)
        let sent = packets(original, id: 0)
        let assembler = FrameAssembler(now: 0)
        assembler.accept(descriptor: descriptor(id: 0, size: original.count), group: 0, now: 0)
        // Lose packets 1 and 6 of the first stripe, 9 of the second, and the short last one.
        for packet in sent.data where ![1, 6, 9, 20].contains(Int(packet.index)) { assembler.accept(packet: packet, now: 1) }
        XCTAssertTrue(assembler.takeFrames().isEmpty)
        for packet in sent.parity { assembler.accept(packet: packet, now: 2) }
        let frames = assembler.takeFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(Bytes(frames[0].data.bytes), original)
        XCTAssertEqual(assembler.repairedByFEC, 4)
    }

    func testLostPacketsAreAskedForAndThenComplete() {
        let original = frame(bytes: 20 * 1024 + 300, seed: 7)
        let sent = packets(original, id: 0)
        let assembler = FrameAssembler(now: 0)
        assembler.accept(descriptor: descriptor(id: 0, size: original.count), group: 0, now: 0)
        // Three lost from one stripe: more than its parity can repair.
        for packet in sent.data where ![1, 4, 6].contains(Int(packet.index)) { assembler.accept(packet: packet, now: 1) }
        for packet in sent.parity { assembler.accept(packet: packet, now: 2) }
        XCTAssertTrue(assembler.takeFrames().isEmpty)
        assembler.tick(now: 10_000)
        let requests = assembler.takeRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value, [1, 0, 4, 0, 6, 0])
        // One of the three comes back: the other two can now be repaired.
        assembler.accept(packet: sent.data[4], now: 11_000)
        let frames = assembler.takeFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first.map { Bytes($0.data.bytes) }, original)
    }

    func testPacketsBeforeTheDescriptorAreKept() {
        let original = frame(bytes: 3 * 1024, seed: 9)
        let sent = packets(original, id: 0)
        let assembler = FrameAssembler(now: 0)
        for packet in sent.data { assembler.accept(packet: packet, now: 1) }      // size not known yet: all are full length
        assembler.accept(descriptor: descriptor(id: 0, size: original.count), group: 0, now: 2)
        let frames = assembler.takeFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(Bytes(frames[0].data.bytes), original)
    }

    func testTakenMemoryLeavesTheBufferEmpty() {
        let buffer = FrameBuffer(copying: [1, 2, 3])
        let taken = buffer.takeMemory()
        XCTAssertEqual(taken?.count, 3)
        XCTAssertNil(buffer.takeMemory())
        XCTAssertEqual(buffer.bytes.count, 0)
        free(taken?.baseAddress)
    }
}
