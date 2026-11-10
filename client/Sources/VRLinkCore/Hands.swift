// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A tracked bare hand, and other hand-relative bits
/// (docs/svl-tracking-input/skeleton.md and controllers.md).
///
/// The host wants three things for a hand: the wrist as if it were a
/// controller, a few gestures as that controller's buttons, and the finger
/// joints as SteamVR's 31-bone hand skeleton.

/// The joints of one hand in world space, in OpenXR's order and convention:
/// each joint's `forward` points towards the fingertip and its `up` points
/// out of the back of the hand.
public struct TrackedHand {
    public var joints: [Pose]
    /// Set when the platform itself says when this hand pinches (see
    /// `SystemPinch`): the pinch is then no longer read off the joints.
    public var systemPinch: SystemPinch?

    /// 26 joints: palm, wrist, then metacarpal-to-tip for thumb (4 joints)
    /// and index, middle, ring, little (5 each).
    public init(joints: [Pose]) {
        precondition(joints.count == TrackedHand.jointCount)
        self.joints = joints
    }

    /// A flat, open hand with its fingers together, for viewers and tests
    /// that have no hand tracking: every joint faces the way the wrist does.
    public static func flat(wrist: Pose, side: Side) -> TrackedHand {
        func joint(across: Float, ahead: Float) -> Pose {
            var pose = wrist
            // Palm down, the thumb is on the inner side: to the right for a left hand.
            pose.position = wrist.position + wrist.right * (side == .left ? across : -across) + wrist.forward * ahead
            return pose
        }
        var joints = [joint(across: 0, ahead: 0.05), wrist]
        joints += [0.02, 0.05, 0.08, 0.10].map { joint(across: 0.04, ahead: $0) }                 // thumb
        for across: Float in [0.02, 0, -0.02, -0.04] {                                            // index ... little
            joints += [0.03, 0.09, 0.13, 0.155, 0.175].map { joint(across: across, ahead: $0) }
        }
        return TrackedHand(joints: joints)
    }

    public static let jointCount = 26
    static let wrist = 1, thumbTip = 5
    /// For finger 0...3 (index, middle, ring, little).
    static func proximal(_ finger: Int) -> Int { 7 + 5 * finger }
    static func tip(_ finger: Int) -> Int { 10 + 5 * finger }
}

/// A hand's pinching as the platform reports it, for platforms where a pinch
/// selects what the eyes are looking at (visionOS). Such a platform says
/// where the eyes look only while a pinch lasts.
public enum SystemPinch {
    case notPinching
    /// - ray: from the eyes through what they looked at when the pinch
    ///   began, moved since by the hand's own movement. World space;
    ///   `forward` is where it points.
    /// - pressed: whether the host should see the pinch as held yet (it
    ///   is told the ray a moment before, so that the press lands on it).
    case pinching(ray: Pose, pressed: Bool)

    /// How much further the ray's start moves than the hand does, so that a
    /// small movement of a pinching hand drags a long way. ALVR's figure.
    public static let handTravelGain: Float = 3.5

    /// The ray for a pinch that began with the eyes at `origin` looking
    /// along `direction`, after the pinching hand has moved by `handTravel`.
    /// All in world space, meters.
    public static func ray(origin: Vec3, direction: Vec3, handTravel: Vec3) -> Pose {
        let forward = direction * (1 / max(length(direction), 0.001))
        var sideways = forward.cross(Vec3(0, 1, 0))
        if length(sideways) < 0.001 { sideways = Vec3(1, 0, 0) }     // looking straight up or down
        let right = sideways * (1 / length(sideways))
        return Pose(position: origin + handTravel * handTravelGain, right: right, up: right.cross(forward), forward: forward)
    }
}

/// What one hand is: something held, or the hand itself.
public enum HandInput {
    case controller(ControllerState)
    case hand(TrackedHand)
}

/// The gestures the host treats as OpenXR button inputs.
struct HandGestures {
    /// Thumb tip against the tip of the index, middle, ring and little finger.
    var pinch = [false, false, false, false]
    /// All four fingers curled into a fist.
    var grip = false
    /// Index finger straight, the other three curled.
    var point = false

    /// Thumb and fingertip closer than `pinchStart` begin a pinch; it lasts
    /// until they are further apart than `pinchEnd`. Meters. The reference
    /// client takes pinches from its headset's runtime, so these are ours.
    static let pinchStart: Float = 0.02, pinchEnd: Float = 0.035

