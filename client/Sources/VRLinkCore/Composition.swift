// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Frame composition
///
/// To keep things simple, all composition is handled in world space in meters.
/// Because setting up a world-space renderer for XR is practically the default,
/// this avoids a lot of headache regarding scaling or shader conventions.

/// A rectangle in world space showing part of the decoded frame.
public struct Quad {
    /// World space, meters: top-left, top-right, bottom-left, bottom-right.
    public var corners: [Vec3]
    /// The part of the decoded frame it shows, in texture coordinates
    /// (0...1, origin top-left): left, top, right, bottom.
    public var atlasLeft, atlasTop, atlasRight, atlasBottom: Float
    /// Soft border, as a fraction of the quad's width. 0 for a hard edge.
    public var feather: Float
    /// When set, the quad is this flat color (red, green, blue, alpha in
    /// linear light) instead of showing the decoded frame.
    public var fill: [Float]?

    public init(corners: [Vec3], atlasLeft: Float = 0, atlasTop: Float = 0, atlasRight: Float = 0,
                atlasBottom: Float = 0, feather: Float = 0, fill: [Float]? = nil) {
        self.corners = corners
        self.atlasLeft = atlasLeft; self.atlasTop = atlasTop
        self.atlasRight = atlasRight; self.atlasBottom = atlasBottom
        self.feather = feather
        self.fill = fill
    }

    /// A flat-colored backdrop filling an eye's whole view, `distance`
    /// meters away. It gives the compositor something with depth everywhere,
    /// which it needs before it shows anything.
    public static func backdrop(for view: EyeView, distance: Float, color: [Float]) -> Quad {
        let wide = Frustum(left: view.frustum.left * 1.5, right: view.frustum.right * 1.5,
                           down: view.frustum.down * 1.5, up: view.frustum.up * 1.5)
        return Quad(corners: wide.corners(from: view.eye, distance: distance), fill: color)
    }
}

/// Where one eye is and what it can see, for one displayed frame. Supplied by
/// an XR runtime, or by a window standing in for one.
public struct EyeView {
    public var eye: Pose
    public var frustum: Frustum
    public init(eye: Pose, frustum: Frustum) {
        self.eye = eye
        self.frustum = frustum
    }
}

public enum Eye: Int, CaseIterable {
    case left = 0, right = 1
}

public enum Composition {
    /// Feathered border of the foveal tile, as a fraction of its width.
    static let foveaFeather: Float = 0.06
    /// How far in front of the rendering eye the picture is placed, in meters.
    /// For a head that only turns, any distance looks the same. When the head
    /// has also moved since the host rendered, the picture shifts as a surface
    /// this far away would; far is the safe choice for a scene of unknown depth.
    static let distance: Float = 10

    /// The quads for one eye of a frame, back to front: the base tile, then
    /// the sharper foveal tile over its middle.
    public static func quads(for eye: Eye, metadata: FrameMetadata, profile: DeviceProfile) -> [Quad] {
        // The eye the host rendered from: the head it rendered for, then the eye's place on that head.
        let renderedFrom = metadata.renderPose.placing(profile.eyesInHead[eye.rawValue])
        let base = profile.eyeFrusta[eye.rawValue]
        let fovea = metadata.foveaFrustum(eye: eye.rawValue, base: base)
        // Atlas tiles, top to bottom: left fovea, left base, right fovea, right base.
        let foveaTile = eye.rawValue * 2, baseTile = eye.rawValue * 2 + 1

        func quad(tile: Int, frustum: Frustum, feather: Float) -> Quad {
            // The tile's rows in the atlas, pulled in half a texel so that
            // linear filtering does not reach into the neighboring tile.
            let tiles = Float(metadata.atlasHeight / max(1, metadata.tileHeight))
            let halfTexel = 0.5 / Float(max(1, metadata.atlasHeight))
            return Quad(corners: frustum.corners(from: renderedFrom, distance: distance),
                        atlasLeft: 0, atlasTop: Float(tile) / tiles + halfTexel,
                        atlasRight: 1, atlasBottom: Float(tile + 1) / tiles - halfTexel,
                        feather: feather)
        }
        return [quad(tile: baseTile, frustum: base, feather: 0),
                quad(tile: foveaTile, frustum: fovea, feather: foveaFeather)]
    }
}
