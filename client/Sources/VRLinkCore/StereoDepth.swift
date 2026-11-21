// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Stereo depth estimation and temporal smoothing.
//
// Neither Steam VR Link nor WiVRn streams a depth buffer from the host, so we
// estimate scene depth on the client from stereo disparity between the left and
// right eye images. `StereoMatcher` measures horizontal disparity on a coarse
// grid, `DepthSmoother` filters those measurements over time and fills unmeasured
// regions, and `Composition` warps the video quads to the resulting `DepthField`
// so head translation produces depth-dependent parallax.
//
// Depths are stored as inverse distance (`nearness = 1 / meters`) because both
// stereo disparity and translational reprojection error scale linearly with
// inverse distance, and objects at infinity map cleanly to zero.

/// Single-channel 8-bit grayscale image stored row-major from the top row.
public struct LumaPicture {
    public var width: Int, height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height)
    }
}

/// Left and right eye grayscale images resampled onto a common rectilinear
/// view-tangent grid (`window`). Pixel `(i, j)` in each image corresponds to
/// tangent `window.left + (i + 0.5) / width * span` horizontally and similarly
/// downward from `window.up` in that eye's frame. Both eyes must share the same
/// orientation so stereo correspondences lie along horizontal scanlines.
public struct StereoPair {
    public var left: LumaPicture, right: LumaPicture
    public var window: Frustum
    /// Interpupillary baseline in meters from the left eye to the right eye along their shared right axis.
    public var apart: Float
    /// Pixel bounds within each image that contain valid rendered content.
    public var leftCovered: (x: Range<Int>, y: Range<Int>)
    public var rightCovered: (x: Range<Int>, y: Range<Int>)
    /// Cyclopean rendering pose midway between the two eyes, or `nil` if unknown.
    public var pose: Pose?

    public init(left: LumaPicture, right: LumaPicture, window: Frustum, apart: Float,
                leftCovered: (x: Range<Int>, y: Range<Int>)? = nil, rightCovered: (x: Range<Int>, y: Range<Int>)? = nil,
                pose: Pose? = nil) {
        self.pose = pose
        self.left = left
        self.right = right
        self.window = window
        self.apart = apart
        self.leftCovered = leftCovered ?? (0..<left.width, 0..<left.height)
        self.rightCovered = rightCovered ?? (0..<right.width, 0..<right.height)
    }

    /// Horizontal disparity in pixels per inverse meter (`1 / m`) of `nearness`.
    public var pixelsPerNearness: Float { apart * Float(left.width) / (window.right - window.left) }

    /// Downsamples both images by 2x along each axis using a 2x2 box filter.
    public func halved() -> StereoPair {
        func half(_ picture: LumaPicture) -> LumaPicture {
            var out = LumaPicture(width: picture.width / 2, height: picture.height / 2)
            for row in 0..<out.height {
                for column in 0..<out.width {
                    let from = row * 2 * picture.width + column * 2
                    out.pixels[row * out.width + column] = UInt8((Int(picture.pixels[from]) + Int(picture.pixels[from + 1])
                        + Int(picture.pixels[from + picture.width]) + Int(picture.pixels[from + picture.width + 1]) + 2) / 4)
                }
            }
            return out
        }
        // Shrink the valid region conservatively to output pixels whose entire 2x2 source block is valid.
        func half(_ covered: (x: Range<Int>, y: Range<Int>)) -> (x: Range<Int>, y: Range<Int>) {
            func each(_ range: Range<Int>) -> Range<Int> {
                let first = (range.lowerBound + 1) / 2
                return first ..< max(first, range.upperBound / 2)
            }
            return (each(covered.x), each(covered.y))
        }
        return StereoPair(left: half(left), right: half(right), window: window, apart: apart,
                          leftCovered: half(leftCovered), rightCovered: half(rightCovered), pose: pose)
    }
}

extension StereoPair {
    /// Subdirectory in `DataDirectory` where diagnostic stereo pairs are written.
    public static var saved: URL { DataDirectory.url.appendingPathComponent("depth-pictures") }

    /// Writes the left and right images as binary PGM files alongside a JSON
    /// metadata file, using a ring buffer of `keep` slots indexed by `number % keep`
    /// for offline debugging of stereo matching failures.
    public func save(number: Int, keep: Int = 8, to folder: URL = StereoPair.saved) {
        let name = "pair-\(((number % keep) + keep) % keep)"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (side, picture) in [("left", left), ("right", right)] {
                var file = Data("P5\n\(picture.width) \(picture.height)\n255\n".utf8)
                file.append(contentsOf: picture.pixels)
                try file.write(to: folder.appendingPathComponent("\(name)-\(side).pgm"), options: .atomic)
            }
            let about: [String: Any] = [
                "number": number, "apart": apart,
                "window": [window.left, window.right, window.down, window.up],
                "leftCovered": [leftCovered.x.lowerBound, leftCovered.x.upperBound, leftCovered.y.lowerBound, leftCovered.y.upperBound],
                "rightCovered": [rightCovered.x.lowerBound, rightCovered.x.upperBound, rightCovered.y.lowerBound, rightCovered.y.upperBound],
            ]
            try JSONSerialization.data(withJSONObject: about, options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)
        } catch {
            Log.note("depth: failed to save diagnostic stereo pair: \(error)")
        }
    }
}

/// Describes how to resample a frame's left and right eye views onto a shared
/// `StereoPair` tangent grid, including output dimensions and valid pixel bounds.
public struct StereoPlan {
    public var window: Frustum
    public var width: Int, height: Int
    /// Interpupillary baseline in meters from the left eye to the right eye.
    public var apart: Float
    /// Valid pixel bounds `[left, right]` covered by each eye's tiles.
    public var covered: [(x: Range<Int>, y: Range<Int>)]
    /// Cyclopean rendering pose midway between the two eyes.
    public var pose: Pose

    /// Output pixels per unit of view tangent horizontally and vertically. `height`
    /// is rounded to a multiple of 4 so two 2x halving steps divide evenly, which
    /// can make horizontal and vertical pixel scales differ slightly.
    public var perTangent: Float { Float(width) / (window.right - window.left) }
    public var perTangentDown: Float { Float(height) / (window.up - window.down) }

