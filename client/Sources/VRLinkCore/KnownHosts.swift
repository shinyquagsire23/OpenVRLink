// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Stores per-host capabilities across sessions in `hosts.json` inside the data directory,
/// keyed by `SteamHost.clientID`.
///
/// Currently this tracks whether a host has `vrlink_<model>` settings for OpenVRLink's
/// native headset names (`DeviceProfile.hostKnowsHeadset`). Because the host only advertises
/// extension features after streaming starts, and the client has to send its static HMD
/// properties at session startup, we save the host's capability flag for the next session.
public struct KnownHosts {
    let file: URL

    public init(file: URL = DataDirectory.url.appendingPathComponent("hosts.json")) {
        self.file = file
    }

    private struct Host: Codable {
        var knowsHeadset = false
        /// Optional for backward compatibility with older `hosts.json` files.
        var playForDreamModels: Bool?
    }

    private func read() -> [String: Host] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Host].self, from: data)) ?? [:]
    }

    public func knowsHeadset(_ clientID: UInt64) -> Bool {
        read()[String(clientID)]?.knowsHeadset ?? false
    }

    /// Whether the host's companion driver carries the Play For Dream controller render models
    /// (`DeviceProfile.hostHasPlayForDreamModels`).
    public func hasPlayForDreamModels(_ clientID: UInt64) -> Bool {
        read()[String(clientID)]?.playForDreamModels ?? false
    }

    public func set(_ clientID: UInt64, knowsHeadset: Bool? = nil, playForDreamModels: Bool? = nil) {
        var hosts = read()
        if let knowsHeadset { hosts[String(clientID), default: Host()].knowsHeadset = knowsHeadset }
        if let playForDreamModels { hosts[String(clientID), default: Host()].playForDreamModels = playForDreamModels }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(hosts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
