// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import XCTest
@testable import VRLinkCore

/// Synthetic test scene with a floor 1.5 m below eye level, a back wall at 5 m,
/// and a floating panel at 1 m in the upper center, textured with world-locked multi-scale noise.
enum PretendRoom {
    static let window = Frustum(left: -1.1, right: 1.1, down: -0.9, up: 0.9)
    static let apart: Float = 0.064
    static let floorBelow: Float = 1.5, wallAhead: Float = 5, panelAhead: Float = 1
    static let panel = (left: Float(-0.25), right: Float(0.25), down: Float(0.05), up: Float(0.45))   // meters, at the panel

    private static func speck(_ x: Int, _ y: Int, _ salt: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ salt &* 362437)
        h = (h ^ (h >> 13)) &* 1274126177
        return Float((h ^ (h >> 16)) & 0xFF) / 255
    }

    /// Evaluates 3-octave value noise (`0...1`) parameterized in meters `(u, v)` along a surface.
    static func speckle(_ u: Float, _ v: Float, surface: Int) -> Float {
        var total: Float = 0
        for (octave, size) in [Float(0.04), 0.15, 0.6].enumerated() {
            let x = u / size, y = v / size, x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Float(x0), fy = y - Float(y0), salt = surface * 7 + octave
            let top = speck(x0, y0, salt) * (1 - fx) + speck(x0 + 1, y0, salt) * fx
            let bottom = speck(x0, y0 + 1, salt) * (1 - fx) + speck(x0 + 1, y0 + 1, salt) * fx
            total += top * (1 - fy) + bottom * fy
        }
        return total / 3
    }

    /// Raycasts from an eye offset `aside` meters right of the midpoint along tangent `(across, up)`,
    /// returning surface brightness (`0...1`) and forward depth in meters.
    static func seen(aside: Float, across: Float, up: Float) -> (brightness: Float, ahead: Float) {
        // Intersect the foreground panel first.
        let px = aside + across * panelAhead, py = up * panelAhead
        if px >= panel.left, px <= panel.right, py >= panel.down, py <= panel.up {
            return (speckle(px, py, surface: 1), panelAhead)
        }
        // Otherwise intersect the floor where it lies closer than the back wall.
        if up < 0, floorBelow / -up < wallAhead {
            let ahead = floorBelow / -up
            return (speckle(aside + across * ahead, ahead, surface: 2), ahead)
        }
        return (speckle(aside + across * wallAhead, up * wallAhead, surface: 3), wallAhead)
    }

    /// Ground-truth inverse depth (`1 / meters`) along `(across, up)` from the cyclopean midpoint.
    static func nearness(across: Float, up: Float) -> Float { 1 / seen(aside: 0, across: across, up: up).ahead }

    static func picture(aside: Float, width: Int, height: Int, brighter: Float = 0) -> LumaPicture {
        var out = LumaPicture(width: width, height: height)
        for row in 0..<height {
            let up = window.up - (Float(row) + 0.5) / Float(height) * (window.up - window.down)
            for column in 0..<width {
                let across = window.left + (Float(column) + 0.5) / Float(width) * (window.right - window.left)
                let value = seen(aside: aside, across: across, up: up).brightness * 200 + 20 + brighter
                out.pixels[row * width + column] = UInt8(max(0, min(255, value)))
            }
        }
        return out
    }

    static func pair(width: Int = 384, height: Int = 314, rightBrighter: Float = 0) -> StereoPair {
        StereoPair(left: picture(aside: -apart / 2, width: width, height: height),
                   right: picture(aside: apart / 2, width: width, height: height, brighter: rightBrighter),
                   window: window, apart: apart)
    }
}

final class StereoDepthTests: XCTestCase {
    /// Tangent coordinates at the center of cell `index`.
    private func direction(_ matcher: StereoMatcher, _ index: Int) -> (across: Float, up: Float) {
        let window = PretendRoom.window, row = index / matcher.columns, column = index % matcher.columns
        return (window.left + (Float(column) + 0.5) / Float(matcher.columns) * (window.right - window.left),
                window.up - (Float(row) + 0.5) / Float(matcher.rows) * (window.up - window.down))
    }

