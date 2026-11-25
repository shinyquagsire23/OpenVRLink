// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreMedia
import VideoToolbox
import VRLinkCore

// VideoToolbox decoding for HEVC, H.264, and AV1 streams. The active codec is
// detected from the stream's first keyframe.
//
// We leave the output pixel format unspecified so VideoToolbox does not convert
// formats (which also forces a buffer copy on visionOS). Native biplanar YCbCr
// hardware buffers go straight to Metal, where the sampler converts them to RGB.
/// A decoded video frame backed by GPU-resident VideoToolbox pixel buffers.
/// VR Link sends a single atlas image per frame containing all tiles, while
/// WiVRn sends one image per eye (plus optional alpha).
public struct DecodedFrame {
    public let frameID: UInt16
    public let images: [CVPixelBuffer]
    public let layout: FrameLayout

    public init(frameID: UInt16, images: [CVPixelBuffer], layout: FrameLayout) {
        self.frameID = frameID
        self.images = images
        self.layout = layout
    }
}

/// Decodes encoded video pictures into complete `DecodedFrame` values.
/// Maintains one `PictureDecoder` per picture index in the stream layout and
/// emits a frame once all of its constituent pictures have finished decoding.
public final class VideoDecoder {
    public var onImage: ((DecodedFrame) -> Void)?
    /// Called on the `decode` caller's thread when picture 0's video format
    /// description is first determined and whenever it changes.
    public var onFormat: ((CMVideoFormatDescription) -> Void)?

    /// Called with the frame ID and picture index when decoding fails so the
    /// session can request a new keyframe from the host.
    public var onFailure: ((UInt16, Int) -> Void)?

    public init() {}

    /// Resets all decoder state before starting a new stream. Each stream
    /// starts from a keyframe with fresh decompression sessions, because
    /// sessions invalidated by the system while the app was backgrounded
    /// silently drop frames without producing output.
    public func reset() {
        decoders = []
        assembler.reset()
    }

    private var decoders: [PictureDecoder] = []
    /// Gathers the pictures of multi-picture frames; incomplete frames are dropped as lost.
    private let assembler = PictureAssembler<CVPixelBuffer>()

    public func decode(_ frame: EncodedFrame) {
        while decoders.count <= frame.picture {
            let picture = decoders.count
            let decoder = PictureDecoder()
            decoder.onImage = { [weak self] frameID, image, layout in
                self?.decoded(frameID, picture: picture, image, layout)
            }
            decoder.onFailure = { [weak self] frameID in self?.onFailure?(frameID, picture) }
            if picture == 0 { decoder.onFormat = { [weak self] in self?.onFormat?($0) } }
            decoders.append(decoder)
        }
        decoders[frame.picture].decode(frame)
    }

    private func decoded(_ frameID: UInt16, picture: Int, _ image: CVPixelBuffer, _ layout: FrameLayout) {
        guard let whole = assembler.add(image, index: picture, frameID: frameID, of: layout.pictures) else { return }
        onImage?(DecodedFrame(frameID: frameID, images: whole, layout: layout))
    }
}

extension DecodedFrame: StreamFrame {
    public var pictureCount: Int { images.count }
}

extension VideoDecoder: StreamDecoder {}

final class PictureDecoder {
    var onImage: ((UInt16, CVPixelBuffer, FrameLayout) -> Void)?
    var onFailure: ((UInt16) -> Void)?
    /// Called on the `decode` caller's thread when the stream format is first
    /// determined and whenever it changes.
    var onFormat: ((CMVideoFormatDescription) -> Void)?

    init() {}

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var codec: VideoCodec?
    private var parameterSets: [UInt8: Bytes] = [:]      // NAL type -> bytes
    private var complainedAboutStream = false
    private var described = 0
    private var printedParameterSets = false
    private var av1Format: CMVideoFormatDescription?

