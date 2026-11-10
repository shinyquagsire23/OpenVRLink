// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Decoded frames waiting for the display.
///
/// The decoder and the display run on different clocks, so frames arrive a
/// little early or late relative to refreshes. A short queue absorbs that: the
/// display takes the oldest waiting frame at each refresh, shows the previous
/// one again when nothing new has arrived.
public final class DisplayQueue<Frame> {
    /// More than this many waiting frames means the display is behind.
    public static var depth: Int { 2 }

    private let lock = NSLock()
    private var waiting: [Frame] = []
    private var shown: Frame?
    public private(set) var dropped = 0

    public init() {}

    public func push(_ frame: Frame) {
        lock.lock()
        waiting.append(frame)
        if waiting.count > DisplayQueue.depth {
            waiting.removeFirst()
            dropped += 1
        }
        lock.unlock()
    }

    /// Discard all queued frames
    public func clear() {
        lock.lock()
        waiting = []
        shown = nil
        lock.unlock()
    }

    /// The frame to draw at this refresh, and whether it is one not shown before.
    public func next() -> (frame: Frame, isNew: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        if !waiting.isEmpty {
            shown = waiting.removeFirst()
            return (shown!, true)
        }
        return shown.map { ($0, false) }
    }
}
