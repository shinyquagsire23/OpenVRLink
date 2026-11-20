// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Parser, builder, and encoding-gamma patcher for Direct3D DXBC shader containers
/// (`.fxo` files produced by `fxc`), used on Windows for `driver_vrlink.dll`'s
/// copy-view shaders.
///
/// A DXBC container consists of a header, a 16-byte checksum, and a list of tagged
/// chunks. Direct3D validates the header checksum on load, so `build` recomputes the
/// checksum whenever chunks are modified.
public enum DXBC {
    /// One chunk of the container: a four-character tag (`SHEX`, `RDEF`, `OSGN`, ...) and its bytes.
    public struct Chunk: Equatable {
        public var tag: UInt32
        public var data: [UInt8]

        public init(tag: UInt32, data: [UInt8]) {
            self.tag = tag
            self.data = data
        }
    }

    public enum PatchError: Error, Equatable {
        case notAShader
        case noSpareConstant
        case noShaderCode
        case noConstantBuffer
        case noTemporaries
        /// The number of sRGB conversions found; one is expected.
        case unexpectedShape(Int)
        case alreadyPatched
    }

    /// A chunk tag from its four characters, as the little-endian word stored in the file.
    public static func tag(_ text: StaticString) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<min(4, text.utf8CodeUnitCount) { value |= UInt32(text.utf8Start[index]) << (8 * UInt32(index)) }
        return value
    }

    /// The container at the start of a file, by the size it declares. Some `.fxo`
    /// files carry further bytes after it, which Direct3D ignores.
    public static func container(_ file: ByteView) -> ByteView? {
        guard file.count >= 32, file.integer(at: 0, as: UInt32.self) == tag("DXBC"), let size: UInt32 = file.integer(at: 24),
              size >= 32 else { return nil }
        return file.slice(at: 0, count: Int(size))
    }

    /// Splits a container into its chunks, or `nil` if it is not a well-formed one.
    public static func chunks(_ file: ByteView) -> [Chunk]? {
        guard let file = container(file), let count: UInt32 = file.integer(at: 28) else { return nil }
        var out: [Chunk] = []
        for index in 0..<Int(count) {
            guard let at: UInt32 = file.integer(at: 32 + index * 4), let tag: UInt32 = file.integer(at: Int(at)),
                  let size: UInt32 = file.integer(at: Int(at) + 4), let data = file.slice(at: Int(at) + 8, count: Int(size))
            else { return nil }
            out.append(Chunk(tag: tag, data: Array(data)))
        }
        return out
    }

    /// Puts chunks back into a container with a correct checksum.
    public static func build(_ chunks: [Chunk]) -> [UInt8] {
        var file: [UInt8] = []
        file.append(littleEndian: tag("DXBC"))
        file.append(contentsOf: [UInt8](repeating: 0, count: 16))
        file.append(littleEndian: UInt32(1))
        file.append(littleEndian: UInt32(0))
        file.append(littleEndian: UInt32(chunks.count))
        var at = 32 + chunks.count * 4
        for chunk in chunks {
            file.append(littleEndian: UInt32(at))
            at += 8 + chunk.data.count
        }
        for chunk in chunks {
            file.append(littleEndian: chunk.tag)
            file.append(littleEndian: UInt32(chunk.data.count))
            file.append(contentsOf: chunk.data)
        }
        let size = UInt32(file.count)
        for index in 0..<4 { file[24 + index] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(index))) }
        let sum = file.withUnsafeBufferPointer { checksum($0) }
        for index in 0..<16 { file[4 + index] = sum[index] }
        return file
    }

    /// Computes the 16-byte DXBC container checksum stored at bytes `4..<20`.
    /// DXBC uses standard MD5 rounds over bytes `20...`, with a custom final-block
    /// bit-length padding layout.
    public static func checksum(_ file: ByteView) -> [UInt8] {
        var state: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476]
        let length = max(0, file.count - 20)
        let whole = length / 64 * 64
        var block = [UInt8](repeating: 0, count: 64)
        var offset = 0
        while offset < whole {
            for index in 0..<64 { block[index] = file[20 + offset + index] }
            round(&state, block)
            offset += 64
        }
        let rest = length - whole
        let bits = UInt32(truncatingIfNeeded: length) &* 8, marker = UInt32(truncatingIfNeeded: length) &* 2 | 1
        block = [UInt8](repeating: 0, count: 64)
        func put(_ value: UInt32, at position: Int) {
            for index in 0..<4 { block[position + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
        }
        if rest >= 56 {
            for index in 0..<rest { block[index] = file[20 + whole + index] }
            block[rest] = 0x80
            round(&state, block)
            block = [UInt8](repeating: 0, count: 64)
            put(bits, at: 0)
        } else {
            put(bits, at: 0)
            for index in 0..<rest { block[4 + index] = file[20 + whole + index] }
            block[4 + rest] = 0x80
        }
        put(marker, at: 60)
        round(&state, block)
        var out: [UInt8] = []
        for word in state { out.append(littleEndian: word) }
        return out
    }

    /// MD5's per-step additive constants: the integer part of `2^32 * |sin(step + 1)|`.
    private static let sines: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]
    private static let shifts: [UInt32] = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]

    private static func round(_ state: inout [UInt32], _ block: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            words[index] = UInt32(block[index * 4]) | UInt32(block[index * 4 + 1]) << 8 | UInt32(block[index * 4 + 2]) << 16
                | UInt32(block[index * 4 + 3]) << 24
        }
        var (a, b, c, d) = (state[0], state[1], state[2], state[3])
        for step in 0..<64 {
            let mixed: UInt32, word: Int
            switch step / 16 {
            case 0: (mixed, word) = ((b & c) | (~b & d), step)
            case 1: (mixed, word) = ((d & b) | (~d & c), (5 * step + 1) % 16)
            case 2: (mixed, word) = (b ^ c ^ d, (3 * step + 5) % 16)
            default: (mixed, word) = (c ^ (b | ~d), (7 * step) % 16)
            }
            let sum = a &+ mixed &+ sines[step] &+ words[word]
            let shift = shifts[step / 16 * 4 + step % 4]
            (a, d, c) = (d, c, b)
            b = b &+ (sum << shift | sum >> (32 - shift))
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
    }

    // MARK: Encoding gamma

    /// Offset, in floats, of the constant the patched shaders read gamma from: `g_unused0`
    /// of the copy-view shaders' `VS_CONSTANT_BUFFER` (byte 40, `cb2[2].z`), which the
    /// driver clears and never sets.
    public static let gammaConstant = 10
    static let carrierBuffer: UInt32 = 2, carrierRow: UInt32 = 2

    private enum Opcode {
        static let div: UInt32 = 14, exp: UInt32 = 25, ge: UInt32 = 29, log: UInt32 = 47, max: UInt32 = 52, min: UInt32 = 51
        static let mov: UInt32 = 54, movc: UInt32 = 55, mul: UInt32 = 56, customData: UInt32 = 53
        static let declareConstantBuffer: UInt32 = 89, declareTemps: UInt32 = 104
        static let saturate: UInt32 = 1 << 13
    }

    /// Operand tokens (each followed by its index words).
    private enum Operand {
        static let tempXYZ: UInt32 = 0x0010_0072        // rN.xyz as a destination
        static let tempW: UInt32 = 0x0010_0082          // rN.w as a destination
        static let tempXYZX: UInt32 = 0x0010_0246       // rN.xyzx as a source
        static let tempWWWW: UInt32 = 0x0010_0FF6       // rN.wwww as a source
        static let tempWScalar: UInt32 = 0x0010_003A    // rN.w as a scalar source
        static let bufferZScalar: UInt32 = 0x0020_802A  // cbA[B].z as a scalar source
        static let literal: UInt32 = 0x0000_4001        // a scalar float literal
        static let literal4: UInt32 = 0x0000_4002       // a four-component literal
    }

    private static func instruction(_ opcode: UInt32, _ operands: [UInt32]) -> [UInt32] {
        [opcode | UInt32(operands.count + 1) << 24] + operands
    }

    /// Patches encoding gamma into one of Windows `driver_vrlink.dll`'s copy-view shaders
    /// (`genforencode_{ps,cs}_copy_view[_cas].fxo`), matching the behavior of `SPIRV.patchGamma`.
    ///
    /// Each copy-view shader finishes with a per-channel linear-to-sRGB branch
    /// (`ge t, 0.0031308, c` followed by `movc dest.xyz, t, low, high`). This patch routes
    /// the `movc` output into a new temporary register, clamps it to `[0, 1]`, raises it
    /// to `1 / clamp(g_unused0, 1, 4)`, and writes the result to the original destination.
    /// When `g_unused0` has its unpatched value of `0`, the exponent is `1` and output is
    /// unchanged.
    public static func patchGamma(_ file: ByteView) throws(PatchError) -> [UInt8] {
        guard var parts = chunks(file) else { throw .notAShader }
        guard let reflection = parts.first(where: { $0.tag == tag("RDEF") }),
              reflection.data.withUnsafeBufferPointer({ $0.containsCString("g_unused0") }) else { throw .noSpareConstant }
        guard let codeIndex = parts.firstIndex(where: { $0.tag == tag("SHEX") }) else { throw .noShaderCode }
        guard let code = parts[codeIndex].data.withUnsafeBufferPointer({ words(of: $0) }), code.count >= 2 else { throw .notAShader }

        var instructions: [[UInt32]] = []
        var at = 2
        while at < code.count {
            let opcode = code[at] & 0x7FF
            let length = opcode == Opcode.customData ? (at + 1 < code.count ? Int(code[at + 1]) : 0) : Int((code[at] >> 24) & 0x7F)
            guard length > 0, at + length <= code.count else { throw .notAShader }
            instructions.append(Array(code[at..<(at + length)]))
            at += length
        }
        func opcode(_ words: [UInt32]) -> UInt32 { words[0] & 0x7FF }

        // The constant buffer must be declared with at least the row the carrier is in.
        guard instructions.contains(where: {
            opcode($0) == Opcode.declareConstantBuffer && $0.count == 4 && $0[2] == carrierBuffer && $0[3] > carrierRow
        }) else { throw .noConstantBuffer }
        guard let temps = instructions.firstIndex(where: { opcode($0) == Opcode.declareTemps && $0.count == 2 }) else { throw .noTemporaries }
        let scratch = instructions[temps][1]

        // `ge` against the sRGB threshold, directly followed by the `movc` that picks the branch.
        let threshold = Float(0.0031308).bitPattern
        func comparesWithThreshold(_ words: [UInt32]) -> Bool {
            guard opcode(words) == Opcode.ge, words.count >= 4 else { return false }
            for index in 0...(words.count - 4)
            where words[index] == Operand.literal4 && words[index + 1] == threshold && words[index + 2] == threshold && words[index + 3] == threshold {
                return true
            }
            return false
        }
        var selects: [Int] = []
        for index in instructions.indices.dropFirst() {
            let select = instructions[index]
            if comparesWithThreshold(instructions[index - 1]), opcode(select) == Opcode.movc, select.count == 9,
               select[1] & 0x8000_0FFF == 0x072 {
                selects.append(index)
            }
        }
        guard selects.count == 1 else { throw .unexpectedShape(selects.count) }
        let select = selects[0]
        if select + 1 < instructions.count, opcode(instructions[select + 1]) == Opcode.max,
           instructions[select + 1].contains(Operand.bufferZScalar) {
            throw .alreadyPatched
        }

        let destination = (instructions[select][1], instructions[select][2])
        instructions[select][1] = Operand.tempXYZ
        instructions[select][2] = scratch
        instructions[temps][1] = scratch + 1
        let one = Float(1).bitPattern, most = Float(4).bitPattern
        let added: [[UInt32]] = [
            // exponent = 1 / clamp(g_unused0, 1, 4)
            instruction(Opcode.max, [Operand.tempW, scratch, Operand.bufferZScalar, carrierBuffer, carrierRow, Operand.literal, one]),
            instruction(Opcode.min, [Operand.tempW, scratch, Operand.tempWScalar, scratch, Operand.literal, most]),
            instruction(Opcode.div, [Operand.tempW, scratch, Operand.literal, one, Operand.tempWScalar, scratch]),
            // value = saturate(value) ^ exponent, as exp(log(value) * exponent); zero stays zero
            instruction(Opcode.mov | Opcode.saturate, [Operand.tempXYZ, scratch, Operand.tempXYZX, scratch]),
            instruction(Opcode.log, [Operand.tempXYZ, scratch, Operand.tempXYZX, scratch]),
            instruction(Opcode.mul, [Operand.tempXYZ, scratch, Operand.tempXYZX, scratch, Operand.tempWWWW, scratch]),
            instruction(Opcode.exp, [Operand.tempXYZ, scratch, Operand.tempXYZX, scratch]),
            instruction(Opcode.mov, [destination.0, destination.1, Operand.tempXYZX, scratch]),
        ]
        instructions.insert(contentsOf: added, at: select + 1)

        var out: [UInt32] = [code[0], 0]
        for words in instructions { out.append(contentsOf: words) }
        out[1] = UInt32(out.count)
        parts[codeIndex].data = out.bytes
        return build(parts)
    }
}
