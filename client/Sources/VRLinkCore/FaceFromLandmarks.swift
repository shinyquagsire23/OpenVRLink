// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Face expressions and eye features worked out from the outline of a face
/// in a camera picture: the points a face-landmark detector gives for the
/// eyes, pupils, brows, lips and nose.
///
/// This is for platforms with no face tracking of their own but provide a
/// "camera" of the wearer's face (on visionOS, Spatial Persona)

/// The 70 expressions of OpenXR's `XR_FB_face_tracking2`, in its order.
public enum FaceExpression: Int, CaseIterable {
    case browLowererL, browLowererR, cheekPuffL, cheekPuffR, cheekRaiserL, cheekRaiserR, cheekSuckL, cheekSuckR
    case chinRaiserB, chinRaiserT, dimplerL, dimplerR, eyesClosedL, eyesClosedR
    case eyesLookDownL, eyesLookDownR, eyesLookLeftL, eyesLookLeftR, eyesLookRightL, eyesLookRightR, eyesLookUpL, eyesLookUpR
    case innerBrowRaiserL, innerBrowRaiserR, jawDrop, jawSidewaysLeft, jawSidewaysRight, jawThrust
    case lidTightenerL, lidTightenerR, lipCornerDepressorL, lipCornerDepressorR, lipCornerPullerL, lipCornerPullerR
    case lipFunnelerLB, lipFunnelerLT, lipFunnelerRB, lipFunnelerRT, lipPressorL, lipPressorR, lipPuckerL, lipPuckerR
    case lipStretcherL, lipStretcherR, lipSuckLB, lipSuckLT, lipSuckRB, lipSuckRT, lipTightenerL, lipTightenerR
    case lipsToward, lowerLipDepressorL, lowerLipDepressorR, mouthLeft, mouthRight, noseWrinklerL, noseWrinklerR
    case outerBrowRaiserL, outerBrowRaiserR, upperLidRaiserL, upperLidRaiserR, upperLipRaiserL, upperLipRaiserR
    case tongueTipInterdental, tongueTipAlveolar, tongueFrontDorsalPalate, tongueMidDorsalPalate
    case tongueBackDorsalVelar, tongueOut, tongueRetreat
}

public struct LandmarkPoint {
    public var x, y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
}

/// One face's landmarks, as Apple's Vision framework gives them: every
/// point inside the face's bounding box, 0 ... 1 across and 0 ... 1 up from
/// its bottom-left corner. "Left" is the left of the picture.
public struct FaceLandmarks {
    /// The bounding box's size as a fraction of the picture's width and height.
    public var boxWidth: Float = 0, boxHeight: Float = 0
    public var leftEye: [LandmarkPoint] = [], rightEye: [LandmarkPoint] = []
    public var leftPupil: [LandmarkPoint] = [], rightPupil: [LandmarkPoint] = []
    public var leftBrow: [LandmarkPoint] = [], rightBrow: [LandmarkPoint] = []
    public var innerLips: [LandmarkPoint] = [], outerLips: [LandmarkPoint] = []
    public var noseCrest: [LandmarkPoint] = [], medianLine: [LandmarkPoint] = []
    public init() {}
}

/// Where each pupil sits within its eye's outline: what a gaze calibration
/// turns into a direction (`GazeCalibration`).
public struct EyeFeatures: Codable, Equatable {
    /// For the picture's left and right eye: `across` is the pupil's place
    /// between the eye's corners, -0.5 ... 0.5; `down` is how far the pupil
    /// is below the middle of the outline, in eye widths.
    public var leftAcross: Float, leftDown: Float, rightAcross: Float, rightDown: Float
    /// Two more signs of looking up or down. The eyelids follow the eye,
    /// so the outline moves with the pupil and `down` alone says little:
    /// `belowCorners` is how far the pupil is below the line through the
    /// eye's two corners, which stay put (in eye widths), and `open` is how
    /// open the lids are (the outline's area over its width squared), which
    /// falls as the eye looks down.
    public var leftBelowCorners: Float, rightBelowCorners: Float
    public var leftOpen: Float, rightOpen: Float

