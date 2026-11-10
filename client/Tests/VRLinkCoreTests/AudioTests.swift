// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class AudioTests: XCTestCase {
    /// A group as the host sends it: A (1024 bytes), B (shorter), and their
    /// XOR parity carrying the shorter length.
    private func group(_ number: UInt16) -> (a: SVLElement, b: SVLElement, parity: SVLElement, pcm: Bytes) {
        let a = (0..<1024).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ Int(number)) }
        let b = (0..<896).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) }
        var parity = a
        for index in b.indices { parity[index] ^= b[index] }
        return (SVLElement(.audioVariable, id: number * 3, index: 0x4B01, value: a),
                SVLElement(.audioVariable, id: number * 3 + 1, index: 0x4B01, value: b),
                SVLElement(.audioVariable, id: number * 3 + 2, index: 896, value: parity),
                a + b)
    }

    private func played(_ receiver: AudioReceiver, bytes: Int) -> Bytes {
        var samples = [Int16](repeating: 0, count: bytes / 2)
        samples.withUnsafeMutableBufferPointer { receiver.buffer.read(into: $0) }
        return samples.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }

    /// Feed two groups (enough to pass the start threshold), dropping one
    /// packet of the first, and check the audio comes out whole and in order.
    private func check(dropping position: Int) {
        let receiver = AudioReceiver()
        var expected = Bytes()
        for number: UInt16 in 0..<4 {
            let packets = group(number)
            expected += packets.pcm
            for (index, element) in [packets.a, packets.b, packets.parity].enumerated()
            where !(number == 0 && index == position) {
                receiver.accept(element)
            }
        }
        XCTAssertEqual(played(receiver, bytes: expected.count), expected)
        XCTAssertEqual(receiver.lost, 0)
    }

    func testNothingLost() { check(dropping: 3) }
    func testFirstPacketRebuiltFromParity() { check(dropping: 0) }
    func testSecondPacketRebuiltFromParity() { check(dropping: 1) }
    func testLostParityDoesNotMatter() { check(dropping: 2) }
}
