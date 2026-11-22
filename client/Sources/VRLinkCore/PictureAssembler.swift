// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Collects decoded images belonging to the same multi-stream video frame (such as WiVRn's separate
/// left-eye, right-eye, and alpha streams) across platform decoder types.
///
/// Individual streams may finish decoding out of order and on different threads. Once all images for a
/// `frameID` arrive, `add` returns the completed array in stream-index order and discards any older
/// incomplete frames.
///
/// Note: `VRLinkVideoToolbox.VideoDecoder` predates `PictureAssembler` and maintains its own `CVPixelBuffer`
/// assembly logic.
public final class PictureAssembler<Picture> {
    private let lock = NSLock()
    /// Incomplete frames awaiting remaining stream images, ordered oldest first.
    private var waiting: [(frameID: UInt16, pictures: [Int: Picture])] = []
    /// Maximum number of incomplete frames buffered before dropping the oldest.
    static var framesWaiting: Int { 4 }

    public init() {}

    public func reset() {
        lock.lock()
        waiting = []
        lock.unlock()
    }

    /// Records decoded image `index` for `frameID` (expecting `count` total images) and returns the ordered
    /// images once the frame is complete.
    public func add(_ picture: Picture, index: Int, frameID: UInt16, of count: Int) -> [Picture]? {
        if count <= 1 { return [picture] }
        lock.lock()
        defer { lock.unlock() }
        let place = waiting.firstIndex { $0.frameID == frameID } ?? waiting.count
        if place == waiting.count { waiting.append((frameID, [:])) }
        waiting[place].pictures[index] = picture
        if waiting[place].pictures.count == count {
            let whole = (0..<count).compactMap { waiting[place].pictures[$0] }
            waiting.removeFirst(place + 1)
            return whole.count == count ? whole : nil
        }
        if waiting.count > PictureAssembler.framesWaiting { waiting.removeFirst() }
        return nil
    }
}