    /// Builds a resampling plan when `layout` contains two parallel, horizontally
    /// separated eyes so stereo disparity lies strictly along image rows; returns `nil` otherwise.
    public init?(layout: FrameLayout, width: Int) {
        let views = layout.views
        guard views.count == 2, width >= 32, views.allSatisfy({ !$0.tiles.isEmpty }) else { return nil }
        let leftEye = views[0].eye, rightEye = views[1].eye
        let offset = leftEye.local(rightEye.position)
        guard leftEye.forward.dot(rightEye.forward) > 0.9995, leftEye.right.dot(rightEye.right) > 0.9995,
              offset.x > 0.02, abs(offset.y) < 0.01, abs(offset.z) < 0.01
        else { return nil }
        // Compute the union frustum enclosing all tiles.
        func box(_ tiles: [FrameLayout.Tile]) -> Frustum {
            var out = Frustum(left: .infinity, right: -.infinity, down: .infinity, up: -.infinity)
            for tile in tiles {
                out.left = min(out.left, tile.frustum.left); out.right = max(out.right, tile.frustum.right)
                out.down = min(out.down, tile.frustum.down); out.up = max(out.up, tile.frustum.up)
            }
            return out
        }
        window = box(views.flatMap(\.tiles))
        let across = window.right - window.left, tall = window.up - window.down
        guard across > 0.1, tall > 0.1 else { return nil }
        self.width = width
        guard across.isFinite, tall.isFinite, tall / across < 100 else { return nil }
        height = max(32, Int((Float(width) * tall / across / 4).rounded()) * 4)
        apart = offset.x
        pose = leftEye.shifted(right: offset.x / 2)
        covered = []
        let perTangent = Float(width) / across, perTangentDown = Float(height) / tall
        for view in views {
            // Compute pixel bounds that fall completely inside this eye's rendered frustum.
            let shown = box(view.tiles)
            let edges = [(shown.left - window.left) * perTangent, (shown.right - window.left) * perTangent,
                         (window.up - shown.up) * perTangentDown, (window.up - shown.down) * perTangentDown]
            guard edges.allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else { return nil }
            let firstColumn = max(0, Int(edges[0].rounded(.up))), endColumn = min(width, Int(edges[1].rounded(.down)))
            let firstRow = max(0, Int(edges[2].rounded(.up))), endRow = min(height, Int(edges[3].rounded(.down)))
            guard firstColumn < endColumn, firstRow < endRow else { return nil }
            covered.append((firstColumn..<endColumn, firstRow..<endRow))
        }
    }

    /// Packages resampled left and right grayscale images with this plan's geometry.
    public func pair(left: LumaPicture, right: LumaPicture) -> StereoPair {
        StereoPair(left: left, right: right, window: window, apart: apart, leftCovered: covered[0], rightCovered: covered[1],
                   pose: pose)
    }
}

/// Coarse `columns` x `rows` grid of inverse depths (`1 / meters`) over `window`.
/// Grid directions are tangents seen from the midpoint between the two eyes,
/// with each value sampled at its cell center.
public struct DepthField {
    public let columns: Int, rows: Int
    public var window: Frustum
    /// Interpupillary baseline in meters between the left and right eyes.
    public var apart: Float
    /// Inverse depth in `1 / meters`, stored row-major from the top-left cell.
    public var nearness: [Float]
    /// World-space cyclopean pose of the frame used to estimate this field.
    /// If `nil`, the field cannot be reprojected when the head moves (`moved(to:)`).
    public var pose: Pose?

    public init(columns: Int, rows: Int, window: Frustum, apart: Float, nearness: [Float]? = nil,
                everywhere: Float = 1 / Composition.distance, pose: Pose? = nil) {
        self.pose = pose
        self.columns = columns
        self.rows = rows
        self.window = window
        self.apart = apart
        self.nearness = nearness ?? [Float](repeating: everywhere, count: columns * rows)
    }

    /// Clamped inverse-depth range for warped quad vertices (`0.25 m` to `50 m`).
    public static let range: ClosedRange<Float> = 0.02...4

