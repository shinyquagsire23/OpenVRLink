// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Metal
import XCTest
import VRLinkCore
import VRLinkMetal
import VRLinkVideoToolbox

/// Verifies that depth-warped quads match flat quads from the rendering eye and produce depth parallax from a translated eye.
final class BentQuadRenderTests: XCTestCase {
    private let size = 192
    private let renderedFrom = Pose(position: Vec3(0, 0, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
    private let tile = Frustum(left: -0.5, right: 0.5, down: -0.5, up: 0.5)

    /// Renders `quads` from `eye` into an offscreen BGRA8 texture and returns the green channel row by row.
    private func drawn(_ quads: [Quad], from eye: Pose, chart: DecodedFrame, device: MTLDevice, renderer: QuadRenderer) throws -> [[UInt8]] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        renderer.draw(quads, of: chart, from: EyeView(eye: eye, frustum: Frustum(left: -0.4, right: 0.4, down: -0.4, up: 0.4)),
                      with: encoder, commands: commands)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return (0..<size).map { row in (0..<size).map { pixels[(row * size + $0) * 4 + 1] } }
    }

    /// Mean absolute pixel difference across `rows`.
    private func difference(_ a: [[UInt8]], _ b: [[UInt8]], rows: Range<Int>) -> Double {
        var total = 0
        for row in rows { total += zip(a[row], b[row]).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } }
        return Double(total) / Double(rows.count * size)
    }

    private func flat(at distance: Float) -> [Quad] {
        [Quad(corners: tile.corners(from: renderedFrom, distance: distance), atlasLeft: 0, atlasTop: 0, atlasRight: 1, atlasBottom: 1)]
    }

    func testABentQuadLooksFlatFromWhereItWasRenderedAndShiftsByDepthFromElsewhere() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .bgra8Unorm))
        let chart = try XCTUnwrap(ReadingChart.frame(heading: "Read every letter", lines: ["ACD EFH KLN", "PRT UVX YZ2"], footing: "x"))
        // Set the lower half of the field to 1 m and the upper half to 10 m.
        var field = DepthField(columns: 2, rows: 16, window: Frustum(left: -1, right: 1, down: -0.5, up: 0.5), apart: 0.064)
        for index in field.nearness.indices where index / 2 >= 8 { field.nearness[index] = 1 }
        let layout = FrameLayout(views: [FrameLayout.View(eye: renderedFrom, tiles: [FrameLayout.Tile(frustum: tile)])], eyePixels: (size, size))
        // Zero IPD for a single-eye test view centered on the depth field.
        field.apart = 0
        let bent = Composition.quads(for: .left, layout: layout, depth: field)
        XCTAssertNotNil(bent[0].grid)

        // Viewed from the rendering eye, the warped mesh matches a flat quad pixel-for-pixel.
        let straight = try drawn(flat(at: 10), from: renderedFrom, chart: chart, device: device, renderer: renderer)
        let shaped = try drawn(bent, from: renderedFrom, chart: chart, device: device, renderer: renderer)
        XCTAssertLessThan(difference(straight, shaped, rows: 0..<size), 0.5)
        XCTAssertGreaterThan(Set(straight.flatMap { $0 }).count, 30, "chart texture rendered non-uniform detail")

        // Translating 5 cm right makes the upper half match a 10 m plane and the lower half match a 1 m plane.
        var moved = renderedFrom
        moved.position = Vec3(0.05, 0, 0)
        let far = try drawn(flat(at: 10), from: moved, chart: chart, device: device, renderer: renderer)
        let near = try drawn(flat(at: 1), from: moved, chart: chart, device: device, renderer: renderer)
        let shapedMoved = try drawn(bent, from: moved, chart: chart, device: device, renderer: renderer)
        let top = 8..<70, bottom = 122..<184
        XCTAssertLessThan(difference(shapedMoved, far, rows: top), 1.5)
        XCTAssertLessThan(difference(shapedMoved, near, rows: bottom), 1.5)
        // Confirm 1 m and 10 m planes produce measurable parallax at 5 cm translation.
        XCTAssertGreaterThan(difference(far, near, rows: bottom), 6)
        XCTAssertGreaterThan(difference(shapedMoved, far, rows: bottom), 6)
    }

    func testAFlatAndABentQuadCanBeDrawnAsOnePair() throws {
        // Exercise mixed flat/warped quad batching in `QuadRenderer` within a single draw pass.
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(QuadRenderer(device: device, colorFormat: .bgra8Unorm))
        let chart = try XCTUnwrap(ReadingChart.frame(heading: "x", lines: ["ACD"], footing: "x"))
        let field = DepthField(columns: 2, rows: 2, window: tile, apart: 0, everywhere: 0.5)
        let layout = FrameLayout(views: [FrameLayout.View(eye: renderedFrom, tiles: [FrameLayout.Tile(frustum: tile)])], eyePixels: (size, size))
        let bent = Composition.quads(for: .left, layout: layout, depth: field)
        let both = try drawn(flat(at: 10) + bent, from: renderedFrom, chart: chart, device: device, renderer: renderer)
        let one = try drawn(flat(at: 10), from: renderedFrom, chart: chart, device: device, renderer: renderer)
        XCTAssertLessThan(difference(both, one, rows: 0..<size), 0.5)
    }
}

