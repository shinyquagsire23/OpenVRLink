// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Host-side definitions for the OpenVRLink extension handshake (`docs/openvrlink-extensions.md`).
///
/// The handshake uses the SVLRoot key/value channel, which exchanges 32-byte
/// `TransportValue_t` records and ignores unknown keys on stock peers. Because an
/// unpatched peer echoes incoming keys unchanged, both sides increment a heartbeat
/// counter so each peer can verify that the remote side is actively generating records.
/// The corresponding client implementation is `HostExtensions` in `VRLinkCore`.
public enum Handshake {
    /// Version of the handshake this code speaks.
    public static let version: UInt32 = 1
    /// Client heartbeat: `version * 65536 + tick`, the tick advancing every `beat` milliseconds.
    public static let clientKey: StaticString = "oxClient"
    /// Bitmask of the features the client is able to undo right now.
    public static let wantKey: StaticString = "oxWant"
    /// Host heartbeat, encoded like the client's.
    public static let hostKey: StaticString = "oxHost"
    /// Bitmask of the features the patched host could apply.
    public static let availableKey: StaticString = "oxAvail"
    /// Bitmask of the features applied to the frames being sent now.
    public static let activeKey: StaticString = "oxOn"
    /// Encoding gamma applied to the picture (1 when gamma is not active).
    public static let gammaKey: StaticString = "oxGamma"

    /// The host raises encoded brightness with `v' = v^(1/gamma)`; the client undoes it.
    public static let gammaFeature: UInt32 = 1 << 0
    /// Advertised in `oxAvail` when the host has `vrlink_<model>` settings enabled for
    /// OpenVRLink's native headset names. No per-frame processing is involved (`oxOn` never
    /// sets this bit); because the client sends its HMD model before receiving `oxAvail`,
    /// it saves this flag for the next session.
    public static let headsetFeature: UInt32 = 1 << 1
    /// Key carrying the bitmask of controller model sets installed in `driver_openvrlink/resources/rendermodels`.
    /// Bit 0 is Play For Dream MR (`{openvrlink}pfd_mr_controller_left` and `_right`) and bit 1 is Galaxy XR
    /// (`{openvrlink}galaxy_xr_controller_left` and `_right`).
    public static let modelsKey: StaticString = "oxModels"

    /// Keys carrying the client's data link IPv4 address (packed big-endian in 32 bits) and TCP port.
    public static let addressKey: StaticString = "oxAddr", portKey: StaticString = "oxPort"
    /// Keys carrying the low and high 48-bit halves of the client's 96-bit data link connection token.
    public static let firstTokenKey: StaticString = "oxKey0", secondTokenKey: StaticString = "oxKey1"
    /// Key carrying the bitmask of controller model sets the client can upload over the data link, using the same bits as `modelsKey`.
    public static let offerKey: StaticString = "oxOffer"

    /// Milliseconds between changes of a heartbeat value.
    public static let beat: UInt64 = 250
    /// A peer whose heartbeat has not changed for this many milliseconds is gone (or was only an echo).
    public static let alive: UInt64 = 1500
    public static let gammaRange: ClosedRange<Float> = 1...3

    /// Size of one `TransportValue_t`: a 20-byte NUL-padded key, a float64 and a 32-bit timestamp.
    public static let recordSize = 32
    static let keySize = 20, valueOffset = 0x14, timeOffset = 0x1C

    public static func heartbeat(atMilliseconds now: UInt64) -> Double {
        Double(version) * 65536 + Double((now / beat) & 0xFFFF)
    }

    /// The version inside a heartbeat value, or `nil` if it is not one.
    public static func version(ofHeartbeat value: Double) -> UInt32? {
        guard value >= 65536, value < 4_294_967_296, value == value.rounded(.towardZero) else { return nil }
        return UInt32(value / 65536)
    }

    public static func clamped(gamma: Float) -> Float {
        gamma.isFinite ? min(max(gamma, gammaRange.lowerBound), gammaRange.upperBound) : 1
    }

    /// Whether the record at `record` has exactly the key `key`.
    public static func record(_ record: UnsafeRawPointer, hasKey key: StaticString) -> Bool {
        let length = key.utf8CodeUnitCount
        guard length <= keySize else { return false }
        for index in 0..<length where record.load(fromByteOffset: index, as: UInt8.self) != key.utf8Start[index] { return false }
        return length == keySize || record.load(fromByteOffset: length, as: UInt8.self) == 0
    }

    public static func value(of record: UnsafeRawPointer) -> Double {
        Double(bitPattern: UInt64(littleEndian: record.loadUnaligned(fromByteOffset: valueOffset, as: UInt64.self)))
    }

    public static func time(of record: UnsafeRawPointer) -> Int32 {
        Int32(littleEndian: record.loadUnaligned(fromByteOffset: timeOffset, as: Int32.self))
    }

    /// Overwrites the record at `record`.
    public static func write(_ record: UnsafeMutableRawPointer, key: StaticString, value: Double, time: Int32) {
        let length = min(key.utf8CodeUnitCount, keySize)
        for index in 0..<keySize {
            record.storeBytes(of: index < length ? key.utf8Start[index] : 0, toByteOffset: index, as: UInt8.self)
        }
        record.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: valueOffset, as: UInt64.self)
        record.storeBytes(of: time.littleEndian, toByteOffset: timeOffset, as: Int32.self)
    }
}

