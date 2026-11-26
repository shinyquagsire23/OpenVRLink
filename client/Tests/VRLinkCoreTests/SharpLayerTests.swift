// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class SharpLayerTests: XCTestCase {
    private let ahead = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
    private let wide = Frustum(left: -1, right: 1, down: -1, up: 1)

    private func layout(sharp: Frustum?) -> FrameLayout {
        let view = FrameLayout.View(eye: ahead, tiles: [FrameLayout.Tile(frustum: wide)],
                                    sharp: sharp.map { FrameLayout.Sharp(frustum: $0, width: 2048, height: 2048) })
        return FrameLayout(views: [view, view], eyePixels: (2048, 2048))
    }

    func testSharpFrustumIsTheRegionItselfFromTheSamePose() throws {
        let region = Frustum(left: -0.2, right: 0.3, down: -0.4, up: 0.1)
        let seen = try XCTUnwrap(Composition.sharpFrustum(for: .left, layout: layout(sharp: region), from: EyeView(eye: ahead, frustum: wide)))
        XCTAssertEqual(seen.left, region.left, accuracy: 1e-4)
        XCTAssertEqual(seen.right, region.right, accuracy: 1e-4)
        XCTAssertEqual(seen.down, region.down, accuracy: 1e-4)
        XCTAssertEqual(seen.up, region.up, accuracy: 1e-4)
    }

    func testSharpFrustumFollowsAHeadTurnAndStopsAtTheViewEdge() throws {
        let region = Frustum(left: -0.25, right: 0.25, down: -0.25, up: 0.25)
        // Turning the head left moves the region right in view.
        let turned = ahead.turned(by: Vec3(0, 0.2, 0))
        let seen = try XCTUnwrap(Composition.sharpFrustum(for: .right, layout: layout(sharp: region), from: EyeView(eye: turned, frustum: wide)))
        XCTAssertGreaterThan(seen.left, region.left + 0.1)
        XCTAssertGreaterThan(seen.right, region.right + 0.1)
        // A region reaching past the edge of the view is cut off there.
        let edge = Frustum(left: 0.7, right: 1.2, down: -0.25, up: 0.25)
        let cut = try XCTUnwrap(Composition.sharpFrustum(for: .left, layout: layout(sharp: edge), from: EyeView(eye: ahead, frustum: wide)))
        XCTAssertEqual(cut.right, 1, accuracy: 1e-4)
    }

    func testNoSharpFrustumWithoutADenserPartOrOutOfView() {
        XCTAssertNil(Composition.sharpFrustum(for: .left, layout: layout(sharp: nil), from: EyeView(eye: ahead, frustum: wide)))
        let behind = ahead.turned(by: Vec3(0, .pi, 0))
        XCTAssertNil(Composition.sharpFrustum(for: .left, layout: layout(sharp: Frustum(left: -0.2, right: 0.2, down: -0.2, up: 0.2)),
                                               from: EyeView(eye: behind, frustum: wide)))
    }

    func testWiVRnLayoutNamesTheFullRateBand() throws {
        let view = WiVRnView(pose: ahead, frustum: wide)
        // Three bands of 100, 200, and 100 encoded pixels representing equal 200-pixel source bands.
        let squeeze = WiVRnFoveation(across: [100, 200, 100], down: [100, 200, 100])
        let foveated = WiVRnSession.layout(views: [view, view], foveation: [squeeze, squeeze], encoded: (400, 400))
        let sharp = try XCTUnwrap(foveated.views[0].sharp)
        XCTAssertEqual(sharp.frustum.left, -1.0 / 3, accuracy: 1e-4)
        XCTAssertEqual(sharp.frustum.right, 1.0 / 3, accuracy: 1e-4)
        XCTAssertEqual(sharp.width, 200)
        XCTAssertEqual(sharp.height, 200)
        let plain = WiVRnFoveation(across: [400], down: [400])
        XCTAssertNil(WiVRnSession.layout(views: [view, view], foveation: [plain, plain], encoded: (400, 400)).views[0].sharp)
    }
}
