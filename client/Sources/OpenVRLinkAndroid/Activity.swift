// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Android)
import Android
import CAndroidNDK
import Foundation
import VRLinkAndroidAudio
import VRLinkCore
import VRLinkMediaCodec
import VRLinkOpenXR
import VRLinkVulkan

/// Runs the OpenVRLink streaming client on Android XR as a native OpenXR application.
///
/// Android's built-in `NativeActivity` loads `libOpenVRLinkAndroid.so` and calls `ANativeActivity_onCreate`
/// on the main thread, which spawns a background thread to run the OpenXR session, MediaCodec video
/// decoder, Vulkan renderer, and AAudio output.
///
/// Because there is no in-headset UI yet, the app connects to the host specified in `host.txt` inside its
/// internal data directory (`steam://address`, `wivrn://address[:port]`, or a bare IP/hostname for Steam),
/// or falls back to the first discovered Steam host. Connection status and pairing PINs are logged to
/// `logcat` under the `OpenVRLink` tag.
final class App {
    static let shared = App()

    private var display: XRDisplay<VulkanXRGraphics>?
    private var audio: AudioOutput?

    private static func property(_ name: String) -> String {
        var value = [CChar](repeating: 0, count: 92)        // PROP_VALUE_MAX
        return __system_property_get(name, &value) > 0 ? String(cString: value) : ""
    }

    /// Selects a target host from `host.txt` if present, or otherwise discovers a Steam host on the local network.
    private func chooseHost() -> (kind: HostKind, address: String, port: UInt16?)? {
        let file = DataDirectory.url.appendingPathComponent("host.txt")
        if let named = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            if named.hasPrefix("wivrn://") {
                var address = String(named.dropFirst("wivrn://".count))
                var port: UInt16?
                if let colon = address.lastIndex(of: ":"), let given = UInt16(address[address.index(after: colon)...]) {
                    port = given
                    address = String(address[..<colon])
                }
                return (.wivrn, address, port)
            }
            return (.steam, named.hasPrefix("steam://") ? String(named.dropFirst("steam://".count)) : named, nil)
        }
        // TODO: Add an Android mDNS browser so WiVRn hosts can be discovered automatically.
        Log.note("searching for Steam hosts (no host configured in \(file.path))")
        let identity = Identity()
        guard let searcher = UDPSocket() else { return nil }
        let usable = Broadcast.discover(searcher, deviceID: identity.deviceID).filter(\.offersVRLink)
        for found in usable { Log.note("  \(found.hostname) at \(found.address)") }
        return (usable.first { identity.isPaired(withHost: $0.clientID) } ?? usable.first).map { (.steam, $0.address, nil) }
    }

    func run(javaVM: UnsafeMutableRawPointer?, activity: UnsafeMutableRawPointer?) {
        let settings = Settings.load()
        let link = StreamLink(decoder: MediaCodecDecoder())
        link.onStatus = { Log.note($0) }
        link.onStarted = { [weak self] session in self?.audio = AudioOutput(buffer: session.audio) }
        link.onStopped = { [weak self] in self?.audio = nil }

        let display: XRDisplay<VulkanXRGraphics>
        do {
            display = try XRDisplay(applicationName: "OpenVRLink", graphics: VulkanXRGraphics { Log.note($0) }, frames: link.frames,
                                    process: XRProcess(javaVM: javaVM, activity: activity)) { Log.note($0) }
        } catch {
            Log.note("could not start OpenXR: \(error)")
            return
        }
        self.display = display
        let model = App.property("ro.product.model")
        display.streamingSession = { link.session }
        display.onPaused = { link.stop() }
        display.onReady = { [weak self] measured in
            var scaled = measured
            scaled.systemName = "Android"
            scaled.eyeFrusta = scaled.eyeFrusta.map {
                $0.scaled(horizontal: settings.fovScaleHorizontal, vertical: settings.fovScaleVertical)
            }
            let profile = scaled
            link.playSpace = PlaySpace(origin: PlaySpace.trackingSpace.origin, boundary: display.boundary())
            // Run host discovery and connection setup off the render thread so network I/O does not block frames.
            Thread.detachNewThread { [weak self] in
                guard let self, let host = self.chooseHost() else {
                    Log.note("no host found; specify an address in host.txt")
                    return
                }
                var connector = HostConnector(deviceName: HostConnector.name(of: model.isEmpty ? "Android XR headset" : model),
                                              deviceModel: model.isEmpty ? display.instance.systemName() : model,
                                              systemVersion: "Android " + App.property("ro.build.version.release"))
                connector.log = { Log.note($0) }
                connector.show = { Log.note($0) }
                var inputs = StreamLink<MediaCodecDecoder>.Inputs(head: { display.input.head() }, hands: { display.input.hands() })
                inputs.haptic = { display.input.vibrate($0) }
                inputs.refreshRateRequested = { display.requestRefreshRate($0) }
                link.start(host.kind, address: host.address, port: host.port, profile: profile, connector: connector, inputs: inputs)
            }
        }
        do {
            try display.run()
        } catch {
            Log.note("OpenXR session failed: \(error)")
        }
        link.stop(leaving: true)
        self.display = nil
    }

    func quit() {
        display?.quit()
    }
}

/// Entry point called by Android's `NativeActivity` on the main UI thread, which must return promptly without blocking.
@_cdecl("ANativeActivity_onCreate")
public func activityCreated(_ activity: UnsafeMutablePointer<ANativeActivity>?, _ savedState: UnsafeMutableRawPointer?, _ savedSize: Int) {
    guard let activity else { return }
    // Point XDG_DATA_HOME, HOME, and TMPDIR at the app's internal files directory for DataDirectory.
    if let files = activity.pointee.internalDataPath {
        setenv("XDG_DATA_HOME", files, 1)
        setenv("HOME", files, 1)
        setenv("TMPDIR", files, 1)
    }
    Log.write = { line in _ = __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), "OpenVRLink", line) }

    activity.pointee.callbacks.pointee.onDestroy = { _ in App.shared.quit() }
    // `vm` and `clazz` (a JNI global reference to the Activity) remain valid for the lifetime of the process.
    nonisolated(unsafe) let vm = activity.pointee.vm
    nonisolated(unsafe) let object = UnsafeMutableRawPointer(activity.pointee.clazz)
    let thread = Thread {
        // Attach this thread to the JVM so the OpenXR loader and runtime can make JNI calls.
        var environment: UnsafeMutablePointer<JNIEnv?>?
        if let vm { _ = vm.pointee?.pointee.AttachCurrentThread(vm, &environment, nil) }
        App.shared.run(javaVM: UnsafeMutableRawPointer(vm), activity: object)
        if let vm { _ = vm.pointee?.pointee.DetachCurrentThread(vm) }
    }
    thread.name = "openxr"
    thread.qualityOfService = .userInteractive
    thread.start()
}
#endif
