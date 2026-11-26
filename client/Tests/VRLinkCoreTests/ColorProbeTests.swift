// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class ColorProbeTests: XCTestCase {
    /// Simulates 8-bit render-target quantization on a color encoded as `value / 2 + 0.25`.
    private func read(_ color: [Float]) -> [Float] {
        color.map { ((($0 / 2 + 0.25) * 255).rounded() / 255 - 0.25) * 2 }
    }

    func testEveryTreatmentIsDistinguished() throws {
        for clip in ColorProbe.clips {
            for treatment in ColorProbe.Treatment.all {
                let measured = clip.patches.map { read(treatment.color(of: $0, bits: clip.bits)) }
                let finding = try XCTUnwrap(ColorProbe.analyze(measured, of: clip))
                XCTAssertEqual(finding.treatment, treatment, "\(clip.name) \(treatment.description)")
                XCTAssertLessThan(finding.worst, 0.01)
            }
        }
    }

    func testEightBitCorrectionRestoresExpectedColors() {
        let clip = ColorProbe.clips[1]
        XCTAssertEqual(clip.bits, 8)
        for treatment in ColorProbe.Treatment.all {
            let fix = treatment.correction(bits: 8)
            for patch in clip.patches {
                let seen = treatment.color(of: patch, bits: 8) + [1], wanted = ColorProbe.Treatment.right.color(of: patch, bits: 8)
                for channel in 0..<3 {
                    let fixed = (0..<4).reduce(Float(0)) { $0 + fix[channel * 4 + $1] * seen[$1] }
                    XCTAssertEqual(fixed, wanted[channel], accuracy: 0.0005, "\(treatment.description) \(patch)")
                }
            }
        }
    }

    func testTenBitCorrectionRestoresExpectedColors() {
        for treatment in ColorProbe.Treatment.all {
            let fix = treatment.correction
            for patch in ColorProbe.patches {
                let seen = treatment.color(of: patch) + [1], wanted = ColorProbe.Treatment.right.color(of: patch)
                for channel in 0..<3 {
                    let fixed = (0..<4).reduce(Float(0)) { $0 + fix[channel * 4 + $1] * seen[$1] }
                    XCTAssertEqual(fixed, wanted[channel], accuracy: 0.0005, "\(treatment.description) \(patch)")
                }
            }
        }
        XCTAssertEqual(zip(ColorProbe.Treatment.right.correction, ColorProbe.noCorrection).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1e-5)
    }

    func testNarrowRangeStretchMapsBlackBelowZero() {
        // Narrow-range expansion maps full-range black (Y' = 0) to a negative float value.
        let black = ColorProbe.Treatment(matrix: .bt2020, stretched: true).color(of: ColorProbe.patches[0])
        XCTAssertEqual(black[0], -64.0 / 876, accuracy: 1e-4)
    }

    func testUnmatchedColorsReturnNilTreatment() throws {
        let odd = ColorProbe.patches.map { patch in ColorProbe.Treatment.right.color(of: patch).map { $0 * 0.7 + 0.1 } }
        let finding = try XCTUnwrap(ColorProbe.analyze(odd))
        XCTAssertNil(finding.treatment)
        XCTAssertEqual(ColorProbe.table(odd).count, 16)
        XCTAssertNil(ColorProbe.analyze([[0, 0, 0]]))
    }

    func testTheAccessUnitIsOneKeyframeWithItsParameterSets() {
        for clip in ColorProbe.clips {
            XCTAssertEqual(clip.units.count, 3, clip.name)
            let bytes = clip.units[0]
            var kinds: [UInt8] = []
            for at in 0..<(bytes.count - 4) where bytes[at] == 0 && bytes[at + 1] == 0 && bytes[at + 2] == 1 {
                kinds.append(bytes[at + 3] >> 1 & 0x3F)
            }
            XCTAssertEqual(kinds, [32, 33, 34, 20], clip.name)   // VPS, SPS, PPS, IDR
        }
    }

    func testBT2020CorrectionMatchesVRLinkShaderMatrix() {
        // `_valve1_d2020d709` from `vrlink`'s fragment shader (row-major 3x4). SteamVR hosts encode with
        // BT.709, and this matrix converts a BT.2020 sampler output back to BT.709 RGB.
        let valve: [Float] = [1.04988847, -0.04433306, -0.005557, 0,
                              0.05442289, 0.96052738, -0.01509698, 0,
                              0.00393458, 0.01122383, 0.98628952, 0]
        let ours = ColorProbe.Treatment(matrix: .bt2020, stretched: false).correction
        for (a, b) in zip(ours, valve) { XCTAssertEqual(a, b, accuracy: 0.003) }
    }

    func testHostChromaKeyCapabilitiesAndFrameMetadata() {
        var profile = DeviceProfile()
        XCTAssertEqual(profile.capabilities, [1] + Bytes(repeating: 0, count: 31))
        XCTAssertNil(profile.startupValues()[DeviceProfile.ValueID.chromaKey])
        profile.hostChromaKey = true
        // Sets bits 45 and 47 in the first 64-bit capability word alongside bit 0.
        XCTAssertEqual(Array(profile.capabilities.prefix(8)), [1, 0, 0, 0, 0, 0xA0, 0, 0])
        XCTAssertEqual(profile.startupValues()[DeviceProfile.ValueID.chromaKey], [2, 0, 0, 0, 0, 0, 0, 0])

        // Encode green key color (2 in bits 11...13) and room dimming (bit 10) in the u16 flags at +0xEE.
        var header = Bytes(repeating: 0, count: 0xF0)
        header[0xEA] = 0x80; header[0xEB] = 0x04; header[0xEC] = 0x80; header[0xED] = 0x04     // 1152 x 1152 tiles
        header[0xE6] = 0x80; header[0xE7] = 0x04; header[0xE8] = 0x00; header[0xE9] = 0x12     // 1152 x 4608 atlas
        header[0xEE] = 0x00; header[0xEF] = 0x14
        // Center each eye's foveal tile inside a 2304 x 2304 virtual base view.
        for eye in [0xC8, 0xD0] {
            for (at, value) in [(0, 576), (2, 576), (4, 2304), (6, 2304)] {
                header[eye + at] = UInt8(value & 0xFF); header[eye + at + 1] = UInt8(value >> 8)
            }
        }
        let metadata = FrameMetadata(header)
        XCTAssertEqual(metadata.keyColor, 2)
        XCTAssertTrue(metadata.keyDims)
        let layout = metadata.layout(profile: profile)
        XCTAssertEqual(layout.hostKey?.rgb, [0, 1, 0])
        XCTAssertTrue(layout.transparent)
        XCTAssertEqual(layout.encodedWith, .bt709)
        // Host chroma key flags are ignored when hostChromaKey is disabled, and color values 0 and 7 mean disabled.
        profile.hostChromaKey = false
        XCTAssertNil(metadata.layout(profile: profile).hostKey)
        XCTAssertNil(FrameLayout.HostKey(color: 0))
        XCTAssertNil(FrameLayout.HostKey(color: 7))
        XCTAssertEqual(FrameLayout.HostKey(color: 5)?.rgb, [1, 0, 1])

        // Keyed layouts populate `covered` on the base quad where the feathered foveal quad overlaps it.
        profile.hostChromaKey = true
        let keyed = metadata.layout(profile: profile)
        let quads = Composition.quads(for: .left, layout: keyed)
        let covered = try? XCTUnwrap(quads.first?.covered)
        XCTAssertNil(quads.last?.covered)
        if let covered, let under = keyed.views.first?.tiles.first?.frustum, let over = keyed.views.first?.tiles.last?.frustum {
            XCTAssertEqual(covered.left, (over.left - under.left) / (under.right - under.left), accuracy: 1e-5)
            XCTAssertEqual(covered.bottom, (under.up - over.down) / (under.up - under.down), accuracy: 1e-5)
            XCTAssertEqual(covered.feather, FrameMetadata.foveaFeather)
        }
        profile.hostChromaKey = false
        XCTAssertNil(Composition.quads(for: .left, layout: metadata.layout(profile: profile)).first?.covered)
    }
}
