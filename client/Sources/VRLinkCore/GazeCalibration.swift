// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Estimates eye gaze direction from face-camera pupil measurements (`EyeFeatures`)
/// on platforms that do not expose raw eye-tracking poses directly.
///
/// Because the mapping from camera features to gaze direction depends on facial
/// geometry and headset fit, it requires per-user calibration. The user looks at
/// targets while a ground-truth source supplies actual eye directions (on visionOS,
/// the system pinch ray provides world-space gaze rays).
///
/// Fitting a `GazeCalibration` to those samples maps `EyeFeatures` to real-time
/// gaze directions. Gaze direction is represented as two tangents in head space:
/// `across` (meters right per meter forward) and `up` (meters up per meter forward).

/// A single calibration sample pairing measured `EyeFeatures` with the ground-truth
/// head-space gaze tangents at that moment.
public struct GazeSample: Codable, Equatable {
    public var features: EyeFeatures
    public var across: Float, up: Float

    public init(features: EyeFeatures, across: Float, up: Float) {
        self.features = features
        self.across = across
        self.up = up
    }
}

public struct GazeCalibration: Codable, Equatable {
    /// Polynomial weights where `across = acrossTerms . terms(features)` (and
    /// similarly for `up`), over `terms = [1, a, d, a*a, a*d, d*d, c, o]` with
    /// `a = features.across`, `d = features.down`, `c = features.belowCorners`,
    /// and `o = features.open`. The first three terms fit a plane, the three
    /// quadratic terms account for spherical eye rotation projected onto a flat
    /// camera image, and the last two capture eyelid cues for vertical gaze
    /// (see `EyeFeatures`).
    public var acrossTerms: [Float]
    public var upTerms: [Float]
    /// RMS angular error across the training samples, in degrees.
    public var typicalErrorDegrees: Float
    public var sampleCount: Int
    /// Training samples ordered oldest-first, retained so the fit can be updated
    /// incrementally via `tuned(with:)`. Empty when loaded from older saved calibrations.
    public var samples: [GazeSample] = []

    static func terms(_ features: EyeFeatures) -> [Double] {
        let a = Double(features.across), d = Double(features.down)
        return [1, a, d, a * a, a * d, d * d, Double(features.belowCorners), Double(features.open)]
    }
    static let termCount = 8

    /// Whether the coefficient arrays match the current model's term count (older builds used fewer terms).
    public var usable: Bool { acrossTerms.count == GazeCalibration.termCount && upTerms.count == GazeCalibration.termCount }

    /// Evaluates the fitted head-space gaze tangents for `features`.
    public func tangents(for features: EyeFeatures) -> (across: Float, up: Float) {
        guard usable else { return (0, 0) }
        let terms = GazeCalibration.terms(features)
        var across = 0.0, up = 0.0
        for index in 0..<GazeCalibration.termCount {
            across += Double(acrossTerms[index]) * terms[index]
            up += Double(upTerms[index]) * terms[index]
        }
        return (Float(across), Float(up))
    }
}

extension GazeCalibration {
    /// Decodes saved calibrations, defaulting `samples` to empty for files written by older builds.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        acrossTerms = try saved.decode([Float].self, forKey: .acrossTerms)
        upTerms = try saved.decode([Float].self, forKey: .upTerms)
        typicalErrorDegrees = try saved.decode(Float.self, forKey: .typicalErrorDegrees)
        sampleCount = try saved.decode(Int.self, forKey: .sampleCount)
        samples = (try? saved.decodeIfPresent([GazeSample].self, forKey: .samples)) ?? []
    }

    /// Refits the calibration with an additional sample collected during normal
    /// use (for example, from a visionOS pinch ray while streaming) to track
    /// headset slippage during a session or across sessions.
    ///
    /// Returns `nil` if the calibration has no stored samples to refit, or if
    /// the new sample deviates from the current prediction by more than
    /// `furthestBelievable` (indicating a blink or saccade rather than headset shift).
    public func tuned(with sample: GazeSample) -> GazeCalibration? {
        guard usable, !samples.isEmpty else { return nil }
        let expected = tangents(for: sample.features)
        guard GazeCalibration.apart(expected, (sample.across, sample.up)) <= GazeCalibration.furthestBelievable
        else { return nil }
        var kept = samples
        // Once at capacity, replace the existing sample with the closest gaze
        // direction. Evicting the oldest sample instead would eventually cluster
        // all samples near the center where users pinch most often, degrading
        // accuracy at the edges.
        if kept.count >= GazeCalibration.mostSamples,
           let nearest = kept.indices.min(by: {
               GazeCalibration.apart((kept[$0].across, kept[$0].up), (sample.across, sample.up))
                   < GazeCalibration.apart((kept[$1].across, kept[$1].up), (sample.across, sample.up)) }) {
            kept.remove(at: nearest)
        }
        kept.append(sample)
        var calibrator = GazeCalibrator()
        calibrator.samples = kept
        return calibrator.fit(fading: GazeCalibration.fading)
    }

    /// Euclidean distance between two tangent pairs.
    static func apart(_ a: (across: Float, up: Float), _ b: (across: Float, up: Float)) -> Float {
        ((a.across - b.across) * (a.across - b.across) + (a.up - b.up) * (a.up - b.up)).squareRoot()
    }

    /// Maximum tangent-space residual allowed when accepting an online sample (~19 degrees).
    static let furthestBelievable: Float = 0.35
    /// Maximum number of samples retained for online refitting.
    static let mostSamples = 60
    /// Exponential decay factor per sample step during online refitting; the oldest of 60 samples retains about 1/6 weight.
    static let fading = 0.97
}

