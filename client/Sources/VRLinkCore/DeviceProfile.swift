// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What this client tells the host about its display and devices
/// (docs/svl-values/). A cold host sends no video until it has the projection,
/// chaperone, HMD static and power props, host defaults and refresh rates.
public struct DeviceProfile {
    /// Where each eye is, left then right, in the head's own frame.
    /// We normalize this to OpenXR convention, which is the headset pose being the midpoint
    /// between both eyes.
    public var eyesInHead = [DeviceProfile.eye(right: -0.0315), DeviceProfile.eye(right: 0.0315)]

    /// An eye facing straight ahead, `meters` to the right of the middle.
    public static func eye(right meters: Float) -> Pose {
        Pose(position: Vec3(meters, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
    }
    public var refreshHz: Float = 90
    /// Each eye's frustum, left then right
    public var eyeFrusta = [Frustum.symmetric(halfAngleDegrees: 45), Frustum.symmetric(halfAngleDegrees: 45)]

    public init() {}

    enum ValueID {
        static let clientInstance: UInt8 = 0x01, hostInstance: UInt8 = 0x02
        static let projection: UInt8 = 0x04, chaperone: UInt8 = 0x05, eyeToHead: UInt8 = 0x08
        static let requestedFrameTime: UInt8 = 0x0C
        static let staticHMD: UInt8 = 0x0D, powerHMD: UInt8 = 0x10
        static func staticController(_ side: Side) -> UInt8 { side == .left ? 0x0E : 0x0F }
        static func powerController(_ side: Side) -> UInt8 { side == .left ? 0x11 : 0x12 }
        static let focusEvent: UInt8 = 0x13, hostDefaults: UInt8 = 0x15, audioCapabilities: UInt8 = 0x18
        static let availableRates: UInt8 = 0x20, displayRateRequest: UInt8 = 0x21
        static let versionString: UInt8 = 0x22, propRefresh: UInt8 = 0x2B
        /// From the host: not zero while an application has the scene, zero
        /// in SteamVR's own grid (docs/svl-values/vte-id-table.md; inferred).
        static let sceneApplicationRunning: UInt8 = 0x35
    }

    /// VTE_StaticProps_t, 1161 bytes: nine strings naming a device to SteamVR.
    /// Order: tracking system, serial, manufacturer, model, render model,
    /// resource root, input profile, controller type, device type.
    private static func staticProps(_ strings: [String], driverType: UInt8 = 0) -> Bytes {
        var out = Bytes()
        out.append(integer: UInt32(0x7FF))
        for text in strings[..<7] { out.append(text: text, fieldSize: 128) }
        out.append(float: 0)                                   // laser-mouse angle
        for text in strings[7...] { out.append(text: text, fieldSize: 128) }
        out.append(driverType)
        return out
    }

    /// The second and third parts of the version string the host is
    /// given, as in "qvlclient;visionOS;OpenVRLink 0.1.0-2": the system
    /// this runs on, and the client and its version. The platform's shell
    /// fills them in. (The Steam Link client sends "qvlclient;hollywood;2.0.20.1812".)
    public var systemName = "unknown", clientVersion = DataDirectory.name

    /// Whether this headset sends eye or face tracking. 
    /// vrlink determines this per headset, so we have to swap
    /// between Quest Pro and Quest 2 for now.
    public var tracksEyesOrFace = false

    /// The strings the Steam Link client ships for a Quest 2 or a Quest Pro
    /// (its `hmd_config.json`); what the host does with other strings is unknown.
    private func staticHMDProps() -> Bytes {
        let serial = tracksEyesOrFace ? "VRLINKHMDQUESTPRO" : "VRLINKHMDQUEST2"
        let model = tracksEyesOrFace ? "Oculus Quest Pro" : "Oculus Quest2"
        return DeviceProfile.staticProps(["oculus", serial, "Oculus", model, "generic_hmd", "vrlink",
                                          "{oculus}/input/rift_profile.json", "rift", "oculus/\(serial)"])
    }

    /// What is published when a hand starts holding a controller, or starts
    /// being tracked bare: the device's identity and battery state (value id
    /// -> bytes).
    static func handValues(_ side: Side, isController: Bool) -> [UInt8: Bytes] {
        let name = side == .left ? "Left" : "Right"
        let power = powerProps(nil, reportsBattery: false)

        // TODO: make this OpenXR-suitable, PSVR2 is visionOS only
        let identity = isController
            ? staticProps(["oculus", "OpenVRLink_Sense_\(name)", "Sony", "PlayStation VR2 Sense (\(name))",
                           "{openvrlink_sense}playstation_vr2_sense_\(name.lowercased())", "openvrlink_sense",
                           "{oculus}/input/touch_profile.json", "oculus_touch", "oculus/OpenVRLink_Sense_\(name)"])
            : staticProps(["vrlink", "VRLINKQ_Hand_\(name)", "VRLink", "VRLink Hand Tracker (\(name) Hand)",
                           "shuttlecock", "vrlink",
                           "{vrlink}/input/svl_hand_interaction_augmented_input_profile.json",
                           "svl_hand_interaction_augmented", "vrlink/VRLINKQ_HandTracker_\(name)"], driverType: 1)
        return [ValueID.staticController(side): identity, ValueID.powerController(side): power]
    }

    /// Two row-major 3x4 matrices, left eye then right. Each one's columns
    /// are the eye's right, up and backward axes and its position, all in
    /// the head's frame.
    /// VTE_PowerProps_t (docs/svl-values/static-and-power-props.md): a mask
    /// of which fields are set, five flags, and the battery level.
    enum PowerProps {
        static let validMask: UInt32 = 0x3F
        /// Flag 2 is "charging" (read from the reference client). The names
        /// of the others are not known; these are the two sets it sends.
        static let flagsWithBattery: UInt32 = 0x1B      // its headset
        static let flagsWithoutBattery: UInt32 = 0x1A   // its controllers and hands, always with level 0
        static let flagCharging: UInt32 = 0x04
    }

    /// `reportsBattery` false is the reference client's constant for a
    /// controller or hand. With it true and no `power` known, a full battery
    /// that is not charging.
    static func powerProps(_ power: PowerState?, reportsBattery: Bool) -> Bytes {
        var out = Bytes()
        out.append(integer: PowerProps.validMask)
        guard reportsBattery else {
            out.append(integer: PowerProps.flagsWithoutBattery)
            out.append(float: 0)
            return out
        }
        out.append(integer: PowerProps.flagsWithBattery | (power?.charging == true ? PowerProps.flagCharging : 0))
        out.append(float: max(0, min(1, power?.level ?? 1)))
        return out
    }

    private func eyeToHead() -> Bytes {
        var out = Bytes()
        for eye in eyesInHead {
            let back = eye.forward * -1
            for value in [eye.right.x, eye.up.x, back.x, eye.position.x,
                          eye.right.y, eye.up.y, back.y, eye.position.y,
                          eye.right.z, eye.up.z, back.z, eye.position.z] { out.append(float: value) }
        }
        return out
    }

    private func projection() -> Bytes {
        var out = Bytes()
        for frustum in eyeFrusta {
            for value in [frustum.left, frustum.right, frustum.down, frustum.up] {
                out.append(float: value)
            }
        }
        return out
    }

    private func chaperone(universe: UInt32) -> Bytes {
        // No play area: four degenerate walls, same as vrlink sends
        // when the headset has no guardian.
        let wall = "[[0,0,0],[0,2.43,0],[0,2.43,0],[0,0,0]]"
        let pose = #"{"translation":[0,0,0],"yaw":0}"#
        let json = #"{"jsonid":"chaperone_info","universes":[{"collision_bounds":["#
            + [wall, wall, wall, wall].joined(separator: ",")
            + #"],"play_area":[0,0],"seated":"# + pose + #","setup_standing2":"# + pose
            + #","standing":"# + pose + #","time":"Thu Jan  1 00:00:00 1970","universeID":"#
            + String(universe) + #"}],"version":5}"#
        return Bytes(json.utf8)
    }

    /// Available refresh rates the headset can switch to
    func availableRates(_ hz: Float) -> Bytes {
        var rates = Bytes()
        rates.append(integer: UInt32(1))
        rates.append(integer: UInt32(1))                       // one rate
        rates.append(zeros: 8)
        rates.append(float: hz)
        return rates
    }

    /// Everything published before video starts. Controllers are published
    /// by the session when a hand first holds one or is first tracked.
    func startupValues() -> [UInt8: Bytes] {
        let instance = UInt64.random(in: 1...UInt64.max) | 1
        var instanceBytes = Bytes(), audio = Bytes()
        instanceBytes.append(integer: instance)
        audio.append(integer: UInt32(3))
        return [
            ValueID.clientInstance: instanceBytes,
            ValueID.projection: projection(),
            ValueID.eyeToHead: eyeToHead(),
            ValueID.availableRates: availableRates(refreshHz),
            ValueID.versionString: Bytes("qvlclient;\(systemName);\(clientVersion)".utf8),
            ValueID.chaperone: chaperone(universe: UInt32(truncatingIfNeeded: instance) & 0x7FFF_FFFF),
            ValueID.hostDefaults: [3, 0, 0, 0, 1, 0, 0, 0],
            ValueID.staticHMD: staticHMDProps(),
            ValueID.powerHMD: DeviceProfile.powerProps(nil, reportsBattery: true),
            ValueID.audioCapabilities: audio,
        ]
    }
}
