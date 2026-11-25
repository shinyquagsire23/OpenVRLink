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
import VRLinkPanel
import VRLinkVulkan
import VRLinkXRClient

/// Runs the Android client on top of Android's built-in `NativeActivity`, which loads `libOpenVRLinkAndroid.so`
/// and calls `ANativeActivity_onCreate` without custom Java or Kotlin subclasses.
///
/// Standalone headsets differ in how they launch VR apps, so `AndroidManifest.xml` declares two entry points and
/// `build.sh --flat` selects which one gets the launcher category:
///
/// - `android.app.NativeActivity` starts directly in an immersive OpenXR session (`XRClient`) with the panel
///   shown as a quad layer in front of the user.
/// - `.Panel` is an `<activity-alias>` without the immersive XR metadata, so Android opens it as a 2D window.
///   `App` blits the panel buffer to the window surface, forwards touch events, and starts the immersive activity
///   once the user picks a host.
///
/// Both activities run in the same process and share one `ClientModel` and `Panel`, so a host picked in the 2D
/// window carries over into the immersive session. `App` connects `XRClient` to MediaCodec, Vulkan, AAudio,
/// runtime permission prompts, and `HeadsetQuirks`.
final class App: @unchecked Sendable {
    static let shared = App()

    /// Manifest suffix for the 2D window activity alias.
    static let flatSuffix = ".Panel"
    static let immersiveClass = "android.app.NativeActivity"
    static let handTracking = "android.permission.HAND_TRACKING"
    /// Required on Android XR for OpenXR eye gaze tracking.
    static let eyeTracking = "android.permission.EYE_TRACKING_FINE"
    static let faceTracking = "android.permission.FACE_TRACKING"
    static let recordAudio = "android.permission.RECORD_AUDIO"

    private var vm: UnsafeMutablePointer<JavaVM?>?
    private var model: ClientModel?
    private var panel: Panel?
    private var quirks = HeadsetQuirks()
    private var device = DeviceIdentity(name: "Android XR headset", model: "Android XR headset", systemName: "Android",
                                        systemVersion: "Android")
    /// Guards access to `panel`. The immersive session holds this lock while running, and the 2D window loop
    /// acquires it per frame when idle.
    private let panelLock = NSLock()

    /// Protects shared state accessed from main-thread `ANativeActivity` callbacks and background worker threads.
    private let lock = NSLock()
    private var flat: UnsafeMutablePointer<ANativeActivity>?
    private var flatWindow: OpaquePointer?
    /// On-screen dimensions of the 2D window used to scale touch coordinates into panel pixel coordinates.
    private var flatSize: (width: Float, height: Float) = (1, 1)
    private var flatNeedsPicture = false
    private var flatQueue: OpaquePointer?
    private var queues: [OpaquePointer] = []
    private var touch: (x: Float, y: Float, pressed: Bool)?
    /// Remaining frames to keep reporting a released touch position so ImGui registers the button release.
    private var touchLingers = 0
    /// Back-button state and minimum hold deadline (uptime in nanoseconds) so brief presses aren't missed
    /// between polls. Guarded by `lock`.
    private var backDown = false, backHeldUntil: UInt64 = 0
    private var keysNoted: Set<Int32> = []

    private var immersive: UnsafeMutablePointer<ANativeActivity>?
    private var quitImmersive: (() -> Void)?
    private var immersiveDone: DispatchSemaphore?
    private var pauses = 0, resumed = true
    private var microphone = MicrophoneInput()
    private var microphoneWanted = 0
    private var audio: AudioOutput?

    private static func property(_ name: String) -> String {
        var value = [CChar](repeating: 0, count: 92)        // PROP_VALUE_MAX
        return __system_property_get(name, &value) > 0 ? String(cString: value) : ""
    }

    private func with<Result>(_ activity: UnsafeMutablePointer<ANativeActivity>, _ body: (ActivityCalls) -> Result) -> Result? {
        guard let vm, let object = activity.pointee.clazz else { return nil }
        return Java.attached(to: vm) { body(ActivityCalls(java: $0, activity: object)) }
    }

