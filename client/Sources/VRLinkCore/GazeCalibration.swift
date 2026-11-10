// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Where the eyes look, worked out from where the pupils sit in a camera
/// picture of the face (`EyeFeatures`), for platforms that don't provide
/// poses directly.
///
/// The link between the two is different for every face and every fit of
/// the headset, so it is calibrated: the wearer looks at a number of places
/// while a ground-truth provider provides real eye poses 
/// (On visionOS, the gaze-pinch ray provides in-meters eye poses).
///
/// From those data pairs a `GazeCalibration` is fitted, which from then on 
/// turns features into a real-time gaze pose.
///
/// A gaze pose is written as two tangents in the head's frame: `across` is
/// meters to the right per meter ahead, `up` meters up per meter ahead.

/// One calibration pair: what the camera saw of the eyes, and where they
/// really looked then, as tangents in the head's frame.
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
    /// across = acrossTerms . terms(features), and the same for up, where
    /// terms = [1, a, d, a*a, a*d, d*d, c, o] with a = features.across,
    /// d = features.down, c = features.belowCorners and o = features.open.
    /// The first three are a plane; the next three let it bend, since an
    /// eyeball turns and a picture of it is flat; the last two are the
    /// other signs of looking up and down (see `EyeFeatures`).
    public var acrossTerms: [Float]
    public var upTerms: [Float]
    /// How far off the fit was on its own samples, root mean square, in degrees.
    public var typicalErrorDegrees: Float
    public var sampleCount: Int
    /// The pairs it was fitted to, oldest first, kept so that it can be
    /// fitted again with more (`tuned`). Empty in a calibration saved by a
    /// build that did not keep them.
    public var samples: [GazeSample] = []

    static func terms(_ features: EyeFeatures) -> [Double] {
        let a = Double(features.across), d = Double(features.down)
        return [1, a, d, a * a, a * d, d * d, Double(features.belowCorners), Double(features.open)]
    }
    static let termCount = 8

    /// Whether this is a fit this build can use (an older one had fewer terms).
    public var usable: Bool { acrossTerms.count == GazeCalibration.termCount && upTerms.count == GazeCalibration.termCount }

    /// The direction for these features, as tangents.
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
    /// A file from a build that kept no samples still reads.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        acrossTerms = try saved.decode([Float].self, forKey: .acrossTerms)
        upTerms = try saved.decode([Float].self, forKey: .upTerms)
        typicalErrorDegrees = try saved.decode(Float.self, forKey: .typicalErrorDegrees)
        sampleCount = try saved.decode(Int.self, forKey: .sampleCount)
        samples = (try? saved.decodeIfPresent([GazeSample].self, forKey: .samples)) ?? []
    }

    /// Continuous calibration: this calibration fitted again with one more
    /// pair, picked up while it was in use (on visionOS, a pinch made while
    /// streaming, whose ray says where the eyes looked). The fit of the
    /// headset shifts through a session and from one wearing to the next,
    /// and this follows it.
    ///
    /// Nil when the pair is not taken: a calibration with no samples kept
    /// cannot be fitted again, and a pair that disagrees with it by more
    /// than `furthestBelievable` is a bad reading of the eyes (they were
    /// moving, or half shut), not news about the fit.
    public func tuned(with sample: GazeSample) -> GazeCalibration? {
        guard usable, !samples.isEmpty else { return nil }
        let expected = tangents(for: sample.features)
        guard GazeCalibration.apart(expected, (sample.across, sample.up)) <= GazeCalibration.furthestBelievable
        else { return nil }
        var kept = samples
        // Once there are enough, the new pair takes the place of the old
        // one that looked nearest to the same spot. Dropping the oldest
        // instead would in time leave only where people pinch most, the
        // middle, and nothing to hold the fit down at the edges.
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

    /// How far apart two directions are, as a length between their tangents.
    static func apart(_ a: (across: Float, up: Float), _ b: (across: Float, up: Float)) -> Float {
        ((a.across - b.across) * (a.across - b.across) + (a.up - b.up) * (a.up - b.up)).squareRoot()
    }

    /// A new pair this far from what the calibration expects is left out (tangent; about 19 degrees).
    static let furthestBelievable: Float = 0.35
    /// How many pairs are kept.
    static let mostSamples = 60
    /// When tuning, each pair counts this much of the one after it, so the
    /// newest say most; the oldest of sixty still counts a sixth.
    static let fading = 0.97
}

