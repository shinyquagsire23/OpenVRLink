// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkCore
import VRLinkOpenXR
import VRLinkPanel

/// Platform hooks that an OpenXR app shell (`OpenVRLinkXR` on macOS, `OpenVRLinkAndroid` on Android) passes to
/// `XRClient`.
public struct XRPlatform {
    public var device: DeviceIdentity
    /// Network interfaces to prefer when reaching a host (such as wired Ethernet interfaces).
    public var preferredInterfaces: () -> [String] = { [] }
    /// Starts audio output for `session`; called on the connection thread when streaming begins.
    public var startAudio: (any StreamingSession) -> Void = { _ in }
    public var stopAudio: () -> Void = {}
    /// Requests microphone permission if needed and begins forwarding audio into `sink` (only called when
    /// `settings.microphone` is enabled).
    public var startMicrophone: (any MicrophoneSink) -> Void = { _ in }
    public var stopMicrophone: () -> Void = {}
    public var power: () -> PowerState? = { nil }
    /// Polls a platform system button not exposed through OpenXR (such as Android's back button), mapped to the
    /// left menu input.
    public var systemButton: (() -> Bool)?
    /// Per-headset controller grip pose offset (`HeadsetQuirks.gripOffset`).
    public var gripOffset: HeadsetQuirks.GripOffset?
    /// Width and height in pixels of the secondary sharp-layer swapchains (`XRDisplay.init`), or 0 to disable.
    public var sharpLayerPixels = 0
    /// Ratio of the display's center pixel density to the recommended eye swapchain size.
    public var eyeDetail: Float = 1
    /// Request sustained high CPU and GPU performance levels (`HeadsetQuirks.sustainedPerformance`).
    public var sustainedPerformance = true
    /// Start sessions with a reduced uplink packet rate (`HeadsetQuirks.leanUplink`).
    public var leanUplink = false
    /// `HeadsetQuirks.compositorPlacesLayers` and `HeadsetQuirks.passthroughLayer`.
    public var compositorPlacesLayers = true, passthroughLayer = false
    /// Whether the headset uses Play For Dream controllers (`DeviceProfile.playForDreamControllers`).
    public var playForDreamControllers = false
    /// `HeadsetQuirks.headVelocityFromPoses` and `controllerVelocityFromPoses`.
    public var headVelocityFromPoses = false, controllerVelocityFromPoses = false
    /// `HeadsetQuirks.colorSpace`.
    public var colorSpace = "rec709"
    /// `HeadsetQuirks.layerFilter`.
    public var layerFilter = "none"
    /// `HeadsetQuirks.encodingGamma`.
    public var encodingGamma = true

    public init(device: DeviceIdentity) {
        self.device = device
    }
}

/// Connects `XRDisplay`, `StreamLink`, `Panel`, and `ClientModel` into a shared OpenXR streaming client.
///
/// Selecting a host in the panel starts streaming as soon as the OpenXR session is ready. If the runtime pauses
/// the session (for example, when the headset is removed), `XRClient` pauses the stream and reconnects when the
/// session resumes; pressing Stop disconnects and clears the selected host. The panel stays visible until the
/// first video frame is decoded, and holding the controller menu button toggles it during a stream.
public final class XRClient<Graphics: XRGraphics, Decoder: StreamDecoder> where Decoder.Frame == Graphics.Frame {
    public let model: ClientModel
    public let link: StreamLink<Decoder>
    public let display: XRDisplay<Graphics>
    public let panel: Panel

    private let platform: XRPlatform
    private let lock = NSLock()
    /// Latest display profile delivered by `XRDisplay.onReady`, or `nil` while the session is paused.
    private var measured: DeviceProfile?
    private var panelPinned = false
    /// Play-space origin set by the most recent host-initiated recenter during this session, in tracking space.
    private var recentered: FloorFrame?
    /// Whether the stream to the current target has connected at least once; if it drops afterward, the
    /// client retries automatically until stopped. Guarded by `lock`.
    private var hasStreamed = false
    /// Whether a wired interface was active when the stream started, and the number of consecutive checks
    /// reporting a change (`followLink`). Guarded by `lock`.
    private var wiredAtStart = false, linkChanges = 0
    private var linkWatch: DispatchSourceTimer?
    /// Interval in seconds between reconnection attempts and network interface checks.
    static var retryEvery: Double { 2 }

