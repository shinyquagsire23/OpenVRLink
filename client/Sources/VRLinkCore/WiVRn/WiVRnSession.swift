// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum WiVRnError: Error, CustomStringConvertible {
    case unreachable(String)
    case noReply
    case closed
    case wrongVersion
    case pinNeeded
    case wrongPin
    case pinCheckFailed
    case pairingDisabled
    case unexpected(String)

    public var description: String {
        switch self {
        case .unreachable(let host): return "nothing answered at \(host)"
        case .noReply: return "the host stopped answering"
        case .closed: return "the host closed the connection"
        case .wrongVersion: return "the host runs another release of WiVRn than this client knows (\(WiVRn.release))"
        case .pinNeeded: return "the host wants its PIN, and none was given"
        case .wrongPin: return "that is not the PIN the host shows"
        case .pinCheckFailed: return "the PIN could not be checked with the host"
        case .pairingDisabled: return "the host does not know this headset and is not pairing with new ones"
        case .unexpected(let what): return "the host sent \(what) where something else was due"
        }
    }
}

/// Manages a streaming session with a WiVRn host (docs/wivrn/protocol.md).
///
/// A session uses a TCP socket for reliable control messages and a UDP socket
/// on the negotiated port for real-time media and tracking packets. All wire
/// timestamps use the headset's monotonic uptime clock in nanoseconds; the host
/// estimates the clock offset via periodic time-sync queries.
public final class WiVRnSession: StreamingSession {
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onLog: ((String) -> Void)?
    public var headProvider: (() -> TrackedPose?)?
    public var handsProvider: (() -> [HandInput?])?
    public var headsetPowerProvider: (() -> PowerState?)?
    public var onHaptic: ((HapticPulse) -> Void)?
    public var gazeProvider: (() -> Vec3?)?
    public var faceProvider: (() -> FaceExpressions?)?
    private let microphone = WiVRnSession.microphoneQueue()
    public var microphoneSink: any MicrophoneSink { microphone }
    /// True when the host has requested microphone audio via `feature_control`.
    private var microphoneWanted = false
    /// Per-stream flag set after dropping an incomplete frame so dependent
    /// P-frames are skipped until the next keyframe arrives.
    private var awaitingKeyframe = [false, false, false]
    public var onRefreshRateRequested: ((Float) -> Void)?
    public var onEnded: ((String) -> Void)?
    /// Unused for WiVRn because WiVRn hosts do not send recenter requests to the client.
    public var onRecenterRequested: (() -> Void)?
    /// Most recent fatal error text from the host, reported if the connection closes.
    private var hostComplaint: String?
    public let audio = PlaybackBuffer()
    /// Always true for WiVRn because the host has no home environment and only streams client apps.
    public var sceneApplicationRunning: Bool { true }

    public let profile: DeviceProfile
    private let control: TCPSocket
    private let stream: UDPSocket
    private var controlReceived = Bytes()
    /// When encryption is enabled, each direction of the TCP control connection
    /// is encrypted as a continuous AES-CTR byte stream, including length prefixes.
    private var controlIn: Primitives.CounterCipher?
    private var controlOut: Primitives.CounterCipher?
    private let controlSendLock = NSLock()
    private var streamCipher: WiVRnStreamCipher?

    private let lock = NSLock()
    private var running = true
    private var head = HeadPose(position: Vec3(0, 1.6, 0)).tracked
    /// Display refresh rate last reported to the host, protected by `lock`.
    private var rate: RefreshRate
    private var refreshPeriod: Double { rate.period }

    /// Default target video bitrate in bits per second (matches WiVRn's default).
    static let bitsPerSecond: UInt32 = 50_000_000
    /// Fallback per-eye render resolution in pixels when the platform does not specify one.
    static let defaultEyePixels = (width: 2048, height: 2048)
    /// Target total pixel throughput per second across all encoded video streams.
    /// Per-eye encoded resolution is scaled to fit within this budget at the
    /// target refresh rate (capped at the native render resolution), and the host
    /// uses foveated scaling to cover the full field of view. Exceeding hardware
    /// encoder throughput drops the frame rate silently; NVENC on an NVIDIA GB10
    /// topped out at 650-690 MP/s across resolutions (docs/wivrn/protocol.md),
    /// so 600 MP/s leaves headroom.
    static let encodedPixelsPerSecond = 600e6
    /// Required alignment in pixels for encoded video dimensions.
    static let pixelAlignment = 32
    /// Stream index for the optional alpha channel stream.
    static let alphaPicture = 2
    /// Ring buffer capacity per stream for tracking in-flight frame feedback.
    static let framesRemembered = 64
    /// Maximum allowed control packet payload size in bytes, matching the host's limit.
    static let largestControlPacket = 16 << 20

    /// Maximum microphone payload per UDP datagram in bytes (aligned to whole samples),
    /// and a half-second backlog limit so audio doesn't accumulate when nobody is consuming it.
    static let microphonePacket = 1200, microphoneBacklog = MicrophoneFormat.bytesPerSecond / 2
    static func microphoneQueue() -> MicrophoneQueue {
        MicrophoneQueue(largestPacket: microphonePacket, most: microphoneBacklog)
    }

