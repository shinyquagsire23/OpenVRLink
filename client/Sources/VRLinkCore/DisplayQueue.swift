// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Small FIFO queue between the video decoder and the display refresh loop.
///
/// Because the decoder and display run on independent clocks, decoded frames can arrive
/// slightly early or late relative to vblank. At each refresh, the display pops the oldest
/// queued frame, or repeats the last displayed frame if no new frame has arrived.
public final class DisplayQueue<Frame> {
    /// Maximum number of queued frames before older frames are dropped.
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

    /// Discards all queued frames and resets the last displayed frame.
    public func clear() {
        lock.lock()
        waiting = []
        shown = nil
        lock.unlock()
    }

    /// Returns the frame to render for the current refresh, along with whether it is newly dequeued.
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
