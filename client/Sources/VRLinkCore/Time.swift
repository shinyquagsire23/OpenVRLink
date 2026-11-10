// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The clock that everything in the core is timed against: nanoseconds since
/// the machine started, not counting time asleep. It never jumps or runs backwards.
public enum Uptime {
    public static var nanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Timestamp helper, call .now() to atomically set a time. One thread can
/// mark that something happened and another ask how long ago that was.
public final class Timestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds = Uptime.nanoseconds

    /// Starts out marked at the time it is made.
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
