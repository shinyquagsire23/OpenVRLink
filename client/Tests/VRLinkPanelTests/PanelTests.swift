// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore
@testable import VRLinkPanel
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

final class PanelRasterizerTests: XCTestCase {
    private func picture(_ vertices: [PanelRasterizer.Vertex], _ indices: [UInt16], size: Int = 16) -> PanelPicture {
        // Use a 2x1 font atlas where the first texel is opaque and the second is half-transparent.
        let rasterizer = PanelRasterizer(atlas: [255, 128], atlasWidth: 2, atlasHeight: 1)
        var picture = PanelPicture(width: size, height: size)
        vertices.withUnsafeBufferPointer { v in
            indices.withUnsafeBufferPointer { i in
                rasterizer.draw(v, i, clip: (0, 0, Float(size), Float(size)), into: &picture)
            }
        }
        return picture
    }

    private func vertex(_ x: Float, _ y: Float, _ color: UInt32, u: Float = 0.25) -> PanelRasterizer.Vertex {
        PanelRasterizer.Vertex(x: x, y: y, u: u, v: 0.5, color: color)
    }

    func testRectangleFillsPixelsWhoseCentersAreInside() {
        let red: UInt32 = 0xFF00_00FF
        let drawn = picture([vertex(2, 3, red), vertex(6, 3, red), vertex(6, 5, red), vertex(2, 5, red)], [0, 1, 2, 0, 2, 3])
        var filled = 0
        for y in 0..<16 {
            for x in 0..<16 where drawn.pixels[(y * 16 + x) * 4 + 3] != 0 {
                filled += 1
                XCTAssertTrue((2..<6).contains(x) && (3..<5).contains(y))
                XCTAssertEqual(Array(drawn.pixels[(y * 16 + x) * 4..<(y * 16 + x) * 4 + 4]), [255, 0, 0, 255])
            }
        }
        XCTAssertEqual(filled, 8)
    }

    func testTrianglesSharingAnEdgeBlendEachPixelOnce() {
        // Draw a semi-transparent quad as two general triangles, varying one vertex color by 1 LSB to bypass the
        // solid-rectangle fast path.
        let white: UInt32 = 0x80FF_FFFF, nearly: UInt32 = 0x80FF_FFFE
        for winding in [[0, 1, 2, 0, 2, 3], [0, 2, 1, 0, 3, 2]] as [[UInt16]] {
            let drawn = picture([vertex(1, 1, white), vertex(13, 1, white), vertex(13, 13, white), vertex(1, 13, nearly)], winding)
            for y in 1..<13 {
                for x in 1..<13 {
                    XCTAssertEqual(drawn.pixels[(y * 16 + x) * 4 + 3], 128, "pixel \(x), \(y) with winding \(winding)")
                }
            }
            XCTAssertEqual(drawn.pixels[3], 0)
        }
    }

    func testPremultipliesAndClips() {
        let rasterizer = PanelRasterizer(atlas: [255], atlasWidth: 1, atlasHeight: 1)
        var picture = PanelPicture(width: 8, height: 8)
        let blue: UInt32 = 0x80FF_0000
        let vertices = [vertex(0, 0, blue), vertex(8, 0, blue), vertex(8, 8, blue), vertex(0, 8, blue)]
        vertices.withUnsafeBufferPointer { v in
            ([0, 1, 2, 0, 2, 3] as [UInt16]).withUnsafeBufferPointer { i in
                rasterizer.draw(v, i, clip: (2, 2, 4, 4), into: &picture)
            }
        }
        XCTAssertEqual(Array(picture.pixels[(2 * 8 + 2) * 4..<(2 * 8 + 2) * 4 + 4]), [0, 0, 128, 128])
        XCTAssertEqual(picture.pixels[(4 * 8 + 4) * 4 + 3], 0)
        XCTAssertEqual(picture.pixels[(1 * 8 + 2) * 4 + 3], 0)
    }

