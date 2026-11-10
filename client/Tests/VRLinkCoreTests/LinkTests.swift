// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class LinkTests: XCTestCase {
    private let elements = [SVLElement(.goodbye, value: []), SVLElement(.videoPacket, id: 7, index: 2, value: Bytes(1...100))]
    // Made-up tokens: a kind, a digit, then 32 bytes as URL-safe base64.
    private let payload = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

    func testBothFormsSurviveTheRoundTrip() throws {
        for kind in ["MID0", "AES0"] {
            var link = try XCTUnwrap(SVLLink(token: kind + payload))
            let datagram = link.pack(sequence: 9, elements: elements)
            let back = try XCTUnwrap(link.unpack(datagram))
            XCTAssertEqual(back.count, 2)
            XCTAssertEqual(back[1].value, elements[1].value)
            XCTAssertEqual(back[1].id, 7)
            // A damaged datagram is not accepted.
            var damaged = datagram
            damaged[5] ^= 0x40
            XCTAssertNil(link.unpack(damaged))
        }
    }

    func testEncryptedDatagramsArePaddedAndOpaque() throws {
        var link = try XCTUnwrap(SVLLink(token: "AES0" + payload))
        let datagram = link.pack(sequence: 1, elements: elements)
        XCTAssertEqual(datagram.count % 16, 0)
        XCTAssertFalse(datagram.contains(Array(1...8)))       // the payload is not visible
    }

    func testUnknownTokenKindIsRefused() {
        XCTAssertNil(SVLLink(token: "XYZ0" + payload))
    }
}
