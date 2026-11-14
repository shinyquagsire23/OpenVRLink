// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class FECTests: XCTestCase {
    private func stripe() -> [Bytes] {
        (0..<8).map { packet in
            (0..<1024).map { UInt8(truncatingIfNeeded: packet * 31 + $0 * 7 + ($0 >> 8) * 13) }
        }
    }

    private func fnv(_ bytes: Bytes) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// The expected hashes come from the Python in docs/svl-video/fec.md,
    /// which reproduced all 8,404 parity packets of a real host's stream.
    func testParityMatchesTheDocumentedCode() {
        let parity = FEC.encode(stripe())
        XCTAssertEqual(fnv(parity.p), 0x0fb8_6993_e7b4_0525)
        XCTAssertEqual(fnv(parity.q), 0xb560_ddab_d81d_21a5)
    }

    func testEverySingleAndDoubleLossIsRepaired() {
        let data = stripe()
        let parity = FEC.encode(data)
        let all: [Bytes?] = data + [parity.p, parity.q]
        for first in 0..<10 {
            for second in first..<10 {
                var received = all
                received[first] = nil
                received[second] = nil
                let repaired = FEC.repair(data: Array(received[0..<8]), p: received[8], q: received[9])
                let lost = [first, second].filter { $0 < 8 }
                XCTAssertEqual(repaired, Dictionary(lost.map { ($0, data[$0]) }, uniquingKeysWith: { a, _ in a }),
                               "lost \(first) and \(second)")
            }
        }
    }

    func testThreeLossesAreNotRepaired() {
        let data = stripe()
        let parity = FEC.encode(data)
        var received: [Bytes?] = data
        received[0] = nil; received[3] = nil; received[5] = nil
        XCTAssertNil(FEC.repair(data: received, p: parity.p, q: parity.q))
    }
}
