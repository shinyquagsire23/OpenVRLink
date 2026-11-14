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
    /// How many pixels the host should recommend that applications draw
    /// for each eye, across and down, where the platform has a figure: the
    /// host's "Render Target", which SteamVR calls 100%. Told nothing, the
    /// host recommends 2048 x 1844. The size of the stream itself does not
    /// depend on it.
    ///
    /// What the host is sent is a display size, which it multiplies by
    /// about 1.14 each way to get the render target (probed 2026-11-13:
    /// 2160 gave 2472, 3200 gave 3660, 3660 gave 4184, 4096 gave 4684). So
    /// what is sent is this divided by that, and the render target comes
    /// out as asked, to within the host's rounding to a multiple of four.
    public var eyePixels: (width: Int, height: Int)?
    /// The host's render target over the display size it is sent, each way.
    static let renderTargetPerDisplayPixel: Float = 1.1436
    public var refreshHz: Float = 90
    /// Other rates the display can be asked to refresh at, where a
    /// platform has a way to ask (`StreamSession.onRefreshRateRequested`).
    /// The host picks from these and `refreshHz` the rate nearest the one
    /// it wants. Empty where the display's rate is not the client's to choose.
    public var otherRefreshRates: [Float] = []
    /// Each eye's frustum, left then right
    public var eyeFrusta = [Frustum.symmetric(halfAngleDegrees: 45), Frustum.symmetric(halfAngleDegrees: 45)]

    public init() {}

    enum ValueID {
        static let clientInstance: UInt8 = 0x01, hostInstance: UInt8 = 0x02
        static let projection: UInt8 = 0x04, chaperone: UInt8 = 0x05, capabilities: UInt8 = 0x06, eyeToHead: UInt8 = 0x08
        static let eyePixels: UInt8 = 0x09
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

    /// Experiment: name the controllers as PlayStation VR2 Sense
    /// controllers with a model of their own, so that SteamVR draws what is
    /// really in the hand. The model has to be on the host already, as a
    /// driver's resources called `openvrlink_sense`; nothing installs it yet.
    /// Otherwise the controllers are a Quest 2's Touch pair in every string,
    /// and SteamVR draws its own Touch models
    /// (docs/svl-values/static-and-power-props.md).
    public var senseControllerModels = false

    /// Whether this headset sends where the eyes look, or the face. It
    /// decides which headset the host is told this is, because the host
    /// chooses how to treat a headset by its model name and no name it
    /// knows gets everything (probed 2026-11-13, every name Steam Link
    /// 2.0.25 ships and the Steam Frame's):
    ///
    /// - A name it does not know: the render target asked for
    ///   (`eyePixels`) and the ordinary dashboard, but no eye-tracking
    ///   input component, and an 8-bit picture.
    /// - Any Quest, Pico or Vive name: a 10-bit picture and the ordinary
    ///   dashboard, but the host replaces the render target with a fixed
    ///   one for that model. Of those, the Quest Pro, Pico 4 Pro, Pico
    ///   Neo 3 and Vive Focus Vision get the eye-tracking component; the
    ///   last two have the largest fixed render target, 2480 x 2480.
    /// - The Steam Frame's name ("Deckard MP"): the render target asked
    ///   for, 10 bits and eye tracking, but the host leaves the dashboard
    ///   to the headset, as that headset draws its own; the system button
    ///   then opens nothing.
    ///
    /// So without eye tracking the headset is itself, an unknown model;
    /// with it, a Vive Focus Vision. The controllers are described
    /// separately (`handValues`), and Touch controllers work beside either.
    ///
    /// A host can be told about an unknown model in its own settings (a
    /// section named `vrlink_` and the model name, with `enable`,
    /// `serialNumber`, `supports10bit`, `supportsEyeTracking`,
    /// `recommendedRenderWidth` and `recommendedRenderHeight`); with that
    /// the unknown model got 10 bits and the size from the settings
    /// (probed 2026-11-13). Nothing writes that section yet.
    public var tracksEyesOrFace = false

    private func staticHMDProps() -> Bytes {
        if tracksEyesOrFace {
            // What the Steam Link client sends on a Vive Focus Vision.
            return DeviceProfile.staticProps(["htc", "VRLINKHMDVIVEFOCUSVISION", "HTC", "Vive Focus Vision", "generic_hmd", "vrlink",
                                              "{htc}/input/vive_controller_profile.json", "vive_focus",
                                              "htc/VRLINKHMDVIVEFOCUSVISION"])
        }
        let serial = DeviceProfile.headsetSerial
        return DeviceProfile.staticProps(["oculus", serial, "OpenVRLink", DeviceProfile.headsetModel, "generic_hmd", "vrlink",
                                          "{oculus}/input/rift_profile.json", "rift", "oculus/\(serial)"])
    }
    static let headsetSerial = "OpenVRLink-HMD"
    static let headsetModel = "OpenVRLink Headset"

    /// What is published when a hand starts holding a controller, or starts
    /// being tracked bare: the device's identity and battery state (value id
    /// -> bytes).
    func handValues(_ side: Side, isController: Bool) -> [UInt8: Bytes] {
        let name = side == .left ? "Left" : "Right"
        let power = DeviceProfile.powerProps(nil, reportsBattery: false)
        let staticProps = DeviceProfile.staticProps

        // TODO: make this OpenXR-suitable, PSVR2 is visionOS only
        let controller = senseControllerModels
            ? staticProps(["oculus", "OpenVRLink_Sense_\(name)", "Sony", "PlayStation VR2 Sense (\(name))",
                           "{openvrlink_sense}playstation_vr2_sense_\(name.lowercased())", "openvrlink_sense",
                           "{oculus}/input/touch_profile.json", "oculus_touch", "oculus/OpenVRLink_Sense_\(name)"], 0)
            // What the Steam Link client sends for a Quest 2's Touch controller.
            : staticProps(["oculus", "VRLINKQ2_Controller_\(name)", "Oculus", "Oculus Quest2 (\(name) Controller)",
                           "oculus_quest2_controller_\(name.lowercased())", "vrlink",
                           "{oculus}/input/touch_profile.json", "oculus_touch", "oculus/VRLINKQ2_Controller_\(name)"], 0)
        let identity = isController
            ? controller
            : staticProps(["vrlink", "VRLINKQ_Hand_\(name)", "VRLink", "VRLink Hand Tracker (\(name) Hand)",
                           "shuttlecock", "vrlink",
                           "{vrlink}/input/svl_hand_interaction_augmented_input_profile.json",
                           "svl_hand_interaction_augmented", "vrlink/VRLINKQ_HandTracker_\(name)"], 1)
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

    /// VTE_CAPABILITIES: 32 bytes of flags for what this client can do.
    /// The Steam Link client sets only the first bit, whose meaning is
    /// not known. Bit 45 is "supports chroma key passthrough" as the host
    /// logs it (probed 2026-11-13); not claimed here.
    static let capabilities: Bytes = [1] + Bytes(repeating: 0, count: 31)

    /// The refresh rates the host may choose from: a mask of one field, how many, eight zeros, then each in Hz.
    func availableRates(_ rates: [Float]) -> Bytes {
        var out = Bytes()
        out.append(integer: UInt32(1))
        out.append(integer: UInt32(rates.count))
        out.append(zeros: 8)
        for hz in rates { out.append(float: hz) }
        return out
    }

    /// Everything published before video starts. Controllers are published
    /// by the session when a hand first holds one or is first tracked.
    func startupValues() -> [UInt8: Bytes] {
        let instance = UInt64.random(in: 1...UInt64.max) | 1
        var instanceBytes = Bytes(), audio = Bytes()
        instanceBytes.append(integer: instance)
        audio.append(integer: UInt32(3))
        var pixels = Bytes()
        if let eyePixels {
            pixels.append(integer: UInt32((Float(eyePixels.width) / DeviceProfile.renderTargetPerDisplayPixel).rounded()))
            pixels.append(integer: UInt32((Float(eyePixels.height) / DeviceProfile.renderTargetPerDisplayPixel).rounded()))
        }
        return [
            ValueID.eyePixels: pixels,                   // empty, and so never sent, when not known
            ValueID.clientInstance: instanceBytes,
            ValueID.capabilities: DeviceProfile.capabilities,
            ValueID.projection: projection(),
            ValueID.eyeToHead: eyeToHead(),
            ValueID.availableRates: availableRates(([refreshHz] + otherRefreshRates.filter { $0 != refreshHz }).sorted()),
            ValueID.versionString: Bytes("qvlclient;\(systemName);\(clientVersion)".utf8),
            ValueID.chaperone: chaperone(universe: UInt32(truncatingIfNeeded: instance) & 0x7FFF_FFFF),
            ValueID.hostDefaults: [3, 0, 0, 0, 1, 0, 0, 0],
            ValueID.staticHMD: staticHMDProps(),
            ValueID.powerHMD: DeviceProfile.powerProps(nil, reportsBattery: true),
            ValueID.audioCapabilities: audio,
        ]
    }
}
