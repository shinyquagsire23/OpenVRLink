// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A blocking IPv4 UDP socket over the POSIX calls every target platform has.
public final class UDPSocket {
    let descriptor: Int32

    /// `interface` names a network interface ("en5") that everything this
    /// socket sends must leave by; nil lets the system's routing choose.
    /// Fails if the interface does not exist. `localPort` asks for a
    /// particular port to send from, and fails if it cannot be had.
    public init?(interface: String? = nil, localPort: UInt16? = nil) {
        descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        if descriptor < 0 { return nil }
        if let interface {
            #if canImport(Darwin)
            var index = if_nametoindex(interface)
            guard index != 0,
                  setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
            else {
                close(descriptor)
                return nil
            }
            #else
            close(descriptor)
            return nil      // binding to an interface is not written for this platform yet
            #endif
        }
        if let localPort {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = localPort.bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard bound else {
                close(descriptor)
                return nil
            }
        }
        var size: Int32 = 8 << 20   // a keyframe arrives as a burst of several hundred datagrams
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(descriptor) }

    private static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        return address
    }

    /// Fix the peer; `send` and `receive` then talk only to it.
    public func connect(host: String, port: UInt16) -> Bool {
        var address = UDPSocket.address(host, port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Where this socket sends from, once connected: its IPv4 address
    /// (four bytes, in network order), its port, and how many leading
    /// bits of the address name its network.
    public func localEndpoint() -> (address: Bytes, port: UInt16, prefixLength: UInt8)? {
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0, bound.sin_family == sa_family_t(AF_INET) else { return nil }
        let own = bound.sin_addr.s_addr
        // The netmask of the interface that has this address.
        var prefix: UInt8 = 24
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            var cursor = list
            while let interface = cursor?.pointee {
                cursor = interface.ifa_next
                guard let address = interface.ifa_addr, let mask = interface.ifa_netmask,
                      address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
                let theirs = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                guard theirs == own else { continue }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                prefix = UInt8(netmask.nonzeroBitCount)
            }
            freeifaddrs(list)
        }
        let host = UInt32(bigEndian: own)
        return ([UInt8(host >> 24), UInt8(host >> 16 & 0xFF), UInt8(host >> 8 & 0xFF), UInt8(host & 0xFF)],
                UInt16(bigEndian: bound.sin_port), prefix)
    }

    public func send(_ bytes: Bytes) {
        _ = Foundation.send(descriptor, bytes, bytes.count, 0)
    }

    public func send(_ bytes: Bytes, host: String, port: UInt16) {
        var address = UDPSocket.address(host, port)
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = sendto(descriptor, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// No datagram of this protocol is longer.
    static let largestDatagram = 2084

    /// One datagram, or nil if none arrives within the timeout.
    public func receive(timeout seconds: Double) -> Bytes? {
        receive(timeout: seconds, sender: nil)
    }

    /// One datagram and the address it came from.
    public func receiveFrom(timeout seconds: Double) -> (bytes: Bytes, sender: String)? {
        var address = sockaddr_in()
        guard let bytes = receive(timeout: seconds, sender: &address) else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address.sin_addr, &text, socklen_t(text.count))
        return (bytes, String(cString: text))
    }

    /// The datagram is received straight into the array that is returned:
    /// its memory is not filled first, and nothing is copied afterwards.
    private func receive(timeout seconds: Double, sender: UnsafeMutablePointer<sockaddr_in>?) -> Bytes? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(max(0, seconds) * 1000)) > 0 else { return nil }
        let bytes = Bytes(unsafeUninitializedCapacity: UDPSocket.largestDatagram) { buffer, count in
            var received = 0
            if let sender {
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                received = sender.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length)
                }
            } else {
                received = recv(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            count = max(0, received)
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// Every address on the local IPv4 subnets, for sweeping. Subnets with
    /// more than `limit` addresses are skipped rather than half-swept.
    public static func localSubnetAddresses(limit: Int = 1022) -> [String] {
        var addresses: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let interface = cursor?.pointee {
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr, let mask = interface.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let own = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let hosts = ~netmask
            guard hosts >= 3, Int(hosts) - 1 <= limit else { continue }
            let network = own & netmask
            for host in 1..<hosts where network | host != own {
                let value = network | host
                addresses.append("\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)")
            }
        }
        return addresses
    }
}