    /// Read the gestures off a hand. `previous` makes each one a little
    /// harder to leave than to enter, so it does not flicker at the edge.
    init(_ hand: TrackedHand, previous: HandGestures?) {
        let thumb = hand.joints[TrackedHand.thumbTip].position
        // How far each finger is bent, in degrees: the angle between where
        // its first joint points and where its tip points.
        var curl: [Float] = []
        for finger in 0..<4 {
            let tip = hand.joints[TrackedHand.tip(finger)]
            let gap = tip.position - thumb
            let limit = previous?.pinch[finger] == true ? HandGestures.pinchEnd : HandGestures.pinchStart
            pinch[finger] = gap.dot(gap).squareRoot() < limit
            let cosine = hand.joints[TrackedHand.proximal(finger)].forward.dot(tip.forward)
            curl.append(acos(max(-1, min(1, cosine))) * 180 / .pi)
        }
        // The reference client's thresholds.
        func curled(_ finger: Int, alreadyOn: Bool) -> Bool { curl[finger] > (alreadyOn ? 80 : 120) }
        let wasGripping = previous?.grip == true, wasPointing = previous?.point == true
        grip = (0..<4).allSatisfy { curled($0, alreadyOn: wasGripping) }
        point = curl[0] < (wasPointing ? 40 : 18) && (1..<4).allSatisfy { curled($0, alreadyOn: wasPointing) }
        // A platform that reports pinches itself decides the index pinch.
        switch hand.systemPinch {
        case .notPinching: pinch[0] = false
        case .pinching(_, let pressed): pinch[0] = pressed
        case nil: break
        }
    }

    /// For the log: what is being done, in words.
    var description: String {
        let names = ["index pinch", "middle pinch", "ring pinch", "little pinch"]
        let active = (0..<4).filter { pinch[$0] }.map { names[$0] } + (grip ? ["grip"] : []) + (point ? ["point"] : [])
        return active.isEmpty ? "nothing" : active.joined(separator: ", ")
    }

    /// The 28-byte input block of the pose message for a hand: the index
    /// pinch and the grip as two buttons and two analog values.
    func inputBlock() -> Bytes {
        var out = Bytes()
        out.append(integer: UInt64((pinch[0] ? 1 : 0) | (grip ? 2 : 0)))
        out.append(integer: UInt64(0))                   // nothing is "touched"
        out.append(InputBlock.kindTrackedHand)
        let full = UInt8(InputBlock.analogFull)
        out.append(contentsOf: [pinch[0] ? full : 0, grip ? full : 0])
        out.append(zeros: InputBlock.size - out.count)
        return out
    }

    /// The gesture bits of the hand message. Bit 4, "menu", is never set.
    var bits: UInt16 {
        var out: UInt16 = point ? 1 << 5 : 0
        for finger in 0..<4 where pinch[finger] { out |= 1 << UInt16(finger) }
        return out
    }
}

/// Quaternions as (w, x, y, z), as the wire has them.
private typealias Quaternion = [Float]

private func multiply(_ a: Quaternion, _ b: Quaternion) -> Quaternion {
    [a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
     a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
     a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
     a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]]
}

private func conjugate(_ q: Quaternion) -> Quaternion { [q[0], -q[1], -q[2], -q[3]] }

private func rotate(_ v: Vec3, by q: Quaternion) -> Vec3 {
    let r = multiply(multiply(q, [0, v.x, v.y, v.z]), conjugate(q))
    return Vec3(r[1], r[2], r[3])
}

func length(_ v: Vec3) -> Float { v.dot(v).squareRoot() }

extension Pose {
    /// `point`, given in this pose's own x, y, z (right, up, backward), in world space.
    fileprivate func world(x: Float, y: Float, z: Float) -> Vec3 {
        position + right * x + up * y + forward * -z
    }

    /// A world-space point in this pose's own x, y, z (right, up, backward).
    fileprivate func ownAxes(_ point: Vec3) -> Vec3 {
        let p = local(point)
        return Vec3(p.x, p.y, -p.z)
    }
}