/// Verifies GPU stereo downsampling and `matchCells` parity against CPU reference implementations.
final class StereoShrinkTests: XCTestCase {
    private let apart: Float = 0.064
    private func eye(_ aside: Float) -> Pose {
        Pose(position: Vec3(aside, 1.6, 0), right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), forward: Vec3(0, 0, -1))
    }

    /// Creates a full-range NV12 pixel buffer with luma populated by `value(column, row)` and neutral chroma.
    private func picture(width: Int, height: Int, _ value: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &made)
        let image = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(image, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        for row in 0..<height { for column in 0..<width { luma[row * stride + column] = value(column, row) } }
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 1)!, 128,
               CVPixelBufferGetHeightOfPlane(image, 1) * CVPixelBufferGetBytesPerRowOfPlane(image, 1))
        CVPixelBufferUnlockBaseAddress(image, [])
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return image
    }

    private func shrunk(_ frame: DecodedFrame, by shrink: StereoShrink) -> StereoPair? {
        let finished = expectation(description: "read back")
        var out: StereoPair?
        shrink.shrink(frame) { pair in
            out = pair
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return out
    }

    func testTheGPUShrinksAFrameAsReadingItsRowsDoes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shrink = try XCTUnwrap(StereoShrink(device: device, width: 200))
        // Build a 4-tile stacked atlas matching Steam VR Link's layout (left fovea, left base,
        // right fovea, right base), with sinusoidal patterns in the base tiles and solid white foveal insets.
        let atlas = try picture(width: 400, height: 1280) { column, row in
            let tile = row / 320, x = Double(column) / 400, y = Double(row % 320) / 320
            guard tile % 2 == 1 else { return 255 }
            return UInt8(110 + 70 * sin(x * 9 + Double(tile)) * cos(y * 7) + 20 * sin(x * 31))
        }
        let whole = Frustum(left: -1, right: 1, down: -0.8, up: 0.8), fovea = Frustum(left: -0.25, right: 0.25, down: -0.2, up: 0.2)
        func tile(_ index: Int, _ frustum: Frustum) -> FrameLayout.Tile {
            FrameLayout.Tile(frustum: frustum, top: Float(index) / 4, bottom: Float(index + 1) / 4)
        }
        // Clip the right eye's nasal frustum slightly, matching typical headset asymmetry.
        let rightWhole = Frustum(left: -0.8, right: 1, down: -0.8, up: 0.8)
        let views = [FrameLayout.View(eye: eye(-apart / 2), tiles: [tile(1, whole), tile(0, fovea)]),
                     FrameLayout.View(eye: eye(apart / 2), tiles: [tile(3, rightWhole), tile(2, fovea)])]
        let frame = DecodedFrame(frameID: 1, images: [atlas], layout: FrameLayout(views: views, eyePixels: (400, 320)))

        let onGPU = try XCTUnwrap(shrunk(frame, by: shrink))
        let onCPU = try XCTUnwrap(DepthEstimator.pair(from: frame, width: 200))
        XCTAssertEqual(onGPU.left.width, onCPU.left.width)
        XCTAssertEqual(onGPU.left.height, onCPU.left.height)
        XCTAssertEqual(onGPU.apart, onCPU.apart)
        XCTAssertEqual(onGPU.rightCovered.x, onCPU.rightCovered.x)
        XCTAssertEqual(onGPU.rightCovered.x.lowerBound, 20)
        // GPU and CPU luma match within filter/color-matrix rounding across the valid region,
        // and base tiles overwrite white foveal insets.
        for (gpu, cpu, covered) in [(onGPU.left, onCPU.left, onGPU.leftCovered), (onGPU.right, onCPU.right, onGPU.rightCovered)] {
            var worst = 0
            for row in covered.y {
                for column in covered.x {
                    worst = max(worst, abs(Int(gpu.pixels[row * 200 + column]) - Int(cpu.pixels[row * 200 + column])))
                }
            }
            XCTAssertLessThan(worst, 14)
            XCTAssertLessThan(gpu.pixels.max()!, 215)
        }
        // Pixels outside the right eye's covered frustum stay cleared to zero.
        XCTAssertEqual(onGPU.right.pixels[80 * 200 + 5], 0)
        // Reusing the same `StereoShrink` instance produces identical output on subsequent frames.
        XCTAssertEqual(try XCTUnwrap(shrunk(frame, by: shrink)).left.pixels, onGPU.left.pixels)
    }

    /// Renders a synthetic speckled scene (4 m wall with a centered 1 m panel, high contrast
    /// on the left and low contrast on the right) from horizontal eye offset `aside`.
    private func room(aside: Float, width: Int, height: Int) -> LumaPicture {
        func speck(_ i: Int, _ j: Int, _ salt: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: i &* 374761393 &+ j &* 668265263 &+ salt &* 362437)
            h = (h ^ (h >> 13)) &* 1274126177
            return Float((h ^ (h >> 16)) & 0xFF) / 255
        }
        func speckle(_ u: Float, _ v: Float, _ size: Float, _ salt: Int) -> Float {
            let x = u / size, y = v / size, x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Float(x0), fy = y - Float(y0)
            return (speck(x0, y0, salt) * (1 - fx) + speck(x0 + 1, y0, salt) * fx) * (1 - fy)
                + (speck(x0, y0 + 1, salt) * (1 - fx) + speck(x0 + 1, y0 + 1, salt) * fx) * fy
        }
        var picture = LumaPicture(width: width, height: height)
        for row in 0..<height {
            let up = Float(0.8) - (Float(row) + 0.5) / Float(height) * 1.6
            for column in 0..<width {
                let across = Float(-1) + (Float(column) + 0.5) / Float(width) * 2
                let onPanel = abs(aside + across) < 0.3 && abs(up) < 0.3
                let ahead: Float = onPanel ? 1 : 4
                let u = aside + across * ahead, v = up * ahead
                let marks = (speckle(u, v, 0.02 * ahead, onPanel ? 1 : 2) + speckle(u, v, 0.08 * ahead, onPanel ? 3 : 4)) / 2
                // High contrast on the left side, low contrast on the right.
                let strength: Float = across < 0.3 ? 160 : 14
                picture.pixels[row * width + column] = UInt8(max(0, min(255, 90 + (marks - 0.5) * strength)))
            }
        }
        return picture
    }

    func testTheKernelComparesAsTheProcessorDoes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shrink = try XCTUnwrap(StereoShrink(device: device, width: 512))
        let window = Frustum(left: -1, right: 1, down: -0.8, up: 0.8)
        var pair = StereoPair(left: room(aside: -apart / 2, width: 512, height: 408), right: room(aside: apart / 2, width: 512, height: 408),
                              window: window, apart: apart)
        // Clip the left margin of the right eye's valid region.
        pair.rightCovered = (40..<512, 0..<408)

        let finished = expectation(description: "compared")
        var onGPU: [StereoMatcher.Reading]?
        // Sample the default lattice plus a dense region of interest in the upper-left wall.
        let interests = [DepthSampling.Interest(across: -0.7, up: 0.5, radius: 0.2)]
        shrink.match(pair, interests: interests) { readings in
            onGPU = readings
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        let matcher = shrink.matcher
        XCTAssertTrue(matcher.sampled)
        XCTAssertEqual(matcher.columns, 56, "StereoShrink doubles StereoMatcher's default grid resolution per axis")
        let cells = try XCTUnwrap(matcher.cells(window: window, interests: interests))
        let gpu = try XCTUnwrap(onGPU), cpu = matcher.measureLevels(pair, cells: cells)
        XCTAssertEqual(matcher.levels.count, 2, "512 px width uses full- and half-resolution pyramid levels")
        XCTAssertEqual(gpu.count, cpu.count)
        XCTAssertEqual(gpu.count, matcher.columns * matcher.rows)
        // GPU mipmap filtering can differ by 1 LSB from CPU box filtering, flipping thresholded
        // cells right at the confidence cutoff; interior confident cells must agree.
        var believed = 0, differing = 0
        for (index, (a, b)) in zip(gpu, cpu).enumerated() {
            guard (a.trust > 0) == (b.trust > 0) else {
                differing += 1
                continue
            }
            guard a.trust > 0 else { continue }
            believed += 1
            XCTAssertEqual(a.nearness, b.nearness, accuracy: 0.03, "cell \(index)")
        }
        XCTAssertGreaterThan(believed, cells.count * 6 / 10)
        XCTAssertLessThan(differing, cells.count / 25)
        // Cells outside the sampled set are left unmatched.
        let sampled = Set(cells)
        XCTAssertTrue(gpu.indices.allSatisfy { sampled.contains($0) || gpu[$0].trust == 0 })
        // Every cell inside the region of interest is matched at full grid density.
        let dense = (0..<matcher.columns * matcher.rows).filter { index in
            let across = -1 + (Float(index % matcher.columns) + 0.5) / Float(matcher.columns) * 2
            let up = 0.8 - (Float(index / matcher.columns) + 0.5) / Float(matcher.rows) * 1.6
            return hypot(across + 0.7, up - 0.5) < 0.15
        }
        XCTAssertGreaterThan(dense.count, 40)
        XCTAssertGreaterThan(dense.filter { gpu[$0].trust > 0 }.count, dense.count * 8 / 10)
        // Verify panel and wall depths in both high-contrast and low-contrast regions, reading the
        // lattice cell (even column and row) at or just before each direction.
        func reading(across: Float, up: Float) -> StereoMatcher.Reading {
            let column = Int((across + 1) / 2 * Float(matcher.columns)) / 2 * 2, row = Int((0.8 - up) / 1.6 * Float(matcher.rows)) / 2 * 2
            return gpu[row * matcher.columns + column]
        }
        XCTAssertEqual(reading(across: 0, up: 0).nearness, 1, accuracy: 0.05)
        XCTAssertEqual(reading(across: -0.7, up: 0.5).nearness, 0.25, accuracy: 0.05)
        // Sample below `thinnedAbove` so the even lattice cell at this direction is always included.
        XCTAssertGreaterThan(reading(across: 0.7, up: 0.38).trust, 0, "low-contrast region still matches via coarser pyramid level")
        XCTAssertEqual(reading(across: 0.7, up: 0.38).nearness, 0.25, accuracy: 0.05)
    }

    func testAFrameIsMeasuredFromItsCompressedSizeToReadings() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shrink = try XCTUnwrap(StereoShrink(device: device, width: 512))
        // Render full-resolution per-eye pixel buffers of the synthetic room.
        let images = try [-apart / 2, apart / 2].map { aside -> CVPixelBuffer in
            let full = room(aside: aside, width: 1200, height: 960)
            return try picture(width: 1200, height: 960) { column, row in full.pixels[row * 1200 + column] }
        }
        let whole = Frustum(left: -1, right: 1, down: -0.8, up: 0.8)
        let views = [FrameLayout.View(eye: eye(-apart / 2), tiles: [FrameLayout.Tile(frustum: whole, picture: 0)]),
                     FrameLayout.View(eye: eye(apart / 2), tiles: [FrameLayout.Tile(frustum: whole, picture: 1)])]
        let frame = DecodedFrame(frameID: 1, images: images, layout: FrameLayout(views: views, pictures: 2, eyePixels: (1200, 960)))
        let finished = expectation(description: "measured")
        var measured: StereoMeasure?
        shrink.measure(frame) { result in
            measured = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        let measure = try XCTUnwrap(measured)
        XCTAssertEqual(measure.readings.count, measure.columns * measure.rows)
        XCTAssertEqual(measure.apart, apart, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(measure.pose).position.x, 0, accuracy: 1e-5, "cyclopean midpoint x")
        // Feeding the GPU measurements into `DepthSmoother` converges to the expected panel and wall depths.
        var smoother = DepthSmoother()
        var field = smoother.update(measure)
        for _ in 0..<6 { field = smoother.update(measure) }
        XCTAssertEqual(field.nearness(across: 0, up: 0), 1, accuracy: 0.08)
        XCTAssertEqual(field.nearness(across: -0.7, up: 0.5), 0.25, accuracy: 0.05)
        XCTAssertNotNil(field.pose)
    }

    func testAFrameThatCannotBeComparedIsAnsweredWithNothing() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shrink = try XCTUnwrap(StereoShrink(device: device, width: 200))
        let image = try picture(width: 64, height: 64) { _, _ in 100 }
        let oneEye = FrameLayout(views: [FrameLayout.View(eye: eye(0), tiles: [FrameLayout.Tile(frustum: .symmetric(halfAngleDegrees: 45))])],
                                 eyePixels: (64, 64))
        XCTAssertNil(shrunk(DecodedFrame(frameID: 1, images: [image], layout: oneEye), by: shrink))
        // Two eye views referencing a missing second pixel buffer.
        let tiles = { (picture: Int) in [FrameLayout.Tile(frustum: .symmetric(halfAngleDegrees: 45), picture: picture)] }
        let two = FrameLayout(views: [FrameLayout.View(eye: eye(-apart / 2), tiles: tiles(0)),
                                      FrameLayout.View(eye: eye(apart / 2), tiles: tiles(1))], pictures: 2, eyePixels: (64, 64))
        XCTAssertNil(shrunk(DecodedFrame(frameID: 1, images: [image], layout: two), by: shrink))
    }
}
