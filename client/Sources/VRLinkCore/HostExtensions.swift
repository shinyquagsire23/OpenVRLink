// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Client side of the OpenVRLink extension handshake (`docs/openvrlink-extensions.md`).
///
/// When `driver_openvrlink` is loaded on the host, both sides exchange `ox*` keys
/// over the SVLRoot key-value channel (`docs/svl-values/svlroot-key-value-channel.md`).
/// Because an unpatched `driver_vrlink` host stores and echoes unknown keys unchanged,
/// each side increments a heartbeat counter every 250 ms so its peer can distinguish
/// a live extension peer from echoed values.
public struct HostExtensions {
    /// Protocol version used by this client.
    public static let version: UInt32 = 1

    public struct Features: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        /// Host encodes sRGB values as `v^(1/gamma)` and the client restores them using `FrameLayout.encodingGamma`.
        public static let encodingGamma = Features(rawValue: 1 << 0)
        /// Host has `vrlink_<model>` settings enabled for OpenVRLink's native headset names
        /// (advertised in `oxAvail` only). Because the client sends its static HMD properties
        /// before receiving `oxAvail`, this flag is saved in `KnownHosts` for the next session.
        public static let headsetSettings = Features(rawValue: 1 << 1)
    }

    /// Host capability state cached in `KnownHosts` across sessions, since the client sends its static HMD
    /// properties before receiving the host's extension records.
    public struct Told: Equatable, Sendable {
        public var features: Features
        /// Bitmask of installed `ControllerModelSet` values reported in `oxModels`.
        public var controllerModels: UInt32
    }

    enum Key {
        static let client = "oxClient", want = "oxWant"
        static let host = "oxHost", available = "oxAvail", active = "oxOn", gamma = "oxGamma", models = "oxModels"
    }

    /// Interval in milliseconds at which a heartbeat value advances.
    static let beat: UInt64 = 250
    /// Timeout in milliseconds after which a host whose heartbeat stops advancing is treated as unpatched.
    static let alive: UInt64 = 1500
    static let gammaRange: ClosedRange<Float> = 1...3

    /// Features supported by this client, sent to the host in `oxWant`.
    public var wants: Features = [.encodingGamma]
    /// Handshake version reported by the host once its heartbeat advances.
    public private(set) var hostVersion: UInt32?
    /// Features available on the host's patched `driver_vrlink`.
    public private(set) var available: Features = []
    /// True once at least one `oxAvail` record has been received (which arrives shortly after the first `oxHost` heartbeats).
    public private(set) var availableHeard = false
    /// Bitmask of controller model sets installed on the host (`oxModels`), or `nil` until received.
    public private(set) var controllerModels: UInt32?
    private var active: Features = []
    private var gamma: Float = 1
    private var lastBeat: Double?
    private var beatAdvanced: UInt64?

    public init() {}

    /// Whether `key` belongs to the handshake (all its keys share the `ox` prefix).
    public static func isExtensionKey(_ key: String) -> Bool { key.hasPrefix("ox") }

    static func heartbeat(atMilliseconds now: UInt64) -> Double {
        Double(version) * 65536 + Double((now / beat) & 0xFFFF)
    }

    /// Data link endpoint and offer records (`DataLink.records`) when a listener is active.
    public var linkRecords: [(key: String, value: Double)] = []

    /// Returns the extension records this client sends on the key-value channel.
    public func records(atMilliseconds now: UInt64) -> [(key: String, value: Double)] {
        [(Key.client, HostExtensions.heartbeat(atMilliseconds: now)), (Key.want, Double(wants.rawValue))] + linkRecords
    }

    /// Applies one key-value record received from the host.
    public mutating func receive(key: String, value: Double, atMilliseconds now: UInt64) {
        guard value.isFinite, value >= 0, value < 4_294_967_296 else { return }
        switch key {
        case Key.host:
            guard value >= 65536, value == value.rounded() else { return }
            if let lastBeat, lastBeat != value {
                beatAdvanced = now
                hostVersion = UInt32(value / 65536)
            }
            lastBeat = value
        case Key.available:
            available = Features(rawValue: UInt32(value))
            availableHeard = true
        case Key.active: active = Features(rawValue: UInt32(value))
        case Key.gamma: gamma = Float(value)
        case Key.models: controllerModels = UInt32(value)
        default: break
        }
    }

    /// Returns whether a patched `driver_vrlink` host has sent an advancing heartbeat recently.
    public func hostPresent(atMilliseconds now: UInt64) -> Bool {
        guard let beatAdvanced else { return false }
        return now &- beatAdvanced <= HostExtensions.alive
    }

    /// Returns the encoding gamma for incoming frames, or `1` when gamma encoding is inactive.
    public func encodingGamma(atMilliseconds now: UInt64) -> Float {
        guard hostPresent(atMilliseconds: now), active.contains(.encodingGamma), wants.contains(.encodingGamma),
              gamma.isFinite else { return 1 }
        return min(max(gamma, HostExtensions.gammaRange.lowerBound), HostExtensions.gammaRange.upperBound)
    }
}
