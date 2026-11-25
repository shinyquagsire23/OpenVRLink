// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Browses mDNS/DNS-SD services over UDP on platforms without a C discovery API (Android's `NsdManager` is
/// Java-only).
///
/// Sends one-shot queries (RFC 6762 section 5.1) from an ephemeral UDP port to the mDNS multicast address.
/// Because responders reply via unicast to queries sent from non-5353 ports (section 6.7), the socket does not
/// need to bind port 5353, join the multicast group, or acquire an Android Wi-Fi multicast lock.
public final class MulticastDNS: ServiceFinder {
    static let group = "224.0.0.251"
    static let port: UInt16 = 5353
    /// Seconds between queries, and how long to listen for answers to each.
    public static let interval = 3.0, listen = 1.0
    /// Number of consecutive queries a service can miss before being removed from the list.
    static let patience = 3

    private let type: String
    private let lock = NSLock()
    private var onChange: (([FoundService]) -> Void)?
    private var running = false
    private var forget = false

    /// Creates a browser for a service type such as `"_wivrn._tcp"`.
    public init(type: String) { self.type = type }

    public func start(onChange: @escaping ([FoundService]) -> Void) {
        lock.lock()
        self.onChange = onChange
        let already = running
        running = true
        lock.unlock()
        if already { return }
        let thread = Thread { [weak self] in
            var found: [String: (service: FoundService, missed: Int)] = [:]
            var published: [FoundService] = []
            while let self {
                lock.lock()
                if forget { found = [:] }
                forget = false
                let report = self.onChange
                lock.unlock()
                let seen = MulticastDNS.browse(type)
                for service in seen { found[service.name] = (service, 0) }
                for name in found.keys where !seen.contains(where: { $0.name == name }) {
                    found[name]?.missed += 1
                    if found[name]?.missed ?? 0 >= MulticastDNS.patience { found[name] = nil }
                }
                let list = found.values.map(\.service).sorted { $0.name < $1.name }
                if list != published {
                    published = list
                    report?(list)
                }
                Thread.sleep(forTimeInterval: MulticastDNS.interval - MulticastDNS.listen)
            }
        }
        thread.name = "mdns"
        thread.start()
    }

    public func restart() {
        lock.lock()
        forget = true
        lock.unlock()
    }

    /// Sends a single mDNS query for `type` and collects responses for `wait` seconds.
    public static func browse(_ type: String, wait: Double = MulticastDNS.listen) -> [FoundService] {
        guard let socket = UDPSocket() else { return [] }
        let name = type + ".local"
        socket.send(query(name, kind: .pointer), host: group, port: port)
        var records: [Record] = []
        var asked: Set<String> = []
        func now() -> Double { Double(Uptime.nanoseconds) / 1e9 }
        let deadline = now() + wait
        while true {
            let left = deadline - now()
            guard left > 0 else { break }
            guard let reply = socket.receive(timeout: left) else { break }
            records += parse(reply)
            // Responders usually add the SRV and address records to a PTR answer; ask for any they left out.
            for instance in instances(of: name, in: records) {
                if let service = records.first(where: { $0.name == instance && $0.target != nil && $0.kind == .service }) {
                    if let host = service.target, !records.contains(where: { $0.name == host && $0.address != nil }),
                       asked.insert(host).inserted {
                        socket.send(query(host, kind: .address), host: group, port: port)
                    }
                } else if asked.insert(instance).inserted {
                    socket.send(query(instance, kind: .service), host: group, port: port)
                }
            }
        }
        return services(of: name, in: records)
    }

    enum Kind: UInt16 {
        case address = 1, pointer = 12, text = 16, service = 33
    }

    /// Parsed DNS resource record containing the fields needed for service discovery.
    struct Record: Equatable {
        /// Lowercased owner name without a trailing dot.
        var name: String
        var kind: Kind
        /// Lowercased instance name for PTR records, or lowercased target host name for SRV records.
        var target: String?
        /// Unlowercased first label of a PTR target, used as the display name.
        var label: String?
        var port: UInt16 = 0
        /// Dotted-decimal IPv4 address from an A record.
        var address: String?
    }