    /// Returns `true` when `(across, up)` lies well inside a single surface, away from occlusion boundaries and the floor-wall crease.
    private func plain(_ across: Float, _ up: Float) -> Bool {
        let panel = PretendRoom.panel, edge: Float = 0.12
        let nearPanelEdge = across > panel.left - edge && across < panel.right + edge && up > panel.down - edge && up < panel.up + edge
            && !(across > panel.left + edge && across < panel.right - edge && up > panel.down + edge && up < panel.up - edge)
        return !nearPanelEdge && abs(up + PretendRoom.floorBelow / PretendRoom.wallAhead) > 0.08
    }

    func testTheShiftBetweenTheEyesGivesEachSurfaceItsDistance() {
        let matcher = StereoMatcher()
        let readings = matcher.measure(PretendRoom.pair())
        var trusted = 0, plainCells = 0, worst: Float = 0
        for (index, reading) in readings.enumerated() {
            let (across, up) = direction(matcher, index)
            guard plain(across, up) else { continue }
            plainCells += 1
            guard reading.trust > 0 else { continue }
            trusted += 1
            let truth = PretendRoom.nearness(across: across, up: up)
            worst = max(worst, abs(reading.nearness - truth))
            XCTAssertEqual(reading.nearness, truth, accuracy: 0.08, "cell \(index) looking \(across), \(up)")
        }
        XCTAssertGreaterThan(Float(trusted), Float(plainCells) * 0.8, "expected confident matches across most interior cells")
        XCTAssertLessThan(worst, 0.08)
        // Check accuracy on the 1 m panel, 5 m back wall, and foreground floor.
        func reading(across: Float, up: Float) -> StereoMatcher.Reading {
            let window = PretendRoom.window
            let column = Int((across - window.left) / (window.right - window.left) * Float(matcher.columns))
            let row = Int((window.up - up) / (window.up - window.down) * Float(matcher.rows))
            return readings[row * matcher.columns + column]
        }
        XCTAssertEqual(reading(across: 0, up: 0.25).nearness, 1, accuracy: 0.05)
        XCTAssertEqual(reading(across: 0.7, up: 0.5).nearness, 0.2, accuracy: 0.05)
        XCTAssertEqual(reading(across: -0.5, up: -0.75).nearness, 0.5, accuracy: 0.06)
    }

    func testOneEyeBeingBrighterDoesNotMatter() {
        let matcher = StereoMatcher()
        let plainReadings = matcher.measure(PretendRoom.pair())
        let lifted = matcher.measure(PretendRoom.pair(rightBrighter: 25))
        var compared = 0
        for (a, b) in zip(plainReadings, lifted) where a.trust > 0 && b.trust > 0 {
            compared += 1
            XCTAssertEqual(a.nearness, b.nearness, accuracy: 0.03)
        }
        XCTAssertGreaterThan(compared, plainReadings.count / 2)
    }

    func testABlankPictureIsNotBelieved() {
        let flat = LumaPicture(width: 384, height: 314, pixels: [UInt8](repeating: 90, count: 384 * 314))
        let readings = StereoMatcher().measure(StereoPair(left: flat, right: flat, window: PretendRoom.window, apart: 0.064))
        XCTAssertTrue(readings.allSatisfy { $0.trust == 0 })
        // Also reject images smaller than the patch window or stereo pairs with zero baseline.
        let tiny = LumaPicture(width: 16, height: 16)
        XCTAssertTrue(StereoMatcher().measure(StereoPair(left: tiny, right: tiny, window: PretendRoom.window, apart: 0.064))
            .allSatisfy { $0.trust == 0 })
        var together = PretendRoom.pair(width: 192, height: 157)
        together.apart = 0
        XCTAssertTrue(StereoMatcher().measure(together).allSatisfy { $0.trust == 0 })
    }

