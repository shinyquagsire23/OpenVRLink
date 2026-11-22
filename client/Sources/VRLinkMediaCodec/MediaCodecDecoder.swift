// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Android)
import CAndroidNDK
import Foundation
import VRLinkCore

/// Wraps a decoded `AImage` and its underlying `AHardwareBuffer` for zero-copy GPU sampling.
///
/// Releasing this object returns the buffer to the `AImageReader` pool, so the renderer must retain it
/// until the GPU finishes sampling the frame.
public final class HardwarePicture {
    /// An `AHardwareBuffer *`.
    public let buffer: OpaquePointer
    private let image: OpaquePointer
    /// Retains the owning `ImageReader` for the lifetime of the acquired `AImage`.
    private let reader: ImageReader

    fileprivate init(image: OpaquePointer, buffer: OpaquePointer, reader: ImageReader) {
        self.image = image
        self.buffer = buffer
        self.reader = reader
        AHardwareBuffer_acquire(buffer)
    }

    deinit {
        AHardwareBuffer_release(buffer)
        AImage_delete(image)
    }
}

/// Decoded video frame backed by Android `AHardwareBuffer` images for `VRLinkVulkan`.
public struct HardwareFrame: StreamFrame {
    public let frameID: UInt16
    public let pictures: [HardwarePicture]
    public let layout: FrameLayout

    public var pictureCount: Int { pictures.count }
}

/// Manages an `AImageReader` surface that receives decoded `AMediaCodec` output as GPU-sampleable hardware buffers.
fileprivate final class ImageReader {
    let handle: OpaquePointer

    init?(width: Int32, height: Int32, pictures: Int32) {
        var made: OpaquePointer?
        // Using AIMAGE_FORMAT_PRIVATE keeps the hardware decoder's native YCbCr layout without an extra copy or conversion.
        let status = AImageReader_newWithUsage(width, height, Int32(AIMAGE_FORMAT_PRIVATE.rawValue),
                                               UInt64(AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE.rawValue), pictures, &made)
        guard status == AMEDIA_OK, let made else { return nil }
        handle = made
    }

    deinit { AImageReader_delete(handle) }
}

/// Decodes video streams on Android using `AMediaCodec` (one decoder instance per stream index) and
/// assembles complete `HardwareFrame` values.
public final class MediaCodecDecoder: StreamDecoder {
    public var onImage: ((HardwareFrame) -> Void)?
    public var onFailure: ((UInt16, Int) -> Void)?

    private var decoders: [PictureCodec] = []
    private let assembler = PictureAssembler<HardwarePicture>()

    public init() {}

    public func reset() {
        decoders.forEach { $0.stop() }
        decoders = []
        assembler.reset()
    }

    public func decode(_ frame: EncodedFrame) {
        while decoders.count <= frame.picture {
            let picture = decoders.count
            let decoder = PictureCodec(picture: picture)
            decoder.onPicture = { [weak self] frameID, decoded, layout in
                guard let self, let whole = assembler.add(decoded, index: picture, frameID: frameID, of: layout.pictures) else { return }
                onImage?(HardwareFrame(frameID: frameID, pictures: whole, layout: layout))
            }
            decoder.onFailure = { [weak self] frameID in self?.onFailure?(frameID, picture) }
            decoders.append(decoder)
        }
        decoders[frame.picture].decode(frame)
    }
}

/// Manages a single `AMediaCodec` instance and its output `ImageReader` for one video stream.
///
/// Compressed access units are queued on the caller's thread, while a dedicated drain thread dequeues
/// decoded output buffers and renders them onto the `ImageReader` surface.
final class PictureCodec {
    var onPicture: ((UInt16, HardwarePicture, FrameLayout) -> Void)?
    var onFailure: ((UInt16) -> Void)?

    private let picture: Int
    private var codec: OpaquePointer?
    private var reader: ImageReader?
    private var kind: VideoCodec?
    private var complained = false

    private let lock = NSLock()
    /// In-flight frame metadata keyed by synthetic input presentation timestamp (in microseconds).
    private var pending: [Int64: (frameID: UInt16, layout: FrameLayout)] = [:]
    private var sequence: Int64 = 0
    /// Incremented on `stop()` and `start()` so previous drain threads exit cleanly.
    private var generation = 0

    /// Maximum concurrent acquired images across the display queue, active GPU frame, and multi-picture assembly.
    private static let picturesOut: Int32 = 10
    /// Timeout in microseconds when dequeuing an input buffer before dropping the frame.
    private static let inputWait: Int64 = 20_000

    init(picture: Int) {
        self.picture = picture
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        generation += 1
        let old = codec
        codec = nil
        reader = nil
        pending = [:]
        kind = nil
        lock.unlock()
        guard let old else { return }
        AMediaCodec_stop(old)
        AMediaCodec_delete(old)
    }

    private static func mime(_ kind: VideoCodec) -> String {
        switch kind {
        case .hevc: return "video/hevc"
        case .h264: return "video/avc"
        case .av1: return "video/av01"
        }
    }

