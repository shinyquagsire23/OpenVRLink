// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class VergenceTestTests: XCTestCase {
    func testEveryDistanceIsShownOutAndBack() {
        let test = VergenceTest(order: [1, 0.5, 2], settle: 1, record: 3)
        XCTAssertEqual(test.steps, [1, 0.5, 2, 2, 0.5, 1])
        XCTAssertEqual(test.duration, 24)
        XCTAssertNil(test.step(at: -0.1))
        XCTAssertNil(test.step(at: 24))

        let first = test.step(at: 0.5)
        XCTAssertEqual(first?.index, 0)
        XCTAssertEqual(first?.distance, 1)
        XCTAssertEqual(first?.recording, false, "still within initial settling window")
        XCTAssertEqual(test.step(at: 1)?.recording, true)
        XCTAssertEqual(test.step(at: 3.9)?.index, 0)

        let fourth = test.step(at: 12.5)
        XCTAssertEqual(fourth?.index, 3)
        XCTAssertEqual(fourth?.distance, 2)
        XCTAssertEqual(fourth?.recording, false)
        XCTAssertEqual(test.step(at: 23.9)?.index, 5)
    }

    /// Generates synthetic samples at `distances` following `gain * nearness + offset` with alternating `±wobble`.
    private func samples(_ distances: [Float], gain: Float, offset: Float, wobble: Float = 0) -> [VergenceSample] {
        var out: [VergenceSample] = []
        for (step, distance) in distances.enumerated() {
            for index in 0..<40 {
                out.append(VergenceSample(step: step, seconds: Double(step * 40 + index) / 30, distance: distance,
                                          signal: gain / distance + offset + wobble * (index % 2 == 0 ? 1 : -1)))
            }
        }
        return out
    }

    func testTheLineThroughTheStepsIsFound() throws {
        // Simulate a negative-slope vergence signal (as produced by a mirrored camera feed).
        let report = VergenceReport(samples([0.5, 1, 2, 4], gain: -0.04, offset: 0.1, wobble: 0.004))
        XCTAssertEqual(report.rows.count, 4)
        XCTAssertEqual(report.rows[1].nearness, 1, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(report.rows[1].signal).median, 0.06, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(report.rows[1].signal).scatter, 0.004, accuracy: 1e-4)

        let fit = try XCTUnwrap(report.fit)
        XCTAssertEqual(fit.gain, -0.04, accuracy: 1e-4)
        XCTAssertEqual(fit.offset, 0.1, accuracy: 1e-4)
        XCTAssertEqual(fit.leftover, 0, accuracy: 1e-4)
        XCTAssertEqual(fit.explained, 1, accuracy: 1e-3)
        XCTAssertTrue(fit.usable)
        XCTAssertEqual(fit.nearness(for: 0.06), 1, accuracy: 1e-3, "signal 0.06 maps to 1 m")
        XCTAssertEqual(fit.readingError, 0.1, accuracy: 1e-3, "0.004 scatter / 0.04 gain = 0.1 m^-1")
        XCTAssertTrue(report.lines.contains { $0.contains("a single reading would read") })
    }

    func testASignalThatIgnoresDistanceIsCalledUnusable() throws {
        // Generate distance-independent periodic values across six steps.
        var taken: [VergenceSample] = []
        for (step, distance) in [Float(0.5), 1, 2, 4, 0.7, 3].enumerated() {
            for index in 0..<40 {
                taken.append(VergenceSample(step: step, seconds: 0, distance: distance,
                                            signal: Float((index + step * 7) % 4) * 0.01 + (step % 2 == 0 ? 0.001 : 0)))
            }
        }
        let report = VergenceReport(taken)
        XCTAssertFalse(try XCTUnwrap(report.fit).usable)
        XCTAssertTrue(report.lines.contains { $0.contains("not usable") })
    }

    func testReadingsAwayFromTheChartAreLeftOut() throws {
        var taken = samples([0.5, 1, 2], gain: 1, offset: 0)
        // Inject off-target gaze spikes on every fourth sample of step 1.
        for index in taken.indices where taken[index].step == 1 && index % 4 == 0 {
            taken[index].offTarget = 0.4
            taken[index].signal = 9
        }
        let report = VergenceReport(taken)
        XCTAssertEqual(report.rows[1].taken, 40)
        XCTAssertEqual(report.rows[1].kept, 30)
        XCTAssertEqual(try XCTUnwrap(report.rows[1].signal).median, 1, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(report.fit).gain, 1, accuracy: 1e-3)
    }

    func testFewReadingsAndEmptyRunsDoNotBreakTheReport() {
        XCTAssertTrue(VergenceReport([]).rows.isEmpty)
        XCTAssertNil(VergenceReport([]).fit)
        XCTAssertFalse(VergenceReport([]).lines.isEmpty)

        // Provide valid samples at only two distances while marking all samples at the third distance off-target.
        var taken = samples([0.5, 1, 2], gain: 1, offset: 0)
        for index in taken.indices where taken[index].step == 2 { taken[index].offTarget = 1 }
        let report = VergenceReport(taken)
        XCTAssertNil(report.rows[2].signal)
        XCTAssertNil(report.fit, "linear regression requires at least three distinct distances")
        XCTAssertEqual(report.lines.count, 4)
    }

    func testTheSamplesCanBeTakenAwayAsATable() {
        let eyes = EyeFeatures(leftAcross: 0.05, leftDown: 0.01, rightAcross: -0.03, rightDown: 0.02)
        XCTAssertEqual(eyes.converging, 0.08, accuracy: 1e-6)
        let sample = VergenceSample(step: 1, seconds: 2.5, distance: 0.5, signal: eyes.converging, eyes: eyes)
        let rows = VergenceReport.csv([sample, VergenceSample(step: 0, seconds: 3, distance: 1, signal: 0.1)], steps: [1.2, 0.4])
            .split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, rows[1].count)
        XCTAssertEqual(rows[0].count, rows[2].count)
        XCTAssertEqual(rows[1][0], "1")
        XCTAssertEqual(rows[1][1], "0.40000")
        XCTAssertEqual(rows[1][4], "2.00000")
        XCTAssertEqual(rows[1][5], "0.08000")
        XCTAssertEqual(rows[1][7], "0.05000")
        XCTAssertEqual(rows[2][7], "", "empty landmark columns when eyes is nil")
    }
}