    func testOnlyThePartOfEachPictureThatHoldsPictureIsCompared() {
        // Zero out the leftmost 60 columns of the right image to simulate asymmetric nasal FOV clipping.
        var pair = PretendRoom.pair()
        for row in 0..<pair.right.height {
            for column in 0..<60 { pair.right.pixels[row * pair.right.width + column] = 0 }
        }
        pair.rightCovered = (60..<pair.right.width, 0..<pair.right.height)
        let matcher = StereoMatcher()
        let readings = matcher.measure(pair)
        for (index, reading) in readings.enumerated() where reading.trust > 0 {
            let (across, up) = direction(matcher, index)
            guard plain(across, up) else { continue }
            XCTAssertEqual(reading.nearness, PretendRoom.nearness(across: across, up: up), accuracy: 0.08)
        }
        XCTAssertEqual(readings[matcher.columns * 12].trust, 0, "leftmost column falls outside the right eye's valid region")
    }

    func testTheFieldSettlesOnTheRoomAndFillsWhatWasNotMeasured() {
        let matcher = StereoMatcher()
        var readings = matcher.measure(PretendRoom.pair())
        // Clear two adjacent wall cells to test inpainting, and inject a single-cell outlier on the floor.
        let blank = [4 * matcher.columns + 21, 4 * matcher.columns + 22]
        for index in blank { readings[index].trust = 0 }
        let wild = 21 * matcher.columns + 6
        readings[wild] = StereoMatcher.Reading(nearness: 2.8, trust: 1)

        var smoother = DepthSmoother()
        var field = DepthField(columns: 0, rows: 0, window: PretendRoom.window, apart: PretendRoom.apart)
        for _ in 0..<12 {
            field = smoother.update(readings, columns: matcher.columns, rows: matcher.rows, window: PretendRoom.window,
                                    apart: PretendRoom.apart)
        }
        XCTAssertGreaterThan(smoother.measured, 0.7)
        XCTAssertEqual(field.nearness(across: 0, up: 0.25), 1, accuracy: 0.08, "panel")
        XCTAssertEqual(field.nearness(across: 0.7, up: 0.5), 0.2, accuracy: 0.05, "wall")
        XCTAssertEqual(field.nearness(across: -0.5, up: -0.75), 0.5, accuracy: 0.06, "floor")
        let (blankAcross, blankUp) = direction(matcher, blank[0])
        XCTAssertEqual(field.nearness(across: blankAcross, up: blankUp), 0.2, accuracy: 0.05, "inpainted from surrounding wall cells")
        let (wildAcross, wildUp) = direction(matcher, wild)
        XCTAssertEqual(field.nearness(across: wildAcross, up: wildUp), PretendRoom.nearness(across: wildAcross, up: wildUp),
                       accuracy: 0.1, "single-cell outlier rejected")
    }

    func testTheFieldMovesPartOfTheWayEachFrame() {
        var smoother = DepthSmoother()
        let window = PretendRoom.window
        func all(_ nearness: Float) -> [StereoMatcher.Reading] {
            [StereoMatcher.Reading](repeating: .init(nearness: nearness, trust: 1), count: 16)
        }
        // Uninitialized cells adopt the first reading immediately, then blend incrementally on subsequent updates.
        XCTAssertEqual(smoother.update(all(1), columns: 4, rows: 4, window: window, apart: 0.064).nearness[5], 1, accuracy: 1e-4)
        for _ in 0..<10 { _ = smoother.update(all(1), columns: 4, rows: 4, window: window, apart: 0.064) }
        let stepped = smoother.update(all(2), columns: 4, rows: 4, window: window, apart: 0.064).nearness[5]
        XCTAssertEqual(stepped, 1 + smoother.rate, accuracy: 0.02)
        // One missing frame decays confidence slightly without snapping back to `far`.
        let none = [StereoMatcher.Reading](repeating: .init(nearness: 0, trust: 0), count: 16)
        let after = smoother.update(none, columns: 4, rows: 4, window: window, apart: 0.064).nearness[5]
        XCTAssertEqual(after, stepped, accuracy: 0.05)
        XCTAssertLessThan(after, stepped)
        // Changing grid dimensions resets the smoother to `DepthSmoother.far`.
        XCTAssertEqual(smoother.update([], columns: 2, rows: 2, window: window, apart: 0.064).nearness,
                       [Float](repeating: DepthSmoother.far, count: 4))
    }