    private var description: WiVRnVideoDescription?
    private var assemblers = (0..<3).map { ShardAssembler(stream: UInt8($0)) }
    /// Ring buffer of recent frame timing records indexed by stream and `frame % framesRemembered`.
    private var feedback = [[WiVRnFeedback?]](repeating: [WiVRnFeedback?](repeating: nil, count: WiVRnSession.framesRemembered), count: 3)
    /// Device poses and prediction offsets requested by the host (defaults to unpredicted head pose).
    private var pattern: [(device: UInt8, prediction: Int64)] = [(WiVRn.Device.head, 0)]
    /// Preferred refresh rate for both the stream and display. Selecting the
    /// lowest supported display rate maximizes the per-frame pixel budget.
    private var targetHz: Float { ([profile.refreshHz] + profile.otherRefreshRates).min() ?? profile.refreshHz }
    /// Last sent scalar value and change timestamp for each WiVRn input ID.
    private var inputsSent: [UInt8: (value: Float, changed: Int64)] = [:]
    /// Resolves hand gestures and smooths aim rays across pose updates.
    private var handResolver = HandResolver()
    private var holding: [UInt8] = [WiVRn.InteractionProfile.none, WiVRn.InteractionProfile.none]
    /// Reset at the start of each display period so hand joints are sent once per frame.
    private var jointsDue = true
    private var powerSent = PowerNews()
    private var hasMicrophone = false
    private var foveationNoted: [WiVRnFoveation] = []
    private var alphaNoted = false
    private var framesReceived = [0, 0, 0], framesLost = [0, 0, 0], hapticPulses = 0

    private init(control: TCPSocket, stream: UDPSocket, profile: DeviceProfile) {
        self.control = control
        self.stream = stream
        self.profile = profile
        // Initialize to the requested target rate. If the display stays at a different rate,
        // `rate.follow` will detect the mismatch on the first refresh and notify the host.
        rate = RefreshRate(hz: ([profile.refreshHz] + profile.otherRefreshRates).min() ?? profile.refreshHz)
    }

    private static func now() -> Int64 { Int64(bitPattern: Uptime.nanoseconds) }

    // MARK: Connecting

    /// Connects to a WiVRn host, completes pairing and encryption setup, and sends
    /// headset capabilities. Streaming begins once `start()` is called.
    ///
    /// - Parameters:
    ///   - name: Display name shown for this headset on the host.
    ///   - identity: Persistent 56-byte client key (`WiVRnIdentity.own()`).
    ///   - pin: Closure invoked if the host requires a pairing PIN (the host waits
    ///     up to two minutes for user entry); returning `nil` aborts pairing.
    ///   - microphone: Whether to advertise a microphone input stream.
    ///   - preferred: Network interface names (such as wired USB/Ethernet adapters)
    ///     to try in order before falling back to default system routing.
    public static func connect(host: String, port: UInt16 = WiVRn.defaultPort, profile: DeviceProfile,
                               name: String, identity: Bytes = WiVRnIdentity.own(), pin: (() -> String?)? = nil,
                               microphone: Bool = false, preferring preferred: [String] = [],
                               onLog: ((String) -> Void)? = nil) throws -> WiVRnSession {
        guard let address = TCPSocket.resolve(host) else { throw WiVRnError.unreachable(host) }
        var sockets: (control: TCPSocket, stream: UDPSocket)?
        for interface in preferred where sockets == nil {
            if let control = TCPSocket(address: address, port: port, timeout: 1, interface: interface),
               let stream = UDPSocket(interface: interface) {
                sockets = (control, stream)
                onLog?("using wired interface \(interface)")
            }
        }
        if sockets == nil, let control = TCPSocket(address: address, port: port), let stream = UDPSocket() {
            sockets = (control, stream)
        }
        guard let (control, stream) = sockets else { throw WiVRnError.unreachable(host) }
        // WiVRn only lets a reconnecting headset rejoin an active session if its
        // eye frusta match the original session bit-for-bit (docs/wivrn/protocol.md).
        var profile = profile
        let measured = profile.eyeFrusta
        profile.eyeFrusta = WiVRnDisplayMemory.settled(measured, host: host)
        // Log both the reported and freshly measured frusta to help diagnose reconnect rejections.
        func text(_ frusta: [Frustum]) -> String {
            frusta.map { String(format: "%.4f %.4f %.4f %.4f", $0.left, $0.right, $0.down, $0.up) }.joined(separator: " | ")
        }
        onLog?("frusta told to the host: " + text(profile.eyeFrusta)
               + (text(measured) == text(profile.eyeFrusta) ? " (as measured)" : "; measured now: " + text(measured)))
        let session = WiVRnSession(control: control, stream: stream, profile: profile)
        session.hasMicrophone = microphone

        try session.sendControl(WiVRnPacket.cryptoHandshake(publicKey: WiVRnIdentity.pem(identity), name: name))
        guard case .cryptoHandshake(_, let state) = try session.awaitControl() else {
            throw WiVRnError.unexpected("no answer to the first packet")
        }
        switch WiVRn.CryptoState(rawValue: state) {
        case .encryptionDisabled:
            onLog?("the host does not encrypt")
        case .pinNeeded:
            guard let typed = pin?() else { throw WiVRnError.pinNeeded }
            try session.checkPin(typed)
            onLog?("the host has the same PIN, and knows this headset from now on")
            try session.encrypt(pin: typed)
        case .alreadyPaired:
            onLog?("the host knows this headset")
            try session.encrypt(pin: WiVRnSecrets.pairedPin)
        case .pairingDisabled: throw WiVRnError.pairingDisabled
        case .incompatibleVersion: throw WiVRnError.wrongVersion
        case nil: throw WiVRnError.unexpected("an answer this client does not know (\(state))")
        }
        try session.sendControl(WiVRnPacket.cryptoHandshakeDone)
        guard case .handshake(let streamPort) = try session.awaitControl() else {
            throw WiVRnError.unexpected("no stream port")
        }
        guard streamPort > 0, stream.connect(host: address, port: UInt16(streamPort)) else {
            throw WiVRnError.unexpected("no UDP port to stream on (a host set to TCP only is not supported)")
        }
        // Send UDP handshake packets repeatedly until the host acknowledges our
        // source address on the TCP control channel.
        var acknowledged = false
        let deadline = Date().addingTimeInterval(10)
        while !acknowledged {
            guard Date() < deadline else { throw WiVRnError.noReply }
            session.sendStream(WiVRnPacket.handshake)
            if let packet = try session.awaitControl(timeout: 0.1, required: false) {
                guard case .handshake = packet else { throw WiVRnError.unexpected("something other than its handshake") }
                acknowledged = true
            }
        }
        try session.sendControl(session.headsetInfo().packet)
        try session.sendControl(WiVRnPacket.sessionState(WiVRn.sessionStateFocused))
        return session
    }

