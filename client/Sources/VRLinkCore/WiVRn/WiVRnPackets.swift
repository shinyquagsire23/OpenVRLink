// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// WiVRn's packets (docs/wivrn/protocol.md), as its release 26.9 has them.
///
/// A packet is one byte saying which it is, then its fields one after
/// another with nothing between them, numbers little-endian:
///
/// - a list or a string is its length and then its elements; a length
///   under 0x7fff is 16 bits, a longer one sets the top bit and puts the
///   rest in 16 more
/// - an optional is one byte, 0 or 1, and then the value if 1
/// - a choice of types is one byte saying which, then that type
///
/// The two sides must agree on every packet exactly: the first thing a
/// client sends is a number made from the whole set (`protocolVersion`),
/// and a host with another number refuses. A new WiVRn release usually
/// has a new number, and this file is then written again for it.
public enum WiVRn {
    /// Release 26.9. Made by WiVRn from the names and types of every field
    /// of every packet; taken from what a 26.9 host announces.
    public static let protocolVersion: UInt64 = 0xfc26_e619_b7ab_80f8
    public static let release = "26.9"
    public static let defaultPort: UInt16 = 9757

    /// The host's answer to the first packet.
    enum CryptoState: UInt8 {
        case encryptionDisabled, pinNeeded, alreadyPaired, pairingDisabled, incompatibleVersion
    }

    enum Codec: Int32 {
        case h264, h265, av1, raw
    }

    /// The devices this client reports and the inputs it sends, by their
    /// place in WiVRn's list; the full list is far longer. Where a name
    /// takes a side, the right hand's follows the left's.
    enum Device {
        static let head: UInt8 = 0
        /// What the host asks to vibrate: a controller, its trigger, its thumb rest.
        static let haptics: [UInt8: Side] = [1: .left, 2: .right, 3: .left, 4: .right, 5: .left, 6: .right]
        static func grip(_ side: Side) -> UInt8 { side == .left ? 11 : 14 }
        static func aim(_ side: Side) -> UInt8 { side == .left ? 12 : 15 }
        /// A bare hand: between thumb and index tip, and the index tip.
        static func pinchPose(_ side: Side) -> UInt8 { side == .left ? 45 : 81 }
        static func poke(_ side: Side) -> UInt8 { side == .left ? 48 : 84 }
        /// In the host's list of what to locate, a hand's joints.
        static func hand(_ side: Side) -> UInt8 { side == .left ? 90 : 91 }
    }

    /// What a hand holds, as the host is told with every pose
    /// (`interaction_profile`): nothing, the hand itself
    /// (XR_EXT_hand_interaction), or a Touch controller.
    enum InteractionProfile {
        static let none: UInt8 = 0, hand: UInt8 = 2, touch: UInt8 = 17
    }

    /// Pose flags: orientation and position valid and tracked, with no velocities.
    static let poseTrackedStill: UInt8 = 0x33

    /// Pose flags: orientation and position valid, both velocities valid, both tracked.
    static let poseFullyTracked: UInt8 = 0x3F
    /// XrViewStateFlags: orientation and position valid and tracked.
    static let viewFullyTracked: UInt64 = 0xF
    /// XrSessionState.
    static let sessionStateFocused: Int32 = 5

    /// Which packet, from the headset.
    enum FromHeadset: UInt8 {
        case cryptoHandshake = 0, headsetInfo = 3, feedback = 5, audio = 6, handshake = 7, tracking = 8
        case handTracking = 10, inputs = 15, battery = 17
        case timesyncResponse = 16, refreshRateChanged = 19, sessionStateChanged = 20
    }

    /// Which packet, to the headset.
    enum ToHeadsetKind: UInt8 {
        case cryptoHandshake = 0, handshake = 3, serverMessage = 4, audioDescription = 5, videoDescription = 6
        case audio = 7, videoShard = 8, haptics = 9, timesyncQuery = 10, trackingControl = 11
        case featureControl = 12, refreshRateChange = 13
    }
}

/// One eye's view as OpenXR gives it and WiVRn sends it.
struct WiVRnView {
    var pose: Pose
    var frustum: Frustum
}

/// One tracked thing in a tracking packet. Velocities are along the world's axes.
struct WiVRnDevicePose {
    var device: UInt8
    var pose: Pose
    var linearVelocity = Vec3(0, 0, 0), angularVelocity = Vec3(0, 0, 0)
    var flags = WiVRn.poseTrackedStill

