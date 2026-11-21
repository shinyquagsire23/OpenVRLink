// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Combine
import Foundation
import VRLinkAppleAudio
import VRLinkAppleNetwork
import VRLinkCore
import VRLinkVideoToolbox
#if canImport(UIKit)
import UIKit
#endif

/// A discovered host shown in the connection picker.
public struct FoundHost: Identifiable {
    public let name: String
    /// An IP address or a resolvable hostname.
    public let address: String
    public let kind: HostKind

    public var id: String { kind.rawValue + " " + address }
}

/// A connection and its lifecycle, including finding, pairing,
/// and the streaming session itself.
///
/// Sessions can be stopped and started with backgrounding/foregrounding
/// and when the headset is doffed and re-donned.
public final class Connection: ObservableObject {
    /// Human-readable status text shown in the entry window (progress, pairing PIN, or errors).
    @Published public var status = "Not connected"
    /// Discovered hosts on the local network, with Steam hosts listed before WiVRn hosts.
    @Published public var hosts: [FoundHost] = []
    private var steamHosts: [FoundHost] = [], wivrnHosts: [FoundHost] = []
    private let wivrnBrowser = ServiceBrowser(type: WiVRn.serviceType)
    /// Whether the immersive space is open
    @Published public var immersed = false
    /// True while connecting and waiting for the first decoded video frame
    /// before opening the immersive space.
    @Published public var waitingForPicture = false
    /// True when an unpaired WiVRn host is waiting for the user to enter its
    /// pairing PIN via `answerPin(_:)`.
    @Published public var askingForPin = false
    private var pinAnswer: String??
    /// The host the user chose.
    /// When the headset is doffed and re-donned, it will resume from this
    /// host instead of re-asking the user.
    public var hostAddress = ""
    /// Protocol used by the selected host (Steam or WiVRn).
    public var hostKind = HostKind.steam
    private var microphone: MicrophoneInput?
    private var searching = false

    /// Decoded frames waiting for the display.
    public let frames = DisplayQueue<DecodedFrame>()

    private let lock = NSLock()
    private let battery = HeadsetBattery()
    private var current: (any StreamingSession)?
    private var starting = false
    private var startedWith: DeviceProfile?
    private var pictureArrived = false
    /// False once stopping, so a connection attempt in progress gives up
    private var wanted = false
    private var audio: AudioOutput?
    private let decoder = VideoDecoder()

    private var space = PlaySpace.trackingSpace

    /// Coordinate space and boundary used when communicating with the host (either the
    /// active room or raw tracking space). Outgoing tracker poses are converted into this
    /// space before transmission, and incoming rendered eye poses are converted back so
    /// trackers and renderers remain in tracking space. Thread-safe.
    public var playSpace: PlaySpace {
        get {
            lock.lock()
            defer { lock.unlock() }
            return space
        }
        set {
            lock.lock()
            let boundaryChanged = space.boundary != newValue.boundary
            space = newValue
            let session = current
            lock.unlock()
            if boundaryChanged { session?.setBoundary(newValue.boundary) }
        }
    }

    /// Called on the session thread when the host requests a recenter.
    public var onRecenterRequested: (() -> Void)?

    /// The running session, nil if not started. Thread-safe.
    public var session: (any StreamingSession)? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The device profile sent to the host for the active or starting stream. Thread-safe.
    public var profile: DeviceProfile? {
        lock.lock()
        defer { lock.unlock() }
        return startedWith
    }

