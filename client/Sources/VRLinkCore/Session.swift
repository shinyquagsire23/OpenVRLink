// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// SVL streaming session implementation (docs/svl-transport/,
// docs/svl-tracking-input/poses.md).

/// Fixed constants in the SVL pose message (docs/svl-tracking-input/poses.md).
enum PoseMessage {
    /// Protocol version in byte 0. The host drops pose messages with any other
    /// value and logs "svl protocol version mismatch. Server expects 10"
    /// (probed 2026-11-13).
    static let protocolVersion: UInt8 = 0x0A
    /// Byte 2 is always 0x20 in captures; its meaning is unknown, and the host
    /// streams normally when sent 0 (probed 2026-11-13).
    static let unknownConstant: UInt8 = 0x20
    /// Holdoff flag in byte 3. Non-zero asks the host to pause streaming; we always send 0.
    static let noHoldoff: UInt8 = 0
    /// Client minor version at the start of the HMD input block (followed by
    /// 8 reserved zero bytes, flags, and a 0xFF trailer byte).
    ///
    /// The host logs this field as "Peer Minor Version Number" and gates
    /// protocol features on it. Steam Link 2.0.25 sends 14, matching the wire
    /// behavior implemented here (docs/svl-transport/): publishing the
    /// capabilities value, using the extended frame report and eye-tracking
    /// message formats, and answering link probes. If a client reports version
    /// 14 without publishing the capabilities value, the host never activates
    /// the headset (probed 2026-11-13).
    static let minorVersion: UInt32 = 14
    static let hmdInputReserved = 8
    static let hmdInputFlagNothingInHands: UInt8 = 0x08
    static let hmdInputTrailer: UInt8 = 0xFF
}

/// Layout and constants for a single device's `PackedPose_t` entry in a pose message.
enum PackedPose {
    static let size = 88
    /// Byte offset of the 16-bit tracking result field, followed immediately by the state byte.
    static let trackingResultOffset = 0x34
    /// Tracking result codes (inferred from OpenVR's `ETrackingResult`).
    static let trackingUninitialized: UInt16 = 1
    static let trackingRunningOK: UInt16 = 200
    /// Device states: 0 = no device (default for a zeroed pose), 1 = located but not fully valid, 2 = valid.
    static let stateValid: UInt8 = 2
    /// Identity device-from-pose offset (xyz position followed by wxyz quaternion).
    static let identityOffset: [Float] = [0, 0, 0, 1, 0, 0, 0]
}

/// Runs an SVL streaming session on its own dedicated thread, invoking
/// `onFrame` on that thread with each reassembled HEVC access unit and its
/// host metadata.
public final class StreamSession: StreamingSession {
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Unused for SVL: a disconnected Steam host simply stops sending packets.
    public var onEnded: ((String) -> Void)?

