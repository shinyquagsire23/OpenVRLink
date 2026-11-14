// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The core streaming session,
/// (docs/svl-transport/, docs/svl-tracking-input/poses.md).
///
/// Runs on its own thread. `onFrame` is called on that thread with each
/// complete HEVC access unit and the host's metadata for it.
/// Fixed values in the pose message (docs/svl-tracking-input/poses.md).
enum PoseMessage {
    /// The first byte: the protocol's version. The host drops every pose
    /// message that says anything else, logging "svl protocol version
    /// mismatch. Server expects 10" (probed 2026-11-13).
    static let protocolVersion: UInt8 = 0x0A
    /// The third byte, always this; what it means is not known. The host
    /// streamed just the same with zero here (probed 2026-11-13).
    static let unknownConstant: UInt8 = 0x20
    /// The holdoff byte: non-zero asks the host to hold off. Never asked for here.
    static let noHoldoff: UInt8 = 0
    /// The headset's own input block: the client's minor version, eight
    /// zero bytes, flags, a closing byte.
    ///
    /// The host logs the first as "Peer Minor Version Number" and behaves
    /// by it. 14 is what Steam Link 2.0.25 sends, and what this client
    /// does is what that one was seen to do (docs/svl-transport/): the
    /// capabilities value, the longer frame report and eye message, and
    /// the ping. A host given 14 without the capabilities value never
    /// starts the headset (probed 2026-11-13).
    static let minorVersion: UInt32 = 14
    static let hmdInputReserved = 8
    static let hmdInputFlagNothingInHands: UInt8 = 0x08
    static let hmdInputTrailer: UInt8 = 0xFF
}

/// PackedPose_t: one device's pose within the pose message.
enum PackedPose {
    static let size = 88
    /// Where the tracking result (16 bits) sits; the state byte follows it.
    static let trackingResultOffset = 0x34
    /// Tracking results. Inferred: OpenVR's ETrackingResult.
    static let trackingUninitialized: UInt16 = 1
    static let trackingRunningOK: UInt16 = 200
    /// States: 0 no device (what a zeroed pose says), 1 located but not fully valid, 2 valid.
    static let stateValid: UInt8 = 2
    /// No offset: the device is where the pose is. Position, then orientation w first.
    static let identityOffset: [Float] = [0, 0, 0, 1, 0, 0, 0]
}

public final class StreamSession: StreamingSession {
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Never called yet: a Steam host that goes away is only noticed as silence.
    public var onEnded: ((String) -> Void)?

