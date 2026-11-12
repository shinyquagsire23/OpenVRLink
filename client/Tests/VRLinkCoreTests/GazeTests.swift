// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class GazeCalibrationTests: XCTestCase {
    /// A made-up eye: how its pupil features would relate to where it looks.
    private func truth(_ f: EyeFeatures) -> (across: Float, up: Float) {
        let a = f.across, d = f.down
        return (0.05 + 2.5 * a + 0.1 * d + 0.8 * a * a, -0.1 - 3 * d + 0.5 * a * d)
    }

    private func features(_ across: Float, _ down: Float) -> EyeFeatures {
        // The two eyes differ a little, as they do; the fit uses their average.
        EyeFeatures(leftAcross: across + 0.02, leftDown: down - 0.01, rightAcross: across - 0.02, rightDown: down + 0.01)
    }

    func testAFitRecoversTheRelationItWasShown() throws {
        var calibrator = GazeCalibrator()
        for across: Float in [-0.2, -0.1, 0, 0.1, 0.2] {
            for down: Float in [-0.1, 0, 0.1] {
                let f = features(across, down), t = truth(f)
                calibrator.add(f, across: t.across, up: t.up)
            }
        }
        let calibration = try XCTUnwrap(calibrator.fit())
        XCTAssertLessThan(calibration.typicalErrorDegrees, 0.3)
        XCTAssertEqual(calibration.sampleCount, 15)
        // A place it was not shown.
        let unseen = features(0.15, -0.05), expected = truth(unseen), got = calibration.tangents(for: unseen)
        XCTAssertEqual(got.across, expected.across, accuracy: 0.01)
        XCTAssertEqual(got.up, expected.up, accuracy: 0.01)
    }

    func testAFewSamplesGiveAPlaneAndTooFewGiveNothing() throws {
        var calibrator = GazeCalibrator()
        let places: [(Float, Float)] = [(-0.2, 0), (0.2, 0), (0, -0.1), (0, 0.1), (0, 0), (0.1, 0.1)]
        for (index, place) in places.enumerated() {
            if index == 4 { XCTAssertNil(calibrator.fit()) }                 // four so far
            let f = features(place.0, place.1), t = truth(f)
            calibrator.add(f, across: t.across, up: t.up)
        }
        let calibration = try XCTUnwrap(calibrator.fit())
        XCTAssertTrue(calibration.acrossTerms[3...].allSatisfy { $0 == 0 })
        XCTAssertTrue(calibration.usable)
        XCTAssertEqual(calibration.acrossTerms[1], 2.5, accuracy: 0.3)       // the slope of the made-up eye
        XCTAssertEqual(calibration.upTerms[2], -3, accuracy: 0.3)
    }

    func testSamplesAllInOnePlaceGiveNothing() {
        var calibrator = GazeCalibrator()
        for _ in 0..<12 { calibrator.add(features(0.1, 0.05), across: 0.3, up: -0.2) }
        XCTAssertNil(calibrator.fit())
    }

    func testARayBecomesTangentsInTheHeadsFrame() throws {
        // A head turned to face +x: its right is +z.
        let head = Pose(position: Vec3(0, 1.6, 0), right: Vec3(0, 0, 1), up: Vec3(0, 1, 0), forward: Vec3(1, 0, 0))
        let tangents = try XCTUnwrap(GazeCalibrator.tangents(ofRay: Vec3(2, 0.5, 1), head: head))
        XCTAssertEqual(tangents.across, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tangents.up, 0.25, accuracy: 1e-6)
        XCTAssertNil(GazeCalibrator.tangents(ofRay: Vec3(-1, 0, 0), head: head))
    }

    /// A calibration of the made-up eye from fifteen places.
    private func calibrated() throws -> GazeCalibration {
        var calibrator = GazeCalibrator()
        for across: Float in [-0.2, -0.1, 0, 0.1, 0.2] {
            for down: Float in [-0.1, 0, 0.1] {
                let f = features(across, down), t = truth(f)
                calibrator.add(f, across: t.across, up: t.up)
            }
        }
        return try XCTUnwrap(calibrator.fit())
    }

    func testTuningFollowsAHeadsetThatHasShifted() throws {
        var calibration = try calibrated()
        // The headset slips: everything now looks 0.1 further right than the calibration thinks.
        let places: [(Float, Float)] = [(0, 0), (0.1, 0.05), (-0.1, -0.05), (0.05, -0.08), (-0.15, 0.06), (0.18, 0)]
        let probe = features(0.03, 0.02), before = calibration.tangents(for: probe)
        for round in 0..<10 {
            for place in places {
                let f = features(place.0 + Float(round) * 0.001, place.1), t = truth(f)
                calibration = try XCTUnwrap(calibration.tuned(with: GazeSample(features: f, across: t.across + 0.1, up: t.up)))
            }
        }
        let after = calibration.tangents(for: probe)
        XCTAssertEqual(after.across - before.across, 0.1, accuracy: 0.015)
        XCTAssertEqual(after.up, before.up, accuracy: 0.015)
        XCTAssertEqual(calibration.samples.count, GazeCalibration.mostSamples)
    }

    func testTuningLeavesOutAPairThatCannotBeRight() throws {
        let calibration = try calibrated()
        let f = features(0.1, 0), t = truth(f)
        XCTAssertNil(calibration.tuned(with: GazeSample(features: f, across: t.across + 0.5, up: t.up)))
        XCTAssertNotNil(calibration.tuned(with: GazeSample(features: f, across: t.across + 0.05, up: t.up)))
    }

    func testAFullCalibrationKeepsItsEdgesWhenTunedInTheMiddle() throws {
        var calibration = try calibrated()
        for index in 0..<200 {
            let f = features(Float(index % 5) * 0.004, Float(index % 3) * 0.004), t = truth(f)
            calibration = try XCTUnwrap(calibration.tuned(with: GazeSample(features: f, across: t.across, up: t.up)))
        }
        XCTAssertEqual(calibration.samples.count, GazeCalibration.mostSamples)
        // The corners of the first calibration are still among the samples, and still fitted.
        let corner = features(-0.2, 0.1), expected = truth(corner)
        XCTAssertTrue(calibration.samples.contains { $0.features == corner })
        XCTAssertEqual(calibration.tangents(for: corner).across, expected.across, accuracy: 0.02)
    }

    func testACalibrationSavedWithoutSamplesStillReadsAndIsNotTuned() throws {
        let old = #"{"acrossTerms":[0,1,0,0,0,0,0,0],"upTerms":[0,0,-1,0,0,0,0,0],"typicalErrorDegrees":1,"sampleCount":19}"#
        let calibration = try JSONDecoder().decode(GazeCalibration.self, from: Data(old.utf8))
        XCTAssertTrue(calibration.usable)
        XCTAssertNil(calibration.tuned(with: GazeSample(features: features(0, 0), across: 0, up: 0)))
    }

    func testACalibrationSurvivesTheSettingsFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-gaze-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = Settings()
        settings.faceFromCamera = true
        settings.gazeCalibration = GazeCalibration(acrossTerms: [0, 1, 2, 3, 4, 5], upTerms: [5, 4, 3, 2, 1, 0],
                                                   typicalErrorDegrees: 1.5, sampleCount: 13)
        settings.save(to: file)
        XCTAssertEqual(Settings.load(from: file), settings)
    }
}

