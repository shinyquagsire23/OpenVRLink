// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Metal
import XCTest
import VRLinkCore
import VRLinkMetal
@testable import VRLinkVideoToolbox

/// Draws one flat-colored video frame into a small texture and reads a pixel back.
final class ChromaKeyTests: XCTestCase {
    private let background: [UInt8] = [0, 0, 255, 255]          // BGRA8 opaque red

    /// Creates a solid-color 64x64 NV12 frame from the given Y, Cb, and Cr byte values.
    private func frame(luma: UInt8, cb: UInt8, cr: UInt8) throws -> DecodedFrame {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &made)
        let image = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(image, [])
        for (plane, values) in [[luma], [cb, cr]].enumerated() {
            let rows = CVPixelBufferGetHeightOfPlane(image, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            let bytes = CVPixelBufferGetBaseAddressOfPlane(image, plane)!.assumingMemoryBound(to: UInt8.self)
            for index in 0..<(rows * stride) { bytes[index] = values[index % values.count] }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return DecodedFrame(frameID: 0, images: [image], layout: .empty)
    }

    /// Renders `frame` across an 8x8 render target cleared to red and returns the center BGRA pixel.
    private func middlePixel(_ renderer: QuadRenderer, _ frame: DecodedFrame, device: MTLDevice) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        // Place the eye at the origin with a quad filling its entire frustum.
        let eye = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        let view = EyeView(eye: eye, frustum: .symmetric(halfAngleDegrees: 45))
        let quad = Quad(corners: view.frustum.corners(from: eye, distance: 10), atlasLeft: 0, atlasTop: 0, atlasRight: 1, atlasBottom: 1)
        renderer.draw([quad], of: frame, from: view, with: encoder, commands: commands)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        return pixel
    }

    func testTheKeyColourShowsTheBackgroundAndFollowsChangesWithoutARebuild() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .bgra8Unorm))
        let blue = try frame(luma: 60, cb: 220, cr: 110)

        // Without chroma keying, rendering outputs the blue video frame rather than the red clear color.
        let plain = try middlePixel(renderer, blue, device: device)
        XCTAssertGreaterThan(plain[0], 150, "blue \(plain)")
        XCTAssertLessThan(plain[2], 100, "red \(plain)")

        // Keying on the rendered frame color makes the quad fully transparent, revealing the background.
        let asDrawn = [plain[2], plain[1], plain[0]].map { Float($0) / 255 }
        renderer.chromaKey = ChromaKey(color: asDrawn, near: 0.2, far: 0.4)
        XCTAssertEqual(try middlePixel(renderer, blue, device: device), background)

        // Changing the key color to red leaves the blue frame opaque without rebuilding the pipeline.
        renderer.chromaKey = ChromaKey(color: [0.9, 0.1, 0.1], near: 0.2, far: 0.4)
        XCTAssertEqual(try middlePixel(renderer, blue, device: device), plain)

        // Offset the key color and tighten the near/far thresholds so the frame color falls
        // outside the key range and renders opaque again.
        renderer.chromaKey = ChromaKey(color: [asDrawn[0], min(1, asDrawn[1] + 0.3), asDrawn[2]], near: 0.01, far: 0.02)
        XCTAssertEqual(try middlePixel(renderer, blue, device: device), plain)

        // Disabling the chroma key restores the original opaque frame.
        renderer.chromaKey = nil
        XCTAssertEqual(try middlePixel(renderer, blue, device: device), plain)
    }

    /// Verifies that partial chroma-key transparency outputs premultiplied RGB and alpha
    /// as expected by the compositor for passthrough blending.
    func testAColourBetweenTheTwoDistancesIsPartlySeenThrough() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .bgra8Unorm))
        let blue = try frame(luma: 60, cb: 220, cr: 110)
        let plain = try middlePixel(renderer, blue, device: device)
        let asDrawn = [plain[2], plain[1], plain[0]].map { Float($0) / 255 }
        // Set the key to 70% of the rendered color's brightness, which keeps the same hue and
        // saturation at an HSV distance of 0.3 * value * 2 (accounting for the 2x value weight).
        let distance = 0.3 * asDrawn.max()! * 2
        renderer.chromaKey = ChromaKey(color: asDrawn.map { $0 * 0.7 }, near: distance - 0.1, far: distance + 0.1)
        let partly = try middlePixel(renderer, blue, device: device)
        // Halfway between `near` and `far` the linear mask is 0.5, which squares to 0.25 alpha
        // under ALVR's smoothstep/squared falloff curve.
        XCTAssertEqual(Double(partly[3]) / 255, 0.25, accuracy: 0.08, "\(partly) against \(plain)")
        XCTAssertLessThan(partly[0], plain[0] / 2, "\(partly) against \(plain)")
    }
}
