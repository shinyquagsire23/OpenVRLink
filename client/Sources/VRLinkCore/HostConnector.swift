// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The streaming protocol used by a host.
public enum HostKind: String, Codable {
    case steam, wivrn
}

/// Handles reaching a host at a known address, pairing if needed, and creating a streaming session
/// for either Steam Remote Play or WiVRn.
///
/// Both protocols use the same callbacks for status updates, logging, and cancellation, though
/// pairing works in opposite directions. Steam generates a PIN on the client that the user enters
/// in Steam on the host (reported via `show`), whereas WiVRn displays a PIN on the host that the
/// user enters on the client (requested via `askPin`).
public struct HostConnector {
    /// Display name reported to the host during pairing or connection (see `HostConnector.name(of:)`).
    public var deviceName: String
    /// Hardware model name reported to the host, such as "Apple Vision Pro".
    public var deviceModel: String
    /// Operating system version string, such as "visionOS 27.0".
    public var systemVersion: String
    /// Whether to advertise microphone support to the host.
    public var microphone = false
    /// Returns network interface names to try first (typically wired interfaces) on each
    /// connection attempt, falling back to default system routing.
    public var preferredInterfaces: () -> [String] = { [] }
    /// When true, retries until the host responds or `cancelled` returns true; when false,
    /// throws immediately if the host is unreachable. Retrying is needed on platforms where
    /// the first packet triggers a local-network permission prompt and packets are dropped
    /// until the user approves it.
    public var keepLooking = true
    /// Reports user-facing connection status updates.
    public var show: (String) -> Void = { _ in }
    /// Writes diagnostic messages to the log.
    public var log: (String) -> Void = { _ in }
    /// Prompts the user for the PIN shown on a WiVRn host, returning nil if they cancel.
    public var askPin: () -> String? = { nil }
    /// Checked between connection steps; if it returns true, `connect` aborts and returns nil.
    public var cancelled: () -> Bool = { false }

    public init(deviceName: String, deviceModel: String, systemVersion: String) {
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
    }

    public init(_ device: DeviceIdentity) {
        self.init(deviceName: HostConnector.name(of: device.name), deviceModel: device.model, systemVersion: device.systemVersion)
    }

    /// Formats a user-assigned device name with the app suffix, e.g. "Max's Mac (OpenVRLink)".
    public static func name(of device: String) -> String { device + " (" + DataDirectory.name + ")" }

    /// Connects to the host at `address`, pairs if necessary, and returns an unstarted session
    /// along with the host's display name. Returns nil if canceled via `cancelled`. `port`
    /// overrides the default port for WiVRn hosts.
    public func connect(_ kind: HostKind, address: String, port: UInt16? = nil,
                        profile: DeviceProfile) throws -> (session: any StreamingSession, hostName: String)? {
        switch kind {
        case .steam: return try steam(address, profile: profile)
        case .wivrn: return try wivrn(address, port: port ?? WiVRn.defaultPort, profile: profile)
        }
    }

