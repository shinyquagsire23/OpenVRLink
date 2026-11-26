// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Controller state and input encoding sent to the host runtime
/// (see `docs/svl-tracking-input/controllers.md`).
///
/// Controllers are reported with the Quest Touch controller type and input profile
/// because the host's `vrlink` driver rejects controller types without a built-in
/// binding table. Render model names remain configurable, allowing SteamVR to
/// display PlayStation VR2 Sense controller models on visionOS
/// (`DeviceProfile.senseControllerModels`).
///
/// Platform backends map their native controller inputs onto the Touch-style fields below.

public enum Side: Int, CaseIterable {
    case left, right
}

/// Constants for the 28-byte per-hand input block in SVL pose messages
/// (see `docs/svl-tracking-input/controllers.md`): 64 button-click bits,
/// 64 capacitive-touch bits, a 1-byte device-kind tag, and signed 8-bit analog axes.
enum InputBlock {
    static let size = 28
    static let kindController: UInt8 = 0
    static let kindTrackedHand: UInt8 = 1
    /// Full-scale magnitude for signed 8-bit analog axes.
    static let analogFull: Float = 127
}

/// Battery charge level and charging status for a headset or controller.
public struct PowerState: Equatable {
    /// Battery level from 0.0 (empty) to 1.0 (full).
    public var level: Float
    public var charging: Bool

    public init(level: Float, charging: Bool) {
        self.level = level
        self.charging = charging
    }

    /// Quantizes `level` to whole percentage points so minor fluctuations do not trigger redundant host updates.
    var rounded: PowerState { PowerState(level: (level * 100).rounded() / 100, charging: charging) }
}

/// Controller identity reported to a SteamVR host, matching `vrlink`'s `staticProps` and `poseAction`
/// definitions in `assets/config/controller_config.json` (keyed by OpenXR interaction profile so a Quest 3
/// paired with Touch Pro controllers reports Touch Pro models).
public enum ControllerModel: String, CaseIterable {
    /// Quest 2 Touch controller (also used as the fallback for unrecognized interaction profiles).
    case touch
    /// Quest Pro Touch Pro controller.
    case touchPro
    /// Quest 3 Touch Plus controller.
    case touchPlus
    case picoNeo3, pico4, viveFocus3

    /// Tracking system, serial prefix, manufacturer, model prefix, render model prefix, input profile,
    /// controller type, and vendor prefix.
    private var words: (system: String, serial: String, maker: String, model: String, render: String, profile: String, type: String, vendor: String) {
        let touch = "{oculus}/input/touch_profile.json", pico = "{vrlink}/input/pico_controller_profile.json"
        switch self {
        case .touch: return ("oculus", "VRLINKQ2", "Oculus", "Oculus Quest2", "oculus_quest2_controller", touch, "oculus_touch", "oculus")
        case .touchPro: return ("oculus", "VRLINKQP", "Oculus", "Oculus Quest Pro", "oculus_quest_pro_controller", touch, "oculus_touch", "oculus")
        case .touchPlus: return ("oculus", "VRLINKQ3", "Oculus", "Oculus Quest3", "oculus_quest_plus_controller", touch, "oculus_touch", "oculus")
        case .picoNeo3: return ("pico", "VRLINKPICONEO3", "PICO", "PICO Neo 3", "pico_neo3_controller", pico, "pico_controller", "PICO")
        case .pico4: return ("pico", "VRLINKP4", "PICO", "PICO 4", "pico_4_controller", pico, "pico_controller", "PICO")
        case .viveFocus3:
            return ("htc", "VRLINKVIVEFOCUS3", "HTC", "Vive Focus 3", "vive_focus3_controller",
                    "{vrlink}/input/vive_focus3_controller_profile.json", "vive_focus3_controller", "HTC")
        }
    }

    /// Returns the nine `VTE_StaticProps_t` strings for `side`.
    func staticStrings(_ side: Side) -> [String] {
        let name = side == .left ? "Left" : "Right", w = words
        // vrlink's Focus 3 device-type string includes an underscore omitted from its serial prefix.
        let typed = self == .viveFocus3 ? "VRLINKVIVE_FOCUS3" : w.serial
        return [w.system, "\(w.serial)_Controller_\(name)", w.maker, "\(w.model) (\(name) Controller)", "\(w.render)_\(name.lowercased())",
                "vrlink", w.profile, w.type, "\(w.vendor)/\(typed)_Controller_\(name)"]
    }

