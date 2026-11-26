// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import DriverABI
import PatchCore

// `driver_openvrlink` is a device-less SteamVR server driver. `vrserver` loads it into
// the same process as `driver_vrlink`, where it redirects internal calls in `driver_vrlink`
// (see `Scan`) to implement the OpenVRLink protocol extensions (`docs/openvrlink-extensions.md`).
//
// No files on disk are modified, and each hook is optional: if a target function cannot
// be resolved in the installed `driver_vrlink` binary, the corresponding feature is marked
// unavailable and `driver_vrlink` runs unmodified.
//
// `driver_openvrlink` spawns no background threads; periodic work runs inside `vrserver`'s
// `RunFrame` callback.

private enum Provider {
    static var attached: Patches.Attached?
    static var published: (gamma: Bool, status: UnsafeRawPointer)?
    static var lastWork: UInt64 = 0

    static let interfaceNotFound: Int32 = 105       // VRInitError_Init_InterfaceNotFound

    static let versions: UnsafeMutablePointer<UnsafePointer<CChar>?> = {
        let list = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: 3)
        list[0] = Server.cString("IVRSettings_003")
        list[1] = Server.cString("IServerTrackedDeviceProvider_004")
        list[2] = nil
        return list
    }()

    static let object: UnsafeMutablePointer<ovr_provider> = {
        let vtable = UnsafeMutablePointer<ovr_provider_vtable>.allocate(capacity: 1)
        vtable.initialize(to: ovr_provider_vtable(
            init: { _, context in
                guard let context else { return 0 }
                var error: Int32 = 0
                guard let interface = context.pointee.vtable.pointee.get_generic_interface else { return 0 }
                Server.log = interface(context, Server.cString("IVRDriverLog_001"), &error)?.assumingMemoryBound(to: ovr_log.self)
                Server.settings = interface(context, Server.cString("IVRSettings_003"), &error)?.assumingMemoryBound(to: ovr_settings.self)
                Platform.lock()
                Shared.host = HostSide()
                Platform.unlock()
                // Whatever happens next, VR Link must come up: this driver never fails to start.
                return 0
            },
            cleanup: { _ in
                Patches.restoreAll()
                Platform.lock()
                Shared.host = nil
                Platform.unlock()
                Server.publish(gammaAvailable: false, status: "not loaded")
                attached = nil
                published = nil
                Server.log = nil
                Server.settings = nil
            },
            interface_versions: { _ in UnsafePointer(versions) },
            run_frame: { _ in work() },
            should_block_standby: { _ in false },
            enter_standby: { _ in },
            leave_standby: { _ in }))
        let object = UnsafeMutablePointer<ovr_provider>.allocate(capacity: 1)
        object.initialize(to: ovr_provider(vtable: vtable))
        return object
    }()

    /// Called every server frame; does its work a few times a second.
    static func work() {
        guard Server.settings != nil else { return }
        let now = Platform.milliseconds()
        guard now &- lastWork >= 250 || lastWork == 0 else { return }
        lastWork = now
        if attached == nil {
            attached = Patches.attach()
            if let attached {
                Server.say(Message("driver_vrlink found; handshake ").adding(attached.handshake ? "applied" : "not applied")
                    .adding(attached.gamma ? ", encode hooks applied" : ", encode hooks not applied")
                    .adding(attached.floorPerimeter ? ", floor perimeter patch applied" : ""))
            }
        }
        Platform.lock()
        let patched = Shared.shadersPatched, refused = Shared.shadersRefused
        Platform.unlock()
        let hooks = attached?.gamma ?? false
        let gammaAvailable = hooks && patched > 0 && refused == 0
        let status: StaticString
        switch attached {
        case nil: status = "waiting for VR Link to load"
        case let attached? where !attached.handshake: status = "not applied to this VR Link build (see vrserver.txt)"
        case _ where gammaAvailable: status = "handshake and encoding gamma active"
        case _ where hooks && refused > 0: status = "handshake only: the encode shaders have changed"
        case _ where hooks: status = "handshake active; gamma starts when a headset connects"
        default: status = "handshake only (see vrserver.txt)"
        }
        let gammaOn = Server.bool(Server.gammaOnKey, default: true)
        let headsets = Server.headsetsKnown()
        let gamma = Server.float(Server.gammaValueKey, default: Server.defaultGamma)
        // Set in default.vrsettings when openvrlink-companion installs the bundled controller models.
        let models = Server.bool(Server.playForDreamModelsKey, default: false)
        Platform.lock()
        Shared.host?.available = (gammaAvailable ? Handshake.gammaFeature : 0) | (headsets ? Handshake.headsetFeature : 0)
            | (models ? Handshake.playForDreamModelsFeature : 0)
        Shared.host?.enabled = gammaOn ? Handshake.gammaFeature : 0
        Shared.host?.gamma = gamma
        Platform.unlock()
        let text = UnsafeRawPointer(status.utf8Start)
        if published?.gamma != gammaAvailable || published?.status != text {
            Server.publish(gammaAvailable: gammaAvailable, status: status)
            Server.say(status)
            published = (gammaAvailable, text)
        }
    }
}

/// The entry point vrserver looks up in every driver. Steam's watchdog calls it too,
/// inside steam.exe, asking for an interface this driver does not have.
@_cdecl("HmdDriverFactory")
public func HmdDriverFactory(_ interface: UnsafePointer<CChar>?, _ returnCode: UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer? {
    Platform.pinThisLibrary(containing: UnsafeRawPointer(Provider.versions))
    if let interface, strcmp(interface, Server.cString("IServerTrackedDeviceProvider_004")) == 0 {
        return UnsafeMutableRawPointer(Provider.object)
    }
    returnCode?.pointee = Provider.interfaceNotFound
    return nil
}
