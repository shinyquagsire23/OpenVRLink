// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreMedia
import VideoToolbox
import VRLinkCore

/// HEVC, H.264 or AV1 access units in, pixel buffers out, on VideoToolbox.
/// The codec is read off the stream's first keyframe.
///
/// No output pixel format is requested: asking for one makes VideoToolbox
/// convert (and on visionOS, copy). Whatever biplanar YCbCr the hardware
/// produces goes to the GPU as it is, and the sampler converts it to RGB.
/// A decoded frame as this platform's decoder and renderer agree to pass it:
/// VideoToolbox pixel buffers, still on the GPU side. Steam's VR Link sends
/// one picture a frame, with every tile in it; WiVRn one for each eye.
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

/// Encoded pictures in, whole decoded frames out: one `PictureDecoder` for
/// each picture a frame has, and a frame is handed on when all of its
/// pictures are decoded.
public final class VideoDecoder {
    public var onImage: ((DecodedFrame) -> Void)?
    /// Called, on the thread that calls `decode`, when the format of a
    /// frame's first picture becomes known and each time it changes.
    public var onFormat: ((CMVideoFormatDescription) -> Void)?

    /// Called when a picture could not be decoded, with its frame and
    /// which picture: the session can ask the host to start afresh.
    public var onFailure: ((UInt16, Int) -> Void)?

    public init() {}

    /// Forget everything about the stream decoded so far. A new stream
    /// begins with a keyframe and gets decoders of its own: the system
    /// may have ended the old ones while the app was put away, and one
    /// ended that way takes frames and gives nothing back.
    public func reset() {
        decoders = []
        lock.lock()
        waiting = []
        lock.unlock()
    }

    private var decoders: [PictureDecoder] = []
    private let lock = NSLock()
    /// Frames some of whose pictures are decoded, oldest first.
    private var waiting: [(frameID: UInt16, images: [Int: CVPixelBuffer])] = []
    /// A frame still short of a picture when this many newer ones have
    /// begun will not get it: that picture was lost on the way.
    static let framesWaiting = 4

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
        if layout.pictures <= 1 {
            onImage?(DecodedFrame(frameID: frameID, images: [image], layout: layout))
            return
        }
        lock.lock()
        let index = waiting.firstIndex { $0.frameID == frameID } ?? waiting.count
        if index == waiting.count { waiting.append((frameID, [:])) }
        waiting[index].images[picture] = image
        var whole: [CVPixelBuffer]?
        if waiting[index].images.count == layout.pictures {
            whole = (0..<layout.pictures).compactMap { waiting[index].images[$0] }
            waiting.removeFirst(index + 1)            // and with it, any older frame still short
        } else if waiting.count > VideoDecoder.framesWaiting {
            waiting.removeFirst()
        }
        lock.unlock()
        if let whole, whole.count == layout.pictures {
            onImage?(DecodedFrame(frameID: frameID, images: whole, layout: layout))
        }
    }
}

/// One picture's decoder.
final class PictureDecoder {
    var onImage: ((UInt16, CVPixelBuffer, FrameLayout) -> Void)?
    var onFailure: ((UInt16) -> Void)?
    /// Called, on the thread that calls `decode`, when the stream's
    /// format becomes known and each time it changes.
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

    /// The NAL type of a unit, and whether it is a parameter set, in the stream's codec.
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

    /// Adopt new parameter sets. The host re-sends sets whose bytes differ
    /// (rate control); rebuilding the session each time would throw away its
    /// reference frames, so an existing session is asked to accept them first.
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

    /// Decode one frame. The frame's memory is taken over: it goes to
    /// VideoToolbox as it is, with no copy, so a frame can be decoded once.
    func decode(_ frame: EncodedFrame) {
        let whole = UnsafeBufferPointer(frame.data.bytes)
        if let seen = AnnexB.keyframeCodec(whole), seen != codec {
            if let codec { Log.note("decoder: the stream changed from \(codec.rawValue) to \(seen.rawValue)") }
            else { Log.note("decoder: the stream is \(seen.rawValue)") }
            codec = seen
            parameterSets = [:]
        }
        // The first frames of a session, for the log: what each begins with.
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
        // From here the frame's block of memory is ours; it ends up owned by
        // the sample buffer, which frees it when the decoder has finished.
        guard var memory = frame.data.takeMemory(), var base = memory.baseAddress else { return }
        var changed = false
        if codec == .av1 {
            // AV1 goes as it arrived. Its configuration is the sequence
            // header at the start of a keyframe, which AV1Parser.swift
            // (from the ALVR visionOS client) turns into a format description.
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
            // HEVC and H.264 arrive with a start code (00 00 00 01) in front
            // of each unit; VideoToolbox wants the unit's length there
            // instead. Both are four bytes, so the lengths are written over
            // the start codes where they lie (the ALVR visionOS client's
            // method). Parameter sets stay in the sample as well as going
            // into the format description.
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
                // Three-byte start codes leave no room for a length, so this
                // one frame is copied, unit by unit, into a block with room.
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
            // Once: the stream's parameter sets, which say everything about
            // its format, in a form that can be pasted into a bitstream tool.
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
            // The session would not take the frame at all (the system ends
            // sessions when the app is put away): no answer will come for
            // it. Drop the session; the next keyframe makes another.
            Log.note("decoder: the decompression session refused a frame (\(accepted)); starting another at the next keyframe")
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            parameterSets = [:]
            onFailure?(frame.frameID)
        }
    }
}
