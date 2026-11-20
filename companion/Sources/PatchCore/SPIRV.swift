// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Patches encoding gamma into Linux `driver_vrlink.so`'s Vulkan compute shaders
/// (`genforencode_comp_{rgb,luma,chroma}.spv` and `genforencode_cs_{rgb,luma,chroma}.spv`).
///
/// Each shader finishes by converting the sampled linear color to sRGB one channel at a
/// time (`c <= 0.0031308 ? c * 12.92 : 1.055 * c^(1/2.4) - 0.055`) before writing RGB or
/// converting to YUV. This patch raises each of those three sRGB channels to `1 / gamma`
/// to preserve dark detail through video compression, and the client restores the decoded
/// sRGB values with `value ^ gamma`.
///
/// At runtime, the shader reads `gamma` from an unused float in its uniform constant
/// block. Because newer Linux `driver_vrlink.so` builds strip debug names, the patcher
/// scans the SPIR-V instructions for the last float or float-vector member that the
/// shader never reads (which `UpdateConstantBuffer` leaves zeroed) and returns its float
/// offset so `driver_openvrlink` knows where to write `gamma`. Values outside `(1, 4]`
/// are ignored, leaving the output unchanged if constants are unpatched.
///
/// If a shader does not match the expected structure, `patchGamma` throws a `PatchError`
/// without modifying the shader.
public enum SPIRV {
    public enum PatchError: Error, Equatable {
        case notSPIRV
        case malformed
        case missingFloatType, missingBoolType, missingIntType, missingGLSLImport
        /// No constant block, or no member of it that the shader leaves unread.
        case missingBlock, missingCarrier, missingFunction
        /// The sRGB conversions are not in one straight run of instructions.
        case notStraightLine
        /// The number of per-channel sRGB selects found; three are expected.
        case unexpectedShape(Int)
        /// An instruction this patcher cannot rewrite safely (by opcode) uses a patched value.
        case unknownUse(UInt16)
        case alreadyPatched
    }

    private static let magic: UInt32 = 0x0723_0203

    private enum Opcode {
        static let extInstImport: UInt16 = 11, extInst: UInt16 = 12
        static let typeBool: UInt16 = 20, typeInt: UInt16 = 21, typeFloat: UInt16 = 22, typeVector: UInt16 = 23
        static let typeStruct: UInt16 = 30, typePointer: UInt16 = 32
        static let decorate: UInt16 = 71, memberDecorate: UInt16 = 72, inBoundsAccessChain: UInt16 = 66
        static let constant: UInt16 = 43, function: UInt16 = 54, variable: UInt16 = 59, load: UInt16 = 61, store: UInt16 = 62
        static let accessChain: UInt16 = 65, vectorShuffle: UInt16 = 79, compositeConstruct: UInt16 = 80
        static let compositeExtract: UInt16 = 81, compositeInsert: UInt16 = 82, imageWrite: UInt16 = 99
        static let fDiv: UInt16 = 136, logicalAnd: UInt16 = 167, select: UInt16 = 169
        static let fOrdGreaterThan: UInt16 = 186, fOrdLessThanEqual: UInt16 = 188
        static let phi: UInt16 = 245, label: UInt16 = 248, branchConditional: UInt16 = 250
    }

    private static let storageUniform: UInt32 = 2, decorationBlock: UInt32 = 2, decorationOffset: UInt32 = 35
    private static let glslFClamp: UInt32 = 43, glslPow: UInt32 = 26

    private struct Instruction {
        var opcode: UInt16
        var words: [UInt32]

        init(_ opcode: UInt16, _ operands: [UInt32]) {
            self.opcode = opcode
            words = [UInt32(operands.count + 1) << 16 | UInt32(opcode)] + operands
        }

        init(words: [UInt32]) {
            opcode = UInt16(truncatingIfNeeded: words[0])
            self.words = words
        }

        /// Indices (into `words`) of the operands that are value ids the patch might need
        /// to redirect, or `nil` for an instruction it does not know.
        var valueOperands: [Int]? {
            switch opcode {
            // Conversions, arithmetic, logic, comparisons, selects, constructors, phis and
            // access chains: everything after the result type and result id is an id.
            case 109...115, 124...168, Opcode.select, 170...191, Opcode.compositeConstruct, Opcode.phi, Opcode.accessChain:
                return Array(3..<max(3, words.count))
            case Opcode.extInst: return Array(5..<max(5, words.count))
            case Opcode.compositeExtract, Opcode.load: return [3]
            case Opcode.compositeInsert, Opcode.vectorShuffle: return [3, 4]
            case Opcode.store: return [1, 2]
            case Opcode.imageWrite: return [1, 2, 3]
            case Opcode.branchConditional: return [1]
            // Structure with no value operands: labels, branches, merges, returns, line info.
            case Opcode.label, 246, 247, 249, 253, 56, 8, 317: return []
            default: return nil
            }
        }
    }

