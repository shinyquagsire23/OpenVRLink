// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Parses display dimensions from H.264 and HEVC sequence parameter sets so decoders that require initial
/// dimensions at configuration time (such as Android's `AMediaCodec`) do not have to guess before decoding.
public enum PictureSize {
    /// Returns the cropped display dimensions of an Annex B H.264 or HEVC keyframe, or `nil` if no valid SPS
    /// is found. AV1 sequence headers are not parsed yet.
    public static func of(keyframe: UnsafeBufferPointer<UInt8>, codec: VideoCodec) -> (width: Int, height: Int)? {
        // Parameter sets precede the first slice, so scanning the first 4 KB is enough.
        let head = UnsafeBufferPointer(rebasing: keyframe.prefix(4096))
        for unit in AnnexB.units(in: head) where unit.size > 3 {
            let nal = Bytes(head[unit.payload..<(unit.payload + unit.size)])
            switch codec {
            case .hevc where hevcNalType(nal[0]) == HEVC_NAL_TYPE_SPS: return hevc(nal)
            case .h264 where h264NalType(nal[0]) == H264_NAL_TYPE_SPS: return h264(nal)
            default: continue
            }
        }
        return nil
    }

    /// Reads bits from a NAL unit's payload, skipping the emulation prevention bytes (the 03 in 00 00 03).
    struct Bits {
        private var bytes: Bytes = []
        private var at = 0
        /// True once a read reaches past the end of the buffer; subsequent reads return zero.
        private(set) var ranOut = false

        init(nal: Bytes, headerBytes: Int) {
            var zeros = 0
            bytes.reserveCapacity(nal.count)
            for byte in nal.dropFirst(headerBytes) {
                if zeros >= 2, byte == 3 {
                    zeros = 0
                    continue
                }
                zeros = byte == 0 ? zeros + 1 : 0
                bytes.append(byte)
            }
        }

        mutating func bit() -> Int {
            guard at < bytes.count * 8 else {
                ranOut = true
                return 0
            }
            defer { at += 1 }
            return Int(bytes[at / 8] >> (7 - UInt8(at % 8)) & 1)
        }

        mutating func bits(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count { value = value << 1 | bit() }
            return value
        }

        mutating func skip(_ count: Int) {
            at += count
            if at > bytes.count * 8 { ranOut = true }
        }

        /// An unsigned Exp-Golomb value, `ue(v)`.
        mutating func unsigned() -> Int {
            var zeros = 0
            while bit() == 0 {
                zeros += 1
                if zeros > 31 || ranOut {
                    ranOut = true
                    return 0
                }
            }
            return (1 << zeros) - 1 + bits(zeros)
        }

        /// A signed Exp-Golomb value, `se(v)`.
        mutating func signed() -> Int {
            let code = unsigned()
            return code % 2 == 0 ? -(code / 2) : (code + 1) / 2
        }
    }

    private static func checked(_ width: Int, _ height: Int, _ bits: Bits) -> (width: Int, height: Int)? {
        guard !bits.ranOut, (16...16384).contains(width), (16...16384).contains(height) else { return nil }
        return (width, height)
    }

    /// Parses an H.265 SPS (ITU-T H.265 section 7.3.2.2) through the conformance cropping window.
    static func hevc(_ nal: Bytes) -> (width: Int, height: Int)? {
        var bits = Bits(nal: nal, headerBytes: 2)
        bits.skip(4)                                    // sps_video_parameter_set_id
        let subLayers = bits.bits(3)                    // sps_max_sub_layers_minus1
        bits.skip(1)                                    // sps_temporal_id_nesting_flag
        // Skip the 96-bit general profile_tier_level fields, then any per-sub-layer profile and level fields.
        bits.skip(96)
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0..<subLayers {
            profilePresent.append(bits.bit() == 1)
            levelPresent.append(bits.bit() == 1)
        }
        if subLayers > 0 { bits.skip(2 * (8 - subLayers)) }
        for layer in 0..<subLayers {
            if profilePresent[layer] { bits.skip(88) }
            if levelPresent[layer] { bits.skip(8) }
        }
        _ = bits.unsigned()                             // sps_seq_parameter_set_id
        let chroma = bits.unsigned()
        if chroma == 3 { bits.skip(1) }                 // separate_colour_plane_flag
        var width = bits.unsigned(), height = bits.unsigned()
        if bits.bit() == 1 {                            // conformance_window_flag
            let left = bits.unsigned(), right = bits.unsigned(), top = bits.unsigned(), bottom = bits.unsigned()
            // Offsets are in chroma samples.
            width -= (chroma == 1 || chroma == 2 ? 2 : 1) * (left + right)
            height -= (chroma == 1 ? 2 : 1) * (top + bottom)
        }
        return checked(width, height, bits)
    }

    /// Parses an H.264 SPS (ITU-T H.264 section 7.3.2.1.1) through the frame cropping offsets.
    static func h264(_ nal: Bytes) -> (width: Int, height: Int)? {
        var bits = Bits(nal: nal, headerBytes: 1)
        let profile = bits.bits(8)
        bits.skip(16)                                   // constraint flags and level_idc
        _ = bits.unsigned()                             // seq_parameter_set_id
        var chroma = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chroma = bits.unsigned()
            if chroma == 3 { bits.skip(1) }             // separate_colour_plane_flag
            _ = bits.unsigned()                         // bit_depth_luma_minus8
            _ = bits.unsigned()                         // bit_depth_chroma_minus8
            bits.skip(1)                                // qpprime_y_zero_transform_bypass_flag
            if bits.bit() == 1 {                        // seq_scaling_matrix_present_flag
                for list in 0..<(chroma == 3 ? 12 : 8) where bits.bit() == 1 {
                    var last = 8, next = 8
                    for _ in 0..<(list < 6 ? 16 : 64) {
                        if next != 0 { next = (last + bits.signed() + 256) % 256 }
                        last = next == 0 ? last : next
                    }
                }
            }
        }
        _ = bits.unsigned()                             // log2_max_frame_num_minus4
        let orderType = bits.unsigned()
        if orderType == 0 {
            _ = bits.unsigned()                         // log2_max_pic_order_cnt_lsb_minus4
        } else if orderType == 1 {
            bits.skip(1)                                // delta_pic_order_always_zero_flag
            _ = bits.signed()
            _ = bits.signed()
            let cycle = bits.unsigned()
            guard cycle <= 255 else { return nil }
            for _ in 0..<cycle { _ = bits.signed() }
        }
        _ = bits.unsigned()                             // max_num_ref_frames
        bits.skip(1)                                    // gaps_in_frame_num_value_allowed_flag
        let macroblocksWide = bits.unsigned() + 1, mapUnitsHigh = bits.unsigned() + 1
        let framesOnly = bits.bit()
        if framesOnly == 0 { bits.skip(1) }             // mb_adaptive_frame_field_flag
        bits.skip(1)                                    // direct_8x8_inference_flag
        var width = macroblocksWide * 16, height = (2 - framesOnly) * mapUnitsHigh * 16
        if bits.bit() == 1 {                            // frame_cropping_flag
            let left = bits.unsigned(), right = bits.unsigned(), top = bits.unsigned(), bottom = bits.unsigned()
            width -= (chroma == 1 || chroma == 2 ? 2 : 1) * (left + right)
            height -= (chroma == 1 ? 2 : 1) * (2 - framesOnly) * (top + bottom)
        }
        return checked(width, height, bits)
    }
}
