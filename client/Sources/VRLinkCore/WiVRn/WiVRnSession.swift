// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum WiVRnError: Error, CustomStringConvertible {
    case unreachable(String)
    case noReply
    case closed
    case wrongVersion
    case encrypted
    case pairingDisabled
    case unexpected(String)

    public var description: String {
        switch self {
        case .unreachable(let host): return "nothing answered at \(host)"
        case .noReply: return "the host stopped answering"
        case .closed: return "the host closed the connection"
        case .wrongVersion: return "the host runs another release of WiVRn than this client knows (\(WiVRn.release))"
        case .encrypted: return "the host wants an encrypted stream, which this client does not have yet; start it with --no-encrypt"
        case .pairingDisabled: return "the host is not accepting new headsets"
        case .unexpected(let what): return "the host sent \(what) where something else was due"
        }
    }
}

/// A stream from a WiVRn host (docs/wivrn/protocol.md).
///
/// Two sockets to the same port: a TCP one for what must arrive, and a UDP
/// one for what is only worth having in time (video, audio, tracking).
/// Every time on the wire is the headset's own clock in nanoseconds, here
/// the system's uptime; the host works out the difference for itself from
/// the answers to its queries.
public final class WiVRnSession: StreamingSession {
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onLog: ((String) -> Void)?
    public var headProvider: (() -> TrackedPose?)?
    /// Not sent yet: hands and controllers, eyes, face, the battery; and
    /// the host's haptics are counted, not played.
    public var handsProvider: (() -> [HandInput?])?
    public var gazeProvider: (() -> Vec3?)?
    public var faceProvider: (() -> FaceExpressions?)?
    public var headsetPowerProvider: (() -> PowerState?)?
    public var onHaptic: ((HapticPulse) -> Void)?
    public var onRefreshRateRequested: ((Float) -> Void)?
    public let audio = PlaybackBuffer()
    /// A WiVRn host has no scene of its own: any picture is an application's.
    public var sceneApplicationRunning: Bool { true }

    public let profile: DeviceProfile
    private let control: TCPSocket
    private let stream: UDPSocket
    private var controlReceived = Bytes()

    private let lock = NSLock()
    private var running = true
    private var head = HeadPose(position: Vec3(0, 1.6, 0)).tracked
    private var refreshPeriod: Double

    /// What the host asks of the encoder, bits per second. WiVRn's own default.
    static let bitsPerSecond: UInt32 = 50_000_000
    /// One eye's rendered picture when the platform does not say, in pixels.
    static let defaultEyePixels = (width: 2048, height: 2048)
    /// How many pixels a second the host's encoder is asked for, both eyes
    /// together. The encoded picture is made as large as this allows at
    /// the display's rate, and never larger than the rendered one; the host
    /// makes up the difference by squeezing the edges. An encoder asked
    /// for more than it can do does not complain, it delivers fewer frames:
    /// NVENC on an NVIDIA GB10 gave 650 to 690 million whatever the size
    /// (docs/wivrn/protocol.md), and this leaves it some room.
    static let encodedPixelsPerSecond = 600e6
    /// Encoders want sides that are multiples of this.
    static let pixelAlignment = 32
    /// Frames of each picture whose progress is remembered for the host.
    static let framesRemembered = 64
    /// The largest packet on the control socket; the host refuses larger ones itself.
    static let largestControlPacket = 16 << 20

    private var description: WiVRnVideoDescription?
    private var assemblers = [ShardAssembler(stream: 0), ShardAssembler(stream: 1)]
    /// Progress of recent frames, by picture and by frame number modulo `framesRemembered`.
    private var feedback = [[WiVRnFeedback?]](repeating: [WiVRnFeedback?](repeating: nil, count: WiVRnSession.framesRemembered), count: 2)
    /// Until the host says otherwise: the head, as it is when asked.
    private var pattern: [(device: UInt8, prediction: Int64)] = [(WiVRn.Device.head, 0)]
    private var foveationNoted: [WiVRnFoveation] = []
    private var framesReceived = [0, 0], framesLost = [0, 0], hapticPulses = 0

    private init(control: TCPSocket, stream: UDPSocket, profile: DeviceProfile) {
        self.control = control
        self.stream = stream
        self.profile = profile
        refreshPeriod = 1 / Double(profile.refreshHz)
    }

    private static func now() -> Int64 { Int64(bitPattern: Uptime.nanoseconds) }

    // MARK: Connecting