    func testWhatCanNoLongerBeMeasuredGoesBackToFarAway() {
        // Place a 1 m foreground object on the left half over an unmeasurable featureless background.
        var smoother = DepthSmoother()
        let window = PretendRoom.window, columns = 12, rows = 8
        func readings(nearColumns: Range<Int>) -> [StereoMatcher.Reading] {
            (0..<columns * rows).map { nearColumns.contains($0 % columns) ? .init(nearness: 1, trust: 1) : .init(nearness: 0, trust: 0) }
        }
        var field = smoother.update(readings(nearColumns: 0..<6), columns: columns, rows: rows, window: window, apart: 0.064)
        for _ in 0..<10 { field = smoother.update(readings(nearColumns: 0..<6), columns: columns, rows: rows, window: window, apart: 0.064) }
        XCTAssertEqual(field.nearness[3 * columns + 2], 1, accuracy: 0.05, "foreground object")
        XCTAssertLessThan(field.nearness[3 * columns + 10], 0.08, "distant background stays near DepthSmoother.far")
        XCTAssertGreaterThan(field.nearness[3 * columns + 6], field.nearness[3 * columns + 8], "depth transitions smoothly across the object boundary")

        // Move the foreground object to the right half; within 30 frames (~1 s) the vacated left
        // region decays back to `far` rather than retaining stale foreground depth.
        for _ in 0..<30 { field = smoother.update(readings(nearColumns: 6..<12), columns: columns, rows: rows, window: window, apart: 0.064) }
        XCTAssertLessThan(field.nearness[3 * columns + 1], 0.08)
        XCTAssertEqual(field.nearness[3 * columns + 9], 1, accuracy: 0.05)
    }

    func testAFloorMeasuredOnlyHereAndThereIsFilledInAsAFloor() {
        // Simulate a floor 1.6 m below eye level in the lower half of the view with sparse 25% measurement coverage.
        var smoother = DepthSmoother()
        let window = Frustum(left: -1, right: 1, down: -1, up: 1), columns = 24, rows = 24
        func truth(_ index: Int) -> Float? {
            let up = 1 - (Float(index / columns) + 0.5) / Float(rows) * 2
            return up < -0.05 ? -up / 1.6 : nil
        }
        let readings = (0..<columns * rows).map { index -> StereoMatcher.Reading in
            guard let nearness = truth(index), (index / columns + index % columns * 3) % 4 == 0 else { return .init(nearness: 0, trust: 0) }
            return .init(nearness: nearness, trust: 1)
        }
        var field = smoother.update(readings, columns: columns, rows: rows, window: window, apart: 0.064)
        for _ in 0..<10 { field = smoother.update(readings, columns: columns, rows: rows, window: window, apart: 0.064) }
        // Plane-fitting inpainting preserves the linear inverse-depth gradient across unmeasured floor cells.
        var worst: Float = 0
        for index in 0..<columns * rows {
            let row = index / columns, column = index % columns
            guard let nearness = truth(index), (3..<columns - 3).contains(column), (14..<rows - 2).contains(row) else { continue }
            worst = max(worst, abs(field.nearness[index] - nearness))
        }
        XCTAssertLessThan(worst, 0.05)
        // Unmeasured sky cells well above the floor remain at `far`.
        XCTAssertLessThan(field.nearness[3 * columns + 12], 0.06)
    }

