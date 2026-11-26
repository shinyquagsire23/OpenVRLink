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
}