    /// Returns `vrlink`'s transform from the OpenXR grip pose to SteamVR's device origin as 7 floats
    /// (`x, y, z, qw, qx, qy, qz`), mirrored across X for the right hand.
    func gripOffset(_ side: Side) -> [Float] {
        let left: (x: Float, y: Float, z: Float, pitch: Float)
        switch self {
        case .touch, .touchPro, .touchPlus: left = (-0.007, -0.03416, -0.09607, -20.6)
        case .picoNeo3: left = (0.003, -0.046, -0.115, -10)
        case .pico4: left = (-0.007, -0.0512, -0.09607, -10)
        case .viveFocus3: left = (0, -0.002, -0.11, -5)
        }
        let half = left.pitch * Float.pi / 360
        return [side == .left ? left.x : -left.x, left.y, left.z, cos(half), sin(half), 0, 0]
    }

    /// Whether this model uses the Oculus Touch family, where `HeadsetQuirks.gripOffset` applies.
    public var isTouch: Bool { self == .touch || self == .touchPro || self == .touchPlus }
}

public struct ControllerState {
    /// World-space OpenXR grip pose and velocity, with the origin centered in the
    /// handle, -z pointing forward along the handle, and +x pointing out of the
    /// left palm.
    public var grip: TrackedPose

    /// Optional world-space OpenXR aim pose specifying the controller's pointing ray origin and direction.
    public var aim: Pose?

    /// Optional battery state; when `nil`, no battery property is reported to the host.
    public var power: PowerState?

    /// Controller model corresponding to the active OpenXR interaction profile.
    public var model = ControllerModel.touch

    /// Lower and upper face buttons: X and Y on the left, A and B on the right.
    public var lowerButton = false, upperButton = false
    /// Left hand only on a Touch controller.
    public var menuButton = false
    public var stickClick = false

    /// A finger resting on the control without pressing it.
    public var lowerButtonTouched = false, upperButtonTouched = false
    public var triggerTouched = false, stickTouched = false, thumbRestTouched = false

    /// 0 released ... 1 fully pulled.
    public var trigger: Float = 0, squeeze: Float = 0
    /// -1 ... 1; right and away from the body are positive.
    public var stickX: Float = 0, stickY: Float = 0

    public init(grip: TrackedPose) { self.grip = grip }

    /// Scale factor applied to controller angular velocity sent to the host.
    /// The host extrapolates poses across the full motion-to-photon latency
    /// (`docs/svl-tracking-input/poses.md`). Full linear velocity feels accurate,
    /// whereas full angular velocity overshoots during wrist turns and zero angular
    /// velocity makes the pointer lag; 0.5 was tuned empirically on Vision Pro.
    static let spinSent: Float = 0.5

    /// Grip pose with scaled angular velocity for host transmission.
    var gripForHost: TrackedPose {
        var out = grip
        out.angularVelocity = grip.angularVelocity * ControllerState.spinSent
        return out
    }

    /// Encodes the 28-byte SVL input block containing click bits, touch bits,
    /// the controller kind byte, and signed analog values.
    func inputBlock() -> Bytes {
        func bits(_ flags: [Bool]) -> UInt64 {
            flags.enumerated().reduce(0) { $0 | ($1.element ? 1 << UInt64($1.offset) : 0) }
        }
        func analog(_ value: Float) -> UInt8 {
            UInt8(bitPattern: Int8(max(-1, min(1, value)) * InputBlock.analogFull))
        }
        var out = Bytes()
        out.append(integer: bits([lowerButton, upperButton, menuButton, stickClick]))
        out.append(integer: bits([lowerButtonTouched, upperButtonTouched, triggerTouched, stickTouched, thumbRestTouched]))
        out.append(InputBlock.kindController)
        out.append(contentsOf: [analog(trigger), analog(stickX), analog(stickY), analog(squeeze)])
        out.append(zeros: InputBlock.size - out.count)
        return out
    }

    /// Transform from the grip pose to the SteamVR controller device origin as
    /// 7 floats (`x, y, z, qw, qx, qy, qz`).
    ///
    /// When `senseModel` is true, SteamVR renders the PlayStation VR2 Sense model,
    /// whose origin differs from the OpenXR grip pose. We combine the two offsets
    /// used by the ALVR visionOS client: pitching 5.037 degrees around +x (matching
    /// SteamVR's render model metadata) with a (+2 mm, 0, -10 mm) nudge, followed
    /// by translating 11 cm forward along the pitched -z axis.
    ///
    /// When `senseModel` is false, uses the grip offset for `model` (`docs/svl-tracking-input/controllers.md`),
    /// or Play For Dream's host-driver override (`offsetPos*` and `offsetDegX` under
    /// `vrlink_yvr_d3_controller_left` in "MR SteamLink Driver" 1.0.1.0: 2.5 cm up, 3.5 cm forward, +25 deg
    /// pitch, since Play For Dream's grip pose aligns with the aim ray rather than the handle).
    static func gripOffset(_ side: Side, senseModel: Bool, playForDream: Bool = false, model: ControllerModel = .touch) -> [Float] {
        if playForDream, !senseModel {
            let pitch = 25 * Float.pi / 180
            return [0, 0.025, -0.035, cos(pitch / 2), sin(pitch / 2), 0, 0]
        }
        guard senseModel else { return model.gripOffset(side) }
        let pitch = 5.037 * Float.pi / 180
        let forward: Float = 0.11
        // 11 cm forward along the pitched -z axis expressed in the unpitched grip frame.
        let position = [0.002, sin(pitch) * forward, -0.01 - cos(pitch) * forward]
        return position + [cos(pitch / 2), sin(pitch / 2), 0, 0]
    }
}