    /// Connects, and tells the host about the headset. Takes up to a few
    /// seconds; the stream begins once `start` is called.
    /// `name` is what the host lists this headset as.
    public static func connect(host: String, port: UInt16 = WiVRn.defaultPort, profile: DeviceProfile,
                               name: String) throws -> WiVRnSession {
        guard let address = TCPSocket.resolve(host), let control = TCPSocket(address: address, port: port),
              let stream = UDPSocket()
        else { throw WiVRnError.unreachable(host) }
        let session = WiVRnSession(control: control, stream: stream, profile: profile)

        // With encryption off the host wants a key all the same, and does nothing with it.
        let key = (0..<32).map { _ in UInt8.random(in: 0...255) }
        try session.sendControl(WiVRnPacket.cryptoHandshake(publicKey: WiVRnPacket.publicKeyPEM(key), name: name))
        guard case .cryptoHandshake(_, let state) = try session.awaitControl() else {
            throw WiVRnError.unexpected("no answer to the first packet")
        }
        switch WiVRn.CryptoState(rawValue: state) {
        case .encryptionDisabled: break
        case .pinNeeded, .alreadyPaired: throw WiVRnError.encrypted
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
        // The host learns where to send the stream from a packet on it,
        // which may be lost: it is sent until the host says it has it.
        var acknowledged = false
        let deadline = Date().addingTimeInterval(10)
        while !acknowledged {
            guard Date() < deadline else { throw WiVRnError.noReply }
            stream.send(WiVRnPacket.handshake)
            if let packet = try session.awaitControl(timeout: 0.1, required: false) {
                guard case .handshake = packet else { throw WiVRnError.unexpected("something other than its handshake") }
                acknowledged = true
            }
        }
        try session.sendControl(session.headsetInfo().packet)
        try session.sendControl(WiVRnPacket.sessionState(WiVRn.sessionStateFocused))
        return session
    }

    private func headsetInfo() -> WiVRnHeadsetInfo {
        let render = profile.eyePixels ?? WiVRnSession.defaultEyePixels
        let perEye = WiVRnSession.encodedPixelsPerSecond / Double(profile.refreshHz) / 2
        let scale = min(1, (perEye / Double(render.width * render.height)).squareRoot())
        func encoded(_ side: Int) -> Int {
            max(WiVRnSession.pixelAlignment, Int(Double(side) * scale) / WiVRnSession.pixelAlignment * WiVRnSession.pixelAlignment)
        }
        return WiVRnHeadsetInfo(renderPixels: render, streamPixels: (encoded(render.width), encoded(render.height)),
                                refreshRates: [profile.refreshHz] + profile.otherRefreshRates,
                                bitsPerSecond: WiVRnSession.bitsPerSecond, frusta: profile.eyeFrusta,
                                codecs: [.h265, .h264], systemName: profile.systemName)
    }

    // MARK: The control socket

    /// A packet on the control socket goes with its length in front.
    private func sendControl(_ packet: Bytes) throws {
        var framed = Bytes()
        framed.append(integer: UInt32(packet.count))
        framed.append(contentsOf: packet)
        guard control.send(framed) else { throw WiVRnError.closed }
    }

    /// The next whole packet already received on the control socket.
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
        controlReceived.append(contentsOf: bytes)
    }

    /// Wait for one packet on the control socket.
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

    // MARK: Running

    public func setHead(_ pose: TrackedPose) {
        lock.lock()
        head = pose
        lock.unlock()
    }

    public func start() {
        let thread = Thread { [self] in
            do { try run() } catch { onLog?("the stream ended: \(error)") }
            // The host takes the connection closing as the headset leaving,
            // and only then offers itself to be found again.
            control.shutDown()
        }
        thread.name = "wivrn-session"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The host is told nothing: it notices the connection close.
    public func stop(leaving: Bool) {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func run() throws {
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
                // Take what has arrived, not only one: a frame comes as a burst.
                while let datagram = stream.receive(timeout: 0) {
                    if let packet = WiVRnToHeadset(datagram) { try handle(packet) }
                }
            }
            if readable[1] {
                try readControl()
                while let packet = try takeControlPacket() {
                    if let parsed = WiVRnToHeadset(packet) { try handle(parsed) }
                }
            }

            let time = WiVRnSession.now()
            while let next = sends.first, next.at <= time {
                sends.removeFirst()
                sendTracking(at: time, prediction: next.prediction)
            }
            if sends.isEmpty {
                // The next frame's; after a stall, start again from now.
                frameStart += Int64(period * 1e9)
                if frameStart < time - Int64(period * 1e9) { frameStart = time }
                sends = trackingTimes(from: frameStart)
            }
            if Date() >= nextReport {
                onLog?("left eye \(framesReceived[0]) frames/s, right eye \(framesReceived[1]); so far \(framesLost[0]) and \(framesLost[1]) lost"
                       + "; audio \(audio.underruns) underruns, \(audio.overflows) overflows"
                       + (hapticPulses > 0 ? "; \(hapticPulses) haptic pulses asked for" : ""))
                framesReceived = [0, 0]
                hapticPulses = 0
                nextReport = nextReport.addingTimeInterval(1)
            }
        }
    }

