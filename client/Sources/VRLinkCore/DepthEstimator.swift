// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Asynchronously estimates a `DepthField` from decoded video frames off the render thread.
///
/// The display loop offers each newly decoded frame via `offer(_:)`. Frames
/// offered while a previous frame is still in flight (or within the rate-limit
/// interval) are dropped immediately so depth estimation never blocks rendering
/// and trails display by at most a frame or two. Accepted frames are downsampled
/// to grayscale stereo pairs, matched (`StereoMatcher`), and temporally filtered
/// (`DepthSmoother`). Each `DepthField` records the pose of its source frame so
/// callers can reproject it to later frames via `DepthField.fitted(to:)`.
public final class StereoDepthEstimator<Frame> {
    /// Diagnostic metrics from the most recently processed frame.
    public struct Report {
        /// Fraction of grid cells (`0...1`) with recent confident measurements.
        public var measured: Float
        /// Inverse depth (`1 / meters`) at view center and maximum inverse depth across the grid.
        public var ahead: Float, nearest: Float
        /// CPU time spent smoothing (plus CPU matching when no GPU `measure` callback is supplied)
        /// and total wall-clock latency from `offer` to completion, in milliseconds.
        public var milliseconds: Double
        public var behind: Double
        /// Cumulative counts of processed frames (`taken`) and skipped frames (`passed`).
        public var taken: Int, passed: Int
    }

    /// Asynchronous frame-measurement hook (such as `StereoShrink.measure`); may complete on any queue.
    public typealias Measure = (Frame, [DepthSampling.Interest], @escaping (StereoMeasure?) -> Void) -> Void
    /// Downsamples a frame into a `width`-pixel-wide grayscale stereo pair for CPU matching. Called off the
    /// render thread and may complete on any queue (passing `nil` if the frame cannot be read).
    public typealias Shrink = (Frame, Int, @escaping (StereoPair?) -> Void) -> Void

    private let width: Int
    private let measure: Measure?
    private let shrink: Shrink
    /// Utility-priority queue kept below decode, render, and tracking threads so stereo depth never contends for high-priority cores.
    private let work = DispatchQueue(label: "depth from picture", qos: .utility)
    /// Minimum interval in seconds between accepted frames; scene geometry changes slowly enough that 30 Hz updates are sufficient.
    private let least: Double
    private var lastTaken: UInt64 = 0
    private let lock = NSLock()
    private var busy = false
    private var latest: DepthField?
    private var latestReport: Report?
    private var taken = 0, passed = 0
    /// Incremented by `forget()` so any in-flight frame from before a reset is discarded on completion.
    private var generation = 0
    // Accessed exclusively on `work`.
    private var smoother = DepthSmoother()
    private let matcher: StereoMatcher

    /// - Parameters:
    ///   - width: Horizontal resolution in pixels when downsampling frames for CPU matching.
    ///     Larger widths improve disparity precision at higher CPU cost.
    ///   - most: Maximum number of frames processed per second; extra frames are skipped.
    ///   - measure: Optional GPU callback that downsamples and matches a frame on the GPU
    ///     (such as `StereoShrink.measure`).
    ///   - shrink: Fallback callback that downsamples a frame into a grayscale stereo pair for CPU matching
    ///     when `measure` is `nil`.
    public init(width: Int = 384, most: Double = 30, measure: Measure? = nil, shrink: @escaping Shrink) {
        self.width = width
        self.measure = measure
        self.shrink = shrink
        matcher = StereoMatcher.fitted(toWidth: width)
        least = most > 0 ? 1 / most : 0
    }

    /// Latest smoothed depth field, or `nil` before the first frame finishes.
    public var field: DepthField? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public var report: Report? {
        lock.lock()
        defer { lock.unlock() }
        return latestReport
    }

    /// Clears the current depth field and resets temporal state so rendering returns to flat quads until new frames arrive.
    public func forget() {
        lock.lock()
        latest = nil
        latestReport = nil
        generation += 1
        lock.unlock()
        work.async { [self] in smoother = DepthSmoother() }
    }

    /// Submits `frame` for background depth estimation when the estimator is idle and past the
    /// rate-limit interval, then returns immediately. When sparse sampling is enabled, `interests`
    /// specifies the regions to match at full grid density.
    public func offer(_ frame: Frame, interests: [DepthSampling.Interest] = []) {
        let now = Uptime.nanoseconds
        lock.lock()
        // Allow a 10% timing slack so a steady 90 Hz stream consistently accepts every third frame rather than slipping to every fourth.
        guard !busy, Double(now &- lastTaken) / 1e9 >= least * 0.9 else {
            passed += 1
            lock.unlock()
            return
        }
        busy = true
        lastTaken = now
        let asked = generation
        lock.unlock()
        let offered = Uptime.nanoseconds
        if let measure {
            measure(frame, interests) { [self] measured in work.async { [self] in finish({ measured }, asked: asked, offered: offered) } }
        } else {
            work.async { [self] in
                shrink(frame, width) { [self] pair in
                    work.async { [self] in
                        finish({ pair.map { matcher.measured($0, interests: interests) } }, asked: asked, offered: offered)
                    }
                }
            }
        }
    }

    /// Updates the temporal smoother with one frame's measurements on `work`.
    private func finish(_ measured: () -> StereoMeasure?, asked: Int, offered: UInt64) {
        let began = Uptime.nanoseconds
        let found = measured().map { smoother.update($0) }
        let now = Uptime.nanoseconds
        lock.lock()
        busy = false
        if let found, asked == generation {
            taken += 1
            latest = found
            latestReport = Report(measured: smoother.measured, ahead: found.nearness(across: 0, up: 0),
                                  nearest: found.nearness.max() ?? 0, milliseconds: Double(now - began) / 1e6,
                                  behind: Double(now - offered) / 1e6, taken: taken, passed: passed)
        } else {
            passed += 1
        }
        lock.unlock()
    }
}