    /// Bilinearly samples inverse depth at tangent `(across, up)` from the cyclopean midpoint.
    public func nearness(across: Float, up: Float) -> Float {
        guard columns > 0, rows > 0 else { return 1 / Composition.distance }
        let x = (across - window.left) / (window.right - window.left) * Float(columns) - 0.5
        let y = (window.up - up) / (window.up - window.down) * Float(rows) - 0.5
        let cx = max(0, min(Float(columns - 1), x)), cy = max(0, min(Float(rows - 1), y))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(columns - 1, x0 + 1), y1 = min(rows - 1, y0 + 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let top = nearness[y0 * columns + x0] * (1 - fx) + nearness[y0 * columns + x1] * fx
        let bottom = nearness[y1 * columns + x0] * (1 - fx) + nearness[y1 * columns + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Samples inverse depth along tangent `(across, up)` in `eye`'s local frame.
    /// Because each eye is offset horizontally from the cyclopean midpoint by half
    /// the IPD, the corresponding midpoint tangent shifts by parallax proportional
    /// to the surface's inverse depth. At occlusion boundaries multiple depths can
    /// project to the same ray; starting the fixed-point search from the nearest
    /// candidate selects the foreground occluder.
    public func nearness(seenBy eye: Eye, across: Float, up: Float) -> Float {
        let aside = (eye == .left ? -0.5 : 0.5) * apart
        var found: Float = 0
        for guess: Float in [0, 1, 2, DepthField.range.upperBound] {
            found = max(found, nearness(across: across + aside * guess, up: up))
        }
        for _ in 0..<2 { found = nearness(across: across + aside * found, up: up) }
        return max(DepthField.range.lowerBound, min(DepthField.range.upperBound, found))
    }
}

extension DepthField {
    /// View tangents at the center of `(column, row)`.
    func direction(column: Int, row: Int) -> (across: Float, up: Float) {
        (window.left + (Float(column) + 0.5) / Float(columns) * (window.right - window.left),
         window.up - (Float(row) + 0.5) / Float(rows) * (window.up - window.down))
    }

    /// Performs bilinear lookups on a row-major grid through an unsafe pointer.
    /// This matches `nearness(across:up:)` while precomputing the tangent-to-cell
    /// scale factors and avoiding per-call array bounds checks in tight loops.
    struct Sampler {
        let values: UnsafePointer<Float>
        let columns: Int, rows: Int
        let left: Float, up: Float
        /// Converts tangent coordinates to grid cell coordinates along each axis.
        let perAcross: Float, perDown: Float

        init(_ values: UnsafePointer<Float>, columns: Int, rows: Int, window: Frustum) {
            self.values = values
            self.columns = columns
            self.rows = rows
            left = window.left
            up = window.up
            perAcross = Float(columns) / (window.right - window.left)
            perDown = Float(rows) / (window.up - window.down)
        }

        @inline(__always) func callAsFunction(_ across: Float, _ up: Float) -> Float {
            let cx = max(0, min(Float(columns - 1), (across - left) * perAcross - 0.5))
            let cy = max(0, min(Float(rows - 1), (self.up - up) * perDown - 0.5))
            let x0 = Int(cx), y0 = Int(cy), x1 = min(columns - 1, x0 + 1), y1 = min(rows - 1, y0 + 1)
            let fx = cx - Float(x0), fy = cy - Float(y0)
            let top = values[y0 * columns + x0] * (1 - fx) + values[y0 * columns + x1] * fx
            let bottom = values[y1 * columns + x0] * (1 - fx) + values[y1 * columns + x1] * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// Reprojects each cell from `target` back into this field's original `pose`,
    /// returning the source `(across, up)` tangents in the original view and the
    /// updated inverse depth seen from `target`. Assumes a static world scene so
    /// head rotation shifts directions across the grid and translation updates
    /// distances. Returns `nil` if `pose` is unset.
    func sources(seenFrom target: Pose) -> [(across: Float, up: Float, nearness: Float)]? {
        guard let from = pose, columns > 0, rows > 0 else { return nil }
        // Position of `target` in this field's local coordinate frame.
        let step = from.local(target.position)
        let moved = step.dot(step) > 0.002 * 0.002
        // Express `target`'s basis vectors in this field's coordinate frame so each cell's sight ray is a simple linear combination.
        let right = Vec3(target.right.dot(from.right), target.right.dot(from.up), target.right.dot(from.forward))
        let upward = Vec3(target.up.dot(from.right), target.up.dot(from.up), target.up.dot(from.forward))
        let forward = Vec3(target.forward.dot(from.right), target.forward.dot(from.up), target.forward.dot(from.forward))
        var out = [(across: Float, up: Float, nearness: Float)](repeating: (0, 0, -1), count: columns * rows)
        nearness.withUnsafeBufferPointer { values in
            let sample = Sampler(values.baseAddress!, columns: columns, rows: rows, window: window)
            // Intersect a sight ray with the previous depth map's heightfield using fixed-point iteration.
            // Each step projects the current point on the ray into the old view, samples the old depth there,
            // and updates the ray distance `ahead` until the two agree.
            @inline(__always) func settle(_ line: Vec3, from start: Float) -> (across: Float, up: Float, ahead: Float, miss: Float) {
                var ahead = start, across = line.x / line.z, up = line.y / line.z, miss = Float.infinity
                for round in 0..<4 {
                    let z = step.z + line.z * ahead
                    guard z > 0.05 else { return (across, up, ahead, .infinity) }
                    across = (step.x + line.x * ahead) / z
                    up = (step.y + line.y * ahead) / z
                    let was = 1 / max(0.005, sample(across, up))                       // meters ahead of the old pose
                    miss = abs(z - was) / was
                    // Stop early once the ray distance converges, which usually happens on the first step between consecutive frames.
                    if miss < 0.002 { break }
                    if round < 3 { ahead = max(0.05, (was - step.z) / line.z) }
                }
                return (across, up, ahead, miss)
            }
            for row in 0..<rows {
                for column in 0..<columns {
                    let (x, y) = direction(column: column, row: row)
                    // Sight ray from `target` expressed in this field's coordinate frame.
                    let line = Vec3(right.x * x + upward.x * y + forward.x, right.y * x + upward.y * y + forward.y,
                                    right.z * x + upward.z * y + forward.z)
                    // Leave rays pointing ~87 degrees or more from the original forward axis marked invalid.
                    guard line.z > 0.05 else {
                        out[row * columns + column] = (x, y, -1)
                        continue
                    }
                    // Seed from pure rotation, which is exact when the head has not translated.
                    let turned = 1 / max(0.005, sample(line.x / line.z, line.y / line.z))
                    let seed = max(0.05, (turned - step.z) / line.z)
                    var found = settle(line, from: seed)
                    if moved {
                        // Head translation can cause nearby geometry to occlude the rotation-seeded ray;
                        // probe several closer starting distances and keep the nearest consistent hit.
                        let consistent = found.miss <= 0.15
                        // Only run fixed-point iteration from a probe distance if the old depth map is
                        // significantly closer at that point than the rotation-seeded hit.
                        let behind = consistent ? step.z + line.z * found.ahead : Float.infinity
                        if !consistent { found.ahead = .infinity }
                        for start: Float in [0.3, 0.6, 1.2, 2.5, 5] {
                            if consistent {
                                guard start < found.ahead else { break }
                                let z = step.z + line.z * start
                                guard z > 0.05 else { continue }
                                let was = 1 / max(0.005, sample((step.x + line.x * start) / z, (step.y + line.y * start) / z))
                                guard was < 0.9 * behind else { continue }
                            }
                            let other = settle(line, from: start)
                            if other.miss <= 0.15, other.ahead < found.ahead { found = other }
                        }
                        if !found.ahead.isFinite { found = settle(line, from: seed) }
                    }
                    out[row * columns + column] = (found.across, found.up, 1 / found.ahead)
                }
            }
        }
        return out
    }

    /// Reprojects this depth field to a new `target` head pose so depth estimates
    /// computed on an earlier frame stay aligned with scene geometry on later frames.
    /// Returns `self` unchanged if `pose` is `nil`.
    public func moved(to target: Pose) -> DepthField {
        // Skip reprojection when the field is already expressed in `target` (for example, after `fitted(to:)`).
        if let pose {
            let step = pose.position - target.position
            if step.dot(step) < 1e-10, pose.forward.dot(target.forward) > 0.9999999, pose.right.dot(target.right) > 0.9999999 { return self }
        }
        guard let sources = sources(seenFrom: target) else { return self }
        var out = self
        out.pose = target
        for (index, source) in sources.enumerated() {
            out.nearness[index] = source.nearness < 0 ? DepthSmoother.far : source.nearness
        }
        return out
    }

    /// Linearly interpolates each cell's inverse depth toward `newer` by `weight`
    /// (clamped to `0...1`). Both fields should already be reprojected to the same pose.
    /// If the grid dimensions, frustum, or eye separation differ, returns `newer` directly.
    public func eased(toward newer: DepthField, by weight: Float) -> DepthField {
        guard columns == newer.columns, rows == newer.rows, nearness.count == newer.nearness.count,
              window.left == newer.window.left, window.right == newer.window.right,
              window.down == newer.window.down, window.up == newer.window.up, apart == newer.apart
        else { return newer }
        let weight = max(0, min(1, weight))
        var out = newer
        for index in out.nearness.indices { out.nearness[index] = nearness[index] + (newer.nearness[index] - nearness[index]) * weight }
        return out
    }

    /// Reprojects this depth field to `layout`'s cyclopean rendering pose.
    public func fitted(to layout: FrameLayout) -> DepthField {
        guard let middle = layout.middle else { return self }
        return moved(to: middle)
    }

    /// Evaluates `nearness(seenBy:)` across every cell for `eye`, returning a field
    /// with `apart == 0` whose `nearness(across:up:)` can be sampled directly in
    /// that eye's tangent space without repeating the parallax search per vertex.
    public func seen(by eye: Eye) -> DepthField {
        var out = DepthField(columns: columns, rows: rows, window: window, apart: 0, pose: pose)
        guard columns > 0, rows > 0 else { return out }
        let aside = (eye == .left ? -0.5 : 0.5) * apart
        let wide = (window.right - window.left) / Float(columns), tall = (window.up - window.down) / Float(rows)
        nearness.withUnsafeBufferPointer { values in
            let sample = Sampler(values.baseAddress!, columns: columns, rows: rows, window: window)
            for row in 0..<rows {
                let up = window.up - (Float(row) + 0.5) * tall
                for column in 0..<columns {
                    let across = window.left + (Float(column) + 0.5) * wide
                    // Run the same parallax search as `nearness(seenBy:across:up:)`, seeding from the nearest candidate before iterating.
                    var found = max(max(sample(across, up), sample(across + aside, up)),
                                    max(sample(across + aside * 2, up), sample(across + aside * DepthField.range.upperBound, up)))
                    found = sample(across + aside * found, up)
                    found = sample(across + aside * found, up)
                    out.nearness[row * columns + column] = max(DepthField.range.lowerBound, min(DepthField.range.upperBound, found))
                }
            }
        }
        return out
    }
}

/// Estimates horizontal stereo disparity across a coarse grid on a `StereoPair`.
public struct StereoMatcher {
    /// Inverse-depth estimate and confidence (`0...1`) for a single grid cell.
    public struct Reading: Equatable {
        public var nearness: Float
        public var trust: Float
        public init(nearness: Float, trust: Float) {
            self.nearness = nearness
            self.trust = trust
        }
    }

    public var columns = 28, rows = 24
    /// Patch half-width in pixels (`2 * reach + 1` square) and subsampling step within the patch.
    public var reach = 7, stride = 2
    /// Maximum inverse depth (`1 / meters`) searched during disparity matching.
    public var nearest: Float = 3
    /// Regularization constant (in 8-bit luma units) added to the mean absolute
    /// deviation denominator when computing zero-mean normalized SAD patch cost.
    /// Normalizing by patch contrast makes low-contrast texture match as cleanly
    /// as high-contrast edges (0 for identical patches, ~1 for uncorrelated ones),
    /// while `grain` prevents video compression noise on flat surfaces from amplifying into false matches.
    public var grain: Float = 2
    /// Minimum cost margin below the mean disparity cost required to accept a match
    /// (`least`, mapped to 0 confidence) and the margin that reaches full confidence (`full`, mapped to 1).
    public var distinct: (least: Float, full: Float) = (0.2, 0.5)

    /// Parameters for one pyramid scale in multi-scale matching (`measureLevels`).
    public struct Level: Equatable {
        /// Number of 2x downsampling steps applied before matching at this level.
        public var halvings: Int
        public var reach: Int
        public var grain: Float
        /// Confidence multiplier applied to readings that only matched at this coarser scale.
        public var worth: Float
        public init(halvings: Int, reach: Int, grain: Float, worth: Float) {
            self.halvings = halvings
            self.reach = reach
            self.grain = grain
            self.worth = worth
        }
    }

    /// Pyramid scales evaluated fine-to-coarse by `measureLevels`. Each 2x downsampling
    /// averages 4 pixels (reducing encoder block noise while doubling the angular span
    /// of a patch), so broad, low-contrast surfaces that fail to match at full resolution
    /// can still match at coarser scales. Tuned for ~768 px input width (`fitted(toWidth:)`).
    public var levels: [Level] = [
        Level(halvings: 0, reach: 14, grain: 2, worth: 1),
        Level(halvings: 1, reach: 10, grain: 1, worth: 0.8),
        Level(halvings: 2, reach: 8, grain: 0.5, worth: 0.6),
    ]

    /// When `true`, `measured` only matches the subset of grid cells selected by
    /// `DepthSampling.cells` instead of the full grid. It samples a sparser base
    /// lattice across the view and fills in every cell inside the regions of
    /// interest, such as around a hand or straight ahead. `DepthSmoother` then
    /// inpaints the unmeasured cells from nearby confident readings.
    public var sampled = false

    public init() {}

    /// Returns a matcher whose pyramid levels are adjusted for input `width`,
    /// dropping fine levels when the input is already narrower than 640 px.
    public static func fitted(toWidth width: Int) -> StereoMatcher {
        var matcher = StereoMatcher()
        let skipped = width >= 640 ? 0 : width >= 320 ? 1 : 2
        matcher.levels = matcher.levels.dropFirst(skipped).enumerated().map { index, level in
            Level(halvings: index, reach: level.reach, grain: level.grain, worth: index == 0 ? 1 : level.worth)
        }
        return matcher
    }

    /// Runs multi-scale matching on `pair` and packages the resulting `StereoMeasure`.
    public func measured(_ pair: StereoPair, interests: [DepthSampling.Interest] = []) -> StereoMeasure {
        StereoMeasure(readings: measureLevels(pair, cells: cells(window: pair.window, interests: interests)),
                      columns: columns, rows: rows, window: pair.window, apart: pair.apart, pose: pair.pose)
    }

    /// Returns the row-major cell indices to match for `window` when `sampled` is enabled, or `nil` to match every cell.
    public func cells(window: Frustum, interests: [DepthSampling.Interest]) -> [Int]? {
        sampled ? DepthSampling.cells(columns: columns, rows: rows, window: window, interests: interests) : nil
    }

    /// Evaluates each pyramid level in `levels` and selects the finest confident reading per cell.
    /// When `cells` is given, only those row-major cell indices are matched.
    public func measureLevels(_ pair: StereoPair, cells: [Int]? = nil) -> [Reading] {
        var sized = pair, halvings = 0, found: [[Reading]] = []
        for level in levels {
            while halvings < level.halvings {
                sized = sized.halved()
                halvings += 1
            }
            var one = self
            one.reach = level.reach
            one.grain = level.grain
            found.append(one.measure(sized, cells: cells))
        }
        return StereoMatcher.finest(found, worth: levels.map(\.worth))
    }

    /// Selects the first non-zero-confidence reading per cell from `levels`, weighted by `worth`.
    public static func finest(_ levels: [[Reading]], worth: [Float]) -> [Reading] {
        guard var out = levels.first else { return [] }
        for index in out.indices {
            out[index].trust *= worth.first ?? 1
            for (level, readings) in levels.enumerated().dropFirst() where out[index].trust <= 0 && readings[index].trust > 0 {
                out[index] = Reading(nearness: readings[index].nearness, trust: readings[index].trust * worth[level])
            }
        }
        return out
    }

    /// Matches `pair` at a single scale. When `cells` is given, only those row-major
    /// cell indices are matched and the rest are returned with zero confidence.
    public func measure(_ pair: StereoPair, cells: [Int]? = nil) -> [Reading] {
        var wanted: [Bool]?
        if let cells {
            var chosen = [Bool](repeating: false, count: columns * rows)
            for cell in cells where chosen.indices.contains(cell) { chosen[cell] = true }
            wanted = chosen
        }
        let width = pair.left.width, height = pair.left.height
        let none = Reading(nearness: 0, trust: 0)
        guard width == pair.right.width, height == pair.right.height, width > 4 * reach, height > 4 * reach,
              pair.apart > 0.01
        else { return [Reading](repeating: none, count: columns * rows) }
        let most = max(2, min(width / 3, Int((nearest * pair.pixelsPerNearness).rounded(.up))))
        var out = [Reading](repeating: none, count: columns * rows)
        // Precompute sample offsets within the patch and total sample count.
        let offsets = Swift.stride(from: -reach, through: reach, by: stride).map { $0 }
        let times = Int32(offsets.count * offsets.count), compared = Float(times)
        var costs = [Float](repeating: .infinity, count: most + 1)

        pair.left.pixels.withUnsafeBufferPointer { left in
            pair.right.pixels.withUnsafeBufferPointer { right in
                for row in 0..<rows {
                    let cy = Int((Float(row) + 0.5) / Float(rows) * Float(height))
                    guard cy - reach >= max(pair.leftCovered.y.lowerBound, pair.rightCovered.y.lowerBound),
                          cy + reach < min(pair.leftCovered.y.upperBound, pair.rightCovered.y.upperBound)
                    else { continue }
                    for column in 0..<columns {
                        if let wanted, !wanted[row * columns + column] { continue }
                        let cx = Int((Float(column) + 0.5) / Float(columns) * Float(width))
                        // Split integer disparity `shift` symmetrically around the cyclopean cell center (`+shift/2` in left, `-shift/2` in right).
                        var best = -1
                        for shift in 0...most {
                            costs[shift] = .infinity
                            let lx = cx + (shift + 1) / 2, rx = cx - shift / 2
                            guard lx - reach >= pair.leftCovered.x.lowerBound, lx + reach < pair.leftCovered.x.upperBound,
                                  rx - reach >= pair.rightCovered.x.lowerBound, rx + reach < pair.rightCovered.x.upperBound
                            else { continue }
                            // Subtract each patch's mean luma so per-eye exposure or tint differences don't penalize matches.
                            // Multiply each sample by `times` and subtract `sum` to keep the inner loop in exact integer math.
                            var sumLeft: Int32 = 0, sumRight: Int32 = 0
                            for dy in offsets {
                                let l = (cy + dy) * width + lx, r = (cy + dy) * width + rx
                                for dx in offsets {
                                    sumLeft &+= Int32(left[l + dx])
                                    sumRight &+= Int32(right[r + dx])
                                }
                            }
                            var unlike: Int32 = 0, variedLeft: Int32 = 0, variedRight: Int32 = 0
                            for dy in offsets {
                                let l = (cy + dy) * width + lx, r = (cy + dy) * width + rx
                                for dx in offsets {
                                    let a = Int32(left[l + dx]) &* times &- sumLeft, b = Int32(right[r + dx]) &* times &- sumRight
                                    unlike &+= abs(a &- b)
                                    variedLeft &+= abs(a)
                                    variedRight &+= abs(b)
                                }
                            }
                            let scale = compared * compared
                            costs[shift] = (Float(unlike) / scale) / (Float(variedLeft &+ variedRight) / (2 * scale) + grain)
                            if best < 0 || costs[shift] < costs[best] { best = shift }
                        }
                        guard best >= 0 else { continue }
                        // Accept the match only if its cost beats the mean across all shifts and has no close non-adjacent competitor.
                        var total: Float = 0, tried = 0, rival = Float.infinity
                        for shift in 0...most where costs[shift].isFinite {
                            total += costs[shift]
                            tried += 1
                            if abs(shift - best) > 2 { rival = min(rival, costs[shift]) }
                        }
                        guard tried >= 4 else { continue }
                        let typical = total / Float(tried)
                        let margin = typical - costs[best]
                        guard margin > distinct.least, rival - costs[best] > 0.35 * margin else { continue }
                        // Refine the integer disparity to sub-pixel precision by fitting a parabola through the two neighboring costs.
                        var shift = Float(best)
                        if best > 0, best < most, costs[best - 1].isFinite, costs[best + 1].isFinite {
                            let before = costs[best - 1], after = costs[best + 1], bend = before + after - 2 * costs[best]
                            if bend > 1e-6 { shift += max(-0.5, min(0.5, (before - after) / (2 * bend))) }
                        }
                        out[row * columns + column] = Reading(
                            nearness: max(0, shift) / pair.pixelsPerNearness,
                            trust: min(1, (margin - distinct.least) / (distinct.full - distinct.least)))
                    }
                }
            }
        }
        return out
    }
}

/// Chooses the subset of depth grid cells to stereo-match on a given frame.
public enum DepthSampling {
    /// Defines a circular region in cyclopean tangent space (`across`, `up`, and `radius`)
    /// where every depth grid cell is matched.
    public struct Interest: Equatable {
        public var across: Float, up: Float, radius: Float
        public init(across: Float, up: Float, radius: Float) {
            self.across = across
            self.up = up
            self.radius = radius
        }

        /// Creates a region covering `reach` meters around world-space `point` as seen from `pose`,
        /// or returns `nil` if `point` is behind or nearly beside the head.
        public init?(around point: Vec3, reach: Float, seenFrom pose: Pose) {
            let seen = pose.local(point)
            guard seen.z > 0.1 else { return nil }
            self.init(across: seen.x / seen.z, up: seen.y / seen.z, radius: max(0.1, min(0.45, reach / seen.z)))
        }
    }

    /// Each hand or controller is sampled at full density within this world-space radius (in meters),
    /// which covers the hand, held objects, and motion since the frame was rendered.
    public static let handReach: Float = 0.17
    /// The region straight ahead is sampled at full density within this tangent radius.
    public static let sharpRadius: Float = 0.3
    /// Beyond `thinnedAbove` vertically or `thinnedBeside` horizontally, the base lattice skips half of its remaining cells.
    public static let thinnedAbove: Float = 0.45, thinnedBeside: Float = 0.85

    /// Builds the regions of interest for `layout` from the current `hands` positions.
    /// Each visible hand or controller gets a region scaled by its distance, plus a
    /// fixed region straight ahead. We keep the central region fixed rather than
    /// tracking the host's gaze-driven foveal inset because moving the dense sampling
    /// window with your eyes swaps cells between measured and inpainted depth on each
    /// glance, causing noticeable depth shifts (the video stream itself still uses
    /// dynamic foveation).
    public static func interests(layout: FrameLayout, hands: [Vec3]) -> [Interest] {
        guard let middle = layout.middle else { return [] }
        var out = hands.compactMap { Interest(around: $0, reach: handReach, seenFrom: middle) }
        out.append(Interest(across: 0, up: 0, radius: sharpRadius))
        return out
    }

    /// Returns the row-major cell indices to stereo-match, capped at `most` cells.
    /// Sampling starts with a base lattice of every even row and column, drops half of
    /// those cells in the upper (`thinnedAbove`) and far peripheral (`thinnedBeside`)
    /// bands, and then appends every remaining cell inside `interests`.
    public static func cells(columns: Int, rows: Int, window: Frustum, interests: [Interest], most: Int = 2048) -> [Int] {
        guard columns > 0, rows > 0 else { return [] }
        var chosen = [Bool](repeating: false, count: columns * rows), out: [Int] = []
        func direction(_ column: Int, _ row: Int) -> (across: Float, up: Float) {
            (window.left + (Float(column) + 0.5) / Float(columns) * (window.right - window.left),
             window.up - (Float(row) + 0.5) / Float(rows) * (window.up - window.down))
        }
        for row in stride(from: 0, to: rows, by: 2) {
            for column in stride(from: 0, to: columns, by: 2) {
                let (across, up) = direction(column, row)
                if up > thinnedAbove || abs(across) > thinnedBeside, (row / 2 + column / 2) % 2 == 1 { continue }
                chosen[row * columns + column] = true
                out.append(row * columns + column)
            }
        }
        let wide = (window.right - window.left) / Float(columns), tall = (window.up - window.down) / Float(rows)
        for interest in interests {
            // Only check grid cells within the interest circle's bounding box.
            let firstRow = max(0, Int(((window.up - interest.up - interest.radius) / tall).rounded(.down)))
            let lastRow = min(rows - 1, Int(((window.up - interest.up + interest.radius) / tall).rounded(.up)))
            let firstColumn = max(0, Int(((interest.across - interest.radius - window.left) / wide).rounded(.down)))
            let lastColumn = min(columns - 1, Int(((interest.across + interest.radius - window.left) / wide).rounded(.up)))
            guard firstRow <= lastRow, firstColumn <= lastColumn else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn where !chosen[row * columns + column] {
                    let (across, up) = direction(column, row)
                    let dx = across - interest.across, dy = up - interest.up
                    guard dx * dx + dy * dy <= interest.radius * interest.radius, out.count < most else { continue }
                    chosen[row * columns + column] = true
                    out.append(row * columns + column)
                }
            }
        }
        return Array(out.prefix(most))
    }
}

/// Disparity readings and camera geometry from a single frame.
public struct StereoMeasure {
    public var readings: [StereoMatcher.Reading]
    public var columns: Int, rows: Int
    public var window: Frustum
    /// Interpupillary baseline in meters between the left and right eyes.
    public var apart: Float
    /// Cyclopean rendering pose of the frame, or `nil` if unknown.
    public var pose: Pose?

    public init(readings: [StereoMatcher.Reading], columns: Int, rows: Int, window: Frustum, apart: Float, pose: Pose? = nil) {
        self.readings = readings
        self.columns = columns
        self.rows = rows
        self.window = window
        self.apart = apart
        self.pose = pose
    }
}

/// Temporally filters per-frame `StereoMeasure` grids into a stable `DepthField`.
///
/// On each update, any previous depth field and confidence map are first
/// reprojected to the new frame's head pose so depth tracks world geometry
/// during head motion. Isolated outlier readings that disagree with spatial
/// neighbors and prior frames are rejected, while consistent readings blend
/// exponentially into the field. Cells without recent measurements decay in
/// confidence and are smoothly inpainted by fitting a local plane to nearby
/// confident cells (preserving slanted surfaces like floors and walls), falling
/// back toward a distant default (`far`) in unmeasured exterior regions like
/// open sky. Finally, a 3x3 tent filter smooths cell boundaries before mesh warping.
public struct DepthSmoother {
    /// Default inverse depth (`~33 m`) used when no nearby confident measurements exist.
    public static let far: Float = 0.03

    /// Exponential blending weight per frame for a full-confidence reading.
    public var rate: Float = 0.5
    /// Per-frame confidence decay factor when a cell has no valid reading.
    public var fading: Float = 0.85
    /// Per-frame blending weight pulling unconfident cells toward locally inpainted depth.
    public var filling: Float = 0.4
    /// Search radius (in cells), Gaussian falloff sigma (in cells), and total
    /// neighbor weight threshold for full local plane inpainting.
    public var fillReach = 4
    public var fillSpread: Float = 2
    public var fillEnough: Float = 1.5

    private var held: DepthField?
    private var trust: [Float] = []
    /// Raw readings from the previous frame, used to confirm isolated features that persist across two frames.
    private var pending: [StereoMatcher.Reading] = []

    public init() {}

    /// Fraction of grid cells (`0...1`) with recent measurement confidence above `0.5`.
    public var measured: Float {
        trust.isEmpty ? 0 : Float(trust.filter { $0 > 0.5 }.count) / Float(trust.count)
    }

    public mutating func update(_ readings: [StereoMatcher.Reading], columns: Int, rows: Int, window: Frustum,
                                apart: Float, pose: Pose? = nil) -> DepthField {
        update(StereoMeasure(readings: readings, columns: columns, rows: rows, window: window, apart: apart, pose: pose))
    }

    public mutating func update(_ measure: StereoMeasure) -> DepthField {
        let columns = measure.columns, rows = measure.rows
        var field: DepthField
        if let before = held, before.columns == columns, before.rows == rows, trust.count == columns * rows {
            field = before
            // Reproject both the previous depth estimates and their confidence values to the current head pose.
            if let pose = measure.pose, let sources = before.sources(seenFrom: pose) {
                let old = trust, window = before.window
                old.withUnsafeBufferPointer { values in
                    let believed = DepthField.Sampler(values.baseAddress!, columns: columns, rows: rows, window: window)
                    for (index, source) in sources.enumerated() {
                        if source.nearness < 0 {
                            field.nearness[index] = DepthSmoother.far
                            trust[index] = 0
                        } else {
                            field.nearness[index] = source.nearness
                            // Reset confidence for rays that rotated outside the previous frame's view frustum.
                            let outside = source.across < window.left || source.across > window.right
                                || source.up < window.down || source.up > window.up
                            trust[index] = outside ? 0 : believed(source.across, source.up)
                        }
                    }
                }
            }
        } else {
            field = DepthField(columns: columns, rows: rows, window: measure.window, apart: measure.apart,
                               everywhere: DepthSmoother.far)
            trust = [Float](repeating: 0, count: columns * rows)
            pending = []
        }
        field.window = measure.window
        field.apart = measure.apart
        field.pose = measure.pose
        let readings = measure.readings
        guard readings.count == columns * rows, columns > 0, rows > 0 else {
            held = field
            return field
        }
        @inline(__always) func alike(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= max(0.12, 0.35 * max(a, b)) }
        // Neighborhood radii are specified for a 28-column grid and scale up on finer grids.
        let finer = max(1, columns / 28)

        // Keep a reading if at least two neighbors within `checkReach` cells agree with it, preserving
        // narrow objects (1-2 cells wide) while rejecting single-cell spikes. When fewer than three
        // neighbors have readings, also accept readings that match the smoothed cell or previous frame.
        var kept = readings
        let checkReach = 2 * finer
        readings.withUnsafeBufferPointer { all in
            for index in 0..<all.count where all[index].trust > 0 {
                let row = index / columns, column = index % columns, mine = all[index].nearness
                var others = 0, agreeing = 0
                rows: for r in max(0, row - checkReach)...min(rows - 1, row + checkReach) {
                    for c in max(0, column - checkReach)...min(columns - 1, column + checkReach) {
                        let other = all[r * columns + c]
                        guard other.trust > 0, r != row || c != column else { continue }
                        others += 1
                        if alike(mine, other.nearness) {
                            agreeing += 1
                            if agreeing >= 2 { break rows }
                        }
                    }
                }
                if agreeing >= 2 { continue }
                let repeats = (trust[index] > 0.3 && alike(mine, field.nearness[index]))
                    || (pending.count == all.count && pending[index].trust > 0 && alike(mine, pending[index].nearness))
                if others >= 3 || !repeats { kept[index].trust = 0 }
            }
        }
        pending = readings
        for index in kept.indices {
            if kept[index].trust > 0 {
                // Initialize unconfident cells directly to the first valid reading instead of ramping from `far`.
                let step = trust[index] < 0.05 ? 1 : rate * kept[index].trust
                field.nearness[index] += (kept[index].nearness - field.nearness[index]) * step
                trust[index] += (1 - trust[index]) * rate * kept[index].trust
            } else {
                trust[index] *= fading
            }
        }

        // Inpaint cells that lacked a reading this frame using nearby confident cells. Because planar
        // surfaces (floors, walls, ceilings) have linear inverse depth in tangent space, we fit a
        // weighted least-squares plane `n = a + b*x + c*y` to confident neighbors so partially
        // textured floors extrapolate at the right slope. Only neighbors on the same surface as the
        // highest-weighted one are fitted, so a hand in front of the floor is not averaged with it.
        // When all confident neighbors lie to one side of the cell (for example, sky next to a
        // foreground object), blend back toward `far` instead of extrapolating the foreground plane outward.
        //
        // Because inpainting visits up to a 17 x 17 neighborhood for thousands of cells per frame,
        // we precompute the Gaussian weights into a flat table and avoid allocations in the loop.
        // We keep this loop scalar rather than using `SIMD4` or `SIMD8` because most neighbors have
        // zero weight; skipping them with a branch is faster in benchmarks than evaluating empty
        // vector lanes.
        let fillReach = self.fillReach * finer, span = 2 * fillReach + 1
        var gauss = [Float](repeating: 0, count: span * span)
        for dy in -fillReach...fillReach {
            for dx in -fillReach...fillReach {
                // Normalize offsets to 28-column grid units so the Gaussian falloff stays the same physical width on finer grids.
                let x = Float(dx) / Float(finer), y = Float(dy) / Float(finer)
                gauss[(dy + fillReach) * span + dx + fillReach] = exp(-(x * x + y * y) / (2 * fillSpread * fillSpread))
            }
        }
        // Zero the center entry so a cell never contributes to its own neighborhood fit.
        gauss[fillReach * span + fillReach] = 0
        let before = field.nearness, perCell = 1 / Float(finer)
        // Only cells on the sampled lattice or inside regions of interest build up confidence,
        // so we pack cells with `trust > 0.3` into contiguous row-ordered arrays before inpainting.
        // `firstFrom[r * (columns + 1) + c]` stores the starting index in the packed arrays for
        // entries in row `r` at or after column `c`.
        var packedColumn: [Int32] = [], packedTrust: [Float] = [], packedValue: [Float] = []
        var firstFrom = [Int](repeating: 0, count: rows * (columns + 1))
        for row in 0..<rows {
            for column in 0..<columns {
                firstFrom[row * (columns + 1) + column] = packedColumn.count
                if trust[row * columns + column] > 0.3 {
                    packedColumn.append(Int32(column))
                    packedTrust.append(trust[row * columns + column])
                    packedValue.append(before[row * columns + column])
                }
            }
            firstFrom[row * (columns + 1) + columns] = packedColumn.count
        }
        gauss.withUnsafeBufferPointer { gauss in
        packedColumn.withUnsafeBufferPointer { packedColumn in
            packedTrust.withUnsafeBufferPointer { packedTrust in
                packedValue.withUnsafeBufferPointer { packedValue in
                    for index in 0..<before.count where kept[index].trust == 0 {
                        let row = index / columns, column = index % columns
                        let firstRow = max(0, row - fillReach), lastRow = min(rows - 1, row + fillReach)
                        let firstColumn = max(0, column - fillReach), lastColumn = min(columns - 1, column + fillReach)
                        // First, find the highest-weighted confident neighbor to set the reference depth `surface`
                        // for this cell, breaking ties by row-major order.
                        var strongest: Float = 0, surface: Float = 0
                        for r in firstRow...lastRow {
                            let table = (r - row + fillReach) * span + fillReach - column
                            for entry in firstFrom[r * (columns + 1) + firstColumn]..<firstFrom[r * (columns + 1) + lastColumn + 1] {
                                let share = packedTrust[entry] * gauss[table + Int(packedColumn[entry])]
                                if share > strongest {
                                    strongest = share
                                    surface = packedValue[entry]
                                }
                            }
                        }
                        var target = DepthSmoother.far
                        if strongest > 0 {
                            // Next, accumulate the weighted least-squares plane fit over neighbors that match `surface`.
                            var w: Float = 0, wx: Float = 0, wy: Float = 0, wxx: Float = 0, wxy: Float = 0, wyy: Float = 0
                            var wn: Float = 0, wxn: Float = 0, wyn: Float = 0, least = Float.infinity, most = -Float.infinity, count = 0
                            let tolerance = max(0.12, 0.35 * surface)
                            for r in firstRow...lastRow {
                                let table = (r - row + fillReach) * span + fillReach - column
                                let y = Float(r - row) * perCell
                                for entry in firstFrom[r * (columns + 1) + firstColumn]..<firstFrom[r * (columns + 1) + lastColumn + 1] {
                                    let c = Int(packedColumn[entry]), n = packedValue[entry]
                                    let share = packedTrust[entry] * gauss[table + c]
                                    // Inline `alike(n, surface)` using the precomputed `tolerance` so most neighbors only need one comparison.
                                    guard share > 0, abs(n - surface) <= tolerance || abs(n - surface) <= 0.35 * n else { continue }
                                    let x = Float(c - column) * perCell
                                    w += share; wx += share * x; wy += share * y
                                    wxx += share * x * x; wxy += share * x * y; wyy += share * y * y
                                    wn += share * n; wxn += share * x * n; wyn += share * y * n
                                    least = min(least, n); most = max(most, n)
                                    count += 1
                                }
                            }
                            if count >= 3, w > 0.05 {
                                // Evaluate the weighted plane fit `n = a + b*x + c*y` at the cell center `(x = 0, y = 0)`, which equals `a`.
                                let det = w * (wxx * wyy - wxy * wxy) - wx * (wx * wyy - wxy * wy) + wy * (wx * wxy - wxx * wy)
                                var fitted = wn / w
                                if abs(det) > 1e-4 * w * w * w {
                                    fitted = (wn * (wxx * wyy - wxy * wxy) - wx * (wxn * wyy - wxy * wyn) + wy * (wxn * wxy - wxx * wyn)) / det
                                }
                                // Clamp plane extrapolation to stay near the observed neighbor range.
                                fitted = max(least * 0.8, min(most * 1.2, fitted))
                                // Measure how one-sided the neighbor distribution is via the weighted centroid offset (in cells).
                                let aside = ((wx / w) * (wx / w) + (wy / w) * (wy / w)).squareRoot()
                                let among = max(0, min(1, 2 - aside)) * min(1, w / fillEnough)
                                target = fitted * among + DepthSmoother.far * (1 - among)
                            }
                        }
                        field.nearness[index] += (target - before[index]) * (1 - trust[index]) * filling
                    }
                }
            }
        }
        }
        held = field
        // Apply a 3x3 tent blur (center weight 4, axial neighbors 2, diagonal neighbors 1), skipping
        // neighbors across a depth discontinuity so foreground edges stay sharp.
        var smooth = field
        field.nearness.withUnsafeBufferPointer { values in
            for row in 0..<rows {
                for column in 0..<columns {
                    let mine = values[row * columns + column]
                    var sum: Float = 0, weight: Float = 0
                    for r in max(0, row - 1)...min(rows - 1, row + 1) {
                        for c in max(0, column - 1)...min(columns - 1, column + 1) {
                            let other = values[r * columns + c]
                            guard alike(other, mine) else { continue }
                            let share: Float = (r == row ? 2 : 1) * (c == column ? 2 : 1)
                            sum += other * share
                            weight += share
                        }
                    }
                    smooth.nearness[row * columns + column] = sum / weight
                }
            }
        }
        return smooth
    }
}
