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
    /// Per eye (left, right): where the foveal tile sits in a virtual image of
    /// the base frustum drawn at foveal pixel density.
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
        // Rows from the top of the virtual image down to the optical centre,
        // and columns from the optical centre to its right edge.
        let rowsAboveCentre = base.up * inset.virtualHeight / (base.up - base.down)
        let columnsRightOfCentre = base.right * inset.virtualWidth / (base.right - base.left)
        let leftColumn = inset.x - inset.virtualWidth + columnsRightOfCentre
        return Frustum(
            left: base.right * leftColumn / columnsRightOfCentre,
            right: base.right * (leftColumn + Float(tileWidth)) / columnsRightOfCentre,
            down: base.up * (rowsAboveCentre - (inset.y + Float(tileHeight))) / rowsAboveCentre,
            up: base.up * (rowsAboveCentre - inset.y) / rowsAboveCentre)
    }
}

struct FrameDescriptor {
    let frameID: UInt16
    let txTime: UInt32          // host clock when the frame started sending
    let frameSize: Int
    let hostVersion: UInt32
    /// Which error correction the packets carry; 0x20 is the only one known.
    let fecMode: UInt8
    let metadata: FrameMetadata
    /// After the metadata: haptics, statistics records, timing events, value-transport bytes.
    let valueTransportBytes: Bytes

    init(_ element: SVLElement) {
        let value = element.value
        frameID = element.id
        txTime = value.integer(at: 0x00)
        frameSize = Int(value.integer(at: 0x08) as UInt32)
        let declared = Int(value.integer(at: 0x16) as UInt16)
        let metadataSize = declared == 0 ? 0xF0 : declared
        hostVersion = value.integer(at: 0x18)
        fecMode = value.count > 0x0D ? value[0x0D] : 0
        metadata = FrameMetadata(Bytes(value.dropFirst(0x20).prefix(metadataSize)))
        // The trailer's counted sections; what follows them is stale host memory.
        let trailer = 0x20 + metadataSize
        if value.count >= trailer + 16, value[trailer + 0x0C] == 3 {
            let records = Int(value[trailer + 0x0D]), events = Int(value[trailer + 0x0E])
            let start = trailer + 0x10 + 32 * records + 8 * events
            let end = min(start + Int(value[trailer + 0x0F]), value.count)
            valueTransportBytes = start < end ? Bytes(value[start..<end]) : []
        } else {
            valueTransportBytes = []
        }
    }
}

/// One encoded frame's bytes, in memory from `malloc` that a decoder can
/// take over without copying.
///
/// The frame is megabytes a second of data that every stage would otherwise
/// copy, so it lives in one block from the moment its packets arrive: the
/// assembler writes each packet straight into place, and the decoder takes
/// the block for itself (`takeMemory`) and frees it with `free` when done.
public final class FrameBuffer {
    private var memory: UnsafeMutablePointer<UInt8>?
    /// The frame's length in bytes. The block may be a little larger.
    public private(set) var count: Int

    /// A block with room for `capacity` bytes, holding a frame of `count`.
    init(count: Int, capacity: Int) {
        memory = UnsafeMutableRawPointer(malloc(max(capacity, count, 1))!).assumingMemoryBound(to: UInt8.self)
        self.count = count
    }

    /// A copy of `bytes`; for tests and for frames that do not come from the network.
    public convenience init(copying bytes: Bytes) {
        self.init(count: bytes.count, capacity: bytes.count)
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { memory!.update(from: base, count: source.count) }
        }
    }

    deinit { free(memory) }

    /// The frame, to read or to change in place. Empty once ownership has changed.
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
    public let data: FrameBuffer
    public let metadata: FrameMetadata

    public init(frameID: UInt16, data: FrameBuffer, metadata: FrameMetadata) {
        self.frameID = frameID
        self.data = data
        self.metadata = metadata
    }
}

/// Turns video packets into frames for a decoder, in order.
///
/// A hole in a frame is filled by FEC when the stripe's parity allows, and
/// otherwise asked for again (docs/svl-video/retransmit.md). Frames are
/// released strictly in frame-id order, because each one is predicted from
/// the one before.
///
/// If a frame cannot be completed, the assembler gives up on it, asks the host 
/// for a keyframe through the pose message's reset counter, and releases nothing 
/// until that keyframe arrives.
final class FrameAssembler {
    static let packetSize = FEC.packetSize
    static let firstParityID = 0x800
    /// In a retransmit request, in place of a packet id: "resend the descriptor".
    static let descriptorRequestID: UInt16 = 0xFFFF
    static let dataPerGroup = 64
    static let parityPerGroup = 16
    /// The host keeps a frame for resending only while it is among its last 16.
    static let frameWindow = 16
    /// Microseconds of silence on an incomplete frame before asking again.
    static let retryInterval: Int32 = 4000
    static let maxEntriesPerUnpromptedRequest = 20
    /// Microseconds the host takes per packet when sending a frame.
    static let packetInterval = 104
    /// How long a finished frame may wait for an earlier one before the
    /// earlier one is abandoned.
    static let giveUpAfter: Int32 = 100_000

