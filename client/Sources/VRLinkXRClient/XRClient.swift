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
                                passthroughLayer: platform.passthroughLayer, colorSpace: platform.colorSpace, log: log)
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
        link.onFailed = { [model] in model.streamEnded($0) }
        link.onStarted = { [model] session in
            platform.startAudio(session)
            if model.settings.microphone { platform.startMicrophone(session.microphoneSink) }
            model.streamStarted()
        }
        link.onStopped = { platform.stopMicrophone(); platform.stopAudio() }
        model.finder.busy = { [link] in link.active }
        model.startStream = { [weak self] in self?.start($0) }
        model.stopStream = { [link] leaving in link.stop(leaving: leaving) }

        display.streamingSession = { [link] in link.session }
        if display.graphics.supportsChromaKey, display.canShowRoom {
            panel.features.insert(.chromaKey)
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

    /// Starts connecting to `target` immediately if the OpenXR session is ready; otherwise `onReady` will
    /// connect once the session starts.
    private func start(_ target: ClientModel.Target) {
        lock.lock()
        let measured = self.measured
        panelPinned = false
        recentered = nil
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
