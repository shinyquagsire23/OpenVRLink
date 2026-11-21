// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import RealityKit
import UIKit
import VRLinkCore
import simd

/// Builds double-sided unlit triangle meshes for Room Setup floor overlays and markers.
struct FlatMesh {
    private var positions: [SIMD3<Float>] = []
    private var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let first = UInt32(positions.count)
        positions += [a, b, c]
        indices += [first, first + 1, first + 2, first, first + 2, first + 1]
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
        triangle(a, b, c)
        triangle(a, c, d)
    }

    /// Appends a horizontal line quad from `a` to `b` with the given `width` and `height` offset.
    mutating func line(_ a: Point2, _ b: Point2, width: Float, height: Float = 0) {
        let along = b - a
        guard along.length > 1e-5 else { return }
        let across = Point2(-along.z, along.x) * (width / 2 / along.length)
        func lifted(_ point: Point2) -> SIMD3<Float> { SIMD3(point.x, height, point.z) }
        quad(lifted(a + across), lifted(b + across), lifted(b - across), lifted(a - across))
    }

    /// Appends line segments connecting `points` in order (and closing back to `points[0]` when `closed` is true).
    mutating func path(_ points: [Point2], closed: Bool, width: Float, height: Float = 0) {
        guard points.count >= 2 else { return }
        for index in 0..<(closed ? points.count : points.count - 1) {
            line(points[index], points[(index + 1) % points.count], width: width, height: height)
        }
    }

    /// Appends a horizontal ring of radius `radius` and stroke width `width` around `center`.
    mutating func ring(radius: Float, width: Float, height: Float = 0, around center: Point2 = Point2(0, 0)) {
        path(FloorShape.circle(radius: radius, corners: 96, around: center), closed: true, width: width, height: height)
    }

    @MainActor func resource() -> MeshResource? {
        guard !isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "flat")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}

@MainActor
enum RoomLook {
    /// Line width in meters for the floor grid rings and spokes.
    static let webLine: Float = 0.0025
    /// Spacing in meters and count of concentric floor rings.
    static let ringSpacing: Float = 1, ringCount = 3
    static let postRadius: Float = 0.02
    static let boundaryLine: Float = 0.02
    static let cornerRadius: Float = 0.035
    /// Radius in meters of the brush ring used to paint boundaries in Basic mode.
    static let brushRadius: Float = 0.05
    /// Vertical offset in meters above the floor to prevent z-fighting.
    static let lift: Float = 0.003

    static func unlit(_ color: UIColor) -> UnlitMaterial {
        // Apply alpha via transparent blending rather than base color alpha to avoid double attenuation.
        var material = UnlitMaterial(color: color.withAlphaComponent(1))
        if color.cgColor.alpha < 1 { material.blending = .transparent(opacity: .init(floatLiteral: Float(color.cgColor.alpha))) }
        return material
    }

    static let web = unlit(UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1))
    static let post = unlit(UIColor(red: 0.95, green: 0.95, blue: 1, alpha: 1))
    static let flag = unlit(UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))
    /// Neutral gray material used for inactive rooms.
    static let idle = unlit(UIColor(white: 0.45, alpha: 1))
    static let boundary = unlit(UIColor(red: 0.2, green: 1, blue: 0.6, alpha: 1))
    static let corner = unlit(.white)
    static let firstCorner = unlit(UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1))
    static let ray = unlit(UIColor(red: 1, green: 1, blue: 1, alpha: 0.7))
    static let paint = unlit(UIColor(red: 0.2, green: 1, blue: 0.6, alpha: 0.45))
    static let plate = unlit(UIColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 0.9))
    static let lettering = unlit(.white)

    /// Floor grid centered on a room: three concentric rings spaced 1 m apart with six radial
    /// spokes, a forward (`-z`) arrowhead at 1 m, and a crossbar 1 m behind.
    static let webMesh: MeshResource? = {
        var mesh = FlatMesh()
        let reach = ringSpacing * Float(ringCount)
        for ring in 1...ringCount { mesh.ring(radius: ringSpacing * Float(ring), width: webLine) }
        for spoke in 0..<6 {
            let angle = Float(spoke) * .pi / 3
            // Spoke 0 points along -z so one diameter aligns with the forward/back axis.
            mesh.line(Point2(0, 0), Point2(-sin(angle) * reach, -cos(angle) * reach), width: webLine)
        }
        // Forward (-z) arrowhead at 1 m.
        mesh.triangle(SIMD3(0, 0, -1.12), SIMD3(-0.09, 0, -0.94), SIMD3(0.09, 0, -0.94))
        // Rear (+z) crossbar at 1 m.
        mesh.line(Point2(-0.15, 1), Point2(0.15, 1), width: 0.02)
        return mesh.resource()
    }()

    /// Triangular flag mesh hung from the top of the center post in the forward/up plane.
    static let flagMesh: MeshResource? = {
        var mesh = FlatMesh()
        // Offset two faces slightly with a back spine so the flag remains visible edge-on.
        for side: Float in [-0.004, 0.004] {
            mesh.triangle(SIMD3(side, 0, 0), SIMD3(side, -0.12, 0), SIMD3(0, -0.06, -0.2))
        }
        mesh.quad(SIMD3(-0.004, 0, 0), SIMD3(0.004, 0, 0), SIMD3(0.004, -0.12, 0), SIMD3(-0.004, -0.12, 0))
        return mesh.resource()
    }()
    /// Approximate center of the flag relative to the top of the post before yaw rotation.
    static let flagMiddle = SIMD3<Float>(0, -0.06, -0.08)
    static let flagTip = SIMD3<Float>(0, -0.06, -0.2)

    static let brushMesh: MeshResource? = {
        var mesh = FlatMesh()
        mesh.ring(radius: brushRadius, width: 0.006)
        return mesh.resource()
    }()

    /// Generates a centered flat text entity with font size `height` in meters.
    static func words(_ text: String, height: Float) -> ModelEntity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.0005, font: .systemFont(ofSize: CGFloat(height), weight: .semibold))
        let entity = ModelEntity(mesh: mesh, materials: [lettering])
        let bounds = mesh.bounds
        entity.position = -bounds.center
        return entity
    }
}
#endif
