// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Metadata sent along with the frame for compositing
/// (the rendered pose, target display time)
public struct FrameMetadata {
    /// The head pose the host rendered this frame from.
    public let renderPose: Pose
    public let displayTime: UInt32          // host clock, microseconds
    public let atlasWidth, atlasHeight, tileWidth, tileHeight: Int
    /// Per-eye (`[left, right]`) bounds placing the foveal tile inside a virtual
    /// image of the base frustum rendered at foveal pixel density.
    public let insets: [(x: Float, y: Float, virtualWidth: Float, virtualHeight: Float)]

    public init(_ m: Bytes) {
        // A row-major 3x4 at +0x04: columns 0..2 are the head's right, up and
        // back axes in world space, column 3 its position in meters.
        func column(_ c: Int) -> Vec3 {
            Vec3(m.float(at: 0x04 + 4 * c), m.float(at: 0x14 + 4 * c), m.float(at: 0x24 + 4 * c))
        }
        renderPose = Pose(position: column(3), right: column(0), up: column(1), forward: column(2) * -1)
        displayTime = m.integer(at: 0xE0)
        atlasWidth = Int(m.integer(at: 0xE6) as UInt16)
        atlasHeight = Int(m.integer(at: 0xE8) as UInt16)
        tileWidth = Int(m.integer(at: 0xEA) as UInt16)
        tileHeight = Int(m.integer(at: 0xEC) as UInt16)
        insets = [0xC8, 0xD0].map { offset in
            (Float(m.integer(at: offset) as Int16), Float(m.integer(at: offset + 2) as Int16),
             Float(m.integer(at: offset + 4) as Int16), Float(m.integer(at: offset + 6) as Int16))
        }
    }

    /// The frustum the foveal tile of one eye covers, given that eye's base
    /// frustum (docs/svl-video/frame-layout.md).
    public func foveaFrustum(eye: Int, base: Frustum) -> Frustum {
        let inset = insets[eye]
        // Rows from the top of the virtual image down to the optical center,
        // and columns from the optical center to its right edge.
        let rowsAboveCentre = base.up * inset.virtualHeight / (base.up - base.down)
        let columnsRightOfCentre = base.right * inset.virtualWidth / (base.right - base.left)
        let leftColumn = inset.x - inset.virtualWidth + columnsRightOfCentre
        return Frustum(
            left: base.right * leftColumn / columnsRightOfCentre,
            right: base.right * (leftColumn + Float(tileWidth)) / columnsRightOfCentre,
            down: base.up * (rowsAboveCentre - (inset.y + Float(tileHeight))) / rowsAboveCentre,
            up: base.up * (rowsAboveCentre - inset.y) / rowsAboveCentre)
    }

    /// Feathered border of the foveal tile, as a fraction of its width.
    static let foveaFeather: Float = 0.06

    /// Builds the compositing tile layout for this frame: each eye draws its
    /// full-FOV base tile followed by the sharper foveal tile blended on top.
    /// Tiles are stacked vertically in the decoded atlas from top to bottom:
    /// left fovea, left base, right fovea, right base.
    public func layout(profile: DeviceProfile) -> FrameLayout {
        let tiles = Float(atlasHeight / max(1, tileHeight))
        // Rows are pulled in half a texel so that linear filtering does not
        // reach into the neighboring tile.
        let halfTexel = 0.5 / Float(max(1, atlasHeight))
        func tile(_ index: Int, _ frustum: Frustum, feather: Float) -> FrameLayout.Tile {
            FrameLayout.Tile(frustum: frustum, top: Float(index) / tiles + halfTexel,
                             bottom: Float(index + 1) / tiles - halfTexel, feather: feather)
        }
        let views = Eye.allCases.map { eye -> FrameLayout.View in
            let base = profile.eyeFrusta[eye.rawValue]
            // Compute the world-space eye pose the host rendered from by applying the eye-in-head offset to `renderPose`.
            return FrameLayout.View(eye: renderPose.placing(profile.eyesInHead[eye.rawValue]), tiles: [
                tile(eye.rawValue * 2 + 1, base, feather: 0),
                tile(eye.rawValue * 2, foveaFrustum(eye: eye.rawValue, base: base), feather: FrameMetadata.foveaFeather),
            ])
        }
        return FrameLayout(views: views, eyePixels: (atlasWidth, tileHeight))
    }
}

