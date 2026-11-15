// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import MetalKit
import VRLinkAppleAudio
import VRLinkAppleFace
import VRLinkAppleNetwork
import VRLinkCore
import VRLinkMetal
import VRLinkVideoToolbox

/// OpenVRLink macOS viewer
///
///     swift run OpenVRLink [host address]
///
/// Drag to look around, use WASD to move, and press X to swap between the left
/// and right eye. Sends a simulated right controller (Space pulls the trigger)
/// and a simulated open left hand positioned in front of the head.

/// Thread-safe hand and controller state shared between the main thread and the session thread.
final class HeldControllers {
    private let lock = NSLock()
    private var states: [HandInput?] = [nil, nil]
    func set(_ new: [HandInput?]) { lock.lock(); states = new; lock.unlock() }
    func get() -> [HandInput?] { lock.lock(); defer { lock.unlock() }; return states }
}

final class ViewerView: MTKView {
    var head = HeadPose(position: Vec3(0, 1.6, 0))
    var onHeadChanged: ((HeadPose) -> Void)?
    var onSwapEyes: (() -> Void)?
    let controllers = HeldControllers()
    var swaying = false
    private let started = Date()
    private var keysDown = Set<String>()
    private var lastStep = Date()
    private var previous = HeadPose(position: Vec3(0, 1.6, 0))

