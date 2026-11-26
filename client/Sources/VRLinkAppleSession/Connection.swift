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

/// Publishes `ClientModel` state to SwiftUI on the main thread and runs a `StreamLink` with VideoToolbox decoding
/// and CoreAudio playback and capture.
///
/// Sessions can be stopped and started with backgrounding/foregrounding
/// and when the headset is doffed and re-donned.
public final class Connection: ObservableObject {
    /// Human-readable status text shown in the entry window (progress, pairing PIN, or errors).
    @Published public var status = "Not connected"
    /// Discovered hosts on the local network, with Steam hosts listed before WiVRn hosts.
    @Published public var hosts: [FoundHost] = []
    /// Whether the immersive space is open
    @Published public var immersed = false
    /// True while connecting and waiting for the first decoded video frame
    /// before opening the immersive space.
    @Published public var waitingForPicture = false
    /// True when an unpaired WiVRn host is waiting for the user to enter its
    /// pairing PIN via `answerPin(_:)`.
    @Published public var askingForPin = false
    /// The host the user chose.
    /// When the headset is doffed and re-donned, it will resume from this
    /// host instead of re-asking the user.
    public var hostAddress = ""
    /// Protocol used by the selected host (Steam or WiVRn).
    public var hostKind = HostKind.steam

    /// Session state and actions shared across UI front ends.
    public let model: ClientModel
    private let link: StreamLink<VideoDecoder>
    private let decoder = VideoDecoder()
    private let wivrnBrowser = ServiceBrowser(type: WiVRn.serviceType)
    private let battery = HeadsetBattery()
    private var microphone: MicrophoneInput?
    private var audio: AudioOutput?
    /// Last `ClientModel.State` copied onto the `@Published` properties on the main thread, used so status
    /// messages written directly by SwiftUI views are only overwritten when `model.state.status` changes.
    private var mirrored = ClientModel.State()

    /// Closure that restarts the active stream, set by `start` and cleared by `stop`.
    /// Used to reconnect every `retryEvery` seconds if a running stream drops (for example, when SteamVR
    /// restarts) or when switching between Wi-Fi and a wired interface. Guarded by `retryLock`.
    private var again: (() -> Void)?
    /// Tracks whether the current stream has connected, whether a wired interface was active on the first
    /// check (`nil` until polled), and the number of consecutive polls reporting a different wired state.
    /// All three properties are guarded by `retryLock`.
    private var hasStreamed = false, wiredWhileRunning: Bool?, linkChanges = 0
    private let retryLock = NSLock()
    private var linkWatch: DispatchSourceTimer?
    /// Interval in seconds between reconnection attempts and network interface checks.
    static var retryEvery: Double { 2 }

    /// Decoded frames waiting for the display.
    public var frames: DisplayQueue<DecodedFrame> { link.frames }

    /// Coordinate space and boundary used when communicating with the host (either the
    /// active room or raw tracking space). Outgoing tracker poses are converted into this
    /// space before transmission, and incoming rendered eye poses are converted back so
    /// trackers and renderers remain in tracking space. Thread-safe.
    public var playSpace: PlaySpace {
        get { link.playSpace }
        set { link.playSpace = newValue }
    }

    /// Called on the session thread when the host requests a recenter.
    public var onRecenterRequested: (() -> Void)? {
        get { link.onRecenterRequested }
        set { link.onRecenterRequested = newValue }
    }

    /// The running session, nil if not started. Thread-safe.
    public var session: (any StreamingSession)? { link.session }

    /// The device profile sent to the host for the active or starting stream. Thread-safe.
    public var profile: DeviceProfile? { link.profile }

    /// Whether a stream is running or being started. Thread-safe.
    public var active: Bool { link.active }

    /// Whether this stream has had a frame decoded yet. Thread-safe.
    public var hasPicture: Bool { link.hasPicture }

    /// Device identity reported to the host during pairing and session setup (for example,
    /// `"Max's Apple Vision Pro"`). Querying the
    /// user-assigned device name requires the
    /// `com.apple.developer.device-information.user-assigned-device-name`
    /// entitlement; without it, UIKit falls back to the generic model name
    /// ("Apple Vision Pro").
    private let device: DeviceIdentity

