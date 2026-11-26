// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Metal
import XCTest
@testable import VRLinkCore
import VRLinkMetal
@testable import VRLinkVideoToolbox

/// Decodes `ColorProbe` test clips with VideoToolbox, renders them through `QuadRenderer`, and verifies that
/// the output colors match full-range BT.709.
final class ColorPathTests: XCTestCase {
    private func decoded(_ clip: ColorProbe.Clip, layout: FrameLayout) throws -> DecodedFrame {
        let decoder = VideoDecoder()
        let got = expectation(description: "decoded frame")
        got.assertForOverFulfill = false
        let lock = NSLock()
        var frames: [DecodedFrame] = []
        decoder.onImage = { frame in
            lock.lock()
            frames.append(frame)
            let enough = frames.count >= 3
            lock.unlock()
            if enough { got.fulfill() }
        }
        for attempt in 0..<12 {
            decoder.decode(EncodedFrame(frameID: UInt16(attempt), data: FrameBuffer(copying: clip.units[attempt % clip.units.count]), layout: layout))
        }
        wait(for: [got], timeout: 10)
        lock.lock()
        defer { lock.unlock() }
        return try XCTUnwrap(frames.last)
    }

    /// Renders `frame` and returns the sRGB-encoded RGB values at the center of each patch.
    private func drawn(_ frame: DecodedFrame, device: MTLDevice) throws -> [[Float]] {
        let side = ColorProbe.side
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .rgba16Float))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        let eye = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        let view = EyeView(eye: eye, frustum: .symmetric(halfAngleDegrees: 45))
        let quad = Quad(corners: view.frustum.corners(from: eye, distance: 10), atlasLeft: 0, atlasTop: 0, atlasRight: 1, atlasBottom: 1)
        renderer.draw([quad], of: frame, from: view, with: encoder, commands: commands)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var halves = [UInt16](repeating: 0, count: side * side * 4)
        target.getBytes(&halves, bytesPerRow: side * 8, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        let patch = side / ColorProbe.across
        return (0..<(ColorProbe.across * ColorProbe.across)).map { index in
            let x = (index % ColorProbe.across) * patch + patch / 2, y = (index / ColorProbe.across) * patch + patch / 2
            return (0..<3).map { Float(Float16(bitPattern: halves[(y * side + x) * 4 + $0])) }
        }
    }

    func testDecodedSteamFramesRenderExpectedBT709Colors() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var layout = ColorProbe.layout
        layout.encodedWith = .bt709
        for clip in ColorProbe.clips {
            let frame = try decoded(clip, layout: layout)
            let image = try XCTUnwrap(frame.images.first)
            let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil)
            let format = CVPixelBufferGetPixelFormatType(image)
            let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) }, encoding: .ascii) ?? "?"
            let colors = try drawn(frame, device: device)
            let finding = try XCTUnwrap(ColorProbe.analyze(colors, of: clip))
            print("color path, \(clip.name): pixel format \(fourcc), matrix attachment \(matrix.map { "\($0)" } ?? "none"): \(finding.description)")
            if finding.treatment != ColorProbe.Treatment.right { for line in ColorProbe.table(colors, of: clip) { print("  " + line) } }
            XCTAssertEqual(finding.treatment, ColorProbe.Treatment.right, clip.name)
        }
    }
}
