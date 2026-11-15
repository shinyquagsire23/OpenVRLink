// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import QuartzCore
import VRLinkCore
import simd

/// Tracks the user's head pose using ARKit `WorldTrackingProvider`.
///
/// visionOS splits OpenXR's unified tracking and frame loop across several
/// frameworks: ARKit provides head and hand poses, GameController provides
/// button state, and CompositorServices drives frame timing. `HeadTracking`
/// handles the ARKit world-tracking portion.
public final class HeadTracking {
    public init() {}

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    private let lock = NSLock()
    private var previous: (pose: Pose, time: TimeInterval)?
    /// Midpoint between the eyes in device-anchor coordinates (meters).
    /// The host expects the head pose at this point (matching OpenXR's view space).
    private var eyeMidpoint = SIMD3<Float>(0, 0, 0)
    /// Eye midpoint captured at session start. Velocities are measured at this
    /// fixed offset so rapid eye movements (which shift the live eye midpoint)
    /// are not reported to the host as head velocity.
    private var steadyMidpoint = SIMD3<Float>(0, 0, 0)

    /// Most recent head pose returned by `trackedHead()`.
    private var latest: Pose?

    /// Returns the most recently sampled head pose without querying ARKit again.
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

    /// Queries the device anchor for a target display timestamp. ARKit returns
    /// `nil` beyond its prediction horizon, so this steps back in 5 ms increments
    /// until a valid anchor is returned.
    public func anchor(at time: TimeInterval) -> DeviceAnchor? {
        var target = time
        for _ in 0..<10 {
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: target) { return anchor }
            target -= 0.005
        }
        return nil
    }

    /// Converts a right-handed transform matrix (columns: right, up, backward, position) into a `Pose`.
    public static func pose(_ m: simd_float4x4) -> Pose {
        func vector(_ column: SIMD4<Float>) -> Vec3 { Vec3(column.x, column.y, column.z) }
        return Pose(position: vector(m.columns.3), right: vector(m.columns.0), up: vector(m.columns.1),
                    forward: vector(m.columns.2) * -1)
    }

    /// Samples the current head pose and computes velocities relative to the previous sample.
    public func trackedHead() -> TrackedPose? {
        let now = CACurrentMediaTime()
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: now) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Offset the device anchor position by a local-space vector.
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
        // Report position at the current live eye midpoint while keeping steady-point velocities.
        tracked.pose = head(at: eyeMidpoint)
        previous = (pose, now)
        latest = tracked.pose
        return tracked
    }
}
#endif
