// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import dnssd

/// Finds services announced on the local network by Bonjour (mDNS), and
/// where each is to be reached. A WiVRn host announces itself this way.
///
/// The system ends a search when it suspends the app (taking the headset
/// off, say) and says so only if asked again, so a search that reports an
/// error starts over by itself, and `restart` is there for the moments
/// the app comes back.
///
/// The system's own resolver is asked, so nothing is sent to a service to
/// find out its address. On Apple's platforms other than macOS the app
/// must list the service type under `NSBonjourServices` in its Info.plist.
public final class ServiceBrowser {
    public struct Service: Equatable {
        /// The name it announces: for WiVRn, the computer's.
        public let name: String
        /// Its host name, ending in `.local`.
        public let host: String
        public let port: UInt16
    }

    private let type: String
    private let queue = DispatchQueue(label: "service-browser")
    private var browse: DNSServiceRef?
    private var resolving: [String: DNSServiceRef] = [:]
    private var found: [String: Service] = [:]
    private var onChange: (([Service]) -> Void)?

    /// `type` as in "_wivrn._tcp".
    public init(type: String) { self.type = type }

    deinit {
        resolving.values.forEach(DNSServiceRefDeallocate)
        if let browse { DNSServiceRefDeallocate(browse) }
    }

    /// `onChange` is called, off the main thread, with every service
    /// known each time one comes or goes.
    public func start(onChange: @escaping ([Service]) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            if browse == nil { search() }
        }
    }

    /// Forget what was found and search again.
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

    /// The search died: begin another, after a moment in case it dies at once again.
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
        // Which of the names being resolved this is: the full name begins with it, escaped.
        guard let name = resolving.keys.first(where: { fullName.hasPrefix(ServiceBrowser.escaped($0) + ".") }) else { return }
        let service = Service(name: name, host: host.hasSuffix(".") ? String(host.dropLast()) : host, port: port)
        guard found[name] != service else { return }
        found[name] = service
        publish()
    }

    /// A name as it stands in a full service name: dots and backslashes escaped.
    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: " ", with: "\\032")
    }

    private func publish() {
        onChange?(found.values.sorted { $0.name < $1.name })
    }
}
