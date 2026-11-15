// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import QuartzCore
import Spatial
import SwiftUI
import VRLinkCore

/// Tracks indirect spatial pinch events from visionOS and converts them to `SystemPinch`.
///
/// For each pinch made at a distance, visionOS delivers a spatial event
/// carrying an eye-gaze selection ray (the only time the OS exposes where the
/// user is looking). `PinchRays` tracks the latest pinch per hand and formats
/// its ray and press timing for `VRLinkCore`.
public final class PinchRays {
    public init() {}

    private struct Pinch {
        var id: SpatialEventCollection.Event.ID
        /// World-space gaze selection ray origin and unit direction.
        var origin = Vec3(0, 0, 0), direction = Vec3(0, 0, -1)
        /// World-space hand position at pinch start and on the latest update.
        var handAtStart: Vec3?, handNow: Vec3?
        var began: TimeInterval
        var ended: TimeInterval?
        var rayGivenOut = false
    }

    /// Invoked once per pinch when its selection ray is first received, passing
    /// the world-space gaze unit vector on the event delivery thread.
    public var onGaze: ((_ direction: Vec3) -> Void)?

    private let lock = NSLock()
    private var pinches: [Pinch?] = [nil, nil]

    /// Lead time (seconds) to send the gaze ray before asserting the pinch press,
    /// giving the host time to aim at the target before the click registers.
    private static let rayLeadsPress: TimeInterval = 0.05
    /// Minimum press duration in seconds so brief taps still register on the host.
    private static let shortestPress: TimeInterval = 0.05
    /// Hold time (seconds) to keep the gaze ray active after release so the button-up event lands on target.
    private static let rayOutlastsPress: TimeInterval = 0.08

    /// Ingests spatial pinch events from visionOS. CompositorServices delivers
    /// coordinates directly in world space (`toWorld == nil`), whereas RealityKit
    /// delivers SwiftUI gesture coordinates and provides `toWorld` to convert points.
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
                // Assign a new pinch to its reported hand chirality, or fall back
                // to the first idle hand slot when chirality is unspecified.
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
                // Convert the direction by transforming two points along the ray,
                // then re-normalize because SwiftUI point units are sub-millimeter.
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

    /// Returns the current `SystemPinch` state for `side`.
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
