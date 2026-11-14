// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A TCP connection that is written to whole and read as it comes.
public final class TCPSocket {
    let descriptor: Int32
    private let sendLock = NSLock()

    /// Connects to `address` (IPv4, in numbers), giving up after `timeout` seconds.
    public init?(address: String, port: UInt16, timeout: Double = 5) {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        if descriptor < 0 { return nil }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &target.sin_addr)
        // Connect without blocking, so that an address nobody answers at does not hold the caller for minutes.
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let started = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
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
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        // A write to a connection the peer has closed is an error here, not a signal that ends the process.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close(descriptor) }

    /// End the connection now, without waiting for this object to go: the peer sees it close.
    public func shutDown() {
        _ = shutdown(descriptor, SHUT_RDWR)
    }

    /// All of `bytes`, or false if the connection is gone. Safe to call from any thread.
    @discardableResult
    public func send(_ bytes: Bytes) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { Foundation.send(descriptor, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if wrote <= 0 { return false }
            sent += wrote
        }
        return true
    }

    /// Whatever has arrived, without waiting. Nil when the peer has closed the connection.
    public func receiveAvailable() -> Bytes? {
        var closed = false
        let bytes = Bytes(unsafeUninitializedCapacity: 64 << 10) { buffer, count in
            let received = recv(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT))
            closed = received == 0 || (received < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            count = max(0, received)
        }
        return closed ? nil : bytes
    }

    /// The IPv4 address of `host`, a name or an address, in numbers.
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

/// Waiting on several sockets at once.
enum Sockets {
    /// Which of `descriptors` can be read, after waiting up to `timeout` seconds for any of them.
    static func readable(_ descriptors: [Int32], timeout: Double) -> [Bool] {
        var pollers = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        _ = poll(&pollers, nfds_t(pollers.count), Int32(max(0, timeout) * 1000))
        return pollers.map { $0.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 }
    }
}