    public init() {
        #if canImport(UIKit)
        device = SystemVersion.device(named: UIDevice.current.name)
        #else
        device = SystemVersion.device(named: Host.current().localizedName ?? "Mac")
        #endif
        // HACK: Apple is annoying and *apparently* starting network activity too soon (before the window shows)
        // can cause the dialog to just Not Show Up? So the first broadcast waits a second.
        model = ClientModel(finder: HostFinder(services: wivrnBrowser, startDelay: 1))
        link = StreamLink(decoder: decoder)
        model.finder.busy = { [link] in link.active }
        model.onChange = { [weak self] in
            DispatchQueue.main.async { self?.mirror() }
        }
        link.onStatus = { [model] in model.show($0) }
        link.onFailed = { [weak self] in self?.lost($0) }
        let watch = DispatchSource.makeTimerSource(queue: .global())
        watch.schedule(deadline: .now() + Connection.retryEvery, repeating: Connection.retryEvery)
        watch.setEventHandler { [weak self] in self?.followLink() }
        watch.resume()
        linkWatch = watch
        link.onStarted = { [weak self] session in
            if let self {
                retryLock.lock()
                hasStreamed = true
                retryLock.unlock()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let audio = self.audio { audio.resume() } else { self.audio = AudioOutput(buffer: session.audio) }
            }
            if self?.sendingMicrophone == true { self?.sendMicrophone(to: session.microphoneSink) }
        }
        link.onStopped = { [weak self] in
            DispatchQueue.main.async {
                self?.microphone?.stop()
                self?.microphone = nil
                self?.audio = nil
            }
            // WiVRn stops advertising over mDNS while a client is connected, so refresh discovery after disconnecting.
            self?.wivrnBrowser.restart()
        }
        #if canImport(UIKit)
        // Restart mDNS discovery when returning to the foreground, since the OS suspends it in the background.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.wivrnBrowser.restart()
        }
        #endif
        #if os(visionOS)
        decoder.onFormat = { DisplayRate.shared.videoFormat($0) }
        #endif
    }

    /// Updates `@Published` properties that changed in `model.state`. Must be called on the main thread.
    private func mirror() {
        let state = model.state
        if state.status != mirrored.status { status = state.status }
        if state.hosts != mirrored.hosts { hosts = state.hosts }
        if state.askingForPin != mirrored.askingForPin { askingForPin = state.askingForPin }
        mirrored = state
    }

    /// Starts background discovery for WiVRn (mDNS) and Steam (UDP broadcast) hosts.
    public func searchForHosts() {
        model.search()
    }

    /// Starts streaming from `hostAddress`, pairing first if needed.
    /// Tracking providers are polled each vsync; pass `microphone: true` to
    /// stream microphone audio to the host.
    public func start(profile: DeviceProfile, microphone microphoneWanted: Bool, headProvider: @escaping () -> TrackedPose?,
               handsProvider: @escaping () -> [HandInput?],
               gazeProvider: @escaping () -> Vec3?,
               faceProvider: @escaping () -> FaceExpressions?,
               onHaptic: @escaping (HapticPulse) -> Void) {
        var connector = HostConnector(device)
        connector.microphone = microphoneWanted
        // Prefer wired network interfaces (such as the developer strap Ethernet) when available.
        connector.preferredInterfaces = { WiredInterfaces.names() }
        connector.log = { Log.note($0) }
        connector.askPin = { [model, link] in model.askPin { !link.isWanted } }
        var inputs = StreamLink<VideoDecoder>.Inputs(head: headProvider, hands: handsProvider)
        inputs.gaze = gazeProvider
        inputs.face = faceProvider
        inputs.power = { [battery] in battery.state }
        inputs.haptic = onHaptic
        #if os(visionOS)
        inputs.refreshRateRequested = { hz in DisplayRate.shared.ask(for: hz) }
        #endif
        sendingMicrophone = microphoneWanted
        let kind = hostKind, address = hostAddress.trimmingCharacters(in: .whitespaces)
        let begin = { [link] in link.start(kind, address: address, profile: profile, connector: connector, inputs: inputs) }
        retryLock.lock()
        again = begin
        hasStreamed = false
        wiredWhileRunning = nil
        linkChanges = 0
        retryLock.unlock()
        begin()
    }

    /// Retries a disconnected stream every `retryEvery` seconds until it reconnects or `stop` is called.
    /// If the stream never connected initially, leaves the error status visible without retrying.
    private func lost(_ why: String) {
        retryLock.lock()
        let retry = hasStreamed ? again : nil
        retryLock.unlock()
        guard retry != nil else { return }
        model.show("\(why)\nReconnecting")
        DispatchQueue.global().asyncAfter(deadline: .now() + Connection.retryEvery) { [weak self] in
            guard let self else { return }
            // Skip retry if stop was called or another connection attempt already started.
            retryLock.lock()
            let begin = again
            wiredWhileRunning = nil
            linkChanges = 0
            retryLock.unlock()
            if let begin, !link.active { begin() }
        }
    }

    /// Restarts a running stream when a wired interface connects or disconnects so `HostConnector` can
    /// re-select the network path. Polled every `retryEvery` seconds and requires two consecutive checks
    /// before restarting to debounce transient interface changes.
    private func followLink() {
        guard link.session != nil else { return }
        let wired = !WiredInterfaces.names().isEmpty
        retryLock.lock()
        guard let before = wiredWhileRunning else {
            wiredWhileRunning = wired
            retryLock.unlock()
            return
        }
        linkChanges = wired == before ? 0 : linkChanges + 1
        let begin = linkChanges >= 2 ? again : nil
        if begin != nil {
            linkChanges = 0
            wiredWhileRunning = nil
        }
        retryLock.unlock()
        guard let begin else { return }
        Log.note(wired ? "wired interface connected; switching stream to wired link" : "wired interface disconnected; switching stream to Wi-Fi")
        link.stop()
        model.show(wired ? "Switching to wired link" : "Switching to Wi-Fi")
        begin()
    }

    /// Whether the stream being started was asked to send the microphone.
    private var sendingMicrophone = false

    /// Delivers the user-entered pairing PIN (or nil if canceled) to the waiting connection attempt.
    public func answerPin(_ pin: String?) {
        model.answerPin(pin)
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
        retryLock.lock()
        again = nil
        hasStreamed = false
        retryLock.unlock()
        let session = link.session
        link.stop(leaving: leaving)
        guard let session else { return }
        // Request brief background execution time so the session can finish sending disconnect packets.
        #if !os(macOS)
        if leaving || !session.sceneApplicationRunning {
            ProcessInfo.processInfo.performExpiringActivity(withReason: "telling the host the session is over") { expired in
                if !expired { Thread.sleep(forTimeInterval: 0.8) }
            }
        }
        #else
        _ = session
        #endif
        model.show("Not connected")
    }
}
