// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Frame composition
///
/// To keep things simple, all composition is handled in world space in meters.
/// Because setting up a world-space renderer for XR is practically the default,
/// this avoids a lot of headache regarding scaling or shader conventions.

/// UV region in a decoded picture that supplies alpha for premultiplied-alpha
/// streams where opacity is packed separately from RGB. Coordinates are normalized
/// (`0...1`, origin top-left), and the luma channel gives the opacity.
public struct AlphaSource {
    public var picture: Int
    public var left, top, right, bottom: Float

    public init(picture: Int, left: Float, top: Float, right: Float, bottom: Float) {
        self.picture = picture
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

/// A world-space quad that renders a region of a decoded video frame (or a solid color).
public struct Quad {
    /// Corner positions in world space (meters), ordered top-left, top-right, bottom-left, bottom-right.
    public var corners: [Vec3]
    /// Normalized texture coordinates (`0...1`, origin top-left) for the sampled region.
    public var atlasLeft, atlasTop, atlasRight, atlasBottom: Float
    /// Edge feathering width as a fraction of the quad's width (`0` for a hard edge).
    public var feather: Float
    /// Optional solid linear RGBA fill color used instead of sampling a decoded picture.
    public var fill: [Float]?
    /// Index of the decoded picture to sample.
    public var picture: Int
    /// Separate alpha source when the stream carries transparency.
    public var alpha: AlphaSource?
    /// Optional mesh grid used to warp the quad to scene depth instead of drawing a flat plane between `corners`.
    public var grid: Grid?

    /// Subdivides a quad into `columns` x `rows` cells, placing each vertex at
    /// its estimated depth along the rendering eye's ray. Texture coordinates are
    /// projected from the rendering eye, so the mesh matches a flat quad from the
    /// rendered pose and produces depth parallax when the user's head translates.
    public struct Grid {
        public var columns: Int, rows: Int
        /// World-space positions of the `(rows + 1) * (columns + 1)` grid vertices in row-major order starting at the top-left.
        public var points: [Vec3]
        /// Forward distance in meters from the rendering eye for each vertex in `points`, used for projective UV interpolation.
        public var ahead: [Float]

        public init(columns: Int, rows: Int, points: [Vec3], ahead: [Float]) {
            self.columns = columns
            self.rows = rows
            self.points = points
            self.ahead = ahead
        }
    }

    public init(corners: [Vec3], atlasLeft: Float = 0, atlasTop: Float = 0, atlasRight: Float = 0,
                atlasBottom: Float = 0, feather: Float = 0, fill: [Float]? = nil, picture: Int = 0,
                alpha: AlphaSource? = nil, grid: Grid? = nil) {
        self.picture = picture
        self.alpha = alpha
        self.grid = grid
        self.corners = corners
        self.atlasLeft = atlasLeft; self.atlasTop = atlasTop
        self.atlasRight = atlasRight; self.atlasBottom = atlasBottom
        self.feather = feather
        self.fill = fill
    }

    /// Creates a solid-color backdrop quad covering the eye's full field of view at `distance`
    /// meters, ensuring every pixel has valid depth for the platform compositor.
    public static func backdrop(for view: EyeView, distance: Float, color: [Float]) -> Quad {
        let wide = Frustum(left: view.frustum.left * 1.5, right: view.frustum.right * 1.5,
                           down: view.frustum.down * 1.5, up: view.frustum.up * 1.5)
        return Quad(corners: wide.corners(from: view.eye, distance: distance), fill: color)
    }
}

/// Pose and projection frustum for a single eye on a given display frame,
/// provided by the XR runtime (or a window renderer in flat-screen mode).
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

/// Protocol-independent layout describing how a video frame's decoded pictures map
/// to each eye's view. Each eye has the pose used by the host when rendering and an
/// ordered list of tiles mapping UV regions of decoded pictures to view frusta.
public struct FrameLayout {
    public struct Tile {
        /// View frustum covered by this tile relative to the rendering eye pose.
        public var frustum: Frustum
        /// Decoded picture index and normalized UV bounds (`0...1`, origin top-left).
        public var picture: Int
        public var left, top, right, bottom: Float
        /// Edge feathering width as a fraction of the tile's width.
        public var feather: Float
        /// Separate alpha source when the stream carries transparency.
        public var alpha: AlphaSource?

        public init(frustum: Frustum, picture: Int = 0, left: Float = 0, top: Float = 0, right: Float = 1,
                    bottom: Float = 1, feather: Float = 0, alpha: AlphaSource? = nil) {
            self.alpha = alpha
            self.frustum = frustum
            self.picture = picture
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
            self.feather = feather
        }
    }

    public struct View {
        /// World-space eye pose used by the host when rendering this view.
        public var eye: Pose
        /// Tiles ordered back-to-front.
        public var tiles: [Tile]

        public init(eye: Pose, tiles: [Tile]) {
            self.eye = eye
            self.tiles = tiles
        }
    }

    /// Per-eye views ordered `[left, right]`.
    public var views: [View]
    /// Number of decoded pictures required per frame.
    public var pictures: Int
    /// Effective per-eye resolution in pixels at peak stream density, used to size intermediate render targets.
    public var eyePixels: (width: Int, height: Int)
    /// Encoding gamma applied by the host to this frame's sRGB values (`HostExtensions`).
    /// The renderer restores the original values with `value^encodingGamma` (`1` means no gamma adjustment).
    public var encodingGamma: Float = 1

    public init(views: [View], pictures: Int = 1, eyePixels: (width: Int, height: Int)) {
        self.views = views
        self.pictures = pictures
        self.eyePixels = eyePixels
    }

    /// Midpoint pose between the left and right rendering eyes, using the left
    /// eye's orientation. Returns `nil` unless `views` contains two eyes.
    public var middle: Pose? {
        guard views.count == 2 else { return nil }
        var pose = views[0].eye
        pose.position = (views[0].eye.position + views[1].eye.position) * 0.5
        return pose
    }

    /// Whether any tile carries an alpha channel for passthrough compositing (skipping the opaque black backdrop).
    public var transparent: Bool { views.contains { $0.tiles.contains { $0.alpha != nil } } }

    /// Empty layout used for tests and initial placeholders.
    public static let empty = FrameLayout(views: [], eyePixels: (0, 0))
}

public enum Composition {
    /// Projection distance in meters in front of the rendering eye. Pure rotation
    /// is invariant to distance, while head translation since the frame was rendered
    /// reprojects as a plane at this depth; 10 m is a comfortable default when scene depth is unknown.
    public static let distance: Float = 10

    /// Distance in meters where the debug depth colormap saturates to pure blue.
    public static let farthestColored: Float = 7

    /// Maps a distance in meters to an RGB debug color, sweeping from red at 0 m
    /// through yellow, green, and cyan to blue at `farthestColored` meters and beyond.
    public static func color(forDistance meters: Float) -> [Float] {
        // Sweep two-thirds of the HSV hue wheel at full saturation and value.
        let turn = max(0, min(1, meters / farthestColored)) * 4          // 0 red, 1 yellow, 2 green, 3 cyan, 4 blue
        let part = turn - turn.rounded(.down)
        switch Int(turn) {
        case 0: return [1, part, 0]
        case 1: return [1 - part, 1, 0]
        case 2: return [0, 1, part]
        case 3: return [0, 1 - part, 1]
        default: return [0, 0, 1]
        }
    }

    /// Builds translucent solid-color debug quads visualizing `depth` for `eye`.
    /// Each grid cell produces one quad colored by `color(forDistance:)` and placed
    /// slightly closer than the estimated surface depth so it renders on top of the video.
    public static func picture(of depth: DepthField, for eye: Eye, layout: FrameLayout) -> [Quad] {
        guard layout.views.indices.contains(eye.rawValue), depth.columns > 0, depth.rows > 0 else { return [] }
        let view = layout.views[eye.rawValue], depth = depth.fitted(to: layout)
        let wide = (depth.window.right - depth.window.left) / Float(depth.columns)
        let tall = (depth.window.up - depth.window.down) / Float(depth.rows)
        // Shift cell tangents horizontally from the cyclopean midpoint to this eye using half-IPD disparity.
        let aside = (eye == .left ? 0.5 : -0.5) * depth.apart
        var quads: [Quad] = []
        for row in 0..<depth.rows {
            for column in 0..<depth.columns {
                let nearness = max(DepthField.range.lowerBound, min(DepthField.range.upperBound, depth.nearness[row * depth.columns + column]))
                let left = depth.window.left + Float(column) * wide + aside * nearness
                let up = depth.window.up - Float(row) * tall
                // Inset each cell slightly so the grid structure remains visible.
                let cell = Frustum(left: left + wide * 0.08, right: left + wide * 0.92, down: up - tall * 0.92, up: up - tall * 0.08)
                quads.append(Quad(corners: cell.corners(from: view.eye, distance: 0.97 / nearness),
                                  fill: color(forDistance: 1 / nearness) + [0.55]))
            }
        }
        return quads
    }

    /// `cell` sets the maximum tangent span per warped mesh cell (~2.3 degrees, roughly
    /// matching the finest depth grid), and `mostCells` caps subdivisions per axis.
    static let cell: Float = 0.04, mostCells = 64

    /// Builds world-space quads for `eye` ordered back-to-front. When `depth` is
    /// `nil`, quads are flat planes `distance` meters in front of the rendering
    /// eye; when `depth` is provided, each quad carries a `Quad.Grid` warped to
    /// the estimated scene depth.
    public static func quads(for eye: Eye, layout: FrameLayout, depth: DepthField? = nil) -> [Quad] {
        guard layout.views.indices.contains(eye.rawValue) else { return [] }
        let view = layout.views[eye.rawValue]
        // Reproject the depth field from the earlier frame's pose to this frame's rendering eye.
        let seen = depth?.fitted(to: layout).seen(by: eye)
        return view.tiles.enumerated().map { index, tile in
            var quad = Quad(corners: tile.frustum.corners(from: view.eye, distance: distance),
                            atlasLeft: tile.left, atlasTop: tile.top, atlasRight: tile.right, atlasBottom: tile.bottom,
                            feather: tile.feather, picture: tile.picture, alpha: tile.alpha)
            guard let seen else { return quad }
            // Stereo vertex amplification draws corresponding left and right tiles in a single
            // indexed draw call, so both eyes must share the grid dimensions needed by the wider tile.
            let frusta = layout.views.compactMap { $0.tiles.indices.contains(index) ? $0.tiles[index].frustum : nil }
            func cells(_ extent: (Frustum) -> Float) -> Int {
                max(1, min(mostCells, Int(((frusta.map(extent).max() ?? 0) / cell).rounded(.up))))
            }
            let columns = cells { $0.right - $0.left }, rows = cells { $0.up - $0.down }
            var grid = Quad.Grid(columns: columns, rows: rows, points: [], ahead: [])
            for row in 0...rows {
                let up = tile.frustum.up - (tile.frustum.up - tile.frustum.down) * Float(row) / Float(rows)
                for column in 0...columns {
                    let across = tile.frustum.left + (tile.frustum.right - tile.frustum.left) * Float(column) / Float(columns)
                    let ahead = 1 / max(DepthField.range.lowerBound, min(DepthField.range.upperBound, seen.nearness(across: across, up: up)))
                    grid.points.append(view.eye.position + (view.eye.forward + view.eye.right * across + view.eye.up * up) * ahead)
                    grid.ahead.append(ahead)
                }
            }
            quad.grid = grid
            return quad
        }
    }
}
