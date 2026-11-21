// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A 2D point on the horizontal floor plane in meters (`+x` right, `+z` back,
/// matching `Vec3` without height).
public struct Point2: Equatable, Codable {
    public var x, z: Float
    public init(_ x: Float, _ z: Float) { self.x = x; self.z = z }

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.z + b.z) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.z - b.z) }
    public static func * (a: Point2, s: Float) -> Point2 { Point2(a.x * s, a.z * s) }
    public func dot(_ b: Point2) -> Float { x * b.x + z * b.z }
    /// 2D cross product (`x * b.z - z * b.x`), positive when `b` is counterclockwise from `self` on the `(x, z)` plane.
    public func cross(_ b: Point2) -> Float { x * b.z - z * b.x }
    public var length: Float { dot(self).squareRoot() }
}

/// 2D polygon geometry for room boundaries.
///
/// Polygons are represented as ordered vertices without repeating the first vertex at
/// the end. Strokes are open polylines of sampled points.
public enum FloorShape {
    /// Signed area of `polygon`, positive when vertices run counterclockwise on the `(x, z)` plane.
    public static func signedArea(_ polygon: [Point2]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var twice: Float = 0
        for (index, corner) in polygon.enumerated() { twice += corner.cross(polygon[(index + 1) % polygon.count]) }
        return twice / 2
    }