    /// Something whose velocities are known.
    init(_ device: UInt8, _ tracked: TrackedPose) {
        self.device = device
        pose = tracked.pose
        linearVelocity = tracked.linearVelocity
        angularVelocity = tracked.worldAngularVelocity
        flags = WiVRn.poseFullyTracked
    }

    /// Something only located.
    init(_ device: UInt8, _ pose: Pose) {
        self.device = device
        self.pose = pose
    }
}

/// How the host squeezed one eye's picture along each axis: how many
/// encoded pixels each band has. The middle band is at full detail, and
/// each band further out has one more source pixel per encoded pixel.
struct WiVRnFoveation: Equatable {
    var across: [UInt16], down: [UInt16]

    /// For one axis: each band's place in the encoded picture and in the
    /// picture before it was squeezed, as fractions (0...1) of each.
    static func bands(_ counts: [UInt16], encodedSize: Int) -> [(encoded: ClosedRange<Float>, source: ClosedRange<Float>)] {
        let middle = (counts.count - 1) / 2
        let ratios = counts.indices.map { abs(middle - $0) + 1 }
        let sourceSize = zip(counts, ratios).reduce(0) { $0 + Int($1.0) * $1.1 }
        // The encoder's picture may be wider than what the bands fill.
        let encodedSize = max(encodedSize, counts.reduce(0) { $0 + Int($1) })
        guard sourceSize > 0, encodedSize > 0 else { return [(0...1, 0...1)] }
        var out: [(encoded: ClosedRange<Float>, source: ClosedRange<Float>)] = []
        var encoded = 0, source = 0
        for (count, ratio) in zip(counts, ratios) where count > 0 {
            let encodedEnd = encoded + Int(count), sourceEnd = source + Int(count) * ratio
            out.append((Float(encoded) / Float(encodedSize)...Float(encodedEnd) / Float(encodedSize),
                        Float(source) / Float(sourceSize)...Float(sourceEnd) / Float(sourceSize)))
            encoded = encodedEnd
            source = sourceEnd
        }
        return out
    }

    /// The length of one axis before it was squeezed, in pixels.
    static func sourceSize(_ counts: [UInt16]) -> Int {
        let middle = (counts.count - 1) / 2
        return counts.enumerated().reduce(0) { $0 + Int($1.element) * (abs(middle - $1.offset) + 1) }
    }
}

/// A part of one picture of one frame.
struct WiVRnShard {
    /// 0 the left eye, 1 the right, 2 transparency.
    var stream: UInt8
    var frame: UInt64
    var index: UInt16
    /// With a frame's first shard: when it is meant to be seen (headset
    /// clock, nanoseconds), and for each eye where it was rendered from
    /// and how it was squeezed.
    var views: (displayTime: Int64, views: [WiVRnView], foveation: [WiVRnFoveation], alpha: Bool)?
    /// With a frame's last shard: when the host began and ended encoding and sending it.
    var timing: [Int64]?
    var payload: ByteSlice
}

struct WiVRnVideoDescription: Equatable {
    /// One eye's encoded picture.
    var width, height: Int
    /// Left, right, transparency.
    var codecs: [Int32]
    var frameRate, refreshRate: Float
}

enum WiVRnToHeadset {
    case cryptoHandshake(publicKey: String, state: UInt8)
    case handshake(streamPort: Int32)
    case serverMessage(kind: UInt8, text: String)
    case audioDescription(speaker: (channels: UInt8, rate: UInt32)?, microphone: (channels: UInt8, rate: UInt32)?)
    case videoDescription(WiVRnVideoDescription)
    case audio(timestamp: Int64, payload: ByteSlice)
    case videoShard(WiVRnShard)
    case haptics(device: UInt8, nanoseconds: Int64, frequency: Float, amplitude: Float)
    case timesyncQuery(Int64)
    /// Which devices the host wants located, each how far ahead of the time it is asked.
    case trackingControl(pattern: [(device: UInt8, prediction: Int64)], motionToPhotons: Int64)
    case featureControl(feature: Int32, on: Bool)
    case refreshRateChange(Float)
    /// A packet this client has no use for.
    case other(UInt8)

