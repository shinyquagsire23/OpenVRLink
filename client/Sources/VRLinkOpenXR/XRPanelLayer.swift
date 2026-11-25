// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Manages an in-headset 2D UI panel rendered as an `XrCompositionLayerQuad` and driven by pointer rays.
///
/// `XRDisplay` positions the quad in front of the user when it becomes visible, intersects controller and
/// hand pointer rays with the quad to compute pixel coordinates, and composites the panel over the stream.
public final class XRPanelLayer {
    /// Panel dimensions in pixels.
    public let width: Int, height: Int
    /// Physical quad width in meters and placement distance in front of the user's head.
    public var metersWide: Float = 1.3, metersAway: Float = 1.6

    /// Called once per frame on the render thread while visible with the pointer position in pixels from the
    /// top-left corner (`nil` when no ray hits the panel). Returns updated premultiplied sRGB RGBA pixels
    /// (`width * height * 4` bytes, top row first) when the image has changed, or `nil` to reuse the previous
    /// swapchain image.
    public var update: ((_ pointer: (x: Float, y: Float, pressed: Bool)?) -> [UInt8]?)?
    /// Queried each frame on the render thread to check whether the panel should be visible; defaults to
    /// `visible` when `nil`.
    public var isWanted: (() -> Bool)?
    /// Called on the render thread when the menu button has been held for `holdSeconds` so the shell can
    /// toggle the panel during a stream.
    public var onMenuHeld: (() -> Void)?
    public static let holdSeconds = 0.8

    private let lock = NSLock()
    private var shown = true

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Whether the panel is visible. Thread-safe. Repositioned in front of the user each time it becomes visible.
    public var visible: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return shown
        }
        set {
            lock.lock()
            shown = newValue
            lock.unlock()
        }
    }

    /// Whether at least one image has been uploaded to the panel swapchain.
    public internal(set) var hasPicture = false

    // Render-thread state managed by XRDisplay.
    var swapchain: XRSwapchain?
    /// Pose of the quad's center with +Z facing the user, or `nil` when unpositioned.
    var pose: Pose?
    /// Active pointing hand; switches to the other hand when it presses or when the current hand points away.
    var pointing = Side.right
    var menuHeldSince: UInt64?
    var menuReported = false

    /// Computes a level quad pose `metersAway` in front of `head`, facing back toward the user.
    static func placed(before head: Pose, metersAway: Float) -> Pose {
        var ahead = Vec3(head.forward.x, 0, head.forward.z)
        let length = (ahead.x * ahead.x + ahead.z * ahead.z).squareRoot()
        ahead = length > 0.01 ? ahead * (1 / length) : Vec3(0, 0, -1)
        let center = Vec3(head.position.x + ahead.x * metersAway, head.position.y - 0.1, head.position.z + ahead.z * metersAway)
        // Quad +Z (the front face) points back toward the user.
        let up = Vec3(0, 1, 0)
        return Pose(position: center, right: ahead.cross(up), up: up, forward: ahead)
    }

    /// Intersects `ray` with the panel quad at `pose` and returns pixel coordinates from the top-left corner,
    /// or `nil` if the ray misses or points away.
    static func hit(_ ray: Pose, on pose: Pose, metersWide: Float, width: Int, height: Int) -> (x: Float, y: Float)? {
        let facing = ray.forward.dot(pose.forward)
        guard facing > 0.05 else { return nil }
        let distance = (pose.position - ray.position).dot(pose.forward) / facing
        guard distance > 0 else { return nil }
        let across = Vec3(ray.position.x + ray.forward.x * distance - pose.position.x,
                          ray.position.y + ray.forward.y * distance - pose.position.y,
                          ray.position.z + ray.forward.z * distance - pose.position.z)
        let metersHigh = metersWide * Float(height) / Float(width)
        let x = across.dot(pose.right) / metersWide + 0.5, y = 0.5 - across.dot(pose.up) / metersHigh
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x * Float(width), y * Float(height))
    }

    /// Selects the active panel pointer for this frame from the left and right hand rays.
    func pointer(from rays: [XRInput.Pointer?]) -> (x: Float, y: Float, pressed: Bool)? {
        guard let pose else { return nil }
        let hits = rays.map { ray in
            ray.flatMap { found in
                XRPanelLayer.hit(found.ray, on: pose, metersWide: metersWide, width: width, height: height).map { ($0, found.press > 0.6) }
            }
        }
        let other = pointing == .left ? Side.right : Side.left
        // Switch to the other hand if it presses while the active hand isn't pressing, or if the active hand misses.
        if let theirs = hits[other.rawValue], theirs.1 && hits[pointing.rawValue]?.1 != true || hits[pointing.rawValue] == nil {
            pointing = other
            return (theirs.0.x, theirs.0.y, theirs.1)
        }
        return hits[pointing.rawValue].map { ($0.0.x, $0.0.y, $0.1) }
    }
}
