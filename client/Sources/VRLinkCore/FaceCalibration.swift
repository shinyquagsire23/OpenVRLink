// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Per-user calibration for landmark-based face tracking.
///
/// `FaceEstimator` converts facial landmark measurements into expression weights using fixed
/// heuristics that vary in accuracy across different faces. Calibration records a user's actual
/// measurements across a short sequence of target expressions, then maps live measurements
/// linearly from the neutral baseline toward each recorded peak pose.

/// Normalized facial measurements extracted from a single camera frame. Distances are
/// divided by face width or height for scale invariance. `L` and `R` correspond to the left
/// and right sides of the mirrored image (matching the user's anatomical left and right, as
/// in `FaceExpression`).
public struct FaceMeasures: Codable, Equatable {
    /// Vertical inner-lip opening divided by face height.
    public var mouthOpen: Float = 0
    /// Full, left-half, and right-half outer mouth widths divided by face width.
    public var mouthWidth: Float = 0, mouthWidthL: Float = 0, mouthWidthR: Float = 0
    /// Vertical drop of each mouth corner below the mouth center, divided by face height.
    public var cornerDropL: Float = 0, cornerDropR: Float = 0
    /// Height of each eyebrow above the line connecting its eye's inner and outer corners,
    /// divided by face height. Measured relative to the eye corners rather than the upper
    /// eyelid so closing the eyes does not register as raising the brows.
    public var browLiftL: Float = 0, browLiftR: Float = 0
    /// Eyelid openness ratio (eye contour area divided by eye width squared).
    public var eyeOpenL: Float = 0, eyeOpenR: Float = 0

    public init() {}

    static let all: [WritableKeyPath<FaceMeasures, Float>] = [
        \.mouthOpen, \.mouthWidth, \.mouthWidthL, \.mouthWidthR, \.cornerDropL, \.cornerDropR,
        \.browLiftL, \.browLiftR, \.eyeOpenL, \.eyeOpenR,
    ]

    public static func average(_ samples: [FaceMeasures]) -> FaceMeasures? {
        guard !samples.isEmpty else { return nil }
        var out = FaceMeasures()
        for measure in all { out[keyPath: measure] = samples.reduce(0) { $0 + $1[keyPath: measure] } / Float(samples.count) }
        return out
    }
}

/// Target expressions requested during face calibration, in presentation order.
public enum FacePose: String, CaseIterable, Codable {
    // Keep eyesClosed last because the user cannot read on-screen prompts with closed eyes.
    case neutral, jawOpen, smile, frown, pucker, browsUp, browsDown, eyesWide, eyesClosed

    /// User-facing instruction for this calibration step.
    public var prompt: String {
        // TODO: i8n
        switch self {
        case .neutral: return "Relax your face with your mouth closed"
        case .jawOpen: return "Open your mouth wide, in an O"
        case .smile: return "Smile as widely as you can with your mouth closed"
        case .frown: return "Frown, pulling the corners of your mouth down"
        case .pucker: return "Pucker your lips, as for a kiss"
        case .browsUp: return "Raise your eyebrows"
        case .browsDown: return "Lower your eyebrows, like you're angry"
        case .eyesWide: return "Open your eyes wide"
        case .eyesClosed: return "Last one: close your eyes and count to three"
        }
    }
}

public struct FaceCalibration: Codable, Equatable {
    /// Recorded facial measurements keyed by `FacePose.rawValue`.
    public var poses: [String: FaceMeasures]
    /// Schema version of the measurement definitions used when recording.
    public var version: Int

    /// Incremented when `FaceMeasures` definitions change, invalidating older saved calibrations.
    public static let currentVersion = 2

    public init(poses: [FacePose: FaceMeasures]) {
        self.poses = Dictionary(uniqueKeysWithValues: poses.map { ($0.key.rawValue, $0.value) })
        version = FaceCalibration.currentVersion
    }

    /// Whether this calibration matches `currentVersion` and contains every required `FacePose`.
    public var usable: Bool {
        version == FaceCalibration.currentVersion && FacePose.allCases.allSatisfy { poses[$0.rawValue] != nil }
    }