    private struct Frame {
        var size = 0                         // 0 until the descriptor or the short last packet says
        var metadata: FrameMetadata?
        /// The frame's bytes. Made once the size is known.
        var buffer: FrameBuffer?
        /// Which data packets are in the buffer.
        var have: Set<Int> = []
        /// Data packets that arrived before the size was known.
        var early: [Int: Bytes] = [:]
        var parity: [Int: Bytes] = [:]       // keyed by parity index: stripe * 2 (P) or stripe * 2 + 1 (Q)
        var highestGroup = 0
        var lastActivity: Int32 = 0          // last packet received or request sent
        var lastPacket: Int32 = 0            // last packet received
        var complete = false
        var completedAt: Int32 = 0
        /// Whether a decoder can start from this frame
        var isKeyframe = false

        var dataCount: Int { (size + packetSize - 1) / packetSize }

        /// Stores a data packet
        mutating func store(_ index: Int, _ packet: Bytes) {
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

        /// Pops a data packet out of the buffer, zero-extended to full length.
        /// Returns nil if it has not arrived yet.
        func packet(_ index: Int) -> Bytes? {
            guard have.contains(index), let buffer else { return nil }
            let length = min(packetSize, size - index * packetSize)
            var out = Bytes(UnsafeBufferPointer(start: buffer.bytes.baseAddress! + index * packetSize, count: length))
            out.append(zeros: packetSize - length)
            return out
        }
    }

    private var frames: [UInt16: Frame] = [:]
    private var newest: UInt16 = 0
    private var next: UInt16?                // the frame id the decoder needs next
    private var waitingForKeyframeSince: Int32?
    private var requests: [SVLElement] = []
    private var ready: [EncodedFrame] = []

    /// Bumped to ask the host for a keyframe (sent in every pose message)
    private(set) var resetCounter: UInt16 = 0
    private(set) var repairedByFEC = 0
    private(set) var packetsRequested = 0
    private(set) var framesAbandoned = 0

    init(now: Int32) { waitingForKeyframeSince = now }

    /// Retransmit requests to send, and frames to decode, since the last call.
    func takeRequests() -> [SVLElement] { defer { requests = [] }; return requests }
    func takeFrames() -> [EncodedFrame] { defer { ready = [] }; return ready }

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

    /// Checkup tick, asks again for the tail of frames that have gone quiet,
    /// and abandons frames that are holding up later ones for too long.
    func tick(now: Int32) {
        for (id, frame) in frames where !frame.complete && now &- frame.lastActivity >= FrameAssembler.retryInterval {
            // While nothing can be decoded until a keyframe arrives, only the
            // newest few frames can be that keyframe in time to matter.
            // Chasing every old frame as well floods the host with requests
            // it answers by resending, which crowds out the keyframe itself.
            if waitingForKeyframeSince != nil, Int16(bitPattern: newest &- id) > 2 { continue }
            request(id, upToGroup: nil, now: now)
        }
        release(now: now)
    }

    // MARK: Per-frame work

    /// Makes sure the frame has a slot.
    /// Returns False for a frame the decoder has already been given 
    /// (its parity keeps arriving after its data) or has been abandoned
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
        // The frame is taken out of the table while it is worked on, so that
        // its buffer has one owner and is written in place, never copied.
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
            // Packets past the end of the frame are known zeros, and the short
            // last packet is zero-extended, exactly as the host encoded them.
            let blocks: [Bytes?] = ids.map { id in
                id >= frame.dataCount ? Bytes(repeating: 0, count: FEC.packetSize) : frame.packet(id)
            }
            guard let repaired = FEC.repair(data: blocks, p: p, q: q) else { continue }
            for id in missing {
                frame.store(id, repaired[id - stripe * FEC.dataPerStripe])
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
                // A frame that has gone quiet: ask only for as many of its
                // missing packets as the host should have sent by now, at
                // its pace of one packet every 104 microseconds counted from
                // the end of the quiet interval
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
            ready.append(EncodedFrame(frameID: expected, data: data, metadata: metadata))
            frames[expected] = nil
            expected &+= 1
        }
        next = expected
        // If later frames are finished and have waited too long for this one,
        // or the host can no longer resend it, then it is not coming.
        let waiting = frames.filter { $0.value.complete && Int16(bitPattern: $0.key &- expected) > 0 }
        let oldestWait = waiting.values.map { now &- $0.completedAt }.max() ?? 0
        let outOfWindow = Int16(bitPattern: newest &- expected) >= Int16(FrameAssembler.frameWindow)
        if oldestWait > FrameAssembler.giveUpAfter || outOfWindow {
            framesAbandoned += 1
            resetCounter &+= 1
            waitingForKeyframeSince = now
            // Everything received so far depends on the lost frame.
            // Only frames newer than the newest seen can belong to the fresh keyframe
            frames = [:]
            next = newest &+ 1
        }
    }
}