struct FrameDescriptor {
    let frameID: UInt16
    let txTime: UInt32          // host clock when the frame started sending
    let hostClockOffset: Int32  // the host's estimate of (its clock - ours), plus the delay to it
    let frameSize: Int
    let hostVersion: UInt32
    /// Forward error correction mode for the frame's packets (`0x20` is the only mode implemented).
    let fecMode: UInt8
    let metadata: FrameMetadata
    /// Value-transport payload extracted from the descriptor trailer (which follows haptics, stats records, and timing events).
    let valueTransportBytes: Bytes

    init(_ element: SVLElement) {
        // `element.value` is a slice of the datagram; `byte` and `integer(at:)` index relative to `startIndex`.
        let value = element.value
        func byte(_ offset: Int) -> UInt8 { value[value.startIndex + offset] }
        frameID = element.id
        txTime = value.integer(at: 0x00)
        hostClockOffset = value.integer(at: 0x04)
        frameSize = Int(value.integer(at: 0x08) as UInt32)
        let declared = Int(value.integer(at: 0x16) as UInt16)
        let metadataSize = declared == 0 ? 0xF0 : declared
        hostVersion = value.integer(at: 0x18)
        fecMode = value.count > 0x0D ? byte(0x0D) : 0
        metadata = FrameMetadata(Bytes(value.dropFirst(0x20).prefix(metadataSize)))
        // Parse the counted sections in the trailer; any trailing bytes beyond them are uninitialized host memory.
        let trailer = 0x20 + metadataSize
        if value.count >= trailer + 16, byte(trailer + 0x0C) == 3 {
            let records = Int(byte(trailer + 0x0D)), events = Int(byte(trailer + 0x0E))
            let start = trailer + 0x10 + 32 * records + 8 * events
            let end = min(start + Int(byte(trailer + 0x0F)), value.count)
            valueTransportBytes = start < end ? Bytes(value.dropFirst(start).prefix(end - start)) : []
        } else {
            valueTransportBytes = []
        }
    }
}

/// Holds an encoded video frame in a `malloc`-allocated buffer so the
/// decoder can take ownership without copying.
///
/// Video streams run at tens of megabytes per second. Allocating a single
/// buffer up front lets `FrameAssembler` write incoming packets directly
/// into place, after which the decoder claims the pointer via `takeMemory()`
/// and calls `free` when finished.
public final class FrameBuffer {
    private var memory: UnsafeMutablePointer<UInt8>?
    /// Valid frame length in bytes (the underlying allocation may have extra trailing capacity).
    public private(set) var count: Int

    /// Allocates at least `capacity` bytes for a frame of length `count`,
    /// zero-filling any trailing bytes past `count`.
    init(count: Int, capacity: Int) {
        let size = max(capacity, count, 1)
        memory = UnsafeMutableRawPointer(malloc(size)!).assumingMemoryBound(to: UInt8.self)
        self.count = count
        if size > count { (memory! + count).update(repeating: 0, count: size - count) }
    }

    /// Allocates a buffer initialized with a copy of `bytes` (used by tests and non-SVL transports).
    public convenience init(copying bytes: Bytes) {
        self.init(count: bytes.count, capacity: bytes.count)
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { memory!.update(from: base, count: source.count) }
        }
    }

    deinit { free(memory) }

    /// Mutable view of the frame bytes, or empty after ownership has been transferred via `takeMemory()`.
    public var bytes: UnsafeMutableBufferPointer<UInt8> {
        UnsafeMutableBufferPointer(start: memory, count: memory == nil ? 0 : count)
    }

    /// Take ownership of the latest memory pointer.
    /// Caller must `free` the returned buffer, or memory will leak.
    public func takeMemory() -> UnsafeMutableBufferPointer<UInt8>? {
        guard let taken = memory else { return nil }
        memory = nil
        return UnsafeMutableBufferPointer(start: taken, count: count)
    }

    func setCount(_ newCount: Int) { count = newCount }
}

/// A complete encoded frame, ready for the decoder.
public struct EncodedFrame {
    public let frameID: UInt16
    /// Sub-picture index within the frame, for protocols that encode multiple streams per frame.
    public let picture: Int
    public let data: FrameBuffer
    public let layout: FrameLayout

