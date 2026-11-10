// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest
@testable import VRLinkCore

final class SettingsTests: XCTestCase {
    func testSettingsSurviveBeingSavedAndLoaded() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = Settings()
        settings.chromaKey = true
        settings.chromaKeyColor = [0.25, 0.5, 0.75]
        settings.fovScaleHorizontal = 1.2
        settings.gazePinchRays = true
        settings.save(to: file)
        XCTAssertEqual(Settings.load(from: file), settings)
    }

    func testTheChromaKeyCanBeLeftOffInGames() {
        var settings = Settings()
        XCTAssertNil(settings.chromaKeying(inGame: false))
        settings.chromaKey = true
        XCTAssertNotNil(settings.chromaKeying(inGame: false))
        XCTAssertNotNil(settings.chromaKeying(inGame: true))
        settings.chromaKeyOffInGames = true
        XCTAssertNotNil(settings.chromaKeying(inGame: false))
        XCTAssertNil(settings.chromaKeying(inGame: true))
    }

    func testAFileFromAnotherBuildKeepsDefaultsForWhatItLacks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // One setting known, one unknown, one out of range, one of the wrong type.
        try Data(#"{"chromaKey": true, "fromTheFuture": 3, "fovScaleVertical": 9, "microphone": "yes"}"#.utf8).write(to: file)
        var expected = Settings()
        expected.chromaKey = true
        expected.fovScaleVertical = Settings.fovScaleRange.upperBound
        XCTAssertEqual(Settings.load(from: file), expected)
    }

    func testNoFileMeansDefaults() {
        XCTAssertEqual(Settings.load(from: URL(fileURLWithPath: "/nonexistent/settings.json")), Settings())
    }

    func testFrustumScalesAcrossAndUpDownSeparately() {
        let scaled = Frustum(left: -1, right: 0.8, down: -0.9, up: 0.7).scaled(horizontal: 1.5, vertical: 0.5)
        XCTAssertEqual(scaled.left, -1.5, accuracy: 1e-6)
        XCTAssertEqual(scaled.right, 1.2, accuracy: 1e-6)
        XCTAssertEqual(scaled.down, -0.45, accuracy: 1e-6)
        XCTAssertEqual(scaled.up, 0.35, accuracy: 1e-6)
    }
}

final class ClackTests: XCTestCase {
    private let head = Pose(position: Vec3(0, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))

    private func controller(x: Float, z: Float = -0.3, velocity: Float) -> TrackedPose {
        var pose = TrackedPose(pose: Pose(position: Vec3(x, 1.6, z), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)))
        pose.linearVelocity = Vec3(velocity, 0, 0)
        return pose
    }

    /// Run the detector at 90 Hz from `start` for `seconds`, the controllers
    /// 10 cm apart and moving towards each other, stopping dead at each of `knocks`.
    private func run(_ detector: inout ClackDetector, from start: Double, seconds: Double, knocks: [Double],
                     z: Float = -0.3) -> Int {
        var completed = 0, time = start
        var pending = knocks
        while time < start + seconds {
            // A knock: both controllers lose 0.3 m/s between two looks.
            var speed: Float = 0.3
            if let next = pending.first, time >= next {
                speed = 0
                pending.removeFirst()
            }
            if detector.update(left: controller(x: -0.05, z: z, velocity: speed), right: controller(x: 0.05, z: z, velocity: -speed),
                               head: head, seconds: time) { completed += 1 }
            // The frame after a knock they are moving again; that jolt is part of the same knock.
            time += 1.0 / 90
        }
        return completed
    }

    func testTwoKnocksSwitchAndTwoMoreSwitchBack() {
        var detector = ClackDetector()
        XCTAssertEqual(run(&detector, from: 0, seconds: 2, knocks: [0.5, 0.9]), 1)
        XCTAssertTrue(detector.handsWanted)
        XCTAssertEqual(run(&detector, from: 5, seconds: 2, knocks: [5.5, 5.9]), 1)
        XCTAssertFalse(detector.handsWanted)
    }

    func testOneKnockDoesNothing() {
        var detector = ClackDetector()
        XCTAssertEqual(run(&detector, from: 0, seconds: 3, knocks: [0.5]), 0)
        XCTAssertFalse(detector.handsWanted)
    }

    func testKnocksTooFarApartInTimeDoNothing() {
        var detector = ClackDetector()
        XCTAssertEqual(run(&detector, from: 0, seconds: 4, knocks: [0.5, 2.5]), 0)
        XCTAssertFalse(detector.handsWanted)
    }

    func testKnocksAwayFromTheFaceDoNothing() {
        var detector = ClackDetector()
        XCTAssertEqual(run(&detector, from: 0, seconds: 2, knocks: [0.5, 0.9], z: -0.7), 0)
        XCTAssertFalse(detector.handsWanted)
    }
}

final class SystemPinchTests: XCTestCase {
    func testThePinchRayPointsWhereTheEyesLookedAndMovesWithTheHand() {
        let ray = SystemPinch.ray(origin: Vec3(0, 1.6, 0), direction: Vec3(0, 0, -2), handTravel: Vec3(0.01, 0, 0))
        XCTAssertEqual(ray.forward.z, -1, accuracy: 1e-6)
        XCTAssertEqual(ray.position.x, 0.035, accuracy: 1e-6)     // 1 cm of hand, 3.5 cm of ray
        XCTAssertEqual(ray.right.x, 1, accuracy: 1e-6)
        XCTAssertEqual(ray.up.y, 1, accuracy: 1e-6)
    }

    func testASystemPinchDecidesTheIndexPinch() {
        let wrist = Pose(position: Vec3(0, 1, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        var hand = TrackedHand.flat(wrist: wrist, side: .left)
        // Thumb tip on the index tip: a pinch, read off the joints.
        hand.joints[TrackedHand.thumbTip].position = hand.joints[TrackedHand.tip(0)].position
        XCTAssertTrue(HandGestures(hand, previous: nil).pinch[0])
        hand.systemPinch = .notPinching
        XCTAssertFalse(HandGestures(hand, previous: nil).pinch[0])
        let ray = SystemPinch.ray(origin: Vec3(0, 1.6, 0), direction: Vec3(0, 0, -1), handTravel: Vec3(0, 0, 0))
        hand.systemPinch = .pinching(ray: ray, pressed: false)
        XCTAssertFalse(HandGestures(hand, previous: nil).pinch[0])
        hand.systemPinch = .pinching(ray: ray, pressed: true)
        XCTAssertTrue(HandGestures(hand, previous: nil).pinch[0])
    }
}
