// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Estimates facial expressions and eye features from 2D facial landmarks
/// (eyes, pupils, brows, lips, and nose) detected in a camera feed.
///
/// Used on platforms that do not expose native face-tracking weights but provide
/// a virtual camera view of the user's face (such as Spatial Persona on visionOS).

/// The 70 facial expressions defined by OpenXR's `XR_FB_face_tracking2`, in specification order.
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

/// 2D facial landmarks matching Apple Vision's coordinate convention: points are normalized
/// to `0...1` within the face bounding box with the origin at the bottom-left corner, and
/// `left`/`right` refer to image-left and image-right.
public struct FaceLandmarks {
    /// Face bounding box dimensions normalized to the full image width and height.
    public var boxWidth: Float = 0, boxHeight: Float = 0
    public var leftEye: [LandmarkPoint] = [], rightEye: [LandmarkPoint] = []
    public var leftPupil: [LandmarkPoint] = [], rightPupil: [LandmarkPoint] = []
    public var leftBrow: [LandmarkPoint] = [], rightBrow: [LandmarkPoint] = []
    public var innerLips: [LandmarkPoint] = [], outerLips: [LandmarkPoint] = []
    public var noseCrest: [LandmarkPoint] = [], medianLine: [LandmarkPoint] = []
    public init() {}
}

/// Normalized pupil and eyelid features extracted from eye landmarks, used by
/// `GazeCalibration` to estimate gaze direction.
public struct EyeFeatures: Codable, Equatable {
    /// Horizontal pupil offset between the eye corners (`-0.5...0.5`) and vertical pupil
    /// offset below the eye contour centroid (in eye widths), for image-left and image-right eyes.
    public var leftAcross: Float, leftDown: Float, rightAcross: Float, rightDown: Float
    /// Additional vertical gaze cues. Because the eyelids track vertical eye motion, the eye
    /// contour centroid shifts with the pupil and `down` alone has limited range. `belowCorners`
    /// measures pupil offset below the fixed eye-corner line (in eye widths), and `open` measures
    /// eyelid openness (contour area divided by width squared), which decreases on downward gaze.
    public var leftBelowCorners: Float, rightBelowCorners: Float
    public var leftOpen: Float, rightOpen: Float

    public init(leftAcross: Float, leftDown: Float, rightAcross: Float, rightDown: Float,
                leftBelowCorners: Float = 0, rightBelowCorners: Float = 0, leftOpen: Float = 0, rightOpen: Float = 0) {
        self.leftAcross = leftAcross; self.leftDown = leftDown
        self.rightAcross = rightAcross; self.rightDown = rightDown
        self.leftBelowCorners = leftBelowCorners; self.rightBelowCorners = rightBelowCorners
        self.leftOpen = leftOpen; self.rightOpen = rightOpen
    }

    /// Bilateral averages across both eyes.
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
    /// True when both eyes are closed (excluding partially lowered lids during downward gaze),
    /// indicating pupil positions are unusable for gaze estimation.
    public var blinking: Bool
    /// Normalized facial measurements consumed by `FaceCalibration`.
    public var measures = FaceMeasures()
}

/// Heuristic estimator that converts per-frame `FaceLandmarks` into expression weights and
/// eye features. Learns neutral proportions over the initial frames and tracks min/max eye
/// bounds over time, so keep a single instance for the duration of a tracking session.
public struct FaceEstimator {
    // Neutral mouth widths sampled over the initial frames.
    private var restMouthWidth: Float = 0.35, restMouthWidthL: Float = 0.175, restMouthWidthR: Float = 0.175
    // Maximum observed width of each eye.
    private var widestEyeL: Float = 0.35, widestEyeR: Float = 0.35
    // Minimum observed eye openness and observed openness range for each eye.
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

    /// Eye contour area divided by width squared (`0` when closed).
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