    /// Runs the four-message PAKE PIN verification exchange (`WiVRnPinCheck`).
    private func checkPin(_ pin: String) throws {
        var check = WiVRnPinCheck(pin: pin)
        do {
            try sendControl(WiVRnPacket.pinCheck(.pinCheck1, check.first()))
            guard case .pinCheck2(let second) = try awaitControl() else { throw WiVRnError.pinCheckFailed }
            try sendControl(WiVRnPacket.pinCheck(.pinCheck3, try check.third(answering: second)))
            guard case .pinCheck4(let fourth) = try awaitControl() else { throw WiVRnError.pinCheckFailed }
            guard try check.matches(fourth) else { throw WiVRnError.wrongPin }
        } catch is WiVRnPinCheck.Failure {
            throw WiVRnError.pinCheckFailed
        }
    }

    /// Enables AES-CTR encryption on both the TCP control stream and UDP media socket.
    private func encrypt(pin: String) throws {
        guard let secrets = WiVRnSecrets(pin: pin),
              let incoming = Primitives.CounterCipher(key: secrets.controlKey, counter: secrets.controlCounterToHeadset),
              let outgoing = Primitives.CounterCipher(key: secrets.controlKey, counter: secrets.controlCounterFromHeadset)
        else { throw WiVRnError.pinCheckFailed }
        // Bytes buffered in controlReceived prior to this point arrived unencrypted.
        controlIn = incoming
        controlOut = outgoing
        streamCipher = WiVRnStreamCipher(secrets)
    }

    private func headsetInfo() -> WiVRnHeadsetInfo {
        let render = profile.eyePixels ?? WiVRnSession.defaultEyePixels
        // Budget for two full-size eye streams plus an alpha stream at half of
        // one eye's area (2.5 eyes total). Without budgeting for the alpha stream,
        // WayVR's passthrough mode dropped to 97 fps on a 120 Hz display.
        let perEye = WiVRnSession.encodedPixelsPerSecond / Double(targetHz) / 2.5
        let scale = min(1, (perEye / Double(render.width * render.height)).squareRoot())
        func encoded(_ side: Int) -> Int {
            max(WiVRnSession.pixelAlignment, Int(Double(side) * scale) / WiVRnSession.pixelAlignment * WiVRnSession.pixelAlignment)
        }
        return WiVRnHeadsetInfo(renderPixels: render, streamPixels: (encoded(render.width), encoded(render.height)),
                                // Sort refresh rates deterministically so reconnecting sessions
                                // advertise the exact same list regardless of the active rate.
                                refreshRates: Set([profile.refreshHz] + profile.otherRefreshRates).sorted(), preferredRate: targetHz,
                                bitsPerSecond: WiVRnSession.bitsPerSecond, frusta: profile.eyeFrusta,
                                codecs: [.h265, .h264], systemName: profile.systemName,
                                microphone: hasMicrophone, eyeGaze: profile.tracksGaze, face: profile.tracksEyesOrFace)
    }