    func testAPairCanBeSavedForLaterInspection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-pairs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var pair = PretendRoom.pair(width: 64, height: 48)
        pair.rightCovered = (8..<64, 0..<48)
        pair.save(number: 11, keep: 8, to: folder)
        let left = try Data(contentsOf: folder.appendingPathComponent("pair-3-left.pgm"))
        XCTAssertEqual(String(decoding: left.prefix(13), as: UTF8.self), "P5\n64 48\n255\n")
        XCTAssertEqual(Array(left.dropFirst(13)), pair.left.pixels)
        let about = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("pair-3.json"))) as? [String: Any]
        XCTAssertEqual(about?["rightCovered"] as? [Int], [8, 64, 0, 48])
        XCTAssertEqual(about?["number"] as? Int, 11)
    }

    func testOnlyALatticeAndThePlacesOfInterestAreSampled() {
        let window = Frustum(left: -1.2, right: 1.2, down: -1, up: 1), columns = 56, rows = 48
        let lattice = DepthSampling.cells(columns: columns, rows: rows, window: window, interests: [])
        // Every other cell per axis is a quarter of the grid; thinning the ceiling and far periphery removes more.
        XCTAssertLessThan(lattice.count, columns * rows / 4)
        XCTAssertGreaterThan(lattice.count, columns * rows / 8)
        XCTAssertTrue(lattice.allSatisfy { ($0 / columns) % 2 == 0 && ($0 % columns) % 2 == 0 })
        XCTAssertEqual(Set(lattice).count, lattice.count)
        func kept(_ across: Float, _ up: Float) -> Int {
            lattice.filter { index in
                let x = window.left + (Float(index % columns) + 0.5) / Float(columns) * 2.4
                let y = window.up - (Float(index / columns) + 0.5) / Float(rows) * 2
                return abs(x - across) < 0.15 && abs(y - up) < 0.15
            }.count
        }
        XCTAssertGreaterThan(kept(0, -0.3), kept(0, 0.8), "ceiling should be sampled more sparsely than the center")
        XCTAssertGreaterThan(kept(0, -0.3), kept(1.0, -0.3), "far periphery should be sampled more sparsely than the center")

        // Add a hand region in the lower right and check that every cell inside its radius is sampled.
        let hand = DepthSampling.Interest(across: 0.4, up: -0.5, radius: 0.2)
        let withHand = DepthSampling.cells(columns: columns, rows: rows, window: window, interests: [hand])
        XCTAssertEqual(Array(withHand.prefix(lattice.count)), lattice, "base lattice cells should come first")
        XCTAssertEqual(Set(withHand).count, withHand.count)
        for index in 0..<columns * rows {
            let x = window.left + (Float(index % columns) + 0.5) / Float(columns) * 2.4
            let y = window.up - (Float(index / columns) + 0.5) / Float(rows) * 2
            if hypot(x - 0.4, y + 0.5) <= 0.2 { XCTAssertTrue(withHand.contains(index), "cell \(index)") }
            if hypot(x - 0.4, y + 0.5) > 0.3 { XCTAssertEqual(withHand.contains(index), lattice.contains(index)) }
        }
        // Cap the output at `most` cells, and ignore regions outside the view frustum.
        XCTAssertEqual(DepthSampling.cells(columns: columns, rows: rows, window: window, interests: [hand], most: lattice.count + 5).count,
                       lattice.count + 5)
        let outside = DepthSampling.Interest(across: 5, up: 5, radius: 0.2)
        XCTAssertEqual(DepthSampling.cells(columns: columns, rows: rows, window: window, interests: [outside]), lattice)
    }

    func testPlacesOfInterestComeFromTheHandsAndStraightAhead() {
        func eye(_ aside: Float) -> Pose {
            Pose(position: Vec3(aside, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        }
        let whole = Frustum(left: -1, right: 1, down: -1, up: 1)
        func layout(inset: Frustum?) -> FrameLayout {
            let tiles = [FrameLayout.Tile(frustum: whole)] + (inset.map { [FrameLayout.Tile(frustum: $0, feather: 0.06)] } ?? [])
            return FrameLayout(views: [FrameLayout.View(eye: eye(-0.032), tiles: tiles), FrameLayout.View(eye: eye(0.032), tiles: tiles)],
                               eyePixels: (10, 10))
        }
        // Place one hand 0.5 m ahead (20 cm right, 30 cm down) and a second hand behind the head, which should be ignored.
        let hands = [Vec3(0.2, 1.3, -0.5), Vec3(0, 1.6, 0.4)]
        let found = DepthSampling.interests(layout: layout(inset: Frustum(left: 0.1, right: 0.5, down: -0.4, up: 0)), hands: hands)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].across, 0.4, accuracy: 1e-4)
        XCTAssertEqual(found[0].up, -0.6, accuracy: 1e-4)
        XCTAssertEqual(found[0].radius, DepthSampling.handReach / 0.5, accuracy: 1e-4)
        // The central interest region stays fixed at (0, 0) even when the gaze-tracked foveal inset is off-center.
        XCTAssertEqual(found[1], DepthSampling.Interest(across: 0, up: 0, radius: DepthSampling.sharpRadius))
        // Layouts without a foveal inset also place the central region at (0, 0).
        XCTAssertEqual(DepthSampling.interests(layout: layout(inset: nil), hands: []),
                       [DepthSampling.Interest(across: 0, up: 0, radius: DepthSampling.sharpRadius)])
        // Clamp the tangent radius for distant and very close hands.
        XCTAssertEqual(DepthSampling.Interest(around: Vec3(0, 1.6, -5), reach: 0.17, seenFrom: eye(0))?.radius, 0.1)
        XCTAssertEqual(DepthSampling.Interest(around: Vec3(0, 1.6, -0.2), reach: 0.17, seenFrom: eye(0))?.radius, 0.45)
    }

    func testAHandInFrontOfTheFloorKeepsItsOwnDepthAndASharpEdge() {
        // Simulate a 56x48 grid with a floor at 0.6 /m on the base lattice and a dense block of
        // hand readings at 2 /m in the lower right.
        var smoother = DepthSmoother()
        let window = Frustum(left: -1, right: 1, down: -1, up: 1), columns = 56, rows = 48
        let hand = (columns: 30..<38, rows: 30..<38)
        let readings = (0..<columns * rows).map { index -> StereoMatcher.Reading in
            let row = index / columns, column = index % columns
            if hand.columns.contains(column), hand.rows.contains(row) { return .init(nearness: 2, trust: 1) }
            // Include dense floor readings immediately around the hand to match a circular region of interest.
            let nearHand = (26..<42).contains(column) && (26..<42).contains(row)
            return nearHand || (row % 2 == 0 && column % 2 == 0) ? .init(nearness: 0.6, trust: 1) : .init(nearness: 0, trust: 0)
        }
        var field = smoother.update(readings, columns: columns, rows: rows, window: window, apart: 0.064)
        for _ in 0..<8 { field = smoother.update(readings, columns: columns, rows: rows, window: window, apart: 0.064) }
        // Both the hand and the adjacent floor should keep their own depth with a single-cell transition at the boundary.
        XCTAssertEqual(field.nearness[33 * columns + 33], 2, accuracy: 0.05)
        XCTAssertEqual(field.nearness[33 * columns + 37], 2, accuracy: 0.05, "last column of the hand")
        XCTAssertEqual(field.nearness[33 * columns + 38], 0.6, accuracy: 0.05, "first floor column beside the hand")
        XCTAssertEqual(field.nearness[29 * columns + 33], 0.6, accuracy: 0.05, "first floor row above the hand")
        // Away from the hand, the floor is filled between lattice points without being pulled toward the hand.
        XCTAssertEqual(field.nearness[33 * columns + 45], 0.6, accuracy: 0.05)
        XCTAssertEqual(field.nearness[11 * columns + 11], 0.6, accuracy: 0.05)
    }

    func testEachCellTakesTheFinestSizeThatIsBelieved() {
        let fine: [StereoMatcher.Reading] = [.init(nearness: 1, trust: 0.9), .init(nearness: 0, trust: 0), .init(nearness: 0, trust: 0)]
        let half: [StereoMatcher.Reading] = [.init(nearness: 1.1, trust: 1), .init(nearness: 2, trust: 1), .init(nearness: 0, trust: 0)]
        let quarter: [StereoMatcher.Reading] = [.init(nearness: 1.2, trust: 1), .init(nearness: 2.2, trust: 1), .init(nearness: 0.5, trust: 0.5)]
        let chosen = StereoMatcher.finest([fine, half, quarter], worth: [1, 0.8, 0.6])
        XCTAssertEqual(chosen, [.init(nearness: 1, trust: 0.9), .init(nearness: 2, trust: 0.8), .init(nearness: 0.5, trust: 0.3)])
        // Narrower inputs drop fine pyramid levels.
        XCTAssertEqual(StereoMatcher.fitted(toWidth: 768).levels.map(\.halvings), [0, 1, 2])
        XCTAssertEqual(StereoMatcher.fitted(toWidth: 384).levels.map(\.reach), [10, 8])
        XCTAssertEqual(StereoMatcher.fitted(toWidth: 384).levels.map(\.worth), [1, 0.6])
    }

    func testFaintAndSpeckledPicturesAreMeasuredAtSmallerSizes() {
        // Reduce contrast to 10% and add independent per-eye noise to simulate heavy video quantization.
        var pair = PretendRoom.pair(width: 768, height: 628)
        var seed: UInt64 = 88172645463325252
        func dimmed(_ picture: LumaPicture) -> LumaPicture {
            var out = picture
            for index in out.pixels.indices {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let speckle = Float(seed & 0xFF) / 255 * 5 - 2.5
                out.pixels[index] = UInt8(max(0, min(255, 40 + (Float(picture.pixels[index]) - 120) * 0.1 + speckle)))
            }
            return out
        }
        pair.left = dimmed(pair.left)
        pair.right = dimmed(pair.right)
        var matcher = StereoMatcher()
        var fineOnly = matcher
        fineOnly.reach = matcher.levels[0].reach
        let atFullSize = fineOnly.measure(pair).filter { $0.trust > 0 }.count
        let atAllSizes = matcher.measureLevels(pair)
        XCTAssertGreaterThan(atAllSizes.filter { $0.trust > 0 }.count, atFullSize * 2)
        XCTAssertGreaterThan(atAllSizes.filter { $0.trust > 0 }.count, atAllSizes.count / 2)
        // Verify that coarse-scale matches recover accurate depth on the back wall.
        matcher.columns = 28
        let wall = atAllSizes[2 * matcher.columns + 24]
        XCTAssertGreaterThan(wall.trust, 0)
        XCTAssertEqual(wall.nearness, 0.2, accuracy: 0.08)
    }

    private let ahead = Pose(position: Vec3(0, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))

    /// Synthetic depth field at `ahead` with a 4 m back wall and a 1 m vertical post slightly right of center.
    private func postAndWall() -> DepthField {
        var field = DepthField(columns: 48, rows: 12, window: Frustum(left: -1.2, right: 1.2, down: -0.3, up: 0.3), apart: 0.064,
                               everywhere: 0.25, pose: ahead)
        for row in 0..<12 { for column in 28..<32 { field.nearness[row * 48 + column] = 1 } }       // 0.2 ... 0.4 across
        return field
    }

    func testTurningTheHeadSlidesTheDepthAcrossTheView() {
        let field = postAndWall()
        XCTAssertEqual(field.nearness(across: 0.3, up: 0), 1, accuracy: 1e-3)
        // Yawing 0.2 rad left shifts the post further right in head tangent space.
        let turned = field.moved(to: ahead.turned(by: Vec3(0, 0.2, 0)))
        let now = Float(tan(atan(0.3) + 0.2))
        // Forward Z depth in the rotated frame also scales with the cosine/sine of the yaw angle.
        XCTAssertEqual(turned.nearness(across: now, up: 0), Float(1 / (cos(0.2) - 0.3 * sin(0.2))), accuracy: 0.05)
        XCTAssertEqual(turned.nearness(across: 0.3, up: 0), 0.25, accuracy: 0.03, "previous post direction now exposes the 4 m wall")
        XCTAssertNotNil(turned.pose)
        // Rotating 180 degrees leaves no overlap with the previous frustum, falling back to `far`.
        let behind = field.moved(to: ahead.turned(by: Vec3(0, .pi, 0)))
        XCTAssertEqual(behind.nearness(across: 0, up: 0), DepthSmoother.far)
    }

    func testSteppingTowardThingsBringsThemNearerAndShiftsNearOnesMore() {
        let field = postAndWall()
        // Stepping 0.5 m forward brings the wall to 3.5 m and the post to 0.5 m.
        var stepped = ahead
        stepped.position = Vec3(0, 1.6, -0.5)
        let forward = field.moved(to: stepped)
        XCTAssertEqual(forward.nearness(across: -0.5, up: 0), 1 / 3.5, accuracy: 0.01)
        XCTAssertEqual(forward.nearness(across: 0.6, up: 0), 2, accuracy: 0.15, "post at x = 0.3 m, z = 0.5 m projects to tangent 0.6 at 2 m^-1")
        // Stepping 0.3 m right centers the 1 m post straight ahead while barely shifting the 4 m wall.
        var aside = ahead
        aside.position = Vec3(0.3, 1.6, 0)
        let sideways = field.moved(to: aside)
        XCTAssertEqual(sideways.nearness(across: 0, up: 0), 1, accuracy: 0.05)
        XCTAssertEqual(sideways.nearness(across: -0.6, up: 0), 0.25, accuracy: 0.02)
        // A field with `pose == nil` is returned unchanged.
        var unplaced = field
        unplaced.pose = nil
        XCTAssertEqual(unplaced.moved(to: aside).nearness, field.nearness)
    }

    func testWhatIsHeldFollowsTheHeadBetweenFrames() {
        // Establish a post straight ahead, then yaw right on a frame with zero new measurements.
        var smoother = DepthSmoother()
        let window = Frustum(left: -1, right: 1, down: -0.5, up: 0.5), columns = 20, rows = 10
        let seen = (0..<columns * rows).map { index -> StereoMatcher.Reading in
            (9...10).contains(index % columns) ? .init(nearness: 1, trust: 1) : .init(nearness: 0.25, trust: 1)
        }
        for _ in 0..<8 { _ = smoother.update(seen, columns: columns, rows: rows, window: window, apart: 0.064, pose: ahead) }
        let none = [StereoMatcher.Reading](repeating: .init(nearness: 0, trust: 0), count: columns * rows)
        let turned = ahead.turned(by: Vec3(0, -0.3, 0))
        let field = smoother.update(none, columns: columns, rows: rows, window: window, apart: 0.064, pose: turned)
        // Reprojection carries the cached post depth 0.3 rad to the left.
        XCTAssertGreaterThan(field.nearness(across: -Float(tan(0.3)), up: 0), 0.6)
        XCTAssertLessThan(field.nearness(across: 0.05, up: 0), 0.45)
        XCTAssertEqual(field.pose?.forward.x ?? 0, turned.forward.x, accuracy: 1e-5)
    }

    func testEachEyeLooksUpItsOwnDirection() {
        // Step edge at x = 0: 0.5 m on the left half and 10 m on the right half.
        var field = DepthField(columns: 40, rows: 2, window: Frustum(left: -1, right: 1, down: -1, up: 1), apart: 0.064)
        for index in field.nearness.indices { field.nearness[index] = index % 40 < 20 ? 2 : 0.1 }
        XCTAssertEqual(field.nearness(across: -0.5, up: 0), 2, accuracy: 1e-4)
        XCTAssertEqual(field.nearness(across: 0.5, up: 0), 0.1, accuracy: 1e-4)
        XCTAssertEqual(field.nearness(across: -5, up: 9), 2, accuracy: 1e-4, "out-of-bounds coordinates clamp to border cells")
        // Because the left eye sits left of the midpoint, the foreground edge at midpoint tangent 0
        // projects to +0.064 in the left eye, occluding rays slightly right of center in the left eye
        // while the right eye already sees the 10 m background.
        XCTAssertGreaterThan(field.nearness(seenBy: .left, across: 0.03, up: 0), 1)
        XCTAssertLessThan(field.nearness(seenBy: .right, across: 0.03, up: 0), 1)
        // Precomputing `seen(by:)` matches per-ray `nearness(seenBy:)` queries.
        let fromLeft = field.seen(by: .left), fromRight = field.seen(by: .right)
        XCTAssertEqual(fromLeft.apart, 0)
        XCTAssertGreaterThan(fromLeft.nearness(across: 0.03, up: 0), 1)
        XCTAssertLessThan(fromRight.nearness(across: 0.03, up: 0), 1)
        XCTAssertEqual(fromLeft.nearness(across: -0.5, up: 0), 2, accuracy: 1e-3)
        XCTAssertEqual(fromRight.nearness(across: 0.5, up: 0), 0.1, accuracy: 1e-3)
        // Output inverse depths clamp to `DepthField.range`.
        field.nearness = [Float](repeating: 0, count: 80)
        XCTAssertEqual(field.nearness(seenBy: .left, across: 0, up: 0), DepthField.range.lowerBound)
    }
}
