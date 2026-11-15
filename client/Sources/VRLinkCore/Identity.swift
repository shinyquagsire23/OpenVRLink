// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Persists this client's device ID, synthetic serial number, and per-host pairing secrets.
public final class Identity {
    public let deviceID: UInt64
    /// Persistent 16-character hex serial reported to hosts during pairing,
    /// generated once from 64 random bits because Apple platforms do not expose
    /// hardware serial numbers to apps.
    /// TODO: Use the hardware serial on Android when available.
    public let serial: String
    private var secrets: [UInt64: Bytes] = [:]

    public static let path = DataDirectory.url.appendingPathComponent("identity.json")

    public init() {
        if let data = try? Data(contentsOf: Identity.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let device = json["device_id"] as? NSNumber {
            deviceID = device.uint64Value
            serial = json["serial"] as? String ?? Identity.newSerial()
            for (host, hex) in json["secrets"] as? [String: String] ?? [:] {
                if let id = UInt64(host), let secret = Bytes(hex: hex) { secrets[id] = secret }
            }
        } else {
            deviceID = UInt64.random(in: 1...UInt64.max)
            serial = Identity.newSerial()
        }
    }

    private static func newSerial() -> String {
        String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
    }

    public func isPaired(withHost clientID: UInt64) -> Bool { secrets[clientID] != nil }

    /// Returns the stored 32-byte pairing secret for `clientID`, or generates a random 32-byte key if unpaired.
    public func secret(forHost clientID: UInt64) -> Bytes {
        if let secret = secrets[clientID] { return secret }
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    public func setSecret(_ secret: Bytes, forHost clientID: UInt64) {
        secrets[clientID] = secret
        let json: [String: Any] = [
            "device_id": NSNumber(value: deviceID),
            "serial": serial,
            "secrets": Dictionary(uniqueKeysWithValues: secrets.map { (String($0.key), $0.value.hex) }),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        let directory = Identity.path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Identity.path.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }
}