final class FaceEstimatorTests: XCTestCase {
    /// A plain face in a square bounding box. `pupil` moves both pupils
    /// (in box units, +x to the picture's right, +y up); `mouthOpen` parts the lips.
    private func face(pupil: (Float, Float) = (0, 0), mouthOpen: Float = 0.005, tilt: Float = 0) -> FaceLandmarks {
        func eye(_ cx: Float, _ cy: Float) -> [LandmarkPoint] {
            [(-0.06, 0), (-0.03, 0.02), (0, 0.025), (0.03, 0.02), (0.06, 0), (0.03, -0.02), (0, -0.025), (-0.03, -0.02)]
                .map { LandmarkPoint(cx + Float($0.0), cy + Float($0.1)) }
        }
        func lips(_ halfWidth: Float, _ halfHeight: Float) -> [LandmarkPoint] {
            // Round the mouth, starting at the picture's right corner.
            (0..<10).map { index in
                let angle = Double(index) / 10 * 2 * Double.pi
                return LandmarkPoint(0.5 + halfWidth * Float(cos(angle)), 0.3 + halfHeight * Float(sin(angle)))
            }
        }
        var lm = FaceLandmarks()
        lm.boxWidth = 0.4
        lm.boxHeight = 0.4
        lm.leftEye = eye(0.35, 0.65)
        lm.rightEye = eye(0.65, 0.65)
        lm.leftPupil = [LandmarkPoint(0.35 + pupil.0, 0.65 + pupil.1)]
        lm.rightPupil = [LandmarkPoint(0.65 + pupil.0, 0.65 + pupil.1)]
        lm.leftBrow = [LandmarkPoint(0.29, 0.72), LandmarkPoint(0.35, 0.74), LandmarkPoint(0.41, 0.72)]
        lm.rightBrow = [LandmarkPoint(0.59, 0.72), LandmarkPoint(0.65, 0.74), LandmarkPoint(0.71, 0.72)]
        lm.outerLips = lips(0.12, 0.03 + mouthOpen)
        lm.innerLips = lips(0.09, mouthOpen)
        lm.noseCrest = [LandmarkPoint(0.5, 0.6), LandmarkPoint(0.5, 0.5)]
        if tilt != 0 {
            // The whole face turned about the middle of the box.
            let s = Float(sin(Double(tilt))), c = Float(cos(Double(tilt)))
            func turned(_ points: [LandmarkPoint]) -> [LandmarkPoint] {
                points.map { LandmarkPoint(0.5 + c * ($0.x - 0.5) - s * ($0.y - 0.5), 0.5 + s * ($0.x - 0.5) + c * ($0.y - 0.5)) }
            }
            lm.leftEye = turned(lm.leftEye); lm.rightEye = turned(lm.rightEye)
            lm.leftPupil = turned(lm.leftPupil); lm.rightPupil = turned(lm.rightPupil)
            lm.leftBrow = turned(lm.leftBrow); lm.rightBrow = turned(lm.rightBrow)
            lm.outerLips = turned(lm.outerLips); lm.innerLips = turned(lm.innerLips)
            lm.noseCrest = turned(lm.noseCrest)
        }
        return lm
    }