/// A controller haptic vibration pulse requested by the host.
public struct HapticPulse {
    public var side: Side
    public var frequency: Float      // Hz
    public var seconds: Float
    public var amplitude: Float      // 0 ... 1
    /// Minimum pulse duration in seconds.
    static let shortest: Float = 0.03

    /// Parses an SVL haptics payload (`docs/svl-tracking-input/haptics.md`), which
    /// packs two redundant 19-byte pulse records with sequence numbers. `seen`
    /// tracks the last two sequence numbers per hand to deduplicate retransmissions.
    static func parse(_ message: Bytes, seen: inout [[UInt16]]) -> [HapticPulse] {
        var pulses: [HapticPulse] = []
        for start in [0, 19] where message.count >= start + 19 {
            let sequence: UInt16 = message.integer(at: start + 0x10)
            guard let side = Side(rawValue: Int(message[start + 0x12])), !seen[side.rawValue].contains(sequence)
            else { continue }
            var pulse = HapticPulse(side: side, frequency: message.float(at: start), seconds: message.float(at: start + 4),
                                    amplitude: message.float(at: start + 8))
            guard pulse.amplitude > 0.01 else { continue }
            seen[side.rawValue] = Array((seen[side.rawValue] + [sequence]).suffix(2))
            // SteamVR often requests sub-5 ms pulses that physical actuators drop.
            // vrlink special-cases <1 ms (to 20 ms) and 5 ms (to 40 ms); we match
            // the 5 ms boost and clamp everything else to `shortest`.
            if pulse.seconds >= 0.0049, pulse.seconds < 0.0051 { pulse.seconds += 0.035 }
            pulse.seconds = max(pulse.seconds, HapticPulse.shortest)
            pulses.append(pulse)
        }
        return pulses
    }
}

/// Detects tapping the two controllers together twice in front of the headset,
/// which the user can use to toggle between controller input and hand tracking.
/// Thresholds and timing match the ALVR visionOS client.
public struct ClackDetector {
    /// True after an odd number of double-taps, indicating hand tracking is selected.
    public private(set) var handsWanted = false

    private var lastVelocities: [Vec3]?
    private var lastTime = -Double.infinity
    private var firstKnock = -Double.infinity, secondKnock = -Double.infinity

    /// Sampling interval in seconds. Velocity deltas are measured across fixed
    /// intervals matching ALVR's sampling rate.
    static let interval = 0.011
    /// Required per-controller velocity change (in m/s) between consecutive samples to register a tap.
    static let jolt: ClosedRange<Float> = 0.1...0.5
    /// Maximum distance in meters from a point 25 cm in front of the head for both controllers.
    static let nearFace: Float = 0.25
    /// Maximum distance in meters between the two controllers during a tap.
    static let together: Float = 0.17

    public init() {}

    public mutating func reset() { self = ClackDetector() }

    /// Samples both world-space controller poses against `head` using a monotonic
    /// timestamp `seconds`. Returns `true` when the sample completes a double-tap.
    @discardableResult
    public mutating func update(left: TrackedPose, right: TrackedPose, head: Pose, seconds now: Double) -> Bool {
        guard now - lastTime >= ClackDetector.interval else { return false }
        let velocities = [left.linearVelocity, right.linearVelocity]
        defer {
            lastVelocities = velocities
            lastTime = now
        }
        // Ignore stale velocity history after a tracking pause.
        guard let before = lastVelocities, now - lastTime < 0.1 else { return false }

        // Require both controllers to be near the face so incidental bumps at the user's sides are ignored.
        let inFront = head.position + head.forward * 0.25
        let jolts = [length(before[0] - velocities[0]), length(before[1] - velocities[1])]
        let knocked = jolts.allSatisfy { ClackDetector.jolt.contains($0) }
            && length(left.pose.position - inFront) < ClackDetector.nearFace
            && length(right.pose.position - inFront) < ClackDetector.nearFace
            && length(left.pose.position - right.pose.position) < ClackDetector.together
        guard knocked else { return false }

        if now - firstKnock > 1.0 {
            firstKnock = now
            secondKnock = -.infinity
        } else if now - firstKnock > 0.2, now - secondKnock > 1.0 {
            secondKnock = now
            handsWanted.toggle()
            return true
        }
        return false
    }
}