    /// Builds a one-question query. Labels are split on dots, so instance names containing dots are not supported.
    static func query(_ name: String, kind: Kind) -> Bytes {
        var out: Bytes = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]       // id 0, no flags, one question
        for label in name.split(separator: ".") {
            let text = Bytes(label.utf8.prefix(63))
            out.append(UInt8(text.count))
            out += text
        }
        out += [0, UInt8(kind.rawValue >> 8), UInt8(kind.rawValue & 0xFF), 0, 1]      // class IN
        return out
    }

    /// Reads a possibly compressed name at `offset`, returning its labels and the offset just past it.
    static func name(in message: Bytes, at offset: Int) -> (labels: [String], end: Int)? {
        var labels: [String] = []
        var at = offset, end: Int?
        var jumps = 0
        while true {
            guard at < message.count else { return nil }
            let length = Int(message[at])
            if length == 0 {
                return (labels, end ?? at + 1)
            } else if length & 0xC0 == 0xC0 {
                guard at + 1 < message.count, jumps < 16 else { return nil }
                if end == nil { end = at + 2 }
                at = (length & 0x3F) << 8 | Int(message[at + 1])
                jumps += 1
            } else {
                guard length < 64, at + 1 + length <= message.count else { return nil }
                labels.append(String(decoding: message[(at + 1)..<(at + 1 + length)], as: UTF8.self))
                at += 1 + length
            }
        }
    }

    /// Parses the answer, authority, and additional records of an mDNS response, stopping early if a record is
    /// truncated or malformed.
    static func parse(_ message: Bytes) -> [Record] {
        guard message.count >= 12, message[2] & 0x80 != 0 else { return [] }
        func word(_ at: Int) -> Int { Int(message[at]) << 8 | Int(message[at + 1]) }
        var at = 12
        for _ in 0..<word(4) {
            guard let question = name(in: message, at: at) else { return [] }
            at = question.end + 4
        }
        var records: [Record] = []
        for _ in 0..<(word(6) + word(8) + word(10)) {
            guard let owner = name(in: message, at: at), owner.end + 10 <= message.count else { break }
            let type = word(owner.end), length = word(owner.end + 8)
            let data = owner.end + 10
            guard data + length <= message.count else { break }
            at = data + length
            guard let kind = Kind(rawValue: UInt16(type)) else { continue }
            var record = Record(name: owner.labels.joined(separator: ".").lowercased(), kind: kind)
            switch kind {
            case .pointer:
                guard let target = name(in: message, at: data) else { continue }
                record.target = target.labels.joined(separator: ".").lowercased()
                record.label = target.labels.first
            case .service:
                guard length >= 7, let target = name(in: message, at: data + 6) else { continue }
                record.port = UInt16(word(data + 4))
                record.target = target.labels.joined(separator: ".").lowercased()
            case .address:
                guard length == 4 else { continue }
                record.address = message[data..<(data + 4)].map(String.init).joined(separator: ".")
            case .text:
                continue
            }
            records.append(record)
        }
        return records
    }

    private static func instances(of name: String, in records: [Record]) -> [String] {
        var seen: Set<String> = []
        return records.filter { $0.kind == .pointer && $0.name == name.lowercased() }.compactMap(\.target)
            .filter { seen.insert($0).inserted }
    }

    /// Combines PTR, SRV, and A records into resolved services, preferring IPv4 addresses over `.local`
    /// hostnames because Android's system resolver does not resolve mDNS names.
    static func services(of name: String, in records: [Record]) -> [FoundService] {
        var seen: Set<String> = []
        return records.filter { $0.kind == .pointer && $0.name == name.lowercased() }.compactMap { pointer in
            guard let instance = pointer.target, seen.insert(instance).inserted,
                  let service = records.first(where: { $0.kind == .service && $0.name == instance }), let host = service.target
            else { return nil }
            let address = records.first { $0.kind == .address && $0.name == host }?.address
            return FoundService(name: pointer.label ?? instance, host: address ?? host, port: service.port)
        }.sorted { $0.name < $1.name }
    }
}
