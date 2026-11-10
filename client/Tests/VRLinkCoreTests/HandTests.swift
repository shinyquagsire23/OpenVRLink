// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class HandTests: XCTestCase {
    private let wrist = Pose(position: Vec3(0.1, 1.2, -0.3), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))

    /// Undo `compressedSkeleton`, the way the reference client's decompressor does.
    private func decompress(_ data: Bytes) -> [(position: [Float], orientation: [Float])] {
        (0..<data.count / 8).map { bone in
            let first: UInt32 = data.integer(at: bone * 8), second: UInt32 = data.integer(at: bone * 8 + 4)
            let position = [0, 10, 20].map { (Float(first >> $0 & 0x3FF) * 0.0019550342 - 0.0009775171) * 0.175 - 0.175 }
            let largest = Int(second >> 30)
            var q = [Float](repeating: 0, count: 4), bits = second, sum: Float = 0
            for index in [3, 2, 1, 0] where index != largest {
                let size = Float(bits & 0x1FF) * 0.70710678 / 511
                q[index] = bits & 0x200 != 0 ? -size : size
                sum += size * size
                bits >>= 10
            }
            q[largest] = (1 - sum).squareRoot()
            return (position, q)
        }
    }

    func testSkeletonSurvivesCompression() {
        for side in Side.allCases {
            let hand = TrackedHand.flat(wrist: wrist, side: side)
            let bones = hand.bones(side), packed = hand.compressedSkeleton(side)
            XCTAssertEqual(bones.count, 31)
            XCTAssertEqual(packed.count, 248)
            for (bone, unpacked) in zip(bones, decompress(packed)) {
                for (a, b) in zip([bone.position.x, bone.position.y, bone.position.z], unpacked.position) {
                    XCTAssertEqual(a, b, accuracy: 0.0004)
                }
                // q and -q are the same rotation.
                let dot = zip(bone.orientation, unpacked.orientation).map { $0 * $1 }.reduce(0, +)
                XCTAssertEqual(abs(dot), 1, accuracy: 0.001)
            }
        }
    }

    func testStraightFingerBonesLieAlongTheirParents() {
        let bones = TrackedHand.flat(wrist: wrist, side: .left).bones(.left)
        // Index finger, second joint: 4 cm from the first, not bent.
        XCTAssertEqual(bones[8].position.x, 0.04, accuracy: 1e-5)
        XCTAssertEqual(bones[8].orientation[0], 1, accuracy: 1e-5)
        let mirrored = TrackedHand.flat(wrist: wrist, side: .right).bones(.right)
        XCTAssertEqual(mirrored[8].position.x, -0.04, accuracy: 1e-5)
    }

    func testGestures() {
        var hand = TrackedHand.flat(wrist: wrist, side: .right)
        var gestures = HandGestures(hand, previous: nil)
        XCTAssertEqual(gestures.pinch, [false, false, false, false])
        XCTAssertFalse(gestures.grip)

        // Bring the thumb tip to the index tip.
        hand.joints[TrackedHand.thumbTip].position = hand.joints[TrackedHand.tip(0)].position + Vec3(0, 0.01, 0)
        gestures = HandGestures(hand, previous: gestures)
        XCTAssertEqual(gestures.pinch, [true, false, false, false])
        XCTAssertEqual(gestures.inputBlock().count, 28)
        XCTAssertEqual(gestures.inputBlock()[0], 1)

        // Curl every fingertip back towards the wrist: a fist.
        for finger in 0..<4 {
            hand.joints[TrackedHand.tip(finger)].forward = wrist.forward * -1
        }
        hand.joints[TrackedHand.thumbTip].position = wrist.position
        gestures = HandGestures(hand, previous: nil)
        XCTAssertTrue(gestures.grip)
        XCTAssertFalse(gestures.point)
    }

    func testTheAimDirectionIgnoresTheThumb() {
        let head = Pose(position: Vec3(0, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        let hand = TrackedHand.flat(wrist: wrist, side: .right)
        var moved = hand
        for joint in 2...TrackedHand.thumbTip {
            moved.joints[joint].position = moved.joints[joint].position + Vec3(0.03, -0.02, 0.04)
        }
        let before = hand.aim(.right, head: head), after = moved.aim(.right, head: head)
        XCTAssertEqual(length(before.forward - after.forward), 0, accuracy: 1e-6)
        // Where the ray starts does follow the thumb.
        XCTAssertGreaterThan(length(before.position - after.position), 0.005)
    }

    func testPowerProps() {
        // The reference client's two constants, and a controller that is charging.
        XCTAssertEqual(DeviceProfile.powerProps(nil, reportsBattery: false), [0x3F, 0, 0, 0, 0x1A, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(DeviceProfile.powerProps(PowerState(level: 0.5, charging: false), reportsBattery: true),
                       [0x3F, 0, 0, 0, 0x1B, 0, 0, 0, 0, 0, 0, 0x3F])
        XCTAssertEqual(DeviceProfile.powerProps(PowerState(level: 0.5, charging: true), reportsBattery: true)[4], 0x1F)
    }

    func testHandMessageSize() {
        let hand = TrackedHand.flat(wrist: wrist, side: .left)
        let message = hand.message(.left, gestures: HandGestures(hand, previous: nil), aim: hand.aim(.left, head: wrist))
        XCTAssertEqual(message.value.count, 0x133)
        XCTAssertEqual(message.value[248], 0x02)     // left, tracked
    }

    func testOneEuroFilterSteadiesJitterAndFollowsMotion() {
        var filter = OneEuroFilterVec3(slowestCutoff: 1.5, speedGain: 20)
        // A still point with 1 mm of jitter at 480 samples a second comes out steadier.
        var worst: Float = 0
        for step in 0..<480 {
            let out = filter.smooth(Vec3(step % 2 == 0 ? 0.001 : -0.001, 0, 0), seconds: 1.0 / 480)
            if step > 240 { worst = max(worst, abs(out.x)) }
        }
        XCTAssertLessThan(worst, 0.0003)
        // Moving at 1 m/s it stays within a centimeter of the truth.
        var x: Float = 0, out = Vec3(0, 0, 0)
        for _ in 0..<480 {
            x += 1.0 / 480
            out = filter.smooth(Vec3(x, 0, 0), seconds: 1.0 / 480)
        }
        XCTAssertEqual(out.x, x, accuracy: 0.01)
    }
}