    /// Extracts the NAL unit type from `header` and indicates whether it is a parameter set.
    private static func classify(_ header: UInt8, _ codec: VideoCodec) -> (type: UInt8, isParameterSet: Bool) {
        switch codec {
        case .hevc:
            let type = hevcNalType(header)
            return (type, (HEVC_NAL_TYPE_VPS...HEVC_NAL_TYPE_PPS).contains(type))
        case .h264:
            let type = h264NalType(header)
            return (type, type == H264_NAL_TYPE_SPS || type == H264_NAL_TYPE_PPS)
        case .av1:
            return (0, false)                            // AV1 has no NAL units; see `decode`
        }
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        guard let codec else { return nil }
        if codec == .av1 { return av1Format }
        let needed: [UInt8] = codec == .hevc ? [HEVC_NAL_TYPE_VPS, HEVC_NAL_TYPE_SPS, HEVC_NAL_TYPE_PPS]
                                              : [H264_NAL_TYPE_SPS, H264_NAL_TYPE_PPS]
        let sets = needed.compactMap { parameterSets[$0] }
        guard sets.count == needed.count else { return nil }
        // Core Media wants C pointers to every set at once; copies with stable addresses are simplest.
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            copy.initialize(from: set, count: set.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }, sizes = sets.map(\.count)
        var format: CMVideoFormatDescription?
        switch codec {
        case .hevc:
            _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        case .h264:
            _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .av1:
            break
        }
        return format
    }

    /// Updates the format description from the latest parameter sets. Hosts
    /// may send updated parameter sets mid-stream (for example, during rate
    /// control); if the existing decompression session can accept the new
    /// format description, we reuse it to preserve reference frames.
    private func parameterSetsChanged() {
        guard let newFormat = makeFormat() else { return }
        format = newFormat
        onFormat?(newFormat)
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            return
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: newFormat, decoderSpecification: nil,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        if let session, status == noErr {
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        } else {
            Log.note("decoder: could not create a decompression session (\(status))")
        }
    }

    private var failures = 0
    private func noteFailure(_ status: OSStatus) {
        failures += 1
        if failures == 1 || failures % 200 == 0 { Log.note("decoder: \(failures) frames could not be decoded (latest status \(status))") }
    }