    /// Reaches a Steam host, pairs with it if needed, and requests a streaming session.
    private func steam(_ address: String, profile: DeviceProfile) throws -> (session: any StreamingSession, hostName: String)? {
        let identity = Identity()
        show("Looking for \(address)")
        var reached: (socket: UDPSocket, host: SteamHost, interface: String?)?
        while reached == nil {
            if cancelled() { return nil }
            do {
                reached = try Broadcast.reach(address: address, deviceID: identity.deviceID, preferring: preferredInterfaces())
            } catch BroadcastError.noReply where keepLooking {
                continue
            }
        }
        guard let (socket, host, interface) = reached else { return nil }
        log(interface.map { "using wired interface \($0)" } ?? "using the system's choice of network interface")

        let deviceVersion = DataDirectory.name + " " + systemVersion
        let args: SessionArgs
        do {
            show("Asking \(host.hostname) for a session")
            args = try Broadcast.requestSession(socket, host: host, identity: identity, deviceVersion: deviceVersion)
        } catch BroadcastError.notPaired {
            let paired = try Broadcast.pair(socket, host: host, identity: identity, deviceName: deviceName, deviceModel: deviceModel,
                                            cancelled: cancelled, showBusy: {
                show("\(host.hostname) is still showing an earlier PIN prompt; close it in Steam there")
            }, showPIN: { pin in
                show("Enter PIN \(pin) in Steam on \(host.hostname)")
            })
            if !paired { return nil }
            show("Paired; asking \(host.hostname) for a session")
            args = try Broadcast.requestSession(socket, host: host, identity: identity, deviceVersion: deviceVersion)
        }
        if cancelled() { return nil }
        // Report our native HMD model if this host advertised headset settings in the previous session.
        var profile = profile
        let hosts = KnownHosts()
        profile.hostKnowsHeadset = hosts.knowsHeadset(host.clientID)
        if profile.hostKnowsHeadset {
            log("reporting HMD model \(profile.ownModel.model) (supported by \(host.hostname) in previous session)")
        }
        profile.hostControllerModels = hosts.controllerModels(host.clientID)
        if let shown = profile.shownControllerModels { log("using \(shown.title) controller models (installed on \(host.hostname) by openvrlink-companion)") }
        guard let session = StreamSession(args, profile: profile, interface: interface) else {
            // Report whether session creation failed due to an unsupported transport token or a socket error.
            guard SVLLink(token: args.token) != nil else {
                throw BroadcastError.badResponse("the host offered a transport this client does not have implemented yet (token kind \(args.token.prefix(4)), \(args.token.count) characters)")
            }
            throw BroadcastError.badResponse("could not open a socket to \(args.host) port \(args.port)" + (interface.map { " on \($0)" } ?? ""))
        }
        log("transport: \(session.transportName)")
        let clientID = host.clientID, known = profile.hostKnowsHeadset, model = profile.ownModel.model, log = log
        let hadModels = profile.hostControllerModels, own = profile.ownControllerModels
        session.onHostFeatures = { told in
            let hasModels = told?.controllerModels ?? 0
            if hasModels != hadModels {
                hosts.set(clientID, controllerModels: hasModels)
                if let own, (hasModels ^ hadModels) & own.bit != 0 {
                    log(hasModels & own.bit != 0 ? "host has the \(own.title) controller models; will show them starting next session"
                                                 : "host no longer has the \(own.title) controller models; showing Quest controllers next session")
                }
            }
            let knows = told?.features.contains(.headsetSettings) ?? false
            guard knows != known else { return }
            hosts.set(clientID, knowsHeadset: knows)
            log(knows ? "host supports OpenVRLink headset settings; will report \(model) starting next session"
                      : "host no longer advertises OpenVRLink headset settings; reverting to fallback HMD model next session")
        }
        return (session, host.hostname)
    }

    /// Connects to a WiVRn host, handling pairing during the connection handshake.
    private func wivrn(_ address: String, port: UInt16, profile: DeviceProfile) throws -> (session: any StreamingSession, hostName: String)? {
        show("Looking for WiVRn on \(address)")
        while true {
            if cancelled() { return nil }
            do {
                let session = try WiVRnSession.connect(host: address, port: port, profile: profile, name: deviceName,
                                                       pin: {
                                                           show("The host wants its PIN")
                                                           return askPin()
                                                       },
                                                       microphone: microphone, preferring: preferredInterfaces(), onLog: log)
                return (session, address)
            } catch WiVRnError.unreachable where keepLooking {
                // Host isn't reachable yet, or the user hasn't accepted the local-network permission prompt.
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }
}

/// Device metadata reported to the host during pairing and session setup. Platform shells populate this from
/// system APIs (`SystemVersion.device` on Apple platforms, system properties and JNI on Android).
public struct DeviceIdentity {
    /// User-assigned device name, or the hardware model name when unavailable.
    public var name: String
    /// Hardware model, such as "Apple Vision Pro".
    public var model: String
    /// Operating system name, such as "visionOS" (`DeviceProfile.systemName`).
    public var systemName: String
    /// Operating system name and version, such as "visionOS 27.0".
    public var systemVersion: String
    /// Client name and version, such as "OpenVRLink 0.2.0-2" (`DeviceProfile.clientVersion`).
    public var clientVersion: String

    public init(name: String, model: String, systemName: String, systemVersion: String, clientVersion: String = DataDirectory.name) {
        self.name = name
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.clientVersion = clientVersion
    }
}
