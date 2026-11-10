// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Reading just enough of a video elementary stream to know what it is.
///
/// The session layer does not say which codec a stream uses; the reference
/// client assumes HEVC. Hosts are expected to send HEVC, and may send H.264
/// from hardware that cannot encode HEVC, so the stream itself is asked.

// Every NAL unit: the top bit of the first header byte is always zero.
public let NAL_FORBIDDEN_ZERO_BIT: UInt8 = 0x80

// H.264: one header byte, the type in its low five bits and above it a
// two-bit reference priority, never zero for a parameter set or keyframe slice.
public let H264_NAL_TYPE_MASK: UInt8 = 0x1F
public let H264_NAL_REF_IDC_MASK: UInt8 = 0x60
public let H264_NAL_TYPE_SLICE: UInt8 = 1          // a slice of a picture that is not a keyframe
public let H264_NAL_TYPE_IDR: UInt8 = 5            // a slice of a keyframe
public let H264_NAL_TYPE_SPS: UInt8 = 7
public let H264_NAL_TYPE_PPS: UInt8 = 8
public let H264_NAL_TYPE_AUD: UInt8 = 9            // access unit delimiter

// HEVC: two header bytes. The type is six bits of the first, one bit up;
// its lowest bit is the top of the layer id. The second byte is the rest
// of the layer id and the temporal id plus one: 0x01 for the base layer.
public let HEVC_NAL_TYPE_SHIFT: UInt8 = 1
public let HEVC_NAL_TYPE_MASK: UInt8 = 0x3F
public let HEVC_NAL_LAYER_ID_HIGH_BIT: UInt8 = 0x01
public let HEVC_NAL_BASE_LAYER_SECOND_BYTE: UInt8 = 0x01
public let HEVC_NAL_TYPE_IRAP_FIRST: UInt8 = 16    // BLA_W_LP: the first random-access slice type
public let HEVC_NAL_TYPE_IRAP_LAST: UInt8 = 23     // RSV_IRAP_VCL23: the last
public let HEVC_NAL_TYPE_VPS: UInt8 = 32           // also the first type that is not a slice
public let HEVC_NAL_TYPE_SPS: UInt8 = 33
public let HEVC_NAL_TYPE_PPS: UInt8 = 34
public let HEVC_NAL_TYPE_AUD: UInt8 = 35           // access unit delimiter

// AV1: OBU header bytes, each with the "has a size field" bit set.
public let AV1_OBU_TEMPORAL_DELIMITER: UInt8 = 0x12
public let AV1_OBU_TEMPORAL_DELIMITER_SIZE: UInt8 = 0x00
public let AV1_OBU_SEQUENCE_HEADER: UInt8 = 0x0A

/// The NAL unit type from the first header byte of a unit.
@inline(__always) public func h264NalType(_ header: UInt8) -> UInt8 { header & H264_NAL_TYPE_MASK }
@inline(__always) public func hevcNalType(_ header: UInt8) -> UInt8 { (header >> HEVC_NAL_TYPE_SHIFT) & HEVC_NAL_TYPE_MASK }

/// How much of an access unit is read to find out what it is. Parameter
/// sets and other small units come before the first slice, and the access
/// unit can be megabytes long.
private let ACCESS_UNIT_PROBE_LENGTH = 4096

public enum VideoCodec: String {
    case hevc = "HEVC", h264 = "H.264", av1 = "AV1"
}

public enum AnnexB {
    /// Where one NAL unit sits in a stream.
    public struct Unit {
        /// The first byte of its start code, and how long that code is (3 or 4 bytes).
        public var startCode: Int
        public var startCodeLength: Int
        /// The unit itself: its first byte and its length.
        public var payload: Int
        public var size: Int
    }

