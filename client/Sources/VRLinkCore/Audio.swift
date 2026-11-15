// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The host streams audio as raw interleaved 16-bit 48 kHz stereo PCM in groups
/// of two data packets (A and B) plus an XOR parity packet that can recover
/// either one (docs/svl-audio/).

/// Ring buffer for incoming PCM audio. The network delivers audio in bursts while
/// the audio device consumes it steadily, so this provides a small jitter buffer.
public final class PlaybackBuffer {
    public static let sampleRate = 48_000
    public static let channels = 2

    /// Playback starts (and restarts after running dry) only when this many audio frames are buffered
    static let startThreshold = sampleRate * 30 / 1000 // 30ms
    /// Maximum number of audio frames that can be built up before the oldest audio needs to be dropped
    static let maximum = sampleRate * 120 / 1000 // 120ms

    private let lock = NSLock()
    /// Ring buffer of interleaved samples containing `stored` elements starting at
    /// `oldest` and wrapping around at the end. Playing audio advances indices in
    /// place without shifting elements or allocating on the audio thread.
    private var ring = [Int16](repeating: 0, count: PlaybackBuffer.maximum * PlaybackBuffer.channels)
    private var oldest = 0, stored = 0
    private var playing = false
    public private(set) var underruns = 0
    public private(set) var overflows = 0

    public init() {}

    func write(_ pcm: ByteSlice) {
        lock.lock()
        defer { lock.unlock() }
        // If the ring buffer overflows, drop the oldest samples down to the start
        // threshold to shed accumulated latency in one step.
        let arriving = pcm.count / 2
        if stored + arriving > ring.count {
            let kept = min(stored, PlaybackBuffer.startThreshold * PlaybackBuffer.channels)
            oldest = (oldest + stored - kept) % ring.count
            stored = kept
            overflows += 1
        }
        var index = pcm.startIndex
        var slot = (oldest + stored) % ring.count
        for _ in 0..<min(arriving, ring.count - stored) {
            ring[slot] = Int16(bitPattern: UInt16(pcm[index]) | UInt16(pcm[index + 1]) << 8)
            index += 2
            slot = slot + 1 == ring.count ? 0 : slot + 1
            stored += 1
        }
    }

    /// Fill `output` for the audio device
    public func read(into output: UnsafeMutableBufferPointer<Int16>) {
        lock.lock()
        defer { lock.unlock() }
        if !playing, stored >= PlaybackBuffer.startThreshold * PlaybackBuffer.channels { playing = true }
        guard playing, stored >= output.count else {
            if playing, stored > 0 { underruns += 1 }
            playing = false
            for index in output.indices { output[index] = 0 }
            return
        }
        for index in output.indices {
            output[index] = ring[oldest]
            oldest = oldest + 1 == ring.count ? 0 : oldest + 1
        }
        stored -= output.count
    }
}

/// Reassembles the incoming audio stream, using the XOR parity packet to recover
/// a single lost data packet per group.
final class AudioReceiver {
    let buffer = PlaybackBuffer()
    private(set) var recovered = 0
    private(set) var lost = 0

    private struct Group {
        var number: Int
        var a: ByteSlice?
        var b: ByteSlice?
        var parity: (payload: ByteSlice, shorterLength: Int)?
        var aPlayed = false
        var bPlayed = false
    }

    private var group: Group?
    private var reportedFormat: UInt16 = 0
    var onLog: ((String) -> Void)?

    /// Accepts a class 0x0b / 0x0c audio message.
    /// `id` is the sequence number, and `index` is either the format word (for data packets)
    /// or the length of the shorter data packet (for parity packets).
    func accept(_ element: SVLElement) {
        let position = Int(element.id) % 3
        let number = Int(element.id) / 3
        if group?.number != number {
            finish()
            group = Group(number: number)
        }
        switch position {
        case 0:
            noteFormat(element.index)
            group?.a = element.value
        case 1:
            noteFormat(element.index)
            group?.b = element.value
        default:
            // Variable-length parity packets store the shorter data packet's length in index.
            let shorter = element.kind == .audioVariable ? Int(element.index) : element.value.count
            group?.parity = (element.value, shorter)
        }
        play()
    }

    private func noteFormat(_ word: UInt16) {
        guard word != reportedFormat else { return }
        reportedFormat = word
        let rate = Int(word >> 2) * 10, channels = Int(word & 3) + 1
        if rate != PlaybackBuffer.sampleRate || channels != PlaybackBuffer.channels {
            onLog?("audio: host sends \(rate) Hz, \(channels) channels; only 48000 Hz stereo is handled")
        }
    }

    /// Reconstructs a missing data packet (A or B) by XORing the other data packet with the parity packet.
    private func rebuild(from other: ByteSlice, parity: (payload: ByteSlice, shorterLength: Int)) -> ByteSlice {
        // The two data packets have lengths max = parity length and min = shorterLength.
        let length = other.count == parity.payload.count ? parity.shorterLength : parity.payload.count
        var out = Bytes(parity.payload)
        for (index, byte) in other.prefix(out.count).enumerated() { out[index] ^= byte }
        recovered += 1
        return out.prefix(length)
    }

