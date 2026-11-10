// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Face expressions fitted to one user's face.
///
/// The rules of thumb in `FaceEstimator` turn measurements of a face into
/// expression weights with fixed numbers that suit nobody exactly.
/// The calibration step replaces the numbers with the user's own: they hold a few
/// expressions in turn while the measurements are recorded, and from then
/// on each weight is how far the face has gone from its resting measurement
/// towards the one it showed at that expression's fullest.

/// What is measured on a face in one picture. Every number is a length in
/// the picture divided by the face's width or height, so that distance from
/// the camera does not matter. "L" and "R" are the left and right of the
/// (mirrored) picture (ie, relative to the user, not a viewer), as in the expression names.
public struct FaceMeasures: Codable, Equatable {
    /// The gap between the lips, over the face's height.
    public var mouthOpen: Float = 0
    /// The mouth's width over the face's width, whole and by halves.
    public var mouthWidth: Float = 0, mouthWidthL: Float = 0, mouthWidthR: Float = 0
    /// How far each corner of the mouth is below the mouth's middle.
    public var cornerDropL: Float = 0, cornerDropR: Float = 0
    /// How far each brow is above the line through its eye's two corners.
    /// (Not above the top of the eye: that falls when the eye shuts, and
    /// shutting the eyes then read as raising the brows.)
    public var browLiftL: Float = 0, browLiftR: Float = 0
    /// How open each eye's lids are (its outline's area over its width squared).
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

/// The expressions the user is asked to hold, in order.
public enum FacePose: String, CaseIterable, Codable {
    // Shut eyes come last: nothing can be read with them shut.
    case neutral, jawOpen, smile, frown, pucker, browsUp, browsDown, eyesWide, eyesClosed

    /// What to ask for.
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
    /// The measurements recorded at each pose, by the pose's name.
    public var poses: [String: FaceMeasures]
    /// Which definition of the measurements these were recorded with.
    public var version: Int

    /// Raised whenever a measurement changes its meaning: recordings made before are then of no use.
    public static let currentVersion = 2

    public init(poses: [FacePose: FaceMeasures]) {
        self.poses = Dictionary(uniqueKeysWithValues: poses.map { ($0.key.rawValue, $0.value) })
        version = FaceCalibration.currentVersion
    }

    /// Whether every pose this build asks for is there, measured as this build measures.
    public var usable: Bool {
        version == FaceCalibration.currentVersion && FacePose.allCases.allSatisfy { poses[$0.rawValue] != nil }
    }

    /// The picture is of a Persona, which the system drives from its own
    /// reading of the face, and both it and the landmark detector tend to
    /// move the two sides of a face together: one eye shut reads as both
    /// half shut. So the difference between the two sides is exaggerated
    /// before it is used: each side is moved away from the average of the
    /// two by `gain` times its distance from it.
    static func apart(_ left: Float, _ right: Float, gain: Float) -> (left: Float, right: Float) {
        let middle = (left + right) / 2, half = (left - right) / 2 * gain
        return (max(0, min(1, middle + half)), max(0, min(1, middle - half)))
    }
    static let eyeSideGain: Float = 3, browSideGain: Float = 3, mouthSideGain: Float = 2
    /// A frown moves the mouth's corners little in the picture; what is seen is multiplied by this.
    static let frownGain: Float = 2.5
    /// How much of an eye's shutting its brow comes down with. The picture
    /// shows next to none of it, so it is put in.
    static let browFollowsLid: Float = 0.7
    /// Eyes and brows at rest never measure exactly as they did when
    /// calibrated: the first tenth or so of each of their weights is taken
    /// as rest, and the remainder stretched to cover 0 ... 1.
    static let restBand: Float = 0.12
    static func pastRest(_ weight: Float) -> Float { max(0, (weight - restBand) / (1 - restBand)) }

