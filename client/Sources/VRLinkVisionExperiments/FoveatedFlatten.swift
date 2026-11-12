// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import Metal
import RealityKit
import VRLinkCore
import VRLinkMetal
import simd

/// The RealityKit renderer's flattened picture, drawn foveated
/// (`FoveatedTarget`), and the planes that show it. After the ALVR visionOS
/// client.
///
/// A foveated texture has to be stretched back out to be shown. That is
/// done here without another pass: each eye's plane is a mesh of small
/// squares, and every corner is given the place in the squeezed texture
/// that belongs to its place in the picture.
@MainActor
struct FoveatedFlatten {
    let target: FoveatedTarget
    /// The plane for each eye (left, right): 1 by 1 lying in x and z like
    /// `MeshResource.generatePlane(width: 1, depth: 1)`, the top of the
    /// picture at -z.
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
        // Two squares to a zone each way: the squeezing bends within a
        // zone, and straight edges this short follow it to a small part
        // of a pixel.
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
                    // Where this corner is in the eye's picture, 0 ... 1 from its left and from its top.
                    let x = Float(column) / Float(across - 1), y = Float(row) / Float(down - 1)
                    let (fromLeft, fromTop) = target.stored(eye, x: x, y: y)
                    // The stereo material was made for a plain plane showing
                    // half of the texture: it halves v, and for the right
                    // eye adds a half; and its v runs up from the bottom of
                    // the texture. The v given here undoes all three, so
                    // that what it samples is the place worked out above.
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
                    // Counter-clockwise seen from +y, the side the plane shows.
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
