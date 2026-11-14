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
    /// Which of the frame's decoded pictures it shows.
    public var picture: Int

    public init(corners: [Vec3], atlasLeft: Float = 0, atlasTop: Float = 0, atlasRight: Float = 0,
                atlasBottom: Float = 0, feather: Float = 0, fill: [Float]? = nil, picture: Int = 0) {
        self.picture = picture
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

/// What a frame's pictures show, whichever protocol brought them: for each
/// eye, where the host's eye was when it rendered, and the tiles that make
/// up its view. A tile is a part of one decoded picture and the part of
/// the eye's view it fills.
public struct FrameLayout {
    public struct Tile {
        /// What the tile covers, seen from the rendering eye.
        public var frustum: Frustum
        /// Which decoded picture it is cut from, and where (0...1, origin top-left).
        public var picture: Int
        public var left, top, right, bottom: Float
        /// Soft border, as a fraction of its width.
        public var feather: Float

        public init(frustum: Frustum, picture: Int = 0, left: Float = 0, top: Float = 0, right: Float = 1,
                    bottom: Float = 1, feather: Float = 0) {
            self.frustum = frustum
            self.picture = picture
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
            self.feather = feather
        }
    }

    public struct View {
        /// The eye the host rendered from, in world space.
        public var eye: Pose
        /// Back to front.
        public var tiles: [Tile]

        public init(eye: Pose, tiles: [Tile]) {
            self.eye = eye
            self.tiles = tiles
        }
    }

    /// Left, right.
    public var views: [View]
    /// How many pictures a decoder must produce for one frame.
    public var pictures: Int
    /// One eye's whole view in pixels at the stream's finest detail: what a
    /// renderer that flattens a view into a texture should size it from.
    public var eyePixels: (width: Int, height: Int)

    public init(views: [View], pictures: Int = 1, eyePixels: (width: Int, height: Int)) {
        self.views = views
        self.pictures = pictures
        self.eyePixels = eyePixels
    }

    /// No picture at all; for tests and placeholders.
    public static let empty = FrameLayout(views: [], eyePixels: (0, 0))
}

public enum Composition {
    /// How far in front of the rendering eye the picture is placed, in meters.
    /// For a head that only turns, any distance looks the same. When the head
    /// has also moved since the host rendered, the picture shifts as a surface
    /// this far away would; far is the safe choice for a scene of unknown depth.
    static let distance: Float = 10

    /// The quads for one eye of a frame, back to front.
    public static func quads(for eye: Eye, layout: FrameLayout) -> [Quad] {
        guard layout.views.indices.contains(eye.rawValue) else { return [] }
        let view = layout.views[eye.rawValue]
        return view.tiles.map { tile in
            Quad(corners: tile.frustum.corners(from: view.eye, distance: distance),
                 atlasLeft: tile.left, atlasTop: tile.top, atlasRight: tile.right, atlasBottom: tile.bottom,
                 feather: tile.feather, picture: tile.picture)
        }
    }
}