    /// Whether the NUL-terminated literal string in `words[from...]` equals `text`.
    private static func literal(_ words: [UInt32], from: Int, equals text: StaticString) -> Bool {
        let length = text.utf8CodeUnitCount
        for index in 0...length {
            let word = from + index / 4
            guard word < words.count else { return false }
            let byte = UInt8(truncatingIfNeeded: words[word] >> (8 * UInt32(index % 4)))
            if byte != (index < length ? text.utf8Start[index] : 0) { return false }
        }
        return true
    }

    /// Rewrites one of the encode shaders so it applies the encoding gamma. `file` is the
    /// shader file's bytes. The result is the patched file's bytes and the index, counted
    /// in floats from the start of the shaders' constant block, at which it reads gamma.
    public static func patchGamma(_ file: ByteView) throws(PatchError) -> (bytes: [UInt8], gammaConstant: Int) {
        guard file.count >= 20, let all = words(of: file), all[0] == magic else { throw .notSPIRV }
        var bound = all[3]
        var instructions: [Instruction] = []
        var at = 5
        while at < all.count {
            let length = Int(all[at] >> 16)
            guard length > 0, at + length <= all.count else { throw .malformed }
            instructions.append(Instruction(words: Array(all[at..<(at + length)])))
            at += length
        }

        // The ids the new code needs from the module's declarations.
        var float: UInt32?, bool: UInt32?, int: UInt32?, glsl: UInt32?
        for instruction in instructions {
            let w = instruction.words
            switch instruction.opcode {
            case Opcode.typeFloat where w.count >= 3 && w[2] == 32: float = float ?? w[1]
            case Opcode.typeBool where w.count >= 2: bool = bool ?? w[1]
            case Opcode.typeInt where w.count >= 4 && w[2] == 32: int = int ?? w[1]
            case Opcode.extInstImport where w.count >= 3 && literal(w, from: 2, equals: "GLSL.std.450"): glsl = w[1]
            default: break
            }
        }
        guard let float else { throw .missingFloatType }
        guard let bool else { throw .missingBoolType }
        guard let int else { throw .missingIntType }
        guard let glsl else { throw .missingGLSLImport }

        let existingFloatPointer = instructions.first(where: {
            $0.opcode == Opcode.typePointer && $0.words.count >= 4 && $0.words[2] == storageUniform && $0.words[3] == float
        })?.words[1]

        // The three per-channel sRGB results: selects whose condition is `x <= 0.0031308`.
        let threshold = Float(0.0031308).bitPattern
        var thresholds: [UInt32] = [], comparisons: [UInt32] = [], selects: [Int] = []
        for instruction in instructions
        where instruction.opcode == Opcode.constant && instruction.words.count == 4 && instruction.words[1] == float && instruction.words[3] == threshold {
            thresholds.append(instruction.words[2])
        }
        for instruction in instructions
        where instruction.opcode == Opcode.fOrdLessThanEqual && instruction.words.count == 5 && thresholds.contains(instruction.words[4]) {
            comparisons.append(instruction.words[2])
        }
        for (index, instruction) in instructions.enumerated()
        where instruction.opcode == Opcode.select && instruction.words.count == 6 && instruction.words[1] == float
            && comparisons.contains(instruction.words[3]) {
            selects.append(index)
        }
        guard selects.count == 3 else { throw .unexpectedShape(selects.count) }
        var results: [UInt32] = []
        for index in selects { results.append(instructions[index].words[2]) }
        for instruction in instructions
        where instruction.opcode == Opcode.extInst && instruction.words.count == 8 && instruction.words[4] == glslFClamp
            && results.contains(instruction.words[5]) {
            throw .alreadyPatched
        }
        // The constant block: the uniform variable whose type is a struct decorated `Block`.
        var blockTypes: [UInt32] = []
        for instruction in instructions
        where instruction.opcode == Opcode.decorate && instruction.words.count == 3 && instruction.words[2] == decorationBlock {
            blockTypes.append(instruction.words[1])
        }
        var found: (variable: UInt32, type: UInt32)?
        for instruction in instructions
        where instruction.opcode == Opcode.variable && instruction.words.count >= 4 && instruction.words[3] == storageUniform {
            let pointer = instructions.first { $0.opcode == Opcode.typePointer && $0.words.count >= 4 && $0.words[1] == instruction.words[1] }
            if let pointee = pointer?.words[3], blockTypes.contains(pointee) {
                guard found == nil else { throw .missingBlock }      // more than one: not the shape this patch knows
                found = (instruction.words[2], pointee)
            }
        }
        guard let found, let members = instructions.first(where: { $0.opcode == Opcode.typeStruct && $0.words.count >= 2 && $0.words[1] == found.type })?.words.dropFirst(2)
        else { throw .missingBlock }
        let block = found.variable

        // The members the shader reads, by the constant first index of each access to the block.
        var read = Set<UInt32>()
        for instruction in instructions
        where (instruction.opcode == Opcode.accessChain || instruction.opcode == Opcode.inBoundsAccessChain) && instruction.words.count >= 5
            && instruction.words[3] == block {
            guard let index = instructions.first(where: { $0.opcode == Opcode.constant && $0.words.count == 4 && $0.words[2] == instruction.words[4] })?.words[3]
            else { throw .missingCarrier }
            read.insert(index)
        }
        for instruction in instructions where instruction.opcode == Opcode.load && instruction.words.count >= 4 && instruction.words[3] == block {
            throw .missingCarrier                                    // the whole block is read at once
        }
        // The last unread member that is a float or a vector of floats carries gamma, in its first component.
        var carrier: (member: UInt32, isVector: Bool, offset: UInt32)?
        for (index, type) in members.enumerated().reversed() where !read.contains(UInt32(index)) {
            let isVector = instructions.contains { $0.opcode == Opcode.typeVector && $0.words.count == 4 && $0.words[1] == type && $0.words[2] == float }
            guard isVector || type == float else { continue }
            guard let offset = instructions.first(where: {
                $0.opcode == Opcode.memberDecorate && $0.words.count == 5 && $0.words[1] == found.type && $0.words[2] == UInt32(index) && $0.words[3] == decorationOffset
            })?.words[4], offset % 4 == 0 else { continue }
            carrier = (UInt32(index), isVector, offset)
            break
        }
        guard let carrier else { throw .missingCarrier }

        // They must sit in one block, so the gamma read placed before the first is in scope for all.
        let first = selects[0], last = selects[2]
        for index in first...last where instructions[index].opcode == Opcode.label { throw .notStraightLine }
        guard let firstFunction = instructions.firstIndex(where: { $0.opcode == Opcode.function }) else { throw .missingFunction }

        func fresh() -> UInt32 {
            bound += 1
            return bound - 1
        }
        var declarations: [Instruction] = []
        let floatPointer: UInt32
        if let existingFloatPointer {
            floatPointer = existingFloatPointer
        } else {
            floatPointer = fresh()
            declarations.append(Instruction(Opcode.typePointer, [floatPointer, storageUniform, float]))
        }
        func constant(_ type: UInt32, _ bits: UInt32) -> UInt32 {
            let id = fresh()
            declarations.append(Instruction(Opcode.constant, [type, id, bits]))
            return id
        }
        let one = constant(float, Float(1).bitPattern), zero = constant(float, Float(0).bitPattern), most = constant(float, Float(4).bitPattern)
        let memberIndex = constant(int, carrier.member), firstComponent = constant(int, 0)

        // exponent = 1 / (1 < w && w <= 4 ? w : 1)
        let pointer = fresh(), w = fresh(), above = fresh(), below = fresh(), valid = fresh(), gamma = fresh(), exponent = fresh()
        let setup = [
            Instruction(Opcode.accessChain, [floatPointer, pointer, block, memberIndex] + (carrier.isVector ? [firstComponent] : [])),
            Instruction(Opcode.load, [float, w, pointer]),
            Instruction(Opcode.fOrdGreaterThan, [bool, above, w, one]),
            Instruction(Opcode.fOrdLessThanEqual, [bool, below, w, most]),
            Instruction(Opcode.logicalAnd, [bool, valid, above, below]),
            Instruction(Opcode.select, [float, gamma, valid, w, one]),
            Instruction(Opcode.fDiv, [float, exponent, one, gamma]),
        ]

        // After each select: clamp to [0, 1] (the filter can ring below zero, where a power
        // is undefined), raise to the exponent, and send every later use of the select to the result.
        var raisedIDs: [UInt32] = []
        var after: [[Instruction]] = []
        for original in results {
            let clamped = fresh(), raised = fresh()
            after.append([
                Instruction(Opcode.extInst, [float, clamped, glsl, glslFClamp, original, zero, one]),
                Instruction(Opcode.extInst, [float, raised, glsl, glslPow, clamped, exponent]),
            ])
            raisedIDs.append(raised)
        }
        for position in (first + 1)..<instructions.count {
            for which in 0..<3 where position > selects[which] && instructions[position].words.dropFirst().contains(results[which]) {
                guard let operands = instructions[position].valueOperands else { throw .unknownUse(instructions[position].opcode) }
                for operand in operands where operand < instructions[position].words.count && instructions[position].words[operand] == results[which] {
                    instructions[position].words[operand] = raisedIDs[which]
                }
            }
        }

        var out = Array(all[0..<5])
        out[3] = bound
        for (index, instruction) in instructions.enumerated() {
            if index == firstFunction { for added in declarations { out.append(contentsOf: added.words) } }
            if index == first { for added in setup { out.append(contentsOf: added.words) } }
            out.append(contentsOf: instruction.words)
            if let which = selects.firstIndex(of: index) { for added in after[which] { out.append(contentsOf: added.words) } }
        }
        return (out.bytes, Int(carrier.offset / 4))
    }
}