    public init(leftAcross: Float, leftDown: Float, rightAcross: Float, rightDown: Float,
                leftBelowCorners: Float = 0, rightBelowCorners: Float = 0, leftOpen: Float = 0, rightOpen: Float = 0) {
        self.leftAcross = leftAcross; self.leftDown = leftDown
        self.rightAcross = rightAcross; self.rightDown = rightDown
        self.leftBelowCorners = leftBelowCorners; self.rightBelowCorners = rightBelowCorners
        self.leftOpen = leftOpen; self.rightOpen = rightOpen
    }

    /// The two eyes averaged: they look at the same thing.
    public var across: Float { (leftAcross + rightAcross) / 2 }
    public var down: Float { (leftDown + rightDown) / 2 }
    public var belowCorners: Float { (leftBelowCorners + rightBelowCorners) / 2 }
    public var open: Float { (leftOpen + rightOpen) / 2 }

    public static func average(_ all: [EyeFeatures]) -> EyeFeatures? {
        guard !all.isEmpty else { return nil }
        func mean(_ value: KeyPath<EyeFeatures, Float>) -> Float { all.reduce(0) { $0 + $1[keyPath: value] } / Float(all.count) }
        return EyeFeatures(leftAcross: mean(\.leftAcross), leftDown: mean(\.leftDown),
                           rightAcross: mean(\.rightAcross), rightDown: mean(\.rightDown),
                           leftBelowCorners: mean(\.leftBelowCorners), rightBelowCorners: mean(\.rightBelowCorners),
                           leftOpen: mean(\.leftOpen), rightOpen: mean(\.rightOpen))
    }
}

public struct FaceEstimate {
    public var face: FaceExpressions
    public var eyes: EyeFeatures
    /// Both eyes shut: there are then no pupils to go by. (Lids half
    /// lowered, as when looking down, do not count.)
    public var blinking: Bool
    /// The measurements a `FaceCalibration` works from.
    public var measures = FaceMeasures()
}

/// Turns landmarks into expressions, one picture at a time. It learns the
/// face's resting proportions from the first pictures and its extremes as
/// it goes, so make one and keep it for as long as the same face is seen.
public struct FaceEstimator {
    // The neutral face, sampled over the first pictures.
    private var restMouthWidth: Float = 0.35, restMouthWidthL: Float = 0.175, restMouthWidthR: Float = 0.175
    // The widest and tallest each eye has been seen.
    private var widestEyeL: Float = 0.35, widestEyeR: Float = 0.35
    // How open each eye's outline is at its most shut and its most open.
    private var mostShutL: Float = 1, mostShutR: Float = 1
    private var openRangeL: Float = -100000, openRangeR: Float = -100000
    private var picturesSeen = 0
    private static let picturesToLearnTheRestingFace = 15

    public init() {}

    private typealias P = LandmarkPoint

    private static func average(_ points: [P]) -> P {
        guard !points.isEmpty else { return P(0, 0) }
        return P(points.reduce(0) { $0 + $1.x } / Float(points.count), points.reduce(0) { $0 + $1.y } / Float(points.count))
    }
    private static func unit(_ value: Float) -> Float { max(0, min(1, value)) }

    /// The area of an eye's outline over the square of its width: 0 for a shut eye.
    private static func openness(_ outline: [P]) -> Float {
        guard outline.count > 2 else { return 1 }
        var area: Float = 0
        for i in outline.indices {
            let j = (i + 1) % outline.count
            area += outline[i].x * outline[j].y - outline[j].x * outline[i].y
        }
        let width = outline.map(\.x).max()! - outline.map(\.x).min()!
        return unit(abs(area) * 0.5 / max(width * width, 1e-6))
    }

