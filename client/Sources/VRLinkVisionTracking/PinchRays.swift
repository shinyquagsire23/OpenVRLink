// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import QuartzCore
import Spatial
import SwiftUI
import VRLinkCore

/// Pinches as visionOS reports them to an app: a "spatial event" for each
/// pinch of a hand that is not touching anything, which carries a ray from
/// the eyes to what they were looking at. The system reports where the eyes
/// look only at these pinches. This class keeps the newest pinch of each hand
/// and gives it out as the core's `SystemPinch`.
public final class PinchRays {
    public init() {}

    private struct Pinch {
        var id: SpatialEventCollection.Event.ID
        /// The ray from the eyes, world space.
        var origin = Vec3(0, 0, 0), direction = Vec3(0, 0, -1)
        /// Where the pinching fingers were when the pinch began, and are now.
        var handAtStart: Vec3?, handNow: Vec3?
        var began: TimeInterval
        var ended: TimeInterval?
        var rayGivenOut = false
    }

    /// Called once for each pinch, when its ray is first known, with the
    /// ray's direction in world space: the one moment the system says where
    /// the eyes look. Called on the thread that brought the events.
    public var onGaze: ((_ direction: Vec3) -> Void)?

    private let lock = NSLock()
    private var pinches: [Pinch?] = [nil, nil]

    /// The host is shown the ray this long before the press, so that the
    /// press lands where the ray points and not where the hand ray was.
    private static let rayLeadsPress: TimeInterval = 0.05
    /// A press lasts at least this long, however quick the pinch.
    private static let shortestPress: TimeInterval = 0.05
    /// The ray stays this long after the press is let go, so that the
    /// release also lands on it.
    private static let rayOutlastsPress: TimeInterval = 0.08

    /// Take in the events the system gave. A compositor layer is given them
    /// in world space already; a RealityKit view is given them in SwiftUI's
    /// coordinates and supplies `toWorld` to convert a point.
    public func handle(_ events: SpatialEventCollection, toWorld: ((Point3D) -> SIMD3<Float>)? = nil) {
        func world(_ point: Point3D) -> Vec3 {
            let p = toWorld?(point) ?? SIMD3(Float(point.x), Float(point.y), Float(point.z))
            return Vec3(p.x, p.y, p.z)
        }
        let now = CACurrentMediaTime()
        var gazes: [Vec3] = []
        lock.lock()
        defer {
            lock.unlock()
            gazes.forEach { onGaze?($0) }
        }
        for event in events where event.kind == .indirectPinch {
            var side = pinches.firstIndex { $0?.id == event.id }
            if side == nil {
                guard event.phase == .active else { continue }
                // A new pinch: the system usually says which hand. When it
                // does not, it is given to the first hand without a pinch.
                switch event.chirality {
                case .left: side = Side.left.rawValue
                case .right: side = Side.right.rawValue
                default: side = pinches.firstIndex { $0 == nil || $0?.ended != nil }
                }
                guard let side else { continue }
                pinches[side] = Pinch(id: event.id, began: now)
            }
            guard let side, var pinch = pinches[side] else { continue }
            if let ray = event.selectionRay {
                pinch.origin = world(ray.origin)
                // A direction is the difference of two converted points.
                // In SwiftUI's coordinates that difference is under a
                // millimeter long, so it is made a unit vector again.
                let pointing = world(ray.origin + ray.direction) - pinch.origin
                let size = pointing.dot(pointing).squareRoot()
                if size > 0 { pinch.direction = pointing * (1 / size) }
                if size > 0, !pinch.rayGivenOut {
                    pinch.rayGivenOut = true
                    gazes.append(pinch.direction)
                }
            }
            if let hand = event.inputDevicePose?.pose3D.position {
                let position = world(hand)
                if pinch.handAtStart == nil { pinch.handAtStart = position }
                pinch.handNow = position
            }
            if event.phase != .active, pinch.ended == nil { pinch.ended = now }
            pinches[side] = pinch
        }
    }

    /// What `side`'s hand is doing right now.
    public func pinch(_ side: Side) -> SystemPinch {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard let pinch = pinches[side.rawValue] else { return .notPinching }
        let pressStarts = pinch.began + PinchRays.rayLeadsPress
        let pressEnds = pinch.ended.map { max($0, pressStarts + PinchRays.shortestPress) } ?? .infinity
        if now > pressEnds + PinchRays.rayOutlastsPress {
            pinches[side.rawValue] = nil
            return .notPinching
        }
        var travel = Vec3(0, 0, 0)
        if let start = pinch.handAtStart, let current = pinch.handNow { travel = current - start }
        return .pinching(ray: SystemPinch.ray(origin: pinch.origin, direction: pinch.direction, handTravel: travel),
                         pressed: now >= pressStarts && now < pressEnds)
    }

    public func forgetAll() {
        lock.lock()
        pinches = [nil, nil]
        lock.unlock()
    }
}
#endif
