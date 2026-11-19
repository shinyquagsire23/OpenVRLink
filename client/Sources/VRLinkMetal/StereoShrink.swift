// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Foundation
import Metal
import VRLinkCore
import VRLinkVideoToolbox

/// GPU-accelerated stereo downsampler and disparity matcher for `DepthEstimator`.
///
/// Hardware-decoded `VideoToolbox` pixel buffers use lossless compression that
/// cannot be mapped for direct CPU row reads (`DepthEstimator.pair`). Instead,
/// `StereoShrink` renders each eye's tiles into a low-resolution `r8Unorm` luma
/// texture, generates mipmaps for coarser pyramid levels, and runs `matchCells`
/// (`Shrink.metal`) to compute the disparity grid on the GPU (matching the CPU
/// reference implementation in `StereoMatcher`) so only the small grid of cell
/// readings is copied back to CPU memory.
///
/// `StereoShrink` reuses a single set of render targets and is not re-entrant;
/// `DepthEstimator` serializes calls so only one frame is in flight at a time.
public final class StereoShrink {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let matching: MTLComputePipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache!
    private let width: Int
    /// Left and right downsampled luma textures, reallocated when frame height changes.
    private var targets: [MTLTexture] = []
    /// Stores `(nearness, trust, 0, 0)` for each matched cell, with one row per pyramid level.
    private var answers: MTLTexture?
    private var reportedFailure = false

    /// When `true`, periodically writes downsampled stereo pairs to disk (`StereoPair.save`) for offline debugging.
    public var savesPictures = false
    private var lastSaved: UInt64 = 0, savedCount = 0
    private static let secondsBetweenSaves = 4.0

    /// Multi-scale matching configuration shared with `matchCells`. When no custom
    /// matcher is passed to `init`, this doubles the grid resolution per axis of
    /// `StereoMatcher.fitted(toWidth:)` and enables `StereoMatcher.sampled` so only
    /// a subset of cells is matched each frame.
    public let matcher: StereoMatcher

    /// Caps how many cells are matched per frame and sets the texture width of `answers`.
    private static let mostCells = 2048

    /// Maximum pixel disparity supported by `matchCells` (`MOST_SHIFTS` in `Shrink.metal`).
    private static let mostShifts = 160