    /// Nil for a packet cut short.
    init?(_ packet: Bytes) {
        var reader = WireReader(packet)
        let kind = reader.integer(UInt8.self)
        switch WiVRn.ToHeadsetKind(rawValue: kind) {
        case .cryptoHandshake:
            self = .cryptoHandshake(publicKey: reader.string(), state: reader.integer())
        case .handshake:
            self = .handshake(streamPort: reader.integer())
        case .serverMessage:
            self = .serverMessage(kind: reader.integer(), text: reader.string())
        case .audioDescription:
            func device() -> (channels: UInt8, rate: UInt32)? {
                reader.present() ? (reader.integer(), reader.integer()) : nil
            }
            let speaker = device()
            self = .audioDescription(speaker: speaker, microphone: device())
        case .videoDescription:
            self = .videoDescription(WiVRnVideoDescription(
                width: Int(reader.integer(UInt16.self)), height: Int(reader.integer(UInt16.self)),
                codecs: (0..<3).map { _ in reader.integer(Int32.self) },
                frameRate: reader.float(), refreshRate: reader.float()))
        case .audio:
            self = .audio(timestamp: reader.integer(), payload: reader.span())
        case .videoShard:
            var shard = WiVRnShard(stream: reader.integer(), frame: reader.integer(), index: reader.integer(), payload: [])
            if reader.present() {
                let displayTime = reader.integer(Int64.self)
                let poses = (0..<2).map { _ in reader.pose() }
                let frusta = (0..<2).map { _ in reader.frustum() }
                let foveation = (0..<2).map { _ in
                    WiVRnFoveation(across: reader.list { $0.integer(UInt16.self) }, down: reader.list { $0.integer(UInt16.self) })
                }
                shard.views = (displayTime, zip(poses, frusta).map { WiVRnView(pose: $0, frustum: $1) }, foveation,
                               reader.integer(UInt8.self) != 0)
            }
            if reader.present() { shard.timing = (0..<4).map { _ in reader.integer(Int64.self) } }
            shard.payload = reader.span()
            self = .videoShard(shard)
        case .haptics:
            self = .haptics(device: reader.integer(), nanoseconds: reader.integer(), frequency: reader.float(),
                            amplitude: reader.float())
        case .timesyncQuery:
            self = .timesyncQuery(reader.integer())
        case .trackingControl:
            let pattern = reader.list { (device: $0.integer(UInt8.self), prediction: $0.integer(Int64.self)) }
            self = .trackingControl(pattern: pattern, motionToPhotons: reader.integer())
        case .featureControl:
            self = .featureControl(feature: reader.integer(), on: reader.integer(UInt8.self) != 0)
        case .refreshRateChange:
            self = .refreshRateChange(reader.float())
        case nil:
            self = .other(kind)
        }
        if reader.overran { return nil }
    }
}

/// What the headset tells the host about itself before the stream starts.
struct WiVRnHeadsetInfo {
    /// One eye: what applications render, and what is encoded and sent.
    var renderPixels, streamPixels: (width: Int, height: Int)
    var refreshRates: [Float]
    /// The rate the stream should run at; one of `refreshRates`.
    var preferredRate: Float
    var bitsPerSecond: UInt32
    var frusta: [Frustum]
    var codecs: [WiVRn.Codec]
    var systemName: String

    /// The speaker offered: what `PlaybackBuffer` plays.
    static let speakerChannels: UInt8 = 2, speakerRate: UInt32 = 48_000

    var packet: Bytes {
        var out: Bytes = [WiVRn.FromHeadset.headsetInfo.rawValue]
        for value in [renderPixels.width, renderPixels.height, streamPixels.width, streamPixels.height] {
            out.append(integer: UInt16(value))
        }
        out.append(size: refreshRates.count)
        for rate in refreshRates { out.append(float: rate) }
        // Settings that can be changed while streaming: the rate wanted,
        // the least rate accepted, frames per refresh (as a divider), the
        // bitrate, a gamepad mirrored to the host (no), body trackers (none).
        out.append(float: preferredRate)
        out.append(float: refreshRates.min() ?? 0)
        out.append(integer: UInt32(1))
        out.append(integer: bitsPerSecond)
        out.append(0)
        out.append(integer: UInt32(0))
        // A speaker; no microphone.
        out.append(1)
        out.append(WiVRnHeadsetInfo.speakerChannels)
        out.append(integer: WiVRnHeadsetInfo.speakerRate)
        out.append(0)
        for frustum in frusta { out.append(frustum: frustum) }
        // Hand tracking: yes. Eye gaze, palm pose, user presence, passthrough: none.
        out.append(1)
        out.append(zeros: 4)
        // Face and body tracking: none; no other trackers.
        out.append(zeros: 2)
        out.append(integer: UInt32(0))
        out.append(size: codecs.count)
        for codec in codecs { out.append(integer: codec.rawValue) }
        out.append(0)                               // no bit depth asked for
        out.append(string: systemName)
        // Language, country and variant, for the host's list of applications.
        out.append(string: "en")
        out.append(string: "US")
        out.append(string: "")
        return out
    }
}

