// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Wire packet definitions for WiVRn release 26.9 (docs/wivrn/protocol.md).
///
/// Each packet starts with a 1-byte packet type ID followed by tightly packed,
/// little-endian fields:
///
/// - Lists and UTF-8 strings are prefixed by their byte or element count.
///   Counts below `0x7fff` use a 16-bit integer; larger counts set bit 15 of
///   the first 16-bit word and store the upper bits in a second 16-bit word.
/// - Optionals use a 1-byte presence flag (`0` or `1`), followed by the payload when `1`.
/// - Tagged unions (`std::variant`) use a 1-byte variant index followed by the payload.
///
/// Client and server packet schemas must match exactly. On connect, the client
/// sends a hash of the packet definitions (`protocolVersion`), and the host
/// rejects mismatched versions. New WiVRn releases typically change this hash
/// and require updating the packet definitions here.
public enum WiVRn {
    /// Protocol version hash for WiVRn 26.9, computed by WiVRn over all packet
    /// field names and types (captured from a 26.9 host announcement).
    public static let protocolVersion: UInt64 = 0xfc26_e619_b7ab_80f8
    public static let release = "26.9"
    public static let defaultPort: UInt16 = 9757
    /// Bonjour/mDNS service type advertised by WiVRn hosts on the local network.
    public static let serviceType = "_wivrn._tcp"

    /// Server encryption and pairing state returned in response to the initial handshake.
    enum CryptoState: UInt8 {
        case encryptionDisabled, pinNeeded, alreadyPaired, pairingDisabled, incompatibleVersion
    }

    enum Codec: Int32 {
        case h264, h265, av1, raw
    }

    /// Subset of WiVRn device IDs used by this client for pose and haptic
    /// reporting. For sided devices, right-hand IDs follow left-hand IDs.
    enum Device {
        static let head: UInt8 = 0
        /// Eye gaze pose in head space.
        static let eyeGaze: UInt8 = 89
        /// Maps haptic actuator IDs (grip, trigger, thumb rest) to controller side.
        static let haptics: [UInt8: Side] = [1: .left, 2: .right, 3: .left, 4: .right, 5: .left, 6: .right]
        static func grip(_ side: Side) -> UInt8 { side == .left ? 11 : 14 }
        static func aim(_ side: Side) -> UInt8 { side == .left ? 12 : 15 }
        /// Pinch midpoint (between thumb and index tip) and index-tip poke poses for tracked hands.
        static func pinchPose(_ side: Side) -> UInt8 { side == .left ? 45 : 81 }
        static func poke(_ side: Side) -> UInt8 { side == .left ? 48 : 84 }
        /// Device IDs used in `tracking_control` requests when the host wants hand joint tracking.
        static func hand(_ side: Side) -> UInt8 { side == .left ? 90 : 91 }
    }

    /// OpenXR interaction profile IDs sent in each tracking packet (`interaction_profile`)
    /// to report whether a hand is untracked, using `XR_EXT_hand_interaction`, or holding a Touch controller.
    enum InteractionProfile {
        static let none: UInt8 = 0, hand: UInt8 = 2, touch: UInt8 = 17
    }

    /// Pose bitmask indicating valid and tracked position and orientation, without velocity data.
    static let poseTrackedStill: UInt8 = 0x33

    /// Pose bitmask indicating valid and tracked position, orientation, and linear/angular velocities.
    static let poseFullyTracked: UInt8 = 0x3F
    /// `XrViewStateFlags` bitmask indicating valid and tracked view position and orientation.
    static let viewFullyTracked: UInt64 = 0xF
    /// Server message kind used to report a fatal error before closing the connection.
    static let serverMessageError: UInt8 = 2
    /// Feature ID for microphone streaming in `feature_control` packets.
    static let featureMicrophone: Int32 = 1
    /// Face tracking format (`face_type`) used in headset info and tracking packets,
    /// where `faceNone` disables face tracking and `faceFB2` selects the 70 weights of `XR_FB_face_tracking2`.
    static let faceNone: UInt8 = 0, faceFB2: UInt8 = 2
    /// Value of `XR_SESSION_STATE_FOCUSED` in OpenXR's `XrSessionState`.
    static let sessionStateFocused: Int32 = 5

    /// Packet type IDs sent from the headset to the host.
    enum FromHeadset: UInt8 {
        case cryptoHandshake = 0, pinCheck1 = 1, pinCheck3 = 2, headsetInfo = 3, feedback = 5, audio = 6, handshake = 7, tracking = 8
        case handTracking = 10, inputs = 15, battery = 17
        case timesyncResponse = 16, refreshRateChanged = 19, sessionStateChanged = 20
    }

