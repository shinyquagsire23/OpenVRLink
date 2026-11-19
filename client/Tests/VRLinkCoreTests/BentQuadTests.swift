// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class BentQuadTests: XCTestCase {
    private let apart: Float = 0.064
    private func eye(_ aside: Float) -> Pose {
        Pose(position: Vec3(aside, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
    }
    /// Stereo layout with a wide peripheral tile and a centered foveal tile per eye; the right peripheral tile is wider.
    private var layout: FrameLayout {
        FrameLayout(views: [
            FrameLayout.View(eye: eye(-apart / 2), tiles: [
                FrameLayout.Tile(frustum: Frustum(left: -1, right: 0.8, down: -0.9, up: 0.9)),
                FrameLayout.Tile(frustum: Frustum(left: -0.3, right: 0.3, down: -0.3, up: 0.3), feather: 0.06)]),
            FrameLayout.View(eye: eye(apart / 2), tiles: [
                FrameLayout.Tile(frustum: Frustum(left: -0.8, right: 1.2, down: -0.9, up: 0.9)),
                FrameLayout.Tile(frustum: Frustum(left: -0.3, right: 0.3, down: -0.3, up: 0.3), feather: 0.06)]),
        ], eyePixels: (100, 100))
    }
    private let window = Frustum(left: -1.2, right: 1.2, down: -0.9, up: 0.9)

    func testWithoutDepthQuadsAreFlat() {
        let quads = Composition.quads(for: .left, layout: layout)
        XCTAssertEqual(quads.count, 2)
        XCTAssertTrue(quads.allSatisfy { $0.grid == nil })
        XCTAssertEqual(quads[1].feather, 0.06)
    }

    func testEveryPointOfABentQuadIsOnItsLineOfSightAtTheFieldsDistance() throws {
        let field = DepthField(columns: 4, rows: 4, window: window, apart: apart, everywhere: 0.5)
        for side in Eye.allCases {
            let view = layout.views[side.rawValue]
            let quad = Composition.quads(for: side, layout: layout, depth: field)[0]
            let grid = try XCTUnwrap(quad.grid)
            XCTAssertEqual(grid.points.count, (grid.columns + 1) * (grid.rows + 1))
            XCTAssertEqual(grid.ahead.count, grid.points.count)
            let tile = view.tiles[0].frustum
            for row in 0...grid.rows {
                for column in 0...grid.columns {
                    let seen = view.eye.local(grid.points[row * (grid.columns + 1) + column])
                    XCTAssertEqual(seen.z, 2, accuracy: 1e-3, "0.5 m^-1 corresponds to 2 m forward")
                    XCTAssertEqual(grid.ahead[row * (grid.columns + 1) + column], 2, accuracy: 1e-3)
                    // Projected ray tangents match the unwarped flat quad.
                    XCTAssertEqual(seen.x / seen.z, tile.left + (tile.right - tile.left) * Float(column) / Float(grid.columns), accuracy: 1e-4)
                    XCTAssertEqual(seen.y / seen.z, tile.up - (tile.up - tile.down) * Float(row) / Float(grid.rows), accuracy: 1e-4)
                }
            }
        }
    }

    func testBothEyesQuadsAreDividedAlike() throws {
        let field = DepthField(columns: 4, rows: 4, window: window, apart: apart)
        let left = Composition.quads(for: .left, layout: layout, depth: field)
        let right = Composition.quads(for: .right, layout: layout, depth: field)
        for (a, b) in zip(left, right) {
            XCTAssertEqual(a.grid?.columns, b.grid?.columns)
            XCTAssertEqual(a.grid?.rows, b.grid?.rows)
        }
        // The wider peripheral tile (span 2.0) determines the shared column count, keeping cells within `Composition.cell`.
        let wide = try XCTUnwrap(left[0].grid)
        XCTAssertEqual(wide.columns, Int((Float(2.0) / Composition.cell).rounded(.up)))
        XCTAssertLessThan(try XCTUnwrap(left[1].grid).columns, wide.columns)
        // Very wide tiles clamp subdivision count to `Composition.mostCells`.
        let huge = FrameLayout(views: [FrameLayout.View(eye: eye(0), tiles: [
            FrameLayout.Tile(frustum: Frustum(left: -5, right: 5, down: -0.01, up: 0.01))])], eyePixels: (1, 1))
        let stretched = try XCTUnwrap(Composition.quads(for: .left, layout: huge, depth: field)[0].grid)
        XCTAssertEqual(stretched.columns, Composition.mostCells)
        XCTAssertEqual(stretched.rows, 1)
    }

    func testANearThingBendsTheQuadTowardTheEye() throws {
        // Set the lower half of the field to 1 m and the upper half to 10 m.
        var field = DepthField(columns: 8, rows: 8, window: window, apart: apart)
        for index in field.nearness.indices where index / 8 >= 4 { field.nearness[index] = 1 }
        let view = layout.views[0]
        let grid = try XCTUnwrap(Composition.quads(for: .left, layout: layout, depth: field)[0].grid)
        let top = view.eye.local(grid.points[grid.columns / 2])
        let bottom = view.eye.local(grid.points[grid.rows * (grid.columns + 1) + grid.columns / 2])
        XCTAssertEqual(top.z, 10, accuracy: 0.1)
        XCTAssertEqual(bottom.z, 1, accuracy: 0.01)
    }

    func testTheDepthPictureHasOneQuadForEachCellWhereThatEyeSeesIt() {
        var field = DepthField(columns: 2, rows: 1, window: Frustum(left: -1, right: 1, down: -0.5, up: 0.5), apart: apart)
        field.nearness = [2, 0.1]
        let quads = Composition.picture(of: field, for: .left, layout: layout)
        XCTAssertEqual(quads.count, 2)
        let view = layout.views[0]
        let near = view.eye.local(quads[0].corners[0]), far = view.eye.local(quads[1].corners[0])
        XCTAssertEqual(near.z, 0.97 / 2, accuracy: 1e-3, "placed slightly in front of the video surface")
        XCTAssertEqual(far.z, 9.7, accuracy: 1e-2)
        // Parallax shifts the near cell rightward in the left eye by `0.5 * apart * nearness`.
        XCTAssertEqual(near.x / near.z, -1 + 0.08 + apart / 2 * 2, accuracy: 1e-3)
        XCTAssertEqual(Array(quads[0].fill![0..<3]), Composition.color(forDistance: 0.5))
        XCTAssertEqual(Array(quads[1].fill![0..<3]), [0, 0, 1], "10 m saturates to blue beyond farthestColored")
    }

    func testDepthColorsRunFromRedThroughGreenToBlueOverSevenMeters() {
        XCTAssertEqual(Composition.color(forDistance: 0), [1, 0, 0])
        XCTAssertEqual(Composition.color(forDistance: 1.75), [1, 1, 0])
        XCTAssertEqual(Composition.color(forDistance: 3.5), [0, 1, 0])
        XCTAssertEqual(Composition.color(forDistance: 5.25), [0, 1, 1])
        XCTAssertEqual(Composition.color(forDistance: 7), [0, 0, 1])
        XCTAssertEqual(Composition.color(forDistance: 40), [0, 0, 1])
        // Adjacent 1 m steps remain visually distinct across the active range.
        for meters in stride(from: Float(0.5), to: 6, by: 0.5) {
            let here = Composition.color(forDistance: meters), there = Composition.color(forDistance: meters + 1)
            XCTAssertGreaterThan(zip(here, there).map { abs($0 - $1) }.reduce(0, +), 0.5, "\(meters) m against \(meters + 1) m")
        }
    }
}