    func testPupilsMoveTheEyeFeatures() throws {
        var estimator = FaceEstimator()
        let centred = try XCTUnwrap(estimator.estimate(face(), eyeSpacing: 0.063)).eyes
        XCTAssertEqual(centred.across, 0, accuracy: 0.01)
        XCTAssertEqual(centred.down, 0, accuracy: 0.02)
        let right = try XCTUnwrap(estimator.estimate(face(pupil: (0.03, 0)), eyeSpacing: 0.063)).eyes
        XCTAssertEqual(right.across, 0.25, accuracy: 0.01)                   // a quarter of the eye's width
        let lowered = try XCTUnwrap(estimator.estimate(face(pupil: (0, -0.012)), eyeSpacing: 0.063)).eyes
        XCTAssertEqual(lowered.down, 0.1, accuracy: 0.02)                    // a tenth of the eye's width
    }

    func testATiltedHeadGivesTheSameFeatures() throws {
        var upright = FaceEstimator(), tilted = FaceEstimator()
        let a = try XCTUnwrap(upright.estimate(face(pupil: (0.02, -0.01)), eyeSpacing: 0.063)).eyes
        let b = try XCTUnwrap(tilted.estimate(face(pupil: (0.02, -0.01), tilt: 0.3), eyeSpacing: 0.063)).eyes
        XCTAssertEqual(a.across, b.across, accuracy: 0.02)
        XCTAssertEqual(a.down, b.down, accuracy: 0.02)
    }

