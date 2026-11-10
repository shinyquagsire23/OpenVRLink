// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Controller inputs sent to the host runtime
/// (docs/svl-tracking-input/controllers.md).
///
/// The host is told each controller is of the Quest/Touch type, with the Touch
/// input profile; vrlink currently refuses controller types it has no table for.
/// It is free in what the controller is called and drawn as, so SteamVR
/// shows its PlayStation VR2 Sense model on visionOS.
///
/// Platforms map their own controller onto the Touch names below.

public enum Side: Int, CaseIterable {
    case left, right
}

/// One hand-held controller at one instant.
/// One hand's input block in the pose message
/// (docs/svl-tracking-input/controllers.md): 64 click bits, 64 touch bits,
/// what kind of thing the hand is, then signed analog bytes.
enum InputBlock {
    static let size = 28
    static let kindController: UInt8 = 0
    static let kindTrackedHand: UInt8 = 1
    /// An analog value at full travel.
    static let analogFull: Float = 127
}

/// How much charge a device has left.
public struct PowerState: Equatable {
    /// 0 empty ... 1 full.
    public var level: Float
    public var charging: Bool

    public init(level: Float, charging: Bool) {
        self.level = level
        self.charging = charging
    }

    /// The same, to the nearest percent: what is worth telling the host again.
    var rounded: PowerState { PowerState(level: (level * 100).rounded() / 100, charging: charging) }
}

public struct ControllerState {
    /// The OpenXR grip pose in world space: position in the middle of the
    /// handle, -z along the handle towards the front, +x out of the palm side
    /// for the left hand. Includes velocity.
    public var grip: TrackedPose

    /// Its battery, where the platform says; nil tells the host nothing about it.
    public var power: PowerState?

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

    /// How much of a controller's angular velocity the host is told. The
    /// host carries every pose forward by its velocities across the whole
    /// delay to the display (docs/svl-tracking-input/poses.md). For a
    /// controller's position that reads right; its turning, carried that
    /// far in a straight line, overshoots, and with none at all the pointer
    /// drags. Half was settled on by feel on the headset (2026-11-11).
    static let spinSent: Float = 0.5

    /// The grip as it is sent.
    var gripForHost: TrackedPose {
        var out = grip
        out.angularVelocity = grip.angularVelocity * ControllerState.spinSent
        return out
    }

    /// The 28-byte input block of the pose message: click bits, touch bits,
    /// a hand-tracking flag, and eleven signed analog bytes.
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

    /// Where the host should put the SteamVR controller relative to the grip
    /// pose, as 7 floats (position, then quaternion w first). The host draws
    /// SteamVR's PlayStation VR2 Sense model, whose origin is not at the grip.
    ///
    /// The numbers are the ALVR visionOS client's for this model, which come
    /// in two parts that ALVR applies one after the other: its headset app
    /// pitches the grip pose 5.037 degrees about its x axis (the tilt in
    /// SteamVR's own description of the model) and nudges it 2 mm across and
    /// 10 mm forward; then its PC side moves every controller 11 cm further
    /// forward along the controller's own (now pitched) axis.
    static func gripOffset(_ side: Side) -> [Float] {
        let pitch = 5.037 * Float.pi / 180
        let forward: Float = 0.11
        // 11 cm along the pitched -z axis, seen from the unpitched grip: mostly forward, slightly up.
        let position = [0.002, sin(pitch) * forward, -0.01 - cos(pitch) * forward]
        return position + [cos(pitch / 2), sin(pitch / 2), 0, 0]
    }
}

/// A vibration the host asks a controller to play.
public struct HapticPulse {
    public var side: Side
    public var frequency: Float      // Hz
    public var seconds: Float
    public var amplitude: Float      // 0 ... 1
    /// No pulse is played shorter than this, in seconds.
    static let shortest: Float = 0.03

    /// The host's haptics message (docs/svl-tracking-input/haptics.md): two
    /// 19-byte records, each one pulse with a sequence number, sent
    /// redundantly. `seen` holds the last two sequence numbers per hand so
    /// that a repeated record is played once.
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
            // SteamVR's pulses are often a few milliseconds or less, which no
            // actuator renders. The reference client stretches two cases (under
            // 1 ms to 20 ms, 5 ms to 40 ms); the floor below covers the rest.
            if pulse.seconds >= 0.0049, pulse.seconds < 0.0051 { pulse.seconds += 0.035 }
            pulse.seconds = max(pulse.seconds, HapticPulse.shortest)
            pulses.append(pulse)
        }
        return pulses
    }
}

/// Notices the two controllers being knocked together twice in front of the
/// face: the wearer's signal to switch between controllers and bare hands.
/// The rules and numbers are the ALVR visionOS client's.
public struct ClackDetector {
    /// Whether an odd number of double knocks has been seen: use hands.
    public private(set) var handsWanted = false

    private var lastVelocities: [Vec3]?
    private var lastTime = -Double.infinity
    private var firstKnock = -Double.infinity, secondKnock = -Double.infinity

    /// How often the controllers are looked at, in seconds. A knock is
    /// recognized by how much velocity changes from one look to the next,
    /// so the looks are evenly spaced, at ALVR's rate.
    static let interval = 0.011
    /// A knock changes each controller's velocity by this much between two looks, in m/s.
    static let jolt: ClosedRange<Float> = 0.1...0.5
    /// Both controllers within this of a point 25 cm in front of the face, in meters.
    static let nearFace: Float = 0.25
    /// The controllers this close to each other, in meters.
    static let together: Float = 0.17

    public init() {}

    public mutating func reset() { self = ClackDetector() }

    /// Look at both controllers. `head` and the grips are in world space;
    /// `seconds` is any steady clock. Returns true when this look completed
    /// a double knock.
    @discardableResult
    public mutating func update(left: TrackedPose, right: TrackedPose, head: Pose, seconds now: Double) -> Bool {
        guard now - lastTime >= ClackDetector.interval else { return false }
        let velocities = [left.linearVelocity, right.linearVelocity]
        defer {
            lastVelocities = velocities
            lastTime = now
        }
        // After a pause there is no earlier velocity worth comparing with.
        guard let before = lastVelocities, now - lastTime < 0.1 else { return false }

        // Being in front of the face keeps an ordinary bump from counting.
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
