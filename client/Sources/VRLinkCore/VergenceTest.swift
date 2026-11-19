// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Evaluates whether face-camera pupil vergence can estimate viewing distance.
///
/// Displays a reading chart across a sequence of known distances while recording
/// horizontal pupil vergence (`EyeFeatures.converging`) from the face camera.
/// Distances are analyzed in inverse meters (`nearness = 1 / distance`) because
/// both geometric vergence angle and translational reprojection error scale
/// linearly with inverse distance. `VergenceReport` fits a line to the step
/// medians to test whether the camera signal tracks distance reliably.
public struct VergenceTest {
    /// Target distances in meters, interleaved near-to-far so slow camera or posture drift does not alias with distance.
    public static let order: [Float] = [1.2, 0.4, 3.5, 0.8, 6, 0.6, 2]
    /// Settling time in seconds at the start of each step before samples are recorded.
    public static let settle = 1.5
    /// Recording duration in seconds at each distance step.
    public static let record = 3.0

    /// Full step sequence running `order` forward and then in reverse.
    public let steps: [Float]
    public let settle: Double, record: Double

    public init(order: [Float] = VergenceTest.order, settle: Double = VergenceTest.settle,
                record: Double = VergenceTest.record) {
        steps = order + order.reversed()
        self.settle = settle
        self.record = record
    }

    public var duration: Double { Double(steps.count) * (settle + record) }

    /// Returns the active step index, target distance, and whether settling has
    /// finished at `seconds`, or `nil` once the test completes.
    public func step(at seconds: Double) -> (index: Int, distance: Float, recording: Bool)? {
        guard seconds >= 0, seconds < duration else { return nil }
        let each = settle + record
        let index = min(steps.count - 1, Int(seconds / each))
        return (index, steps[index], seconds - Double(index) * each >= settle)
    }
}

/// A single pupil-vergence sample recorded while viewing a test chart.
public struct VergenceSample: Equatable {
    /// Index into `VergenceTest.steps`.
    public var step: Int
    public var seconds: Double
    /// Chart distance in meters along the forward axis when the sample was captured.
    public var distance: Float
    /// Measured pupil-vergence value.
    public var signal: Float
    /// Angular offset tangent between calibrated gaze and the chart center (`0` when uncalibrated).
    public var offTarget: Float
    /// Raw eye landmark features captured for this sample, retained for CSV export.
    public var eyes: EyeFeatures?

    public init(step: Int, seconds: Double, distance: Float, signal: Float, offTarget: Float = 0, eyes: EyeFeatures? = nil) {
        self.step = step
        self.seconds = seconds
        self.distance = distance
        self.signal = signal
        self.offTarget = offTarget
        self.eyes = eyes
    }
}

extension EyeFeatures {
    /// Horizontal pupil-vergence proxy (`leftAcross - rightAcross`). Changes
    /// monotonically as the eyes converge (sign depends on camera mirroring) and
    /// cancels conjugate horizontal eye movements to first order.
    public var converging: Float { leftAcross - rightAcross }
}

/// Summary statistics and linear regression fit for a completed `VergenceTest` run.
public struct VergenceReport {
    /// Maximum gaze-offset tangent (~9 degrees) allowed before a sample is excluded as off-chart.
    public static let onTarget: Float = 0.16

    /// Median and semi-interquartile range of the vergence signal at one step.
    public struct Spread: Equatable {
        public var median: Float
        /// Half the interquartile range (`(Q3 - Q1) / 2`).
        public var scatter: Float
        public var count: Int
    }

    public struct Row {
        public var step: Int
        /// Mean chart inverse depth (`1 / meters`) across accepted samples.
        public var nearness: Float
        /// Total samples captured and samples accepted within `onTarget`.
        public var taken: Int, kept: Int
        public var signal: Spread?
    }

    /// Linear regression `signal = gain * nearness + offset` across step medians.
    public struct Fit: Equatable {
        public var gain: Float, offset: Float
        /// RMS residual of step medians around the fitted line, in signal units.
        public var leftover: Float
        /// Median within-step semi-interquartile scatter across steps, in signal units.
        public var scatter: Float
        /// Coefficient of determination (`R^2`, `0...1`) across step medians.
        public var explained: Float

        /// Inverse depth (`1 / meters`) predicted for `signal`.
        public func nearness(for signal: Float) -> Float { (signal - offset) / gain }

        /// Whether the linear fit explains more than half the step-to-step variance (`R^2 > 0.5`).
        public var usable: Bool { explained > 0.5 }

        /// Equivalent inverse-depth error (`1 / meters`) for step medians (`error`) and individual samples (`readingError`).
        public var error: Float { leftover / max(abs(gain), 1e-6) }
        public var readingError: Float { scatter / max(abs(gain), 1e-6) }
    }

    public let rows: [Row]
    public let fit: Fit?