    func testAnOpenMouthDropsTheJaw() throws {
        var estimator = FaceEstimator()
        let shut = try XCTUnwrap(estimator.estimate(face(), eyeSpacing: 0.063)).face
        let open = try XCTUnwrap(estimator.estimate(face(mouthOpen: 0.08), eyeSpacing: 0.063)).face
        XCTAssertLessThan(shut.weights[FaceExpression.jawDrop.rawValue], 0.2)
        XCTAssertGreaterThan(open.weights[FaceExpression.jawDrop.rawValue], 0.6)
        XCTAssertEqual(FaceExpression.allCases.count, FaceExpressions.weightCount)
        XCTAssertEqual(FaceExpression.tongueRetreat.rawValue, 69)
        XCTAssertEqual(FaceExpression.jawDrop.rawValue, 24)
    }

    func testAFaceWithoutEyesGivesNothing() {
        var estimator = FaceEstimator()
        var lm = face()
        lm.leftPupil = []
        XCTAssertNil(estimator.estimate(lm, eyeSpacing: 0.063))
    }
}

final class FaceCalibrationTests: XCTestCase {
    private func calibration() -> FaceCalibration {
        var rest = FaceMeasures()
        rest.mouthOpen = 0.01; rest.mouthWidth = 0.40; rest.mouthWidthL = 0.20; rest.mouthWidthR = 0.20
        rest.browLiftL = 0.06; rest.browLiftR = 0.06; rest.eyeOpenL = 0.20; rest.eyeOpenR = 0.20
        var poses: [FacePose: FaceMeasures] = [:]
        for pose in FacePose.allCases { poses[pose] = rest }
        poses[.jawOpen]?.mouthOpen = 0.21
        poses[.smile]?.mouthWidthL = 0.26; poses[.smile]?.mouthWidthR = 0.26; poses[.smile]?.mouthWidth = 0.52
        poses[.pucker]?.mouthWidth = 0.28
        poses[.frown]?.cornerDropL = 0.03; poses[.frown]?.cornerDropR = 0.03
        poses[.browsUp]?.browLiftL = 0.10; poses[.browsUp]?.browLiftR = 0.10
        poses[.browsDown]?.browLiftL = 0.04; poses[.browsDown]?.browLiftR = 0.04
        poses[.eyesClosed]?.eyeOpenL = 0.02; poses[.eyesClosed]?.eyeOpenR = 0.02
        poses[.eyesWide]?.eyeOpenL = 0.30; poses[.eyesWide]?.eyeOpenR = 0.30
        return FaceCalibration(poses: poses)
    }

    private func weight(_ weights: [Float], _ expression: FaceExpression) -> Float { weights[expression.rawValue] }

    func testEachWeightIsHowFarTheFaceHasGoneTowardsItsPose() throws {
        let fit = calibration()
        XCTAssertTrue(fit.usable)
        let fallback = [Float](repeating: 0.5, count: FaceExpressions.weightCount)
        var face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        // At rest nothing is on, whatever the rules of thumb said, except where the eyes look.
        var weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 0)
        XCTAssertEqual(weight(weights, .lipCornerPullerL), 0)
        XCTAssertEqual(weight(weights, .eyesLookUpL), 0.5)