    public init(frameID: UInt16, picture: Int = 0, data: FrameBuffer, layout: FrameLayout) {
        self.frameID = frameID
        self.picture = picture
        self.data = data
        self.layout = layout
    }
}

/// Completed frame payload paired with its parsed `FrameMetadata`.
struct AssembledFrame {
    let frameID: UInt16
    let data: FrameBuffer
    let metadata: FrameMetadata
}

/// Reassembles incoming video packets into complete frames in strict frame-ID order.
///
/// Missing packets in a frame are recovered via FEC when the stripe's parity
/// allows, or requested via retransmission otherwise (docs/svl-video/retransmit.md).
/// Frames are released strictly in frame-ID order because each frame predicts
/// from the previous one.
///
/// If a frame cannot be completed, the assembler abandons it, increments the
/// pose message's reset counter to request a keyframe from the host, and holds
/// output until that keyframe arrives.
final class FrameAssembler {
    static let packetSize = FEC.packetSize
    private static let zeroPacket = Bytes(repeating: 0, count: FEC.packetSize)
    static let firstParityID = 0x800
    /// Sentinel packet ID used in retransmit requests to ask the host to resend the frame descriptor.
    static let descriptorRequestID: UInt16 = 0xFFFF
    static let dataPerGroup = 64
    static let parityPerGroup = 16
    /// Number of recent frames the host retains in its retransmit ring buffer.
    static let frameWindow = 16
    /// Idle time in microseconds before re-requesting missing packets on an incomplete frame.
    static let retryInterval: Int32 = 4000
    static let maxEntriesPerUnpromptedRequest = 20
    /// Expected host pacing interval per video packet, in microseconds.
    static let packetInterval = 104
    /// Maximum time in microseconds a completed frame will wait for an earlier
    /// incomplete frame before giving up.
    static let giveUpAfter: Int32 = 100_000

    private struct Frame {
        var size = 0                         // 0 until known from the descriptor or final short packet
        var metadata: FrameMetadata?
        /// Allocated once `size` is known.
        var buffer: FrameBuffer?
        /// Which data packets are in the buffer.
        var have: Set<Int> = []
        /// Data packets that arrived before the size was known.
        var early: [Int: ByteSlice] = [:]
        var parity: [Int: ByteSlice] = [:]   // keyed by parity index: stripe * 2 (P) or stripe * 2 + 1 (Q)
        var highestGroup = 0
        var lastActivity: Int32 = 0          // last packet received or request sent
        var lastPacket: Int32 = 0            // last packet received
        var complete = false
        var completedAt: Int32 = 0
        /// Whether a decoder can start from this frame
        var isKeyframe = false

        var dataCount: Int { (size + packetSize - 1) / packetSize }

