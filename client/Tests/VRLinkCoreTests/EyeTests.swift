// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class EyeTests: XCTestCase {
    func testMessageWithoutTrackingMatchesTheReferenceClient() {
        // The 17 bytes every eye message of the reference capture carries.
        let message = EyesAndFace.message(gaze: nil, face: nil)
        XCTAssertEqual(message.value, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x3F, 0, 0, 0, 0, 0])
    }

    func testGazeAndFaceSizes() {
        let gaze = EyesAndFace.message(gaze: Vec3(0.3, 0, -1), face: nil)
        XCTAssertEqual(gaze.value.count, 0x11)
        XCTAssertEqual(gaze.value[13], 1)                       // valid
        let face = FaceExpressions(weights: [Float](repeating: 0.5, count: 70))
        let both = EyesAndFace.message(gaze: Vec3(0, 0, -1), face: face)
        XCTAssertEqual(both.value.count, 0x131)
        XCTAssertEqual(both.value[12], 2)                       // FB face tracking 2
        XCTAssertEqual(both.value[14], 70)
    }
}
