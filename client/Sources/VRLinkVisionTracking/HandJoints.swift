// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import QuartzCore
import VRLinkCore
import simd

/// Tracks bare hands via ARKit and maps skeletons to the 26-joint layout expected by `VRLinkCore`.
public final class HandJoints {
    public init() {}

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private let lock = NSLock()
    /// Most recent tracked skeleton per hand, held briefly if tracking drops out.
    private var last: [(hand: TrackedHand, time: TimeInterval)?] = [nil, nil]

    /// Prediction lookahead for hand anchors, in seconds.
    private static let lead: TimeInterval = 0.030
    /// Duration in seconds to hold the last known hand pose after tracking is lost.
    private static let holdAfterLoss: TimeInterval = 0.5

    public func start() {
        guard HandTrackingProvider.isSupported else { return }
        Task {
            do {
                try await session.run([provider])
            } catch {
                print("hands: could not start hand tracking: \(error)")
            }
        }
    }

    /// ARKit joint names ordered to match `VRLinkCore`: wrist, thumb, and the
    /// four fingers from metacarpal outward. The palm joint (not provided by
    /// ARKit) is prepended separately.
    private static let names: [HandSkeleton.JointName] = [
        .wrist,
        .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip,
        .indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase,
        .indexFingerIntermediateTip, .indexFingerTip,
        .middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase,
        .middleFingerIntermediateTip, .middleFingerTip,
        .ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase,
        .ringFingerIntermediateTip, .ringFingerTip,
        .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase,
        .littleFingerIntermediateTip, .littleFingerTip,
    ]

    private func hand(_ anchor: HandAnchor?, _ side: Side) -> TrackedHand? {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        var joints: [Pose] = []
        for name in HandJoints.names {
            // Include occluded joints (`!joint.isTracked`) using ARKit's estimated transform.
            let joint = skeleton.joint(name)
            let m = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            func axis(_ column: SIMD4<Float>) -> Vec3 { Vec3(column.x, column.y, column.z) }
            // ARKit mirrors joint basis axes between hands: +X runs along the
            // bone toward the fingertip on the left hand and away from it on
            // the right; +Y points out of the palm on the left hand and out of
            // the back of the hand on the right; -Z matches VRLinkCore's right axis.
            let sign: Float = side == .left ? 1 : -1
            joints.append(Pose(position: axis(m.columns.3), right: axis(m.columns.2) * -1,
                               up: axis(m.columns.1) * -sign, forward: axis(m.columns.0) * sign))
        }
        // Synthesize the palm joint at the midpoint of the middle metacarpal with the same orientation.
        var palm = joints[10]
        palm.position = (joints[10].position + joints[11].position) * 0.5
        return TrackedHand(joints: [palm] + joints)
    }

    /// Returns predicted `[left, right]` hand skeletons, or `nil` for any untracked hand past the hold timeout.
    public func hands() -> [TrackedHand?] {
        guard provider.state == .running else { return [nil, nil] }
        // Serialize queries because ARKit does not allow concurrent prediction calls.
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let anchors = provider.handAnchors(at: now + HandJoints.lead)
        return Side.allCases.map { side in
            if let hand = hand(side == .left ? anchors.leftHand : anchors.rightHand, side) {
                last[side.rawValue] = (hand, now)
                return hand
            }
            guard let held = last[side.rawValue], now - held.time < HandJoints.holdAfterLoss else { return nil }
            return held.hand
        }
    }
}
#endif
