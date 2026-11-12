// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import XCTest
import VRLinkCore
import VRLinkMetal

/// Draws small colored patches at known places in each eye's picture,
/// through that eye's rate map, and looks for them where `stored` says.
final class FoveatedTargetTests: XCTestCase {
    func testWhatIsDrawnIsFoundWhereStoredSays() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // A Vision Pro's frusta, as widened for the host.
        let frusta = [Frustum(left: -1.74, right: 1.01, down: -1.20, up: 1.01),
                      Frustum(left: -1.01, right: 1.74, down: -1.20, up: 1.01)]
        guard let target = FoveatedTarget(device: device, frusta: frusta) else {
            throw XCTSkip("no rasterization rate maps on this device")
        }
        // Fewer pixels stored than drawn, and room for both eyes.
        XCTAssertLessThan(target.texture.width, target.screen.width)
        XCTAssertLessThan(target.texture.height, target.screen.height * 2)

        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .bgra8Unorm))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: target.texture.width,
                                                                  height: target.texture.height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())

        // Places in a picture (from its left and top, 0 ... 1) and a color for each: middle, towards corners.
        let places: [(x: Float, y: Float)] = [(0.5, 0.5), (0.15, 0.2), (0.85, 0.8), (0.63, 0.46), (0.3, 0.9)]
        func color(_ eye: Eye, _ index: Int) -> [Float] {
            [eye == .left ? 1 : 0.25, Float(index + 1) / Float(places.count), eye == .left ? 0.25 : 1, 1]   // red, green, blue, alpha
        }
        let pose = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
        for eye in Eye.allCases {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = eye == .left ? .clear : .load
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            pass.rasterizationRateMap = target.maps[eye.rawValue]
            let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
            encoder.setViewport(target.viewport(eye))
            let frustum = frusta[eye.rawValue]
            // A patch 4% of the picture wide around each place, 10 m out.
            let patches = places.enumerated().map { index, place -> Quad in
                func corner(_ dx: Float, _ dy: Float) -> Vec3 {
                    let across = frustum.left + (place.x + dx) * (frustum.right - frustum.left)
                    let up = frustum.up - (place.y + dy) * (frustum.up - frustum.down)
                    return Vec3(across * 10, up * 10, -10)
                }
                return Quad(corners: [corner(-0.02, -0.02), corner(0.02, -0.02), corner(-0.02, 0.02), corner(0.02, 0.02)],
                            fill: color(eye, index))
            }
            for patch in patches {
                renderer.draw(eyes: [([patch], EyeView(eye: pose, frustum: frustum))], of: nil, near: 0.05, far: 100,
                              with: encoder, commands: commands)
            }
            encoder.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()

        func pixel(fromLeft: Float, fromTop: Float) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 4)
            let x = min(target.texture.width - 1, Int(fromLeft * Float(target.texture.width)))
            let y = min(target.texture.height - 1, Int(fromTop * Float(target.texture.height)))
            texture.getBytes(&out, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return out
        }
        for eye in Eye.allCases {
            for (index, place) in places.enumerated() {
                let where_ = target.stored(eye, x: place.x, y: place.y)
                let found = pixel(fromLeft: where_.fromLeft, fromTop: where_.fromTop), wanted = color(eye, index)
                // Stored blue, green, red, alpha.
                XCTAssertEqual(Float(found[2]) / 255, wanted[0], accuracy: 0.02, "\(eye) eye, place \(index), red")
                XCTAssertEqual(Float(found[1]) / 255, wanted[1], accuracy: 0.02, "\(eye) eye, place \(index), green")
                XCTAssertEqual(Float(found[0]) / 255, wanted[2], accuracy: 0.02, "\(eye) eye, place \(index), blue")
                // Just outside the patch there is nothing.
                let beside = target.stored(eye, x: place.x + 0.05, y: place.y)
                XCTAssertEqual(pixel(fromLeft: beside.fromLeft, fromTop: beside.fromTop)[3], 0, "\(eye) eye, beside place \(index)")
            }
            // The left eye's picture is in the lower half, the right's in the upper.
            let middle = target.stored(eye, x: 0.5, y: 0.5)
            XCTAssertEqual(middle.fromTop > 0.5, eye == .left)
        }
        print("foveated: an eye drawn at \(target.screen.width)x\(target.screen.height), both stored in \(target.texture.width)x\(target.texture.height)")
    }
}
