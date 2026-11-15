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

/// A computer the entry window offers.
public struct FoundHost: Identifiable {
    public let name: String
    /// An address in numbers, or a name the system can look up.
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
    /// What the entry window shows (progress, the pairing PIN, errors)
    @Published public var status = "Not connected"
    /// Hosts found on the local network, Steam's first
    @Published public var hosts: [FoundHost] = []
    private var steamHosts: [FoundHost] = [], wivrnHosts: [FoundHost] = []
    private let wivrnBrowser = ServiceBrowser(type: WiVRn.serviceType)
    /// Whether the immersive space is open
    @Published public var immersed = false
    /// Connecting, with the immersive space still to be opened: it is
    /// opened when there is a picture to show in it.
    @Published public var waitingForPicture = false
    /// A WiVRn host that does not know this headset is waiting for the PIN
    /// it shows: the entry window asks for it and answers with `answerPin`.
    @Published public var askingForPin = false
    private var pinAnswer: String??
    /// The host the user chose.
    /// When the headset is doffed and re-donned, it will resume from this
    /// host instead of re-asking the user.
    public var hostAddress = ""
    /// What that host is.
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

    /// The running session, nil if not started. Thread-safe.
    public var session: (any StreamingSession)? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// How the display was described to the host when the stream now
    /// running, or being started, was asked for. Thread-safe.
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

    /// What the host calls this device from pairing on, as in "Max's Apple
    /// Vision Pro (OpenVRLink)". The system gives an app the name its owner
    /// chose only with an entitlement Apple grants on request
    /// (com.apple.developer.device-information.user-assigned-device-name);
    /// without it the name is the model's, "Apple Vision Pro".
    private let deviceName: String

    public init() {
        #if canImport(UIKit)
        deviceName = HostConnector.name(of: UIDevice.current.name)
        #else
        deviceName = HostConnector.name(of: Host.current().localizedName ?? "Mac")
        #endif
        #if canImport(UIKit)
        // The system ends the search for announced hosts while the app is put away.
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

    /// Keep the list of hosts fresh while the entry window is waiting
    public func searchForHosts() {
        lock.lock()
        let already = searching
        searching = true
        lock.unlock()
        if already { return }
        // WiVRn hosts announce themselves; the system listens for them.
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
                // A new socket every round, so that one the system refused
                // before permission was given is not kept.
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

    /// Start streaming (or pairing first if the host hasn't paired with this device yet)
    /// Poses are retrieved from provider args every vsync.
    /// `microphone`: whether the user wants their voice sent to the host.
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
                // The host ended it: drop the stream and say why, where the wearer will look.
                session.onEnded = { [weak self, weak session] reason in
                    guard let self, let session, self.session === session else { return }
                    self.stop()
                    self.show("The stream ended: \(reason)")
                }
                session.headProvider = headProvider
                session.headsetPowerProvider = { [battery] in battery.state }
                session.handsProvider = handsProvider
                session.gazeProvider = gazeProvider
                session.faceProvider = faceProvider
                session.onHaptic = onHaptic
                #if os(visionOS)
                session.onRefreshRateRequested = { hz in DisplayRate.shared.ask(for: hz) }
                decoder.onFormat = { DisplayRate.shared.videoFormat($0) }
                #endif
                // Nothing of an earlier stream's decoding is carried into this one.
                decoder.reset()
                session.onFrame = { [decoder] frame in decoder.decode(frame) }
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
                // A WiVRn host sends no picture until an application runs there.
                show(kind == .steam ? "Streaming from \(hostName)" : "Connected to \(hostName); waiting for an application there")
            } catch {
                show("Could not connect: \(error)")
            }
        }
    }

    /// The PIN the wearer types, or nil if they would rather not. Waits for
    /// as long as they take; the host itself gives up after two minutes.
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

    /// What was typed when `askingForPin` was set, or nil for "never mind".
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

    /// Drop everything that belonged to the stream. `leaving` is for the
    /// wearer saying they are done: the host then quits SteamVR and the
    /// application in it at once; so it does when nothing
    /// runs in SteamVR. Otherwise (the headset taken off or the app put
    /// away in the middle of a game) the host keeps the game for a while,
    /// and a stream asked for again in that time carries on in it.
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
        // The session says goodbye to the host over the next half second.
        // If the app is being closed, ask the system for that long.
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
        // A WiVRn host is not announced while it has a headset: look afresh now that it has none.
        wivrnBrowser.restart()
    }
}
