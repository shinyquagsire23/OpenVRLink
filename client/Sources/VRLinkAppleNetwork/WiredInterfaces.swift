// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network

/// Find wired ethernet for lower latency
public enum WiredInterfaces {
    /// Names ("en5") of the wired Ethernet interfaces that are up now.
    public static func names() -> [String] {
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        let answered = DispatchSemaphore(value: 0)
        var names: [String] = []
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied {
                names = path.availableInterfaces.filter { $0.type == .wiredEthernet }.map(\.name)
            }
            answered.signal()
        }
        monitor.start(queue: DispatchQueue(label: "wired-interfaces"))
        _ = answered.wait(timeout: .now() + 0.5)
        monitor.cancel()
        return names
    }
}
