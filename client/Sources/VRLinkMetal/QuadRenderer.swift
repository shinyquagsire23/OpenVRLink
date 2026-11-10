// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreVideo
import Foundation
import Metal
import VRLinkCore
import VRLinkVideoToolbox

/// Draws quads through an eye view, sampling a VideoToolbox frame.
///
/// It decides nothing about geometry: the core says where each quad stands in
/// the world and the caller says where the eye is. This class turns those
/// into clip-space vertices and a draw call, inside a render pass the caller
/// owns - a window's on macOS, the compositor's on visionOS.
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
    ///   - eyeCount: 1 for a window; 2 to draw both eyes in one pass with
    ///     vertex amplification, as a layered compositor drawable needs.
    ///   - depthFormat: when given, quads also write depth, reversed (1 near,
    ///     0 far) - visionOS reprojects using it and treats unwritten depth as empty.
    ///   - linearOutput: true when the render target expects linear light (an
    ///     sRGB or floating-point target, as on visionOS): the decoded frame
    ///     is then sampled through the sRGB variant of its texture format, so
    ///     the sampler also undoes the stream's transfer curve. False passes
    ///     the stream's encoded values straight through, for a plain 8-bit window.
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
            // Quad.metal travels as source and is compiled here: building the
            // package from the command line does not compile Metal files.
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
        // Bound when there is no frame yet, so the shader always has a texture.
        placeholder = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))
    }

    /// The color of the picture to see through, if any. Turning keying on
    /// or off builds the pipeline again; changing the color or distances
    /// costs nothing and shows in the next frame.
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
        // The shader gives the color to add (already multiplied by how
        // opaque it is) and, separately, how much of the target it covers.
        // Color and alpha are treated alike, so the target ends up holding
        // what a compositor that lays the picture over the room wants
        // (visionOS, mixed immersion): opaque where the fovea fades into the
        // base tile, see-through only where the chroma key made it so.
        target.isBlendingEnabled = true
        target.sourceRGBBlendFactor = .one
        target.destinationRGBBlendFactor = .oneMinusSource1Alpha
        target.sourceAlphaBlendFactor = .one
        target.destinationAlphaBlendFactor = .oneMinusSource1Alpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Metal's single-texture YCbCr formats, whose sampler does the YUV->RGB
    /// conversion in hardware.
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
        // Each of these formats has an sRGB twin 20 higher that returns linear light.
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

    /// Draw each eye's quads as seen from that eye, all in one pass. Every eye
    /// must have the same number of quads; quad n of each eye is drawn together.
    /// The caller has set viewports and vertex amplification on the encoder.
    /// The frame is kept alive until `commands` has finished on the GPU.
    /// Flat-colored quads need no frame; quads that show the frame are skipped without one.
    public func draw(eyes: [(quads: [Quad], view: EyeView)], of frame: DecodedFrame?, near: Float, far: Float,
                     with encoder: MTLRenderCommandEncoder, commands: MTLCommandBuffer) {
        guard let first = eyes.first, eyes.count <= 2 else { return }
        let cvTexture = frame.flatMap { texture(for: $0.image) }
        let atlas = cvTexture.flatMap(CVMetalTextureGetTexture)
        encoder.setRenderPipelineState(pipeline)
        if let depthState { encoder.setDepthStencilState(depthState) }
        encoder.setFragmentTexture(atlas ?? placeholder, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        // The key color is compared with the picture as it is sampled:
        // linear light for a linear target, encoded values otherwise.
        let keyColor = (linearOutput ? chromaKey?.linearColor : chromaKey?.color) ?? [0, 0, 0]
        for index in first.quads.indices {
            if first.quads[index].fill == nil, atlas == nil { continue }
            // Four corners; per corner: a clip position per eye, an atlas
            // coordinate per eye, and the corner's place within the quad.
            var vertices: [Float] = []
            for corner in 0..<4 {
                let across: Float = corner % 2 == 0 ? 0 : 1, down: Float = corner < 2 ? 0 : 1
                var positions: [Float] = [], coordinates: [Float] = []
                for slot in 0..<2 {
                    let eye = eyes[min(slot, eyes.count - 1)]
                    let quad = eye.quads[index]
                    positions += eye.view.frustum.project(quad.corners[corner], from: eye.view.eye,
                                                          near: near, far: far, reversed: reversedDepth)
                    coordinates += [across == 0 ? quad.atlasLeft : quad.atlasRight,
                                    down == 0 ? quad.atlasTop : quad.atlasBottom]
                }
                vertices += positions + coordinates + [across, down, 0, 0]
            }
            // QuadStyle: the feather, padding to the color's alignment, the
            // fill color, the key color (padded), the key distances (padded).
            let style: [Float] = [first.quads[index].feather, 0, 0, 0] + (first.quads[index].fill ?? [0, 0, 0, 0])
                + keyColor + [0, chromaKey?.near ?? 0, chromaKey?.far ?? 1, 0, 0]
            encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(style, length: style.count * MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        let image = frame?.image
        commands.addCompletedHandler { _ in _ = cvTexture; _ = image }
    }
}
