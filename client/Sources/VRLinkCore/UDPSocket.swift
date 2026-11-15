// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Blocking IPv4 UDP socket built on standard POSIX socket calls.
public final class UDPSocket {
    let descriptor: Int32

    /// Creates an IPv4 UDP socket. Pass `interface` (for example, `"en5"`) to
    /// bind outgoing traffic to a specific network interface, or nil to use
    /// default system routing. Pass `localPort` to bind a specific local port;
    /// initialization fails if the interface does not exist or the port is
    /// unavailable.
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
            return nil      // interface binding is not implemented on this platform
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

    /// Connects the UDP socket to a fixed peer so `send` and `receive` communicate only with that endpoint.
    public func connect(host: String, port: UInt16) -> Bool {
        var address = UDPSocket.address(host, port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Returns the connected socket's local IPv4 address (4 bytes in network
    /// byte order), local port, and subnet prefix length.
    public func localEndpoint() -> (address: Bytes, port: UInt16, prefixLength: UInt8)? {
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0, bound.sin_family == sa_family_t(AF_INET) else { return nil }
        let own = bound.sin_addr.s_addr
        // Look up the subnet mask on the network interface matching our local IP.
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

    /// Maximum datagram size used by the SVL protocol.
    static let largestDatagram = 2084

    /// Receives a single datagram, or returns nil if the timeout expires.
    public func receive(timeout seconds: Double) -> Bytes? {
        receive(timeout: seconds, sender: nil)
    }

    /// Receives a single datagram along with the sender's dotted-decimal IPv4 address.
    public func receiveFrom(timeout seconds: Double) -> (bytes: Bytes, sender: String)? {
        var address = sockaddr_in()
        guard let bytes = receive(timeout: seconds, sender: &address) else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address.sin_addr, &text, socklen_t(text.count))
        return (bytes, String(cString: text))
    }

    /// Reads directly into uninitialized `Bytes` storage to avoid zero-filling
    /// or extra copies.
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

    /// Enumerates host IPv4 addresses on active local subnets for discovery
    /// sweeps, skipping subnets larger than `limit` hosts.
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
