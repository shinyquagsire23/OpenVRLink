// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Foundation
import VRLinkCore

/// Asynchronously estimates a `DepthField` from decoded video frames off the render thread.
///
/// The display loop offers each newly decoded frame via `offer(_:)`. Frames
/// offered while a previous frame is still in flight (or within the rate-limit
/// interval) are dropped immediately so depth estimation never blocks rendering
/// and trails display by at most a frame or two. Accepted frames are downsampled
/// to grayscale stereo pairs, matched (`StereoMatcher`), and temporally filtered
/// (`DepthSmoother`). Each `DepthField` records the pose of its source frame so
/// callers can reproject it to later frames via `DepthField.fitted(to:)`.
public final class DepthEstimator {
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
    public typealias Measure = (DecodedFrame, @escaping (StereoMeasure?) -> Void) -> Void

    private let width: Int
    private let measure: Measure?
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
    ///   - width: Horizontal resolution in pixels when downsampling frames on the CPU.
    ///     Larger widths improve disparity precision at higher CPU cost.
    ///   - most: Maximum number of frames processed per second; extra frames are skipped.
    ///   - measure: Optional GPU measurement callback (such as `StereoShrink.measure`)
    ///     used when decoded buffers are in GPU-only compressed formats.
    public init(width: Int = 384, most: Double = 30, measure: Measure? = nil) {
        self.width = width
        self.measure = measure
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

    /// Submits `frame` for background depth estimation if idle and past the rate-limit interval; returns immediately.
    public func offer(_ frame: DecodedFrame) {
        let now = DispatchTime.now().uptimeNanoseconds
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
        let offered = DispatchTime.now().uptimeNanoseconds
        if let measure {
            measure(frame) { [self] measured in work.async { [self] in finish({ measured }, asked: asked, offered: offered) } }
        } else {
            work.async { [self] in
                finish({ DepthEstimator.pair(from: frame, width: width).map(matcher.measured) }, asked: asked, offered: offered)
            }
        }
    }

    /// Updates the temporal smoother with one frame's measurements on `work`.
    private func finish(_ measured: () -> StereoMeasure?, asked: Int, offered: UInt64) {
        let began = DispatchTime.now().uptimeNanoseconds
        let found = measured().map { smoother.update($0) }
        let now = DispatchTime.now().uptimeNanoseconds
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

    /// Returns `(bytesPerPixel, msbOffset)` for uncompressed biplanar YCbCr formats
    /// whose luma plane can be read directly on the CPU, or `nil` for compressed formats.
    private static func brightness(in format: OSType) -> (bytes: Int, taking: Int)? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return (1, 0)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return (2, 1)       // 10-bit P010 stores samples in the upper bits of a 16-bit little-endian word, so byte 1 holds the top 8 bits
        default:
            return nil          // lossless-compressed hardware decoder formats cannot be read as linear CPU rows
        }
    }

    /// Downsamples both eyes of `frame` onto a shared `width`-pixel tangent grid by
    /// reading uncompressed luma planes on the CPU. Returns `nil` if the frame
    /// lacks parallel stereo views or uses GPU-only compressed pixel buffers (handled by `StereoShrink`).
    public static func pair(from frame: DecodedFrame, width: Int) -> StereoPair? {
        guard let plan = StereoPlan(layout: frame.layout, width: width) else { return nil }
        let window = plan.window, height = plan.height, perTangent = plan.perTangent, perTangentDown = plan.perTangentDown

        var pictures: [LumaPicture] = []
        for (view, covered) in zip(frame.layout.views, plan.covered) {
            var picture = LumaPicture(width: width, height: height)
            let columns = covered.x, rows = covered.y
            // Base peripheral tiles precede foveal insets in `view.tiles`; keeping the first tile
            // that covers each pixel ensures both eyes sample matching resolution layers.
            var filled = [Bool](repeating: false, count: width * height)
            for tile in view.tiles {
                guard frame.images.indices.contains(tile.picture) else { return nil }
                let image = frame.images[tile.picture]
                guard let kind = brightness(in: CVPixelBufferGetPixelFormatType(image)) else { return nil }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
                let sourceWidth = CVPixelBufferGetWidthOfPlane(image, 0), sourceHeight = CVPixelBufferGetHeightOfPlane(image, 0)
                // Compute integer pixel bounds of this tile within the source luma plane.
                let tileLeft = tile.left * Float(sourceWidth), tileTop = tile.top * Float(sourceHeight)
                let tileWide = (tile.right - tile.left) * Float(sourceWidth), tileTall = (tile.bottom - tile.top) * Float(sourceHeight)
                let firstX = max(0, Int(tileLeft.rounded(.up))), lastX = min(sourceWidth, Int((tileLeft + tileWide).rounded(.down))) - 1
                let firstY = max(0, Int(tileTop.rounded(.up))), lastY = min(sourceHeight, Int((tileTop + tileTall).rounded(.down))) - 1
                guard lastX >= firstX, lastY >= firstY else { continue }
                // Average a 2x2 grid of source samples spaced across each output pixel's footprint.
                let stepX = tileWide / ((tile.frustum.right - tile.frustum.left) * perTangent)
                let stepY = tileTall / ((tile.frustum.up - tile.frustum.down) * perTangentDown)
                let tileColumns = max(columns.lowerBound, Int(((tile.frustum.left - window.left) * perTangent).rounded(.up)))
                    ..< min(columns.upperBound, Int(((tile.frustum.right - window.left) * perTangent).rounded(.up)))
                let tileRows = max(rows.lowerBound, Int(((window.up - tile.frustum.up) * perTangentDown).rounded(.up)))
                    ..< min(rows.upperBound, Int(((window.up - tile.frustum.down) * perTangentDown).rounded(.up)))
                guard !tileColumns.isEmpty, !tileRows.isEmpty else { continue }
                // Precompute the two horizontal source byte offsets for each output column.
                let sourceColumns = tileColumns.map { column -> (Int, Int) in
                    let tangent = window.left + (Float(column) + 0.5) / perTangent
                    let x = tileLeft + (tangent - tile.frustum.left) / (tile.frustum.right - tile.frustum.left) * tileWide
                    return (max(firstX, min(lastX, Int(x - stepX / 4))) * kind.bytes + kind.taking,
                            max(firstX, min(lastX, Int(x + stepX / 4))) * kind.bytes + kind.taking)
                }
                for row in tileRows {
                    let tangent = window.up - (Float(row) + 0.5) / perTangentDown
                    let y = tileTop + (tile.frustum.up - tangent) / (tile.frustum.up - tile.frustum.down) * tileTall
                    let upper = bytes + max(firstY, min(lastY, Int(y - stepY / 4))) * rowBytes
                    let lower = bytes + max(firstY, min(lastY, Int(y + stepY / 4))) * rowBytes
                    for (index, column) in tileColumns.enumerated() where !filled[row * width + column] {
                        let (a, b) = sourceColumns[index]
                        picture.pixels[row * width + column]
                            = UInt8((Int(upper[a]) + Int(upper[b]) + Int(lower[a]) + Int(lower[b]) + 2) / 4)
                        filled[row * width + column] = true
                    }
                }
            }
            pictures.append(picture)
        }
        return plan.pair(left: pictures[0], right: pictures[1])
    }
}