extension TrackedHand {
    /// Where the host should put its hand device relative to the wrist joint,
    /// as the pose message carries it: position, then quaternion w first.
    /// The reference client's constants: 9 cm across and 15 cm forward of the
    /// wrist, rolled a quarter turn and pitched 45 degrees.
    static func wristOffset(_ side: Side) -> (position: Vec3, orientation: [Float]) {
        let sign: Float = side == .left ? 1 : -1
        return (Vec3(0.09 * sign, -0.02, -0.15), [0.65328, 0.27060, -0.27060 * sign, -0.65328 * sign])
    }

    /// The skeleton's wrist bone relative to the hand device. vrlink does this oddly,
    /// so the constants are taken from it.
    static func wristBone(_ side: Side) -> (position: Vec3, orientation: [Float]) {
        side == .left ? (Vec3(-0.034038, 0.036503, 0.164722), [-0.055147, -0.078608, -0.920279, 0.379296])
                      : (Vec3(0.034038, 0.036503, 0.164722), [-0.055147, -0.078608, 0.920279, -0.379296])
    }

    /// SteamVR's hand skeleton: 31 bones, each a position and orientation
    /// relative to its parent bone. Bone 0 is the root, 1 the wrist, 2...25
    /// follow the joints of the same number, and 26...30 are one "auxiliary"
    /// bone per finger, placed from the wrist.
    ///
    /// SteamVR's bone axes differ from the joints' and are mirrored between
    /// the hands, so each formula is vrlink's change of axes around a plain "this joint relative to that one".
    func bones(_ side: Side) -> [(position: Vec3, orientation: [Float])] {
        let left = side == .left
        let s: Float = 0.70710678
        let wrist = joints[TrackedHand.wrist], wristQ = wrist.quaternion

        /// A joint placed along its parent's bone: only the distance and the bend matter.
        func along(_ joint: Pose, from parent: Pose) -> (Vec3, [Float]) {
            let bend = multiply(conjugate(parent.quaternion), joint.quaternion)
            let distance = length(joint.position - parent.position)
            return left ? (Vec3(distance, 0, 0), [bend[0], -bend[3], -bend[2], -bend[1]])
                        : (Vec3(-distance, 0, 0), [bend[0], bend[3], bend[2], -bend[1]])
        }

        var bones: [(Vec3, [Float])] = [
            (Vec3(0, 0, 0), [1, 0, 0, 0]),
            // The wrist bone is a constant: the hand's place is the wrist pose sent beside it.
            TrackedHand.wristBone(side),
        ]
        for joint in 2..<TrackedHand.jointCount {
            if [2, 6, 11, 16, 21].contains(joint) {
                // The first bone of each finger hangs off the wrist.
                let relative = multiply(conjugate(wristQ), joints[joint].quaternion)
                let d = wrist.ownAxes(joints[joint].position)
                bones.append(left
                    ? (Vec3(d.y, d.x, -d.z), multiply(multiply([0, s, s, 0], relative), [0, -s, 0, s]))
                    : (Vec3(-d.y, -d.x, -d.z), multiply(multiply([0, s, -s, 0], relative), [-s, 0, s, 0])))
            } else {
                bones.append(along(joints[joint], from: joints[joint - 1]))
            }
        }
        // Auxiliary bones: each finger's last knuckle, as seen from the wrist.
        for joint in [4, 9, 14, 19, 24] { bones.append(along(joints[joint], from: wrist)) }
        return bones
    }

    /// The skeleton packed into 8 bytes per bone: three 10-bit position axes
    /// covering +-17.5 cm, then the orientation as its largest component's
    /// index and the other three in 10 bits each.
    func compressedSkeleton(_ side: Side) -> Bytes {
        func axis(_ meters: Float) -> UInt32 {
            UInt32(max(0, min(1023, Int(((meters + 0.175) * 5.714286 + 0.0019550342) * 511.5))))
        }
        var out = Bytes()
        for (position, q) in bones(side) {
            out.append(integer: axis(position.x) | axis(position.y) << 10 | axis(position.z) << 20)
            var largest = abs(q[0]) < abs(q[1]) ? 1 : 0
            if abs(q[2]) > abs(q[largest]) { largest = 2 }
            if abs(q[3]) > abs(q[largest]) { largest = 3 }
            var word = UInt32(largest)
            for index in 0..<4 where index != largest {
                // Each of the others: a "sign differs from the largest's" bit and a 9-bit size.
                let differs: UInt32 = (q[index] < 0) != (q[largest] < 0) ? 0x200 : 0
                let size = min(511, UInt32(abs(q[index]) / 0.70710677 * 511 + 0.5))
                word = word << 10 | differs | size
            }
            out.append(integer: word)
        }
        return out
    }