    /// - Parameters:
    ///   - model, panel: Shared model and panel instances (which the shell may also render in a 2D launcher
    ///     window before starting OpenXR).
    public init(applicationName: String, graphics: Graphics, decoder: Decoder, model: ClientModel, panel: Panel,
                platform: XRPlatform, process: XRProcess = XRProcess(), log: @escaping (String) -> Void) throws {
        self.model = model
        self.panel = panel
        self.platform = platform
        link = StreamLink(decoder: decoder)
        let layer = XRPanelLayer(width: panel.width, height: panel.height)
        display = try XRDisplay(applicationName: applicationName, graphics: graphics, frames: link.frames, panel: layer,
                                process: process, sharpLayerPixels: platform.sharpLayerPixels, eyeDetail: platform.eyeDetail,
                                sustainedPerformance: platform.sustainedPerformance,
                                compositorPlacesLayers: platform.compositorPlacesLayers,
                                passthroughLayer: platform.passthroughLayer, colorSpace: platform.colorSpace, layerFilter: platform.layerFilter, log: log)
        if let offset = platform.gripOffset, !offset.isNone { display.input.gripOffsets = Side.allCases.map { offset.pose(for: $0) } }
        display.input.systemButton = platform.systemButton
        display.input.headVelocityFromPoses = platform.headVelocityFromPoses
        display.input.controllerVelocityFromPoses = platform.controllerVelocityFromPoses
        panel.showsPointer = true
        let hint = "Hold the menu button to show or hide this panel while streaming."
        panel.hint = hint

        layer.update = { [panel, weak self] pointer in
            panel.pointer = pointer
            // Prompt the user when face tracking is inactive because system face calibration hasn't been run.
            let uncalibrated = self?.display.faceNeedsCalibration ?? false
            panel.hint = hint + (uncalibrated ? "\nFace tracking requires calibration in the headset's system settings." : "")
            // Upload the initial image if the swapchain has never been written, even if ImGui's draw hash didn't change.
            return panel.update() || !layer.hasPicture ? panel.picture.pixels : nil
        }
        layer.isWanted = { [weak self] in
            guard let self else { return true }
            lock.lock()
            defer { lock.unlock() }
            return panelPinned || !link.hasPicture
        }
        layer.onMenuHeld = { [weak self] in
            guard let self else { return }
            lock.lock()
            panelPinned.toggle()
            lock.unlock()
        }

        link.onStatus = { [model] in model.show($0) }
        link.onFailed = { [weak self] in self?.lost($0) }
        link.onStarted = { [model, weak self] session in
            platform.startAudio(session)
            if model.settings.microphone { platform.startMicrophone(session.microphoneSink) }
            model.streamStarted()
            guard let self else { return }
            lock.lock()
            hasStreamed = true
            lock.unlock()
        }
        link.onStopped = { platform.stopMicrophone(); platform.stopAudio() }
        model.finder.busy = { [link] in link.active }
        model.startStream = { [weak self] target in
            guard let self else { return }
            // Reset hasStreamed when the user selects a host so an initial connection failure returns to the host list.
            lock.lock()
            hasStreamed = false
            lock.unlock()
            start(target)
        }
        let watch = DispatchSource.makeTimerSource(queue: .global())
        watch.schedule(deadline: .now() + XRClient.retryEvery, repeating: XRClient.retryEvery)
        watch.setEventHandler { [weak self] in self?.followLink() }
        watch.resume()
        linkWatch = watch
        model.stopStream = { [link] leaving in link.stop(leaving: leaving) }

        display.streamingSession = { [link] in link.session }
        if display.graphics.supportsChromaKey, display.canShowRoom {
            panel.features.insert(.chromaKey)
            // Host chroma keying overrides the client's chroma key on frames that carry `FrameLayout.HostKey`.
            display.chromaKey = { [model, link] in model.settings.chromaKeying(inGame: link.session?.sceneApplicationRunning ?? false) }
        } else {
            panel.features.remove(.chromaKey)
        }
        if display.graphics.supportsDepth {
            panel.features.insert(.depthFromPicture)
            display.depthFromPicture = { [model] in (model.settings.depthFromPicture, model.settings.showDepth) }
        } else {
            panel.features.remove(.depthFromPicture)
        }
        display.onPaused = { [weak self] in
            guard let self else { return }
            lock.lock()
            measured = nil
            lock.unlock()
            link.stop()
            model.streamPaused()
        }
        display.onReady = { [weak self] profile in
            guard let self else { return }
            lock.lock()
            measured = profile
            lock.unlock()
            updatePlaySpace()
            // Reconnect to the active host after a session pause, or connect to a host selected before the session was ready.
            if let target = model.state.target { start(target) }
        }
        // Re-query the OpenXR boundary whenever the runtime updates its reference space.
        display.onSpaceChanged = { [weak self] in
            guard let self else { return }
            lock.lock()
            // Clear any host recenter offset if a non-stage tracking origin itself shifted.
            if display.origin != .stage { recentered = nil }
            lock.unlock()
            updatePlaySpace()
        }
        // Apply system-initiated recenters to the play space the same way as host-requested recenters.
        display.onRecentered = { [weak self] place in
            guard let self else { return }
            lock.lock()
            recentered = FloorFrame(position: Vec3(place.position.x, 0, place.position.z), yaw: FloorFrame.heading(of: place))
            lock.unlock()
            updatePlaySpace()
        }
        link.onRecenterRequested = { [weak self] in
            guard let self, let head = display.input.head()?.pose else { return }
            lock.lock()
            recentered = FloorFrame(position: Vec3(head.position.x, 0, head.position.z), yaw: FloorFrame.heading(of: head))
            lock.unlock()
            updatePlaySpace()
        }
        model.search()
    }

