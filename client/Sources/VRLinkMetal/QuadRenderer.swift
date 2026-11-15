// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Foundation
import Metal
import VRLinkCore
import VRLinkVideoToolbox

/// Renders textured or solid-color quads from an eye view by sampling a VideoToolbox frame.
///
/// `VRLinkCore` provides quad positions in world space and the caller supplies
/// the eye pose and frustum. `QuadRenderer` projects the quads into clip-space
/// vertices and issues draw calls into the caller's render pass (a window on
/// macOS or a compositor drawable on visionOS).
public final class QuadRenderer {
    private var pipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private let library: MTLLibrary
    private let colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat
    private let eyeCount: Int
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache!
    private var reportedFormat: OSType = 0
    private var placeholder: MTLTexture?
    private var reportedTextureFailure = false

    private let depthState: MTLDepthStencilState?
    private let linearOutput: Bool
    private let reversedDepth: Bool

    /// - Parameters:
    ///   - eyeCount: `1` for a single-view window, or `2` to render both eyes in
    ///     one pass using vertex amplification for a layered compositor drawable.
    ///   - depthFormat: When set to a valid format, quads write reversed depth
    ///     (`1` near, `0` far) for visionOS reprojection, which treats unwritten
    ///     depth pixels as passthrough.
    ///   - linearOutput: Set to `true` when the render target expects linear
    ///     light (an sRGB or floating-point attachment, as on visionOS). Decoded
    ///     frames are then wrapped in the sRGB variant of the YCbCr pixel format
    ///     so the hardware sampler linearizes the encoded transfer curve. Set to
    ///     `false` to pass encoded values straight through to a standard 8-bit window.
    public init?(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat = .invalid,
                 eyeCount: Int = 1, linearOutput: Bool = false) {
        self.linearOutput = linearOutput
        reversedDepth = depthFormat != .invalid
        if depthFormat != .invalid {
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .always      // quads are drawn back to front
            depth.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depth)
        } else {
            depthState = nil
        }
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.eyeCount = eyeCount
        do {
            // Compile Quad.metal from bundled source at runtime because `swift build`
            // from the command line does not compile Metal shaders.
            guard let url = Bundle.module.url(forResource: "Quad", withExtension: "metal") else {
                Log.note("renderer: Quad.metal is missing from the bundle")
                return nil
            }
            library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
            pipeline = try QuadRenderer.makePipeline(device: device, library: library, colorFormat: colorFormat,
                                                     depthFormat: depthFormat, eyeCount: eyeCount,
                                                     keyed: false)
        } catch {
            Log.note("renderer: \(error)")
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        // Bound when no frame is available yet so fragment texture slots are always valid.
        placeholder = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))
    }

    /// Optional chroma-key settings for making a target color transparent.
    /// Toggling chroma keying on or off rebuilds the render pipeline, whereas
    /// updating the key color or thresholds takes effect on the next frame at no cost.
    public var chromaKey: ChromaKey? {
        didSet {
            guard (chromaKey == nil) != (oldValue == nil) else { return }
            do {
                pipeline = try QuadRenderer.makePipeline(device: device, library: library, colorFormat: colorFormat,
                                                         depthFormat: depthFormat, eyeCount: eyeCount,
                                                         keyed: chromaKey != nil)
            } catch {
                Log.note("renderer: \(error)")
            }
        }
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat,
                                     depthFormat: MTLPixelFormat, eyeCount: Int,
                                     keyed: Bool) throws -> MTLRenderPipelineState {
        var enabled = keyed
        let constants = MTLFunctionConstantValues()
        constants.setConstantValue(&enabled, type: .bool, index: 0)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.maxVertexAmplificationCount = eyeCount
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = try library.makeFunction(name: "fragmentMain", constantValues: constants)
        descriptor.depthAttachmentPixelFormat = depthFormat
        let target = descriptor.colorAttachments[0]!
        target.pixelFormat = colorFormat
        // Dual-source blending: source 0 outputs premultiplied color/alpha to add,
        // and source 1 outputs coverage (`source1Alpha`). Blending RGB and alpha
        // identically produces the premultiplied alpha expected by mixed-immersion
        // compositors on visionOS: feathered fovea-to-base transitions stay opaque,
        // and only chroma-keyed or alpha-masked regions become transparent.
        target.isBlendingEnabled = true
        target.sourceRGBBlendFactor = .one
        target.destinationRGBBlendFactor = .oneMinusSource1Alpha
        target.sourceAlphaBlendFactor = .one
        target.destinationAlphaBlendFactor = .oneMinusSource1Alpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Returns Metal's combined biplanar YCbCr pixel format for hardware
    /// YUV-to-RGB conversion in the sampler, if supported for `pixelFormat`.
    /// See also: https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
    private static func samplerConvertedFormat(for pixelFormat: OSType) -> MTLPixelFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
            return MTLPixelFormat(rawValue: 500)     // YCBCR8_420_2P
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return MTLPixelFormat(rawValue: 505)     // YCBCR10_420_2P
        case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
            return MTLPixelFormat(rawValue: 508)     // YCBCR10_420_2P_PACKED
        default:
            return nil
        }
    }

    private func texture(for image: CVPixelBuffer) -> CVMetalTexture? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(image)
        if pixelFormat != reportedFormat {
            reportedFormat = pixelFormat
            let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: pixelFormat >> $0) }, encoding: .ascii) ?? "?"
            Log.note("decoder output: '\(fourcc)' \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))")
        }
        guard var format = QuadRenderer.samplerConvertedFormat(for: pixelFormat) else {
            // The shader-conversion fallback is not written yet.
            return nil
        }
        // Each of these formats has an sRGB variant at rawValue + 20 that returns linear light.
        if linearOutput, let linear = MTLPixelFormat(rawValue: format.rawValue + 20) { format = linear }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, image, nil, format,
            CVPixelBufferGetWidthOfPlane(image, 0), CVPixelBufferGetHeightOfPlane(image, 0), 0, &texture)
        if texture == nil, !reportedTextureFailure {
            reportedTextureFailure = true
            Log.note("renderer: could not wrap the decoded frame as Metal format \(format.rawValue) (status \(status))")
        }
        return texture
    }

    /// Draw one eye's quads, in order, as seen from `view`.
    public func draw(_ quads: [Quad], of frame: DecodedFrame, from view: EyeView,
                     with encoder: MTLRenderCommandEncoder, commands: MTLCommandBuffer) {
        draw(eyes: [(quads, view)], of: frame, near: 0.05, far: 100, with: encoder, commands: commands)
    }

    /// Draws each eye's quads in a single render pass, pairing quad `i` across
    /// eyes in each draw call. The caller must configure viewports and vertex
    /// amplification on `encoder` beforehand. Pixel buffers from `frame` are
    /// retained until `commands` completes on the GPU. Solid-color quads render
    /// even when `frame` is `nil`, while textured quads are skipped without a frame.
    public func draw(eyes: [(quads: [Quad], view: EyeView)], of frame: DecodedFrame?, near: Float, far: Float,
                     with encoder: MTLRenderCommandEncoder, commands: MTLCommandBuffer) {
        guard !eyes.isEmpty, eyes.count <= 2 else { return }
        let cvTextures = (frame?.images ?? []).map { texture(for: $0) }
        let pictures = cvTextures.map { $0.flatMap(CVMetalTextureGetTexture) }
        func picture(_ index: Int) -> MTLTexture? { pictures.indices.contains(index) ? pictures[index] : nil }
        encoder.setRenderPipelineState(pipeline)
        if let depthState { encoder.setDepthStencilState(depthState) }
        encoder.setFragmentSamplerState(sampler, index: 0)
        // Match the chroma-key color space to the sampled texture values:
        // linear light when linearOutput is enabled, or encoded sRGB values otherwise.
        let keyColor = (linearOutput ? chromaKey?.linearColor : chromaKey?.color) ?? [0, 0, 0]
        // Each eye can have a different quad layout or count (for example, when
        // eye-tracked foveation splits each eye's tiles differently). Each draw
        // call pairs one quad slot per eye; if one eye has fewer quads, its
        // remaining slots emit degenerate triangles.
        func quad(_ slot: Int, _ index: Int) -> Quad? {
            let quads = eyes[min(slot, eyes.count - 1)].quads
            return quads.indices.contains(index) ? quads[index] : nil
        }
        for index in 0..<(eyes.map { $0.quads.count }.max() ?? 0) {
            let pair = (0..<2).map { quad($0, index) }
            guard let style = pair[0] ?? pair[1] else { continue }
            // Color texture for each eye's quad at this index.
            let shown = pair.map { $0.flatMap { picture($0.picture) } }
            if style.fill == nil, zip(pair, shown).contains(where: { $0 != nil && $1 == nil }) { continue }
            encoder.setFragmentTexture(shown[0] ?? placeholder, index: 0)
            encoder.setFragmentTexture(shown[1] ?? placeholder, index: 1)
            // Optional alpha texture for each eye's quad when the frame carries separate alpha.
            let alphas = pair.map { $0?.alpha.flatMap { picture($0.picture) } }
            let hasAlpha = style.fill == nil && !zip(pair, alphas).contains(where: { $0 != nil && $1 == nil })
            encoder.setFragmentTexture(alphas[0] ?? placeholder, index: 2)
            encoder.setFragmentTexture(alphas[1] ?? placeholder, index: 3)
            // Build 4 triangle-strip vertices, each containing per-eye clip-space
            // positions, per-eye color and alpha UVs, and local quad UV coordinates.
            var vertices: [Float] = []
            for corner in 0..<4 {
                let across: Float = corner % 2 == 0 ? 0 : 1, down: Float = corner < 2 ? 0 : 1
                var positions: [Float] = [], coordinates: [Float] = [], alphaCoordinates: [Float] = []
                for slot in 0..<2 {
                    let eye = eyes[min(slot, eyes.count - 1)]
                    guard let quad = pair[slot] else {
                        // Collapse all four corners to a single point so this eye draws a zero-area quad.
                        positions += [0, 0, 0, 1]
                        coordinates += [0, 0]
                        alphaCoordinates += [0, 0]
                        continue
                    }
                    positions += eye.view.frustum.project(quad.corners[corner], from: eye.view.eye,
                                                          near: near, far: far, reversed: reversedDepth)
                    coordinates += [across == 0 ? quad.atlasLeft : quad.atlasRight,
                                    down == 0 ? quad.atlasTop : quad.atlasBottom]
                    alphaCoordinates += [(across == 0 ? quad.alpha?.left : quad.alpha?.right) ?? 0,
                                         (down == 0 ? quad.alpha?.top : quad.alpha?.bottom) ?? 0]
                }
                vertices += positions + coordinates + alphaCoordinates + [across, down, 0, 0]
            }
            // Pack the `QuadStyle` uniform buffer: feather width, alpha flag,
            // alignment padding, fill color, padded chroma-key color, and key thresholds.
            let styleValues: [Float] = [style.feather, hasAlpha ? 1 : 0, 0, 0] + (style.fill ?? [0, 0, 0, 0])
                + keyColor + [0, chromaKey?.near ?? 0, chromaKey?.far ?? 1, 0, 0]
            encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(styleValues, length: styleValues.count * MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        let images = frame?.images
        commands.addCompletedHandler { _ in _ = cvTextures; _ = images }
    }
}