    /// - Parameter eyeSpacing: The user's interpupillary distance in meters, used to scale image coordinates.
    public mutating func estimate(_ lm: FaceLandmarks, eyeSpacing: Float) -> FaceEstimate? {
        guard !lm.leftEye.isEmpty, !lm.rightEye.isEmpty, !lm.leftPupil.isEmpty, !lm.rightPupil.isEmpty,
              !lm.innerLips.isEmpty, lm.outerLips.count >= 8, lm.boxWidth > 0, lm.boxHeight > 0
        else { return nil }
        let average = FaceEstimator.average, unit = FaceEstimator.unit
        var weights = [Float](repeating: 0, count: FaceExpressions.weightCount)
        func set(_ expression: FaceExpression, _ value: Float) { weights[expression.rawValue] = unit(value) }

        // Remove head roll by rotating all landmarks around the nose until the eyes are level.
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
        // Convert from normalized bounding-box coordinates to image space (+Y downward),
        // scaled to match `eyeSpacing`.
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
        // Left and right halves of the outer lip contour (Vision orders outer-lip points around the perimeter).
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

        // Jaw drop.
        let jawDrop = unit(mouthHeight / faceH * 4)
        set(.jawDrop, jawDrop)

        // Mouth corners pulled down.
        let leftCorner = minX(outer), rightCorner = maxX(outer)
        var depressorL = unit(max(0, (leftCorner.y - mouthMiddle.y) / faceH) * 2 * 24 - 0.7)
        var depressorR = unit(max(0, (rightCorner.y - mouthMiddle.y) / faceH) * 2 * 24 - 0.7)
        if jawDrop > 0.5 { depressorL = 0; depressorR = 0 }
        set(.lipCornerDepressorL, depressorL)
        set(.lipCornerDepressorR, depressorR)

        // Smile weights from mouth widening relative to rest on each side.
        if mouthWidth > 0 {
            let smile = max(0, mouthWidth / faceW - restMouthWidth) / max(0.00001, restMouthWidth * 0.125)
            let smileL = unit(max(0, mouthWidthL / faceW - restMouthWidthL - 0.01) * 70)
            let smileR = unit(max(0, mouthWidthR / faceW - restMouthWidthR - 0.01) * 70)
            set(.lipCornerPullerL, smileL * smile - depressorL)
            set(.lipCornerPullerR, smileR * smile - depressorR)

            // Lip funneling from mouth height-to-width aspect ratio.
            let funnel = unit(mouthHeight / faceH / max(0.001, mouthWidth / faceW) - 0.3) * 0.5
            for expression in [FaceExpression.lipFunnelerLB, .lipFunnelerRB, .lipFunnelerLT, .lipFunnelerRT] { set(expression, funnel) }

            // Lip pucker when the mouth is narrower than at rest and not simply jaw-open.
            let pucker = unit((restMouthWidth - mouthWidth / faceW) * 3 + mouthHeight / faceH)
            set(.lipPuckerL, pucker * 3 - jawDrop)
            set(.lipPuckerR, pucker * 3 - jawDrop)
        }

        // Chin raiser from lips drawn toward the mouth center.
        let towardMiddle = max(0, (mouthMiddle.y - minY(inner)) / faceH) + max(0, (maxY(inner) - mouthMiddle.y) / faceH)
        set(.chinRaiserT, towardMiddle * 3)
        set(.chinRaiserB, towardMiddle * 3)

        // Eyelids: pupil drop relative to the eye corners increases on both downward gaze and lid closure.
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
        // Both Vision and Spatial Persona couple left and right lid closure; exaggerate asymmetry so winks register.
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

        // Eye gaze features from horizontal pupil position between corners and vertical offset from the contour center.
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

        // Brow movement relative to the upper eye contour.
        var browLift: (left: Float, right: Float) = (0, 0)
        if !lBrow.isEmpty, !rBrow.isEmpty {
            let liftL = (maxY(lBrow) - minY(lEye)) / faceH, liftR = (maxY(rBrow) - minY(rEye)) / faceH
            // For calibration, measure brow height relative to the fixed eye-corner line (+Y downward).
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

        // Update running baselines for subsequent frames.
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
                            // Treat as blinking when both eyes are near their minimum observed openness.
                            blinking: openL < 0.12 && openR < 0.12, measures: measures)
    }
}