    public init(_ samples: [VergenceSample]) {
        var rows: [Row] = []
        for step in Set(samples.map(\.step)).sorted() {
            let taken = samples.filter { $0.step == step }
            let kept = taken.filter { $0.offTarget <= VergenceReport.onTarget && $0.distance > 0 && $0.signal.isFinite }
            guard !kept.isEmpty else {
                rows.append(Row(step: step, nearness: 0, taken: taken.count, kept: 0, signal: nil))
                continue
            }
            rows.append(Row(step: step, nearness: kept.map { 1 / $0.distance }.reduce(0, +) / Float(kept.count),
                            taken: taken.count, kept: kept.count, signal: VergenceReport.spread(kept.map(\.signal))))
        }
        self.rows = rows
        fit = VergenceReport.fit(rows.compactMap { row in row.signal.map { (row.nearness, $0) } })
    }

    static func spread(_ values: [Float]) -> Spread? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func at(_ fraction: Float) -> Float {
            let place = fraction * Float(sorted.count - 1)
            let low = Int(place), high = min(sorted.count - 1, low + 1)
            return sorted[low] + (sorted[high] - sorted[low]) * (place - Float(low))
        }
        return Spread(median: at(0.5), scatter: (at(0.75) - at(0.25)) / 2, count: sorted.count)
    }

    /// Ordinary least-squares fit across step medians; requires at least three steps with distinct distances.
    static func fit(_ points: [(nearness: Float, spread: Spread)]) -> Fit? {
        guard points.count >= 3 else { return nil }
        let n = Float(points.count)
        let meanX = points.map(\.nearness).reduce(0, +) / n
        let meanY = points.map(\.spread.median).reduce(0, +) / n
        let across = points.map { ($0.nearness - meanX) * ($0.nearness - meanX) }.reduce(0, +)
        guard across > 1e-6 else { return nil }
        let gain = points.map { ($0.nearness - meanX) * ($0.spread.median - meanY) }.reduce(0, +) / across
        let offset = meanY - gain * meanX
        let missed = points.map { pow($0.spread.median - (gain * $0.nearness + offset), 2) }.reduce(0, +)
        let varied = points.map { pow($0.spread.median - meanY, 2) }.reduce(0, +)
        let scatters = points.map(\.spread.scatter).sorted()
        return Fit(gain: gain, offset: offset, leftover: (missed / n).squareRoot(), scatter: scatters[scatters.count / 2],
                   explained: varied > 1e-12 ? max(0, 1 - missed / varied) : 0)
    }

    /// Human-readable summary lines for logging and display in the UI.
    public var lines: [String] {
        var out: [String] = []
        for row in rows {
            guard row.kept > 0, let signal = row.signal else {
                out.append("chart \(row.step + 1): no usable readings out of \(row.taken)")
                continue
            }
            out.append(String(format: "%.2f m (%.2f /m): signal %.4f ±%.4f, %d of %d readings",
                              1 / row.nearness, row.nearness, signal.median, signal.scatter, row.kept, row.taken))
        }
        guard let fit else {
            out.append("too few distances with readings to fit a line")
            return out
        }
        out.append(String(format: "signal = %.4f x nearness %@ %.4f (R^2 = %.0f%% across steps)",
                          fit.gain, fit.offset < 0 ? "-" : "+", abs(fit.offset), fit.explained * 100))
        guard fit.usable else {
            out.append("signal does not track distance reliably (not usable)")
            return out
        }
        out.append(String(format: "step RMS residual %.4f (%.2f /m); sample scatter ±%.4f (±%.2f /m)",
                          fit.leftover, fit.error, fit.scatter, fit.readingError))
        // Convert inverse-depth error bounds into meter ranges at representative distances.
        func range(_ meters: Float, _ error: Float) -> String {
            let near = 1 / (1 / meters + error), far = 1 / meters - error
            return String(format: "%.1f m as %.2f to %@", meters, near,
                          far > 0.01 ? String(format: "%.2f m", 1 / far) : "anything beyond")
        }
        for (name, error) in [("smoothed", fit.error), ("a single reading", fit.readingError)] {
            out.append("\(name) would read " + [0.5, 1, 3].map { range($0, error) }.joined(separator: "; "))
        }
        return out
    }

    /// Formats all samples as CSV with a header row for offline analysis.
    public static func csv(_ samples: [VergenceSample], steps: [Float]) -> String {
        var out = "step,shown_m,seconds,true_m,true_nearness,signal,off_target,"
            + "left_across,right_across,left_down,right_down,left_below_corners,right_below_corners,left_open,right_open\n"
        func number(_ value: Float?) -> String { value.map { String(format: "%.5f", $0) } ?? "" }
        for sample in samples {
            let shown = steps.indices.contains(sample.step) ? steps[sample.step] : 0
            let eyes = sample.eyes
            out += ["\(sample.step)", number(shown), String(format: "%.4f", sample.seconds), number(sample.distance),
                    number(sample.distance > 0 ? 1 / sample.distance : nil), number(sample.signal), number(sample.offTarget),
                    number(eyes?.leftAcross), number(eyes?.rightAcross), number(eyes?.leftDown), number(eyes?.rightDown),
                    number(eyes?.leftBelowCorners), number(eyes?.rightBelowCorners), number(eyes?.leftOpen),
                    number(eyes?.rightOpen)].joined(separator: ",") + "\n"
        }
        return out
    }
}
