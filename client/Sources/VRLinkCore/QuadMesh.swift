// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Projects one eye's world-space quads into a clip-space triangle mesh so graphics backends only need a
/// pass-through vertex shader.
///
/// Note: `VRLinkMetal.QuadRenderer` predates `QuadMesh` and packs stereo vertex pairs directly for
/// single-pass rendering on visionOS.
public struct QuadMesh {
    /// Vertex stride in floats: clip-space position (4), color UV (2), alpha UV (2), quad-local UV (2), and
    /// forward distance from the rendered eye in meters (1).
    public static let floatsPerVertex = 11

    /// Index range and shading parameters for a single quad draw call.
    public struct Draw {
        public var firstIndex: Int, indexCount: Int
        /// Base vertex offset added to each index in this draw.
        public var firstVertex: Int
        /// Edge feather width as a fraction of the quad's size.
        public var feather: Float
        /// Solid linear RGBA color used when drawing an untextured quad.
        public var fill: [Float]?
        /// Indices of the color and optional alpha textures in the decoded frame.
        public var picture: Int
        public var alphaPicture: Int?
        /// Normalized bounds and feather width of an overlapping feathered quad (see `Quad.covered`).
        public var covered: (left: Float, top: Float, right: Float, bottom: Float, feather: Float)?
    }

    public private(set) var vertices: [Float] = []
    public private(set) var indices: [UInt16] = []
    public private(set) var draws: [Draw] = []

    /// Projects `quads` from `view` into clip space. Set `yDown` to `true` for APIs where clip-space +Y
    /// points downward (such as Vulkan) and `false` when +Y points upward (such as Metal).
    ///
    /// When a quad uses a depth-warped mesh (`quad.grid`), the display eye may have translated away from the
    /// eye pose the host rendered from. To preserve projective texturing from the host eye, texture coordinates
    /// are pre-multiplied by each vertex's forward distance (`ahead`), and the fragment shader divides the
    /// interpolated UVs by the interpolated `ahead` value. Flat quads use `ahead = 1` at every vertex.
    public init(_ quads: [Quad], from view: EyeView, near: Float = 0.05, far: Float = 100, yDown: Bool) {
        for quad in quads {
            let columns = quad.grid?.columns ?? 1, rows = quad.grid?.rows ?? 1
            let firstVertex = vertices.count / QuadMesh.floatsPerVertex
            for row in 0...rows {
                let down = Float(row) / Float(rows)
                for column in 0...columns {
                    let across = Float(column) / Float(columns)
                    let point: Vec3
                    var ahead: Float = 1
                    if let grid = quad.grid {
                        point = grid.points[row * (columns + 1) + column]
                        ahead = grid.ahead[row * (columns + 1) + column]
                    } else {
                        let top = quad.corners[0] * (1 - across) + quad.corners[1] * across
                        let bottom = quad.corners[2] * (1 - across) + quad.corners[3] * across
                        point = top * (1 - down) + bottom * down
                    }
                    var clip = view.frustum.project(point, from: view.eye, near: near, far: far)
                    if yDown { clip[1] = -clip[1] }
                    vertices += clip
                    vertices.append((quad.atlasLeft + (quad.atlasRight - quad.atlasLeft) * across) * ahead)
                    vertices.append((quad.atlasTop + (quad.atlasBottom - quad.atlasTop) * down) * ahead)
                    vertices.append((quad.alpha.map { $0.left + ($0.right - $0.left) * across } ?? 0) * ahead)
                    vertices.append((quad.alpha.map { $0.top + ($0.bottom - $0.top) * down } ?? 0) * ahead)
                    vertices.append(across * ahead)
                    vertices.append(down * ahead)
                    vertices.append(ahead)
                }
            }
            let firstIndex = indices.count
            for row in 0..<rows {
                for column in 0..<columns {
                    let topLeft = UInt16(row * (columns + 1) + column), bottomLeft = topLeft + UInt16(columns + 1)
                    indices += [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1]
                }
            }
            draws.append(Draw(firstIndex: firstIndex, indexCount: indices.count - firstIndex, firstVertex: firstVertex,
                              feather: quad.feather, fill: quad.fill, picture: quad.picture, alphaPicture: quad.alpha?.picture,
                              covered: quad.covered))
        }
    }
}
