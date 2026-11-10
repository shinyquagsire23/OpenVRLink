// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import ARKit
import QuartzCore
import VRLinkCore
import simd

/// Bare hands, from ARKit hand tracking, as the 26 joints the core wants.
public final class HandJoints {
    public init() {}

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private let lock = NSLock()
    /// The last hand seen on each side, shown a little longer when tracking drops out.
    private var last: [(hand: TrackedHand, time: TimeInterval)?] = [nil, nil]

    /// How far ahead hands are predicted, in seconds
    private static let lead: TimeInterval = 0.030
    /// How long a hand that has stopped being tracked stays where it was.
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

    /// ARKit's joints in the core's order: wrist, thumb, then four fingers
    /// from the palm outwards. (The palm joint, which ARKit lacks, is added in front.)
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
            // A joint hidden behind the rest of the hand is still given, as
            // ARKit's best estimate; it is used as it is.
            let joint = skeleton.joint(name)
            let m = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            func axis(_ column: SIMD4<Float>) -> Vec3 { Vec3(column.x, column.y, column.z) }
            // ARKit's joint axes are mirrored between the hands. Its x axis
            // runs along the finger: towards the tip on the left hand, away
            // from it on the right. Its y axis comes out of the palm on the
            // left hand and out of the back of the hand on the right. Its
            // z axis points to the same side as the core's "right", reversed.
            let sign: Float = side == .left ? 1 : -1
            joints.append(Pose(position: axis(m.columns.3), right: axis(m.columns.2) * -1,
                               up: axis(m.columns.1) * -sign, forward: axis(m.columns.0) * sign))
        }
        // A palm joint: halfway along the middle finger's first bone, facing as that bone does.
        var palm = joints[10]
        palm.position = (joints[10].position + joints[11].position) * 0.5
        return TrackedHand(joints: [palm] + joints)
    }

    /// Both hands a moment from now: left then right, nil when not tracked.
    public func hands() -> [TrackedHand?] {
        guard provider.state == .running else { return [nil, nil] }
        // One caller at a time: ARKit's prediction calls must not overlap.
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