        face.mouthOpen = 0.11                       // halfway to the open pose
        face.mouthWidthL = 0.26                     // the left half fully at the smile
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 0.5, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipCornerPullerL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipCornerPullerR), 0, accuracy: 0.01)
    }

    func testTheTwoSidesArePushedApart() throws {
        let fit = calibration()
        let fallback = [Float](repeating: 0, count: FaceExpressions.weightCount)
        var face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        // A wink as the picture shows it: one eye mostly shut, the other dragged half-way along.
        face.eyeOpenL = 0.20 - 0.18 * 0.7
        face.eyeOpenR = 0.20 - 0.18 * 0.35
        // One brow up, the other following a little.
        face.browLiftL = 0.06 + 0.04 * 0.6
        face.browLiftR = 0.06 + 0.04 * 0.2
        var weights = fit.weights(for: face, fallback: fallback)
        XCTAssertGreaterThan(weight(weights, .eyesClosedL), 0.95)
        XCTAssertLessThan(weight(weights, .eyesClosedR), 0.05)
        XCTAssertLessThan(weight(weights, .innerBrowRaiserR), 0.05)
        // The left brow is up, but its eye is shut, which holds the brow down.
        XCTAssertLessThan(weight(weights, .innerBrowRaiserL), 0.1)
        XCTAssertEqual(weight(weights, .browLowererL), 0.7, accuracy: 0.05)

        // Both eyes shut stay both shut.
        face.eyeOpenL = 0.02; face.eyeOpenR = 0.02
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .eyesClosedL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .eyesClosedR), 1, accuracy: 0.01)

        // One brow raised with both eyes open.
        face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        face.browLiftL = 0.06 + 0.04 * 0.6
        face.browLiftR = 0.06 + 0.04 * 0.2
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertGreaterThan(weight(weights, .innerBrowRaiserL), 0.95)
        XCTAssertLessThan(weight(weights, .innerBrowRaiserR), 0.05)

        // A slight frown is sent as a clear one.
        face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        face.cornerDropL = 0.012; face.cornerDropR = 0.012               // 40 % of the way
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .lipCornerDepressorL), 1, accuracy: 0.01)
    }

    /// Measurements like those recorded on the headset: a frown widens the
    /// mouth, and an open jaw narrows it nearly as much as a pucker does.
    func testAFrownIsNotASmileAndAGaspIsAPuckerWithTheJawOpen() throws {
        var fit = calibration()
        fit.poses[FacePose.frown.rawValue]?.mouthWidth = 0.43
        fit.poses[FacePose.frown.rawValue]?.mouthWidthL = 0.215
        fit.poses[FacePose.frown.rawValue]?.mouthWidthR = 0.215
        fit.poses[FacePose.jawOpen.rawValue]?.mouthWidth = 0.31
        let fallback = [Float](repeating: 0, count: FaceExpressions.weightCount)

        var weights = fit.weights(for: try XCTUnwrap(fit.poses[FacePose.frown.rawValue]), fallback: fallback)
        XCTAssertEqual(weight(weights, .lipCornerDepressorL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipCornerPullerL), 0, accuracy: 0.01)

        // The jaw-open pose itself: no pucker.
        weights = fit.weights(for: try XCTUnwrap(fit.poses[FacePose.jawOpen.rawValue]), fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipPuckerL), 0, accuracy: 0.01)

        // Jaw open and the mouth as narrow as the pucker pose: a gasp.
        var gasp = try XCTUnwrap(fit.poses[FacePose.jawOpen.rawValue])
        gasp.mouthWidth = 0.28
        weights = fit.weights(for: gasp, fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipPuckerL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipFunnelerLT), 1, accuracy: 0.01)

        // The pucker pose itself: all pucker, no funnel.
        weights = fit.weights(for: try XCTUnwrap(fit.poses[FacePose.pucker.rawValue]), fallback: fallback)
        XCTAssertEqual(weight(weights, .lipPuckerL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipFunnelerLT), 0, accuracy: 0.01)
    }

    func testACalibrationMissingAPoseLeavesTheRulesOfThumb() {
        var fit = calibration()
        fit.poses[FacePose.pucker.rawValue] = nil
        XCTAssertFalse(fit.usable)
        let fallback = [Float](repeating: 0.25, count: FaceExpressions.weightCount)
        XCTAssertEqual(fit.weights(for: FaceMeasures(), fallback: fallback), fallback)
    }

    func testEyeDirectionWeightsFollowTheGaze() {
        var face = FaceExpressions(weights: [Float](repeating: 0, count: FaceExpressions.weightCount))
        face.setEyeDirection(across: Float(tan(17.5 * Double.pi / 180)), up: -1)      // half-way right, far down
        XCTAssertEqual(face.weights[FaceExpression.eyesLookRightL.rawValue], 0.5, accuracy: 0.01)
        XCTAssertEqual(face.weights[FaceExpression.eyesLookLeftR.rawValue], 0)
        XCTAssertEqual(face.weights[FaceExpression.eyesLookDownR.rawValue], 1)
        XCTAssertEqual(face.weights[FaceExpression.eyesLookUpL.rawValue], 0)
    }

    func testSmallChangesAreFollowedSlowlyAndLargeOnesFast() {
        var smoother = FaceSmoother()
        XCTAssertEqual(smoother.smooth([0, 0], seconds: 0), [0, 0])
        // A thirtieth of a second later: a blink's worth of change, and a shimmer's.
        let next = smoother.smooth([1, 0.03], seconds: 1.0 / 30)
        XCTAssertGreaterThan(next[0], 0.6)
        XCTAssertLessThan(next[1], 0.03 * 0.25)
    }
}

