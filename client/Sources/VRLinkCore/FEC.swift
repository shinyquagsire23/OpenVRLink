// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The video FEC (docs/svl-video/fec.md): a RAID-6 erasure code over stripes
/// of eight 1024-byte data packets plus two parity packets, P and Q. It is
/// jerasure's Liber8tion code, which needs only XOR.
///
/// Each packet is eight 128-byte sub-blocks. Every parity sub-block is the XOR
/// of a fixed set of data sub-blocks; repairing a stripe is solving those
/// equations for the sub-blocks that are missing.

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

    private static func xor(_ target: inout Bytes, _ source: ArraySlice<UInt8>) {
        var index = 0
        for byte in source {
            target[index] ^= byte
            index += 1
        }
    }

    private static func subBlock(_ packet: Bytes, _ index: Int) -> ArraySlice<UInt8> {
        packet[index * subBlockSize..<(index + 1) * subBlockSize]
    }

    /// P and Q for eight full-size data packets.
    static func encode(_ data: [Bytes]) -> (p: Bytes, q: Bytes) {
        var parity = [Bytes(), Bytes()]
        for (row, terms) in equations.enumerated() {
            var block = Bytes(repeating: 0, count: subBlockSize)
            for term in terms { xor(&block, subBlock(data[term.packet], term.subBlock)) }
            parity[row / subBlocks].append(contentsOf: block)
        }
        return (parity[0], parity[1])
    }

    /// Rebuild the missing data packets of a stripe. `data` has eight entries
    /// and `p`, `q` are the parity packets; nil means not received. Every
    /// present packet is 1024 bytes. Returns all eight data packets, or nil
    /// when what arrived is not enough.
    static func repair(data: [Bytes?], p: Bytes?, q: Bytes?) -> [Bytes]? {
        let missing = data.indices.filter { data[$0] == nil }
        if missing.isEmpty { return data.map { $0! } }
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
                xor(&system[row].value, pivotRow.value[...])
            }
            solved += 1
        }
        var result = data
        for packet in missing {
            var rebuilt = Bytes()
            for block in 0..<subBlocks {
                let column = unknownIndex[Term(packet: packet, subBlock: block)]!
                rebuilt.append(contentsOf: system[column].value)   // after elimination, row n solves unknown n
            }
            result[packet] = rebuilt
        }
        return result.map { $0! }
    }
}