/// Collects calibration samples and fits a `GazeCalibration` to them.
public struct GazeCalibrator {
    public internal(set) var samples: [GazeSample] = []

    /// Minimum sample counts required for a linear fit and for a full quadratic fit.
    public static let fewestSamples = 5, fewestForCurvature = 10

    public init() {}

    /// Appends a calibration sample pairing camera features with ground-truth head-space tangents.
    public mutating func add(_ features: EyeFeatures, across: Float, up: Float) {
        samples.append(GazeSample(features: features, across: across, up: up))
    }

    /// Converts a world-space gaze direction vector into head-space tangents given `head`.
    public static func tangents(ofRay direction: Vec3, head: Pose) -> (across: Float, up: Float)? {
        let ahead = direction.dot(head.forward)
        guard ahead > 0.1 else { return nil }                // reject rays behind or nearly perpendicular to the head
        return (direction.dot(head.right) / ahead, direction.dot(head.up) / ahead)
    }

    /// Fits a `GazeCalibration` using weighted least squares, or returns `nil`
    /// if there are too few samples or the system is underdetermined (for example,
    /// all samples look at the same target). When `fading` is less than 1, older
    /// samples are exponentially down-weighted (see `GazeCalibration.tuned`).
    public func fit(fading: Double = 1) -> GazeCalibration? {
        guard samples.count >= GazeCalibrator.fewestSamples else { return nil }
        // Fit only the linear plane terms until enough samples are available for curvature.
        let termCount = samples.count >= GazeCalibrator.fewestForCurvature ? GazeCalibration.termCount : 3
        let rows = samples.map { Array(GazeCalibration.terms($0.features).prefix(termCount)) }
        // Apply light L2 regularization (ridge regression) to the higher-order
        // terms so noisy samples do not cause wild extrapolation near the edges.
        let weights = samples.indices.map { pow(fading, Double(samples.count - 1 - $0)) }
        let restraint = 1e-4 * weights.reduce(0, +)
        func solve(_ targets: [Double]) -> [Double]? {
            // Build the weighted normal equations `(rows^T * W * rows + restraint * I) * x = rows^T * W * targets`.
            var m = [[Double]](repeating: [Double](repeating: 0, count: termCount + 1), count: termCount)
            for (index, row) in rows.enumerated() {
                for i in 0..<termCount {
                    for j in 0..<termCount { m[i][j] += weights[index] * row[i] * row[j] }
                    m[i][termCount] += weights[index] * row[i] * targets[index]
                }
            }
            for i in 3..<termCount { m[i][i] += restraint }
            // Solve via Gaussian elimination with partial pivoting.
            for column in 0..<termCount {
                let pivot = (column..<termCount).max { abs(m[$0][column]) < abs(m[$1][column]) }!
                guard abs(m[pivot][column]) > 1e-9 else { return nil }
                m.swapAt(column, pivot)
                for row in 0..<termCount where row != column {
                    let factor = m[row][column] / m[column][column]
                    for k in column...termCount { m[row][k] -= factor * m[column][k] }
                }
            }
            return (0..<termCount).map { m[$0][termCount] / m[$0][$0] }
                + [Double](repeating: 0, count: GazeCalibration.termCount - termCount)
        }
        guard let across = solve(samples.map { Double($0.across) }), let up = solve(samples.map { Double($0.up) })
        else { return nil }
        var calibration = GazeCalibration(acrossTerms: across.map { Float($0) }, upTerms: up.map { Float($0) },
                                          typicalErrorDegrees: 0, sampleCount: samples.count, samples: samples)
        // Compute the RMS angular error (in degrees) between ground-truth and fitted gaze vectors.
        var squares = 0.0
        for sample in samples {
            let fitted = calibration.tangents(for: sample.features)
            let truth = Vec3(sample.across, sample.up, -1), guess = Vec3(fitted.across, fitted.up, -1)
            let cosine = truth.dot(guess) / (length(truth) * length(guess))
            let angle = acos(Double(max(-1, min(1, cosine)))) * 180 / .pi
            squares += angle * angle
        }
        calibration.typicalErrorDegrees = Float((squares / Double(samples.count)).squareRoot())
        return calibration
    }
}

/// Converts a stream of face-camera eye features into smoothed head-space gaze targets.
public struct GazeFromFeatures {
    private var filter = OneEuroFilterVec3(slowestCutoff: 2.0, speedGain: 30)
    private var lastTime: Double?
    private var last: Vec3?

    /// Assumed vergence/fixation distance in meters.
    public static let fixationDistance: Float = 1.5

    public init() {}

    /// Returns the smoothed 3D fixation point in head space (+x right, +y up, +z back)
    /// expected by `StreamSession.gazeProvider`.
    public mutating func gaze(_ estimate: FaceEstimate, calibration: GazeCalibration, seconds: Double) -> Vec3 {
        // Hold the last valid gaze point during blinks when pupils are occluded.
        if estimate.blinking, let last { return last }
        let tangents = calibration.tangents(for: estimate.eyes)
        let step = Float(seconds - (lastTime ?? seconds))
        if step < 0 || step > 0.5 { filter = OneEuroFilterVec3(slowestCutoff: 2.0, speedGain: 30) }
        lastTime = seconds
        // Clamp extreme tangents caused by polynomial extrapolation outside the calibrated range.
        let limit: Float = 1.2
        let steadied = filter.smooth(Vec3(max(-limit, min(limit, tangents.across)), max(-limit, min(limit, tangents.up)), 0),
                                     seconds: max(step, 0))
        let direction = Vec3(steadied.x, steadied.y, -1)
        let gaze = direction * (GazeFromFeatures.fixationDistance / length(direction))
        last = gaze
        return gaze
    }
}