    /// Whether a stream is running or being started. Thread-safe.
    public var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return starting || current != nil
    }

    /// Whether this stream has had a frame decoded yet. Thread-safe.
    public var hasPicture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pictureArrived
    }

    /// Device name sent to the host during pairing, e.g. "Max's Apple Vision
    /// Pro (OpenVRLink)". Querying the user-assigned device name requires the
    /// `com.apple.developer.device-information.user-assigned-device-name`
    /// entitlement; without it, UIKit falls back to the generic model name
    /// ("Apple Vision Pro").
    private let deviceName: String

    public init() {
        #if canImport(UIKit)
        deviceName = HostConnector.name(of: UIDevice.current.name)
        #else
        deviceName = HostConnector.name(of: Host.current().localizedName ?? "Mac")
        #endif
        #if canImport(UIKit)
        // Restart mDNS discovery when returning to the foreground, since the OS suspends it in the background.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.wivrnBrowser.restart()
        }
        #endif
        decoder.onFailure = { [weak self] frameID, picture in self?.session?.frameNotDecoded(frameID, picture: picture) }
        decoder.onImage = { [weak self] frame in
            guard let self else { return }
            for picture in frame.images.indices { session?.frameDecoded(frame.frameID, picture: picture) }
            frames.push(frame)
            lock.lock()
            pictureArrived = current != nil
            lock.unlock()
        }
    }

    private func show(_ text: String) {
        print(text)
        DispatchQueue.main.async { self.status = text }
    }

    /// Starts background discovery for WiVRn (mDNS) and Steam (UDP broadcast) hosts.
    public func searchForHosts() {
        lock.lock()
        let already = searching
        searching = true
        lock.unlock()
        if already { return }
        // Listen for WiVRn hosts via Bonjour.
        wivrnBrowser.start { [weak self] services in
            DispatchQueue.main.async {
                guard let self else { return }
                self.wivrnHosts = services.map { FoundHost(name: $0.name, address: $0.host, kind: .wivrn) }
                self.hosts = self.steamHosts + self.wivrnHosts
            }
        }
        Thread.detachNewThread { [self] in
            let identity = Identity()
            // HACK: Apple is annoying and *apparently* starting network activity too soon (before the window shows)
            // can cause the dialog to just Not Show Up? So we wait a second.
            Thread.sleep(forTimeInterval: 1)
            while true {
                lock.lock()
                let idle = !wanted && current == nil
                lock.unlock()
                // Create a fresh socket each poll so we don't hold onto a socket
                // that failed before local network permission was granted.
                if idle, let socket = UDPSocket() {
                    let found = Broadcast.discover(socket, deviceID: identity.deviceID)
                        .filter(\.offersVRLink).sorted { $0.hostname < $1.hostname }
                    DispatchQueue.main.async {
                        self.steamHosts = found.map { FoundHost(name: $0.hostname, address: $0.address, kind: .steam) }
                        self.hosts = self.steamHosts + self.wivrnHosts
                    }
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    /// Starts streaming from `hostAddress`, pairing first if needed.
    /// Tracking providers are polled each vsync; pass `microphone: true` to
    /// stream microphone audio to the host.
    public func start(profile: DeviceProfile, microphone microphoneWanted: Bool, headProvider: @escaping () -> TrackedPose?,
               handsProvider: @escaping () -> [HandInput?],
               gazeProvider: @escaping () -> Vec3?,
               faceProvider: @escaping () -> FaceExpressions?,
               onHaptic: @escaping (HapticPulse) -> Void) {
        lock.lock()
        let busy = starting || current != nil
        starting = !busy
        wanted = true
        if !busy {
            startedWith = profile
            pictureArrived = false
        }
        lock.unlock()
        if busy { return }
        let address = hostAddress.trimmingCharacters(in: .whitespaces), kind = hostKind

        Thread.detachNewThread { [self] in
            defer {
                lock.lock()
                starting = false
                lock.unlock()
            }
            func cancelled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return !wanted
            }
            var connector = HostConnector(deviceName: deviceName, deviceModel: SystemVersion.model, systemVersion: SystemVersion.named)
            connector.microphone = microphoneWanted
            // Prefer wired network interfaces (such as the developer strap Ethernet) when available.
            connector.preferredInterfaces = { WiredInterfaces.names() }
            connector.show = { [self] in show($0) }
            connector.log = { Log.note($0) }
            connector.askPin = { [self] in askForPin(cancelled: cancelled) }
            connector.cancelled = cancelled
            do {
                guard let (session, hostName) = try connector.connect(kind, address: address, profile: profile) else { return }
                if microphoneWanted { sendMicrophone(to: session.microphoneSink) }
                session.onLog = { Log.note($0) }
                // Tear down the stream if the host disconnects and display the reason in the UI.
                session.onEnded = { [weak self, weak session] reason in
                    guard let self, let session, self.session === session else { return }
                    self.stop()
                    self.show("The stream ended: \(reason)")
                }
                session.headProvider = { [weak self] in
                    guard let head = headProvider(), let self else { return nil }
                    return self.playSpace.entering(head)
                }
                session.headsetPowerProvider = { [battery] in battery.state }
                session.handsProvider = { [weak self] in
                    let hands = handsProvider()
                    guard let space = self?.playSpace else { return hands }
                    return hands.map { $0.map { space.entering($0) } }
                }
                session.onRecenterRequested = { [weak self] in self?.onRecenterRequested?() }
                session.setBoundary(playSpace.boundary)
                session.gazeProvider = gazeProvider
                session.faceProvider = faceProvider
                session.onHaptic = onHaptic
                #if os(visionOS)
                session.onRefreshRateRequested = { hz in DisplayRate.shared.ask(for: hz) }
                decoder.onFormat = { DisplayRate.shared.videoFormat($0) }
                #endif
                // Reset decoder state before starting a new stream.
                decoder.reset()
                session.onFrame = { [decoder, weak self] frame in
                    guard let space = self?.playSpace else { return }
                    decoder.decode(EncodedFrame(frameID: frame.frameID, picture: frame.picture, data: frame.data,
                                                layout: space.leaving(frame.layout)))
                }
                session.start()
                lock.lock()
                let stillWanted = wanted
                if stillWanted { current = session }
                lock.unlock()
                guard stillWanted else {
                    session.stop(leaving: false)
                    return
                }
                DispatchQueue.main.async {
                    if let audio = self.audio { audio.resume() } else { self.audio = AudioOutput(buffer: session.audio) }
                }
                // WiVRn doesn't send video frames until an OpenXR app starts on the host.
                show(kind == .steam ? "Streaming from \(hostName)" : "Connected to \(hostName); waiting for an application there")
            } catch {
                show("Could not connect: \(error)")
            }
        }
    }

    /// Blocks until the user submits a WiVRn pairing PIN or cancels (returning
    /// nil). The host times out on its own after two minutes.
    private func askForPin(cancelled: () -> Bool) -> String? {
        lock.lock()
        pinAnswer = nil
        lock.unlock()
        DispatchQueue.main.async { self.askingForPin = true }
        while !cancelled() {
            lock.lock()
            let answer = pinAnswer
            lock.unlock()
            if let answer { return answer }
            Thread.sleep(forTimeInterval: 0.1)
        }
        DispatchQueue.main.async { self.askingForPin = false }
        return nil
    }

    /// Delivers the user-entered pairing PIN (or nil if canceled) to a waiting `askForPin` call.
    public func answerPin(_ pin: String?) {
        lock.lock()
        pinAnswer = .some(pin)
        lock.unlock()
        askingForPin = false
    }

    private func sendMicrophone(to sink: any MicrophoneSink) {
        DispatchQueue.main.async {
            MicrophoneInput.requestPermission { allowed in
                DispatchQueue.main.async {
                    let input = MicrophoneInput()
                    if allowed, input.start(into: sink) {
                        self.microphone = input
                        print("Connection: sending mic to the host")
                    } else {
                        print("Connection: mic not available or not permitted, not sending")
                    }
                }
            }
        }
    }

    /// Tears down the active stream. Pass `leaving: true` when the user
    /// explicitly stops streaming so the host quits SteamVR and any running
    /// game immediately (the host also quits SteamVR if no game is running).
    /// When `leaving` is false (for example, when taking off the headset or
    /// backgrounding the app mid-game), the host keeps the game running briefly
    /// so reconnecting resumes the session.
    public func stop(leaving: Bool = false) {
        lock.lock()
        let session = current
        current = nil
        wanted = false
        startedWith = nil
        pictureArrived = false
        lock.unlock()
        frames.clear()
        guard let session else { return }
        session.stop(leaving: leaving)
        // Request brief background execution time so the session can finish sending disconnect packets.
        #if !os(macOS)
        if leaving || !session.sceneApplicationRunning {
            ProcessInfo.processInfo.performExpiringActivity(withReason: "telling the host the session is over") { expired in
                if !expired { Thread.sleep(forTimeInterval: 0.8) }
            }
        }
        #endif
        DispatchQueue.main.async {
            self.microphone?.stop()
            self.microphone = nil
            self.audio = nil
        }
        show("Not connected")
        // WiVRn stops advertising over mDNS while a client is connected, so refresh discovery after disconnecting.
        wivrnBrowser.restart()
    }
}