    /// The expression weights for a face measured as `now`. `fallback` is
    /// what the rules of thumb gave; its eye-direction weights are kept,
    /// since no pose here measures where the eyes look.
    public func weights(for now: FaceMeasures, fallback: [Float]) -> [Float] {
        guard usable, let rest = poses[FacePose.neutral.rawValue] else { return fallback }
        var weights = [Float](repeating: 0, count: FaceExpressions.weightCount)
        for look in [FaceExpression.eyesLookDownL, .eyesLookDownR, .eyesLookLeftL, .eyesLookLeftR,
                     .eyesLookRightL, .eyesLookRightR, .eyesLookUpL, .eyesLookUpR] {
            weights[look.rawValue] = fallback[look.rawValue]
        }
        /// 0 at rest, 1 at the pose's measurement, straight between; 0 if
        /// the pose did not move this measurement enough to go by.
        func reach(_ measure: KeyPath<FaceMeasures, Float>, _ pose: FacePose) -> Float {
            guard let full = poses[pose.rawValue] else { return 0 }
            let from = rest[keyPath: measure], to = full[keyPath: measure]
            guard abs(to - from) > 0.002 else { return 0 }
            return max(0, min(1, (now[keyPath: measure] - from) / (to - from)))
        }
        func set(_ expression: FaceExpression, _ value: Float) { weights[expression.rawValue] = max(0, min(1, value)) }

        let jaw = reach(\.mouthOpen, .jawOpen)
        set(.jawDrop, jaw)

        // A frown drops the mouth's corners below its middle (exaggerated,
        // see `frownGain`). It is worked out first because a frown also
        // widens the mouth, which is otherwise the sign of a smile.
        let frownSeenL = reach(\.cornerDropL, .frown), frownSeenR = reach(\.cornerDropR, .frown)
        let (frownL, frownR) = FaceCalibration.apart(frownSeenL * FaceCalibration.frownGain,
                                                     frownSeenR * FaceCalibration.frownGain,
                                                     gain: FaceCalibration.mouthSideGain)
        set(.lipCornerDepressorL, frownL)
        set(.lipCornerDepressorR, frownR)

        // A smile widens each half of the mouth, with the corners not
        // dropped: half a frown's drop already rules a smile out.
        let (wideL, wideR) = FaceCalibration.apart(reach(\.mouthWidthL, .smile), reach(\.mouthWidthR, .smile),
                                                   gain: FaceCalibration.mouthSideGain)
        let smileL = wideL * (1 - min(1, frownSeenL * 2)), smileR = wideR * (1 - min(1, frownSeenR * 2))
        set(.lipCornerPullerL, smileL)
        set(.lipCornerPullerR, smileR)
        set(.cheekRaiserL, smileL * 0.5)
        set(.cheekRaiserR, smileR * 0.5)

        // A pucker narrows the mouth. So does opening the jaw, so the
        // mouth is compared with how wide it would be at this much jaw
        // with the lips relaxed: narrower than that is pucker. With the
        // jaw open as well the lips are a ring (the funnel), as in a gasp.
        if let open = poses[FacePose.jawOpen.rawValue], let puckered = poses[FacePose.pucker.rawValue] {
            let relaxedWidth = rest.mouthWidth + (open.mouthWidth - rest.mouthWidth) * jaw
            // At least this much room, so that a wide-open mouth, already
            // nearly as narrow as a pucker, does not flicker into one.
            let room = max(relaxedWidth - puckered.mouthWidth, 0.03)
            let pucker = max(0, min(1, (relaxedWidth - now.mouthWidth) / room))
            set(.lipPuckerL, pucker)
            set(.lipPuckerR, pucker)
            for funnel in [FaceExpression.lipFunnelerLB, .lipFunnelerLT, .lipFunnelerRB, .lipFunnelerRT] {
                set(funnel, pucker * jaw)
            }
        }

        // Eyes, each on its own.
        let (shutL, shutR) = FaceCalibration.apart(reach(\.eyeOpenL, .eyesClosed), reach(\.eyeOpenR, .eyesClosed),
                                                   gain: FaceCalibration.eyeSideGain)
        let pastRest = FaceCalibration.pastRest
        set(.eyesClosedL, pastRest(shutL))
        set(.eyesClosedR, pastRest(shutR))
        let (eyeWideL, eyeWideR) = FaceCalibration.apart(reach(\.eyeOpenL, .eyesWide), reach(\.eyeOpenR, .eyesWide),
                                                         gain: FaceCalibration.eyeSideGain)
        set(.upperLidRaiserL, pastRest(eyeWideL) * (1 - shutL))
        set(.upperLidRaiserR, pastRest(eyeWideR) * (1 - shutR))

        // Brows, each on its own. A shutting eye takes its brow down with
        // it a little, as on a real face, and never up.
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
    /// Set the eight eye-direction weights from where the eyes look, given
    /// as tangents in the head's frame (see `GazeCalibration`): a weight of
    /// 1 is the eye turned `fullTurnDegrees` that way.
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

/// Steadies expression weights from one picture to the next. Each weight
/// moves towards its new value at a pace set by how far it has to go: a
/// small difference, which is mostly the detector's shimmer, is followed
/// slowly (a time constant of `slow` seconds); a large one, which is the
/// face really moving, a blink or a word, is followed fast (`fast`).
public struct FaceSmoother {
    private var last: [Float]?
    private var lastTime: Double?
    static let slow = 0.2, fast = 0.03
    /// A difference this large or larger is followed at the fast pace.
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
