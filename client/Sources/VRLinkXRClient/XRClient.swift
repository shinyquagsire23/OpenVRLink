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
                                process: process, log: log)
        panel.showsPointer = true
        panel.hint = "Hold the menu button to show or hide this panel while streaming."

        layer.update = { [panel] pointer in
            panel.pointer = pointer
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
        display.chromaKey = { [model, link] in model.settings.chromaKeying(inGame: link.session?.sceneApplicationRunning ?? false) }
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
            // Forward the OpenXR stage bounds to the host as the room boundary when available.
            link.playSpace = PlaySpace(origin: PlaySpace.trackingSpace.origin, boundary: display.boundary())
            // Reconnect to the active host after a session pause, or connect to a host selected before the session was ready.
            if let target = model.state.target { start(target) }
        }
        model.search()
    }

    /// Starts connecting to `target` immediately if the OpenXR session is ready; otherwise `onReady` will
    /// connect once the session starts.
    private func start(_ target: ClientModel.Target) {
        lock.lock()
        let measured = self.measured
        panelPinned = false
        lock.unlock()
        guard var profile = measured else {
            model.show("Waiting for the headset")
            return
        }
        let settings = model.settings
        profile.systemName = platform.device.systemName
        profile.clientVersion = platform.device.clientVersion
        profile.eyeFrusta = profile.eyeFrusta.map { $0.scaled(horizontal: settings.fovScaleHorizontal, vertical: settings.fovScaleVertical) }
        var connector = HostConnector(platform.device)
        connector.microphone = settings.microphone
        connector.preferredInterfaces = platform.preferredInterfaces
        connector.log = { Log.note($0) }
        connector.askPin = { [model, link] in model.askPin { !link.isWanted } }
        var inputs = StreamLink<Decoder>.Inputs(head: { [display] in display.input.head() }, hands: { [display] in display.input.hands() })
        inputs.haptic = { [display] in display.input.vibrate($0) }
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
