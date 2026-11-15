// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import dnssd

/// Discovers Bonjour (mDNS) services on the local network and resolves their
/// hostnames and ports. WiVRn servers advertise themselves via mDNS.
///
/// visionOS suspends active mDNS browse operations when the app is backgrounded
/// (such as when taking off the headset) without delivering an immediate
/// callback. Any browse or resolve error triggers an automatic retry, and
/// callers can invoke `restart()` when the app returns to the foreground.
///
/// Uses the system DNS-SD daemon (`dnssd`) to resolve hostnames passively. On
/// non-macOS Apple platforms, the browsed service type must be declared under
/// `NSBonjourServices` in `Info.plist`.
public final class ServiceBrowser {
    public struct Service: Equatable {
        /// Advertised service instance name (for WiVRn, the host's computer name).
        public let name: String
        /// Resolved mDNS hostname (typically ending in `.local`).
        public let host: String
        public let port: UInt16
    }

    private let type: String
    private let queue = DispatchQueue(label: "service-browser")
    private var browse: DNSServiceRef?
    private var resolving: [String: DNSServiceRef] = [:]
    private var found: [String: Service] = [:]
    private var onChange: (([Service]) -> Void)?

    /// Creates a browser for a Bonjour service type such as `"_wivrn._tcp"`.
    public init(type: String) { self.type = type }

    deinit {
        resolving.values.forEach(DNSServiceRefDeallocate)
        if let browse { DNSServiceRefDeallocate(browse) }
    }

    /// Starts browsing and invokes `onChange` on an internal serial queue
    /// with the full sorted list of resolved services whenever services are
    /// added or removed.
    public func start(onChange: @escaping ([Service]) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            if browse == nil { search() }
        }
    }

    /// Clears discovered services and restarts the mDNS browse session.
    public func restart() {
        queue.async { [self] in
            guard onChange != nil else { return }
            stop()
            search()
        }
    }

    private func stop() {
        resolving.values.forEach(DNSServiceRefDeallocate)
        resolving = [:]
        if let browse { DNSServiceRefDeallocate(browse) }
        browse = nil
        if !found.isEmpty {
            found = [:]
            publish()
        }
    }

    /// Tears down a failed browse session and retries after a 1-second delay.
    private func failed() {
        guard browse != nil else { return }
        stop()
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            if browse == nil { search() }
        }
    }

    private func search() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
            guard let context else { return }
            let browser = Unmanaged<ServiceBrowser>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let name, let type, let domain else {
                browser.failed()
                return
            }
            let added = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
            browser.changed(String(cString: name), type: String(cString: type), domain: String(cString: domain),
                            interface: interface, added: added)
        }
        guard DNSServiceBrowse(&browse, 0, 0, type, nil, callback, context) == kDNSServiceErr_NoError, let browse
        else {
            browse = nil
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if self.browse == nil, onChange != nil { search() }
            }
            return
        }
        DNSServiceSetDispatchQueue(browse, queue)
    }

    private func changed(_ name: String, type: String, domain: String, interface: UInt32, added: Bool) {
        guard added else {
            if let old = resolving.removeValue(forKey: name) { DNSServiceRefDeallocate(old) }
            if found.removeValue(forKey: name) != nil { publish() }
            return
        }
        guard resolving[name] == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: DNSServiceResolveReply = { _, _, _, error, fullName, host, port, _, _, context in
            guard let context else { return }
            let browser = Unmanaged<ServiceBrowser>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let fullName, let host else {
                browser.failed()
                return
            }
            // The port comes in network byte order.
            browser.resolved(String(cString: fullName), host: String(cString: host), port: UInt16(bigEndian: port))
        }
        var resolve: DNSServiceRef?
        guard DNSServiceResolve(&resolve, 0, interface, name, type, domain, callback, context) == kDNSServiceErr_NoError,
              let resolve
        else { return }
        DNSServiceSetDispatchQueue(resolve, queue)
        resolving[name] = resolve
    }

    private func resolved(_ fullName: String, host: String, port: UInt16) {
        // Match the escaped instance prefix of `fullName` back to its unescaped service name.
        guard let name = resolving.keys.first(where: { fullName.hasPrefix(ServiceBrowser.escaped($0) + ".") }) else { return }
        let service = Service(name: name, host: host.hasSuffix(".") ? String(host.dropLast()) : host, port: port)
        guard found[name] != service else { return }
        found[name] = service
        publish()
    }

    /// Escapes backslashes, dots, and spaces to match DNS-SD full service name formatting.
    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: " ", with: "\\032")
    }

    private func publish() {
        onChange?(found.values.sorted { $0.name < $1.name })
    }
}