    // MARK: Control and stream sockets

    /// Sends a length-prefixed packet over the TCP control socket.
    private func sendControl(_ packet: Bytes) throws {
        var framed = Bytes()
        framed.append(integer: UInt32(packet.count))
        framed.append(contentsOf: packet)
        // Serialize encryption and socket writes so the stream cipher state stays ordered.
        controlSendLock.lock()
        defer { controlSendLock.unlock() }
        guard control.send(controlOut?.apply(framed) ?? framed) else { throw WiVRnError.closed }
    }

    /// Extracts the next complete length-prefixed packet from the control receive buffer, if available.
    private func takeControlPacket() throws -> Bytes? {
        guard controlReceived.count >= 4 else { return nil }
        let length = Int(controlReceived.integer(at: 0) as UInt32)
        guard length > 0, length <= WiVRnSession.largestControlPacket else { throw WiVRnError.unexpected("a packet of \(length) bytes") }
        guard controlReceived.count >= 4 + length else { return nil }
        defer { controlReceived.removeFirst(4 + length) }
        return Bytes(controlReceived[4..<4 + length])
    }

    private func readControl() throws {
        guard let bytes = control.receiveAvailable() else { throw WiVRnError.closed }
        controlReceived.append(contentsOf: controlIn?.apply(bytes) ?? bytes)
    }

    /// Sends a single packet over the UDP media socket, encrypting it if a cipher is active.
    private func sendStream(_ packet: Bytes) {
        stream.send(streamCipher?.sealed(packet) ?? packet)
    }