        /// Stores a data packet
        mutating func store(_ index: Int, _ packet: ByteSlice) {
            guard index < dataCount, !have.contains(index) else { return }
            if buffer == nil { buffer = FrameBuffer(count: size, capacity: dataCount * packetSize) }
            let room = min(packet.count, packetSize)
            packet.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    (buffer!.bytes.baseAddress! + index * packetSize).update(from: base, count: room)
                }
            }
            have.insert(index)
        }

        /// Returns a `packetSize` slice for data packet `index` directly from `buffer`
        /// (for a short final packet, this includes the trailing zero padding matching
        /// how the host computed FEC), or nil if the packet has not arrived. Valid only
        /// for the lifetime of `buffer`.
        func packet(_ index: Int) -> UnsafeBufferPointer<UInt8>? {
            guard have.contains(index), let buffer else { return nil }
            return UnsafeBufferPointer(start: buffer.bytes.baseAddress! + index * packetSize, count: packetSize)
        }
    }

    private var frames: [UInt16: Frame] = [:]
    private var newest: UInt16 = 0
    private var next: UInt16?                // the frame id the decoder needs next
    private var waitingForKeyframeSince: Int32?
    private var requests: [SVLElement] = []
    private var ready: [AssembledFrame] = []

    /// Bumped to ask the host for a keyframe (sent in every pose message)
    private(set) var resetCounter: UInt16 = 0
    private(set) var repairedByFEC = 0
    private(set) var packetsRequested = 0
    private(set) var framesAbandoned = 0

    init(now: Int32) { waitingForKeyframeSince = now }

    /// Retransmit requests to send, and frames to decode, since the last call.
    func takeRequests() -> [SVLElement] { defer { requests = [] }; return requests }
    func takeFrames() -> [AssembledFrame] { defer { ready = [] }; return ready }

    // MARK: Input

    func accept(descriptor: FrameDescriptor, group: Int, now: Int32) {
        guard touch(descriptor.frameID, now) else { return }
        frames[descriptor.frameID]?.size = descriptor.frameSize
        frames[descriptor.frameID]?.metadata = descriptor.metadata
        progress(descriptor.frameID, group: group, now: now)
    }

    func accept(packet element: SVLElement, now: Int32) {
        guard touch(element.id, now) else { return }
        let index = Int(element.index)
        let group: Int
        if index < FrameAssembler.firstParityID {
            // A short packet is the frame's last, which gives the size early.
            if element.value.count != FrameAssembler.packetSize, frames[element.id]?.size == 0 {
                frames[element.id]?.size = index * FrameAssembler.packetSize + element.value.count
            }
            if frames[element.id]?.size == 0 {
                frames[element.id]?.early[index] = element.value
            } else {
                frames[element.id]?.store(index, element.value)
            }
            group = index / FrameAssembler.dataPerGroup
        } else {
            let parityIndex = index - FrameAssembler.firstParityID
            frames[element.id]?.parity[parityIndex] = element.value
            group = parityIndex / FrameAssembler.parityPerGroup
        }
        progress(element.id, group: group, now: now)
    }

    /// Periodic maintenance tick: re-requests missing packets on stalled frames
    /// and abandons frames that block newer ones past `giveUpAfter`.
    func tick(now: Int32) {
        for (id, frame) in frames where !frame.complete && now &- frame.lastActivity >= FrameAssembler.retryInterval {
            // While waiting for a keyframe, only request retransmits for the
            // newest few frames. Asking for older frames floods the link with
            // useless resends that delay the incoming keyframe.
            if waitingForKeyframeSince != nil, Int16(bitPattern: newest &- id) > 2 { continue }
            request(id, upToGroup: nil, now: now)
        }
        release(now: now)
    }

    // MARK: Per-frame work

    /// Ensures a tracking entry exists for frame `id`, returning false if the
    /// frame was already delivered to the decoder (for example, trailing parity
    /// packets) or abandoned.
    private func touch(_ id: UInt16, _ now: Int32) -> Bool {
        if let next, Int16(bitPattern: id &- next) < 0 { return false }
        if frames[id] == nil {
            frames[id] = Frame()
            if Int16(bitPattern: id &- newest) > 0 || frames.count == 1 { newest = id }
            // Forget frames the host can no longer resend
            frames = frames.filter { Int16(bitPattern: newest &- $0.key) < Int16(FrameAssembler.frameWindow) }
        }
        frames[id]?.lastActivity = now
        frames[id]?.lastPacket = now
        return true
    }

    private func progress(_ id: UInt16, group: Int, now: Int32) {
        // Remove the frame from the dictionary while mutating it so its state
        // stays uniquely referenced.
        guard var frame = frames.removeValue(forKey: id) else { return }
        guard !frame.complete else {
            frames[id] = frame
            return
        }
        if frame.size > 0 {
            for (index, packet) in frame.early { frame.store(index, packet) }
            frame.early = [:]
            repair(&frame)
            if frame.have.count == frame.dataCount, frame.metadata != nil {
                frame.complete = true
                frame.completedAt = now
                frame.parity = [:]
                frame.isKeyframe = frame.buffer.map { AnnexB.keyframeCodec(UnsafeBufferPointer($0.bytes)) != nil } ?? false
            }
        }
        let reachedNewGroup = group > frame.highestGroup
        frame.highestGroup = max(frame.highestGroup, group)
        frames[id] = frame
        // A packet from a later group means the earlier groups have all been sent.
        if !frame.complete, reachedNewGroup { request(id, upToGroup: group, now: now) }
        release(now: now)
    }

    /// Fill holes in every stripe whose parity makes that possible.
    private func repair(_ frame: inout Frame) {
        let stripes = (frame.dataCount + FEC.dataPerStripe - 1) / FEC.dataPerStripe
        for stripe in 0..<stripes {
            let ids = (0..<FEC.dataPerStripe).map { stripe * FEC.dataPerStripe + $0 }
            let missing = ids.filter { $0 < frame.dataCount && !frame.have.contains($0) }
            let p = frame.parity[stripe * 2], q = frame.parity[stripe * 2 + 1]
            guard !missing.isEmpty, missing.count <= (p == nil ? 0 : 1) + (q == nil ? 0 : 1) else { continue }
            // Read arrived packets directly from the frame buffer; slots past
            // `dataCount` use `zeroPacket` to match the host's FEC padding.
            let rebuilt: [Int: Bytes]? = FrameAssembler.zeroPacket.withUnsafeBufferPointer { zeros in
                FEC.repair(data: ids.map { $0 >= frame.dataCount ? zeros : frame.packet($0) }, p: p, q: q)
            }
            guard let rebuilt else { continue }
            for id in missing {
                guard let packet = rebuilt[id - stripe * FEC.dataPerStripe] else { continue }
                frame.store(id, packet[...])
                repairedByFEC += 1
            }
        }
    }

    /// Ask the host to resend what is missing
    private func request(_ id: UInt16, upToGroup group: Int?, now: Int32) {
        guard let frame = frames[id] else { return }
        var wanted: [UInt16] = []
        if frame.metadata == nil { wanted.append(FrameAssembler.descriptorRequestID) }
        if frame.size > 0 {
            var limit = group.map { min($0 * FrameAssembler.dataPerGroup, frame.dataCount) } ?? frame.dataCount
            if group == nil {
                // On an unprompted timeout, only request missing packets the host
                // should have transmitted by now (paced at one packet per 104 us
                // after `retryInterval`).
                let overdue = Int(now &- frame.lastPacket &- FrameAssembler.retryInterval)
                let budget = max(0, overdue / FrameAssembler.packetInterval)
                let firstMissing = (0..<frame.dataCount).first { !frame.have.contains($0) } ?? frame.dataCount
                limit = min(limit, firstMissing + budget)
            }
            for index in 0..<limit where !frame.have.contains(index) { wanted.append(UInt16(index)) }
        }
        if group == nil { wanted = Array(wanted.prefix(FrameAssembler.maxEntriesPerUnpromptedRequest)) }
        frames[id]?.lastActivity = now
        guard !wanted.isEmpty else { return }
        var value = Bytes()
        for entry in wanted { value.append(integer: entry) }
        requests.append(SVLElement(.retransmitRequest, id: id, value: value))
        packetsRequested += wanted.count
        frames[id]?.lastActivity = now
    }

    // MARK: Ordered release

    private func release(now: Int32) {
        if let since = waitingForKeyframeSince {
            // Take the oldest complete keyframe and start from it.
            let keyframes = frames.filter { $0.value.isKeyframe }
            if let start = keyframes.keys.min(by: { Int16(bitPattern: $0 &- $1) < 0 }) {
                next = start
                frames = frames.filter { Int16(bitPattern: $0.key &- start) >= 0 }
                waitingForKeyframeSince = nil
            } else if now &- since > 500_000 {
                // Still nothing after half a second, ask again
                resetCounter &+= 1
                waitingForKeyframeSince = now
            }
        }
        guard waitingForKeyframeSince == nil, var expected = next else { return }
        while let frame = frames[expected], frame.complete, let data = frame.buffer, let metadata = frame.metadata {
            ready.append(AssembledFrame(frameID: expected, data: data, metadata: metadata))
            frames[expected] = nil
            expected &+= 1
        }
        next = expected
        // Abandon the expected frame if completed newer frames have waited past
        // `giveUpAfter`, or if the host's retransmit window has moved past it.
        // (Uses a simple loop since this runs on every packet.)
        var oldestWait: Int32 = 0
        for (id, frame) in frames where frame.complete && Int16(bitPattern: id &- expected) > 0 {
            oldestWait = max(oldestWait, now &- frame.completedAt)
        }
        let outOfWindow = Int16(bitPattern: newest &- expected) >= Int16(FrameAssembler.frameWindow)
        if oldestWait > FrameAssembler.giveUpAfter || outOfWindow {
            framesAbandoned += 1
            resetCounter &+= 1
            waitingForKeyframeSince = now
            // Buffered delta frames depend on the abandoned frame, so drop
            // everything up to `newest` and wait for the requested keyframe.
            frames = [:]
            next = newest &+ 1
        }
    }
}