    /// Packet type IDs sent from the host to the headset.
    enum ToHeadsetKind: UInt8 {
        case cryptoHandshake = 0, pinCheck2 = 1, pinCheck4 = 2, handshake = 3, serverMessage = 4, audioDescription = 5, videoDescription = 6
        case audio = 7, videoShard = 8, haptics = 9, timesyncQuery = 10, trackingControl = 11
        case featureControl = 12, refreshRateChange = 13
    }
}

/// Per-eye view pose and frustum matching OpenXR and WiVRn's wire format.
struct WiVRnView {
    var pose: Pose
    var frustum: Frustum
}

/// Pose and world-space velocities for a single tracked device in a tracking packet.
struct WiVRnDevicePose {
    var device: UInt8
    var pose: Pose
    var linearVelocity = Vec3(0, 0, 0), angularVelocity = Vec3(0, 0, 0)
    var flags = WiVRn.poseTrackedStill

    /// Creates a device pose with valid linear and angular velocities.
    init(_ device: UInt8, _ tracked: TrackedPose) {
        self.device = device
        pose = tracked.pose
        linearVelocity = tracked.linearVelocity
        angularVelocity = tracked.worldAngularVelocity
        flags = WiVRn.poseFullyTracked
    }

    /// Creates a static device pose with position and orientation only.
    init(_ device: UInt8, _ pose: Pose) {
        self.device = device
        self.pose = pose
    }
}

/// Per-axis foveation layout for a single eye, listing the encoded pixel count
/// of each band. The center band is encoded at 1:1 resolution, and each step
/// outward increases the source-to-encoded pixel ratio by 1.
struct WiVRnFoveation: Equatable {
    var across: [UInt16], down: [UInt16]

    /// Computes normalized `[0, 1]` UV ranges in both the encoded frame and the
    /// full-resolution source image for each foveation band along one axis.
    static func bands(_ counts: [UInt16], encodedSize: Int) -> [(encoded: ClosedRange<Float>, source: ClosedRange<Float>)] {
        let middle = (counts.count - 1) / 2
        let ratios = counts.indices.map { abs(middle - $0) + 1 }
        let sourceSize = zip(counts, ratios).reduce(0) { $0 + Int($1.0) * $1.1 }
        // Encoded frame dimensions can be padded past the sum of the band sizes.
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

    /// Returns the unscaled source resolution along one axis in pixels.
    static func sourceSize(_ counts: [UInt16]) -> Int {
        let middle = (counts.count - 1) / 2
        return counts.enumerated().reduce(0) { $0 + Int($1.element) * (abs(middle - $1.offset) + 1) }
    }
}

/// A single UDP shard of an encoded video stream frame.
struct WiVRnShard {
    /// Stream index (`0` for left eye, `1` for right eye, `2` for alpha).
    var stream: UInt8
    var frame: UInt64
    var index: UInt16
    /// Metadata attached to a frame's first shard, containing the target display
    /// time (headset clock, in nanoseconds), per-eye render views, foveation
    /// parameters, and whether the frame includes an alpha channel.
    var views: (displayTime: Int64, views: [WiVRnView], foveation: [WiVRnFoveation], alpha: Bool)?
    /// Host encode and send timestamps attached to a frame's final shard.
    var timing: [Int64]?
    var payload: ByteSlice
}

struct WiVRnVideoDescription: Equatable {
    /// Encoded dimensions for a single eye in pixels.
    var width, height: Int
    /// Codec IDs for the left eye, right eye, and alpha streams.
    var codecs: [Int32]
    var frameRate, refreshRate: Float
}

enum WiVRnToHeadset {
    case cryptoHandshake(publicKey: String, state: UInt8)
    /// Server messages 2 and 4 of the PAKE PIN verification exchange.
    case pinCheck2([Natural])
    case pinCheck4([Natural])
    case handshake(streamPort: Int32)
    case serverMessage(kind: UInt8, text: String)
    case audioDescription(speaker: (channels: UInt8, rate: UInt32)?, microphone: (channels: UInt8, rate: UInt32)?)
    case videoDescription(WiVRnVideoDescription)
    case audio(timestamp: Int64, payload: ByteSlice)
    case videoShard(WiVRnShard)
    case haptics(device: UInt8, nanoseconds: Int64, frequency: Float, amplitude: Float)
    case timesyncQuery(Int64)
    /// Configures which device poses the host wants reported and each device's prediction offset.
    case trackingControl(pattern: [(device: UInt8, prediction: Int64)], motionToPhotons: Int64)
    case featureControl(feature: Int32, on: Bool)
    case refreshRateChange(Float)
    /// Unrecognized or unused packet type.
    case other(UInt8)

