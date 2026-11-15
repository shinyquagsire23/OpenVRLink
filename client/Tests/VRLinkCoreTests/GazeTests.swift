// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class GazeCalibrationTests: XCTestCase {
    /// Synthetic ground-truth mapping from pupil features to gaze tangents.
    private func truth(_ f: EyeFeatures) -> (across: Float, up: Float) {
        let a = f.across, d = f.down
        return (0.05 + 2.5 * a + 0.1 * d + 0.8 * a * a, -0.1 - 3 * d + 0.5 * a * d)
    }

    private func features(_ across: Float, _ down: Float) -> EyeFeatures {
        // Offset the left and right eye features slightly; calibration fits against their average.
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
        // Evaluate on a sample point not included in the training grid.
        let unseen = features(0.15, -0.05), expected = truth(unseen), got = calibration.tangents(for: unseen)
        XCTAssertEqual(got.across, expected.across, accuracy: 0.01)
        XCTAssertEqual(got.up, expected.up, accuracy: 0.01)
    }

    func testAFewSamplesGiveAPlaneAndTooFewGiveNothing() throws {
        var calibrator = GazeCalibrator()
        let places: [(Float, Float)] = [(-0.2, 0), (0.2, 0), (0, -0.1), (0, 0.1), (0, 0), (0.1, 0.1)]
        for (index, place) in places.enumerated() {
            if index == 4 { XCTAssertNil(calibrator.fit()) }                 // four samples are not enough to fit
            let f = features(place.0, place.1), t = truth(f)
            calibrator.add(f, across: t.across, up: t.up)
        }
        let calibration = try XCTUnwrap(calibrator.fit())
        XCTAssertTrue(calibration.acrossTerms[3...].allSatisfy { $0 == 0 })
        XCTAssertTrue(calibration.usable)
        XCTAssertEqual(calibration.acrossTerms[1], 2.5, accuracy: 0.3)       // linear across slope from `truth`
        XCTAssertEqual(calibration.upTerms[2], -3, accuracy: 0.3)
    }

    func testSamplesAllInOnePlaceGiveNothing() {
        var calibrator = GazeCalibrator()
        for _ in 0..<12 { calibrator.add(features(0.1, 0.05), across: 0.3, up: -0.2) }
        XCTAssertNil(calibrator.fit())
    }

    func testARayBecomesTangentsInTheHeadsFrame() throws {
        // When the head faces +x, its local right axis points along +z.
        let head = Pose(position: Vec3(0, 1.6, 0), right: Vec3(0, 0, 1), up: Vec3(0, 1, 0), forward: Vec3(1, 0, 0))
        let tangents = try XCTUnwrap(GazeCalibrator.tangents(ofRay: Vec3(2, 0.5, 1), head: head))
        XCTAssertEqual(tangents.across, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tangents.up, 0.25, accuracy: 1e-6)
        XCTAssertNil(GazeCalibrator.tangents(ofRay: Vec3(-1, 0, 0), head: head))
    }

    /// Fits a baseline calibration across a 15-point sample grid.
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
        // Simulate headset slip shifting true gaze tangents 0.1 units to the right.
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
        // Corner samples from the initial calibration are retained and still fit accurately.
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
    /// Builds synthetic face landmarks in a square bounding box. `pupil` offsets both pupils
    /// in normalized box coordinates (+x right, +y up), and `mouthOpen` separates the lips.
    private func face(pupil: (Float, Float) = (0, 0), mouthOpen: Float = 0.005, tilt: Float = 0) -> FaceLandmarks {
        func eye(_ cx: Float, _ cy: Float) -> [LandmarkPoint] {
            [(-0.06, 0), (-0.03, 0.02), (0, 0.025), (0.03, 0.02), (0.06, 0), (0.03, -0.02), (0, -0.025), (-0.03, -0.02)]
                .map { LandmarkPoint(cx + Float($0.0), cy + Float($0.1)) }
        }
        func lips(_ halfWidth: Float, _ halfHeight: Float) -> [LandmarkPoint] {
            // Place 10 points around an ellipse starting from the right corner of the mouth.
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
            // Rotate all landmarks around the center of the bounding box.
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
        // At the neutral pose, calibrated expression weights are zero regardless of fallback values, except eye-look weights.
        var weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 0)
        XCTAssertEqual(weight(weights, .lipCornerPullerL), 0)
        XCTAssertEqual(weight(weights, .eyesLookUpL), 0.5)

        face.mouthOpen = 0.11                       // halfway to the open pose
        face.mouthWidthL = 0.26                     // left side at full smile width
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 0.5, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipCornerPullerL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipCornerPullerR), 0, accuracy: 0.01)
    }

    func testTheTwoSidesArePushedApart() throws {
        let fit = calibration()
        let fallback = [Float](repeating: 0, count: FaceExpressions.weightCount)
        var face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        // Simulate a camera wink where one eye is mostly closed and the other partially squints with it.
        face.eyeOpenL = 0.20 - 0.18 * 0.7
        face.eyeOpenR = 0.20 - 0.18 * 0.35
        // Raise the left brow while the right brow moves up slightly.
        face.browLiftL = 0.06 + 0.04 * 0.6
        face.browLiftR = 0.06 + 0.04 * 0.2
        var weights = fit.weights(for: face, fallback: fallback)
        XCTAssertGreaterThan(weight(weights, .eyesClosedL), 0.95)
        XCTAssertLessThan(weight(weights, .eyesClosedR), 0.05)
        XCTAssertLessThan(weight(weights, .innerBrowRaiserR), 0.05)
        // Closing the left eye suppresses the left brow-raise weight and drives brow lowerer instead.
        XCTAssertLessThan(weight(weights, .innerBrowRaiserL), 0.1)
        XCTAssertEqual(weight(weights, .browLowererL), 0.7, accuracy: 0.05)

        // Closing both eyes keeps both eye-closed weights at 1.
        face.eyeOpenL = 0.02; face.eyeOpenR = 0.02
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .eyesClosedL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .eyesClosedR), 1, accuracy: 0.01)

        // Test raising one brow while both eyes remain open.
        face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        face.browLiftL = 0.06 + 0.04 * 0.6
        face.browLiftR = 0.06 + 0.04 * 0.2
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertGreaterThan(weight(weights, .innerBrowRaiserL), 0.95)
        XCTAssertLessThan(weight(weights, .innerBrowRaiserR), 0.05)

        // A partial frown is boosted to full weight.
        face = try XCTUnwrap(fit.poses[FacePose.neutral.rawValue])
        face.cornerDropL = 0.012; face.cornerDropR = 0.012               // 40% of calibrated frown
        weights = fit.weights(for: face, fallback: fallback)
        XCTAssertEqual(weight(weights, .lipCornerDepressorL), 1, accuracy: 0.01)
    }

    /// Tests cross-expression disambiguation when a frown widens the mouth and
    /// opening the jaw narrows the mouth almost as much as a pucker.
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

        // The calibrated jaw-open pose alone should not trigger lip pucker.
        weights = fit.weights(for: try XCTUnwrap(fit.poses[FacePose.jawOpen.rawValue]), fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipPuckerL), 0, accuracy: 0.01)

        // Opening the jaw while narrowing the mouth to the pucker width produces both pucker and funnel.
        var gasp = try XCTUnwrap(fit.poses[FacePose.jawOpen.rawValue])
        gasp.mouthWidth = 0.28
        weights = fit.weights(for: gasp, fallback: fallback)
        XCTAssertEqual(weight(weights, .jawDrop), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipPuckerL), 1, accuracy: 0.01)
        XCTAssertEqual(weight(weights, .lipFunnelerLT), 1, accuracy: 0.01)

        // The calibrated pucker pose produces pucker without lip funnel.
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
        face.setEyeDirection(across: Float(tan(17.5 * Double.pi / 180)), up: -1)      // halfway right, full down
        XCTAssertEqual(face.weights[FaceExpression.eyesLookRightL.rawValue], 0.5, accuracy: 0.01)
        XCTAssertEqual(face.weights[FaceExpression.eyesLookLeftR.rawValue], 0)
        XCTAssertEqual(face.weights[FaceExpression.eyesLookDownR.rawValue], 1)
        XCTAssertEqual(face.weights[FaceExpression.eyesLookUpL.rawValue], 0)
    }

    func testSmallChangesAreFollowedSlowlyAndLargeOnesFast() {
        var smoother = FaceSmoother()
        XCTAssertEqual(smoother.smooth([0, 0], seconds: 0), [0, 0])
        // Advance one 30 Hz frame with one large jump (a blink) and one tiny change (landmark jitter).
        let next = smoother.smooth([1, 0.03], seconds: 1.0 / 30)
        XCTAssertGreaterThan(next[0], 0.6)
        XCTAssertLessThan(next[1], 0.03 * 0.25)
    }
}