    private static let radiansPerPoint: Float = 0.004
    private static let metersPerSecond: Float = 1.5

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        // Dragging right looks right (yaw is positive to the left); dragging down looks down.
        head.yaw -= Float(event.deltaX) * ViewerView.radiansPerPoint
        head.pitch = max(-1.5, min(1.5, head.pitch - Float(event.deltaY) * ViewerView.radiansPerPoint))
        onHeadChanged?(head)
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        if key == "x", !event.isARepeat { onSwapEyes?() }
        keysDown.insert(key)
    }
    override func keyUp(with event: NSEvent) { keysDown.remove(event.charactersIgnoringModifiers ?? "") }

    /// Updates head position from WASD input along the horizontal plane and
    /// computes smoothed linear and angular velocities.
    func stepMovement() {
        let now = Date()
        let seconds = Float(now.timeIntervalSince(lastStep))
        lastStep = now
        guard seconds > 0 else { return }
        if swaying {
            // Automatically yaw left and right with an 8-second period for testing.
            head.yaw = 0.6 * Float(sin(now.timeIntervalSince(started) * .pi / 4))
        }
        let facing = HeadPose(position: head.position, yaw: head.yaw).pose   // horizontal plane (ignores pitch)
        var ahead: Float = 0, sideways: Float = 0
        if keysDown.contains("w") { ahead += 1 }
        if keysDown.contains("s") { ahead -= 1 }
        if keysDown.contains("d") { sideways += 1 }
        if keysDown.contains("a") { sideways -= 1 }
        let meters = ViewerView.metersPerSecond * seconds
        head.position = head.position + facing.forward * (ahead * meters) + facing.right * (sideways * meters)

        controllers.set(Side.allCases.map { side in
            var grip = head.pose
            let sideways: Float = side == .left ? -0.2 : 0.2
            grip.position = grip.position + grip.right * sideways + grip.up * -0.25 + grip.forward * 0.4
            if side == .left { return .hand(TrackedHand.flat(wrist: grip, side: side)) }
            var state = ControllerState(grip: TrackedPose(pose: grip))
            if side == .right, keysDown.contains(" ") {
                state.trigger = 1
                state.triggerTouched = true
            }
            return .controller(state)
        })

        // Compute velocities from the pose delta, smoothing to filter out
        // bursty mouse events.
        let blend: Float = 0.3
        func smooth(_ old: Float, _ new: Float) -> Float { old + (new - old) * blend }
        let moved = (head.position - previous.position) * (1 / seconds)
        head.velocity = Vec3(smooth(head.velocity.x, moved.x), smooth(head.velocity.y, moved.y),
                             smooth(head.velocity.z, moved.z))
        head.yawRate = smooth(head.yawRate, (head.yaw - previous.yaw) / seconds)
        head.pitchRate = smooth(head.pitchRate, (head.pitch - previous.pitch) / seconds)
        previous = head
        onHeadChanged?(head)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Target host IP or hostname, or nil to auto-discover on the local network.
    let hostAddress: String?
    var window: NSWindow!
    var view: ViewerView!
    var renderer: WindowDisplay!
    let decoder = VideoDecoder()
    let microphone = MicrophoneInput()
    let faceCamera = FaceCamera()
    var session: (any StreamingSession)?
    var movementTimer: Timer?

    let simulatedLoss: Double
    var audioOutput: AudioOutput?

    /// Whether to connect to a WiVRn host rather than Steam.
    let wivrn: Bool

    init(hostAddress: String?, simulatedLoss: Double, wivrn: Bool) {
        self.hostAddress = hostAddress
        self.simulatedLoss = simulatedLoss
        self.wivrn = wivrn
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Match the stream framerate to the display's refresh rate.
        let refreshHz = NSScreen.main?.maximumFramesPerSecond ?? 60
        var profile = DeviceProfile()
        profile.systemName = SystemVersion.name
        profile.clientVersion = SystemVersion.client
        profile.refreshHz = Float(refreshHz)
        // Apply the subset of user settings supported by the macOS viewer (FOV scale, camera face tracking, and chroma key).
        let settings = Settings.load()
        profile.tracksEyesOrFace = settings.faceFromCamera
        profile.eyeFrusta = profile.eyeFrusta.map {
            $0.scaled(horizontal: settings.fovScaleHorizontal, vertical: settings.fovScaleVertical)
        }
        view = ViewerView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.swaying = sway
        view.preferredFramesPerSecond = refreshHz
        print("display refreshes at \(refreshHz) Hz")
        guard let renderer = WindowDisplay(view: view, profile: profile, settings: settings)
        else { fatalError("Metal is not available") }
        self.renderer = renderer
        renderer.refreshPeriod = 1 / Double(refreshHz)
        view.delegate = renderer

        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "OpenVRLink"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        decoder.onImage = { [weak self, renderer] frame in
            for picture in frame.images.indices { self?.session?.frameDecoded(frame.frameID, picture: picture) }
            renderer.frames.push(frame)
        }
        view.onSwapEyes = { [weak self] in
            guard let self, !self.hostName.isEmpty else { return }
            self.renderer.eye = self.renderer.eye == .left ? .right : .left
            self.showEyeInTitle()
        }
        view.onHeadChanged = { [weak self] head in
            self?.renderer.setHead(head)
            self?.session?.setHead(head.tracked)
        }
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            self?.view.stepMovement()
        }
        Thread.detachNewThread { [self] in connect(profile: profile) }
    }

    private var hostName = ""

    private func showEyeInTitle() {
        setTitle("\(hostName) (\(renderer.eye == .left ? "left" : "right") eye; drag to look, WASD to move, X to swap eyes)")
    }

    private func setTitle(_ text: String) {
        print(text)
        DispatchQueue.main.async { self.window.title = "OpenVRLink — " + text }
    }

    /// Discovers a WiVRn or Steam host on the local network and returns its address.
    private func findHost() throws -> String {
        if wivrn {
            setTitle("looking for WiVRn hosts")
            var address = ""
            let browser = ServiceBrowser(type: WiVRn.serviceType)
            let found = DispatchSemaphore(value: 0)
            browser.start { services in
                guard let first = services.first, address.isEmpty else { return }
                print("  \(first.name) at \(first.host)")
                address = first.host
                found.signal()
            }
            // Keep the browser alive until the semaphore finishes waiting, otherwise it stops listening on deinit.
            let heard = withExtendedLifetime(browser) { found.wait(timeout: .now() + 5) }
            guard heard == .success else { throw WiVRnError.unreachable("any address; none announced itself") }
            return address
        }
        setTitle("looking for Steam hosts")
        let identity = Identity()
        guard let searcher = UDPSocket() else { throw BroadcastError.noReply }
        let hosts = Broadcast.discover(searcher, deviceID: identity.deviceID)
        for found in hosts {
            print("  \(found.hostname) at \(found.address)\(found.offersVRLink ? "" : " (no VR Link)")")
        }
        // Prefer a host this device is already paired with.
        let usable = hosts.filter(\.offersVRLink)
        guard let chosen = usable.first(where: { identity.isPaired(withHost: $0.clientID) }) ?? usable.first
        else { throw BroadcastError.noReply }
        return chosen.address
    }

    /// Finds a host, pairs with it if needed, and starts streaming. Runs on a
    /// background thread because host startup blocks for a few seconds.
    private func connect(profile: DeviceProfile) {
        do {
            var address = try hostAddress ?? findHost()
            // Allow "address:port" when testing against a WiVRn host on a non-default port.
            var port: UInt16?
            if wivrn, let colon = address.lastIndex(of: ":"), let given = UInt16(address[address.index(after: colon)...]) {
                port = given
                address = String(address[..<colon])
            }
            var connector = HostConnector(deviceName: HostConnector.name(of: Host.current().localizedName ?? "Mac"),
                                          deviceModel: SystemVersion.model, systemVersion: SystemVersion.named)
            connector.microphone = useMicrophone
            // Prefer wired Ethernet interfaces when available.
            connector.preferredInterfaces = { WiredInterfaces.names() }
            // Fail immediately if the host is unreachable instead of retrying like the headset app does.
            connector.keepLooking = false
            connector.show = { [self] in setTitle($0) }
            connector.log = { Log.note($0) }
            connector.askPin = {
                if let wivrnPin { return wivrnPin }
                print("Type it here: ", terminator: "")
                return readLine()?.trimmingCharacters(in: .whitespaces)
            }
            guard let (session, name) = try connector.connect(wivrn ? .wivrn : .steam, address: address, port: port, profile: profile)
            else { return }
            session.onLog = { Log.note($0) }
            (session as? StreamSession)?.simulatedLoss = simulatedLoss
            if useMicrophone {
                MicrophoneInput.requestPermission { [microphone] allowed in
                    let started = allowed && microphone.start(into: session.microphoneSink)
                    print(started ? "microphone: sending to the host" : "microphone: not available or not permitted")
                }
            }
            session.handsProvider = { [controllers = view.controllers] in controllers.get() }
            // If enabled, run experimental face tracking using the Mac's webcam.
            if Settings.load().faceFromCamera {
                faceCamera.faceCalibration = Settings.load().faceCalibration
                faceCamera.start()
                session.faceProvider = { [faceCamera] in faceCamera.estimate()?.face }
            }
            session.onFrame = { [decoder] frame in decoder.decode(frame) }
            session.start()
            DispatchQueue.main.async {
                self.session = session
                self.renderer.session = session
                self.audioOutput = AudioOutput(buffer: session.audio)
                session.setHead(self.view.head.tracked)
            }
            hostName = name
            showEyeInTitle()
        } catch {
            print("could not start: \(error)")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Give the session loop time to send its goodbye to the host.
        session?.stop(leaving: true)
        Thread.sleep(forTimeInterval: 0.6)
    }
}