    /// Reads from the TCP control socket until a complete packet arrives or `timeout` elapses.
    private func awaitControl(timeout: Double = 10, required: Bool = true) throws -> WiVRnToHeadset? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let packet = try takeControlPacket() {
                guard let parsed = WiVRnToHeadset(packet) else { throw WiVRnError.unexpected("a packet cut short") }
                return parsed
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                if required { throw WiVRnError.noReply }
                return nil
            }
            if Sockets.readable([control.descriptor], timeout: left)[0] { try readControl() }
        }
    }

    private func awaitControl() throws -> WiVRnToHeadset {
        guard let packet = try awaitControl(timeout: 10, required: true) else { throw WiVRnError.noReply }
        return packet
    }

    // MARK: Session loop

    public func setHead(_ pose: TrackedPose) {
        lock.lock()
        head = pose
        lock.unlock()
    }

    public func start() {
        let thread = Thread { [self] in
            var reason: String?
            do { try run() } catch {
                reason = hostComplaint.map { "the host said: " + $0 } ?? "\(error)"
                onLog?("the stream ended: \(reason ?? "")")
            }
            // Closing the TCP socket signals disconnect to the host so it resumes
            // advertising itself over mDNS.
            control.shutDown()
            if let reason { onEnded?(reason) }
        }
        thread.name = "wivrn-session"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the session loop; closing the TCP socket notifies the host.
    public func stop(leaving: Bool) {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func run() throws {
        onRefreshRateRequested?(targetHz)
        var frameStart = WiVRnSession.now()
        var sends = trackingTimes(from: frameStart)
        var nextReport = Date().addingTimeInterval(1)
        while true {
            lock.lock()
            let keepGoing = running, period = refreshPeriod
            lock.unlock()
            if !keepGoing { return }

            let due = sends.first?.at ?? frameStart
            let readable = Sockets.readable([stream.descriptor, control.descriptor],
                                            timeout: Double(due - WiVRnSession.now()) / 1e9)
            if readable[0] {
                // Drain all queued UDP datagrams at once since video shards arrive in bursts.
                while let datagram = stream.receive(timeout: 0) {
                    guard let opened = streamCipher == nil ? datagram : streamCipher?.opened(datagram) else { continue }
                    if let packet = WiVRnToHeadset(opened) { try handle(packet) }
                }
            }
            if readable[1] {
                try readControl()
                while let packet = try takeControlPacket() {
                    if let parsed = WiVRnToHeadset(packet) { try handle(parsed) }
                }
            }

            let time = WiVRnSession.now()
            // Drain captured microphone packets on every iteration, forwarding them
            // only while the host has microphone capture enabled.
            for packet in microphone.take() where microphoneWanted {
                sendStream(WiVRnPacket.audio(time: time, samples: packet[...]))
            }
            while let next = sends.first, next.at <= time {
                sends.removeFirst()
                sendTracking(at: time, prediction: next.prediction)
            }
            if sends.isEmpty {
                // Advance to the next display period, or resync to `time` after a stall.
                jointsDue = true
                frameStart += Int64(period * 1e9)
                if frameStart < time - Int64(period * 1e9) { frameStart = time }
                sends = trackingTimes(from: frameStart)
            }
            if Date() >= nextReport {
                if let power = powerSent.news(headsetPowerProvider?()) {
                    try? sendControl(WiVRnPacket.battery(power))
                }
                onLog?("left eye \(framesReceived[0]) frames/s, right eye \(framesReceived[1]); so far \(framesLost[0]) and \(framesLost[1]) lost"
                       + "; audio \(audio.underruns) underruns, \(audio.overflows) overflows"
                       + (hapticPulses > 0 ? "; \(hapticPulses) haptic pulses played" : ""))
                framesReceived = [0, 0, 0]
                hapticPulses = 0
                nextReport = nextReport.addingTimeInterval(1)
            }
        }
    }

    // MARK: Tracking

    /// Schedules when during the display period starting at `frameStart` to send
    /// tracking packets for each host-requested head prediction offset. Offsets
    /// are taken modulo the frame period from the end of the frame so poses are
    /// sampled as late as possible.
    private func trackingTimes(from frameStart: Int64) -> [(at: Int64, prediction: Int64)] {
        lock.lock()
        let period = Int64(refreshPeriod * 1e9)
        lock.unlock()
        let predictions = Set(pattern.filter { $0.device == WiVRn.Device.head }.map(\.prediction))
        return predictions.map { (frameStart + period - ($0 % period), $0) }.sorted { $0.0 < $1.0 }
    }

    private func sendTracking(at time: Int64, prediction: Int64) {
        lock.lock()
        let last = head
        lock.unlock()
        // Extrapolate poses using linear and angular velocity, matching SteamVR's
        // host-side prediction. Querying ARKit directly at the future timestamp
        // produces similar overshoot on small controller movements.
        let ahead = Float(prediction) / 1e9
        let head = (headProvider?() ?? last).predicted(seconds: ahead)
        let resolved = handResolver.resolve(handsProvider?() ?? [], head: head.pose, seconds: Double(time) / 1e9)
        for note in resolved.notes { onLog?(note) }
        let hands = resolved.hands

        var poses = [WiVRnDevicePose(WiVRn.Device.head, head)]
        var inputs: [(id: UInt8, value: Float)] = []
        var nowHolding = [WiVRn.InteractionProfile.none, WiVRn.InteractionProfile.none]
        for side in Side.allCases {
            switch hands[side.rawValue] {
            case .controller(let controller):
                nowHolding[side.rawValue] = WiVRn.InteractionProfile.touch
                // Extrapolate using damped angular velocity (`ControllerState.spinSent`)
                // to avoid rotational overshoot, and report that same damped velocity
                // in case the host extrapolates further.
                var grip = controller.gripForHost.predicted(seconds: ahead)
                poses.append(WiVRnDevicePose(WiVRn.Device.grip(side), grip))
                // Apply the predicted grip pose to derive the predicted aim pose.
                var aiming = controller
                aiming.grip = grip
                // Preserve any platform-supplied aim pose's local offset relative to the grip.
                if let aim = controller.aim { aiming.aim = grip.pose.placing(controller.grip.pose.relative(aim)) }
                grip.pose = aiming.aimPose(side)
                poses.append(WiVRnDevicePose(WiVRn.Device.aim(side), grip))
                inputs += controller.wivrnInputs(side)
            case .hand(let hand, let gestures, let aim):
                nowHolding[side.rawValue] = WiVRn.InteractionProfile.hand
                // Map palm to grip, thumb-index midpoint (with aim orientation) to
                // pinch, and index fingertip to poke.
                let indexTip = hand.joints[TrackedHand.tip(0)]
                var pinch = aim
                pinch.position = (hand.joints[TrackedHand.thumbTip].position + indexTip.position) * 0.5
                poses += [WiVRnDevicePose(WiVRn.Device.grip(side), hand.joints[0]), WiVRnDevicePose(WiVRn.Device.aim(side), aim),
                          WiVRnDevicePose(WiVRn.Device.pinchPose(side), pinch), WiVRnDevicePose(WiVRn.Device.poke(side), indexTip)]
                inputs += gestures.wivrnInputs(side)
            case nil:
                break
            }
        }
        holding = nowHolding
        // Convert the head-space gaze target into a pose at the head origin
        // oriented toward the target point.
        if profile.tracksGaze, let point = gazeProvider?(), length(point) > 0.001 {
            let forward = point * (1 / length(point))
            var sideways = forward.cross(Vec3(0, 1, 0))
            if length(sideways) < 0.001 { sideways = Vec3(1, 0, 0) }
            let right = sideways * (1 / length(sideways))
            poses.append(WiVRnDevicePose(WiVRn.Device.eyeGaze,
                                         Pose(position: Vec3(0, 0, 0), right: right, up: right.cross(forward), forward: forward)))
        }
        let views = Eye.allCases.map { WiVRnView(pose: profile.eyesInHead[$0.rawValue], frustum: profile.eyeFrusta[$0.rawValue]) }
        sendStream(WiVRnPacket.tracking(produced: time, time: time + prediction, views: views, holding: holding, poses: poses,
                                         face: profile.tracksEyesOrFace ? faceProvider?() : nil))

        // Send the full input state in every packet so dropped UDP packets self-heal on the next update.
        if !inputs.isEmpty {
            sendStream(WiVRnPacket.inputs(inputs.map { input in
                var sent = inputsSent[input.id] ?? (input.value, time)
                if sent.value != input.value { sent = (input.value, time) }
                inputsSent[input.id] = sent
                return (input.id, input.value, sent.changed)
            }))
        }
        // Send hand joint poses once per display period for each hand requested by the host.
        if jointsDue {
            jointsDue = false
            for side in Side.allCases where pattern.contains(where: { $0.device == WiVRn.Device.hand(side) }) {
                var joints: [Pose]?
                if case .hand(let hand, _, _) = hands[side.rawValue] { joints = hand.joints }
                sendStream(WiVRnPacket.handTracking(produced: time, time: time, side: side, joints: joints))
            }
        }
    }

    // MARK: Receiving

    private func handle(_ packet: WiVRnToHeadset) throws {
        switch packet {
        case .videoShard(let shard):
            guard Int(shard.stream) < assemblers.count else { break }
            let stream = Int(shard.stream)
            let result = assemblers[stream].accept(shard, now: WiVRnSession.now())
            for lost in result.abandoned {
                // Report incomplete frames to the host so it generates a recovery keyframe.
                framesLost[stream] += 1
                awaitingKeyframe[stream] = true
                try? sendControl(lost.packet)
            }
            if let whole = result.complete { finished(whole, picture: stream) }
        case .audio(_, let payload):
            audio.write(payload)
        case .timesyncQuery(let query):
            sendStream(WiVRnPacket.timesyncResponse(query: query, response: WiVRnSession.now()))
        case .trackingControl(let pattern, _):
            guard !pattern.isEmpty else { break }
            // Prediction offsets adjust continuously as latency changes, so only log
            // when the set of requested devices changes.
            if pattern.map(\.device) != self.pattern.map(\.device) {
                let head = pattern.filter { $0.device == WiVRn.Device.head }.map { "\($0.prediction / 1_000_000) ms" }
                onLog?("the host wants the head predicted \(head.joined(separator: ", ")) ahead, and \(pattern.count - head.count) poses of other devices")
            }
            self.pattern = pattern
        case .videoDescription(let description):
            if description != self.description {
                self.description = description
                assemblers = (0..<3).map { ShardAssembler(stream: UInt8($0)) }
                let names = description.codecs.prefix(2).map { WiVRn.Codec(rawValue: $0).map { "\($0)" } ?? "codec \($0)" }
                onLog?("video: \(description.width) x \(description.height) per eye, \(names.joined(separator: " and ")), "
                       + "\(description.frameRate) frames/s for a \(description.refreshRate) Hz display")
            }
        case .audioDescription(let speaker, let microphone):
            onLog?("audio: " + (speaker.map { "\($0.channels) channels at \($0.rate) Hz" } ?? "none")
                   + (microphone == nil ? "" : "; the host wants a microphone, which is not sent yet"))
        case .haptics(let device, let nanoseconds, let frequency, let amplitude):
            // Zero amplitude indicates a stop command; ignore it since our haptic pulses are short and self-terminating.
            guard let side = WiVRn.Device.haptics[device], amplitude > 0 else { break }
            hapticPulses += 1
            onHaptic?(HapticPulse(side: side, frequency: frequency,
                                  seconds: max(Float(nanoseconds) / 1e9, HapticPulse.shortest), amplitude: min(1, amplitude)))
        case .serverMessage(let kind, let text):
            onLog?("host: " + text)
            if kind == WiVRn.serverMessageError { hostComplaint = text }
        case .refreshRateChange(let hz):
            onLog?("host asked for \(hz) Hz")
            onRefreshRateRequested?(hz)
        case .featureControl(let feature, let on):
            if feature == WiVRn.featureMicrophone, on != microphoneWanted {
                microphoneWanted = on
                onLog?(on ? "the host is listening to the microphone" : "the host stopped listening to the microphone")
            }
        case .cryptoHandshake, .pinCheck2, .pinCheck4, .handshake, .other:
            break
        }
    }

    /// Processes a reassembled video stream frame and forwards it to the decoder.
    private func finished(_ whole: ShardAssembler.Whole, picture: Int) {
        guard let description else { return }
        framesReceived[picture] += 1
        var progress = whole.feedback
        if awaitingKeyframe[picture] {
            if AnnexB.keyframeCodec(UnsafeBufferPointer(whole.data.bytes)) == nil {
                // Report dependent non-keyframe packets as undecoded while waiting for a keyframe.
                try? sendControl(progress.packet)
                return
            }
            awaitingKeyframe[picture] = false
        }
        progress.sentToDecoder = WiVRnSession.now()
        lock.lock()
        feedback[picture][Int(whole.frame % UInt64(WiVRnSession.framesRemembered))] = progress
        lock.unlock()
        try? sendControl(progress.packet)
        let layout = WiVRnSession.layout(views: whole.views, foveation: whole.foveation,
                                         encoded: (description.width, description.height), alpha: whole.alpha)
        if whole.alpha != alphaNoted {
            alphaNoted = whole.alpha
            onLog?(whole.alpha ? "video: the picture now has transparent parts" : "video: the picture is opaque again")
        }
        if whole.foveation != foveationNoted {
            foveationNoted = whole.foveation
            let bands = whole.foveation.map { "\($0.across.count) across and \($0.down.count) down" }
            onLog?("video: each eye's picture is \(layout.eyePixels.width) x \(layout.eyePixels.height) squeezed into "
                   + "\(description.width) x \(description.height), in bands: \(bands.joined(separator: "; "))")
        }
        onFrame?(EncodedFrame(frameID: UInt16(truncatingIfNeeded: whole.frame), picture: picture, data: whole.data, layout: layout))
    }

    /// Builds a `FrameLayout` from per-eye foveation bands. Crossing the horizontal
    /// and vertical bands produces a grid of constant-scale rectangular tiles.
    /// Because perspective projection is linear in view-angle tangents, each band's
    /// fraction of the unscaled source image maps linearly to its share of the frustum.
    ///
    /// When `alpha` is true, stream 2 carries a foveated opacity mask with the left
    /// eye packed in the left half and the right eye packed in the right half.
    static func layout(views: [WiVRnView], foveation: [WiVRnFoveation], encoded: (width: Int, height: Int),
                       alpha: Bool = false) -> FrameLayout {
        var pixels = (width: 0, height: 0)
        let layoutViews = views.indices.map { eye -> FrameLayout.View in
            let whole = views[eye].frustum, squeeze = foveation[eye]
            let across = WiVRnFoveation.bands(squeeze.across, encodedSize: encoded.width)
            let down = WiVRnFoveation.bands(squeeze.down, encodedSize: encoded.height)
            pixels = (max(pixels.width, squeeze.across.isEmpty ? encoded.width : WiVRnFoveation.sourceSize(squeeze.across)),
                      max(pixels.height, squeeze.down.isEmpty ? encoded.height : WiVRnFoveation.sourceSize(squeeze.down)))
            var tiles: [FrameLayout.Tile] = []
            for row in down {
                for column in across {
                    // Image V=0 corresponds to the top edge of the frustum.
                    let frustum = Frustum(left: whole.left + (whole.right - whole.left) * column.source.lowerBound,
                                          right: whole.left + (whole.right - whole.left) * column.source.upperBound,
                                          down: whole.up - (whole.up - whole.down) * row.source.upperBound,
                                          up: whole.up - (whole.up - whole.down) * row.source.lowerBound)
                    let half = Float(eye) / 2
                    let transparency = !alpha ? nil : AlphaSource(
                        picture: WiVRnSession.alphaPicture,
                        left: half + column.encoded.lowerBound / 2, top: row.encoded.lowerBound,
                        right: half + column.encoded.upperBound / 2, bottom: row.encoded.upperBound)
                    tiles.append(FrameLayout.Tile(frustum: frustum, picture: eye,
                                                  left: column.encoded.lowerBound, top: row.encoded.lowerBound,
                                                  right: column.encoded.upperBound, bottom: row.encoded.upperBound,
                                                  alpha: transparency))
                }
            }
            return FrameLayout.View(eye: views[eye].pose, tiles: tiles)
        }
        return FrameLayout(views: layoutViews, pictures: views.count + (alpha ? 1 : 0), eyePixels: pixels)
    }

    // MARK: Decoder and display callbacks

    public func frameDecoded(_ frameID: UInt16, picture: Int) {
        report(frameID, pictures: [picture]) { $0.decoded = WiVRnSession.now() }
    }

    /// Reports a frame with `sentToDecoder = 0` so the host knows decoding failed
    /// and emits a new keyframe.
    public func frameNotDecoded(_ frameID: UInt16, picture: Int) {
        report(frameID, pictures: [picture]) { $0.sentToDecoder = 0 }
    }

    public func frameShown(_ frameID: UInt16, at uptimeNanoseconds: UInt64) {
        report(frameID, pictures: [0, 1, 2]) {
            $0.drawn = WiVRnSession.now()
            $0.displayed = Int64(bitPattern: uptimeNanoseconds)
            $0.timesDisplayed &+= 1
        }
    }

    public func displayRefreshes(at uptimeNanoseconds: UInt64, period: Double) {
        lock.lock()
        let change = rate.follow(period)
        lock.unlock()
        guard let change else { return }
        onLog?(change.note)
        try? sendControl(WiVRnPacket.refreshRateChanged(from: change.from, to: change.to))
    }

    /// Updates a frame's timing record and sends an updated feedback packet to the
    /// host (thread-safe for decoder and display callbacks).
    private func report(_ frameID: UInt16, pictures: [Int], _ change: (inout WiVRnFeedback) -> Void) {
        for picture in pictures where feedback.indices.contains(picture) {
            lock.lock()
            let slot = Int(frameID) % WiVRnSession.framesRemembered
            var progress = feedback[picture][slot]
            if progress != nil, UInt16(truncatingIfNeeded: progress!.frame) == frameID {
                change(&progress!)
                feedback[picture][slot] = progress
            } else {
                progress = nil
            }
            lock.unlock()
            if let progress { try? sendControl(progress.packet) }
        }
    }
}

/// Reassembles UDP shards into complete frames for a single video stream.
///
/// WiVRn uses neither retransmission nor forward error correction. An incomplete
/// frame is abandoned as soon as the next frame completes or a shard arrives from
/// two frames ahead; reporting the abandoned frame prompts the host to send a keyframe.
struct ShardAssembler {
    struct Whole {
        var frame: UInt64
        var data: FrameBuffer
        var views: [WiVRnView]
        var foveation: [WiVRnFoveation]
        /// Whether this frame includes an accompanying alpha stream frame.
        var alpha: Bool
        var feedback: WiVRnFeedback
    }

    private struct Partial {
        var shards: [ByteSlice?] = []
        var views: (displayTime: Int64, views: [WiVRnView], foveation: [WiVRnFoveation], alpha: Bool)?
        var timing: [Int64]?
        var feedback: WiVRnFeedback

        var whole: Bool { timing != nil && views != nil && !shards.contains { $0 == nil } }
    }

    let stream: UInt8
    /// In-flight frames indexed by frame number (at most two consecutive frames at any time).
    private var partial: [UInt64: Partial] = [:]
    /// Minimum accepted frame number; shards for older completed or abandoned frames are ignored.
    private var oldest: UInt64 = 0

    init(stream: UInt8) { self.stream = stream }

    mutating func accept(_ shard: WiVRnShard, now: Int64) -> (complete: Whole?, abandoned: [WiVRnFeedback]) {
        guard shard.frame >= oldest else { return (nil, []) }
        var abandoned: [WiVRnFeedback] = []
        // Abandon any in-flight frame that is at least two frames behind the incoming shard.
        for number in partial.keys.sorted() where number + 2 <= shard.frame {
            abandoned.append(partial.removeValue(forKey: number)!.feedback)
        }
        oldest = max(oldest, shard.frame > 0 ? shard.frame - 1 : 0)

        var frame = partial[shard.frame] ?? Partial(feedback: WiVRnFeedback(frame: shard.frame, stream: stream, firstPacket: now))
        let index = Int(shard.index)
        if index >= frame.shards.count { frame.shards.append(contentsOf: [ByteSlice?](repeating: nil, count: index + 1 - frame.shards.count)) }
        frame.shards[index] = shard.payload
        if let views = shard.views { frame.views = views }
        if let timing = shard.timing {
            frame.timing = timing
            frame.feedback.hostTiming = timing
        }
        guard frame.whole, let views = frame.views else {
            partial[shard.frame] = frame
            return (nil, abandoned)
        }
        // Once a frame completes, abandon any older incomplete frames.
        for number in partial.keys.sorted() where number < shard.frame {
            abandoned.append(partial.removeValue(forKey: number)!.feedback)
        }
        partial[shard.frame] = nil
        oldest = shard.frame + 1
        frame.feedback.lastPacket = now

        let size = frame.shards.reduce(0) { $0 + ($1?.count ?? 0) }
        let data = FrameBuffer(count: size, capacity: size)
        var offset = 0
        for part in frame.shards {
            guard let part else { continue }
            part.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { (data.bytes.baseAddress! + offset).update(from: base, count: source.count) }
            }
            offset += part.count
        }
        return (Whole(frame: shard.frame, data: data, views: views.views, foveation: views.foveation, alpha: views.alpha,
                      feedback: frame.feedback),
                abandoned)
    }
}