    /// Updates `link.playSpace` using either the latest host-requested recenter frame or the tracking origin,
    /// transforming the OpenXR stage boundary so it remains fixed in physical space.
    private func updatePlaySpace() {
        lock.lock()
        let frame = recentered ?? FloorFrame(position: Vec3(0, 0, 0), yaw: 0)
        lock.unlock()
        link.playSpace = PlaySpace(origin: frame.pose, boundary: display.boundary().map { frame.local(Vec3($0.x, 0, $0.z)) })
    }

    /// Handles stream disconnects and connection failures. If the stream had already connected, retries every
    /// `retryEvery` seconds until it reconnects or the user stops it; otherwise returns to the host list.
    private func lost(_ why: String) {
        lock.lock()
        let again = hasStreamed
        lock.unlock()
        guard again, let target = model.state.target else {
            model.streamEnded(why)
            return
        }
        model.streamInterrupted("\(why)\nReconnecting to \(target.name)")
        DispatchQueue.global().asyncAfter(deadline: .now() + XRClient.retryEvery) { [weak self] in
            // Skip retry if the user stopped the stream or selected a different host.
            guard let self, model.state.target == target, !link.active else { return }
            start(target, again: true)
        }
    }

    /// Restarts a running stream when a wired interface connects or disconnects so `HostConnector` can
    /// re-select the network path. Polled every `retryEvery` seconds and requires two consecutive checks
    /// before restarting to debounce transient interface states.
    private func followLink() {
        guard link.session != nil, let target = model.state.target else { return }
        let wired = !platform.preferredInterfaces().isEmpty
        lock.lock()
        linkChanges = wired == wiredAtStart ? 0 : linkChanges + 1
        let moved = linkChanges >= 2
        if moved { linkChanges = 0 }
        lock.unlock()
        guard moved else { return }
        Log.note(wired ? "wired interface connected; switching stream to wired link" : "wired interface disconnected; switching stream to Wi-Fi")
        link.stop()
        model.streamInterrupted(wired ? "Switching to wired link" : "Switching to Wi-Fi")
        start(target, again: true)
    }

    /// Starts connecting to `target` immediately if the OpenXR session is ready; otherwise `onReady` will
    /// connect once the session starts.
    private func start(_ target: ClientModel.Target, again: Bool = false) {
        lock.lock()
        let measured = self.measured
        panelPinned = false
        // Preserve any active recenter offset across automatic reconnections.
        if !again { recentered = nil }
        wiredAtStart = !platform.preferredInterfaces().isEmpty
        linkChanges = 0
        lock.unlock()
        guard var profile = measured else {
            model.show("Waiting for the headset")
            return
        }
        updatePlaySpace()
        let settings = model.settings
        profile.systemName = platform.device.systemName
        profile.leanUplink = platform.leanUplink
        profile.wantsEncodingGamma = platform.encodingGamma
        // Advertise host chroma-key support whenever passthrough is available; SteamVR enables keying per application.
        profile.hostChromaKey = display.graphics.supportsHostChromaKey && display.canShowRoom
        profile.playForDreamControllers = platform.playForDreamControllers
        profile.clientVersion = platform.device.clientVersion
        profile.eyeFrusta = profile.eyeFrusta.map { $0.scaled(horizontal: settings.fovScaleHorizontal, vertical: settings.fovScaleVertical) }
        var connector = HostConnector(platform.device)
        connector.microphone = settings.microphone
        connector.preferredInterfaces = platform.preferredInterfaces
        connector.log = { Log.note($0) }
        connector.askPin = { [model, link] in model.askPin { !link.isWanted } }
        var inputs = StreamLink<Decoder>.Inputs(head: { [display] in display.input.head() }, hands: { [display] in display.input.hands() })
        inputs.haptic = { [display] in display.input.vibrate($0) }
        if display.input.tracksGaze {
            profile.tracksGaze = true
            inputs.gaze = { [display] in display.input.gaze() }
        }
        if display.tracksFace { inputs.face = { [display] in display.faceExpressions() } }
        profile.tracksEyesOrFace = display.input.tracksGaze || display.tracksFace
        inputs.refreshRateRequested = { [display] in display.requestRefreshRate($0) }
        inputs.power = platform.power
        link.start(target.kind, address: target.address, port: target.port, profile: profile, connector: connector, inputs: inputs)
    }

    deinit { linkWatch?.cancel() }

    /// Runs the OpenXR session until it exits, then tells the host the client is leaving.
    public func run() throws {
        defer { link.stop(leaving: true) }
        try display.run()
    }

    /// Asks the session to end, making `run` return. Thread-safe.
    public func quit() {
        display.quit()
    }
}