setvbuf(stdout, nil, _IOLBF, 0) 
// Terminate cleanly on SIGINT/SIGTERM so applicationWillTerminate can notify the host.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let quitSignals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}
// Supported CLI options:
//   [host address]    Optional host IP or hostname (with optional :port for WiVRn)
//   --mic             Stream microphone audio to the host
//   --loss <percent>  Drop a percentage of incoming video/audio packets to test loss recovery
//   --wivrn           Connect to a WiVRn host instead of Steam
//   --sway            Continuously yaw the head left and right for testing
//   --pin <digits>    WiVRn pairing PIN (prompts on stdin if omitted)
var hostAddress: String?
var simulatedLoss = 0.0
var useMicrophone = false
var wivrn = false
var sway = false
var wivrnPin: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == "--loss", let percent = arguments.popFirst().flatMap(Double.init) {
        simulatedLoss = percent / 100
    } else if argument == "--mic" {
        useMicrophone = true
    } else if argument == "--wivrn" {
        wivrn = true
    } else if argument == "--sway" {
        sway = true
    } else if argument == "--pin", let digits = arguments.popFirst() {
        wivrnPin = digits
    } else if hostAddress == nil, !argument.hasPrefix("-") {
        hostAddress = argument
    } else {
        print("usage: OpenVRLink [host address] [--mic] [--loss <percent>] [--wivrn] [--sway] [--pin <digits>]")
        exit(2)
    }
}
let application = NSApplication.shared
let delegate = AppDelegate(hostAddress: hostAddress, simulatedLoss: simulatedLoss, wivrn: wivrn)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