    /// - Parameter width: Horizontal resolution in pixels for each downsampled eye texture.
    public init?(device: MTLDevice, width: Int = 768, matcher: StereoMatcher? = nil) {
        self.device = device
        self.width = width
        if let matcher {
            self.matcher = matcher
        } else {
            var fine = StereoMatcher.fitted(toWidth: width)
            fine.columns *= 2
            fine.rows *= 2
            fine.sampled = true
            self.matcher = fine
        }
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        do {
            guard let url = Bundle.module.url(forResource: "Shrink", withExtension: "metal") else {
                Log.note("depth: Shrink.metal is missing from the bundle")
                return nil
            }
            let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "shrinkVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "shrinkFragment")
            descriptor.colorAttachments[0].pixelFormat = .r8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            guard let kernel = library.makeFunction(name: "matchCells") else {
                Log.note("depth: Shrink.metal has no matchCells")
                return nil
            }
            matching = try device.makeComputePipelineState(function: kernel)
        } catch {
            Log.note("depth: \(error)")
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    private func fail(_ why: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Log.note("depth: \(why)")
    }

    /// Allocates or resizes the downsampled luma textures and output grid texture for `height`.
    private func ready(height: Int) -> Bool {
        if targets.first?.height != height {
            // Allocate enough mipmap levels for the coarsest `halvings` scale.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.mipmapLevelCount = (matcher.levels.map(\.halvings).max() ?? 0) + 1
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            targets = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        }
        // Allocate `answers` with one column per matched cell and one row per pyramid level.
        if answers == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: StereoShrink.mostCells,
                                                                      height: matcher.levels.count, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            answers = device.makeTexture(descriptor: descriptor)
        }
        return targets.count == 2 && answers != nil
    }

    /// Encodes render passes to downsample both eyes of `frame` into `targets`.
    /// Returns resources that must be retained until the command buffer completes,
    /// or `nil` (after logging once) if textures or encoders cannot be created.
    private func drawEyes(of frame: DecodedFrame, plan: StereoPlan, into commands: MTLCommandBuffer) -> [Any]? {
        // Wrap each decoded buffer in a non-sRGB YCbCr Metal texture; gamma linearization
        // is unnecessary since we only compare the left and right eyes against each other.
        var wrapped: [CVMetalTexture?] = []
        for image in frame.images {
            var texture: CVMetalTexture?
            if let format = QuadRenderer.samplerConvertedFormat(for: CVPixelBufferGetPixelFormatType(image)) {
                CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, format,
                                                          CVPixelBufferGetWidthOfPlane(image, 0),
                                                          CVPixelBufferGetHeightOfPlane(image, 0), 0, &texture)
            }
            wrapped.append(texture)
        }
        let across = plan.window.right - plan.window.left, tall = plan.window.up - plan.window.down
        var kept: [Any] = [wrapped, frame.images]
        for (eye, view) in frame.layout.views.enumerated() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = targets[eye]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                fail("failed to create render command encoder")
                return nil
            }
            defer { encoder.endEncoding() }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentSamplerState(sampler, index: 0)
            // Draw tiles in reverse order so base peripheral tiles overwrite foveal insets,
            // ensuring both eyes compare matching resolution layers where tiles overlap.
            var corners: [Float] = [], pictures: [MTLTexture] = []
            for tile in view.tiles.reversed() {
                guard wrapped.indices.contains(tile.picture), let texture = wrapped[tile.picture].flatMap(CVMetalTextureGetTexture)
                else {
                    fail("failed to wrap decoded pixel buffer as a Metal texture")
                    return nil
                }
                // Inset UV bounds by half a texel so bilinear filtering doesn't sample across atlas tile borders.
                let halfU = 0.5 / Float(texture.width), halfV = 0.5 / Float(texture.height)
                let bounds = [tile.left + halfU, tile.top + halfV, tile.right - halfU, tile.bottom - halfV]
                func corner(_ x: Float, _ y: Float, _ u: Float, _ v: Float) {
                    corners += [(x - plan.window.left) / across * 2 - 1, (y - plan.window.down) / tall * 2 - 1, u, v] + bounds
                }
                let f = tile.frustum
                corner(f.left, f.up, tile.left, tile.top); corner(f.right, f.up, tile.right, tile.top)
                corner(f.left, f.down, tile.left, tile.bottom); corner(f.right, f.up, tile.right, tile.top)
                corner(f.right, f.down, tile.right, tile.bottom); corner(f.left, f.down, tile.left, tile.bottom)
                pictures.append(texture)
            }
            guard let buffer = device.makeBuffer(bytes: corners, length: corners.count * MemoryLayout<Float>.size,
                                                 options: .storageModeShared)
            else { continue }
            kept.append(buffer)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            for (index, texture) in pictures.enumerated() {
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: index * 6, vertexCount: 6)
            }
        }
        return kept
    }

    /// Generates mipmaps for `targets` and dispatches `matchCells` for each pyramid level in `matcher.levels`.
    /// Only the row-major cell indices in `cells` are matched.
    private func compare(cells: [Int], covered: [(x: Range<Int>, y: Range<Int>)], pixelsPerNearness: Float,
                         into commands: MTLCommandBuffer) -> Bool {
        let listed = cells.prefix(StereoShrink.mostCells).map { UInt32($0 % matcher.columns) | UInt32($0 / matcher.columns) << 16 }
        guard let answers, !listed.isEmpty,
              let list = device.makeBuffer(bytes: listed, length: listed.count * MemoryLayout<UInt32>.size, options: .storageModeShared)
        else { return false }
        if targets[0].mipmapLevelCount > 1 {
            guard let blit = commands.makeBlitCommandEncoder() else { return false }
            targets.forEach { blit.generateMipmaps(for: $0) }
            blit.endEncoding()
        }
        guard let encoder = commands.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(matching)
        encoder.setTexture(targets[0], index: 0)
        encoder.setTexture(targets[1], index: 1)
        encoder.setTexture(answers, index: 2)
        encoder.setBuffer(list, offset: 0, index: 1)
        for (index, level) in matcher.levels.enumerated() {
            // Shrink valid pixel bounds for each 2x mipmap step, matching `StereoPair.halved()`.
            var parts = covered
            for _ in 0..<level.halvings {
                parts = parts.map { part in
                    func each(_ range: Range<Int>) -> Range<Int> {
                        let first = (range.lowerBound + 1) / 2
                        return first ..< max(first, range.upperBound / 2)
                    }
                    return (each(part.x), each(part.y))
                }
            }
            let perNearness = pixelsPerNearness / Float(1 << level.halvings)
            let most = max(2, min((width >> level.halvings) / 3, StereoShrink.mostShifts,
                                  Int((matcher.nearest * perNearness).rounded(.up))))
            // Pack `MatchSettings` (`Shrink.metal`) as floats.
            let settings: [Float] = [
                Float(level.halvings), Float(index), Float(listed.count),
                Float(matcher.columns), Float(matcher.rows), Float(level.reach), Float(matcher.stride), Float(most),
                Float(parts[0].x.lowerBound), Float(parts[0].x.upperBound), Float(parts[0].y.lowerBound), Float(parts[0].y.upperBound),
                Float(parts[1].x.lowerBound), Float(parts[1].x.upperBound), Float(parts[1].y.lowerBound), Float(parts[1].y.upperBound),
                perNearness, level.grain, matcher.distinct.least, matcher.distinct.full,
            ]
            encoder.setBytes(settings, length: settings.count * MemoryLayout<Float>.size, index: 0)
            encoder.dispatchThreadgroups(MTLSize(width: (listed.count + 15) / 16, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
        }
        encoder.endEncoding()
        return true
    }

    /// Reads back the multi-scale output texture after GPU completion and selects the finest
    /// confident reading for each index in `cells`, leaving unmatched cells at zero confidence.
    private func readings(for cells: [Int]) -> [StereoMatcher.Reading] {
        guard let answers else { return [] }
        let count = min(cells.count, StereoShrink.mostCells), levels = matcher.levels.count
        var values = [Float](repeating: 0, count: StereoShrink.mostCells * levels * 4)
        answers.getBytes(&values, bytesPerRow: StereoShrink.mostCells * 4 * MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(0, 0, StereoShrink.mostCells, levels), mipmapLevel: 0)
        let none = StereoMatcher.Reading(nearness: 0, trust: 0)
        let byLevel = (0..<levels).map { level -> [StereoMatcher.Reading] in
            var all = [StereoMatcher.Reading](repeating: none, count: matcher.columns * matcher.rows)
            for item in 0..<count where all.indices.contains(cells[item]) {
                let at = (level * StereoShrink.mostCells + item) * 4
                all[cells[item]] = StereoMatcher.Reading(nearness: values[at], trust: values[at + 1])
            }
            return all
        }
        return StereoMatcher.finest(byLevel, worth: matcher.levels.map(\.worth))
    }

    /// Returns all grid cell indices in row-major order when `matcher.sampled` is `false`.
    private var everyCell: [Int] { Array(0..<matcher.columns * matcher.rows) }

    /// Downsamples and matches `frame` on the GPU, invoking `done` from Metal's
    /// command-buffer completion handler with the resulting `StereoMeasure`, or
    /// calling `done(nil)` immediately if the frame layout cannot be stereo-matched.
    /// When `matcher.sampled` is enabled, `interests` specifies the regions to match at full grid density.
    public func measure(_ frame: DecodedFrame, interests: [DepthSampling.Interest] = [],
                        done: @escaping (StereoMeasure?) -> Void) {
        guard let plan = StereoPlan(layout: frame.layout, width: width) else {
            fail("eye views are not parallel and horizontally separated; skipping stereo depth")
            return done(nil)
        }
        guard ready(height: plan.height), let commands = queue.makeCommandBuffer() else {
            fail("failed to allocate downsampled textures or command buffer")
            return done(nil)
        }
        let cells = matcher.cells(window: plan.window, interests: interests) ?? everyCell
        guard let kept = drawEyes(of: frame, plan: plan, into: commands),
              compare(cells: cells, covered: plan.covered, pixelsPerNearness: plan.apart * plan.perTangent, into: commands)
        else { return done(nil) }
        let now = DispatchTime.now().uptimeNanoseconds
        let saving = savesPictures && Double(now &- lastSaved) / 1e9 >= StereoShrink.secondsBetweenSaves
        if saving {
            lastSaved = now
            savedCount += 1
        }
        let targets = targets, width = width, number = savedCount
        commands.addCompletedHandler { [self] finished in
            _ = kept
            guard finished.status == .completed else { return done(nil) }
            if saving {
                // Copy pixels inside the completion handler before the next frame overwrites `targets`, then write files on a utility queue.
                let read = targets.map { target -> LumaPicture in
                    var picture = LumaPicture(width: width, height: plan.height)
                    target.getBytes(&picture.pixels, bytesPerRow: width, from: MTLRegionMake2D(0, 0, width, plan.height), mipmapLevel: 0)
                    return picture
                }
                DispatchQueue.global(qos: .utility).async { plan.pair(left: read[0], right: read[1]).save(number: number) }
            }
            done(StereoMeasure(readings: readings(for: cells), columns: matcher.columns, rows: matcher.rows, window: plan.window,
                               apart: plan.apart, pose: plan.pose))
        }
        commands.commit()
    }

    /// Downsamples both eyes of `frame` on the GPU and reads back the resulting
    /// `StereoPair` without running `matchCells`, used for testing and inspection.
    public func shrink(_ frame: DecodedFrame, done: @escaping (StereoPair?) -> Void) {
        guard let plan = StereoPlan(layout: frame.layout, width: width), ready(height: plan.height),
              let commands = queue.makeCommandBuffer(), let kept = drawEyes(of: frame, plan: plan, into: commands)
        else { return done(nil) }
        let targets = targets, height = plan.height, width = width
        commands.addCompletedHandler { finished in
            _ = kept
            guard finished.status == .completed else { return done(nil) }
            let read = targets.map { target -> LumaPicture in
                var picture = LumaPicture(width: width, height: height)
                target.getBytes(&picture.pixels, bytesPerRow: width, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                return picture
            }
            done(plan.pair(left: read[0], right: read[1]))
        }
        commands.commit()
    }

    /// Uploads an existing `StereoPair` and runs `matchCells` on the GPU to verify
    /// parity with `StereoMatcher.measureLevels`. Requires `width`-wide images
    /// whose height is a multiple of 4.
    public func match(_ pair: StereoPair, interests: [DepthSampling.Interest] = [],
                      done: @escaping ([StereoMatcher.Reading]?) -> Void) {
        guard pair.left.width == width, pair.right.width == width, pair.left.height == pair.right.height,
              ready(height: pair.left.height), let commands = queue.makeCommandBuffer()
        else { return done(nil) }
        for (target, picture) in zip(targets, [pair.left, pair.right]) {
            target.replace(region: MTLRegionMake2D(0, 0, width, picture.height), mipmapLevel: 0, withBytes: picture.pixels,
                           bytesPerRow: width)
        }
        let cells = matcher.cells(window: pair.window, interests: interests) ?? everyCell
        guard compare(cells: cells, covered: [pair.leftCovered, pair.rightCovered], pixelsPerNearness: pair.pixelsPerNearness,
                      into: commands)
        else { return done(nil) }
        commands.addCompletedHandler { [self] finished in
            done(finished.status == .completed ? readings(for: cells) : nil)
        }
        commands.commit()
    }
}