final class FoveationTests: XCTestCase {
    func testRatesAreSharpAroundStraightAheadAndFallAwayToTheEdges() {
        let rates = Foveation.rates(zones: 59, center: 0.63, unseenAtStart: 2)
        XCTAssertEqual(rates.count, 59)
        // Matching ALVR, the falloff region starts with one zone at full rate.
        XCTAssertEqual(rates.filter { $0 == 1 }.count, Foveation.sharpZones + 1)
        // The full-rate region is centered around 63% across the axis.
        let firstSharp = rates.firstIndex(of: 1)!
        XCTAssertEqual(Float(firstSharp) + Float(Foveation.sharpZones) / 2, 0.63 * 59, accuracy: 1)
        // Rates ramp up to the center, fall off after it, and stay at or above the minimum rate.
        XCTAssertEqual(rates[0], Foveation.lowest)
        XCTAssertEqual(rates[1], Foveation.lowest)
        // The unseen leading zones and the start of the ramp clamp to the minimum rate.
        for zone in 3..<firstSharp { XCTAssertGreaterThanOrEqual(rates[zone], rates[zone - 1]) }
        XCTAssertGreaterThan(rates[firstSharp - 1], rates[firstSharp - 8])
        for zone in (firstSharp + Foveation.sharpZones + 2)..<59 { XCTAssertLessThan(rates[zone], rates[zone - 1]) }
        XCTAssertTrue(rates.allSatisfy { $0 >= Foveation.lowest && $0 <= 1 })
    }

    func testEachEyeIsSharpTowardsTheNose() {
        // Vision Pro frusta extend much further outward temporally than nasally.
        let left = Foveation.rates(for: .left, frustum: Frustum(left: -1.74, right: 1.01, down: -1.20, up: 1.01))
        let right = Foveation.rates(for: .right, frustum: Frustum(left: -1.01, right: 1.74, down: -1.20, up: 1.01))
        XCTAssertGreaterThan(left.across.firstIndex(of: 1)!, 59 / 2 - Foveation.sharpZones / 2)
        XCTAssertLessThan(right.across.firstIndex(of: 1)!, 59 / 2 - Foveation.sharpZones / 2)
        XCTAssertEqual(left.down, right.down)
        // Clamping an off-center gaze point still preserves a full-width sharp region.
        let off = Foveation.rates(zones: 20, center: 1.4)
        XCTAssertGreaterThanOrEqual(off.filter { $0 == 1 }.count, Foveation.sharpZones)
    }
}