/// How far one picture of one frame got, for the host. Times are the
/// headset's clock in nanoseconds, zero for a step not reached.
struct WiVRnFeedback {
    var frame: UInt64
    var stream: UInt8
    /// When the host began and ended encoding and sending it, as it said itself.
    var hostTiming: [Int64] = [0, 0, 0, 0]
    var firstPacket: Int64 = 0, lastPacket: Int64 = 0
    var sentToDecoder: Int64 = 0, decoded: Int64 = 0
    var drawn: Int64 = 0, displayed: Int64 = 0
    var timesDisplayed: UInt8 = 0

    var packet: Bytes {
        var out: Bytes = [WiVRn.FromHeadset.feedback.rawValue]
        out.append(integer: frame)
        out.append(stream)
        for time in hostTiming + [firstPacket, lastPacket, sentToDecoder, decoded, drawn, displayed] {
            out.append(integer: time)
        }
        out.append(timesDisplayed)
        return out
    }
}

enum WiVRnPacket {
    /// The first packet. The name is what the host lists this headset as.
    static func cryptoHandshake(publicKey: String, name: String) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.cryptoHandshake.rawValue]
        out.append(integer: WiVRn.protocolVersion)
        out.append(string: publicKey)
        out.append(string: name)
        return out
    }

    /// The same packet with nothing in it: "ready to go on".
    static let cryptoHandshakeDone: Bytes = {
        var out: Bytes = [WiVRn.FromHeadset.cryptoHandshake.rawValue]
        out.append(integer: UInt64(0))
        out.append(string: "")
        out.append(string: "")
        return out
    }()

    static let handshake: Bytes = [WiVRn.FromHeadset.handshake.rawValue]

    static func timesyncResponse(query: Int64, response: Int64) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.timesyncResponse.rawValue]
        out.append(integer: query)
        out.append(integer: response)
        return out
    }

    /// The display has gone from one refresh rate to another, in Hz.
    static func refreshRateChanged(from: Float, to: Float) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.refreshRateChanged.rawValue]
        out.append(float: from)
        out.append(float: to)
        return out
    }

    static func sessionState(_ state: Int32) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.sessionStateChanged.rawValue]
        out.append(integer: state)
        return out
    }

    /// Where the head and whatever the hands hold are expected to be at
    /// `time`, worked out at `produced`; with it, each eye's place on the
    /// head and its frustum. `holding` is an `InteractionProfile` for each hand.
    static func tracking(produced: Int64, time: Int64, views: [WiVRnView], holding: [UInt8],
                         poses: [WiVRnDevicePose]) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.tracking.rawValue]
        out.append(contentsOf: holding)
        out.append(WiVRn.InteractionProfile.none)   // no gamepad
        out.append(integer: produced)
        out.append(integer: time)
        out.append(integer: WiVRn.viewFullyTracked)
        out.append(0)                               // state flags: not recentered
        for view in views {
            out.append(pose: view.pose)
            out.append(frustum: view.frustum)
        }
        out.append(size: poses.count)
        for pose in poses {
            out.append(pose: pose.pose)
            out.append(vector: pose.linearVelocity)
            out.append(vector: pose.angularVelocity)
            out.append(pose.device)
            out.append(pose.flags)
        }
        out.append(0)                               // face tracking: none
        return out
    }

    /// One hand's 26 joints in OpenXR's order, in world space, or nil for
    /// a hand that is not tracked. A joint is its position, its rotation
    /// packed into 32 bits, velocities (not given), its radius in tenths
    /// of a millimeter, and pose flags.
    static func handTracking(produced: Int64, time: Int64, side: Side, joints: [Pose]?) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.handTracking.rawValue]
        out.append(integer: produced)
        out.append(integer: time)
        out.append(UInt8(side.rawValue))
        guard let joints else {
            out.append(0)
            return out
        }
        out.append(1)
        for joint in joints {
            out.append(vector: joint.position)
            out.append(integer: packedRotation(joint.quaternion))
            out.append(zeros: 24)
            out.append(integer: jointRadius)
            out.append(WiVRn.poseTrackedStill)
        }
        return out
    }

    /// No platform here says how thick a finger is: 8 mm, in tenths of a millimeter.
    static let jointRadius: UInt16 = 80

    /// A unit quaternion (w, x, y, z) in 32 bits: two bits say which of
    /// x, y, z, w is largest, and the other three follow in that order at
    /// ten bits each, signed so that the largest is positive.
    static func packedRotation(_ q: [Float]) -> UInt32 {
        let parts = [q[1], q[2], q[3], q[0]]                    // x, y, z, w
        var largest = 3
        for index in 0..<3 where abs(parts[index]) > abs(parts[largest]) { largest = index }
        let scale = 511 * Float(2).squareRoot() * (parts[largest] < 0 ? -1 : 1)
        var out = UInt32(largest) << 30
        var shift: UInt32 = 20
        for index in 0..<4 where index != largest {
            out |= UInt32(max(0, min(1023, parts[index] * scale + 512.5))) << shift
            shift = shift &- 10
        }
        return out
    }

    /// Buttons, triggers and sticks: each value with the time it last changed.
    static func inputs(_ values: [(id: UInt8, value: Float, changed: Int64)]) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.inputs.rawValue]
        out.append(size: values.count)
        for input in values {
            out.append(input.id)
            out.append(float: input.value)
            out.append(integer: input.changed)
        }
        return out
    }

    /// The headset's battery: 0 empty ... 1 full.
    static func battery(_ power: PowerState) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.battery.rawValue]
        out.append(float: power.level)
        out.append(1)                               // there is a battery
        out.append(power.charging ? 1 : 0)
        return out
    }

    /// A public key as the host wants one, in PEM. With encryption off the
    /// host only checks that it is a key. This is an X25519 one: the
    /// fixed twelve bytes that say so, then the key's 32.
    static func publicKeyPEM(_ key: Bytes) -> String {
        let prefix: Bytes = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
        return "-----BEGIN PUBLIC KEY-----\n" + Data(prefix + key).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
    }
}