/// Host-side state machine for the extension handshake. `driver_openvrlink` feeds
/// incoming client records to `observe` and calls `fill` on outgoing record batches.
public struct HostSide {
    /// Features whose patches were applied to this `driver_vrlink` build.
    public var available: UInt32 = 0
    /// Features the user has switched on in SteamVR's settings.
    public var enabled: UInt32 = 0
    /// Gamma to use while the gamma feature is active.
    public var gamma: Float = 1
    /// Bitmask of controller model sets installed in the driver (`Handshake.modelsKey`).
    public var models: UInt32 = 0
    private var lastBeat: Double = 0
    private var beatSeen = false
    private var beatChanged: UInt64?
    private var wants: UInt32 = 0
    private var linkAddress: Double?, linkPort: Double?, firstToken: Double?, secondToken: Double?, offer: Double = 0
    private var fills: UInt32 = 0
    private var next = 0

    public init(available: UInt32 = 0, enabled: UInt32 = 0, gamma: Float = 1) {
        self.available = available
        self.enabled = enabled
        self.gamma = gamma
    }

    /// Looks at `count` records received from the client.
    public mutating func observe(_ records: UnsafeRawPointer, count: Int, atMilliseconds now: UInt64) {
        for index in 0..<count {
            let record = records + index * Handshake.recordSize
            if Handshake.record(record, hasKey: Handshake.clientKey) {
                let value = Handshake.value(of: record)
                guard Handshake.version(ofHeartbeat: value) != nil else { continue }
                if beatSeen, value != lastBeat { beatChanged = now }
                lastBeat = value
                beatSeen = true
            } else if Handshake.record(record, hasKey: Handshake.wantKey) {
                let value = Handshake.value(of: record)
                if value >= 0, value < 4_294_967_296 { wants = UInt32(value) }
            } else if Handshake.record(record, hasKey: Handshake.addressKey) {
                linkAddress = Handshake.value(of: record)
            } else if Handshake.record(record, hasKey: Handshake.portKey) {
                linkPort = Handshake.value(of: record)
            } else if Handshake.record(record, hasKey: Handshake.firstTokenKey) {
                firstToken = Handshake.value(of: record)
            } else if Handshake.record(record, hasKey: Handshake.secondTokenKey) {
                secondToken = Handshake.value(of: record)
            } else if Handshake.record(record, hasKey: Handshake.offerKey) {
                let value = Handshake.value(of: record)
                if value >= 0, value < 4_294_967_296 { offer = value }
            }
        }
    }

    public func clientPresent(atMilliseconds now: UInt64) -> Bool {
        guard let beatChanged else { return false }
        return now >= beatChanged ? now - beatChanged <= Handshake.alive : true
    }

    /// Returns the client's data link endpoint, authentication token, and offered model bitmask once all keys
    /// have been received from a client with an advancing heartbeat (ignoring stale keys echoed by stock clients).
    public func link(atMilliseconds now: UInt64) -> (address: UInt32, port: UInt16, token: [UInt8], offer: UInt32)? {
        guard clientPresent(atMilliseconds: now), let linkAddress, let linkPort, let firstToken, let secondToken,
              linkAddress >= 1, linkAddress < 4_294_967_296, linkAddress == linkAddress.rounded(.towardZero),
              linkPort >= 1, linkPort < 65536, linkPort == linkPort.rounded(.towardZero),
              let token = DataLink.token(firstToken, secondToken) else { return nil }
        return (UInt32(linkAddress), UInt16(linkPort), token, UInt32(offer))
    }

    /// Features to apply to the frame being prepared now.
    public func active(atMilliseconds now: UInt64) -> UInt32 {
        clientPresent(atMilliseconds: now) ? available & enabled & wants : 0
    }

    /// Gamma to apply to the frame being prepared now; exactly 1 means none.
    public func activeGamma(atMilliseconds now: UInt64) -> Float {
        let gamma = Handshake.clamped(gamma: gamma)
        return active(atMilliseconds: now) & Handshake.gammaFeature != 0 && gamma > 1.001 ? gamma : 1
    }

    /// Updates an outgoing batch of `count` records before `driver_vrlink` sends them.
    /// While an OpenVRLink client is active, overwrites the first record (the slow
    /// round-robin slot) on every second batch with the next `ox*` host key. Stock clients
    /// never receive extension keys.
    public mutating func fill(_ records: UnsafeMutableRawPointer, count: Int, atMilliseconds now: UInt64) {
        guard count > 0, clientPresent(atMilliseconds: now) else { return }
        fills &+= 1
        guard fills % 2 == 0 else { return }
        let time = Handshake.time(of: records)
        switch next {
        case 0: Handshake.write(records, key: Handshake.hostKey, value: Handshake.heartbeat(atMilliseconds: now), time: time)
        case 1: Handshake.write(records, key: Handshake.availableKey, value: Double(available), time: time)
        case 2: Handshake.write(records, key: Handshake.activeKey, value: Double(active(atMilliseconds: now)), time: time)
        case 3: Handshake.write(records, key: Handshake.gammaKey, value: Double(activeGamma(atMilliseconds: now)), time: time)
        default: Handshake.write(records, key: Handshake.modelsKey, value: Double(models), time: time)
        }
        next = (next + 1) % 5
    }
}
