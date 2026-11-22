// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Display, tracking, and controller properties advertised to the host
/// (docs/svl-values/). A newly started host will not begin streaming video until it
/// receives the projection, chaperone, HMD static and power properties, host defaults,
/// and available refresh rates.
public struct DeviceProfile {
    /// Left and right eye poses in head space.
    /// Normalized to the OpenXR convention where the head pose is the midpoint between both eyes.
    public var eyesInHead = [DeviceProfile.eye(right: -0.0315), DeviceProfile.eye(right: 0.0315)]

    /// Returns a forward-facing eye pose offset by `meters` along the +X (right) axis.
    public static func eye(right meters: Float) -> Pose {
        Pose(position: Vec3(meters, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
    }
    /// Per-eye render target resolution (SteamVR's 100% render target) to request from
    /// the host when known by the platform. If omitted, the host defaults to 2048 x 1844.
    /// Encoded video resolution is controlled separately from the application render target.
    ///
    /// On the wire, the client sends a panel display size that the host multiplies by ~1.1436
    /// on each axis to compute the render target (for example, 2160 -> 2472, 3200 -> 3660,
    /// 3660 -> 4184, 4096 -> 4684). We divide `eyePixels` by `renderTargetPerDisplayPixel`
    /// before sending so SteamVR lands on the requested render target (within 4-pixel rounding).
    public var eyePixels: (width: Int, height: Int)?
    /// Ratio of SteamVR's 100% render target resolution to the reported panel display size on each axis.
    static let renderTargetPerDisplayPixel: Float = 1.1436
    public var refreshHz: Float = 90
    /// Additional display refresh rates supported by the platform when dynamic rate switching
    /// is available (`StreamSession.onRefreshRateRequested`). The host selects the closest match
    /// among `refreshHz` and these rates. Leave empty when the display refresh rate is fixed.
    public var otherRefreshRates: [Float] = []
    /// Per-eye projection frusta, ordered `[left, right]`.
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
        /// Sent by the host when SteamVR requests a recenter (docs/svl-values/vte-id-table.md).
        static let recenter: UInt8 = 0x16
        /// Sent by the host: non-zero while a scene application is running, and zero
        /// when idle in the SteamVR grid (docs/svl-values/vte-id-table.md; inferred).
        static let sceneApplicationRunning: UInt8 = 0x35
    }

    /// Serializes `VTE_StaticProps_t` (1161 bytes), which describes a device to SteamVR using nine
    /// strings in order: tracking system, serial, manufacturer, model, render model,
    /// resource root, input profile, controller type, and device type.
    private static func staticProps(_ strings: [String], driverType: UInt8 = 0) -> Bytes {
        var out = Bytes()
        out.append(integer: UInt32(0x7FF))
        for text in strings[..<7] { out.append(text: text, fieldSize: 128) }
        out.append(float: 0)                                   // laser-mouse angle
        for text in strings[7...] { out.append(text: text, fieldSize: 128) }
        out.append(driverType)
        return out
    }

    /// Platform name and client version fields for the `qvlclient;<systemName>;<clientVersion>`
    /// version string sent to the host (for example, `"qvlclient;visionOS;OpenVRLink 0.1.0-2"`).
    /// Set by the platform app; `vrlink` on Quest sends `"qvlclient;hollywood;2.0.20.1812"`.
    public var systemName = "unknown", clientVersion = DataDirectory.name

    /// Experimental option to advertise controllers as PlayStation VR2 Sense controllers
    /// with custom render models so SteamVR renders the physical controllers accurately.
    /// Requires an `openvrlink_sense` driver resource directory to be installed on the host
    /// manually. When false, controllers are advertised as Quest 2 Touch controllers and use
    /// SteamVR's built-in Touch render models (docs/svl-values/static-and-power-props.md).
    public var senseControllerModels = false

    /// Whether this headset sends eye or face tracking to a SteamVR host.
    /// This also controls the HMD model name reported to SteamVR, because the host
    /// gates capabilities by model name and no built-in profile in `vrlink` 2.0.25
    /// enables every feature at once:
    ///
    /// - Unrecognized model name: honors the requested `eyePixels` render target and
    ///   enables the standard SteamVR dashboard, but limits video to 8-bit and disables
    ///   the eye-tracking input component.
    /// - Known Quest, Pico, or Vive model names: enables 10-bit video and the standard
    ///   dashboard, but overrides `eyePixels` with a hardcoded per-model render target.
    ///   Among those, Quest Pro, Pico 4 Pro, Pico Neo 3, and Vive Focus Vision enable
    ///   eye tracking; Pico Neo 3 and Vive Focus Vision have the highest fixed render
    ///   target at 2480 x 2480.
    /// - Steam Frame (`"Deckard MP"`): honors `eyePixels` and enables 10-bit video and
    ///   eye tracking, but expects the headset to render its own dashboard, leaving the
    ///   system button non-functional.
    ///
    /// When the host has `driver_openvrlink` installed, its default settings define custom
    /// `vrlink_<model>` sections (`enable`, `supports10bit`, `supportsEyeTracking`, and `-1`
    /// for `recommendedRenderWidth`/`Height`) for our native model names (`hostKnowsHeadset`),
    /// enabling 10-bit video, eye tracking, and the requested `eyePixels` render target
    /// together. On other hosts, we report `"OpenVRLink Headset"` when `tracksEyesOrFace` is
    /// false and `"Vive Focus Vision"` when true. Controller profiles are reported
    /// independently via `handValues`, and Quest Touch controllers work alongside any of these
    /// HMD profiles.
    public var tracksEyesOrFace = false
    /// Whether the platform provides eye gaze tracking (even approximate). Reported to WiVRn
    /// hosts directly; SteamVR hosts instead check `tracksEyesOrFace`, which also switches
    /// the reported HMD model.
    public var tracksGaze = false

    /// True when the host previously advertised `vrlink_<model>` settings for `ownModel`
    /// (`HostExtensions.Features.headsetSettings`), which `driver_openvrlink` provides in its
    /// `default.vrsettings`. Because the host only sends extension records after streaming
    /// starts, after the client has already sent its static HMD properties, this flag comes
    /// from the previous session with that host (`KnownHosts`).
    public var hostKnowsHeadset = false

    /// Returns the native `(model, manufacturer)` pair for this device. Windows builds of
    /// `driver_vrlink` (SteamVR 2.19.4) recognize `"Apple Vision Pro M2"` and `"Apple Vision Pro M5"`
    /// with a fixed 1800 x 1920 render target and no eye tracking, while `"Apple Vision Pro"`
    /// is treated as an unknown model. We report `"Apple Vision Pro (OpenVRLink)"`, which uses the
    /// `vrlink_Apple Vision Pro (OpenVRLink)` settings section, so a later driver that adds the plain
    /// name will not override our settings.
    var ownModel: (model: String, manufacturer: String) {
        systemName == "visionOS" ? ("Apple Vision Pro (OpenVRLink)", "Apple") : (DeviceProfile.headsetModel, "OpenVRLink")
    }

    private func staticHMDProps() -> Bytes {
        if hostKnowsHeadset {
            let serial = DeviceProfile.headsetSerial, own = ownModel
            return DeviceProfile.staticProps(["oculus", serial, own.manufacturer, own.model, "generic_hmd", "vrlink",
                                              "{oculus}/input/rift_profile.json", "rift", "oculus/\(serial)"])
        }
        if tracksEyesOrFace {
            // Static HMD properties sent by vrlink on a Vive Focus Vision.
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

    /// Builds the static identity and battery property values (`ValueID -> Bytes`) published
    /// when a controller or tracked hand becomes active.
    func handValues(_ side: Side, isController: Bool) -> [UInt8: Bytes] {
        let name = side == .left ? "Left" : "Right"
        let power = DeviceProfile.powerProps(nil, reportsBattery: false)
        let staticProps = DeviceProfile.staticProps

        // TODO: make this OpenXR-suitable, PSVR2 is visionOS only
        let controller = senseControllerModels
            ? staticProps(["oculus", "OpenVRLink_Sense_\(name)", "Sony", "PlayStation VR2 Sense (\(name))",
                           "{openvrlink_sense}playstation_vr2_sense_\(name.lowercased())", "openvrlink_sense",
                           "{oculus}/input/touch_profile.json", "oculus_touch", "oculus/OpenVRLink_Sense_\(name)"], 0)
            // Static controller properties sent by vrlink for a Quest 2 Touch controller.
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

    /// `VTE_PowerProps_t` constants (docs/svl-values/static-and-power-props.md): a validity
    /// bitmask, five status flags, and a `0...1` battery level.
    enum PowerProps {
        static let validMask: UInt32 = 0x3F
        /// Bit 2 indicates charging (observed in `vrlink`). The remaining flag bits are
        /// undocumented; these two presets match what `vrlink` sends.
        static let flagsWithBattery: UInt32 = 0x1B      // HMD
        static let flagsWithoutBattery: UInt32 = 0x1A   // controllers and hands (always sent with level 0)
        static let flagCharging: UInt32 = 0x04
    }

    /// Serializes `VTE_PowerProps_t`. Pass `reportsBattery: false` for controllers and hands
    /// (matching `vrlink`). When `reportsBattery` is true and `power` is `nil`, reports a
    /// full, non-charging battery.
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

    /// Serializes two row-major 3x4 eye-to-head matrices (left, then right) whose columns
    /// are the eye's right, up, and backward (+Z) basis vectors and head-space position.
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

    /// Initial empty chaperone payload; `StreamSession.setBoundary` publishes updates once a room is active.
    private func chaperone(universe: UInt32) -> Bytes {
        Bytes(PlaySpace.trackingSpace.chaperone(universe: universe).utf8)
    }

    /// `VTE_CAPABILITIES` 32-byte feature bitfield. `vrlink` sets only bit 0 (meaning unknown).
    /// Bit 45 advertises chroma-key passthrough according to host logs and is left unset here.
    static let capabilities: Bytes = [1] + Bytes(repeating: 0, count: 31)

    /// Serializes the list of supported refresh rates: validity mask (`1`), count, 8 zero bytes, and each rate in Hz.
    func availableRates(_ rates: [Float]) -> Bytes {
        var out = Bytes()
        out.append(integer: UInt32(1))
        out.append(integer: UInt32(rates.count))
        out.append(zeros: 8)
        for hz in rates { out.append(float: hz) }
        return out
    }

    /// Initial device properties published before video streaming begins. Controller and
    /// hand properties are published dynamically by the session once tracked.
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
            ValueID.eyePixels: pixels,                   // omitted on the wire when empty
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