/// Reads a packet's fields in order. Reading past the end gives zeros and
/// sets `overran`, so a packet cut short is noticed once, at the end.
struct WireReader {
    private let bytes: Bytes
    private var offset = 0
    private(set) var overran = false

    init(_ bytes: Bytes) { self.bytes = bytes }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) -> T {
        let size = MemoryLayout<T>.size
        if offset + size > bytes.count { overran = true }
        let value: T = bytes.integer(at: offset)
        offset += size
        return value
    }

    mutating func float() -> Float { Float(bitPattern: integer(UInt32.self)) }
    mutating func present() -> Bool { integer(UInt8.self) != 0 }

    /// A length: 16 bits, or 31 in two halves when the top bit of the first is set.
    mutating func size() -> Int {
        let first = Int(integer(UInt16.self))
        return first & 0x8000 == 0 ? first : (first & 0x7FFF) | Int(integer(UInt16.self)) << 15
    }

    /// A run of bytes with its length in front: a part of the packet, not a copy.
    mutating func span() -> ByteSlice {
        let count = size()
        guard offset + count <= bytes.count else {
            overran = true
            return []
        }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func string() -> String { String(decoding: span(), as: UTF8.self) }

    mutating func list<T>(_ element: (inout WireReader) -> T) -> [T] {
        let count = size()
        var out: [T] = []
        for _ in 0..<count where !overran { out.append(element(&self)) }
        return out
    }

    /// XrPosef: orientation (x, y, z, w), then position.
    mutating func pose() -> Pose {
        let x = float(), y = float(), z = float(), w = float()
        return Pose(position: Vec3(float(), float(), float()), quaternion: [w, x, y, z])
    }

    /// XrFovf: the angles to the left, right, upper and lower edges, in radians.
    mutating func frustum() -> Frustum {
        let left = float(), right = float(), up = float(), down = float()
        return Frustum(left: Float(tan(Double(left))), right: Float(tan(Double(right))),
                       down: Float(tan(Double(down))), up: Float(tan(Double(up))))
    }
}

extension Array where Element == UInt8 {
    mutating func append(size: Int) {
        if size < 0x7FFF {
            append(integer: UInt16(size))
        } else {
            append(integer: UInt16(size & 0x7FFF) | 0x8000)
            append(integer: UInt16(size >> 15))
        }
    }

    mutating func append(string: String) {
        append(size: string.utf8.count)
        append(contentsOf: string.utf8)
    }

    mutating func append(vector: Vec3) {
        for value in [vector.x, vector.y, vector.z] { append(float: value) }
    }

    mutating func append(pose: Pose) {
        let q = pose.quaternion
        for value in [q[1], q[2], q[3], q[0]] { append(float: value) }
        append(vector: pose.position)
    }

    mutating func append(frustum: Frustum) {
        for tangent in [frustum.left, frustum.right, frustum.up, frustum.down] {
            append(float: Float(atan(Double(tangent))))
        }
    }
}
