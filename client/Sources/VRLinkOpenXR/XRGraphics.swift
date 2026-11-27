// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Metadata for a single eye's OpenXR color swapchain.
public struct XRSwapchain {
    public var handle: XrSwapchain
    /// Native pixel format enum value (such as `MTLPixelFormat` or `VkFormat`) selected by `XRGraphics.chooseFormat`.
    public var format: Int64
    public var width: Int, height: Int
    /// True if the swapchain was created with `XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT`, allowing image views with
    /// a different compatible format (such as UNORM views of an sRGB swapchain).
    public var mutableFormat = false
}

/// Layer composition options from `HeadsetQuirks` that can be updated per frame from the panel.
public struct XRLayerChoices: Equatable {
    public var blendTest = "none"
    public var topLayer = false
    public var skipEmptyProjection = false
    public var streamQuads = "never", quadDistance: Float = 50
    public var reuseFrames = true
    /// Keep rendering the sharp layer while the stream is transparent (during room view or chroma keying).
    public var sharpWhenTransparent = true

    public init() {}
}

/// Per-eye render target, view pose, and world-space quads for a single frame.
public struct XREyeDraw {
    /// Eye swapchain index matching the array passed to `XRGraphics.adopt`.
    public var eye: Int
    /// Acquired swapchain image index for this frame.
    public var image: Int
    /// Predicted eye pose and field of view in the same reference space as `quads`.
    public var view: EyeView
    public var quads: [Quad]
    /// Top-left sub-rect of the swapchain image to render into, or `nil` to use the full image.
    public var size: (width: Int, height: Int)?
    /// Clears the attachment to transparent black regardless of the frame-level `transparent` flag.
    public var clear = false

    public init(eye: Int, image: Int, view: EyeView, quads: [Quad], size: (width: Int, height: Int)? = nil, clear: Bool = false) {
        self.eye = eye
        self.image = image
        self.view = view
        self.quads = quads
        self.size = size
        self.clear = clear
    }
}

/// Graphics API backend for an `XRDisplay` OpenXR session (implemented with Metal on Apple platforms and
/// Vulkan on Android).
///
/// `XRDisplay` manages the OpenXR session, frame timing loop, and swapchain lifecycle, while `XRGraphics`
/// creates the GPU device required by the runtime, wraps swapchain images, and renders quads from decoded
/// `Frame` textures.
extension XRGraphics {
    public var supportsHostChromaKey: Bool { false }
    public var wantsMutableFormat: Bool { false }
    public var lastDrawSteps: [(name: String, nanoseconds: UInt64)] { [] }
}

public protocol XRGraphics: AnyObject {
    /// Decoded video frame type sampled by this renderer.
    associatedtype Frame: StreamFrame

    /// OpenXR instance extensions required for this graphics API binding.
    static var extensions: [String] { get }

    /// Queries the runtime's graphics requirements and initializes the GPU device before session creation.
    func prepare(instance: XRInstance) throws

    /// Invokes `body` with a pointer to the API-specific `XrGraphicsBinding*` struct for `xrCreateSession`.
    func withSessionBinding<Result>(_ body: (UnsafeRawPointer) throws -> Result) throws -> Result

    /// Requests `XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT` when creating eye swapchains. Check
    /// `XRSwapchain.mutableFormat` in `adopt` to see whether the runtime accepted the flag.
    var wantsMutableFormat: Bool { get }

    /// Selects a supported swapchain pixel format from the runtime's ordered format list.
    func chooseFormat(among offered: [Int64]) -> Int64?

    /// Enumerates and wraps the native GPU images for each eye's swapchain.
    func adopt(_ swapchains: [XRSwapchain], instance: XRInstance) throws

    /// Renders all eye views and submits GPU commands before returning so `XRDisplay` can immediately
    /// release the swapchain images. When `transparent` is `true`, clears alpha to 0 for passthrough.
    func draw(_ eyes: [XREyeDraw], frame: Frame?, transparent: Bool)

    /// Selects an 8-bit RGBA swapchain format for the panel layer (preferring sRGB when available), or `nil`
    /// if none of the offered formats are supported.
    func choosePanelFormat(among offered: [Int64]) -> Int64?

    /// Wraps the native textures or images of the panel swapchain.
    func adoptPanel(_ swapchain: XRSwapchain, instance: XRInstance) throws

    /// Uploads a panel RGBA buffer (`XRPanelLayer.update`) into swapchain image `image`, submitting GPU work
    /// before returning.
    func drawPanel(_ pixels: [UInt8], image: Int)

    /// Time spent waiting on the GPU fence during the most recent `draw` call, in nanoseconds.
    var lastGPUWait: UInt64 { get }
    /// Per-stage CPU timing breakdown from the most recent `draw` call for `FramePace` logging.
    var lastDrawSteps: [(name: String, nanoseconds: UInt64)] { get }

    /// Optional chroma-key filter applied during quad rendering.
    var chromaKey: ChromaKey? { get set }
    /// Whether the graphics device supports chroma-keyed rendering. Valid after `prepare` completes.
    var supportsChromaKey: Bool { get }
    /// Whether the renderer supports per-frame SteamVR host chroma keying (`FrameLayout.HostKey`).
    var supportsHostChromaKey: Bool { get }

    /// Whether decoded frames can be read back for stereo depth estimation.
    var supportsDepth: Bool { get }
    /// Optional GPU stereo-matching hook; when `nil`, `StereoDepthEstimator` falls back to `shrink` and matches
    /// on the CPU. Valid after `adopt` completes.
    var measure: StereoDepthEstimator<Frame>.Measure? { get }
    /// Downsamples both eyes of `frame` to `width`-pixel-wide grayscale images (`StereoPlan`) for CPU stereo
    /// matching, completing on any queue with `nil` if readback fails. Called off the render thread; GPU-backed
    /// implementations may defer the work to the next `draw` call.
    func shrink(_ frame: Frame, width: Int, done: @escaping (StereoPair?) -> Void)
}