final class FoveationTests: XCTestCase {
    func testRatesAreSharpAroundStraightAheadAndFallAwayToTheEdges() {
        let rates = Foveation.rates(zones: 59, center: 0.63, unseenAtStart: 2)
        XCTAssertEqual(rates.count, 59)
        // (The fall begins at full rate, as ALVR's does: one zone more.)
        XCTAssertEqual(rates.filter { $0 == 1 }.count, Foveation.sharpZones + 1)
        // The sharp block is around 0.63 of the way across.
        let firstSharp = rates.firstIndex(of: 1)!
        XCTAssertEqual(Float(firstSharp) + Float(Foveation.sharpZones) / 2, 0.63 * 59, accuracy: 1)
        // Rising up to it, falling after it, never nothing.
        XCTAssertEqual(rates[0], Foveation.lowest)
        XCTAssertEqual(rates[1], Foveation.lowest)
        // (The first few zones of the rise are all at the lowest rate there is.)
        for zone in 3..<firstSharp { XCTAssertGreaterThanOrEqual(rates[zone], rates[zone - 1]) }
        XCTAssertGreaterThan(rates[firstSharp - 1], rates[firstSharp - 8])
        for zone in (firstSharp + Foveation.sharpZones + 2)..<59 { XCTAssertLessThan(rates[zone], rates[zone - 1]) }
        XCTAssertTrue(rates.allSatisfy { $0 >= Foveation.lowest && $0 <= 1 })
    }

    func testEachEyeIsSharpTowardsTheNose() {
        // A Vision Pro's frusta: much wider outwards than towards the nose.
        let left = Foveation.rates(for: .left, frustum: Frustum(left: -1.74, right: 1.01, down: -1.20, up: 1.01))
        let right = Foveation.rates(for: .right, frustum: Frustum(left: -1.01, right: 1.74, down: -1.20, up: 1.01))
        XCTAssertGreaterThan(left.across.firstIndex(of: 1)!, 59 / 2 - Foveation.sharpZones / 2)
        XCTAssertLessThan(right.across.firstIndex(of: 1)!, 59 / 2 - Foveation.sharpZones / 2)
        XCTAssertEqual(left.down, right.down)
        // An axis off the edge of the picture still gives a whole sharp block.
        let off = Foveation.rates(zones: 20, center: 1.4)
        XCTAssertGreaterThanOrEqual(off.filter { $0 == 1 }.count, Foveation.sharpZones)
    }
}
