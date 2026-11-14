// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MetalKit
import VRLinkCore
import VRLinkMetal
import VRLinkVideoToolbox

/// The window's side of the display seam: at each refresh it picks the frame
/// to show, says where the (one) eye is, and tells the session what it did.
/// On a headset an XR runtime does this job for two eyes.
final class WindowDisplay: NSObject, MTKViewDelegate {
    /// Decoded frames waiting for a refresh.
    let frames = DisplayQueue<DecodedFrame>()
    /// Told when frames are shown and when the display will next refresh.
    var session: (any StreamingSession)?
    /// Which eye the window shows.
    var eye = Eye.left
    /// Seconds between this display's refreshes.
    var refreshPeriod = 1.0 / 60

    private let queue: MTLCommandQueue
    private let renderer: QuadRenderer
    private let profile: DeviceProfile
    private let lock = NSLock()
    private var head = HeadPose(position: Vec3(0, 1.6, 0))

    private let settings: Settings

    /// `settings`: for the chroma key, a color of the picture to leave out; the window's background shows there.
    init?(view: MTKView, profile: DeviceProfile, settings: Settings) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
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
            // Drawn now, seen a refresh later.
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
            // The window is the eye's view: the viewer's eye, at its place to
            // one side of the head, looking where the head looks through a
            // frustum shaped like the window.
            let window = EyeView(eye: head.pose.shifted(right: profile.eyesInHead[eye.rawValue].position.x),
                                 frustum: .symmetric(halfAngleDegrees: 45, aspect: Float(size.width / max(1, size.height))))
            renderer.draw(Composition.quads(for: eye, layout: frame.layout),
                          of: frame, from: window, with: encoder, commands: commands)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
