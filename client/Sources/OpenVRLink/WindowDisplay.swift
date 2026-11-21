// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MetalKit
import VRLinkCore
import VRLinkMetal
import VRLinkVideoToolbox

/// Renders decoded frames into a macOS `MTKView`. On each display refresh, it
/// selects the next frame, computes a single-eye view from the simulated head
/// pose, and reports frame timing back to the session (standing in for an XR
/// compositor).
final class WindowDisplay: NSObject, MTKViewDelegate {
    /// Decoded frames queued for the next display refresh.
    let frames = DisplayQueue<DecodedFrame>()
    /// Receives frame presentation and vsync timing callbacks.
    var session: (any StreamingSession)?
    /// Which eye the window shows.
    var eye = Eye.left
    /// Display refresh interval in seconds.
    var refreshPeriod = 1.0 / 60

    private let queue: MTLCommandQueue
    private let renderer: QuadRenderer
    private let profile: DeviceProfile
    private let lock = NSLock()
    private var head = HeadPose(position: Vec3(0, 1.6, 0))

    private let settings: Settings

    /// Optional directory where rendered frames are saved as PNGs every 2 seconds for debugging.
    var picturesFolder: URL?
    private var lastPicture = Date.distantPast
    private var picturesSaved = 0

    /// Creates a window renderer using `settings` to configure chroma-key passthrough.
    init?(view: MTKView, profile: DeviceProfile, settings: Settings) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        // Allow reading back rendered textures when saving screenshots (`picturesFolder`).
        view.framebufferOnly = false
        guard let renderer = QuadRenderer(device: device, colorFormat: view.colorPixelFormat) else { return nil }
        self.settings = settings
        self.queue = queue
        self.renderer = renderer
        self.profile = profile
        super.init()
    }

    func setHead(_ pose: HeadPose) {
        lock.lock()
        head = pose
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let head = self.head
        lock.unlock()
        // No XR timing stuff so we just YOLO our wait times here
        let picked = frames.next()
        renderer.chromaKey = settings.chromaKeying(inGame: session?.sceneApplicationRunning ?? false)
        if let session {
            // Estimate presentation one refresh interval from now.
            let period = UInt64(refreshPeriod * 1e9)
            let seen = Uptime.nanoseconds + period
            session.displayRefreshes(at: seen + period, period: refreshPeriod)
            if let picked, picked.isNew { session.frameShown(picked.frame.frameID, at: seen) }
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        if let frame = picked?.frame {
            let size = view.drawableSize
            // Offset the eye from the head pose by IPD and build a symmetric
            // frustum matching the window's aspect ratio.
            let window = EyeView(eye: head.pose.shifted(right: profile.eyesInHead[eye.rawValue].position.x),
                                 frustum: .symmetric(halfAngleDegrees: 45, aspect: Float(size.width / max(1, size.height))))
            renderer.draw(Composition.quads(for: eye, layout: frame.layout),
                          of: frame, from: window, with: encoder, commands: commands)
        }
        encoder.endEncoding()
        if let picturesFolder, picked != nil, Date().timeIntervalSince(lastPicture) >= 2 {
            lastPicture = Date()
            picturesSaved += 1
            let file = picturesFolder.appendingPathComponent(String(format: "picture-%03d.png", picturesSaved))
            let texture = drawable.texture
            commands.addCompletedHandler { _ in WindowDisplay.save(texture, to: file) }
        }
        commands.present(drawable)
        commands.commit()
    }

    /// Saves a BGRA texture to disk as a PNG.
    private static func save(_ texture: MTLTexture, to file: URL) {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: file)
    }
}