/// Collects calibration samples and fits a `GazeCalibration` to them.
public struct GazeCalibrator {
    public internal(set) var samples: [GazeSample] = []

    /// The fewest samples a fit is made from, and the fewest for one that may bend.
    public static let fewestSamples = 5, fewestForCurvature = 10

    public init() {}

    /// One pair: what the camera saw, and where the eyes really looked.
    public mutating func add(_ features: EyeFeatures, across: Float, up: Float) {
        samples.append(GazeSample(features: features, across: across, up: up))
    }

    /// Where the eyes looked, from a ray known in world space and the head's pose then.
    public static func tangents(ofRay direction: Vec3, head: Pose) -> (across: Float, up: Float)? {
        let ahead = direction.dot(head.forward)
        guard ahead > 0.1 else { return nil }                // not a ray behind or beside the head
        return (direction.dot(head.right) / ahead, direction.dot(head.up) / ahead)
    }

    /// The calibration that fits the samples best (least squares), or nil
    /// when there are too few or they do not pin it down, as when every
    /// sample looks at the same place. With `fading` below 1 each sample
    /// counts that much of the one after it (see `GazeCalibration.tuned`).
    public func fit(fading: Double = 1) -> GazeCalibration? {
        guard samples.count >= GazeCalibrator.fewestSamples else { return nil }
        // With few samples only the plane is fitted; the bending terms stay zero.
        let termCount = samples.count >= GazeCalibrator.fewestForCurvature ? GazeCalibration.termCount : 3
        let rows = samples.map { Array(GazeCalibration.terms($0.features).prefix(termCount)) }
        // The bending terms are held back a little (ridge regression), so
        // that noise in a handful of samples does not turn into wild curves
        // away from them.
        let weights = samples.indices.map { pow(fading, Double(samples.count - 1 - $0)) }
        let restraint = 1e-4 * weights.reduce(0, +)
        func solve(_ targets: [Double]) -> [Double]? {
            // Normal equations: (rows' rows + restraint) x = rows' targets.
            var m = [[Double]](repeating: [Double](repeating: 0, count: termCount + 1), count: termCount)
            for (index, row) in rows.enumerated() {
                for i in 0..<termCount {
                    for j in 0..<termCount { m[i][j] += weights[index] * row[i] * row[j] }
                    m[i][termCount] += weights[index] * row[i] * targets[index]
                }
            }
            for i in 3..<termCount { m[i][i] += restraint }
            // Gaussian elimination, largest pivot first.
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
        // How well it does on what it was fitted to: the angle between the true and the fitted direction.
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

/// Turns a stream of eye features into a gaze that is sent to vrlink
public struct GazeFromFeatures {
    private var filter = OneEuroFilterVec3(slowestCutoff: 2.0, speedGain: 30)
    private var lastTime: Double?
    private var last: Vec3?

    /// How far away the eyes are taken to be fixed, in meters
    public static let fixationDistance: Float = 1.5

    public init() {}

    /// The fixation point in the head's frame (x right, y up, z back), as
    /// `StreamSession.gazeProvider` wants it.
    public mutating func gaze(_ estimate: FaceEstimate, calibration: GazeCalibration, seconds: Double) -> Vec3 {
        // A shut eye has no pupil to find: keep looking where it last looked.
        if estimate.blinking, let last { return last }
        let tangents = calibration.tangents(for: estimate.eyes)
        let step = Float(seconds - (lastTime ?? seconds))
        if step < 0 || step > 0.5 { filter = OneEuroFilterVec3(slowestCutoff: 2.0, speedGain: 30) }
        lastTime = seconds
        // Nobody's eyes turn further than this; a wilder answer is the fit running away.
        let limit: Float = 1.2
        let steadied = filter.smooth(Vec3(max(-limit, min(limit, tangents.across)), max(-limit, min(limit, tangents.up)), 0),
                                     seconds: max(step, 0))
        let direction = Vec3(steadied.x, steadied.y, -1)
        let gaze = direction * (GazeFromFeatures.fixationDistance / length(direction))
        last = gaze
        return gaze
    }
}