    /// Amplifies left/right asymmetry around the bilateral average by `gain`.
    /// Both Spatial Persona rendering and Vision's landmark detector couple the two sides
    /// of the face (for example, winking one eye appears as both eyes half-closed), so
    /// exaggerating the difference restores single-side expressions.
    static func apart(_ left: Float, _ right: Float, gain: Float) -> (left: Float, right: Float) {
        let middle = (left + right) / 2, half = (left - right) / 2 * gain
        return (max(0, min(1, middle + half)), max(0, min(1, middle - half)))
    }
    static let eyeSideGain: Float = 3, browSideGain: Float = 3, mouthSideGain: Float = 2
    /// Gain applied to frown measurements, which produce only subtle mouth-corner movement in Persona frames.
    static let frownGain: Float = 2.5
    /// Amount of brow lowering synthesized when an eye closes, compensating for Persona's static brows during blinks.
    static let browFollowsLid: Float = 0.7
    /// Deadzone for resting eye and brow weights; values below `restBand` clamp to 0 and the remainder rescales to `0...1`.
    static let restBand: Float = 0.12
    static func pastRest(_ weight: Float) -> Float { max(0, (weight - restBand) / (1 - restBand)) }

    /// Computes calibrated expression weights from `now`. Copies eye-look weights from
    /// `fallback` (`FaceEstimator`) because face calibration does not measure gaze direction.
    public func weights(for now: FaceMeasures, fallback: [Float]) -> [Float] {
        guard usable, let rest = poses[FacePose.neutral.rawValue] else { return fallback }
        var weights = [Float](repeating: 0, count: FaceExpressions.weightCount)
        for look in [FaceExpression.eyesLookDownL, .eyesLookDownR, .eyesLookLeftL, .eyesLookLeftR,
                     .eyesLookRightL, .eyesLookRightR, .eyesLookUpL, .eyesLookUpR] {
            weights[look.rawValue] = fallback[look.rawValue]
        }
        /// Linearly maps `measure` from neutral (`0`) to `pose` (`1`), returning `0` if the
        /// calibrated range is too small to be reliable.
        func reach(_ measure: KeyPath<FaceMeasures, Float>, _ pose: FacePose) -> Float {
            guard let full = poses[pose.rawValue] else { return 0 }
            let from = rest[keyPath: measure], to = full[keyPath: measure]
            guard abs(to - from) > 0.002 else { return 0 }
            return max(0, min(1, (now[keyPath: measure] - from) / (to - from)))
        }
        func set(_ expression: FaceExpression, _ value: Float) { weights[expression.rawValue] = max(0, min(1, value)) }

        let jaw = reach(\.mouthOpen, .jawOpen)
        set(.jawDrop, jaw)

        // Compute frown weights first (scaled by `frownGain`) because frowning also widens
        // the mouth, which would otherwise register as a smile.
        let frownSeenL = reach(\.cornerDropL, .frown), frownSeenR = reach(\.cornerDropR, .frown)
        let (frownL, frownR) = FaceCalibration.apart(frownSeenL * FaceCalibration.frownGain,
                                                     frownSeenR * FaceCalibration.frownGain,
                                                     gain: FaceCalibration.mouthSideGain)
        set(.lipCornerDepressorL, frownL)
        set(.lipCornerDepressorR, frownR)

        // Smiling widens each half of the mouth without dropping the corners; suppress
        // smile weights once corner drop reaches half of a calibrated frown.
        let (wideL, wideR) = FaceCalibration.apart(reach(\.mouthWidthL, .smile), reach(\.mouthWidthR, .smile),
                                                   gain: FaceCalibration.mouthSideGain)
        let smileL = wideL * (1 - min(1, frownSeenL * 2)), smileR = wideR * (1 - min(1, frownSeenR * 2))
        set(.lipCornerPullerL, smileL)
        set(.lipCornerPullerR, smileR)
        set(.cheekRaiserL, smileL * 0.5)
        set(.cheekRaiserR, smileR * 0.5)

        // Both puckering and opening the jaw narrow the mouth. Compare current width against
        // the expected relaxed mouth width at the current jaw opening so jaw drop alone does
        // not trigger pucker. Combining pucker with an open jaw drives the lip funneler weights.
        if let open = poses[FacePose.jawOpen.rawValue], let puckered = poses[FacePose.pucker.rawValue] {
            let relaxedWidth = rest.mouthWidth + (open.mouthWidth - rest.mouthWidth) * jaw
            // Enforce a minimum denominator so a wide-open mouth (already nearly as narrow
            // as a pucker) does not cause pucker weights to flicker.
            let room = max(relaxedWidth - puckered.mouthWidth, 0.03)
            let pucker = max(0, min(1, (relaxedWidth - now.mouthWidth) / room))
            set(.lipPuckerL, pucker)
            set(.lipPuckerR, pucker)
            for funnel in [FaceExpression.lipFunnelerLB, .lipFunnelerLT, .lipFunnelerRB, .lipFunnelerRT] {
                set(funnel, pucker * jaw)
            }
        }

        // Eyelid closure and widening per eye.
        let (shutL, shutR) = FaceCalibration.apart(reach(\.eyeOpenL, .eyesClosed), reach(\.eyeOpenR, .eyesClosed),
                                                   gain: FaceCalibration.eyeSideGain)
        let pastRest = FaceCalibration.pastRest
        set(.eyesClosedL, pastRest(shutL))
        set(.eyesClosedR, pastRest(shutR))
        let (eyeWideL, eyeWideR) = FaceCalibration.apart(reach(\.eyeOpenL, .eyesWide), reach(\.eyeOpenR, .eyesWide),
                                                         gain: FaceCalibration.eyeSideGain)
        set(.upperLidRaiserL, pastRest(eyeWideL) * (1 - shutL))
        set(.upperLidRaiserR, pastRest(eyeWideR) * (1 - shutR))

        // Per-side brow raise and lower. Closing an eye pulls the corresponding brow slightly
        // downward and suppresses brow raise.
        let (browUpL, browUpR) = FaceCalibration.apart(reach(\.browLiftL, .browsUp), reach(\.browLiftR, .browsUp),
                                                       gain: FaceCalibration.browSideGain)
        let (browDownL, browDownR) = FaceCalibration.apart(reach(\.browLiftL, .browsDown), reach(\.browLiftR, .browsDown),
                                                           gain: FaceCalibration.browSideGain)
        set(.innerBrowRaiserL, pastRest(browUpL) * (1 - shutL)); set(.outerBrowRaiserL, pastRest(browUpL) * (1 - shutL))
        set(.innerBrowRaiserR, pastRest(browUpR) * (1 - shutR)); set(.outerBrowRaiserR, pastRest(browUpR) * (1 - shutR))
        set(.browLowererL, max(pastRest(browDownL), pastRest(shutL) * FaceCalibration.browFollowsLid))
        set(.browLowererR, max(pastRest(browDownR), pastRest(shutR) * FaceCalibration.browFollowsLid))
        return weights
    }
}

