// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The value-transport system (docs/svl-values/value-transport-wire-format.md).
/// Each side publishes values by id in 128-byte chunks and repeats every chunk
/// until the peer ACKs it. Its bytes ride alongside the pose message going up and
/// inside type-0x0d messages and frame descriptors coming down.

public final class ValueTransport {
    static let chunkSize = 128
    static let maxValue = 0x80_0000

    private struct Outgoing {
        var data: Bytes
        var version: UInt8
        var unacked: Set<Int>
    }

    private struct Incoming {
        var version: UInt8
        var data: Bytes
        var missing: Set<Int>
    }

    private var local: [UInt8: Outgoing] = [:]
    private var staged: [UInt8: Bytes] = [:]
    private var acksOwed: [(version: UInt8, id: UInt8, chunk: UInt16)] = []
    private var inProgress: [UInt8: Incoming] = [:]
    /// Complete values received from the peer.
    public private(set) var remote: [UInt8: (version: UInt8, data: Bytes)] = [:]

    public init() {}

    private static func chunkCount(_ size: Int) -> Int { (size + chunkSize - 1) / chunkSize }

    /// Set a local value. An unchanged value is not sent again unless forced
    /// (vrlink calls a forced update an event).
    public func publish(_ id: UInt8, _ data: Bytes, force: Bool = false) {
        if !force, staged[id] == nil, let current = local[id], current.data == data { return }
        staged[id] = data
    }

    /// Send every value again under a new version. The reference client does
    /// this when the host's instance id changes or the host asks for a refresh.
    public func republishAll() {
        for (id, outgoing) in local where staged[id] == nil { staged[id] = outgoing.data }
    }

    /// Bytes to attach to the next pose message: acks first, then every
    /// unacked chunk that fits.
    public func tick(budget: Int) -> Bytes {
        for (id, data) in staged {
            if let current = local[id], !current.unacked.isEmpty { continue }   // previous value still in flight
            let version = local[id].map { ($0.version + 1) & 0x7F } ?? 1
            local[id] = Outgoing(data: data, version: version,
                                 unacked: Set(0..<ValueTransport.chunkCount(data.count)))
            staged[id] = nil
        }
        var out = Bytes()
        while let ack = acksOwed.first, out.count + 4 <= budget {
            out.append(ack.version)
            out.append(ack.id)
            out.append(integer: ack.chunk)
            acksOwed.removeFirst()
        }
        for id in local.keys.sorted() {
            guard let outgoing = local[id] else { continue }
            for chunk in outgoing.unacked.sorted() {
                let start = chunk * ValueTransport.chunkSize
                let piece = outgoing.data[start..<min(start + ValueTransport.chunkSize, outgoing.data.count)]
                if out.count + 8 + piece.count > budget { return out }
                out.append(0x80 | outgoing.version)
                out.append(id)
                out.append(integer: UInt16(chunk))
                out.append(integer: UInt32(outgoing.data.count))
                out.append(contentsOf: piece)
            }
        }
        return out
    }

    /// Parse value-transport bytes from the peer. Returns the ids whose value
    /// completed with this call.
    public func receive(_ buffer: Bytes) -> [UInt8] {
        var completed: [UInt8] = []
        var offset = 0
        while offset + 4 <= buffer.count {
            let first = buffer[offset], id = buffer[offset + 1]
            let chunk = Int(buffer.integer(at: offset + 2) as UInt16)
            let version = first & 0x7F
            if first & 0x80 == 0 {                       // an ack for one of our chunks
                if local[id]?.version == version { local[id]?.unacked.remove(chunk) }
                offset += 4
                continue
            }
            guard offset + 8 <= buffer.count else { break }
            let total = Int(buffer.integer(at: offset + 4) as UInt32)
            guard total <= ValueTransport.maxValue, total > chunk * ValueTransport.chunkSize else { break }
            let size = min(ValueTransport.chunkSize, total - chunk * ValueTransport.chunkSize)
            guard offset + 8 + size <= buffer.count else { break }
            let piece = buffer[offset + 8..<offset + 8 + size]
            offset += 8 + size
            // Ack every data chunk, duplicates and unknown ids included, or
            // the host repeats it forever.
            acksOwed.append((version, id, UInt16(chunk)))
            var incoming: Incoming
            // Taken out of the table while it is written to, so that its
            // bytes have one owner and the chunk goes in without a copy
            // of the whole value.
            if let current = inProgress[id], current.version == version {
                incoming = current
                inProgress[id] = nil
            } else {
                if inProgress[id] == nil, remote[id]?.version == version { continue }   // duplicate of a finished value
                incoming = Incoming(version: version, data: Bytes(repeating: 0, count: total),
                                    missing: Set(0..<ValueTransport.chunkCount(total)))
            }
            if incoming.missing.remove(chunk) != nil {
                incoming.data.replaceSubrange(chunk * ValueTransport.chunkSize..<chunk * ValueTransport.chunkSize + size,
                                              with: piece)
            }
            if incoming.missing.isEmpty {
                remote[id] = (version, incoming.data)
                inProgress[id] = nil
                completed.append(id)
            } else {
                inProgress[id] = incoming
            }
        }
        return completed
    }
}
