// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class StreamPipelineTests: XCTestCase {
    func testSinglePictureFrameCompletesImmediately() {
        let assembler = PictureAssembler<String>()
        XCTAssertEqual(assembler.add("a", index: 0, frameID: 7, of: 1), ["a"])
    }

    func testOutOfOrderPicturesReturnInStreamOrder() {
        let assembler = PictureAssembler<String>()
        XCTAssertNil(assembler.add("right", index: 1, frameID: 7, of: 3))
        XCTAssertNil(assembler.add("alpha", index: 2, frameID: 7, of: 3))
        XCTAssertEqual(assembler.add("left", index: 0, frameID: 7, of: 3), ["left", "right", "alpha"])
    }

    func testCompletedFrameDropsOlderIncompleteFrames() {
        let assembler = PictureAssembler<String>()
        XCTAssertNil(assembler.add("old left", index: 0, frameID: 1, of: 2))
        XCTAssertNil(assembler.add("left", index: 0, frameID: 2, of: 2))
        XCTAssertEqual(assembler.add("right", index: 1, frameID: 2, of: 2), ["left", "right"])
        // Completing frame 2 discards frame 1, so a late arrival for frame 1 does not complete it.
        XCTAssertNil(assembler.add("old right", index: 1, frameID: 1, of: 2))
    }

    func testResetClearsIncompleteFrames() {
        let assembler = PictureAssembler<String>()
        XCTAssertNil(assembler.add("left", index: 0, frameID: 1, of: 2))
        assembler.reset()
        XCTAssertNil(assembler.add("right", index: 1, frameID: 1, of: 2))
    }

    private let ahead = EyeView(eye: Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)),
                                frustum: Frustum(left: -1, right: 1, down: -1, up: 1))

    func testFlatQuadFillsClipSpace() {
        // Place a 4x4 m quad 2 m ahead so its corners map directly to the edges of the 90-degree frustum.
        let quad = Quad(corners: [Vec3(-2, 2, -2), Vec3(2, 2, -2), Vec3(-2, -2, -2), Vec3(2, -2, -2)],
                        atlasLeft: 0.25, atlasTop: 0, atlasRight: 0.75, atlasBottom: 0.5, feather: 0.1, picture: 1)
        let mesh = QuadMesh([quad], from: ahead, yDown: false)
        XCTAssertEqual(mesh.vertices.count, 4 * QuadMesh.floatsPerVertex)
        XCTAssertEqual(mesh.indices, [0, 2, 1, 1, 2, 3])
        XCTAssertEqual(mesh.draws.count, 1)
        XCTAssertEqual(mesh.draws[0].picture, 1)
        XCTAssertEqual(mesh.draws[0].feather, 0.1)
        XCTAssertNil(mesh.draws[0].alphaPicture)
        func vertex(_ index: Int) -> [Float] {
            Array(mesh.vertices[index * QuadMesh.floatsPerVertex..<(index + 1) * QuadMesh.floatsPerVertex])
        }
        // Top-left vertex projects to clip (-w, +w) with w = 2 m, atlas top-left UV, and quad corner (0, 0).
        let topLeft = vertex(0)
        XCTAssertEqual(topLeft[0], -2, accuracy: 1e-5)
        XCTAssertEqual(topLeft[1], 2, accuracy: 1e-5)
        XCTAssertEqual(topLeft[3], 2, accuracy: 1e-5)
        XCTAssertEqual(Array(topLeft[4..<6]), [0.25, 0])
        XCTAssertEqual(Array(topLeft[8..<11]), [0, 0, 1])
        let bottomRight = vertex(3)
        XCTAssertEqual(bottomRight[0], 2, accuracy: 1e-5)
        XCTAssertEqual(bottomRight[1], -2, accuracy: 1e-5)
        XCTAssertEqual(Array(bottomRight[4..<6]), [0.75, 0.5])
        XCTAssertEqual(Array(bottomRight[8..<11]), [1, 1, 1])
    }

    func testYDownFlipsClipY() {
        let quad = Quad(corners: [Vec3(-2, 2, -2), Vec3(2, 2, -2), Vec3(-2, -2, -2), Vec3(2, -2, -2)])
        let up = QuadMesh([quad], from: ahead, yDown: false), down = QuadMesh([quad], from: ahead, yDown: true)
        XCTAssertEqual(up.vertices[1], -down.vertices[1])
        XCTAssertEqual(up.vertices[0], down.vertices[0])
    }

    func testMultipleQuadsUseBaseVertexOffsets() {
        let quad = Quad(corners: [Vec3(-1, 1, -2), Vec3(1, 1, -2), Vec3(-1, -1, -2), Vec3(1, -1, -2)])
        let mesh = QuadMesh([quad, quad], from: ahead, yDown: true)
        XCTAssertEqual(mesh.draws.map(\.firstVertex), [0, 4])
        XCTAssertEqual(mesh.draws.map(\.firstIndex), [0, 6])
        XCTAssertEqual(Array(mesh.indices[6...]), [0, 2, 1, 1, 2, 3])
    }
}
