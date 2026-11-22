// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// IPv4 TCP client socket with blocking full-buffer writes and non-blocking reads.
public final class TCPSocket {
    let descriptor: Int32
    private let sendLock = NSLock()

    /// Connects to a dotted-decimal IPv4 `address` and `port`, timing out after
    /// `timeout` seconds. Pass `interface` to bind the socket to a specific
    /// network interface, or nil to use default system routing.
    public init?(address: String, port: UInt16, timeout: Double = 5, interface: String? = nil) {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
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
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &target.sin_addr)
        // Use a non-blocking connect with poll() so unreachable hosts time out promptly.
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let started = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started != 0 {
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard errno == EINPROGRESS, poll(&poller, 1, Int32(timeout * 1000)) > 0,
                  getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0
            else {
                close(descriptor)
                return nil
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags)
        var on: Int32 = 1
        setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        // Return EPIPE on writes to a closed peer instead of raising SIGPIPE.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close(descriptor) }

    /// Shuts down both directions of the socket immediately so the peer sees EOF before deallocation.
    public func shutDown() {
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
    }

    /// Writes all of `bytes` to the socket, returning false if the connection fails. Thread-safe.
    @discardableResult
    public func send(_ bytes: Bytes) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { systemSend(descriptor, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if wrote <= 0 { return false }
            sent += wrote
        }
        return true
    }

    /// Reads any immediately available bytes without blocking, or returns nil if the connection is closed or errored.
    public func receiveAvailable() -> Bytes? {
        var closed = false
        let bytes = Bytes(unsafeUninitializedCapacity: 64 << 10) { buffer, count in
            let received = recv(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT))
            closed = received == 0 || (received < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            count = max(0, received)
        }
        return closed ? nil : bytes
    }

    /// Resolves a hostname or IPv4 string to a dotted-decimal IPv4 address.
    public static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
            var numbers = address.pointee.sin_addr
            inet_ntop(AF_INET, &numbers, &text, socklen_t(text.count))
        }
        return String(cString: text)
    }
}

/// Multiplexed readiness polling across multiple file descriptors.
enum Sockets {
    /// Polls `descriptors` for up to `timeout` seconds and returns a boolean per descriptor indicating read/close readiness.
    static func readable(_ descriptors: [Int32], timeout: Double) -> [Bool] {
        var pollers = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        _ = poll(&pollers, nfds_t(pollers.count), Int32(max(0, timeout) * 1000))
        return pollers.map { $0.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 }
    }
}
