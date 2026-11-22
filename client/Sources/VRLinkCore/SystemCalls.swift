// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// On non-Apple platforms, importing Foundation does not automatically re-export the platform C library
// (`Android` or `Glibc`). Re-exporting it here makes POSIX sockets and C math functions visible across `VRLinkCore`.
#if canImport(Android)
@_exported import Android
#elseif canImport(Glibc)
@_exported import Glibc
#endif

// Thin wrappers around POSIX `connect` and `send` so they are not shadowed by methods of the same name
// on `TCPSocket` and `UDPSocket`.

func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(descriptor, address, length)
}

func systemSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return send(descriptor, bytes, count, flags)
    #else
    // Fail with EPIPE on a closed peer rather than raising SIGPIPE (Darwin sets SO_NOSIGPIPE on the socket instead).
    guard let bytes else { return 0 }
    return send(descriptor, bytes, count, flags | Int32(MSG_NOSIGNAL))
    #endif
}