    /// A pointing ray for this hand, which vrlink gets from its headset's runtime and we have to make up
    /// for platforms which are missing it.
    ///
    /// The point rests in the opening between the index and thumb, and is stabilized using a ray going from
    /// the predicted shoulder pose  to the middle metacarpal tip.
    func aim(_ side: Side, head: Pose) -> Pose {
        let gap = (joints[TrackedHand.proximal(0) + 1].position + joints[TrackedHand.thumbTip - 1].position) * 0.5
        let worldUp = Vec3(0, 1, 0)
        let shoulder = head.position + head.right * (side == .left ? -0.18 : 0.18) + worldUp * -0.25
        // The direction comes only from parts of the hand the thumb does not
        // move (the middle finger's knuckle, the palm), so that pinching or
        // moving the thumb shifts where the ray starts but never where it points.
        let reach = joints[TrackedHand.proximal(1)].position - shoulder
        let fromShoulder = reach * (1 / max(length(reach), 0.001))
        let palmFaces = joints[0].up * -1                    // a joint's "up" comes out of the back of the hand
        let mixed = fromShoulder * (1 - TrackedHand.palmShare) + palmFaces * TrackedHand.palmShare
        let forward = mixed * (1 / max(length(mixed), 0.001))
        let sideways = forward.cross(worldUp)
        let right = sideways * (1 / max(length(sideways), 0.001))
        return Pose(position: gap + forward * 0.02, right: right, up: right.cross(forward), forward: forward)
    }

    /// How much of the pointing direction comes from where the palm faces.
    static let palmShare: Float = 0.25

    /// The hand message (class 3, type 0x17): the skeleton, which hand,
    /// its gestures, the pointing ray relative to the hand device, and the
    /// way back from the hand device to the wrist.
    /// In the hand message's byte after the skeleton: bit 0 is which hand, bit 1 says it is tracked.
    static let messageFlagTracked: UInt8 = 0x02

    func message(_ side: Side, gestures: HandGestures, aim: Pose) -> SVLElement {
        let offset = TrackedHand.wristOffset(side)
        let wrist = joints[TrackedHand.wrist]
        // The hand device: the wrist, moved and turned by the offset.
        let deviceQ = multiply(wrist.quaternion, offset.orientation)
        let devicePosition = wrist.world(x: offset.position.x, y: offset.position.y, z: offset.position.z)
        let aimPosition = rotate(aim.position - devicePosition, by: conjugate(deviceQ))
        let aimQ = multiply(conjugate(deviceQ), aim.quaternion)
        let backPosition = rotate(offset.position * -1, by: conjugate(offset.orientation))

        var out = compressedSkeleton(side)
        out.append(UInt8(side.rawValue) | TrackedHand.messageFlagTracked)
        out.append(integer: gestures.bits)
        for value in [aimPosition.x, aimPosition.y, aimPosition.z] + aimQ { out.append(float: value) }
        for value in [backPosition.x, backPosition.y, backPosition.z] + conjugate(offset.orientation) {
            out.append(float: value)
        }
        return SVLElement(.hand, value: out)
    }
}

/// A hand's pointing ray, smoothed: where it starts (meters) and which way
/// it points (a unit vector) each go through their own 1 euro filter.
struct AimFilter {
    private var origin = OneEuroFilterVec3(slowestCutoff: 1.5, speedGain: 20)      // free by about 0.5 m/s
    private var direction = OneEuroFilterVec3(slowestCutoff: 1.0, speedGain: 6)    // free by about 2 rad/s
    private var lastTime: Double?

    mutating func smooth(_ aim: Pose, seconds time: Double) -> Pose {
        // After a gap the hand may be anywhere: start again.
        var step = Float(time - (lastTime ?? time))
        if step < 0 || step > 0.2 {
            self = AimFilter()
            step = 0
        }
        lastTime = time
        let position = origin.smooth(aim.position, seconds: step)
        let pointing = direction.smooth(aim.forward, seconds: step)
        let forward = pointing * (1 / max(length(pointing), 0.001))
        let sideways = forward.cross(Vec3(0, 1, 0))
        let right = sideways * (1 / max(length(sideways), 0.001))
        return Pose(position: position, right: right, up: right.cross(forward), forward: forward)
    }
}
