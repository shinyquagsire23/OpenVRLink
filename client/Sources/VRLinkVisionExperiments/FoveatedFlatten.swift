// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import Metal
import RealityKit
import VRLinkCore
import VRLinkMetal
import simd

/// Manages the foveated render target (`FoveatedTarget`) and per-eye display
/// meshes for the RealityKit renderer, adapted from the ALVR visionOS client.
///
/// A foveated texture must be dewarped for display. Instead of running an
/// extra render pass, each eye's plane is a subdivided grid mesh whose vertex
/// UVs map directly to the corresponding positions in the compressed texture.
@MainActor
struct FoveatedFlatten {
    let target: FoveatedTarget
    /// Per-eye meshes (left, then right), each a 1x1 plane in the XZ plane matching
    /// `MeshResource.generatePlane(width: 1, depth: 1)` with the top of the image at -z.
    let meshes: [MeshResource]

    private struct Vertex {
        var position: SIMD3<Float> = .zero
        var uv: SIMD2<Float> = .zero
    }

    init?(device: MTLDevice, frusta: [Frustum]) {
        guard let target = FoveatedTarget(device: device, frusta: frusta) else { return nil }
        self.target = target
        var meshes: [MeshResource] = []
        for eye in Eye.allCases {
            guard let mesh = try? FoveatedFlatten.mesh(for: eye, target: target) else { return nil }
            meshes.append(mesh)
        }
        self.meshes = meshes
    }

    private static func mesh(for eye: Eye, target: FoveatedTarget) throws -> MeshResource {
        // Use a 2x2 quad subdivision per foveation zone. Because compression
        // curves smoothly within a zone, quads of this size approximate the
        // mapping to within a fraction of a pixel.
        let across = Foveation.zonesAcross * 2 + 1, down = Foveation.zonesDown * 2 + 1
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.indexType = .uint32
        descriptor.vertexCapacity = across * down
        descriptor.indexCapacity = (across - 1) * (down - 1) * 6
        let mesh = try LowLevelMesh(descriptor: descriptor)

        mesh.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            let vertices = bytes.bindMemory(to: Vertex.self)
            for row in 0..<down {
                for column in 0..<across {
                    // Normalized [0, 1] image coordinates for this vertex, measured from top-left.
                    let x = Float(column) / Float(across - 1), y = Float(row) / Float(down - 1)
                    let (fromLeft, fromTop) = target.stored(eye, x: x, y: y)
                    // The stereo material expects a standard plane displaying half of the
                    // stacked texture: its V coordinate runs bottom-to-top, scales V by 0.5,
                    // and adds 0.5 for the right eye. Pre-invert those adjustments here so
                    // the shader samples the target UV computed above.
                    let fromBottom = 1 - fromTop
                    let v = eye == .left ? fromBottom * 2 : fromBottom * 2 - 1
                    vertices[row * across + column] = Vertex(position: [x - 0.5, 0, y - 0.5], uv: [fromLeft, v])
                }
            }
        }
        mesh.withUnsafeMutableIndices { bytes in
            let indices = bytes.bindMemory(to: UInt32.self)
            var next = 0
            for row in 0..<down - 1 {
                for column in 0..<across - 1 {
                    let a = UInt32(row * across + column), b = a + 1                  // this row: left, right
                    let c = a + UInt32(across), d = c + 1                            // the next row (further +z)
                    // Wind triangles counter-clockwise as viewed from +y (the visible face).
                    for index in [a, c, b, b, c, d] {
                        indices[next] = index
                        next += 1
                    }
                }
            }
        }
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: descriptor.indexCapacity, topology: .triangle,
                              bounds: BoundingBox(min: [-0.5, 0, -0.5], max: [0.5, 0, 0.5])),
        ])
        return try MeshResource(from: mesh)
    }
}
#endif
