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
/// Drag to look around, W A S D to move, X to swap between the left and
/// right eye. A pretend controller is held in front of the head on the right
/// (the space bar pulls its trigger) and a pretend open hand on the left.

/// The pretend controllers, handed from the main thread to the session's.
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

    /// Called at a steady rate: walk along the floor in the direction the
    /// head faces, and measure how fast the head is moving and turning.
    func stepMovement() {
        let now = Date()
        let seconds = Float(now.timeIntervalSince(lastStep))
        lastStep = now
        guard seconds > 0 else { return }
        let facing = HeadPose(position: head.position, yaw: head.yaw).pose   // level: ignores pitch
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

        // Velocities from the change since the last step, smoothed because
        // mouse movement arrives in bursts.
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
    /// Nil means "find one on the local network".
    let hostAddress: String?
    var window: NSWindow!
    var view: ViewerView!
    var renderer: WindowDisplay!
    let decoder = VideoDecoder()
    let microphone = MicrophoneInput()
    let faceCamera = FaceCamera()
    var session: StreamSession?
    var movementTimer: Timer?

    let simulatedLoss: Double
    var audioOutput: AudioOutput?

    init(hostAddress: String?, simulatedLoss: Double) {
        self.hostAddress = hostAddress
        self.simulatedLoss = simulatedLoss
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stream at the display's own refresh rate, so frames and refreshes pair up.
        let refreshHz = NSScreen.main?.maximumFramesPerSecond ?? 60
        var profile = DeviceProfile()
        profile.systemName = SystemVersion.name
        profile.clientVersion = SystemVersion.client
        profile.refreshHz = Float(refreshHz)
        // The settings this viewer has a use for: the field of view asked of the host, and the chroma key.
        let settings = Settings.load()
        profile.tracksEyesOrFace = settings.faceFromCamera
        profile.eyeFrusta = profile.eyeFrusta.map {
            $0.scaled(horizontal: settings.fovScaleHorizontal, vertical: settings.fovScaleVertical)
        }
        view = ViewerView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
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
            self?.session?.frameDecoded(frame.frameID)
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

    /// Find the host, pair with it if needed, and start streaming. Blocks for
    /// a few seconds while SteamVR starts, so it runs off the main thread.
    private func connect(profile: DeviceProfile) {
        do {
            let identity = Identity()
            var address = hostAddress
            if address == nil {
                setTitle("looking for Steam hosts")
                guard let searcher = UDPSocket() else { throw BroadcastError.noReply }
                let hosts = Broadcast.discover(searcher, deviceID: identity.deviceID)
                for found in hosts {
                    print("  \(found.hostname) at \(found.address)\(found.offersVRLink ? "" : " (no VR Link)")")
                }
                // Prefer a host this device is already paired with.
                let usable = hosts.filter(\.offersVRLink)
                guard let chosen = usable.first(where: { identity.isPaired(withHost: $0.clientID) }) ?? usable.first
                else { throw BroadcastError.noReply }
                address = chosen.address
            }
            // Talk to the host over a cable if there is one that reaches it.
            let (socket, host, interface) = try Broadcast.reach(address: address ?? "", deviceID: identity.deviceID,
                                                                preferring: WiredInterfaces.names())
            print(interface.map { "using wired interface \($0)" } ?? "using the system's choice of network interface")

            let args: SessionArgs
            do {
                setTitle("asking \(host.hostname) for a session")
                args = try Broadcast.requestSession(socket, host: host, identity: identity,
                                                        deviceVersion: "OpenVRLink " + SystemVersion.named)
            } catch BroadcastError.notPaired {
                try Broadcast.pair(socket, host: host, identity: identity,
                                   deviceName: (Host.current().localizedName ?? "Mac") + " (OpenVRLink)",
                                   deviceModel: SystemVersion.model) { pin in
                    setTitle("enter PIN \(pin) in Steam on \(host.hostname)")
                }
                setTitle("paired; asking \(host.hostname) for a session")
                args = try Broadcast.requestSession(socket, host: host, identity: identity,
                                                        deviceVersion: "OpenVRLink " + SystemVersion.named)
            }

            guard let session = StreamSession(args, profile: profile, interface: interface) else {
                throw BroadcastError.badResponse("the host offered a transport this client does not know (token kind \(args.token.prefix(4)))")
            }
            session.onLog = { Log.note($0) }
            print("transport: \(session.transportName)")
            session.simulatedLoss = simulatedLoss
            if useMicrophone {
                MicrophoneInput.requestPermission { [microphone] allowed in
                    let started = allowed && microphone.start(into: session.microphone)
                    print(started ? "microphone: sending to the host" : "microphone: not available or not permitted")
                }
            }
            session.handsProvider = { [controllers = view.controllers] in controllers.get() }
            // The face experiment, with this Mac's camera standing in for a Persona.
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
            hostName = host.hostname
            showEyeInTitle()
        } catch {
            print("could not start: \(error)")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Give the session loop time to send its goodbye to the host.
        session?.stop()
        Thread.sleep(forTimeInterval: 0.6)
    }
}

setvbuf(stdout, nil, _IOLBF, 0) 
// Quit properly when asked to from a terminal, so the host is told goodbye
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let quitSignals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}
// Arguments: an optional host address; `--mic` to send this Mac's microphone
// to the host; and `--loss <percent>`, a testing aid that throws away that
// share of incoming video and audio to exercise loss recovery on a clean network.
var hostAddress: String?
var simulatedLoss = 0.0
var useMicrophone = false
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == "--loss", let percent = arguments.popFirst().flatMap(Double.init) {
        simulatedLoss = percent / 100
    } else if argument == "--mic" {
        useMicrophone = true
    } else if hostAddress == nil, !argument.hasPrefix("-") {
        hostAddress = argument
    } else {
        print("usage: OpenVRLink [host address] [--mic] [--loss <percent>]")
        exit(2)
    }
}
let application = NSApplication.shared
let delegate = AppDelegate(hostAddress: hostAddress, simulatedLoss: simulatedLoss)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