    // MARK: Tracking

    /// When within the frame beginning at `frameStart` to send the head,
    /// and how far ahead to predict it each time. The host asks for a
    /// pose so far ahead; it is sent that long before the frame's end, less
    /// whole frames, so that each prediction is made as late as it can be.
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
        // TODO: ask the platform for the pose at that time; its own
        // prediction is better than carrying the velocities forward.
        let head = (headProvider?() ?? last).predicted(seconds: Float(prediction) / 1e9)
        let views = Eye.allCases.map { WiVRnView(pose: profile.eyesInHead[$0.rawValue], frustum: profile.eyeFrusta[$0.rawValue]) }
        stream.send(WiVRnPacket.tracking(produced: time, time: time + prediction, head: head, views: views))
    }

    // MARK: Receiving

    private func handle(_ packet: WiVRnToHeadset) throws {
        switch packet {
        case .videoShard(let shard):
            guard Int(shard.stream) < assemblers.count else { break }        // transparency: not drawn
            let stream = Int(shard.stream)
            let result = assemblers[stream].accept(shard, now: WiVRnSession.now())
            for lost in result.abandoned {
                // A frame that never came whole: the host answers with a keyframe.
                framesLost[stream] += 1
                try? sendControl(lost.packet)
            }
            if let whole = result.complete { finished(whole, picture: stream) }
        case .audio(_, let payload):
            audio.write(payload)
        case .timesyncQuery(let query):
            stream.send(WiVRnPacket.timesyncResponse(query: query, response: WiVRnSession.now()))
        case .trackingControl(let pattern, _):
            guard !pattern.isEmpty else { break }
            // The host tunes how far ahead as it measures the delay; that it
            // wants other devices at all is what is worth a line.
            if pattern.map(\.device) != self.pattern.map(\.device) {
                let head = pattern.filter { $0.device == WiVRn.Device.head }.map { "\($0.prediction / 1_000_000) ms" }
                onLog?("the host wants the head predicted \(head.joined(separator: ", ")) ahead, and \(pattern.count - head.count) poses of other devices")
            }
            self.pattern = pattern
        case .videoDescription(let description):
            if description != self.description {
                self.description = description
                assemblers = [ShardAssembler(stream: 0), ShardAssembler(stream: 1)]
                let names = description.codecs.prefix(2).map { WiVRn.Codec(rawValue: $0).map { "\($0)" } ?? "codec \($0)" }
                onLog?("video: \(description.width) x \(description.height) per eye, \(names.joined(separator: " and ")), "
                       + "\(description.frameRate) frames/s for a \(description.refreshRate) Hz display")
            }
        case .audioDescription(let speaker, let microphone):
            onLog?("audio: " + (speaker.map { "\($0.channels) channels at \($0.rate) Hz" } ?? "none")
                   + (microphone == nil ? "" : "; the host wants a microphone, which is not sent yet"))
        case .haptics:
            hapticPulses += 1
        case .serverMessage(_, let text):
            onLog?("host: " + text)
        case .refreshRateChange(let hz):
            onLog?("host asked for \(hz) Hz")
            onRefreshRateRequested?(hz)
        case .featureControl, .cryptoHandshake, .handshake, .other:
            break
        }
    }

    /// One picture of one frame has arrived whole.
    private func finished(_ whole: ShardAssembler.Whole, picture: Int) {
        guard let description else { return }
        framesReceived[picture] += 1
        var progress = whole.feedback
        progress.sentToDecoder = WiVRnSession.now()
        lock.lock()
        feedback[picture][Int(whole.frame % UInt64(WiVRnSession.framesRemembered))] = progress
        lock.unlock()
        try? sendControl(progress.packet)
        let layout = WiVRnSession.layout(views: whole.views, foveation: whole.foveation,
                                         encoded: (description.width, description.height))
        if whole.foveation != foveationNoted {
            foveationNoted = whole.foveation
            let bands = whole.foveation.map { "\($0.across.count) across and \($0.down.count) down" }
            onLog?("video: each eye's picture is \(layout.eyePixels.width) x \(layout.eyePixels.height) squeezed into "
                   + "\(description.width) x \(description.height), in bands: \(bands.joined(separator: "; "))")
        }
        onFrame?(EncodedFrame(frameID: UInt16(truncatingIfNeeded: whole.frame), picture: picture, data: whole.data, layout: layout))
    }

    /// Each eye has a picture of its own, squeezed in bands along both
    /// axes; a band of one axis crossed with a band of the other is a
    /// rectangle at one scale, and so one tile. What an eye sees is linear
    /// in the tangent of the angle, so a band's share of the unsqueezed
    /// picture is its share of the frustum.
    static func layout(views: [WiVRnView], foveation: [WiVRnFoveation], encoded: (width: Int, height: Int)) -> FrameLayout {
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
                    // The picture's top row is the frustum's upper edge.
                    let frustum = Frustum(left: whole.left + (whole.right - whole.left) * column.source.lowerBound,
                                          right: whole.left + (whole.right - whole.left) * column.source.upperBound,
                                          down: whole.up - (whole.up - whole.down) * row.source.upperBound,
                                          up: whole.up - (whole.up - whole.down) * row.source.lowerBound)
                    tiles.append(FrameLayout.Tile(frustum: frustum, picture: eye,
                                                  left: column.encoded.lowerBound, top: row.encoded.lowerBound,
                                                  right: column.encoded.upperBound, bottom: row.encoded.upperBound))
                }
            }
            return FrameLayout.View(eye: views[eye].pose, tiles: tiles)
        }
        return FrameLayout(views: layoutViews, pictures: views.count, eyePixels: pixels)
    }

    // MARK: What the display side reports

    public func frameDecoded(_ frameID: UInt16, picture: Int) {
        report(frameID, pictures: [picture]) { $0.decoded = WiVRnSession.now() }
    }

    public func frameShown(_ frameID: UInt16, at uptimeNanoseconds: UInt64) {
        report(frameID, pictures: [0, 1]) {
            $0.drawn = WiVRnSession.now()
            $0.displayed = Int64(bitPattern: uptimeNanoseconds)
            $0.timesDisplayed &+= 1
        }
    }

    public func displayRefreshes(at uptimeNanoseconds: UInt64, period: Double) {
        lock.lock()
        let before = refreshPeriod
        // The display's rate has changed when the period is off by more than a little.
        let changed = abs(period - before) > before * 0.02
        if changed { refreshPeriod = period }
        lock.unlock()
        guard changed else { return }
        let from = Float((1 / before).rounded()), to = Float((1 / period).rounded())
        onLog?("display now refreshes at \(to) Hz")
        try? sendControl(WiVRnPacket.refreshRateChanged(from: from, to: to))
    }

    /// Note a step in a frame's progress and tell the host. Called from the decoder's and the display's threads.
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

/// Puts one picture's shards back together, frame by frame.
///
/// WiVRn sends nothing twice and no parity: a frame with a shard missing
/// is given up as soon as the frame after it is whole or one later still
/// begins, and the host, told so, makes its next frame a keyframe.
struct ShardAssembler {
    struct Whole {
        var frame: UInt64
        var data: FrameBuffer
        var views: [WiVRnView]
        var foveation: [WiVRnFoveation]
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
    /// The frames being gathered, by number: at most the oldest unfinished one and the one after it.
    private var partial: [UInt64: Partial] = [:]
    /// Frames before this one are over, whole or not.
    private var oldest: UInt64 = 0

    init(stream: UInt8) { self.stream = stream }

    mutating func accept(_ shard: WiVRnShard, now: Int64) -> (complete: Whole?, abandoned: [WiVRnFeedback]) {
        guard shard.frame >= oldest else { return (nil, []) }
        var abandoned: [WiVRnFeedback] = []
        // A shard two frames on means the oldest will not be finished.
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
        // Whole: anything older is over.
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
        return (Whole(frame: shard.frame, data: data, views: views.views, foveation: views.foveation, feedback: frame.feedback),
                abandoned)
    }
}