    public let profile: DeviceProfile
    private let socket: UDPSocket
    private var link: SVLLink
    private let values = ValueTransport()
    private let assembler = FrameAssembler(now: 0)
    private let audioReceiver = AudioReceiver()
    /// Decoded audio waiting to be played; an audio output pulls from it.
    public var audio: PlaybackBuffer { audioReceiver.buffer }
    /// Microphone audio for the host; a platform's capture feeds it.
    public let microphone = MicrophoneUplink()
    public var microphoneSink: any MicrophoneSink { microphone }
    private var clock = ClockOffset()
    private var statisticsSent = 0
    private let started = Uptime.nanoseconds
    private var sequence: UInt16 = 0
    private var frameCounter: Int32 = 0
    private var frameDisplayTime: Int32 = 0
    private var framePeriod: Double
    private var hostInstance: Bytes?
    /// Nil until the host has said; it says again to a client that returns.
    private var applicationRunning: Bool?
    /// Whether the host says an application has the scene (a game, as
    /// against SteamVR's own grid). It does not say which.
    public var sceneApplicationRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return applicationRunning ?? false
    }
    /// The last frame to arrive whole: when, on the session clock and on
    /// the wall clock (microseconds since 1970).
    private var lastFrame: (id: UInt16, time: Int32, wallClock: UInt64) = (0, 0, 0)
    /// When each recent frame was handed on for decoding, by frame id modulo this many.
    private var handedToDecoder = [Int32](repeating: 0, count: StreamSession.framesRemembered)
    static let framesRemembered = 64
    /// Each side tells the other, this often, where it can be reached. Seconds.
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

    /// The reference client samples the head four times per displayed frame.
    static let posesPerFrame = 4
    static let poseBlockSize = 0x168
    static let valueTransportBudget = 0x174
    /// The sequence number of the datagram that ends the session.
    static let goodbyeSequence: UInt16 = 0xFFFF
    /// The focus event value: its first byte says what happened, the rest is zero.
    /// The host's names for the two the Steam Link client sends are
    /// EVTYPE_LDASH_PAUSE ("Remote was paused") and EVTYPE_LDASH_CONTINUE.
    static let focusEventSize = 52
    static let focusEventPaused: UInt8 = 4
    static let focusEventContinued: UInt8 = 5
    /// A wrist not heard of for this long starts afresh, with no velocity. Microseconds.
    static let wristForgottenAfter: Int32 = 200_000
    /// Wrist velocities are not measured over less than this. Microseconds.
    static let wristShortestStep: Int32 = 1000

    /// `interface`: the network interface the stream must use, or nil for
    /// the system's choice.
    public init?(_ args: SessionArgs, profile: DeviceProfile, interface: String? = nil) {
        // The Steam Link client sends from the port the host listens on,
        // and a host given version 14 sends to that port at this address
        // whatever port it hears from; with nothing there, the refusal
        // that comes back makes the host remake its socket every two
        // seconds (probed 2026-11-13). Any port will do if that one is taken.
        guard let link = SVLLink(token: args.token),
              let socket = UDPSocket(interface: interface, localPort: args.port) ?? UDPSocket(interface: interface),
              socket.connect(host: args.host, port: args.port)
        else { return nil }
        self.link = link
        self.socket = socket
        self.profile = profile
        framePeriod = 1 / Double(profile.refreshHz)
        audioReceiver.onLog = { [weak self] in self?.onLog?($0) }
        for (id, value) in profile.startupValues() { values.publish(id, value) }
        // "The headset has focus": the host logs "Remote was continued".
        values.publish(DeviceProfile.ValueID.focusEvent, [StreamSession.focusEventContinued] + Bytes(repeating: 0, count: StreamSession.focusEventSize - 1), force: true)
    }

    /// Called on the session thread when the host wants a refresh rate,
    /// in Hz: one of `DeviceProfile.otherRefreshRates` or `refreshHz`.
    /// The platform asks its display for it, if it can. Nothing depends on
    /// the display obliging: the host is always told the rate the display
    /// really runs at, and streams at that.
    public var onRefreshRateRequested: ((Float) -> Void)?
    private var rateHinted: Float?

    /// Asked for the head pose each time one is sent (four times a frame, on
    /// the session thread). When nil, the last pose given to `setHead` is sent.
    public var headProvider: (() -> TrackedPose?)?

    /// Asked for both hands each time a pose is sent: left then right, nil
    /// for a hand that is neither holding a tracked controller nor tracked itself.
    public var handsProvider: (() -> [HandInput?])?
    /// What the host has been told each hand is: a controller (true) or a bare hand.
    private var handIsController: [Side: Bool] = [:]

    /// Asked about once a second for the headset's battery. Nil, or no
    /// provider, tells the host "full, not charging".
    public var headsetPowerProvider: (() -> PowerState?)?
    /// The battery states the host was last told, by value id.
    private var powerPublished: [UInt8: PowerState] = [:]

    /// Tell the host a device's battery state if it has changed by a percent or more.
    private func publishPower(_ power: PowerState?, as id: UInt8) {
        guard let power = power?.rounded, powerPublished[id] != power else { return }
        powerPublished[id] = power
        values.publish(id, DeviceProfile.powerProps(power, reportsBattery: true), force: true)
    }
    private var gestures: [HandGestures?] = [nil, nil]
    /// Each wrist as it was last sent, for measuring how it moves.
    private var wrists: [(pose: TrackedPose, time: Int32)?] = [nil, nil]
    private var hostVersion: UInt32 = 0
    static let knownFECMode: UInt8 = 0x20
    private var warnedAboutFEC = false
    /// Smoothing for each hand's pointing ray.
    private var aimFilters = [AimFilter(), AimFilter()]
    private var hapticPulses = 0
    /// The longest wait between two pose datagrams since the last report, and when the last one went.
    private var longestPoseGap: Double = 0
    private var lastPoseSent: Date?
    /// The host treats a tracked hand as a controller from this protocol version on.
    static let firstVersionWithHands: UInt32 = 7

    /// Asked with every pose where the eyes look: the point they are fixed
    /// on, in meters in the head's own frame (x right, y up, z back). Nil,
    /// or no provider, tells the host there is no eye tracking.
    public var gazeProvider: (() -> Vec3?)?
    /// Asked with every pose for face tracking, on platforms that have it.
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

    /// For the log: how the host wants this session's datagrams.
    public var transportName: String { link.name }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "svl-session"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the loop. `leaving` says the wearer is done: the host is told
    /// goodbye, and quits SteamVR and whatever runs in it at once. It is
    /// told the same when it has said that nothing runs in SteamVR, there
    /// being nothing to lose. Otherwise the host only sees the stream go
    /// quiet, keeps the application up for a while, and takes this client
    /// back if it returns (docs/svl-transport/connection-lifecycle.md).
    public func stop(leaving: Bool = false) {
        lock.lock()
        running = false
        sayGoodbye = leaving
        lock.unlock()
    }

    /// The session clock the host is told about: microseconds since the
    /// session began, wrapping at 32 bits. Safe to call from any thread.
    public func now() -> Int32 {
        Int32(truncatingIfNeeded: (Uptime.nanoseconds - started) / 1000)
    }

    // MARK: What the display side reports

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

    /// The display's rhythm: when its next refresh will be seen, and how far
    /// apart refreshes are. The host paces its frames against this.
    public func displayWillRefresh(at displayTime: Int32, period: Double) {
        lock.lock()
        nextRefresh = displayTime
        refreshPeriod = period
        lock.unlock()
    }

    // MARK: The same, as any session is told (`StreamingSession`)

    /// A time on the system's clock as this session's.
    private func sessionTime(_ uptimeNanoseconds: UInt64) -> Int32 {
        Int32(truncatingIfNeeded: (Int64(bitPattern: uptimeNanoseconds) - Int64(bitPattern: started)) / 1000)
    }

    public func frameDecoded(_ frameID: UInt16, picture: Int) { frameDecoded(frameID) }

    /// Nothing is asked of the host here yet: a Steam host sends new
    /// parameter sets often, and a decoder starts afresh at each.
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

    /// The wrist as the host wants it: the joint's pose, with velocities
    /// along the world's axes, smoothed the way vrlink does.
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
        // `withVelocities` measures turning about the wrist's own axes; the
        // host wants a hand's about the world's.
        let spin = tracked.angularVelocity
        tracked.angularVelocity = pose.right * spin.x + pose.up * spin.y + pose.forward * -spin.z
        tracked.linearVelocity = last.pose.linearVelocity * 0.8 + tracked.linearVelocity * 0.2
        tracked.angularVelocity = last.pose.angularVelocity * 0.8 + tracked.angularVelocity * 0.2
        wrists[side.rawValue] = (tracked, time)
        return tracked
    }

    /// The pose message, and behind it one hand message per tracked bare hand.
    private func poseMessages(subIndex: Int, head: TrackedPose, hands: [HandInput?]) -> (pose: SVLElement, hands: [SVLElement]) {
        let time = now()
        var inputBlocks = Bytes(), poses = Bytes(), handMessages: [SVLElement] = []
        for side in Side.allCases {
            switch hands[side.rawValue] {
            case .controller(let controller):
                inputBlocks.append(contentsOf: controller.inputBlock())
                poses.append(contentsOf: packedPose(controller.gripForHost, offset: ControllerState.gripOffset(side, senseModel: profile.senseControllerModels)))
            case .hand(let hand):
                let now = HandGestures(hand, previous: gestures[side.rawValue])
                if now.description != (gestures[side.rawValue]?.description ?? "nothing") {
                    onLog?("\(side) hand: \(now.description)")
                }
                gestures[side.rawValue] = now
                let offset = TrackedHand.wristOffset(side)
                inputBlocks.append(contentsOf: now.inputBlock())
                poses.append(contentsOf: packedPose(trackedWrist(hand, side),
                                                    offset: [offset.position.x, offset.position.y, offset.position.z] + offset.orientation))
                let aim: Pose
                if case .pinching(let ray, _) = hand.systemPinch {
                    // Where the eyes looked: used as it is, and the smoothed
                    // hand ray starts afresh when the pinch ends.
                    aim = ray
                    aimFilters[side.rawValue] = AimFilter()
                } else {
                    aim = aimFilters[side.rawValue].smooth(hand.aim(side, head: head.pose), seconds: Double(time) / 1_000_000)
                }
                handMessages.append(hand.message(side, gestures: now, aim: aim))
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

    /// Three of the string->double statistics the host reads
    /// (docs/svl-values/svlroot-key-value-channel.md), three to a message
    /// as the reference client sends them: the round trip to the host and
    /// back, the recent worst of each packet's delay (the host's graph
    /// draws its network line from these), and in turn one of "no loss".
    private func statistics() -> SVLElement {
        var out = Bytes()
        let steady = [("cRXpass", 100.0), ("cRXerr", 0.0), ("cFramePhase", 0.3)]
        statisticsSent &+= 1
        for (key, value) in [("cPingMS", Double(clock.roundTrip) / 1000), ("cPingAMS", Double(clock.peakDelay) / 1000),
                             steady[statisticsSent % steady.count]] {
            out.append(text: key, fieldSize: 20)
            out.append(double: value)
            out.append(integer: now())
        }
        return SVLElement(.statistics, value: out)
    }

    /// Where the host can reach this client
    /// (docs/svl-transport/host-address-list.md): a leading 1, then one
    /// record for the address the session runs on. A record is the
    /// family (0 is IPv4), the length of what follows, the port in
    /// network order, the prefix length, and sixteen bytes that begin
    /// with the address. A host given version 14 and no such list
    /// remakes its socket every two seconds (probed 2026-11-13).
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

    /// Tell the host the refresh rate the display is set to, as the
    /// length of a frame in microseconds.
    /// `again`: send it even if it is what the host was last told. A host
    /// that wants another rate asks several times a second, and need not
    /// be answered each time.
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
                // The host is told what the display runs at, not what it
                // asked for: it streams at the rate it is told, and goes on
                // asking for the one it wants. The platform is asked for
                // that rate; if the display follows, the host hears of it.
                if hz != rateHinted {
                    rateHinted = hz
                    onLog?("host asked for \(hz) Hz")
                    onRefreshRateRequested?(hz)
                }
                publishFrameTime(Float((1 / framePeriod).rounded()), again: false)
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

    /// Send what the assembler wants resent and hand finished frames on.
    private func drainAssembler() {
        let requests = assembler.takeRequests()
        if !requests.isEmpty { send(requests) }
        for frame in assembler.takeFrames() {
            let time = now()
            lastFrame = (frame.frameID, time, UInt64(Date().timeIntervalSince1970 * 1_000_000))
            handedToDecoder[Int(frame.frameID) % StreamSession.framesRemembered] = time
            framesReceived += 1
            onFrame?(EncodedFrame(frameID: frame.frameID, data: frame.data, layout: frame.metadata.layout(profile: profile)))
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

    /// For studying the protocol: with `OPENVRLINK_LOG_HOST=1` in the
    /// environment, every value the host publishes and every message this
    /// client does not act on is written to the log when its bytes change
    /// (and at most once a second each), with what else was going on left
    /// to the reader. docs/svl-values/vte-id-table.md is built from this.
    private func noteForStudy(_ name: String, _ data: Bytes, version: UInt8?) {
        guard StreamSession.studyingHost else { return }
        let time = Date()
        var entry = studied[name] ?? (data: [], noted: .distantPast, skipped: 0)
        guard entry.data != data else { return }
        guard time.timeIntervalSince(entry.noted) >= 1 else {
            entry.skipped += 1
            entry.data = []          // so that the value it settles on is still written
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
                    if let period, abs(period - framePeriod) > framePeriod * 0.02 {
                        framePeriod = period
                        let hz = Float((1 / period).rounded())
                        onLog?("display now refreshes at \(hz) Hz")
                        // Tell the host what the display runs at now; it
                        // switches the stream to match. What is offered stays
                        // as it was, so the host can still choose (and
                        // SteamVR's settings still list the rates); a rate
                        // with no other on offer is itself what is offered.
                        if profile.otherRefreshRates.isEmpty {
                            values.publish(DeviceProfile.ValueID.availableRates, profile.availableRates([hz]), force: true)
                        }
                        publishFrameTime(hz)
                    }
                    // The refresh this frame is aimed at: the first one still ahead of us.
                    let step = Int32(framePeriod * 1_000_000)
                    var target = refresh ?? now() &+ step
                    while target &- now() <= 0 { target &+= step }
                    frameDisplayTime = target
                }
                let head = headProvider?() ?? lastHead
                var hands = handsProvider?() ?? []
                hands += [HandInput?](repeating: nil, count: max(0, 2 - hands.count))
                for side in Side.allCases {
                    var isController: Bool?
                    switch hands[side.rawValue] {
                    case .controller: isController = true
                    case .hand:
                        // An older host, or one whose version is not known yet, gets no hand.
                        if hostVersion >= StreamSession.firstVersionWithHands { isController = false } else { hands[side.rawValue] = nil }
                    case nil: break
                    }
                    if let isController, handIsController[side] != isController {
                        // This hand is something new: tell the host what.
                        handIsController[side] = isController
                        powerPublished[DeviceProfile.ValueID.powerController(side)] = nil
                        onLog?("\(side) hand is now a \(isController ? "controller" : "tracked hand")")
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

    /// The host's own estimate the other way, (peer - local) as it last
    /// reported it. Each estimate is the clock difference plus one
    /// direction's delay, so the two add up to the round trip.
    private var peerOffset: Int32 = 0
    /// Microseconds to the host and back.
    var roundTrip: Int32 { confident ? offset &+ peerOffset : 0 }
    /// How late the worst recent packet was against the best case, plus
    /// half the round trip, in microseconds; it sinks by `peakDecay` with
    /// every packet and is never more than `peakLimit`.
    private(set) var peakDelay: Int32 = 0
    /// The host sets the decay in a value of its own (0x1c); 1000 is what
    /// it has sent in every capture.
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