    func testGlyphTakesCoverageFromTheAtlas() {
        let white: UInt32 = 0xFFFF_FFFF
        // Draw a 2x1 quad mapped across the 2x1 font atlas so each pixel samples one texel.
        let quad = [PanelRasterizer.Vertex(x: 4, y: 4, u: 0, v: 0, color: white), PanelRasterizer.Vertex(x: 6, y: 4, u: 1, v: 0, color: white),
                    PanelRasterizer.Vertex(x: 6, y: 5, u: 1, v: 1, color: white), PanelRasterizer.Vertex(x: 4, y: 5, u: 0, v: 1, color: white)]
        let drawn = picture(quad, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(drawn.pixels[(4 * 16 + 4) * 4 + 3], 255)
        XCTAssertEqual(drawn.pixels[(4 * 16 + 5) * 4 + 3], 128)
    }
}

/// Exercises `Panel` flows in a single test method because Dear ImGui uses a single global context.
final class PanelTests: XCTestCase {
    private final class NoServices: ServiceFinder {
        func start(onChange: @escaping ([FoundService]) -> Void) {}
        func restart() {}
    }

    private func save(_ picture: PanelPicture, as name: String) {
        #if canImport(ImageIO)
        guard let folder = ProcessInfo.processInfo.environment["PANEL_PICTURES"] else { return }
        let file = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
        guard let provider = CGDataProvider(data: Data(picture.pixels) as CFData),
              let image = CGImage(width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: picture.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let output = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(output, image, nil)
        CGImageDestinationFinalize(output)
        #endif
    }

    func testPanelDrawsTheModelAndActsOnIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("panel-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ClientModel(finder: HostFinder(services: NoServices()), folder: folder)
        var asked: [ClientModel.Target] = []
        var stopped = 0
        model.startStream = { asked.append($0) }
        model.stopStream = { _ in stopped += 1 }
        let panel = Panel(model: model, features: [.microphone, .chromaKey])
        panel.caption = "v0.0.0 test"

        // Let ImGui settle its initial layout, then verify that an unchanged model skips rasterization.
        for _ in 0..<4 { panel.update() }
        XCTAssertFalse(panel.update())
        XCTAssertGreaterThan(panel.picture.pixels.filter { $0 != 0 }.count, panel.width * panel.height)
        save(panel.picture, as: "searching")
        // Enabling quirks adds the Quirks tab and renders saved overrides.
        panel.quirks = HeadsetQuirks(.playForDream)
        model.settings.quirkOverrides = ["video_range": "narrow"]
        // ImGui lays out a newly added tab on the frame after it is first submitted.
        let first = panel.update(), second = panel.update()
        XCTAssertTrue(first || second)
        panel.quirks = nil
        model.settings.quirkOverrides = [:]
        for _ in 0..<4 { panel.update() }

        // Discovering hosts triggers a redraw.
        model.finder.onChange?([FoundHost(name: "Deskside", address: "192.168.1.20", kind: .steam),
                                FoundHost(name: "Penguin", address: "192.168.1.21", kind: .wivrn, port: 9000)])
        XCTAssertTrue(panel.update())
        panel.update()
        save(panel.picture, as: "hosts")

        // Click the first host tile to start connecting.
        func click(_ x: Float, _ y: Float) {
            panel.pointer = (x, y, false)
            panel.update()
            panel.pointer = (x, y, true)
            panel.update()
            panel.pointer = (x, y, false)
            panel.update()
            panel.pointer = nil
            panel.update()
        }
        click(200, 300)
        XCTAssertEqual(asked, [ClientModel.Target(kind: .steam, address: "192.168.1.20", name: "Deskside")])
        XCTAssertEqual(model.state.phase, .connecting)
        model.show("To pair, type 1234 into Steam on Deskside")
        panel.update()
        panel.update()
        save(panel.picture, as: "connecting")

        // A WiVRn PIN prompt replaces the status.
        let answered = expectation(description: "pin")
        Thread.detachNewThread {
            XCTAssertNil(model.askPin { false })
            answered.fulfill()
        }
        while !model.state.askingForPin { Thread.sleep(forTimeInterval: 0.01) }
        panel.update()
        panel.update()
        save(panel.picture, as: "pin")
        model.answerPin(nil)
        wait(for: [answered], timeout: 2)

        model.streamEnded("Could not connect: nobody home")
        XCTAssertEqual(model.state.phase, .choosing)
        panel.update()
        save(panel.picture, as: "failed")
        XCTAssertEqual(stopped, 0)
    }
}