extension FaceExpressions {
    /// Sets the eight eye-look weights from horizontal and vertical gaze tangents in head
    /// space (see `GazeCalibration`), where `1.0` corresponds to `fullTurnDegrees` of rotation.
    public mutating func setEyeDirection(across: Float, up: Float, fullTurnDegrees: Float = 35) {
        func share(_ tangent: Float) -> Float { Float(atan(Double(tangent))) * 180 / .pi / fullTurnDegrees }
        let right = share(across), upward = share(up)
        func set(_ expression: FaceExpression, _ value: Float) { weights[expression.rawValue] = max(0, min(1, value)) }
        for (lookRight, lookLeft, lookUp, lookDown) in [
            (FaceExpression.eyesLookRightL, FaceExpression.eyesLookLeftL, FaceExpression.eyesLookUpL, FaceExpression.eyesLookDownL),
            (.eyesLookRightR, .eyesLookLeftR, .eyesLookUpR, .eyesLookDownR),
        ] {
            set(lookRight, right); set(lookLeft, -right); set(lookUp, upward); set(lookDown, -upward)
        }
    }
}

/// Adaptive exponential smoother for frame-to-frame expression weights. Small changes
/// (mostly landmark detector jitter) use a `slow` time constant, while large changes
/// (blinks, speech, or rapid expressions) interpolate using the `fast` time constant.
public struct FaceSmoother {
    private var last: [Float]?
    private var lastTime: Double?
    static let slow = 0.2, fast = 0.03
    /// Weight delta at which smoothing reaches the `fast` time constant.
    static let largeStep: Float = 0.35

    public init() {}

    public mutating func smooth(_ weights: [Float], seconds: Double) -> [Float] {
        defer { lastTime = seconds }
        guard let last, let lastTime, seconds > lastTime, seconds - lastTime < 0.5, last.count == weights.count else {
            self.last = weights
            return weights
        }
        let step = seconds - lastTime
        let out = zip(last, weights).map { old, new -> Float in
            let size = Double(min(1, abs(new - old) / FaceSmoother.largeStep))
            let timeConstant = FaceSmoother.slow + (FaceSmoother.fast - FaceSmoother.slow) * size
            return old + (new - old) * Float(1 - exp(-step / timeConstant))
        }
        self.last = out
        return out
    }
}
