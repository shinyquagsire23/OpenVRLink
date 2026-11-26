// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Hand tracking data, gesture recognition, and SteamVR skeleton packing
/// (see `docs/svl-tracking-input/skeleton.md` and `controllers.md`).
///
/// For each tracked hand, the host expects a controller-like wrist pose, basic
/// pinch/grip gestures mapped to button inputs, and SteamVR's 31-bone hand skeleton.

/// World-space hand joints in OpenXR order and axis convention (`forward` points
/// toward the fingertip and `up` points out of the back of the hand).
public struct TrackedHand {
    public var joints: [Pose]
    /// Optional platform-provided pinch state (see `SystemPinch`); overrides joint-based index pinch detection when set.
    public var systemPinch: SystemPinch?
    /// Whether the platform reports a menu gesture or system button on this hand (used on the left hand to open
    /// the SteamVR dashboard when no controller is held).
    public var menu = false

    /// 26 joints: palm, wrist, then metacarpal-to-tip for thumb (4 joints)
    /// and index, middle, ring, little (5 each).
    public init(joints: [Pose]) {
        precondition(joints.count == TrackedHand.jointCount)
        self.joints = joints
    }

    /// Synthesizes a flat, open hand with all joints aligned to `wrist`, used for
    /// tests and viewers without hand tracking.
    public static func flat(wrist: Pose, side: Side) -> TrackedHand {
        func joint(across: Float, ahead: Float) -> Pose {
            var pose = wrist
            // With palm facing down, the thumb is on the inner side (+right for the left hand).
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

/// Platform-reported pinch and gaze-aim state for systems like visionOS where
/// pinching targets whatever the user is looking at and eye gaze is only exposed
/// during an active pinch.
public enum SystemPinch {
    case notPinching
    /// - `ray`: World-space interaction ray starting at the eyes toward the initial
    ///   gaze target and translated by subsequent hand movement (`forward` is the ray direction).
    /// - `pressed`: Whether the pinch click is active yet (the ray is sent slightly
    ///   before the click so the cursor settles on target before pressing).
    case pinching(ray: Pose, pressed: Bool)

    /// Multiplier applied to hand translation while pinching so small hand motions drag comfortably (matches ALVR).
    public static let handTravelGain: Float = 3.5

    /// Constructs the world-space interaction ray (in meters) for a pinch that started
    /// at `origin` along `direction` after the hand has translated by `handTravel`.
    public static func ray(origin: Vec3, direction: Vec3, handTravel: Vec3) -> Pose {
        let forward = direction * (1 / max(length(direction), 0.001))
        var sideways = forward.cross(Vec3(0, 1, 0))
        if length(sideways) < 0.001 { sideways = Vec3(1, 0, 0) }     // looking straight up or down
        let right = sideways * (1 / length(sideways))
        return Pose(position: origin + handTravel * handTravelGain, right: right, up: right.cross(forward), forward: forward)
    }
}

/// Input source for a single hand: either a physical controller or bare-hand tracking.
public enum HandInput {
    case controller(ControllerState)
    case hand(TrackedHand)
}

/// Discrete hand gestures mapped to OpenXR button inputs on the host.
struct HandGestures {
    /// Thumb tip against the tip of the index, middle, ring and little finger.
    var pinch = [false, false, false, false]
    /// All four fingers curled into a fist.
    var grip = false
    /// Index finger straight, the other three curled.
    var point = false
    /// Platform menu gesture or system button (`TrackedHand.menu`).
    var menu = false

    /// Hysteresis thresholds in meters between thumb tip and fingertip to enter
    /// (`pinchStart`) and exit (`pinchEnd`) a pinch. `vrlink` relies on the headset
    /// runtime for pinch detection, so we define our own thresholds here.
    static let pinchStart: Float = 0.02, pinchEnd: Float = 0.035

    /// Evaluates gestures from joint poses, using `previous` for hysteresis to prevent flickering near thresholds.
    init(_ hand: TrackedHand, previous: HandGestures?) {
        let thumb = hand.joints[TrackedHand.thumbTip].position
        // Finger curl in degrees, measured between the proximal phalanx and fingertip forward vectors.
        var curl: [Float] = []
        for finger in 0..<4 {
            let tip = hand.joints[TrackedHand.tip(finger)]
            let gap = tip.position - thumb
            let limit = previous?.pinch[finger] == true ? HandGestures.pinchEnd : HandGestures.pinchStart
            pinch[finger] = gap.dot(gap).squareRoot() < limit
            let cosine = hand.joints[TrackedHand.proximal(finger)].forward.dot(tip.forward)
            curl.append(acos(max(-1, min(1, cosine))) * 180 / .pi)
        }
        // Curl angle thresholds (with hysteresis) matching vrlink.
        func curled(_ finger: Int, alreadyOn: Bool) -> Bool { curl[finger] > (alreadyOn ? 80 : 120) }
        let wasGripping = previous?.grip == true, wasPointing = previous?.point == true
        grip = (0..<4).allSatisfy { curled($0, alreadyOn: wasGripping) }
        point = curl[0] < (wasPointing ? 40 : 18) && (1..<4).allSatisfy { curled($0, alreadyOn: wasPointing) }
        menu = hand.menu
        // Override index-finger pinch when the platform provides system pinch state.
        switch hand.systemPinch {
        case .notPinching: pinch[0] = false
        case .pinching(_, let pressed): pinch[0] = pressed
        case nil: break
        }
    }

    /// Human-readable summary of active gestures for logging.
    var description: String {
        let names = ["index pinch", "middle pinch", "ring pinch", "little pinch"]
        let active = (0..<4).filter { pinch[$0] }.map { names[$0] } + (grip ? ["grip"] : []) + (point ? ["point"] : [])
        return active.isEmpty ? "nothing" : active.joined(separator: ", ")
    }

    /// Encodes the 28-byte pose-message input block mapping index pinch and grip to buttons and analog channels.
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

    /// Packed gesture bitmask for the hand packet. Bit 4 is the menu gesture, which SteamVR reads from the left
    /// hand.
    var bits: UInt16 {
        var out: UInt16 = (point ? 1 << 5 : 0) | (menu ? 1 << 4 : 0)
        for finger in 0..<4 where pinch[finger] { out |= 1 << UInt16(finger) }
        return out
    }
}

/// Quaternion ordered `(w, x, y, z)` to match the wire format.
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
    /// Converts local `(right, up, backward)` coordinates into a world-space point.
    fileprivate func world(x: Float, y: Float, z: Float) -> Vec3 {
        position + right * x + up * y + forward * -z
    }

    /// Converts a world-space point into local `(right, up, backward)` coordinates.
    fileprivate func ownAxes(_ point: Vec3) -> Vec3 {
        let p = local(point)
        return Vec3(p.x, p.y, -p.z)
    }
}

extension TrackedHand {
    /// Offset from the wrist joint to the SteamVR hand device pose, as `(position, quaternion)`
    /// with `w` first. Uses `vrlink`'s constants: 9 cm inward and 15 cm forward of
    /// the wrist, rolled 90 degrees and pitched 45 degrees.
    static func wristOffset(_ side: Side) -> (position: Vec3, orientation: [Float]) {
        let sign: Float = side == .left ? 1 : -1
        return (Vec3(0.09 * sign, -0.02, -0.15), [0.65328, 0.27060, -0.27060 * sign, -0.65328 * sign])
    }

    /// Offset of the skeleton's wrist bone relative to the hand device, using `vrlink`'s empirical constants.
    static func wristBone(_ side: Side) -> (position: Vec3, orientation: [Float]) {
        side == .left ? (Vec3(-0.034038, 0.036503, 0.164722), [-0.055147, -0.078608, -0.920279, 0.379296])
                      : (Vec3(0.034038, 0.036503, 0.164722), [-0.055147, -0.078608, 0.920279, -0.379296])
    }

    /// Computes SteamVR's 31-bone hand skeleton, where each bone is a `(position, orientation)`
    /// transform relative to its parent. Bone 0 is the root, bone 1 is the wrist,
    /// bones 2...25 correspond to the OpenXR joints at the same indices, and bones
    /// 26...30 are per-finger auxiliary bones relative to the wrist.
    ///
    /// SteamVR's bone axes differ from OpenXR's joint axes and mirror across left
    /// and right hands, so each bone applies `vrlink`'s basis change to the parent-relative
    /// joint transform.
    func bones(_ side: Side) -> [(position: Vec3, orientation: [Float])] {
        let left = side == .left
        let s: Float = 0.70710678
        let wrist = joints[TrackedHand.wrist], wristQ = wrist.quaternion

        /// Computes a child bone transform along its parent bone from joint distance and relative rotation.
        func along(_ joint: Pose, from parent: Pose) -> (Vec3, [Float]) {
            let bend = multiply(conjugate(parent.quaternion), joint.quaternion)
            let distance = length(joint.position - parent.position)
            return left ? (Vec3(distance, 0, 0), [bend[0], -bend[3], -bend[2], -bend[1]])
                        : (Vec3(-distance, 0, 0), [bend[0], bend[3], bend[2], -bend[1]])
        }

        var bones: [(Vec3, [Float])] = [
            (Vec3(0, 0, 0), [1, 0, 0, 0]),
            // The wrist bone uses a fixed local offset because overall hand tracking is carried by the wrist pose.
            TrackedHand.wristBone(side),
        ]
        for joint in 2..<TrackedHand.jointCount {
            if [2, 6, 11, 16, 21].contains(joint) {
                // Each finger's metacarpal is parented directly to the wrist.
                let relative = multiply(conjugate(wristQ), joints[joint].quaternion)
                let d = wrist.ownAxes(joints[joint].position)
                bones.append(left
                    ? (Vec3(d.y, d.x, -d.z), multiply(multiply([0, s, s, 0], relative), [0, -s, 0, s]))
                    : (Vec3(-d.y, -d.x, -d.z), multiply(multiply([0, s, -s, 0], relative), [-s, 0, s, 0])))
            } else {
                bones.append(along(joints[joint], from: joints[joint - 1]))
            }
        }
        // Append the five auxiliary bones (each finger's distal joint relative to the wrist).
        for joint in [4, 9, 14, 19, 24] { bones.append(along(joints[joint], from: wrist)) }
        return bones
    }

    /// Packs the 31-bone skeleton into 8 bytes per bone: three 10-bit quantized
    /// position coordinates (+-17.5 cm) followed by smallest-three quaternion
    /// compression (2-bit largest-component index plus three 10-bit components).
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
                // Pack each remaining quaternion component as a sign-difference bit (relative to the largest component) and a 9-bit magnitude.
                let differs: UInt32 = (q[index] < 0) != (q[largest] < 0) ? 0x200 : 0
                let size = min(511, UInt32(abs(q[index]) / 0.70710677 * 511 + 0.5))
                word = word << 10 | differs | size
            }
            out.append(integer: word)
        }
        return out
    }

    /// Synthesizes a hand-aim ray for platforms whose runtime does not provide one
    /// (unlike Quest, where `vrlink` reads the runtime's aim pose directly).
    ///
    /// The ray starts between the thumb and index finger and blends the direction
    /// from an estimated shoulder point through the middle knuckle with the palm normal.
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

    /// Weight given to the palm normal when blending the synthesized aim direction.
    static let palmShare: Float = 0.25

    /// Bit 1 of the flags byte following the skeleton (bit 0 encodes `Side`), indicating active tracking.
    static let messageFlagTracked: UInt8 = 0x02

    /// Builds the SVL hand tracking element (class 3, type 0x17) containing the
    /// compressed skeleton, handedness/tracking flags, gesture bitmask, hand-device-relative
    /// aim pose, and inverse wrist offset.
    func message(_ side: Side, gestures: HandGestures, aim: Pose) -> SVLElement {
        let offset = TrackedHand.wristOffset(side)
        let wrist = joints[TrackedHand.wrist]
        // Compute the hand device pose in world space by applying wristOffset to the wrist joint.
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

/// Smooths a hand's aim ray by filtering its world-space origin and forward
/// vector with separate 1-euro filters.
struct AimFilter {
    private var origin = OneEuroFilterVec3(slowestCutoff: 1.5, speedGain: 20)      // free by about 0.5 m/s
    private var direction = OneEuroFilterVec3(slowestCutoff: 1.0, speedGain: 6)    // free by about 2 rad/s
    private var lastTime: Double?

    mutating func smooth(_ aim: Pose, seconds time: Double) -> Pose {
        // Reset the filters after a tracking gap so the ray snaps immediately to the new hand pose.
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

/// Computes a panel pointer ray and index-pinch state from tracked hand joints on runtimes that support
/// `XR_EXT_hand_tracking` without `XR_EXT_hand_interaction`, using the same aim ray and pinch detection sent
/// to the host (`TrackedHand.aim`, `HandGestures`).
public struct HandPointer {
    private var filter = AimFilter()
    private var gestures: HandGestures?

    public init() {}

    /// - Parameter seconds: A monotonic timestamp for the smoothing filter.
    public mutating func point(_ hand: TrackedHand, side: Side, head: Pose, seconds: Double) -> (ray: Pose, pressed: Bool) {
        let now = HandGestures(hand, previous: gestures)
        gestures = now
        return (filter.smooth(hand.aim(side, head: head), seconds: seconds), now.pinch[0])
    }
}

/// Processed input for a single hand, ready to send over either protocol.
/// For tracked hands, this includes recognized gestures and the smoothed aim ray.
enum ResolvedHand {
    case controller(ControllerState)
    case hand(TrackedHand, gestures: HandGestures, aim: Pose)
}

/// Tracks per-hand state across pose updates, including gesture hysteresis,
/// aim ray smoothing, and logging when input switches between controllers and hand tracking.
struct HandResolver {
    private var gestures: [HandGestures?] = [nil, nil]
    private var aimFilters = [AimFilter(), AimFilter()]
    private var holding = ["nothing", "nothing"]

    struct Resolved {
        /// Resolved left and right hand states (always two elements).
        var hands: [ResolvedHand?]
        /// Log messages when a hand switches between nothing, a controller, or hand tracking.
        var notes: [String] = []
        /// Log messages when a tracked hand's active gestures change.
        var gestureNotes: [String] = []
    }

    /// Resolves raw hand inputs (`hands`, ordered left then right; missing entries are treated as nil).
    /// `head` provides the reference pose for aim rays, and `seconds` is a monotonic timestamp
    /// used by the smoothing filter. If `bareHands` is false, tracked hands without a controller
    /// are ignored and treated as nil.
    mutating func resolve(_ hands: [HandInput?], head: Pose, seconds: Double, bareHands: Bool = true) -> Resolved {
        var out = Resolved(hands: [nil, nil])
        for side in Side.allCases {
            let index = side.rawValue
            var now = "nothing"
            switch index < hands.count ? hands[index] : nil {
            case .controller(let controller):
                now = "a controller"
                gestures[index] = nil
                out.hands[index] = .controller(controller)
            case .hand(let hand) where bareHands:
                now = "a tracked hand"
                let read = HandGestures(hand, previous: gestures[index])
                if read.description != (gestures[index]?.description ?? "nothing") {
                    out.gestureNotes.append("\(side) hand: \(read.description)")
                }
                gestures[index] = read
                let aim: Pose
                if case .pinching(let ray, _) = hand.systemPinch {
                    // System pinch uses the eye-tracked ray directly. Reset the filter so
                    // hand-ray smoothing starts fresh when the pinch ends.
                    aim = ray
                    aimFilters[index] = AimFilter()
                } else {
                    aim = aimFilters[index].smooth(hand.aim(side, head: head), seconds: seconds)
                }
                out.hands[index] = .hand(hand, gestures: read, aim: aim)
            case .hand, nil:
                gestures[index] = nil
            }
            if now != holding[index] {
                holding[index] = now
                out.notes.append("\(side) hand is now \(now)")
            }
        }
        return out
    }
}