    /// Queues available packets in order (A, then B), reconstructing a missing packet if possible.
    private func play() {
        guard var current = group else { return }
        if !current.aPlayed {
            if current.a == nil, let b = current.b, let parity = current.parity {
                current.a = rebuild(from: b, parity: parity)
            }
            if let a = current.a {
                buffer.write(a)
                current.aPlayed = true
            }
        }
        if current.aPlayed, !current.bPlayed {
            if current.b == nil, let a = current.a, let parity = current.parity {
                current.b = rebuild(from: a, parity: parity)
            }
            if let b = current.b {
                buffer.write(b)
                current.bPlayed = true
            }
        }
        group = current
    }

    private func finish() {
        guard let current = group else { return }
        if !current.aPlayed { lost += 1 }
        if !current.bPlayed {
            if let b = current.b { buffer.write(b) } else { lost += 1 }
        }
    }
}

/// Audio format used for microphone capture across protocols: 48 kHz little-endian
/// signed 16-bit mono PCM.
public enum MicrophoneFormat {
    public static let sampleRate = 48_000
    static let bytesPerSecond = sampleRate * 2
}

/// Receives captured microphone samples formatted as `MicrophoneFormat`.
/// Implementations must be safe to call from a real-time audio thread.
public protocol MicrophoneSink: AnyObject {
    func capture(_ samples: Bytes)
}

/// Thread-safe buffer for outgoing microphone audio. The audio thread appends samples,
/// which are split into packet-sized chunks and drained by the session thread.
/// If a session stalls and the buffer exceeds its capacity, the oldest chunks are dropped
/// rather than sending stale audio.
public final class MicrophoneQueue: MicrophoneSink {
    private let lock = NSLock()
    private var waiting: [Bytes] = []
    private var bytesWaiting = 0
    private let largestPacket: Int, most: Int

    /// `largestPacket` is the maximum chunk size in bytes (must be a multiple of the sample size).
    /// `most` is the maximum number of buffered bytes to retain before dropping the oldest chunks.
    init(largestPacket: Int, most: Int) {
        self.largestPacket = largestPacket
        self.most = most
    }

    public func capture(_ samples: Bytes) {
        lock.lock()
        defer { lock.unlock() }
        for start in stride(from: 0, to: samples.count, by: largestPacket) {
            waiting.append(Bytes(samples[start..<min(start + largestPacket, samples.count)]))
        }
        bytesWaiting += samples.count
        while bytesWaiting > most, let oldest = waiting.first {
            bytesWaiting -= oldest.count
            waiting.removeFirst()
        }
    }

    /// Drains and returns all buffered audio chunks captured since the last call.
    func take() -> [Bytes] {
        lock.lock()
        defer { lock.unlock() }
        let out = waiting
        waiting = []
        bytesWaiting = 0
        return out
    }
}

/// Formats microphone audio for VR Link (Steam): splits samples into packets of up to 1024 bytes
/// and inserts an XOR parity packet after every pair of data packets.
/// Audio is queued on the audio thread and packetized on the session thread.
public final class MicrophoneUplink: MicrophoneSink {
    /// Format word for 48 kHz mono: `(channels - 1) | (rate / 10) << 2`.
    static let formatWord: UInt16 = UInt16(MicrophoneFormat.sampleRate / 10) << 2
    static let largestPacket = 1024

    /// Buffer at most one second of audio if the session stalls.
    private let queue = MicrophoneQueue(largestPacket: largestPacket, most: MicrophoneFormat.bytesPerSecond)
    private var sequence: UInt16 = 0
    private var first: Bytes? // the first data packet of the pair being built

    public init() {}

    public func capture(_ samples: Bytes) { queue.capture(samples) }

    /// Drains queued audio and returns SVL packets ready to send to the host.
    /// Must only be called from the session thread.
    func takePackets() -> [SVLElement] {
        var out: [SVLElement] = []
        for payload in queue.take() {
            out.append(SVLElement(.audioVariable, id: sequence, index: MicrophoneUplink.formatWord, value: payload))
            sequence &+= 1
            guard let a = first else {
                first = payload
                continue
            }
            // Parity packet
            var parity = Bytes(repeating: 0, count: max(a.count, payload.count))
            for index in a.indices { parity[index] ^= a[index] }
            for index in payload.indices { parity[index] ^= payload[index] }
            out.append(SVLElement(.audioVariable, id: sequence, index: UInt16(min(a.count, payload.count)), value: parity))
            sequence &+= 1
            if sequence == 0xFFFF { sequence = 0 } // multiple of 3, so the pairs stay aligned
            first = nil
        }
        return out
    }
}
