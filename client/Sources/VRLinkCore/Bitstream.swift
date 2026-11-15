// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Inspects video elementary streams to detect the codec and locate keyframes.
///
/// The session layer does not signal which codec a stream uses; `vrlink`
/// assumes HEVC. Hosts normally send HEVC, or H.264 on hardware without an
/// HEVC encoder, so we inspect the bitstream directly to identify the codec.

// The top bit of the first NAL unit header byte is always zero.
public let NAL_FORBIDDEN_ZERO_BIT: UInt8 = 0x80

// H.264 uses a single-byte NAL header with the unit type in the low 5 bits and a
// 2-bit reference priority (`nal_ref_idc`) above it, which is non-zero for parameter sets and IDR slices.
public let H264_NAL_TYPE_MASK: UInt8 = 0x1F
public let H264_NAL_REF_IDC_MASK: UInt8 = 0x60
public let H264_NAL_TYPE_SLICE: UInt8 = 1          // non-IDR coded slice
public let H264_NAL_TYPE_IDR: UInt8 = 5            // IDR keyframe slice
public let H264_NAL_TYPE_SPS: UInt8 = 7
public let H264_NAL_TYPE_PPS: UInt8 = 8
public let H264_NAL_TYPE_AUD: UInt8 = 9            // access unit delimiter

// HEVC uses a two-byte NAL header. Bits 1..6 of the first byte hold the 6-bit unit type,
// and bit 0 is the high bit of the layer ID. The second byte holds the remaining 5 bits
// of the layer ID and `temporal_id_plus1` (0x01 for base-layer temporal sublayer 0).
public let HEVC_NAL_TYPE_SHIFT: UInt8 = 1
public let HEVC_NAL_TYPE_MASK: UInt8 = 0x3F
public let HEVC_NAL_LAYER_ID_HIGH_BIT: UInt8 = 0x01
public let HEVC_NAL_BASE_LAYER_SECOND_BYTE: UInt8 = 0x01
public let HEVC_NAL_TYPE_IRAP_FIRST: UInt8 = 16    // BLA_W_LP (first IRAP slice type)
public let HEVC_NAL_TYPE_IRAP_LAST: UInt8 = 23     // RSV_IRAP_VCL23 (last IRAP slice type)
public let HEVC_NAL_TYPE_VPS: UInt8 = 32           // Video Parameter Set (first non-VCL unit type)
public let HEVC_NAL_TYPE_SPS: UInt8 = 33
public let HEVC_NAL_TYPE_PPS: UInt8 = 34
public let HEVC_NAL_TYPE_AUD: UInt8 = 35           // access unit delimiter

// AV1 OBU header bytes with `obu_has_size_field` set.
public let AV1_OBU_TEMPORAL_DELIMITER: UInt8 = 0x12
public let AV1_OBU_TEMPORAL_DELIMITER_SIZE: UInt8 = 0x00
public let AV1_OBU_SEQUENCE_HEADER: UInt8 = 0x0A

/// Extracts the NAL unit type from the first header byte.
@inline(__always) public func h264NalType(_ header: UInt8) -> UInt8 { header & H264_NAL_TYPE_MASK }
@inline(__always) public func hevcNalType(_ header: UInt8) -> UInt8 { (header >> HEVC_NAL_TYPE_SHIFT) & HEVC_NAL_TYPE_MASK }

/// Maximum prefix scanned when probing an access unit. Parameter sets and
/// delimiters precede the first slice, while the full access unit may be megabytes.
private let ACCESS_UNIT_PROBE_LENGTH = 4096

public enum VideoCodec: String {
    case hevc = "HEVC", h264 = "H.264", av1 = "AV1"
}

public enum AnnexB {
    /// Byte offsets and lengths for a single NAL unit in an Annex B byte stream.
    public struct Unit {
        /// Offset of the start code and its length (3 or 4 bytes).
        public var startCode: Int
        public var startCodeLength: Int
        /// Offset and byte length of the NAL unit payload.
        public var payload: Int
        public var size: Int
    }

    /// Finds NAL units in an Annex B byte stream by scanning for 00 00 01 start codes without copying.
    /// Based on ALVR's visionOS client, which derives from WebRTC's NAL parser.
    // See also: https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    public static func units(in stream: UnsafeBufferPointer<UInt8>) -> [Unit] {
        var units: [Unit] = []
        let count = stream.count
        var index = 0
        while index + 2 < count {
            if stream[index + 2] > 1 {
                index += 3
            } else if stream[index + 2] == 1, stream[index + 1] == 0, stream[index] == 0 {
                // A preceding zero byte indicates a 4-byte start code.
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

    /// Returns the NAL unit payloads in `stream` as slices.
    public static func nalUnits(_ stream: Bytes) -> [ArraySlice<UInt8>] {
        stream.withUnsafeBufferPointer { units(in: $0) }.map { stream[$0.payload..<$0.payload + $0.size] }
    }

    /// Returns the codec if `accessUnit` is a keyframe containing decoder initialization
    /// parameters, or `nil` otherwise.
    ///
    /// For HEVC and H.264, the access unit must include parameter sets (VPS/SPS for HEVC,
    /// SPS for H.264) followed by an IRAP/IDR first slice (HEVC NAL types 16...23, H.264
    /// type 5). Checking parameter sets alone is not enough because some encoders repeat
    /// them before non-keyframe slices.
    ///
    /// AV1 does not use Annex B start codes; a keyframe starts with a temporal delimiter
    /// OBU (`0x12 0x00`) immediately followed by a sequence header OBU (`0x0A`).
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
                // Distinguish HEVC from H.264: a base-layer HEVC parameter set has 0x01
                // in its second header byte, while an H.264 SPS has a non-zero nal_ref_idc.
                // A valid header cannot match both.
                if hevcBaseLayer, hevcType == HEVC_NAL_TYPE_VPS || hevcType == HEVC_NAL_TYPE_SPS { parameterSets = .hevc }
                else if h264Type == H264_NAL_TYPE_SPS, first & H264_NAL_REF_IDC_MASK != 0 { parameterSets = .h264 }
                else if (hevcBaseLayer && hevcType == HEVC_NAL_TYPE_AUD) || h264Type == H264_NAL_TYPE_AUD { continue }
                else { return nil }
            case .hevc:
                if hevcType < HEVC_NAL_TYPE_VPS {                                           // first VCL slice
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

    /// Formats the leading NAL unit types of `accessUnit` for diagnostic logging.
    public static func describeStart(_ accessUnit: UnsafeBufferPointer<UInt8>, as codec: VideoCodec) -> String {
        let start = UnsafeBufferPointer(rebasing: accessUnit.prefix(ACCESS_UNIT_PROBE_LENGTH))
        return units(in: start).prefix(12).filter { $0.size > 0 }.map { unit in
            let first = start[unit.payload]
            return String(codec == .h264 ? h264NalType(first) : hevcNalType(first))
        }.joined(separator: " ")
    }
}