    /// Parses a raw packet, returning `nil` if the buffer is truncated.
    init?(_ packet: Bytes) {
        var reader = WireReader(packet)
        let kind = reader.integer(UInt8.self)
        switch WiVRn.ToHeadsetKind(rawValue: kind) {
        case .cryptoHandshake:
            self = .cryptoHandshake(publicKey: reader.string(), state: reader.integer())
        case .pinCheck2:
            self = .pinCheck2((0..<WiVRnPinCheck.counts.second).map { _ in Natural(bytes: Bytes(reader.span())) })
        case .pinCheck4:
            self = .pinCheck4((0..<WiVRnPinCheck.counts.fourth).map { _ in Natural(bytes: Bytes(reader.span())) })
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

/// Capability and configuration packet sent by the headset before streaming begins.
struct WiVRnHeadsetInfo {
    /// Per-eye application render resolution and encoded video stream resolution.
    var renderPixels, streamPixels: (width: Int, height: Int)
    var refreshRates: [Float]
    /// Initial refresh rate requested for the stream (must be an entry in `refreshRates`).
    var preferredRate: Float
    var bitsPerSecond: UInt32
    var frusta: [Frustum]
    var codecs: [WiVRn.Codec]
    var systemName: String
    var microphone = false, eyeGaze = false, face = false

    /// Stereo 48 kHz speaker output format matching `PlaybackBuffer`.
    static let speakerChannels: UInt8 = 2, speakerRate: UInt32 = 48_000

    var packet: Bytes {
        var out: Bytes = [WiVRn.FromHeadset.headsetInfo.rawValue]
        for value in [renderPixels.width, renderPixels.height, streamPixels.width, streamPixels.height] {
            out.append(integer: UInt16(value))
        }
        out.append(size: refreshRates.count)
        for rate in refreshRates { out.append(float: rate) }
        // Write runtime-adjustable stream parameters (preferred and minimum
        // refresh rates, frame divisor, bitrate, disabled gamepad, and 0 trackers).
        out.append(float: preferredRate)
        out.append(float: refreshRates.min() ?? 0)
        out.append(integer: UInt32(1))
        out.append(integer: bitsPerSecond)
        out.append(0)
        out.append(integer: UInt32(0))
        // Advertise stereo speaker output and optional mono microphone input.
        out.append(1)
        out.append(WiVRnHeadsetInfo.speakerChannels)
        out.append(integer: WiVRnHeadsetInfo.speakerRate)
        out.append(microphone ? 1 : 0)
        if microphone {
            out.append(1)                           // mono channel
            out.append(integer: UInt32(MicrophoneFormat.sampleRate))
        }
        for frustum in frusta { out.append(frustum: frustum) }
        // Enable hand tracking, conditionally enable eye gaze, disable palm pose
        // and user presence, and enable passthrough so apps can submit alpha.
        out.append(1)
        out.append(eyeGaze ? 1 : 0)
        out.append(zeros: 2)
        out.append(1)
        // Advertise optional XR_FB_face_tracking2 support; disable body and generic trackers.
        out.append(face ? WiVRn.faceFB2 : WiVRn.faceNone)
        out.append(0)
        out.append(integer: UInt32(0))
        out.append(size: codecs.count)
        for codec in codecs { out.append(integer: codec.rawValue) }
        out.append(0)                               // no preferred bit depth
        out.append(string: systemName)
        // Locale (language, country, variant) used by the host to localize app names.
        out.append(string: "en")
        out.append(string: "US")
        out.append(string: "")
        return out
    }
}

/// Per-stream frame timing report sent back to the host. Timestamps use the
/// headset's monotonic clock in nanoseconds, or `0` for stages not yet reached.
struct WiVRnFeedback {
    var frame: UInt64
    var stream: UInt8
    /// Encode and send timestamps echoed from the host's final shard for this frame.
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
    /// Builds the initial handshake packet advertising the protocol version, public key, and display name.
    static func cryptoHandshake(publicKey: String, name: String) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.cryptoHandshake.rawValue]
        out.append(integer: WiVRn.protocolVersion)
        out.append(string: publicKey)
        out.append(string: name)
        return out
    }

    /// Empty `crypto_handshake` packet sent after pairing or encryption setup to complete the handshake.
    static let cryptoHandshakeDone: Bytes = {
        var out: Bytes = [WiVRn.FromHeadset.cryptoHandshake.rawValue]
        out.append(integer: UInt64(0))
        out.append(string: "")
        out.append(string: "")
        return out
    }()

    /// Encodes message 1 or 3 of the PIN verification exchange as length-prefixed big-endian integers.
    static func pinCheck(_ kind: WiVRn.FromHeadset, _ numbers: [Natural]) -> Bytes {
        var out: Bytes = [kind.rawValue]
        for number in numbers {
            let bytes = number.bytes
            out.append(size: bytes.count)
            out.append(contentsOf: bytes)
        }
        return out
    }

    static let handshake: Bytes = [WiVRn.FromHeadset.handshake.rawValue]

    static func timesyncResponse(query: Int64, response: Int64) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.timesyncResponse.rawValue]
        out.append(integer: query)
        out.append(integer: response)
        return out
    }