    /// Configures and starts an `AMediaCodec` decoder for `kind`. Because SPS/PPS/VPS parameter sets arrive
    /// in-band, initial dimensions use a 2048x2048 placeholder alongside `MAX_WIDTH`/`MAX_HEIGHT` until the
    /// codec parses the bitstream.
    ///
    /// TODO: Parse coded dimensions from the H.264/HEVC SPS or AV1 sequence header in `VRLinkCore` for
    /// devices whose decoders require exact initial dimensions.
    private func start(_ kind: VideoCodec) -> Bool {
        let (width, height): (Int32, Int32) = (2048, 2048)
        guard let reader = ImageReader(width: width, height: height, pictures: PictureCodec.picturesOut) else {
            Log.note("decoder: failed to create AImageReader")
            return false
        }
        var listener = AImageReader_ImageListener(context: Unmanaged.passUnretained(self).toOpaque()) { context, reader in
            guard let context else { return }
            Unmanaged<PictureCodec>.fromOpaque(context).takeUnretainedValue().imageAvailable()
        }
        AImageReader_setImageListener(reader.handle, &listener)
        var window: OpaquePointer?
        guard AImageReader_getWindow(reader.handle, &window) == AMEDIA_OK, let window else { return false }

        guard let made = AMediaCodec_createDecoderByType(PictureCodec.mime(kind)) else {
            Log.note("decoder: no hardware decoder available for \(kind.rawValue)")
            return false
        }
        let format = AMediaFormat_new()
        defer { AMediaFormat_delete(format) }
        AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, PictureCodec.mime(kind))
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width)
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height)
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_MAX_WIDTH, 8192)
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_MAX_HEIGHT, 8192)
        // Request low-latency output so frames are emitted immediately without B-frame reordering buffering.
        AMediaFormat_setInt32(format, "low-latency", 1)
        AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_PRIORITY, 0)
        AMediaFormat_setInt32(format, "vendor.qti-ext-dec-low-latency.enable", 1)
        var status = AMediaCodec_configure(made, format, window, nil, 0)
        if status == AMEDIA_OK { status = AMediaCodec_start(made) }
        guard status == AMEDIA_OK else {
            Log.note("decoder: failed to start \(kind.rawValue) decoder (status \(status.rawValue))")
            AMediaCodec_delete(made)
            return false
        }
        lock.lock()
        codec = made
        self.reader = reader
        self.kind = kind
        generation += 1
        let mine = generation
        lock.unlock()
        nonisolated(unsafe) let draining = made
        let thread = Thread { [weak self] in self?.drain(draining, generation: mine) }
        thread.name = "decoder output \(picture)"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func decode(_ frame: EncodedFrame) {
        let bytes = UnsafeBufferPointer(frame.data.bytes)
        if let seen = AnnexB.keyframeCodec(bytes), seen != kind {
            Log.note(kind == nil ? "decoder: starting \(seen.rawValue) stream" : "decoder: switching codec to \(seen.rawValue)")
            stop()
            guard start(seen) else {
                onFailure?(frame.frameID)
                return
            }
        }
        guard let codec else {
            if !complained {
                complained = true
                Log.note("decoder: waiting for a keyframe")
            }
            return
        }
        // AMediaCodec accepts H.264 and HEVC access units directly in Annex B format (with in-band parameter
        // sets) and AV1 frames as raw OBUs.
        let index = AMediaCodec_dequeueInputBuffer(codec, PictureCodec.inputWait)
        var capacity = 0
        guard index >= 0, let input = AMediaCodec_getInputBuffer(codec, index, &capacity), capacity >= bytes.count,
              let source = bytes.baseAddress
        else {
            Log.note("decoder: no input buffer available for frame \(frame.frameID) (\(bytes.count) bytes)")
            onFailure?(frame.frameID)
            return
        }
        input.update(from: source, count: bytes.count)
        lock.lock()
        sequence += 1
        let stamp = sequence
        pending[stamp] = (frame.frameID, frame.layout)
        // Bound the pending map in case the hardware decoder drops frames without emitting output.
        if pending.count > 64 { pending = pending.filter { $0.key > stamp - 32 } }
        lock.unlock()
        if AMediaCodec_queueInputBuffer(codec, index, 0, bytes.count, UInt64(stamp), 0) != AMEDIA_OK {
            onFailure?(frame.frameID)
        }
    }

    /// Dequeues decoded buffers and releases them to the `ImageReader` surface until the codec stops.
    private func drain(_ codec: OpaquePointer, generation mine: Int) {
        var info = AMediaCodecBufferInfo()
        while true {
            lock.lock()
            let current = generation == mine
            lock.unlock()
            guard current else { return }
            let index = AMediaCodec_dequeueOutputBuffer(codec, &info, 10_000)
            if index >= 0 {
                AMediaCodec_releaseOutputBuffer(codec, index, true)
            } else if index == Int(AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                let format = AMediaCodec_getOutputFormat(codec)
                var width: Int32 = 0, height: Int32 = 0
                AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_WIDTH, &width)
                AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_HEIGHT, &height)
                AMediaFormat_delete(format)
                Log.note("decoder output: \(width)x\(height)")
            } else if index != Int(AMEDIACODEC_INFO_TRY_AGAIN_LATER), index != Int(AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
                // Exit the drain loop once the codec stops or encounters an unrecoverable error.
                return
            }
        }
    }

    /// Callback invoked by `AImageReader` when a decoded image is ready to acquire.
    private func imageAvailable() {
        lock.lock()
        let reader = self.reader
        lock.unlock()
        guard let reader else { return }
        var image: OpaquePointer?
        guard AImageReader_acquireNextImage(reader.handle, &image) == AMEDIA_OK, let image else { return }
        var nanoseconds: Int64 = 0
        var buffer: OpaquePointer?
        AImage_getTimestamp(image, &nanoseconds)
        guard AImage_getHardwareBuffer(image, &buffer) == AMEDIA_OK, let buffer else {
            AImage_delete(image)
            return
        }
        let decoded = HardwarePicture(image: image, buffer: buffer, reader: reader)
        // AMediaCodec input timestamps are in microseconds, while AImage timestamps are reported in nanoseconds.
        lock.lock()
        let frame = pending.removeValue(forKey: nanoseconds / 1000)
        lock.unlock()
        guard let frame else { return }
        onPicture?(frame.frameID, decoded, frame.layout)
    }
}
#endif
