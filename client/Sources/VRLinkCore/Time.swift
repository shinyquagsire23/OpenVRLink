// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Monotonic system uptime in nanoseconds (excluding sleep), used as the
/// shared timebase across `VRLinkCore`.
public enum Uptime {
    public static var nanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Thread-safe monotonic timestamp for recording an event on one thread and
/// checking elapsed time from another.
public final class Timestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds = Uptime.nanoseconds

    /// Initializes the timestamp to the current uptime.
    public init() {}

    public func now() {
        lock.lock()
        nanoseconds = Uptime.nanoseconds
        lock.unlock()
    }

    public func secondsSince() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(Uptime.nanoseconds &- nanoseconds) / 1e9
    }
}
