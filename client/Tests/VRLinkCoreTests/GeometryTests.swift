// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class GeometryTests: XCTestCase {
    /// The quaternion read off a pose's axes must equal yaw about world up
    /// followed by pitch about the head's right axis, written out by hand.
    func testQuaternionFromAxesMatchesYawThenPitch() {
        for (yaw, pitch) in [(0.0, 0.0), (0.7, 0.2), (-2.5, -0.9), (3.0, 1.2), (1.6, -0.3)] as [(Float, Float)] {
            let q = HeadPose(position: Vec3(0, 0, 0), yaw: yaw, pitch: pitch).pose.quaternion
            let cy = Float(cos(Double(yaw) / 2)), sy = Float(sin(Double(yaw) / 2))
            let cp = Float(cos(Double(pitch) / 2)), sp = Float(sin(Double(pitch) / 2))
            var expected = [cy * cp, cy * sp, sy * cp, -sy * sp]
            if expected[0] * q[0] + expected[1] * q[1] + expected[2] * q[2] + expected[3] * q[3] < 0 {
                expected = expected.map { -$0 }   // q and -q are the same rotation
            }
            for index in 0..<4 { XCTAssertEqual(q[index], expected[index], accuracy: 1e-4, "yaw \(yaw) pitch \(pitch)") }
        }
    }

    /// Turning left at one radian per second is an angular velocity of +1
    /// about the head's own up axis.
    func testAngularVelocityOfASteadyTurn() {
        let earlier = HeadPose(position: Vec3(0, 0, 0), yaw: 0.50).pose
        let now = HeadPose(position: Vec3(0.02, 0, 0), yaw: 0.51).pose
        let tracked = TrackedPose(pose: now).withVelocities(since: earlier, seconds: 0.01)
        XCTAssertEqual(tracked.angularVelocity.y, 1, accuracy: 1e-2)
        XCTAssertEqual(tracked.angularVelocity.x, 0, accuracy: 1e-3)
        XCTAssertEqual(tracked.linearVelocity.x, 2, accuracy: 1e-3)
    }

    /// A point on the frustum's edge lands on the edge of clip space, and
    /// reversed depth is 1 at the near plane.
    func testProjection() {
        let eye = HeadPose(position: Vec3(1, 2, 3), yaw: 0.4, pitch: -0.2).pose
        let frustum = Frustum(left: -0.8, right: 1.1, down: -0.9, up: 0.7)
        let corner = frustum.corners(from: eye, distance: 5)[1]          // top-right
        let clip = frustum.project(corner, from: eye, near: 0.1, far: 100, reversed: true)
        XCTAssertEqual(clip[0] / clip[3], 1, accuracy: 1e-4)
        XCTAssertEqual(clip[1] / clip[3], 1, accuracy: 1e-4)
        let near = frustum.project(eye.position + eye.forward * 0.1, from: eye, near: 0.1, far: 100, reversed: true)
        XCTAssertEqual(near[2] / near[3], 1, accuracy: 1e-4)
    }

    func testEnclosingFrustumOfATurnedEye() {
        let frustum = Frustum(left: -1.7, right: 1.0, down: -1.2, up: 1.0)
        let straight = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        let same = frustum.enclosing(turnedAs: straight)
        XCTAssertEqual(same.left, -1.7, accuracy: 1e-5)
        XCTAssertEqual(same.up, 1.0, accuracy: 1e-5)
        // An eye turned 1 degree to its left sees a little further left and less far right.
        let turned = HeadPose(position: Vec3(0, 0, 0), yaw: .pi / 180).pose
        let wider = frustum.enclosing(turnedAs: turned)
        XCTAssertLessThan(wider.left, -1.7)
        XCTAssertLessThan(wider.right, 1.0)
        XCTAssertEqual(atan(wider.right), atan(1.0) - .pi / 180, accuracy: 1e-3)
    }
}