    /// Returns true if `point` lies inside `polygon` using the even-odd rule (supports self-intersecting polygons).
    public static func contains(_ polygon: [Point2], _ point: Point2) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        for (index, a) in polygon.enumerated() {
            let b = polygon[(index + 1) % polygon.count]
            if (a.z > point.z) != (b.z > point.z), point.x < a.x + (point.z - a.z) / (b.z - a.z) * (b.x - a.x) {
                inside.toggle()
            }
        }
        return inside
    }

    /// Returns the intersection of segments `a`–`b` and `c`–`d` strictly inside both segments,
    /// expressed as parametric fractions in `(0, 1)`. Touching endpoints and collinear segments return `nil`.
    public static func crossing(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> (along: Float, alongOther: Float)? {
        let r = b - a, s = d - c
        let denominator = r.cross(s)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = (c - a).cross(s) / denominator, u = (c - a).cross(r) / denominator
        let edge: Float = 1e-5
        guard t > edge, t < 1 - edge, u > edge, u < 1 - edge else { return nil }
        return (t, u)
    }

    /// Returns the distance from `point` to the closest point on segment `a`–`b` and its parametric fraction in `[0, 1]`.
    public static func nearest(on a: Point2, _ b: Point2, to point: Point2) -> (distance: Float, along: Float) {
        let span = b - a, size = span.dot(span)
        let along = size > 0 ? max(0, min(1, (point - a).dot(span) / size)) : 0
        return ((a + span * along - point).length, along)
    }

    /// Returns the index of the vertex in `points` closest to `point` within `reach` meters.
    public static func nearestCorner(of points: [Point2], to point: Point2, within reach: Float) -> Int? {
        let near = points.enumerated().map { ($0.offset, ($0.element - point).length) }.filter { $0.1 <= reach }
        return near.min { $0.1 < $1.1 }?.0
    }

    /// Returns the closest edge to `point` within `reach` meters, where edge `index` connects
    /// vertex `index` to `index + 1`. Open polylines do not connect the last point back to the first.
    public static func nearestEdge(of points: [Point2], closed: Bool, to point: Point2, within reach: Float)
        -> (index: Int, along: Float)? {
        var best: (index: Int, along: Float, distance: Float)?
        let edges = closed ? points.count : points.count - 1
        guard points.count >= 2 else { return nil }
        for index in 0..<edges {
            let found = nearest(on: points[index], points[(index + 1) % points.count], to: point)
            if found.distance <= reach, found.distance < (best?.distance ?? .infinity) {
                best = (index, found.along, found.distance)
            }
        }
        return best.map { ($0.index, $0.along) }
    }

    /// Simplifies a polyline or polygon with Douglas-Peucker, removing vertices within `tolerance`
    /// meters of the chord between kept neighbors. Closed polygons retain at least three vertices.
    public static func simplified(_ points: [Point2], tolerance: Float, closed: Bool) -> [Point2] {
        guard points.count > (closed ? 3 : 2) else { return points }
        func reduce(_ run: ArraySlice<Point2>) -> [Point2] {
            guard run.count > 2, let first = run.first, let last = run.last else { return Array(run) }
            var farthest = (index: run.startIndex, distance: Float(0))
            for index in run.indices.dropFirst().dropLast() {
                let distance = nearest(on: first, last, to: run[index]).distance
                if distance > farthest.distance { farthest = (index, distance) }
            }
            guard farthest.distance > tolerance else { return [first, last] }
            return reduce(run[run.startIndex...farthest.index]).dropLast() + reduce(run[farthest.index...])
        }
        guard closed else { return reduce(points[...]) }
        // Split a closed outline at the corner farthest from the first, so neither half is degenerate.
        var far = (index: 0, distance: Float(0))
        for (index, point) in points.enumerated() where (point - points[0]).length > far.distance {
            far = (index, (point - points[0]).length)
        }
        guard far.index > 0 else { return points }
        let out = reduce(points[0...far.index]).dropLast() + reduce(points[far.index...] + [points[0]]).dropLast()
        return out.count >= 3 ? Array(out) : points
    }

    /// Removes consecutive duplicate points (and a trailing duplicate of the first vertex when `closed` is true).
    static func withoutRepeats(_ points: [Point2], closed: Bool) -> [Point2] {
        var out: [Point2] = []
        for point in points where out.last.map({ ($0 - point).length > 1e-4 }) ?? true { out.append(point) }
        if closed, out.count > 1, let first = out.first, let last = out.last, (first - last).length <= 1e-4 { out.removeLast() }
        return out
    }

    /// Resolves self-intersections in `polygon` by splitting at each edge crossing and keeping
    /// the loop with the larger area.
    public static func untangled(_ polygon: [Point2]) -> [Point2] {
        var corners = withoutRepeats(polygon, closed: true)
        // Each cut removes at least one crossing and adds none.
        for _ in 0..<(polygon.count * 2 + 8) {
            let count = corners.count
            guard count > 3 else { break }
            var cut: (first: Int, second: Int, at: Point2)?
            search: for first in 0..<(count - 2) {
                for second in (first + 2)..<count where !(first == 0 && second == count - 1) {
                    let a = corners[first], b = corners[first + 1]
                    if let found = crossing(a, b, corners[second], corners[(second + 1) % count]) {
                        cut = (first, second, a + (b - a) * found.along)
                        break search
                    }
                }
            }
            guard let cut else { break }
            let inner = [cut.at] + corners[(cut.first + 1)...cut.second]
            let outer = corners[...cut.first] + [cut.at] + corners[(cut.second + 1)...]
            corners = abs(signedArea(inner)) > abs(signedArea(Array(outer))) ? inner : Array(outer)
        }
        return corners
    }

    /// Simplifies `polygon`, removes self-intersections, and orients vertices counterclockwise on the `(x, z)` plane.
    public static func tidied(_ polygon: [Point2], tolerance: Float = 0.02) -> [Point2] {
        let simple = untangled(simplified(withoutRepeats(polygon, closed: true), tolerance: tolerance, closed: true))
        return signedArea(simple) < 0 ? simple.reversed() : simple
    }

    /// Extracts a closed loop from a drawn `stroke` when the stroke crosses itself or passes
    /// within `joinWithin` meters of an earlier segment. Returns `nil` if the stroke does not
    /// form a loop or encloses less than `smallestArea` square meters.
    public static func loop(in stroke: [Point2], joinWithin: Float, smallestArea: Float = 0.2) -> [Point2]? {
        let points = withoutRepeats(stroke, closed: false)
        guard points.count >= 3 else { return nil }
        func acceptable(_ loop: [Point2]) -> [Point2]? {
            abs(signedArea(loop)) >= smallestArea ? loop : nil
        }
        // Check for a direct self-intersection first, pairing the earliest crossed segment with the latest segment that crosses it.
        for first in 0..<(points.count - 2) {
            for second in stride(from: points.count - 2, to: first + 1, by: -1) {
                guard let found = crossing(points[first], points[first + 1], points[second], points[second + 1]) else { continue }
                let at = points[first] + (points[first + 1] - points[first]) * found.along
                if let loop = acceptable([at] + points[(first + 1)...second]) { return loop }
            }
        }
        // Otherwise check whether a later point passes within `joinWithin` of an earlier segment
        // after traveling far enough along the stroke to have looped back rather than staying adjacent.
        var traveled: [Float] = [0]
        for index in 1..<points.count { traveled.append(traveled[index - 1] + (points[index] - points[index - 1]).length) }
        let farEnough = max(1, joinWithin * 4)
        for first in 0..<(points.count - 2) {
            for second in stride(from: points.count - 1, to: first + 1, by: -1) {
                guard traveled[second] - traveled[first + 1] >= farEnough else { break }
                let found = nearest(on: points[first], points[first + 1], to: points[second])
                guard found.distance <= joinWithin else { continue }
                let at = points[first] + (points[first + 1] - points[first]) * found.along
                if let loop = acceptable([at] + points[(first + 1)...second]) { return loop }
                break
            }
        }
        return nil
    }

    private struct Crossing {
        var strokeEdge: Int, along: Float
        var polygonEdge: Int, alongPolygon: Float
        var at: Point2
    }

    private static func crossings(of stroke: [Point2], with polygon: [Point2]) -> [Crossing] {
        var found: [Crossing] = []
        guard stroke.count >= 2 else { return [] }
        for strokeEdge in 0..<(stroke.count - 1) {
            let a = stroke[strokeEdge], b = stroke[strokeEdge + 1]
            for polygonEdge in polygon.indices {
                guard let hit = crossing(a, b, polygon[polygonEdge], polygon[(polygonEdge + 1) % polygon.count]) else { continue }
                found.append(Crossing(strokeEdge: strokeEdge, along: hit.along, polygonEdge: polygonEdge,
                                      alongPolygon: hit.alongOther, at: a + (b - a) * hit.along))
            }
        }
        return found.sorted { ($0.strokeEdge, $0.along) < ($1.strokeEdge, $1.along) }
    }

    /// Expands `polygon` to include exterior regions enclosed by `stroke`. Each segment of
    /// `stroke` that exits and re-enters `polygon` replaces the bypassed boundary section.
    /// Returns `nil` if `stroke` never exits and re-enters `polygon`.
    ///
    /// When `snap` is positive, stroke endpoints that stop outside `polygon` within `snap`
    /// meters of an edge are extended across the boundary automatically.
    public static func expanded(_ polygon: [Point2], by stroke: [Point2], snap: Float = 0) -> [Point2]? {
        var outline = withoutRepeats(polygon, closed: true)
        var rest = withoutRepeats(stroke, closed: false)
        if snap > 0, outline.count >= 3, rest.count >= 2 {
            /// Projects an exterior endpoint slightly inside `outline` if it lies within `snap` meters of an edge.
            func carriedIn(_ end: Point2) -> Point2? {
                guard !contains(outline, end) else { return nil }
                var best: (at: Point2, distance: Float)?
                for (index, a) in outline.enumerated() {
                    let b = outline[(index + 1) % outline.count]
                    let found = nearest(on: a, b, to: end)
                    if found.distance <= snap, found.distance < (best?.distance ?? .infinity) {
                        best = (a + (b - a) * found.along, found.distance)
                    }
                }
                guard let best else { return nil }
                // Step straight across the closest edge if that lands inside the polygon; otherwise step toward the centroid.
                let onward = best.distance > 1e-4 ? (best.at - end) * (1 / best.distance) : Point2(0, 0)
                let through = best.at + onward * 0.03
                if contains(outline, through) { return through }
                let middle = outline.reduce(Point2(0, 0), +) * (1 / Float(outline.count))
                let inward = middle - best.at
                let stepped = best.at + inward * (0.03 / max(inward.length, 0.03))
                return contains(outline, stepped) ? stepped : nil
            }
            if let first = rest.first, let start = carriedIn(first) { rest.insert(start, at: 0) }
            if let last = rest.last, let finish = carriedIn(last) { rest.append(finish) }
        }
        var grown = false
        guard outline.count >= 3 else { return nil }
        // Each pass consumes at least one exterior excursion of the stroke.
        for _ in 0..<64 {
            let all = crossings(of: rest, with: outline)
            guard all.count >= 2 else { break }
            // Find the first pair of consecutive crossings whose midpoint lies outside the polygon.
            var pair: (leaving: Crossing, returning: Crossing)?
            for index in 0..<(all.count - 1) {
                let leaving = all[index], returning = all[index + 1]
                let next = leaving.strokeEdge == returning.strokeEdge ? returning.at : rest[leaving.strokeEdge + 1]
                if !contains(outline, leaving.at + (next - leaving.at) * 0.5) {
                    pair = (leaving, returning)
                    break
                }
            }
            guard let pair else { break }
            let (leaving, returning) = pair
            var stretch = [leaving.at]
            if returning.strokeEdge > leaving.strokeEdge { stretch += rest[(leaving.strokeEdge + 1)...returning.strokeEdge] }
            stretch.append(returning.at)

            // Walk the existing polygon perimeter from `returning` to `leaving` in both directions.
            let count = outline.count
            let sameEdge = leaving.polygonEdge == returning.polygonEdge
            var onward: [Point2] = [], backward: [Point2] = []
            if !(sameEdge && leaving.alongPolygon >= returning.alongPolygon) {
                var edge = returning.polygonEdge
                repeat {
                    edge = (edge + 1) % count
                    onward.append(outline[edge])
                } while edge != leaving.polygonEdge
            }
            if !(sameEdge && leaving.alongPolygon <= returning.alongPolygon) {
                var edge = returning.polygonEdge
                repeat {
                    backward.append(outline[edge])
                    edge = (edge + count - 1) % count
                } while edge != leaving.polygonEdge
            }
            // Keep the perimeter path that produces the larger combined area (the union rather than just the added lobe).
            let one = stretch + onward, other = stretch + backward
            outline = withoutRepeats(abs(signedArea(one)) > abs(signedArea(other)) ? one : other, closed: true)
            grown = true
            rest = [returning.at] + rest[(returning.strokeEdge + 1)...]
        }
        return grown ? outline : nil
    }

    /// Finds the largest-area axis-aligned rectangle centered on the origin that fits inside
    /// `polygon` (used for SteamVR's `play_area`). Returns `(0, 0)` if the origin is outside `polygon`.
    public static func centeredRectangle(in polygon: [Point2]) -> (width: Float, depth: Float) {
        guard contains(polygon, Point2(0, 0)) else { return (0, 0) }
        let reach = polygon.map { abs($0.x) }.max() ?? 0
        /// Returns the maximum half-depth along z that fits inside `polygon` for a given half-width along x.
        func halfDepth(forHalfWidth half: Float) -> Float {
            var least = Float.infinity
            for (index, a) in polygon.enumerated() {
                let b = polygon[(index + 1) % polygon.count]
                // Clip the edge to the open vertical strip `-half < x < half`.
                var from: Float = 0, to: Float = 1
                let run = b.x - a.x
                if abs(run) < 1e-9 {
                    guard abs(a.x) < half else { continue }
                } else {
                    let one = (-half - a.x) / run, other = (half - a.x) / run
                    from = max(from, min(one, other))
                    to = min(to, max(one, other))
                    guard from < to else { continue }
                }
                let start = a.z + (b.z - a.z) * from, end = a.z + (b.z - a.z) * to
                least = min(least, (start > 0) != (end > 0) ? 0 : min(abs(start), abs(end)))
            }
            return least.isFinite ? least : 0
        }
        // Sample evenly spaced candidate half-widths along with every vertex x distance.
        let steps = 48
        let widths = (1...steps).map { reach * Float($0) / Float(steps) } + polygon.map { abs($0.x) }
        var best: (width: Float, depth: Float) = (0, 0)
        for half in widths where half > 0 {
            let depth = halfDepth(forHalfWidth: half)
            if half * depth > best.width * best.depth / 4 { best = (half * 2, depth * 2) }
        }
        return best
    }

    /// Approximates a circle with a regular counterclockwise polygon on the `(x, z)` plane.
    public static func circle(radius: Float, corners: Int = 32, around center: Point2 = Point2(0, 0)) -> [Point2] {
        (0..<corners).map { index in
            let angle = Float(index) / Float(corners) * 2 * .pi
            return Point2(center.x + radius * cos(angle), center.z + radius * sin(angle))
        }
    }
}
