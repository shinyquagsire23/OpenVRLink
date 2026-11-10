// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import QuartzCore
import VRLinkCore
import simd

/// Where the head is, from ARKit world tracking.
///
/// visionOS splits what OpenXR keeps in one API: head (and hand) poses come
/// from ARKit, controller buttons from GameController, frame timing from
/// CompositorServices. This file is only the first of those.
public final class HeadTracking {
    public init() {}

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    private let lock = NSLock()
    private var previous: (pose: Pose, time: TimeInterval)?
    /// The middle of the two eyes relative to the device anchor, in meters.
    /// The host expects the head pose there (the OpenXR "view" convention).
    private var eyeMidpoint = SIMD3<Float>(0, 0, 0)
    /// The midpoint as it was when the session began. Velocities are measured
    /// at this fixed point, so that a glance to the side, which moves the
    /// live midpoint quickly, is not reported to the host as the head moving.
    private var steadyMidpoint = SIMD3<Float>(0, 0, 0)

    /// The head pose last given out by `trackedHead`.
    private var latest: Pose?

    /// Where the head was a moment ago, without asking ARKit again.
    public func latestHead() -> Pose? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public func start() {
        Task {
            do {
                try await session.run([worldTracking])
            } catch {
                print("tracking: could not start world tracking: \(error)")
            }
        }
    }

    public func setEyeMidpoint(_ midpoint: SIMD3<Float>, atConnect: Bool) {
        lock.lock()
        eyeMidpoint = midpoint
        if atConnect { steadyMidpoint = midpoint }
        lock.unlock()
    }

    /// The device anchor for a display time. ARKit answers nil beyond its
    /// prediction horizon, so step back 5 ms at a time until it answers.
    public func anchor(at time: TimeInterval) -> DeviceAnchor? {
        var target = time
        for _ in 0..<10 {
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: target) { return anchor }
            target -= 0.005
        }
        return nil
    }

    /// A matrix whose columns are a frame's right, up and backward axes and
    /// its position, as a pose.
    public static func pose(_ m: simd_float4x4) -> Pose {
        func vector(_ column: SIMD4<Float>) -> Vec3 { Vec3(column.x, column.y, column.z) }
        return Pose(position: vector(m.columns.3), right: vector(m.columns.0), up: vector(m.columns.1),
                    forward: vector(m.columns.2) * -1)
    }

    /// The head as it is right now, with velocities measured since the last call.
    public func trackedHead() -> TrackedPose? {
        let now = CACurrentMediaTime()
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: now) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Move from the device anchor to a point given along the device's own axes.
        func head(at point: SIMD3<Float>) -> Pose {
            var m = anchor.originFromAnchorTransform
            m.columns.3 += m.columns.0 * point.x + m.columns.1 * point.y + m.columns.2 * point.z
            return HeadTracking.pose(m)
        }
        let pose = head(at: steadyMidpoint)
        var tracked = TrackedPose(pose: pose)
        if let previous, now > previous.time {
            tracked = tracked.withVelocities(since: previous.pose, seconds: Float(now - previous.time))
        }
        // Where the head is: the middle of the eyes as they are now.
        tracked.pose = head(at: eyeMidpoint)
        previous = (pose, now)
        latest = tracked.pose
        return tracked
    }
}
#endif