    // MARK: Startup

    /// Sets up data directories, logging, device info, `ClientModel`, and `Panel` the first time an activity is
    /// created.
    private func setUp(_ activity: UnsafeMutablePointer<ANativeActivity>) {
        guard model == nil else { return }
        vm = activity.pointee.vm
        // Point XDG_DATA_HOME, HOME, and TMPDIR at the app's internal files directory for DataDirectory.
        if let files = activity.pointee.internalDataPath {
            setenv("XDG_DATA_HOME", files, 1)
            setenv("HOME", files, 1)
            setenv("TMPDIR", files, 1)
        }
        Log.write = { line in _ = __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), "OpenVRLink", line) }

        let named = App.property("ro.product.model")
        let modelName = named.isEmpty ? "Android XR headset" : named
        quirks = HeadsetQuirks(HeadsetQuirks.identify(manufacturer: App.property("ro.product.manufacturer"), model: named,
                                                      device: App.property("ro.product.device"), product: App.property("ro.product.name")))
        quirks.apply { name in
            let value = App.property("debug.openvrlink." + name)
            return value.isEmpty ? nil : value
        }
        Log.note("headset \(App.property("ro.product.manufacturer")) \(named) (\(App.property("ro.product.device"))): \(quirks.summary)")
        let version = with(activity) { $0.versionName() } ?? nil
        device = DeviceIdentity(name: (with(activity) { $0.deviceName() } ?? nil) ?? modelName, model: modelName, systemName: "Android",
                                systemVersion: "Android " + App.property("ro.build.version.release"),
                                clientVersion: DataDirectory.name + (version.map { " " + $0 } ?? ""))

        let model = ClientModel(finder: HostFinder(services: MulticastDNS(type: WiVRn.serviceType)))
        self.model = model
        let panel = Panel(model: model, features: [.microphone])
        panel.caption = (version.map { "v" + $0 + "  " } ?? "") + modelName
        self.panel = panel
        model.search()

        let thread = Thread { [self] in windowLoop() }
        thread.name = "panel"
        thread.start()
    }

    func created(_ activity: UnsafeMutablePointer<ANativeActivity>) {
        setUp(activity)
        let callbacks = activity.pointee.callbacks
        callbacks?.pointee.onDestroy = { activity in activity.map { App.shared.destroyed($0) } }
        callbacks?.pointee.onPause = { _ in App.shared.paused(true) }
        callbacks?.pointee.onResume = { _ in App.shared.paused(false) }
        callbacks?.pointee.onNativeWindowCreated = { activity, window in App.shared.window(activity, window) }
        callbacks?.pointee.onNativeWindowDestroyed = { activity, _ in App.shared.window(activity, nil) }
        callbacks?.pointee.onInputQueueCreated = { activity, queue in App.shared.input(activity, queue, attached: true) }
        callbacks?.pointee.onInputQueueDestroyed = { activity, queue in App.shared.input(activity, queue, attached: false) }

        let component = (with(activity) { $0.componentClass() } ?? nil) ?? App.immersiveClass
        if component.hasSuffix(App.flatSuffix) {
            Log.note("activity: flat panel")
            lock.lock()
            flat = activity
            let running = immersive != nil
            lock.unlock()
            if !running { model?.startStream = { [weak self] _ in self?.enterImmersive() } }
            return
        }
        Log.note("activity: immersive")
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        immersive = activity
        immersiveDone = done
        lock.unlock()
        nonisolated(unsafe) let activity = activity
        let thread = Thread { [self] in
            // Attach this thread to the JVM for as long as it runs, since the OpenXR loader and runtime make JNI calls.
            var environment: UnsafeMutablePointer<JNIEnv?>?
            if let vm { _ = vm.pointee?.pointee.AttachCurrentThread(vm, &environment, nil) }
            runImmersive(activity)
            if let vm { _ = vm.pointee?.pointee.DetachCurrentThread(vm) }
            done.signal()
        }
        thread.name = "openxr"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func destroyed(_ activity: UnsafeMutablePointer<ANativeActivity>) {
        lock.lock()
        let wasImmersive = immersive == activity
        let quit = quitImmersive, done = immersiveDone
        if wasImmersive { immersive = nil }
        if flat == activity {
            flat = nil
            flatWindow = nil
            flatQueue = nil
        }
        lock.unlock()
        guard wasImmersive else { return }
        quit?()
        // Give the session a moment to end while the activity's Java object is still there to be called.
        _ = done?.wait(timeout: .now() + 2)
    }

    private func paused(_ now: Bool) {
        lock.lock()
        if now { pauses += 1 }
        resumed = !now
        lock.unlock()
    }

    // MARK: Immersive activity

    /// Requests runtime `permissions` via JNI and waits for the user to respond. Because receiving
    /// `onRequestPermissionsResult` requires a Java subclass, we detect the system prompt by watching the
    /// activity pause and resume and then re-checking permission status.
    private func ask(for permissions: [String], from activity: UnsafeMutablePointer<ANativeActivity>) {
        let needed = permissions.filter { name in with(activity) { $0.knows(name) && !$0.has(name) } ?? false }
        guard !needed.isEmpty else { return }
        Log.note("permissions: asking for \(needed.joined(separator: ", "))")
        lock.lock()
        let before = pauses
        lock.unlock()
        _ = with(activity) { $0.request(needed) }
        func state() -> (prompted: Bool, back: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (pauses > before, resumed)
        }
        // If the activity does not pause within 3 seconds, Android auto-denied the request without showing a dialog.
        var waited = 0.0
        while !state().prompted, waited < 3 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        while state().prompted, !state().back, waited < 120 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        for name in needed {
            Log.note("permissions: \(name) \(with(activity) { $0.has(name) } == true ? "granted" : "not granted")")
        }
    }

    private func runImmersive(_ activity: UnsafeMutablePointer<ANativeActivity>) {
        guard let model, let panel else { return }
        // Request hand, eye, and face tracking permissions before creating the OpenXR instance, since the runtime
        // checks granted permissions at instance creation.
        ask(for: [App.handTracking, App.eyeTracking, App.faceTracking], from: activity)

        var platform = XRPlatform(device: device)
        platform.gripOffset = quirks.gripOffset
        platform.systemButton = { [weak self] in
            guard let self else { return false }
            lock.lock()
            defer { lock.unlock() }
            return backDown || Uptime.nanoseconds < backHeldUntil
        }
        // Android routes sockets over the default network unless explicitly bound by handle, and a direct USB or
        // Ethernet link to a PC without internet access never becomes the default.
        platform.preferredInterfaces = { [weak self] in self?.with(activity) { $0.wiredNetworks().map(\.name) } ?? [] }
        NetworkInterfaces.bind = { [weak self] descriptor, name in
            guard let handle = self?.with(activity, { $0.wiredNetworks().first { $0.name == name }?.handle }) ?? nil else { return false }
            return android_setsocknetwork(net_handle_t(bitPattern: handle), descriptor) == 0
        }
        platform.startAudio = { [weak self] session in self?.audio = AudioOutput(buffer: session.audio) }
        platform.stopAudio = { [weak self] in self?.audio = nil }
        platform.startMicrophone = { [weak self] sink in self?.startMicrophone(into: sink, from: activity) }
        platform.stopMicrophone = { [weak self] in
            guard let self else { return }
            lock.lock()
            microphoneWanted += 1
            lock.unlock()
            microphone.stop()
        }

        panelLock.lock()
        defer {
            // Restore panel and model callbacks for the 2D window when the immersive session exits.
            NetworkInterfaces.bind = nil
            panel.showsPointer = false
            panel.hint = ""
            panel.pointer = nil
            model.stopStream = nil
            model.startStream = { [weak self] _ in self?.enterImmersive() }
            if model.state.phase != .choosing { model.streamEnded("Not connected") }
            lock.lock()
            quitImmersive = nil
            flatNeedsPicture = true
            let stillThere = immersive == activity
            lock.unlock()
            panelLock.unlock()
            // Finish the activity if the OpenXR session exited on its own.
            if stillThere { ANativeActivity_finish(activity) }
        }
        let client: XRClient<VulkanXRGraphics, MediaCodecDecoder>
        do {
            client = try XRClient(applicationName: "OpenVRLink", graphics: VulkanXRGraphics(quirks: quirks) { Log.note($0) },
                                  decoder: MediaCodecDecoder(quirks: quirks), model: model, panel: panel, platform: platform,
                                  process: XRProcess(javaVM: UnsafeMutableRawPointer(vm), activity: UnsafeMutableRawPointer(activity.pointee.clazz))) {
                Log.note($0)
            }
        } catch {
            Log.note("could not start OpenXR: \(error)")
            model.show("Could not start OpenXR: \(error)")
            return
        }
        lock.lock()
        quitImmersive = { client.quit() }
        let gone = immersive != activity
        lock.unlock()
        if gone { return }

        // Allow specifying a target host in host.txt for headless/adb testing without interacting with the panel.
        let file = DataDirectory.url.appendingPathComponent("host.txt")
        if model.state.target == nil, let named = try? String(contentsOf: file, encoding: .utf8),
           let target = ClientModel.Target(parsing: named) {
            Log.note("connecting to \(target.address) from \(file.path)")
            model.connect(to: target)
        }
        do {
            try client.run()
        } catch {
            Log.note("OpenXR session failed: \(error)")
        }
    }

    /// Requests `RECORD_AUDIO` permission if needed, then starts capturing microphone audio into `sink`.
    private func startMicrophone(into sink: any MicrophoneSink, from activity: UnsafeMutablePointer<ANativeActivity>) {
        lock.lock()
        microphoneWanted += 1
        let mine = microphoneWanted
        lock.unlock()
        nonisolated(unsafe) let activity = activity
        let thread = Thread { [self] in
            func current() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return microphoneWanted == mine && immersive == activity
            }
            if with(activity, { $0.has(App.recordAudio) }) != true {
                Log.note("microphone: asking for permission")
                _ = with(activity) { $0.request([App.recordAudio]) }
                var waited = 0.0
                while current(), waited < 60, with(activity, { $0.has(App.recordAudio) }) != true {
                    Thread.sleep(forTimeInterval: 0.5)
                    waited += 0.5
                }
            }
            guard current(), with(activity, { $0.has(App.recordAudio) }) == true else {
                Log.note("microphone: not permitted, not sending")
                return
            }
            Log.note(microphone.start(into: sink) ? "microphone: sending to the host" : "microphone: could not be opened")
        }
        thread.name = "microphone"
        thread.start()
    }

    // MARK: 2D panel window

    /// Launches the immersive activity when the user selects a host in the 2D panel window.
    private func enterImmersive() {
        lock.lock()
        let from = flat
        lock.unlock()
        guard let from, with(from, { $0.start(activityClass: App.immersiveClass) }) == true else {
            model?.streamEnded("Could not enter XR")
            return
        }
        model?.show("Entering XR")
    }

    private func window(_ activity: UnsafeMutablePointer<ANativeActivity>?, _ window: OpaquePointer?) {
        lock.lock()
        defer { lock.unlock() }
        guard activity == flat, let panel else { return }
        if let old = flatWindow { ANativeWindow_release(old) }
        flatWindow = window
        guard let window else { return }
        ANativeWindow_acquire(window)
        flatSize = (Float(max(1, ANativeWindow_getWidth(window))), Float(max(1, ANativeWindow_getHeight(window))))
        // Configure the window buffer at the panel's native resolution and let SurfaceFlinger scale it to fit.
        ANativeWindow_setBuffersGeometry(window, Int32(panel.width), Int32(panel.height), Int32(WINDOW_FORMAT_RGBA_8888.rawValue))
        flatNeedsPicture = true
    }

    private func input(_ activity: UnsafeMutablePointer<ANativeActivity>?, _ queue: OpaquePointer?, attached: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue else { return }
        queues.removeAll { $0 == queue }
        if attached { queues.append(queue) }
        if activity == flat { flatQueue = attached ? queue : nil }
    }

    /// Drains all pending input events across attached queues. Motion events on the 2D window update the panel
    /// pointer, while other events are finished as unhandled so Android does not trigger an ANR.
    private func drainInput() {
        for queue in queues {
            var event: OpaquePointer?
            while AInputQueue_getEvent(queue, &event) >= 0, let event {
                if AInputQueue_preDispatchEvent(queue, event) != 0 { continue }
                var handled: Int32 = 0
                if AInputEvent_getType(event) == Int32(AINPUT_EVENT_TYPE_KEY) {
                    let key = AKeyEvent_getKeyCode(event), down = AKeyEvent_getAction(event) == Int32(AKEY_EVENT_ACTION_DOWN)
                    if keysNoted.insert(key).inserted { Log.note("input: key \(key) \(down ? "pressed" : "released") for the first time") }
                    // Intercept the back button during an immersive session so it acts as the host system button
                    // (`XRPlatform.systemButton`) instead of closing the activity.
                    if key == Int32(AKEYCODE_BACK), immersive != nil, queue != flatQueue {
                        backDown = down
                        if down { backHeldUntil = Uptime.nanoseconds + 150_000_000 }
                        handled = 1
                    }
                }
                if queue == flatQueue, AInputEvent_getType(event) == Int32(AINPUT_EVENT_TYPE_MOTION), let panel {
                    let x = AMotionEvent_getX(event, 0) / flatSize.width * Float(panel.width)
                    let y = AMotionEvent_getY(event, 0) / flatSize.height * Float(panel.height)
                    switch AMotionEvent_getAction(event) & Int32(AMOTION_EVENT_ACTION_MASK) {
                    case Int32(AMOTION_EVENT_ACTION_DOWN), Int32(AMOTION_EVENT_ACTION_MOVE):
                        touch = (x, y, true)
                        touchLingers = 0
                    case Int32(AMOTION_EVENT_ACTION_UP):
                        touch = (x, y, false)
                        touchLingers = 4
                    case Int32(AMOTION_EVENT_ACTION_HOVER_MOVE), Int32(AMOTION_EVENT_ACTION_HOVER_ENTER):
                        touch = (x, y, false)
                        touchLingers = 0
                    default:
                        touch = nil
                    }
                    handled = 1
                }
                AInputQueue_finishEvent(queue, event, handled)
            }
        }
    }

    /// Polls input queues and renders the panel into the 2D window whenever the immersive session is not active.
    private func windowLoop() {
        while true {
            lock.lock()
            drainInput()
            if let window = flatWindow, let panel, panelLock.try() {
                panel.pointer = touch
                if touchLingers > 0 {
                    touchLingers -= 1
                    if touchLingers == 0 { touch = nil }
                }
                if panel.update() || flatNeedsPicture {
                    flatNeedsPicture = !show(panel.picture, in: window)
                }
                panelLock.unlock()
            }
            lock.unlock()
            usleep(16_000)
        }
    }

    /// Copies the picture into the window's next buffer and posts it.
    private func show(_ picture: PanelPicture, in window: OpaquePointer) -> Bool {
        var buffer = ANativeWindow_Buffer()
        guard ANativeWindow_lock(window, &buffer, nil) == 0, let bits = buffer.bits else { return false }
        let rows = min(Int(buffer.height), picture.height), bytes = min(Int(buffer.width), picture.width) * 4
        picture.pixels.withUnsafeBytes { pixels in
            for row in 0..<rows {
                (bits + row * Int(buffer.stride) * 4).copyMemory(from: pixels.baseAddress! + row * picture.width * 4, byteCount: bytes)
            }
        }
        return ANativeWindow_unlockAndPost(window) == 0
    }
}

/// Entry point called by Android's `NativeActivity` on the main UI thread, which must return promptly without blocking.
@_cdecl("ANativeActivity_onCreate")
public func activityCreated(_ activity: UnsafeMutablePointer<ANativeActivity>?, _ savedState: UnsafeMutableRawPointer?, _ savedSize: Int) {
    guard let activity else { return }
    App.shared.created(activity)
}
#endif
