// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Log lines from threads that must not wait.
///
/// Writing a line can block for a long time when the output is a debugger
/// or a remote console. The session and display threads work to a deadline
/// of a few milliseconds, so they hand their lines to a queue and carry on.
public enum Log {
    private static let queue = DispatchQueue(label: "log", qos: .utility)

    public static func note(_ line: String) {
        queue.async { print(line) }
    }
}
