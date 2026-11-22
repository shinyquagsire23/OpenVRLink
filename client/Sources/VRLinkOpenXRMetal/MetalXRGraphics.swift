// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if canImport(Metal)
import COpenXR
import CoreGraphics
import Foundation
import ImageIO
import Metal
import VRLinkCore
import VRLinkMetal
import VRLinkOpenXR
import VRLinkVideoToolbox

extension DecodedFrame: StreamFrame {
    public var pictureCount: Int { images.count }
}

extension VideoDecoder: StreamDecoder {}

/// Renders OpenXR swapchains using Metal (`XR_KHR_metal_enable`), sharing `QuadRenderer` and VideoToolbox
/// `DecodedFrame` textures with the visionOS compositor and macOS viewer.
public final class MetalXRGraphics: XRGraphics {
    public typealias Frame = DecodedFrame

    public static let extensions = ["XR_KHR_metal_enable"]

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var renderer: QuadRenderer?
    /// Metal textures for each eye's swapchain images.
    private var textures: [[MTLTexture]] = []

    public var chromaKey: ChromaKey? {
        didSet { renderer?.chromaKey = chromaKey }
    }

    /// Optional directory where a PNG of the left eye's swapchain texture is saved every 2 seconds for debugging.
    public var picturesFolder: URL?
    private var lastPicture = Date.distantPast
    private var picturesSaved = 0

    public init() {}

    public func prepare(instance: XRInstance) throws {
        let requirements = try instance.function("xrGetMetalGraphicsRequirementsKHR", as: PFN_xrGetMetalGraphicsRequirementsKHR.self)
        var wanted = XrGraphicsRequirementsMetalKHR()
        wanted.type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR
        let result = requirements(instance.handle, instance.system, &wanted)
        guard result.rawValue >= 0 else { throw XRFailure.call("xrGetMetalGraphicsRequirementsKHR", result) }
        // Use the specific MTLDevice reported by the OpenXR runtime's compositor.
        guard let named = wanted.metalDevice, let device = Unmanaged<AnyObject>.fromOpaque(named).takeUnretainedValue() as? MTLDevice,
              let queue = device.makeCommandQueue()
        else { throw XRFailure.unsupported("a Metal device") }
        self.device = device
        self.queue = queue
    }

    public func withSessionBinding<Result>(_ body: (UnsafeRawPointer) throws -> Result) throws -> Result {
        guard let queue else { throw XRFailure.unsupported("a Metal device") }
        var binding = XrGraphicsBindingMetalKHR()
        binding.type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR
        binding.commandQueue = Unmanaged.passUnretained(queue as AnyObject).toOpaque()
        return try withUnsafePointer(to: &binding) { try body(UnsafeRawPointer($0)) }
    }

    /// Preferred swapchain formats. sRGB formats are listed first so `QuadRenderer` outputs linear light for
    /// hardware sRGB encoding (matching visionOS); non-sRGB 8-bit formats receive gamma-encoded values directly.
    private static let formats: [MTLPixelFormat] = [.bgra8Unorm_srgb, .rgba8Unorm_srgb, .rgba16Float, .bgra8Unorm, .rgba8Unorm]

    public func chooseFormat(among offered: [Int64]) -> Int64? {
        MetalXRGraphics.formats.map { Int64($0.rawValue) }.first { offered.contains($0) }
    }

    public func adopt(_ swapchains: [XRSwapchain], instance: XRInstance) throws {
        guard let device, let first = swapchains.first, let format = MTLPixelFormat(rawValue: UInt(first.format))
        else { throw XRFailure.unsupported("a Metal device") }
        let enumerate = try instance.function("xrEnumerateSwapchainImages", as: PFN_xrEnumerateSwapchainImages.self)
        textures = try swapchains.map { swapchain in
            var count: UInt32 = 0
            var result = enumerate(swapchain.handle, 0, &count, nil)
            guard result.rawValue >= 0 else { throw XRFailure.call("xrEnumerateSwapchainImages", result) }
            var blank = XrSwapchainImageMetalKHR()
            blank.type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR
            var images = [XrSwapchainImageMetalKHR](repeating: blank, count: Int(count))
            // xrEnumerateSwapchainImages populates the array of XrSwapchainImageMetalKHR via its base header pointer.
            result = images.withUnsafeMutableBytes { all in
                enumerate(swapchain.handle, count, &count, all.baseAddress?.assumingMemoryBound(to: XrSwapchainImageBaseHeader.self))
            }
            guard result.rawValue >= 0 else { throw XRFailure.call("xrEnumerateSwapchainImages", result) }
            return try images.map { image in
                guard let pointer = image.texture, let texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLTexture
                else { throw XRFailure.unsupported("Metal swapchain images") }
                return texture
            }
        }
        let linear = format != .bgra8Unorm && format != .rgba8Unorm
        guard let renderer = QuadRenderer(device: device, colorFormat: format, linearOutput: linear)
        else { throw XRFailure.unsupported("Metal quad shaders") }
        renderer.chromaKey = chromaKey
        self.renderer = renderer
    }

    public func draw(_ eyes: [XREyeDraw], frame: DecodedFrame?, transparent: Bool) {
        guard let queue, let renderer, let commands = queue.makeCommandBuffer() else { return }
        for eye in eyes {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = textures[eye.eye][eye.image]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: transparent ? 0 : 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            renderer.draw(eyes: [(eye.quads, eye.view)], of: frame, near: 0.05, far: 100, with: encoder, commands: commands)
            encoder.endEncoding()
        }
        if let picturesFolder, frame != nil, let first = eyes.first, Date().timeIntervalSince(lastPicture) >= 2 {
            lastPicture = Date()
            picturesSaved += 1
            save(textures[first.eye][first.image], to: picturesFolder.appendingPathComponent("eye-\(picturesSaved).png"), with: commands)
        }
        // Commit before releasing swapchain images; the runtime synchronizes on the bound MTLCommandQueue.
        commands.commit()
    }

    /// Blits `texture` into a shared CPU buffer and writes it to `file` as a PNG once `commands` completes.
    private func save(_ texture: MTLTexture, to file: URL, with commands: MTLCommandBuffer) {
        let (width, height) = (texture.width, texture.height)
        guard let device, let copy = commands.makeBlitCommandEncoder(),
              let readable = device.makeBuffer(length: width * height * 4, options: .storageModeShared)
        else { return }
        copy.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readable, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        copy.endEncoding()
        let blueFirst = texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb
        commands.addCompletedHandler { _ in
            let order = blueFirst ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                                  : CGImageAlphaInfo.noneSkipLast.rawValue
            let pixels = Data(bytes: readable.contents(), count: width * height * 4)
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: order),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let output = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(output, image, nil)
            CGImageDestinationFinalize(output)
        }
    }
}
#endif
