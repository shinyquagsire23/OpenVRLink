// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Video forward error correction (docs/svl-video/fec.md) using Jerasure's Liber8tion
/// RAID-6 erasure code. Each stripe consists of eight 1024-byte data packets plus two
/// parity packets (P and Q) computed using pure XOR operations.
///
/// Each packet is divided into eight 128-byte sub-blocks. Every parity sub-block is the
/// XOR of a fixed subset of data sub-blocks, and stripe recovery solves that linear system
/// over GF(2) for any missing sub-blocks.

enum FEC {
    static let dataPerStripe = 8
    static let subBlocks = 8
    static let subBlockSize = 128
    static let packetSize = subBlocks * subBlockSize

    /// qSource[j][r]: which sub-block of data packet j feeds sub-block r of Q.
    private static let qSource: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7],
        [7, 3, 0, 2, 6, 1, 5, 4],
        [6, 2, 4, 0, 7, 3, 1, 5],
        [2, 5, 7, 6, 0, 3, 4, 1],
        [5, 6, 1, 7, 2, 4, 3, 0],
        [1, 2, 3, 4, 5, 6, 7, 0],
        [3, 0, 6, 5, 1, 7, 4, 2],
        [4, 7, 1, 5, 3, 2, 0, 6],
    ]
    /// One extra term per data packet j >= 1: Q sub-block `row` also takes sub-block `column` of packet j.
    private static let qExtra: [Int: (row: Int, column: Int)] = [
        1: (4, 7), 2: (1, 3), 3: (5, 4), 4: (2, 0), 5: (7, 2), 6: (6, 5), 7: (3, 1),
    ]

    private struct Term: Hashable {
        let packet: Int
        let subBlock: Int
    }

    /// The sixteen parity equations: P sub-blocks 0...7, then Q sub-blocks 0...7.
    private static let equations: [[Term]] = {
        var rows: [[Term]] = []
        for subBlock in 0..<subBlocks {          // P is the plain XOR of the eight data packets
            rows.append((0..<dataPerStripe).map { Term(packet: $0, subBlock: subBlock) })
        }
        for row in 0..<subBlocks {
            var terms = Set((0..<dataPerStripe).map { Term(packet: $0, subBlock: qSource[$0][row]) })
            for (packet, extra) in qExtra where extra.row == row {
                terms.formSymmetricDifference([Term(packet: packet, subBlock: extra.column)])
            }
            rows.append(Array(terms))
        }
        return rows
    }()

    private static func xor<Source: Sequence>(_ target: inout Bytes, _ source: Source) where Source.Element == UInt8 {
        var index = 0
        for byte in source {
            target[index] ^= byte
            index += 1
        }
    }

    /// Returns the `index`-th 128-byte sub-block slice of `packet` without copying.
    private static func subBlock<Packet: RandomAccessCollection>(_ packet: Packet, _ index: Int) -> Packet.SubSequence
    where Packet.Element == UInt8, Packet.Index == Int {
        packet[packet.startIndex + index * subBlockSize..<packet.startIndex + (index + 1) * subBlockSize]
    }

    /// Computes the P and Q parity packets for eight 1024-byte data packets.
    static func encode(_ data: [Bytes]) -> (p: Bytes, q: Bytes) {
        var parity = [Bytes(), Bytes()]
        for (row, terms) in equations.enumerated() {
            var block = Bytes(repeating: 0, count: subBlockSize)
            for term in terms { xor(&block, subBlock(data[term.packet], term.subBlock)) }
            parity[row / subBlocks].append(contentsOf: block)
        }
        return (parity[0], parity[1])
    }

    /// Reconstructs missing data packets in an 8-packet stripe from the received data packets
    /// and optional `p` and `q` parity packets (`nil` indicates a lost packet). Present packets
    /// must be 1024 bytes and are read in place without copying. Returns recovered packets keyed
    /// by stripe index, or `nil` if too many packets were lost to recover.
    static func repair<Data: RandomAccessCollection, Parity: RandomAccessCollection>(
        data: [Data?], p: Parity?, q: Parity?
    ) -> [Int: Bytes]? where Data.Element == UInt8, Data.Index == Int, Parity.Element == UInt8, Parity.Index == Int {
        let missing = data.indices.filter { data[$0] == nil }
        if missing.isEmpty { return [:] }
        // One unknown per missing sub-block; an equation is a bitmask over the
        // unknowns plus the XOR of everything in it that is known.
        var unknownIndex: [Term: Int] = [:]
        for packet in missing {
            for block in 0..<subBlocks { unknownIndex[Term(packet: packet, subBlock: block)] = unknownIndex.count }
        }
        var system: [(mask: UInt32, value: Bytes)] = []
        for (parityIndex, parity) in [p, q].enumerated() {
            guard let parity else { continue }
            for row in 0..<subBlocks {
                var mask: UInt32 = 0
                var value = Bytes(subBlock(parity, row))
                for term in equations[parityIndex * subBlocks + row] {
                    if let unknown = unknownIndex[term] {
                        mask |= 1 << UInt32(unknown)
                    } else {
                        xor(&value, subBlock(data[term.packet]!, term.subBlock))
                    }
                }
                system.append((mask, value))
            }
        }
        // Gaussian elimination over GF(2).
        var solved = 0
        for column in 0..<unknownIndex.count {
            let bit: UInt32 = 1 << UInt32(column)
            guard let pivot = (solved..<system.count).first(where: { system[$0].mask & bit != 0 }) else { return nil }
            system.swapAt(solved, pivot)
            let pivotRow = system[solved]
            for row in system.indices where row != solved && system[row].mask & bit != 0 {
                system[row].mask ^= pivotRow.mask
                xor(&system[row].value, pivotRow.value)
            }
            solved += 1
        }
        var result: [Int: Bytes] = [:]
        for packet in missing {
            var rebuilt = Bytes()
            for block in 0..<subBlocks {
                let column = unknownIndex[Term(packet: packet, subBlock: block)]!
                rebuilt.append(contentsOf: system[column].value)   // after elimination, row n solves unknown n
            }
            result[packet] = rebuilt
        }
        return result
    }
}
