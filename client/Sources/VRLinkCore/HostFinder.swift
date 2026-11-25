// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A host found on the local network, as shown in a host picker.
public struct FoundHost: Identifiable, Equatable {
    public let name: String
    /// An IP address or a resolvable hostname.
    public let address: String
    public let kind: HostKind
    /// Non-default port advertised by the host, or `nil` to use the protocol's default port.
    public let port: UInt16?

    public init(name: String, address: String, kind: HostKind, port: UInt16? = nil) {
        self.name = name
        self.address = address
        self.kind = kind
        self.port = port
    }

    public var id: String { kind.rawValue + " " + address }

    /// Display label for the host picker; appends `"(WiVRn)"` so a machine running both Steam and WiVRn is
    /// distinguishable.
    public var title: String { kind == .steam ? name : name + " (WiVRn)" }
}

/// Discovered DNS-SD service resolved to a host and port.
public struct FoundService: Equatable {
    /// Advertised service instance name (for WiVRn, the host's computer name).
    public let name: String
    /// Resolved IP address or mDNS hostname (typically ending in `.local`).
    public let host: String
    public let port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Discovers DNS-SD services of a single type (`VRLinkAppleNetwork.ServiceBrowser` uses Bonjour on Apple
/// platforms; `MulticastDNS` sends mDNS queries directly elsewhere).
public protocol ServiceFinder: AnyObject {
    /// Starts browsing, calling `onChange` on an arbitrary thread with the sorted list whenever it changes.
    func start(onChange: @escaping ([FoundService]) -> Void)
    /// Clears cached services and restarts browsing (for example, after networking resumes from background).
    func restart()
}

/// Discovers Steam hosts via UDP broadcast and WiVRn hosts via a platform `ServiceFinder`, publishing a
/// combined list.
public final class HostFinder {
    /// Called on an arbitrary thread with the combined host list (Steam hosts first) whenever it changes.
    public var onChange: (([FoundHost]) -> Void)?
    /// Returns `true` while a stream is connecting or active to pause Steam UDP broadcasts.
    public var busy: () -> Bool = { false }

    private let services: (any ServiceFinder)?
    private let startDelay: Double
    private let lock = NSLock()
    private var searching = false
    private var steamHosts: [FoundHost] = [], wivrnHosts: [FoundHost] = []

    /// Seconds between Steam discovery broadcasts.
    static let steamInterval = 2.0

    /// - Parameters:
    ///   - services: DNS-SD browser for WiVRn hosts, or `nil` to discover Steam hosts only.
    ///   - startDelay: Seconds to wait before the first UDP broadcast on platforms where triggering local-network
    ///     traffic before the initial window appears can suppress the system permission prompt.
    public init(services: (any ServiceFinder)?, startDelay: Double = 0) {
        self.services = services
        self.startDelay = startDelay
    }

    /// Current discovered hosts, with Steam hosts listed before WiVRn hosts. Thread-safe.
    public var hosts: [FoundHost] {
        lock.lock()
        defer { lock.unlock() }
        return steamHosts + wivrnHosts
    }

    private func update(_ change: () -> Void) {
        lock.lock()
        let before = steamHosts + wivrnHosts
        change()
        let after = steamHosts + wivrnHosts
        lock.unlock()
        if after != before { onChange?(after) }
    }

    /// Starts background discovery if it is not already running.
    public func start() {
        lock.lock()
        let already = searching
        searching = true
        lock.unlock()
        if already { return }
        services?.start { [weak self] found in
            self?.update {
                self?.wivrnHosts = found.map {
                    FoundHost(name: $0.name, address: $0.host, kind: .wivrn, port: $0.port == WiVRn.defaultPort ? nil : $0.port)
                }
            }
        }
        let thread = Thread { [weak self, startDelay] in
            let identity = Identity()
            if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
            while let self {
                // Create a fresh socket on each poll so we don't hold onto one created before local-network permission was granted.
                if !busy(), let socket = UDPSocket() {
                    let found = Broadcast.discover(socket, deviceID: identity.deviceID)
                        .filter(\.offersVRLink).sorted { $0.hostname < $1.hostname }
                    update { self.steamHosts = found.map { FoundHost(name: $0.hostname, address: $0.address, kind: .steam) } }
                }
                Thread.sleep(forTimeInterval: HostFinder.steamInterval)
            }
        }
        thread.name = "host-finder"
        thread.start()
    }

    /// Restarts DNS-SD browsing. WiVRn stops advertising while a client is connected, and systems suspend
    /// browsing in the background, so shells call this after a stream ends and when returning to the foreground.
    public func restartServices() {
        services?.restart()
    }
}
