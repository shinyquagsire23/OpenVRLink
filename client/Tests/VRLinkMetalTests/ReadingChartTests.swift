// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Metal
import XCTest
import VRLinkCore
import VRLinkMetal
import VRLinkVideoToolbox

final class ReadingChartTests: XCTestCase {
    /// Extracts the luma plane of `frame` as rows of bytes ordered top-to-bottom.
    private func luma(_ frame: DecodedFrame) -> [[UInt8]] {
        let image = frame.images[0]
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0), width = CVPixelBufferGetWidthOfPlane(image, 0)
        return (0..<CVPixelBufferGetHeightOfPlane(image, 0)).map { row in
            Array(UnsafeBufferPointer(start: bytes + row * stride, count: width))
        }
    }

    func testTheChartHasSpeckleAndWritingTheRightWayUp() throws {
        let blank = try XCTUnwrap(ReadingChart.frame(heading: "", lines: [], footing: "", seed: 7))
        let written = try XCTUnwrap(ReadingChart.frame(heading: "", lines: ["HHHH HHHH"], footing: "", seed: 7))
        let before = luma(blank), after = luma(written)
        XCTAssertEqual(before.count, 512)
        XCTAssertEqual(before[0].count, 1024)

        // Background noise stays dark (`<= 120`) with multiple distinct gray levels, while text is bright (`> 200`).
        let inside = before[40..<470].flatMap { $0[40..<980] }
        XCTAssertLessThanOrEqual(inside.max()!, 120)
        XCTAssertGreaterThan(Set(inside).count, 20)

        // Using the same PRNG seed produces identical background noise, isolating the rendered text in the upper half.
        func changed(_ rows: Range<Int>) -> Int {
            rows.reduce(0) { total, row in total + zip(before[row], after[row]).filter { $0 != $1 && $1 > 200 }.count }
        }
        XCTAssertGreaterThan(changed(0..<256), 2000)
        XCTAssertEqual(changed(256..<512), 0)
    }

    func testTheChartIsAlsoAvailableAsAnImage() throws {
        let image = try XCTUnwrap(ReadingChart.image(heading: "", lines: ["HH"], footing: "", width: 256, height: 128))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 128)
    }

    func testRandomLinesAreGroupsOfThree() {
        var generator = SystemRandomNumberGenerator()
        let lines = ReadingChart.randomLines(using: &generator)
        XCTAssertEqual(lines.map { $0.split(separator: " ").count }, [3, 4, 5])
        XCTAssertTrue(lines.allSatisfy { $0.split(separator: " ").allSatisfy { $0.count == 3 } })
    }

    /// Draws the chart with `QuadRenderer` into a 256x128 BGRA target and returns its bytes.
    private func drawn(_ chart: DecodedFrame, colorFormat: MTLPixelFormat = .bgra8Unorm) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Pass linearOutput: true for sRGB targets to match the visionOS compositor path.
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: colorFormat, linearOutput: colorFormat == .bgra8Unorm_srgb))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: 256, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        let eye = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        let view = EyeView(eye: eye, frustum: Frustum(left: -1, right: 1, down: -0.5, up: 0.5))
        let quad = Quad(corners: view.frustum.corners(from: eye, distance: 2), atlasLeft: 0, atlasTop: 0, atlasRight: 1, atlasBottom: 1)
        renderer.draw([quad], of: chart, from: view, with: encoder, commands: commands)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: 256 * 128 * 4)
        target.getBytes(&pixels, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0)
        return pixels
    }

    /// Verifies that `QuadRenderer` raises sRGB values to `encodingGamma` when sampling either sRGB or linear textures.
    func testTheRendererUndoesTheEncodingGamma() throws {
        let plain = try XCTUnwrap(ReadingChart.frame(heading: "", lines: [], footing: "", seed: 3))
        var layout = FrameLayout.empty
        layout.encodingGamma = 2
        let brightened = DecodedFrame(frameID: 0, images: plain.images, layout: layout)
        for format in [MTLPixelFormat.bgra8Unorm, .bgra8Unorm_srgb] {
            let before = try drawn(plain, colorFormat: format), after = try drawn(brightened, colorFormat: format)
            // An sRGB render target re-encodes linear output to sRGB bytes, so both pixel formats produce matching byte values.
            // Only compare pixels in flat regions away from sharp edges. On a linear target, bilinear texture
            // filtering happens in sRGB space when encoding gamma is active and in linear light when it is not, so
            // edge pixels interpolate slightly differently.
            func flat(_ pixel: Int) -> Bool {
                [-4, 4, -256 * 4, 256 * 4].allSatisfy { step in
                    before.indices.contains(pixel + step + 1) && abs(Int(before[pixel + step + 1]) - Int(before[pixel + 1])) <= 24
                }
            }
            var checked = 0
            for pixel in stride(from: 0, to: before.count, by: 4 * 97) where before[pixel + 1] > 24 && flat(pixel) {
                let value = Double(before[pixel + 1]) / 255
                XCTAssertEqual(Double(after[pixel + 1]) / 255, value * value, accuracy: 0.03, "\(format) at byte \(pixel)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 50)
        }
    }

    /// Verifies that `QuadRenderer` samples the NV12 chart frame cleanly, preserving grayscale balance,
    /// the bright border, and bright text.
    func testTheRendererDrawsTheChart() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .bgra8Unorm))
        let chart = try XCTUnwrap(ReadingChart.frame(heading: "Read this aloud", lines: ["ACD EFH"], footing: "1 of 14"))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        let eye = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        let view = EyeView(eye: eye, frustum: Frustum(left: -1, right: 1, down: -0.5, up: 0.5))
        let quad = Quad(corners: view.frustum.corners(from: eye, distance: 2), atlasLeft: 0, atlasTop: 0, atlasRight: 1, atlasBottom: 1)
        renderer.draw([quad], of: chart, from: view, with: encoder, commands: commands)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: 256 * 128 * 4)
        target.getBytes(&pixels, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 256 + x) * 4..<(y * 256 + x) * 4 + 4]) }
        // Output pixels are neutral gray with none of the red clear color showing through.
        let speckle = pixel(20, 100)
        XCTAssertLessThan(speckle[2], 140, "\(speckle)")
        XCTAssertEqual(Int(speckle[0]), Int(speckle[2]), accuracy: 12, "\(speckle)")
        XCTAssertGreaterThan(pixel(0, 64)[1], 150, "bright border: \(pixel(0, 64))")
        let brightest = (0..<256).map { pixel($0, 38)[1] }.max()!
        XCTAssertGreaterThan(brightest, 200, "first-line text brightness")
    }
}