/// Persists the per-eye frusta last reported to each WiVRn host across runs.
///
/// Dynamic eye-relief or IPD tracking causes slight variations in measured frusta
/// between sessions, and a WiVRn host with a running session rejects reconnects
/// unless the reported frusta match the initial connection bit-for-bit. Reusing
/// the previously reported frusta when current measurements remain within
/// `tolerance` allows seamless reconnection.
enum WiVRnDisplayMemory {
    /// Maximum per-edge tangent delta allowed before updating the stored frusta.
    static let tolerance: Float = 0.05
    static var file: URL { DataDirectory.url.appendingPathComponent("wivrn-displays.json") }

    static func settled(_ measured: [Frustum], host: String, file: URL = WiVRnDisplayMemory.file) -> [Frustum] {
        func numbers(_ frusta: [Frustum]) -> [Float] { frusta.flatMap { [$0.left, $0.right, $0.down, $0.up] } }
        var known = (try? JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: file))) ?? [:]
        let now = numbers(measured)
        if let before = known[host], before.count == now.count, zip(before, now).allSatisfy({ abs($0 - $1) <= tolerance }) {
            return stride(from: 0, to: before.count, by: 4).map {
                Frustum(left: before[$0], right: before[$0 + 1], down: before[$0 + 2], up: before[$0 + 3])
            }
        }
        known[host] = now
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(known).write(to: file, options: .atomic)
        return measured
    }
}