    /// - eyeSpacing: the wearer's real distance between pupils, in meters;
    ///   it gives the picture a scale.
    public mutating func estimate(_ lm: FaceLandmarks, eyeSpacing: Float) -> FaceEstimate? {
        guard !lm.leftEye.isEmpty, !lm.rightEye.isEmpty, !lm.leftPupil.isEmpty, !lm.rightPupil.isEmpty,
              !lm.innerLips.isEmpty, lm.outerLips.count >= 8, lm.boxWidth > 0, lm.boxHeight > 0
        else { return nil }
        let average = FaceEstimator.average, unit = FaceEstimator.unit
        var weights = [Float](repeating: 0, count: FaceExpressions.weightCount)
        func set(_ expression: FaceExpression, _ value: Float) { weights[expression.rawValue] = unit(value) }

        // A tilted head: turn every point back about the nose until the eyes are level.
        let eyeToEye = P(average(lm.rightEye).x - average(lm.leftEye).x, average(lm.rightEye).y - average(lm.leftEye).y)
        let roll = Float(atan2(Double(eyeToEye.y), Double(eyeToEye.x)))
        let pivot = lm.noseCrest.isEmpty ? average(lm.medianLine.isEmpty ? lm.leftEye + lm.rightEye : lm.medianLine)
                                         : average(lm.noseCrest)
        let sine = Float(sin(Double(roll))), cosine = Float(cos(Double(roll)))
        func levelled(_ points: [P]) -> [P] {
            points.map { p in
                let x = p.x - pivot.x, y = p.y - pivot.y
                return P(cosine * x + sine * y + pivot.x, -sine * x + cosine * y + pivot.y)
            }
        }
        // From the bounding box to the picture, y now running downwards, and
        // scaled so that the eyes are their real distance apart.
        func inPicture(_ points: [P], scale: Float) -> [P] {
            points.map { P($0.x * lm.boxWidth * scale, (1 - $0.y * lm.boxHeight) * scale) }
        }
        func distance(_ a: P, _ b: P) -> Float { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        let levelLeftEye = levelled(lm.leftEye), levelRightEye = levelled(lm.rightEye)
        let scale = eyeSpacing / max(1e-6, distance(average(inPicture(levelLeftEye, scale: 1)), average(inPicture(levelRightEye, scale: 1))))
        let faceW = max(0.00001, lm.boxWidth * scale), faceH = max(0.00001, lm.boxHeight * scale)

        let inner = inPicture(levelled(lm.innerLips), scale: scale), outer = inPicture(levelled(lm.outerLips), scale: scale)
        let lEye = inPicture(levelLeftEye, scale: scale), rEye = inPicture(levelRightEye, scale: scale)
        let lPupil = inPicture(levelled(lm.leftPupil), scale: scale), rPupil = inPicture(levelled(lm.rightPupil), scale: scale)
        let lBrow = inPicture(levelled(lm.leftBrow), scale: scale), rBrow = inPicture(levelled(lm.rightBrow), scale: scale)
        // The two halves of the outer lip line (the detector's points run round the mouth in a fixed order).
        let outerL = inPicture(Array(lm.outerLips.dropFirst(3).dropLast(3)), scale: scale)
        let outerR = inPicture(Array(lm.outerLips.prefix(4) + lm.outerLips.suffix(4)), scale: scale)

        func minX(_ p: [P]) -> P { p.min { $0.x < $1.x }! }
        func maxX(_ p: [P]) -> P { p.max { $0.x < $1.x }! }
        func minY(_ p: [P]) -> Float { p.map(\.y).min()! }
        func maxY(_ p: [P]) -> Float { p.map(\.y).max()! }
        func width(_ p: [P]) -> Float { p.isEmpty ? 0 : maxX(p).x - minX(p).x }

        let eyeWidthL = width(lEye), eyeWidthR = width(rEye)
        let mouthWidth = width(outer), mouthHeight = maxY(inner) - minY(inner)
        let mouthWidthL = width(outerL), mouthWidthR = width(outerR)
        let mouthMiddle = average(outer)

        // Jaw.
        let jawDrop = unit(mouthHeight / faceH * 4)
        set(.jawDrop, jawDrop)

        // Mouth corners pulled down.
        let leftCorner = minX(outer), rightCorner = maxX(outer)
        var depressorL = unit(max(0, (leftCorner.y - mouthMiddle.y) / faceH) * 2 * 24 - 0.7)
        var depressorR = unit(max(0, (rightCorner.y - mouthMiddle.y) / faceH) * 2 * 24 - 0.7)
        if jawDrop > 0.5 { depressorL = 0; depressorR = 0 }
        set(.lipCornerDepressorL, depressorL)
        set(.lipCornerDepressorR, depressorR)

        // Smiling: the mouth wider than at rest, each side by its own half.
        if mouthWidth > 0 {
            let smile = max(0, mouthWidth / faceW - restMouthWidth) / max(0.00001, restMouthWidth * 0.125)
            let smileL = unit(max(0, mouthWidthL / faceW - restMouthWidthL - 0.01) * 70)
            let smileR = unit(max(0, mouthWidthR / faceW - restMouthWidthR - 0.01) * 70)
            set(.lipCornerPullerL, smileL * smile - depressorL)
            set(.lipCornerPullerR, smileR * smile - depressorR)

            // Funnel: tall for its width.
            let funnel = unit(mouthHeight / faceH / max(0.001, mouthWidth / faceW) - 0.3) * 0.5
            for expression in [FaceExpression.lipFunnelerLB, .lipFunnelerRB, .lipFunnelerLT, .lipFunnelerRT] { set(expression, funnel) }

            // Pucker: narrower than at rest, and not simply open.
            let pucker = unit((restMouthWidth - mouthWidth / faceW) * 3 + mouthHeight / faceH)
            set(.lipPuckerL, pucker * 3 - jawDrop)
            set(.lipPuckerR, pucker * 3 - jawDrop)
        }

        // Lips drawn towards the middle of the mouth.
        let towardMiddle = max(0, (mouthMiddle.y - minY(inner)) / faceH) + max(0, (maxY(inner) - mouthMiddle.y) / faceH)
        set(.chinRaiserT, towardMiddle * 3)
        set(.chinRaiserB, towardMiddle * 3)

        // Eyelids. How low the pupil sits against the eye's corners rises
        // both when looking down and when the lid comes down.
        func lidDown(_ eye: [P], _ pupil: [P]) -> Float {
            let pupilY = average(pupil).y / faceH
            let cornersY = (minX(eye).y + maxX(eye).y) / 2 / faceH
            let eyeWidth = width(eye) / faceW
            return unit(((pupilY - cornersY) / max(0.001, eyeWidth * 0.5) + 0.125 + 0.06) * 4 * 2)
        }
        let rawOpenL = FaceEstimator.openness(lm.leftEye), rawOpenR = FaceEstimator.openness(lm.rightEye)
        let openL = unit((rawOpenL - mostShutL) / openRangeL), openR = unit((rawOpenR - mostShutR) / openRangeR)
        mostShutL = min(mostShutL, rawOpenL)
        mostShutR = min(mostShutR, rawOpenR)
        if rawOpenL - mostShutL > openRangeL { openRangeL = max(rawOpenL - mostShutL, 0.00001) }
        if rawOpenR - mostShutR > openRangeR { openRangeR = max(rawOpenR - mostShutR, 0.00001) }
        let lidDownL = lidDown(lEye, lPupil), lidDownR = lidDown(rEye, rPupil)
        // The detector and the Persona both tend to shut the eyes together;
        // push the two apart so that a wink survives.
        let shutL = 1 - openL, shutR = 1 - openR
        var closedL = shutL, closedR = shutR
        for _ in 0..<3 {
            let difference = max(abs(shutR - shutL), 0.00001)
            if shutR > shutL {
                closedL *= closedL - difference
                closedR *= closedR + difference
            } else if shutL > shutR {
                closedL *= closedL + difference
                closedR *= closedR - difference
            } else {
                closedL *= closedL
                closedR *= closedR
            }
        }
        closedL = unit(closedL * 3)
        closedR = unit(closedR * 3)
        set(.eyesClosedL, closedL)
        set(.eyesClosedR, closedR)
        let tightenL = lidDownL * 0.2 + closedL * 0.2, tightenR = lidDownR * 0.2 + closedR * 0.2
        set(.lidTightenerL, tightenL)
        set(.lidTightenerR, tightenR)
        set(.cheekRaiserL, unit(tightenL) * 0.7)
        set(.cheekRaiserR, unit(tightenR) * 0.7)

        // Where the eyes look: the pupil's place between the eye's corners,
        // and its height against the middle of the outline.
        func look(_ eye: [P], _ pupil: [P], widest: Float) -> (across: Float, down: Float, belowCorners: Float) {
            let pupilAt = average(pupil)
            let across = (pupilAt.x - minX(eye).x) / max(0.001, width(eye)) - 0.5
            let down = (pupilAt.y - (average(eye).y + 0.0005)) / max(0.001, widest)
            let cornersY = (minX(eye).y + maxX(eye).y) / 2
            return (across, down, (pupilAt.y - cornersY) / max(0.001, widest))
        }
        let lookL = look(lEye, lPupil, widest: widestEyeL), lookR = look(rEye, rPupil, widest: widestEyeR)
        func lookWeights(_ look: (across: Float, down: Float, belowCorners: Float)) -> (up: Float, down: Float, left: Float, right: Float) {
            let vertical = (look.down * 2 + 1.0 / 3.0) * 6
            return (unit(-vertical), unit(vertical), unit(-look.across * 2), unit(look.across * 2))
        }
        let weightsL = lookWeights(lookL), weightsR = lookWeights(lookR)
        set(.eyesLookUpL, weightsL.up); set(.eyesLookDownL, weightsL.down)
        set(.eyesLookLeftL, weightsL.right); set(.eyesLookRightL, weightsL.left)     // the picture is a mirror image
        set(.eyesLookUpR, weightsR.up); set(.eyesLookDownR, weightsR.down)
        set(.eyesLookLeftR, weightsR.right); set(.eyesLookRightR, weightsR.left)

        // Brows, against the top of the eye.
        var browLift: (left: Float, right: Float) = (0, 0)
        if !lBrow.isEmpty, !rBrow.isEmpty {
            let liftL = (maxY(lBrow) - minY(lEye)) / faceH, liftR = (maxY(rBrow) - minY(rEye)) / faceH
            // For a calibration: the brow's middle above the line through the
            // eye's corners, which do not move when the eye shuts (y runs downwards).
            browLift = (((minX(lEye).y + maxX(lEye).y) / 2 - average(lBrow).y) / faceH,
                        ((minX(rEye).y + maxX(rEye).y) / 2 - average(rBrow).y) / faceH)
            set(.innerBrowRaiserL, liftL * 8)
            set(.innerBrowRaiserR, liftR * 8)
            set(.browLowererL, (1 - unit((0.08 - liftL) * 8)) * 5 + 0.6 * lidDownL)
            set(.browLowererR, (1 - unit((0.08 - liftR) * 8)) * 5 + 0.6 * lidDownR)
            let outerUpL = (maxX(lBrow).y - minX(lBrow).y) / faceH, outerUpR = (minX(rBrow).y - maxX(rBrow).y) / faceH
            set(.outerBrowRaiserL, outerUpL * 4 - 0.5 * closedL)
            set(.outerBrowRaiserR, outerUpR * 4 - 0.5 * closedR)
        }

        // What is carried to the next picture.
        widestEyeL = max(widestEyeL, eyeWidthL)
        widestEyeR = max(widestEyeR, eyeWidthR)
        if picturesSeen <= FaceEstimator.picturesToLearnTheRestingFace {
            restMouthWidth = mouthWidth / faceW
            restMouthWidthL = mouthWidthL / faceW
            restMouthWidthR = mouthWidthR / faceW
            widestEyeL = eyeWidthL
            widestEyeR = eyeWidthR
            picturesSeen += 1
        }

        var measures = FaceMeasures()
        measures.mouthOpen = mouthHeight / faceH
        measures.mouthWidth = mouthWidth / faceW
        measures.mouthWidthL = mouthWidthL / faceW
        measures.mouthWidthR = mouthWidthR / faceW
        measures.cornerDropL = (leftCorner.y - mouthMiddle.y) / faceH
        measures.cornerDropR = (rightCorner.y - mouthMiddle.y) / faceH
        measures.browLiftL = browLift.left
        measures.browLiftR = browLift.right
        measures.eyeOpenL = rawOpenL
        measures.eyeOpenR = rawOpenR

        return FaceEstimate(face: FaceExpressions(weights: weights),
                            eyes: EyeFeatures(leftAcross: lookL.across, leftDown: lookL.down,
                                              rightAcross: lookR.across, rightDown: lookR.down,
                                              leftBelowCorners: lookL.belowCorners, rightBelowCorners: lookR.belowCorners,
                                              leftOpen: rawOpenL, rightOpen: rawOpenR),
                            // Shut means nearly as shut as these eyes have ever been seen.
                            blinking: openL < 0.12 && openR < 0.12, measures: measures)
    }
}