    /// Notifies the host that the display refresh rate changed from `from` to `to` Hz.
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

    /// Encodes a tracking packet with poses predicted for target timestamp `time`
    /// (sampled at `produced`), per-eye view poses and frusta, and the active
    /// `InteractionProfile` for each hand in `holding`.
    static func tracking(produced: Int64, time: Int64, views: [WiVRnView], holding: [UInt8],
                         poses: [WiVRnDevicePose], face: FaceExpressions? = nil) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.tracking.rawValue]
        out.append(contentsOf: holding)
        out.append(WiVRn.InteractionProfile.none)   // no gamepad
        out.append(integer: produced)
        out.append(integer: time)
        out.append(integer: WiVRn.viewFullyTracked)
        out.append(0)                               // view state flags (not recentered)
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
        guard let face else {
            out.append(WiVRn.faceNone)
            return out
        }
        // Serialize XR_FB_face_tracking2 sample time, 70 blendshape weights,
        // lower/upper face confidences, is_valid = 1, and is_eye_following_blendshapes_valid = 0.
        out.append(WiVRn.faceFB2)
        out.append(integer: produced)
        for weight in face.weights { out.append(float: weight) }
        out.append(float: face.lowerFaceConfidence)
        out.append(float: face.upperFaceConfidence)
        out.append(1)
        out.append(0)
        return out
    }

    /// Encodes a hand's 26 OpenXR world-space joints, or marks the hand untracked
    /// when `joints` is `nil`. Each joint includes a position, a 32-bit smallest-three
    /// quaternion, zeroed velocities, radius in 0.1 mm units, and pose flags.
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

    /// Default joint radius (8 mm, in 0.1 mm units) used when the platform does not report finger thickness.
    static let jointRadius: UInt16 = 80

    /// Packs a unit quaternion `(w, x, y, z)` into 32 bits using smallest-three
    /// encoding. The top 2 bits store the index of the largest-magnitude component
    /// (`x`, `y`, `z`, `w`), negated if needed so that component is positive, and
    /// the remaining 3 components are quantized to 10 bits each.
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

    /// Encodes captured 16-bit PCM microphone samples and their capture timestamp.
    static func audio(time: Int64, samples: ByteSlice) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.audio.rawValue]
        out.append(integer: time)
        out.append(size: samples.count)
        out.append(contentsOf: samples)
        return out
    }

    /// Encodes controller and hand gesture scalar inputs along with each input's last-change timestamp.
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

    /// Encodes headset battery charge (`0.0` to `1.0`) and charging state.
    static func battery(_ power: PowerState) -> Bytes {
        var out: Bytes = [WiVRn.FromHeadset.battery.rawValue]
        out.append(float: power.level)
        out.append(1)                               // battery present
        out.append(power.charging ? 1 : 0)
        return out
    }

}

/// Sequential cursor for decoding WiVRn wire packets. Reads past the end of the
/// buffer return zero and set `overran` so truncation can be checked once after parsing.
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

    /// Reads a variable-length count (15-bit in one `UInt16`, or 31-bit across two `UInt16`s if bit 15 is set).
    mutating func size() -> Int {
        let first = Int(integer(UInt16.self))
        return first & 0x8000 == 0 ? first : (first & 0x7FFF) | Int(integer(UInt16.self)) << 15
    }

    /// Reads a length-prefixed byte slice directly referencing the underlying packet buffer.
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

    /// Reads an `XrPosef` (quaternion `x, y, z, w` followed by 3D position).
    mutating func pose() -> Pose {
        let x = float(), y = float(), z = float(), w = float()
        return Pose(position: Vec3(float(), float(), float()), quaternion: [w, x, y, z])
    }

    /// Reads an `XrFovf` (left, right, up, and down half-angles in radians) and converts to tangents.
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
