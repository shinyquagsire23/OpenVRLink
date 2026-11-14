// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import CompositorServices
import Metal
import VRLinkCore
import VRLinkVisionTracking
import VRLinkMetal
import VRLinkVideoToolbox
import simd

/// Draw quads into one compositor drawable, both eyes in one pass.
///
/// `quads` is asked once per eye for what that eye should see, given where
/// the eye is; the eyes need not have the same number of quads. Returns
/// the two eye views used (world space), or none if nothing could be drawn.
@discardableResult
func drawQuads(into drawable: LayerRenderer.Drawable, commands: MTLCommandBuffer, renderer: QuadRenderer,
               frame: DecodedFrame?, originFromDevice: simd_float4x4, behind: MTLClearColor,
               quads: (Eye, EyeView) -> [Quad]) -> [EyeView] {
    let views = drawable.views
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.colorTextures[0]
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = behind
    pass.colorAttachments[0].storeAction = .store
    // Depth is kept: the compositor reprojects with it. Reversed, so 0 is far.
    pass.depthAttachment.texture = drawable.depthTextures[0]
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.clearDepth = 0
    pass.depthAttachment.storeAction = .store
    // Both eyes are layers of one texture, drawn in one pass.
    pass.renderTargetArrayLength = views.count
    pass.rasterizationRateMap = drawable.rasterizationRateMaps.first
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return [] }
    defer { encoder.endEncoding() }

    encoder.setViewports(views.map { $0.textureMap.viewport })
    if views.count > 1 {
        var mappings = views.indices.map {
            MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                              renderTargetArrayIndexOffset: UInt32(views[$0].textureMap.sliceIndex))
        }
        encoder.setVertexAmplificationCount(views.count, viewMappings: &mappings)
    }
    guard views.count == 2 else { return [] }

    // Each eye, in world space: the device's pose, then the eye's place on the device.
    let eyes = Eye.allCases.map { eye -> (quads: [Quad], view: EyeView) in
        let originFromEye = originFromDevice * views[eye.rawValue].transform
        let projection = drawable.computeProjection(viewIndex: eye.rawValue)
        let xScale = projection.columns.0.x, yScale = projection.columns.1.y
        let xShift = projection.columns.2.x, yShift = projection.columns.2.y
        let view = EyeView(eye: HeadTracking.pose(originFromEye),
                           frustum: Frustum(left: (-1 + xShift) / xScale, right: (1 + xShift) / xScale,
                                            down: (-1 + yShift) / yScale, up: (1 + yShift) / yScale))
        return (quads(eye, view), view)
    }
    renderer.draw(eyes: eyes, of: frame, near: drawable.depthRange.y, far: drawable.depthRange.x,
                  with: encoder, commands: commands)
    return eyes.map(\.view)
}
#endif
