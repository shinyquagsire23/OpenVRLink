// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Non-blocking logger for latency-sensitive threads.
///
/// Standard output can stall when attached to a debugger or remote console.
/// Session and render threads run on tight millisecond budgets, so log messages
/// are dispatched asynchronously to a background utility queue.
public enum Log {
    private static let queue = DispatchQueue(label: "log", qos: .utility)

    /// Output sink for log messages. Defaults to `print`, and can be overridden at startup on platforms
    /// that route logs to a system logger such as Android `logcat`.
    public nonisolated(unsafe) static var write: (String) -> Void = { print($0) }

    public static func note(_ line: String) {
        queue.async { write(line) }
    }
}