    /// Find the NAL units of a stream by its 00 00 01 start codes, without copying anything. 
    /// Based on the ALVR's visionOS client code, which derives from WebRTC's NAL parser.
    // See also: https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    public static func units(in stream: UnsafeBufferPointer<UInt8>) -> [Unit] {
        var units: [Unit] = []
        let count = stream.count
        var index = 0
        while index + 2 < count {
            if stream[index + 2] > 1 {
                index += 3
            } else if stream[index + 2] == 1, stream[index + 1] == 0, stream[index] == 0 {
                // A zero in front makes it the four-byte form
                let long = index > 0 && stream[index - 1] == 0
                let start = long ? index - 1 : index
                if !units.isEmpty { units[units.count - 1].size = start - units[units.count - 1].payload }
                units.append(Unit(startCode: start, startCodeLength: long ? 4 : 3, payload: index + 3, size: 0))
                index += 3
            } else {
                index += 1
            }
        }
        if !units.isEmpty { units[units.count - 1].size = count - units[units.count - 1].payload }
        return units
    }

    /// The NAL units of a stream, as ArraySlices
    public static func nalUnits(_ stream: Bytes) -> [ArraySlice<UInt8>] {
        stream.withUnsafeBufferPointer { units(in: $0) }.map { stream[$0.payload..<$0.payload + $0.size] }
    }

    /// The codec of an access unit that is a keyframe, which a decoder can
    /// initialize from. Nil for any other access unit type.
    ///
    /// For HEVC and H.264, the access unit carries a Sequence Parameter Set and
    /// its first picture slice is a random-access one (HEVC NAL types 16 to
    /// 23; H.264 type 5). Parameter sets don't guarantee a keyframe, some
    /// encoders repeat them in front of every frame and some don't.
    ///
    /// AV1 has no start codes, a keyframe is a temporal delimiter (12 00) 
    /// followed at once by a sequence header (first byte 0A).
    public static func keyframeCodec(_ accessUnit: Bytes) -> VideoCodec? {
        accessUnit.withUnsafeBufferPointer { keyframeCodec($0) }
    }

    public static func keyframeCodec(_ accessUnit: UnsafeBufferPointer<UInt8>) -> VideoCodec? {
        if accessUnit.count >= 3, accessUnit[0] == AV1_OBU_TEMPORAL_DELIMITER, accessUnit[1] == AV1_OBU_TEMPORAL_DELIMITER_SIZE,
           accessUnit[2] == AV1_OBU_SEQUENCE_HEADER { return .av1 }
        let start = UnsafeBufferPointer(rebasing: accessUnit.prefix(ACCESS_UNIT_PROBE_LENGTH))
        var parameterSets: VideoCodec?
        for unit in units(in: start) where unit.size > 0 {
            let first = start[unit.payload]
            guard first & NAL_FORBIDDEN_ZERO_BIT == 0 else { return nil }
            let second = unit.size > 1 ? start[unit.payload + 1] : 0
            let hevcType = hevcNalType(first), h264Type = h264NalType(first)
            let hevcBaseLayer = first & HEVC_NAL_LAYER_ID_HIGH_BIT == 0 && second == HEVC_NAL_BASE_LAYER_SECOND_BYTE
            switch parameterSets {
            case nil:
                // Which codec: an HEVC parameter set has two header bytes, the
                // second 0x01 for the base layer; an H.264 one has a non-zero
                // reference priority. The two readings cannot both hold.
                if hevcBaseLayer, hevcType == HEVC_NAL_TYPE_VPS || hevcType == HEVC_NAL_TYPE_SPS { parameterSets = .hevc }
                else if h264Type == H264_NAL_TYPE_SPS, first & H264_NAL_REF_IDC_MASK != 0 { parameterSets = .h264 }
                else if (hevcBaseLayer && hevcType == HEVC_NAL_TYPE_AUD) || h264Type == H264_NAL_TYPE_AUD { continue }
                else { return nil }
            case .hevc:
                if hevcType < HEVC_NAL_TYPE_VPS {                                           // the first slice
                    return (HEVC_NAL_TYPE_IRAP_FIRST...HEVC_NAL_TYPE_IRAP_LAST).contains(hevcType) ? .hevc : nil
                }
            case .h264:
                if h264Type == H264_NAL_TYPE_IDR { return .h264 }
                if h264Type == H264_NAL_TYPE_SLICE { return nil }
            case .av1:
                return nil
            }
        }
        return nil
    }

    /// For the log: the NAL unit types at the start of an access unit, read as `codec`.
    public static func describeStart(_ accessUnit: UnsafeBufferPointer<UInt8>, as codec: VideoCodec) -> String {
        let start = UnsafeBufferPointer(rebasing: accessUnit.prefix(ACCESS_UNIT_PROBE_LENGTH))
        return units(in: start).prefix(12).filter { $0.size > 0 }.map { unit in
            let first = start[unit.payload]
            return String(codec == .h264 ? h264NalType(first) : hevcNalType(first))
        }.joined(separator: " ")
    }
}
