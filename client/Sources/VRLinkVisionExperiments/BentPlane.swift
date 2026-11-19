// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import RealityKit
import VRLinkCore
import simd

/// Deformable per-eye `LowLevelMesh` warped to `DepthField` for the RealityKit renderer.
///
/// Standard `RealityKitDisplay` planes sit at a fixed distance, so RealityKit
/// reprojects head translation since the frame was rendered as if the entire
/// scene were far away. `BentPlane` places each grid vertex in world space along
/// its rendering eye ray at the estimated scene depth every frame, allowing
/// RealityKit's display-time rendering to shift nearby geometry more than distant geometry.
///
/// Because RealityKit interpolates UVs linearly across each mesh triangle rather
/// than projectively from the host's rendering eye, the mesh is subdivided finely
/// (~1 degree per cell); combined with a spatially smoothed depth field, affine
/// UV distortion stays sub-pixel.
@MainActor
final class BentPlane {
    let resource: MeshResource
    private let mesh: LowLevelMesh
    /// Vertex counts horizontally and vertically (`cells + 1`).
    private let across: Int, down: Int
    private let uvs: [SIMD2<Float>]

    private struct Vertex {
        var position: SIMD3<Float> = .zero
        var uv: SIMD2<Float> = .zero
    }

    /// Large static bounding box so RealityKit frustum culling never drops the mesh when vertices move in world space.
    private static let bounds = BoundingBox(min: [-500, -500, -500], max: [500, 500, 500])

    /// - Parameters:
    ///   - across, down: Grid cell counts horizontally and vertically.
    ///   - uv: Maps normalized view coordinates (`0...1` from top-left) to the
    ///     atlas UV expected by the RealityKit stereo material.
    init?(across cellsAcross: Int, down cellsDown: Int, uv: (Float, Float) -> SIMD2<Float>) {
        across = cellsAcross + 1
        down = cellsDown + 1
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.indexType = .uint32
        descriptor.vertexCapacity = across * down
        descriptor.indexCapacity = cellsAcross * cellsDown * 6
        var uvs: [SIMD2<Float>] = []
        for row in 0..<down {
            for column in 0..<across { uvs.append(uv(Float(column) / Float(cellsAcross), Float(row) / Float(cellsDown))) }
        }
        self.uvs = uvs
        guard let mesh = try? LowLevelMesh(descriptor: descriptor) else { return nil }
        self.mesh = mesh
        let across = across
        mesh.withUnsafeMutableIndices { bytes in
            let indices = bytes.bindMemory(to: UInt32.self)
            var next = 0
            for row in 0..<cellsDown {
                for column in 0..<cellsAcross {
                    let a = UInt32(row * across + column), b = a + 1                  // top-left, top-right
                    let c = a + UInt32(across), d = c + 1                            // bottom-left, bottom-right
                    // Counter-clockwise winding facing the eye.
                    for index in [a, c, b, b, c, d] {
                        indices[next] = index
                        next += 1
                    }
                }
            }
        }
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: descriptor.indexCapacity, topology: .triangle, bounds: BentPlane.bounds),
        ])
        guard let resource = try? MeshResource(from: mesh) else { return nil }
        self.resource = resource
        place(eye: Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1)),
              frustum: Frustum(left: -1, right: 1, down: -1, up: 1), depth: nil, flatAt: 10)
    }

    /// Updates vertex positions in world space along `eye`'s rays across `frustum`
    /// using per-eye `depth` (`DepthField.seen(by:)`), or places a flat plane at
    /// `flatAt` meters when `depth` is `nil`.
    func place(eye: Pose, frustum: Frustum, depth: DepthField?, flatAt: Float) {
        let origin = SIMD3(eye.position.x, eye.position.y, eye.position.z)
        let right = SIMD3(eye.right.x, eye.right.y, eye.right.z), up = SIMD3(eye.up.x, eye.up.y, eye.up.z)
        let forward = SIMD3(eye.forward.x, eye.forward.y, eye.forward.z)
        let wide = frustum.right - frustum.left, tall = frustum.up - frustum.down
        let across = across, down = down, uvs = uvs
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            let vertices = bytes.bindMemory(to: Vertex.self)
            for row in 0..<down {
                let y = frustum.up - tall * Float(row) / Float(down - 1)
                for column in 0..<across {
                    let x = frustum.left + wide * Float(column) / Float(across - 1)
                    var ahead = flatAt
                    if let depth {
                        ahead = 1 / max(DepthField.range.lowerBound, min(DepthField.range.upperBound, depth.nearness(across: x, up: y)))
                    }
                    let index = row * across + column
                    vertices[index] = Vertex(position: origin + (forward + right * x + up * y) * ahead, uv: uvs[index])
                }
            }
        }
    }
}
#endif