    /// Decodes a single encoded frame. Takes ownership of `frame.data`'s
    /// buffer and passes it directly to VideoToolbox without copying, so each
    /// `EncodedFrame` can only be decoded once.
    func decode(_ frame: EncodedFrame) {
        let whole = UnsafeBufferPointer(frame.data.bytes)
        if let seen = AnnexB.keyframeCodec(whole), seen != codec {
            if let codec { Log.note("decoder: the stream changed from \(codec.rawValue) to \(seen.rawValue)") }
            else { Log.note("decoder: the stream is \(seen.rawValue)") }
            codec = seen
            parameterSets = [:]
        }
        // Log the leading bytes and NAL types of the first few frames in a session.
        if described < 6 {
            described += 1
            Log.note("decoder: frame \(frame.frameID), \(whole.count) bytes, begins "
                     + whole.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " ")
                     + "; NAL types as HEVC: " + AnnexB.describeStart(whole, as: .hevc))
        }
        guard let codec else {
            if !complainedAboutStream {
                complainedAboutStream = true
                Log.note("decoder: waiting for a keyframe; this frame begins "
                         + whole.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            return
        }
        // Take ownership of the frame's buffer; CMBlockBuffer will free it once
        // VideoToolbox finishes decoding.
        guard var memory = frame.data.takeMemory(), var base = memory.baseAddress else { return }
        var changed = false
        if codec == .av1 {
            // AV1 OBUs are passed directly to VideoToolbox without framing changes.
            // Keyframes start with a sequence header OBU, which AV1Parser.swift
            // (from the ALVR visionOS client) parses into a CMFormatDescription.
            if AnnexB.keyframeCodec(UnsafeBufferPointer(memory)) == .av1 {
                let header = Bytes(memory.prefix(128))
                if parameterSets[0] != header {
                    parameterSets[0] = header
                    av1Format = try? CMVideoFormatDescriptionCreateFromAV1SequenceHeaderOBUWithAV1C(memory)
                    if av1Format == nil { Log.note("decoder: could not read the AV1 sequence header") }
                    changed = true
                }
            }
        } else {
            // HEVC and H.264 arrive in Annex B format with 4-byte start codes
            // (00 00 00 01), whereas VideoToolbox expects 4-byte big-endian NAL
            // lengths (AVCC/HVCC). When every start code is 4 bytes, we overwrite
            // them in place (following the ALVR visionOS client). Parameter sets
            // remain in the sample buffer in addition to building the format description.
            let units = AnnexB.units(in: UnsafeBufferPointer(memory))
            for unit in units where unit.size > 0 {
                let (type, isParameterSet) = PictureDecoder.classify(memory[unit.payload], codec)
                guard isParameterSet else { continue }
                let bytes = Bytes(memory[unit.payload..<unit.payload + unit.size])
                if parameterSets[type] != bytes {
                    parameterSets[type] = bytes
                    changed = true
                }
            }
            func writeLength(_ size: Int, to pointer: UnsafeMutablePointer<UInt8>) {
                pointer[0] = UInt8(truncatingIfNeeded: size >> 24)
                pointer[1] = UInt8(truncatingIfNeeded: size >> 16)
                pointer[2] = UInt8(truncatingIfNeeded: size >> 8)
                pointer[3] = UInt8(truncatingIfNeeded: size)
            }
            if units.first?.startCode == 0, units.allSatisfy({ $0.startCodeLength == 4 }) {
                for unit in units { writeLength(unit.size, to: base + unit.startCode) }
            } else {
                // 3-byte start codes cannot hold a 4-byte length in place, so
                // allocate a new buffer and copy each NAL unit with a 4-byte length prefix.
                let total = units.reduce(0) { $0 + 4 + $1.size }
                guard let copy = malloc(max(total, 1))?.assumingMemoryBound(to: UInt8.self) else {
                    free(base)
                    return
                }
                var offset = 0
                for unit in units {
                    writeLength(unit.size, to: copy + offset)
                    (copy + offset + 4).update(from: base + unit.payload, count: unit.size)
                    offset += 4 + unit.size
                }
                free(base)
                base = copy
                memory = UnsafeMutableBufferPointer(start: copy, count: total)
            }
        }
        let sampleLength = memory.count
        if changed, !printedParameterSets, codec != .av1 {
            // Log the hex-encoded parameter sets once so they can be inspected
            // with external bitstream analysis tools.
            printedParameterSets = true
            for type in parameterSets.keys.sorted() {
                Log.note("decoder: parameter set \(type): " + (parameterSets[type] ?? []).map { String(format: "%02x", $0) }.joined())
            }
        }
        if changed { parameterSetsChanged() }
        guard let session, let format, sampleLength > 0 else {
            free(base)
            return
        }
        // The block buffer takes the memory over and frees it when the decoder is done with it.
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: base, blockLength: sampleLength, blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil, offsetToData: 0, dataLength: sampleLength, flags: 0,
            blockBufferOut: &block) == noErr, let block
        else {
            free(base)
            return
        }
        var sampleBuffer: CMSampleBuffer?
        var size = sampleLength
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer
        else { return }

        let accepted = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            if status == noErr, let image {
                self?.onImage?(frame.frameID, image, frame.layout)
            } else {
                self?.noteFailure(status)
                self?.onFailure?(frame.frameID)
            }
        }
        if accepted != noErr {
            // VideoToolbox rejected the frame synchronously (for example, because
            // the system invalidated the session while the app was backgrounded),
            // so the callback will not run. Invalidate the session and recreate it
            // on the next keyframe.
            Log.note("decoder: the decompression session refused a frame (\(accepted)); starting another at the next keyframe")
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            parameterSets = [:]
            onFailure?(frame.frameID)
        }
    }
}
