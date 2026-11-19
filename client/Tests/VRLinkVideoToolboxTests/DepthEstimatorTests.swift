// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import XCTest
import VRLinkCore
@testable import VRLinkVideoToolbox

final class DepthEstimatorTests: XCTestCase {
    private let apart: Float = 0.064
    private let frustum = Frustum(left: -1, right: 1, down: -0.8, up: 0.8)
    private func eye(_ aside: Float, turned: Float = 0) -> Pose {
        Pose(position: Vec3(aside, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
            .turned(by: Vec3(0, turned, 0))
    }

    /// Evaluates synthetic multi-scale noise on a wall `ahead` meters away as seen from horizontal offset `aside`.
    private func wall(_ across: Float, _ up: Float, aside: Float, ahead: Float) -> UInt8 {
        func speck(_ size: Float, _ salt: Int) -> Float {
            let x = (aside + across * ahead) / size, y = up * ahead / size
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Float(x0), fy = y - Float(y0)
            func at(_ i: Int, _ j: Int) -> Float {
                var h = UInt32(truncatingIfNeeded: i &* 374761393 &+ j &* 668265263 &+ salt &* 362437)
                h = (h ^ (h >> 13)) &* 1274126177
                return Float((h ^ (h >> 16)) & 0xFF) / 255
            }
            return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
        }
        return UInt8(20 + 200 * (speck(0.03 * ahead, 1) + speck(0.12 * ahead, 2)) / 2)
    }

    /// Creates an 8-bit or 10-bit biplanar YCbCr pixel buffer with luma populated by `value(column, row)`.
    private func picture(width: Int, height: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                         _ value: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &made)
        let image = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let wide = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 2
        for row in 0..<height {
            for column in 0..<width {
                if wide == 1 {
                    bytes[row * stride + column] = value(column, row)
                } else {
                    // Pack 8-bit luma into the upper bits of a 16-bit little-endian P010 sample.
                    let ten = UInt16(value(column, row)) << 8
                    bytes[row * stride + column * 2] = UInt8(ten & 0xFF)
                    bytes[row * stride + column * 2 + 1] = UInt8(ten >> 8)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }

    /// Builds a stereo `DecodedFrame` viewing a textured wall `ahead` meters away.
    private func wallFrame(ahead: Float, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                           rightTurned: Float = 0) throws -> DecodedFrame {
        let width = 800, height = 640
        let images = try [-apart / 2, apart / 2].map { aside in
            try picture(width: width, height: height, format: format) { column, row in
                self.wall(self.frustum.left + (Float(column) + 0.5) / Float(width) * 2,
                          self.frustum.up - (Float(row) + 0.5) / Float(height) * 1.6, aside: aside, ahead: ahead)
            }
        }
        let views = [FrameLayout.View(eye: eye(-apart / 2), tiles: [FrameLayout.Tile(frustum: frustum, picture: 0)]),
                     FrameLayout.View(eye: eye(apart / 2, turned: rightTurned), tiles: [FrameLayout.Tile(frustum: frustum, picture: 1)])]
        return DecodedFrame(frameID: 1, images: images, layout: FrameLayout(views: views, pictures: 2, eyePixels: (width, height)))
    }

    func testBothEyesAreShrunkOntoTheSameWindow() throws {
        let pair = try XCTUnwrap(DepthEstimator.pair(from: try wallFrame(ahead: 2), width: 200))
        XCTAssertEqual(pair.left.width, 200)
        XCTAssertEqual(pair.left.height, 160)
        XCTAssertEqual(pair.right.pixels.count, 200 * 160)
        XCTAssertEqual(pair.apart, apart, accuracy: 1e-5)
        XCTAssertEqual(pair.window.left, -1, accuracy: 1e-5)
        XCTAssertEqual(pair.leftCovered.x, 0..<200)
        XCTAssertEqual(pair.leftCovered.y, 0..<160)
        // Downsampled pixels match the wall's luma at each ray tangent within 2x2 filter averaging.
        for (column, row) in [(20, 20), (100, 80), (180, 140)] {
            let across = Float(-1) + (Float(column) + 0.5) / 100, up = Float(0.8) - (Float(row) + 0.5) / 100
            XCTAssertEqual(Int(pair.left.pixels[row * 200 + column]), Int(wall(across, up, aside: -apart / 2, ahead: 2)), accuracy: 12)
            XCTAssertEqual(Int(pair.right.pixels[row * 200 + column]), Int(wall(across, up, aside: apart / 2, ahead: 2)), accuracy: 12)
        }
    }

    func testTilesOfOneAtlasAreEachReadFromTheirOwnPart() throws {
        // Build a 4-tile stacked atlas matching Steam VR Link's layout (left fovea, left base,
        // right fovea, right base) with distinct constant luma per tile.
        let atlas = try picture(width: 64, height: 256) { _, row in [UInt8(200), 50, 220, 90][row / 64] }
        let fovea = Frustum(left: -0.25, right: 0.25, down: -0.2, up: 0.2)
        func tile(_ index: Int, _ frustum: Frustum) -> FrameLayout.Tile {
            FrameLayout.Tile(frustum: frustum, top: Float(index) / 4, bottom: Float(index + 1) / 4)
        }
        let views = [FrameLayout.View(eye: eye(-apart / 2), tiles: [tile(1, frustum), tile(0, fovea)]),
                     FrameLayout.View(eye: eye(apart / 2), tiles: [tile(3, frustum), tile(2, fovea)])]
        let frame = DecodedFrame(frameID: 1, images: [atlas], layout: FrameLayout(views: views, eyePixels: (64, 64)))
        let pair = try XCTUnwrap(DepthEstimator.pair(from: frame, width: 100))
        // Base tiles take precedence over foveal insets so both eyes compare matching resolution layers.
        XCTAssertEqual(Set(pair.left.pixels), [50])
        XCTAssertEqual(Set(pair.right.pixels), [90])
    }

    func testTenBitPicturesAreReadToo() throws {
        let frame = try wallFrame(ahead: 2, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let eight = try XCTUnwrap(DepthEstimator.pair(from: try wallFrame(ahead: 2), width: 200))
        let ten = try XCTUnwrap(DepthEstimator.pair(from: frame, width: 200))
        XCTAssertEqual(ten.left.pixels, eight.left.pixels)
    }

    func testFramesThatCannotBeComparedGiveNothing() throws {
        // Reject non-parallel eye orientations.
        XCTAssertNil(DepthEstimator.pair(from: try wallFrame(ahead: 2, rightTurned: 0.1), width: 200))
        // Reject monocular layouts or tiles referencing missing images.
        let whole = try wallFrame(ahead: 2)
        let oneEye = FrameLayout(views: [whole.layout.views[0]], eyePixels: (1, 1))
        XCTAssertNil(DepthEstimator.pair(from: DecodedFrame(frameID: 1, images: whole.images, layout: oneEye), width: 200))
        XCTAssertNil(DepthEstimator.pair(from: DecodedFrame(frameID: 1, images: [whole.images[0]], layout: whole.layout), width: 200))
        // Reject non-YCbCr pixel formats.
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &made)
        let other = try XCTUnwrap(made)
        XCTAssertNil(DepthEstimator.pair(from: DecodedFrame(frameID: 1, images: [other, other], layout: whole.layout), width: 200))
    }

    func testOfferedFramesBecomeAFieldAtTheWallsDistance() throws {
        let estimator = DepthEstimator(width: 256)
        XCTAssertNil(estimator.field)
        let frame = try wallFrame(ahead: 2)
        // Repeatedly offer frames until at least 4 are processed; concurrent offers while busy are skipped.
        let deadline = Date().addingTimeInterval(20)
        while (estimator.report?.taken ?? 0) < 4, Date() < deadline {
            estimator.offer(frame)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let field = try XCTUnwrap(estimator.field)
        let report = try XCTUnwrap(estimator.report)
        XCTAssertGreaterThanOrEqual(report.taken, 4)
        XCTAssertGreaterThan(report.measured, 0.6)
        XCTAssertEqual(field.nearness(across: 0, up: 0), 0.5, accuracy: 0.06)
        XCTAssertEqual(field.nearness(across: -0.5, up: 0.4), 0.5, accuracy: 0.06)
        XCTAssertEqual(report.ahead, 0.5, accuracy: 0.06)
        print("depth estimate took \(report.milliseconds) ms per frame in this build")

        estimator.forget()
        XCTAssertNil(estimator.field)
        XCTAssertNil(estimator.report)
    }

    func testOnlySoManyFramesASecondAreTaken() throws {
        let estimator = DepthEstimator(width: 64, most: 10)
        let frame = try wallFrame(ahead: 2)
        // Offering every 5 ms over 0.55 s with `most: 10` Hz caps accepted frames to ~5-6.
        let until = Date().addingTimeInterval(0.55)
        var offered = 0
        while Date() < until {
            estimator.offer(frame)
            offered += 1
            Thread.sleep(forTimeInterval: 0.005)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let report = try XCTUnwrap(estimator.report)
        XCTAssertGreaterThanOrEqual(report.taken, 3)
        XCTAssertLessThanOrEqual(report.taken, 7)
        XCTAssertGreaterThan(offered, 40)
    }
}