    public let profile: DeviceProfile
    private let socket: UDPSocket
    private var link: SVLLink
    private let values = ValueTransport()
    private let assembler = FrameAssembler(now: 0)
    private let audioReceiver = AudioReceiver()
    /// Decoded audio waiting to be played; an audio output pulls from it.
    public var audio: PlaybackBuffer { audioReceiver.buffer }
    /// Captures and packets microphone audio to send to the host.
    public let microphone = MicrophoneUplink()
    public var microphoneSink: any MicrophoneSink { microphone }
    private var clock = ClockOffset()
    private var statisticsSent = 0
    /// OpenVRLink extension handshake state; guarded by `lock`.
    private var extensions = HostExtensions()
    private var extensionsReported: UInt32?
    private var gammaReported: Float = 1
    private let started = Uptime.nanoseconds
    private var sequence: UInt16 = 0
    private var frameCounter: Int32 = 0
    private var frameDisplayTime: Int32 = 0
    /// Tracks the display refresh rate last reported to the host.
    private var rate: RefreshRate
    private var framePeriod: Double { rate.period }
    private var hostInstance: Bytes?
    /// Nil until the host reports it; re-sent when a client reconnects.
    private var applicationRunning: Bool?
    /// Whether a scene application (such as a game, rather than SteamVR's
    /// empty compositor grid) is running on the host. The host only reports a
    /// boolean, not which application is active.
    public var sceneApplicationRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return applicationRunning ?? false
    }
    /// ID and arrival timestamps (session clock and Unix wall-clock
    /// microseconds) of the most recently completed frame.
    private var lastFrame: (id: UInt16, time: Int32, wallClock: UInt64) = (0, 0, 0)
    /// Session timestamp when each recent frame was passed to the decoder, indexed by `frameID % framesRemembered`.
    private var handedToDecoder = [Int32](repeating: 0, count: StreamSession.framesRemembered)
    static let framesRemembered = 64
    /// Interval in seconds between sending local address-list updates to the host.
    static let addressListInterval: TimeInterval = 2
    private var running = true
    private var sayGoodbye = false

    private let lock = NSLock()
    private var head = HeadPose(position: Vec3(0, 1.6, 0)).tracked
    private var framesReceived = 0
    private var decoded: (id: UInt16, time: Int32) = (0, 0)
    private var displayed: (id: UInt16, displayTime: Int32, submitted: Int32) = (0, 0, 0)
    private var nextRefresh: Int32?
    private var refreshPeriod: Double?

    /// Testing aid: discard this fraction of incoming video and audio
    /// messages, to exercise loss recovery on a clean network.
    public var simulatedLoss: Double = 0

    /// `vrlink` samples and sends head poses four times per display frame.
    static let posesPerFrame = 4
    static let poseBlockSize = 0x168
    static let valueTransportBudget = 0x174
    /// The sequence number of the datagram that ends the session.
    static let goodbyeSequence: UInt16 = 0xFFFF
    /// Focus event payload size and event codes (byte 0 holds the event type
    /// and the remaining bytes are zero). On the host, the two events sent by
    /// `vrlink` correspond to `EVTYPE_LDASH_PAUSE` ("Remote was paused") and
    /// `EVTYPE_LDASH_CONTINUE`.
    static let focusEventSize = 52
    static let focusEventPaused: UInt8 = 4
    static let focusEventContinued: UInt8 = 5
    /// Reset wrist velocity tracking after this many microseconds without a hand update.
    static let wristForgottenAfter: Int32 = 200_000
    /// Minimum elapsed time in microseconds required to compute wrist velocity.
    static let wristShortestStep: Int32 = 1000

    /// Creates a streaming session, optionally bound to `interface` (or nil to
    /// use system routing).
    public init?(_ args: SessionArgs, profile: DeviceProfile, interface: String? = nil) {
        // vrlink binds its local UDP port to match the host's port. Under minor
        // version 14, the host sends packets to that port on the client's IP
        // regardless of the source port it receives from; if nothing is bound
        // there, the resulting ICMP port-unreachable errors cause the host to
        // recreate its socket every two seconds (probed 2026-11-13). Fall back
        // to an ephemeral port if that port is already in use.
        guard let link = SVLLink(token: args.token),
              let socket = UDPSocket(interface: interface, localPort: args.port) ?? UDPSocket(interface: interface),
              socket.connect(host: args.host, port: args.port)
        else { return nil }
        self.link = link
        self.socket = socket
        self.profile = profile
        rate = RefreshRate(hz: profile.refreshHz)
        audioReceiver.onLog = { [weak self] in self?.onLog?($0) }
        for (id, value) in profile.startupValues() { values.publish(id, value) }
        // Notify the host that the headset has focus (logged on the host as "Remote was continued").
        values.publish(DeviceProfile.ValueID.focusEvent, [StreamSession.focusEventContinued] + Bytes(repeating: 0, count: StreamSession.focusEventSize - 1), force: true)
    }

    /// Called on the session thread when the host requests a target refresh
    /// rate in Hz (from `DeviceProfile.refreshHz` or `otherRefreshRates`).
    /// The platform can switch its display rate if supported, and we always
    /// report the display's actual measured refresh rate back to the host.
    public var onRefreshRateRequested: ((Float) -> Void)?
    private var rateHinted: Float?

    /// Polled on the session thread four times per frame for the latest head
    /// pose. Falls back to the last pose passed to `setHead` when nil.
    public var headProvider: (() -> TrackedPose?)?

    /// Polled with every pose update for `[left, right]` hand inputs, using
    /// nil for any hand without an active controller or hand tracking.
    public var handsProvider: (() -> [HandInput?])?
    /// Tracks whether each hand was last advertised to the host as a controller (`true`) or a tracked hand (`false`).
    private var handIsController: [Side: Bool] = [:]

    /// Polled once per second for the headset battery state; if nil, the host
    /// keeps the initial "full, not charging" state.
    public var headsetPowerProvider: (() -> PowerState?)?
    /// Last battery state reported to the host, keyed by value ID.
    private var powerPublished: [UInt8: PowerNews] = [:]

    /// Publishes a device's battery state if its level changed by at least 1% or charging state changed.
    private func publishPower(_ power: PowerState?, as id: UInt8) {
        guard let power = powerPublished[id, default: PowerNews()].news(power) else { return }
        values.publish(id, DeviceProfile.powerProps(power, reportsBattery: true), force: true)
    }
    /// Resolves hand gestures and smooths aim rays across pose updates.
    private var handResolver = HandResolver()
    /// Previous wrist pose and timestamp per hand, used to estimate wrist velocities.
    private var wrists: [(pose: TrackedPose, time: Int32)?] = [nil, nil]
    private var hostVersion: UInt32 = 0
    static let knownFECMode: UInt8 = 0x20
    private var warnedAboutFEC = false
    private var hapticPulses = 0
    /// Maximum interval between consecutive outgoing pose datagrams since the last 1-second log report.
    private var longestPoseGap: Double = 0
    private var lastPoseSent: Date?
    /// The host treats a tracked hand as a controller from this protocol version on.
    static let firstVersionWithHands: UInt32 = 7

    /// Polled with every pose for the eye-gaze fixation point in head space
    /// (meters: +x right, +y up, +z back). Returning nil or omitting the
    /// provider reports eye tracking as inactive.
    public var gazeProvider: (() -> Vec3?)?
    /// Polled with every pose for facial expression weights when supported by the platform.
    public var faceProvider: (() -> FaceExpressions?)?

    /// Called on the session thread when the host wants a controller to vibrate.
    public var onHaptic: ((HapticPulse) -> Void)?
    private var hapticsSeen: [[UInt16]] = [[], []]
    /// Which hands the host has been given a controller identity for.
    private var controllersPublished: Set<Side> = []

    /// The viewer's head, in world space. Safe to call from any thread.
    public func setHead(_ pose: TrackedPose) {
        lock.lock()
        head = pose
        lock.unlock()
    }

    /// Human-readable name of the session's datagram framing mode for logging.
    public var transportName: String { link.name }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "svl-session"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the session loop. When `leaving` is true (the user explicitly
    /// exited) or no scene application is running in SteamVR, we send a goodbye
    /// packet so the host shuts down SteamVR immediately. Otherwise we simply
    /// stop sending packets, allowing the host to keep the running game alive
    /// and accept a reconnect (docs/svl-transport/connection-lifecycle.md).
    public func stop(leaving: Bool = false) {
        lock.lock()
        running = false
        sayGoodbye = leaving
        lock.unlock()
    }

    /// Session timestamp reported to the host, in microseconds since session
    /// start (32-bit wrapping). Thread-safe.
    public func now() -> Int32 {
        Int32(truncatingIfNeeded: (Uptime.nanoseconds - started) / 1000)
    }

    // MARK: Display timing callbacks

    /// The decoder has produced this frame's picture.
    public func frameDecoded(_ frameID: UInt16) {
        let time = now()
        lock.lock()
        decoded = (frameID, time)
        lock.unlock()
    }

    /// This frame has been submitted for display and is expected on screen at
    /// `displayTime` (session clock).
    public func frameDisplayed(_ frameID: UInt16, displayTime: Int32) {
        let time = now()
        lock.lock()
        displayed = (frameID, displayTime, time)
        lock.unlock()
    }

    /// Updates the next expected vsync timestamp and refresh interval so the
    /// host can pace frame delivery.
    public func displayWillRefresh(at displayTime: Int32, period: Double) {
        lock.lock()
        nextRefresh = displayTime
        refreshPeriod = period
        lock.unlock()
    }

    // MARK: StreamingSession conformance

    /// Converts a system uptime timestamp in nanoseconds to the 32-bit microsecond session clock.
    private func sessionTime(_ uptimeNanoseconds: UInt64) -> Int32 {
        Int32(truncatingIfNeeded: (Int64(bitPattern: uptimeNanoseconds) - Int64(bitPattern: started)) / 1000)
    }

    public func frameDecoded(_ frameID: UInt16, picture: Int) { frameDecoded(frameID) }

    /// No-op for SVL: the Steam host resends parameter sets frequently enough
    /// for the decoder to recover on its own.
    public func frameNotDecoded(_ frameID: UInt16, picture: Int) {}

    public func frameShown(_ frameID: UInt16, at uptimeNanoseconds: UInt64) {
        frameDisplayed(frameID, displayTime: sessionTime(uptimeNanoseconds))
    }

    public func displayRefreshes(at uptimeNanoseconds: UInt64, period: Double) {
        displayWillRefresh(at: sessionTime(uptimeNanoseconds), period: period)
    }

    // MARK: Sending

    /// PackedPose_t, 88 bytes: position in meters, orientation (w first),
    /// velocities, tracking state, and an identity offset pose.
    /// `offset` is where the host should place its device relative to the pose.
    private func packedPose(_ tracked: TrackedPose?, offset: [Float] = PackedPose.identityOffset) -> Bytes {
        guard let tracked else {
            // Absent: tracking result "uninitialized", state "no device".
            var out = Bytes(repeating: 0, count: PackedPose.size)
            out[PackedPose.trackingResultOffset] = UInt8(PackedPose.trackingUninitialized)
            return out
        }
        var out = Bytes()
        let position = tracked.pose.position, velocity = tracked.linearVelocity, spin = tracked.angularVelocity
        for value in [position.x, position.y, position.z] + tracked.pose.quaternion { out.append(float: value) }
        for value in [velocity.x, velocity.y, velocity.z, spin.x, spin.y, spin.z] { out.append(float: value) }
        out.append(integer: PackedPose.trackingRunningOK)
        out.append(PackedPose.stateValid)
        out.append(0)                            // padding
        for value in offset { out.append(float: value) }
        out.append(zeros: 4)
        return out
    }

    /// Computes the wrist pose with world-space velocities smoothed to match `vrlink`.
    private func trackedWrist(_ hand: TrackedHand, _ side: Side) -> TrackedPose {
        let pose = hand.joints[TrackedHand.wrist], time = now()
        guard let last = wrists[side.rawValue], time &- last.time < StreamSession.wristForgottenAfter else {
            wrists[side.rawValue] = (TrackedPose(pose: pose), time)
            return TrackedPose(pose: pose)
        }
        let moved = pose.position - last.pose.pose.position
        // Hand tracking updates less often than poses are sent: between
        // updates, send the newest pose with the velocities already measured.
        guard time &- last.time >= StreamSession.wristShortestStep, moved.dot(moved) > 0 else {
            var same = last.pose
            same.pose = pose
            return same
        }
        var tracked = TrackedPose(pose: pose).withVelocities(since: last.pose.pose, seconds: Float(time &- last.time) / 1_000_000)
        // `withVelocities` computes angular velocity in wrist-local space;
        // rotate it into world space for the host.
        let spin = tracked.angularVelocity
        tracked.angularVelocity = pose.right * spin.x + pose.up * spin.y + pose.forward * -spin.z
        tracked.linearVelocity = last.pose.linearVelocity * 0.8 + tracked.linearVelocity * 0.2
        tracked.angularVelocity = last.pose.angularVelocity * 0.8 + tracked.angularVelocity * 0.2
        wrists[side.rawValue] = (tracked, time)
        return tracked
    }

    /// Builds the main pose element along with a separate hand-skeleton element for each tracked hand.
    private func poseMessages(subIndex: Int, head: TrackedPose, hands: [ResolvedHand?]) -> (pose: SVLElement, hands: [SVLElement]) {
        let time = now()
        var inputBlocks = Bytes(), poses = Bytes(), handMessages: [SVLElement] = []
        for side in Side.allCases {
            switch hands[side.rawValue] {
            case .controller(let controller):
                inputBlocks.append(contentsOf: controller.inputBlock())
                poses.append(contentsOf: packedPose(controller.gripForHost, offset: ControllerState.gripOffset(side, senseModel: profile.senseControllerModels)))
            case .hand(let hand, let gestures, let aim):
                let offset = TrackedHand.wristOffset(side)
                inputBlocks.append(contentsOf: gestures.inputBlock())
                poses.append(contentsOf: packedPose(trackedWrist(hand, side),
                                                    offset: [offset.position.x, offset.position.y, offset.position.z] + offset.orientation))
                handMessages.append(hand.message(side, gestures: gestures, aim: aim))
            case nil:
                inputBlocks.append(zeros: InputBlock.size)
                poses.append(contentsOf: packedPose(nil))
            }
        }
        var out = Bytes()
        out.append(PoseMessage.protocolVersion)
        out.append(UInt8(subIndex))
        out.append(PoseMessage.unknownConstant)
        out.append(PoseMessage.noHoldoff)
        out.append(integer: clock.confident ? clock.offset : 0)
        out.append(integer: time)                // send time
        out.append(integer: time)                // sample time
        // When this frame will be displayed. The host paces against it, so it
        // must stay the same for all four poses of a frame.
        out.append(integer: frameDisplayTime)
        out.append(integer: frameCounter)
        out.append(integer: assembler.resetCounter)   // bumped to ask for a keyframe
        out.append(integer: PoseMessage.minorVersion)        // the headset's input block: no buttons
        out.append(zeros: PoseMessage.hmdInputReserved)
        out.append(hands.contains { $0 != nil } ? 0 : PoseMessage.hmdInputFlagNothingInHands)
        out.append(PoseMessage.hmdInputTrailer)
        out.append(contentsOf: inputBlocks)
        out.append(contentsOf: packedPose(head))
        out.append(contentsOf: poses)
        assert(out.count == StreamSession.poseBlockSize)
        out.append(contentsOf: values.tick(budget: StreamSession.valueTransportBudget))
        return (SVLElement(.pose, value: out), handMessages)
    }

    /// Tells the host how far each frame got: when its last packet arrived,
    /// when it was decoded, and when it was shown (docs/svl-video/retransmit.md).
    private func frameReport() -> SVLElement {
        lock.lock()
        let decoded = self.decoded, displayed = self.displayed
        lock.unlock()
        var out = Bytes()
        out.append(integer: decoded.time)
        out.append(integer: lastFrame.time)          // accepted: complete off the network
        out.append(integer: displayed.id)
        out.append(integer: UInt16(0))
        out.append(integer: displayed.displayTime)   // when it is expected on screen
        out.append(integer: displayed.id)
        out.append(integer: UInt16(0))
        out.append(integer: displayed.submitted)     // when it was handed to the display
        out.append(integer: lastFrame.wallClock)     // accepted, by the wall clock
        out.append(integer: handedToDecoder[Int(decoded.id) % StreamSession.framesRemembered])
        return SVLElement(.frameReport, id: decoded.id, index: lastFrame.id, value: out)
    }

    /// Encodes three key-value statistics entries per message, matching `vrlink`
    /// (docs/svl-values/svlroot-key-value-channel.md): round-trip ping, peak
    /// packet delay (used by SteamVR's network performance graph), and one
    /// rotating steady-state reception metric.
    private func statistics() -> SVLElement {
        var out = Bytes()
        // Rotate the two extension handshake records alongside the steady-state metrics.
        // An unpatched host stores and echoes them without acting on them.
        lock.lock()
        let ours = extensions.records(atMilliseconds: Uptime.nanoseconds / 1_000_000)
        lock.unlock()
        let steady = [("cRXpass", 100.0), ("cRXerr", 0.0), ("cFramePhase", 0.3)] + ours.map { ($0.key, $0.value) }
        statisticsSent &+= 1
        for (key, value) in [("cPingMS", Double(clock.roundTrip) / 1000), ("cPingAMS", Double(clock.peakDelay) / 1000),
                             steady[statisticsSent % steady.count]] {
            out.append(text: key, fieldSize: 20)
            out.append(double: value)
            out.append(integer: now())
        }
        return SVLElement(.statistics, value: out)
    }

    /// Builds the client address-list element (docs/svl-transport/host-address-list.md):
    /// a count byte (`1`) followed by a single endpoint record containing the
    /// address family (`0` for IPv4), remaining record length (`19`), big-endian
    /// port, subnet prefix length, and 16-byte padded IP address. Under minor
    /// version 14, the host recreates its socket every two seconds if it does not
    /// receive this list (probed 2026-11-13).
    private func addressList() -> SVLElement? {
        guard let local = socket.localEndpoint() else { return nil }
        var out: Bytes = [1, 0, 19, UInt8(local.port >> 8), UInt8(local.port & 0xFF), local.prefixLength]
        out.append(contentsOf: local.address)
        out.append(zeros: 12)
        return SVLElement(.addressList, value: out)
    }

    private func send(_ elements: [SVLElement]) {
        socket.send(link.pack(sequence: sequence, elements: elements))
        sequence &+= 1
    }

    // MARK: Receiving

    /// Publishes the display's current frame interval in microseconds to the host.
    /// Pass `again: false` to suppress duplicate updates when the host repeatedly
    /// polls for a rate change.
    private func publishFrameTime(_ hz: Float, again: Bool = true) {
        var value = Bytes()
        value.append(integer: UInt32(1_000_000.5 / Double(hz)))
        values.publish(DeviceProfile.ValueID.requestedFrameTime, value, force: again)
    }

    private func valuesCompleted(_ ids: [UInt8]) {
        for id in ids {
            guard let data = values.remote[id]?.data else { continue }
            noteForStudy("value 0x" + String(id, radix: 16), data, version: values.remote[id]?.version)
            switch id {
            case DeviceProfile.ValueID.hostInstance:
                // A new host instance means it has forgotten everything we published.
                if hostInstance != data {
                    hostInstance = data
                    values.republishAll()
                }
            case DeviceProfile.ValueID.displayRateRequest:
                let hz = data.float(at: 0)
                guard hz > 1 else { break }
                // Always report the display's actual refresh rate back to the host.
                // Forward the requested rate to the platform; if the display switches,
                // the main loop will detect the new period and publish it.
                if hz != rateHinted {
                    rateHinted = hz
                    onLog?("host asked for \(hz) Hz")
                    onRefreshRateRequested?(hz)
                }
                publishFrameTime(rate.hz, again: false)
            case DeviceProfile.ValueID.propRefresh:
                values.republishAll()
            case DeviceProfile.ValueID.sceneApplicationRunning:
                let running = data.contains { $0 != 0 }
                lock.lock()
                applicationRunning = running
                lock.unlock()
                onLog?(running ? "the host says an application is running" : "the host says no application is running")
            default:
                break
            }
        }
    }

    /// Feeds the host's extension records to the handshake and logs when a patched host is first recognized.
    private func receive(extensionRecords: [(key: String, value: Double)]) {
        let time = Uptime.nanoseconds / 1_000_000
        lock.lock()
        for record in extensionRecords { extensions.receive(key: record.key, value: record.value, atMilliseconds: time) }
        let version = extensions.hostPresent(atMilliseconds: time) ? extensions.hostVersion : nil
        let report = version != nil && version != extensionsReported
        if report { extensionsReported = version }
        let available = extensions.available
        lock.unlock()
        if report, let version {
            onLog?("the host has the OpenVRLink extensions (version \(version)); encoding gamma "
                   + (available.contains(.encodingGamma) ? "available" : "not available"))
        }
    }

    /// Send what the assembler wants resent and hand finished frames on.
    private func drainAssembler() {
        let requests = assembler.takeRequests()
        if !requests.isEmpty { send(requests) }
        for frame in assembler.takeFrames() {
            let time = now()
            lastFrame = (frame.frameID, time, UInt64(Date().timeIntervalSince1970 * 1_000_000))
            handedToDecoder[Int(frame.frameID) % StreamSession.framesRemembered] = time
            framesReceived += 1
            var layout = frame.metadata.layout(profile: profile)
            lock.lock()
            layout.encodingGamma = extensions.encodingGamma(atMilliseconds: Uptime.nanoseconds / 1_000_000)
            let gammaChanged = layout.encodingGamma != gammaReported
            gammaReported = layout.encodingGamma
            lock.unlock()
            if gammaChanged {
                onLog?(layout.encodingGamma > 1 ? "frames now arrive with encoding gamma \(layout.encodingGamma)"
                                                : "frames now arrive without encoding gamma")
            }
            onFrame?(EncodedFrame(frameID: frame.frameID, data: frame.data, layout: layout))
        }
    }

    private func receive(_ datagram: Bytes) {
        if let echo = LinkProbe.reply(to: datagram) {
            socket.send(echo)
            return
        }
        if LinkProbe.isProbe(datagram) { return }
        guard let elements = link.unpack(datagram) else { return }
        for element in elements {
            switch element.kind {
            case .frameDescriptor, .videoPacket:
                if simulatedLoss > 0, Double.random(in: 0..<1) < simulatedLoss { break }
                if element.kind == .frameDescriptor {
                    let descriptor = FrameDescriptor(element)
                    hostVersion = descriptor.hostVersion
                    if descriptor.fecMode != StreamSession.knownFECMode, !warnedAboutFEC {
                        warnedAboutFEC = true
                        onLog?(String(format: "the host says its video uses error correction 0x%02x; this client only knows 0x%02x, so lost packets may not be repaired",
                                      descriptor.fecMode, StreamSession.knownFECMode))
                    }
                    clock.update(peerTime: descriptor.txTime, peerOffset: descriptor.hostClockOffset, localTime: now())
                    valuesCompleted(values.receive(descriptor.valueTransportBytes))
                    if !descriptor.extensionRecords.isEmpty { receive(extensionRecords: descriptor.extensionRecords) }
                    assembler.accept(descriptor: descriptor, group: Int(element.index), now: now())
                } else {
                    assembler.accept(packet: element, now: now())
                }
                drainAssembler()
            case .audio, .audioVariable:
                if simulatedLoss > 0, Double.random(in: 0..<1) < simulatedLoss { break }
                audioReceiver.accept(element)
            case .valueTransport:
                valuesCompleted(values.receive(Bytes(element.value)))
            case .haptics:
                for pulse in HapticPulse.parse(Bytes(element.value), seen: &hapticsSeen) {
                    hapticPulses += 1
                    onHaptic?(pulse)
                }
            case _ where element.messageClass == SVLClass.serverEvent:
                onLog?("host: " + String(decoding: element.value.dropFirst(4), as: UTF8.self))
            default:
                // the host's address list, and anything unknown
                if StreamSession.studyingHost {
                    noteForStudy("message class \(element.messageClass) type 0x" + String(element.kind.type, radix: 16),
                                 Bytes(element.value), version: nil)
                }
            }
        }
    }

    /// Protocol debugging helper enabled by setting `OPENVRLINK_LOG_HOST=1`.
    /// Logs every host-published value and unhandled SVL message whenever its
    /// payload changes (rate-limited to once per second per key). Used to build
    /// docs/svl-values/vte-id-table.md.
    private func noteForStudy(_ name: String, _ data: Bytes, version: UInt8?) {
        guard StreamSession.studyingHost else { return }
        let time = Date()
        var entry = studied[name] ?? (data: [], noted: .distantPast, skipped: 0)
        guard entry.data != data else { return }
        guard time.timeIntervalSince(entry.noted) >= 1 else {
            entry.skipped += 1
            entry.data = []          // clear cached bytes so the final settled value will be logged
            studied[name] = entry
            return
        }
        let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        onLog?("host \(name)\(version.map { " v\($0)" } ?? ""), \(data.count) bytes: \(hex)\(data.count > 64 ? " ..." : "")"
               + (entry.skipped > 0 ? " (\(entry.skipped) changes since the last line)" : ""))
        studied[name] = (data, time, 0)
    }
    private var studied: [String: (data: Bytes, noted: Date, skipped: Int)] = [:]
    private static let studyingHost = ProcessInfo.processInfo.environment["OPENVRLINK_LOG_HOST"] == "1"

    // MARK: Loop

    private func run() {
        var nextTick = Date()
        var nextReport = Date().addingTimeInterval(1)
        var nextAddressList = Date()
        var subIndex = 0
        while true {
            lock.lock()
            let keepGoing = running, lastHead = self.head
            lock.unlock()
            if !keepGoing { break }

            if let datagram = socket.receive(timeout: nextTick.timeIntervalSinceNow) {
                receive(datagram)
            }
            assembler.tick(now: now())
            drainAssembler()
            // Microphone packets go out as they come, one to a datagram,
            // once the host has started streaming.
            let captured = microphone.takePackets()
            if hostVersion != 0 { for packet in captured { send([packet]) } }
            let time = Date()
            if time >= nextTick {
                if subIndex == 0 {
                    frameCounter &+= 1
                    lock.lock()
                    let refresh = nextRefresh, period = refreshPeriod
                    lock.unlock()
                    if let period, let change = rate.follow(period) {
                        let hz = change.to
                        onLog?(change.note)
                        // Report the new refresh rate so the host adjusts its stream. If the
                        // device profile exposes a fixed list of alternate rates, keep that list
                        // unchanged so SteamVR's settings UI continues to show all choices;
                        // otherwise update `availableRates` to match the single active rate.
                        if profile.otherRefreshRates.isEmpty {
                            values.publish(DeviceProfile.ValueID.availableRates, profile.availableRates([hz]), force: true)
                        }
                        publishFrameTime(hz)
                    }
                    // Target the first upcoming display refresh.
                    let step = Int32(framePeriod * 1_000_000)
                    var target = refresh ?? now() &+ step
                    while target &- now() <= 0 { target &+= step }
                    frameDisplayTime = target
                }
                let head = headProvider?() ?? lastHead
                // Only send tracked hands once the host reports a protocol version that supports them.
                let resolved = handResolver.resolve(handsProvider?() ?? [], head: head.pose, seconds: Double(now()) / 1_000_000,
                                                    bareHands: hostVersion >= StreamSession.firstVersionWithHands)
                for note in resolved.notes + resolved.gestureNotes { onLog?(note) }
                let hands = resolved.hands
                for side in Side.allCases {
                    var isController: Bool?
                    switch hands[side.rawValue] {
                    case .controller: isController = true
                    case .hand: isController = false
                    case nil: break
                    }
                    if let isController, handIsController[side] != isController {
                        // Hand input mode changed between controller and bare hand; republish its device properties.
                        handIsController[side] = isController
                        powerPublished[DeviceProfile.ValueID.powerController(side)] = nil
                        for (id, value) in profile.handValues(side, isController: isController) {
                            values.publish(id, value, force: true)
                        }
                    }
                }
                for side in Side.allCases {
                    if case .controller(let controller) = hands[side.rawValue] {
                        publishPower(controller.power, as: DeviceProfile.ValueID.powerController(side))
                    }
                }
                let messages = poseMessages(subIndex: subIndex, head: head, hands: hands)
                if let last = lastPoseSent { longestPoseGap = max(longestPoseGap, time.timeIntervalSince(last)) }
                lastPoseSent = time
                let eyes = EyesAndFace.message(gaze: gazeProvider?(), face: faceProvider?())
                send([eyes, statistics(), frameReport(), messages.pose])
                if !messages.hands.isEmpty { send(messages.hands) }
                subIndex = (subIndex + 1) % StreamSession.posesPerFrame
                nextTick = max(nextTick.addingTimeInterval(framePeriod / Double(StreamSession.posesPerFrame)),
                               time.addingTimeInterval(-0.05))
            }
            if time >= nextAddressList {
                if hostVersion != 0, let list = addressList() { send([list]) }
                nextAddressList = time.addingTimeInterval(StreamSession.addressListInterval)
            }
            if time >= nextReport {
                publishPower(headsetPowerProvider?(), as: DeviceProfile.ValueID.powerHMD)
                lock.lock()
                let decoded = self.decoded, displayed = self.displayed
                lock.unlock()
                // Rough latencies from the most recent frame at each stage.
                let toDecode = Double(decoded.time &- lastFrame.time) / 1000
                let toScreen = Double(displayed.displayTime &- decoded.time) / 1000
                onLog?(String(format: "latest: network->decoded %.1f ms, decoded->on screen %.1f ms", toDecode, toScreen))
                onLog?("\(framesReceived) frames/s; so far \(assembler.repairedByFEC) packets repaired by FEC, "
                       + "\(assembler.packetsRequested) re-requested, \(assembler.framesAbandoned) frames abandoned; "
                       + "audio \(audioReceiver.recovered) recovered, \(audioReceiver.lost) lost, "
                       + "\(audio.underruns) underruns, \(audio.overflows) overflows")
                // Poses are due every quarter frame; a long gap means this thread was held up.
                if longestPoseGap > framePeriod {
                    onLog?(String(format: "the session thread was held up: %.0f ms between two poses", longestPoseGap * 1000))
                }
                longestPoseGap = 0
                if hapticPulses > 0 { onLog?("\(hapticPulses) haptic pulses played in the last second") }
                hapticPulses = 0
                framesReceived = 0
                nextReport = nextReport.addingTimeInterval(1)
            }
        }
        lock.lock()
        let leaving = sayGoodbye || applicationRunning == false
        lock.unlock()
        guard leaving else { return }
        let goodbye = link.pack(sequence: StreamSession.goodbyeSequence, elements: [SVLElement(.goodbye, value: [])])
        for _ in 0..<5 {
            socket.send(goodbye)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

/// SVLRoot::SymmetricTimingUpdate (docs/svl-timing/clock-sync.md): tracks the
/// smallest believable (local - peer) clock difference, in microseconds. The
/// 32-bit wrapping multiplies are part of vrlink's original behavior.
struct ClockOffset {
    private(set) var offset: Int32 = 0
    private var confidence: Int32 = 0
    var confident: Bool { confidence > 0 }

    /// Host's most recent `(peer - local)` clock offset estimate. Because each
    /// side's estimate includes one-way transit delay, summing `offset` and
    /// `peerOffset` cancels the clock difference and leaves the round-trip time.
    private var peerOffset: Int32 = 0
    /// Estimated round-trip latency in microseconds.
    var roundTrip: Int32 { confident ? offset &+ peerOffset : 0 }
    /// Recent worst packet delay relative to the minimum observed transit time
    /// plus half the RTT, in microseconds. Decays by `peakDecay` per packet
    /// and is clamped to `peakLimit`.
    private(set) var peakDelay: Int32 = 0
    /// Decay step and cap for `peakDelay`. The host configures decay via value
    /// 0x1c, which has been 1000 in every capture.
    static let peakDecay: Int32 = 1000, peakLimit: Int32 = 100_000

    mutating func update(peerTime: UInt32, peerOffset: Int32, localTime: Int32) {
        self.peerOffset = peerOffset
        follow(peerTime: peerTime, localTime: localTime)
        let delay = (localTime &- (offset &+ Int32(bitPattern: peerTime))) &+ roundTrip / 2
        peakDelay = min(ClockOffset.peakLimit, max(delay, peakDelay - ClockOffset.peakDecay))
    }

    private mutating func follow(peerTime: UInt32, localTime: Int32) {
        let difference = localTime &- Int32(bitPattern: peerTime)
        if confidence == 0 {
            offset = difference
            confidence = 1
            return
        }
        let k = 1_000_000 / (confidence + 5)
        let error = difference &- offset
        if error <= 0 {
            if error >= -(k / 2) {
                offset &-= min(100, ((0 &- error) &* k) / 200_000)
                confidence = min(400, confidence + 1)
            } else if confidence < 20 {
                confidence = 0
            } else {
                confidence -= 4
            }
        } else if error > k {
            confidence = max(0, confidence - 1)
        } else {
            offset &+= min(5, (error &* k) / 2_000_000)
            confidence = min(400, confidence + 1)
        }
    }
}
