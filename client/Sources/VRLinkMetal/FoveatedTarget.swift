// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import VRLinkCore

/// Layout and rasterization rate maps for a shared foveated render target
/// (using `Foveation` from `VRLinkCore`), keeping resolution high near the
/// forward view direction and coarser toward the edges.
///
/// Metal renders through a rasterization rate map: the caller draws into a
/// large virtual screen (6018x5814 per eye), while the physical texture stores
/// fewer pixels by compressing low-rate regions. `stored` maps normalized
/// virtual-screen coordinates for an eye to normalized coordinates in the
/// physical texture.
///
/// The right eye is stacked above the left eye in the texture. Because each eye
/// needs its own horizontal rate profile (sharper toward the nose) and a rate
/// map applies a single horizontal profile across the whole texture, each eye
/// gets its own rate map and render pass. Both maps repeat the same vertical
/// rates for the top and bottom halves so they agree on where each half lands.
public struct FoveatedTarget {
    /// One rate map per eye (left, then right), each covering the full two-eye texture.
    public let maps: [MTLRasterizationRateMap]
    /// Virtual screen dimensions for a single eye before variable-rate compression, in pixels.
    public let screen = (width: Foveation.zonesAcross * Foveation.zoneSize, height: Foveation.zonesDown * Foveation.zoneSize)
    /// Physical texture dimensions holding both eyes, in pixels.
    public let texture: (width: Int, height: Int)

    public init?(device: MTLDevice, frusta: [Frustum]) {
        guard frusta.count == 2, device.supportsRasterizationRateMap(layerCount: 1) else { return nil }
        var maps: [MTLRasterizationRateMap] = []
        for eye in Eye.allCases {
            let rates = Foveation.rates(for: eye, frustum: frusta[eye.rawValue])
            let down = rates.down + rates.down                    // top half (right eye), then bottom half (left eye)
            let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSizeMake(rates.across.count, down.count, 1))
            for (zone, rate) in rates.across.enumerated() { layer.horizontal[zone] = rate }
            for (zone, rate) in down.enumerated() { layer.vertical[zone] = rate }
            let descriptor = MTLRasterizationRateMapDescriptor()
            descriptor.label = "foveated, \(eye) eye"
            descriptor.screenSize = MTLSizeMake(screen.width, screen.height * 2, 1)
            descriptor.setLayer(layer, at: 0)
            guard let map = device.makeRasterizationRateMap(descriptor: descriptor) else { return nil }
            maps.append(map)
        }
        self.maps = maps
        let sizes = maps.map { $0.physicalSize(layer: 0) }
        texture = (sizes.map(\.width).max() ?? 0, sizes.map(\.height).max() ?? 0)
        guard texture.width > 0, texture.height > 0 else { return nil }
    }

    /// Returns the virtual-screen viewport for `eye` (right eye in the top half, left eye in the bottom half).
    public func viewport(_ eye: Eye) -> MTLViewport {
        MTLViewport(originX: 0, originY: eye == .left ? Double(screen.height) : 0,
                    width: Double(screen.width), height: Double(screen.height), znear: 0, zfar: 1)
    }

    /// Maps normalized coordinates (`x` from left, `y` from top, in `0...1`)
    /// in an eye's virtual screen to normalized UV coordinates in the physical texture.
    public func stored(_ eye: Eye, x: Float, y: Float) -> (fromLeft: Float, fromTop: Float) {
        let top = eye == .left ? Float(screen.height) : 0
        let place = maps[eye.rawValue].physicalCoordinates(
            screenCoordinates: MTLCoordinate2D(x: x * Float(screen.width), y: top + y * Float(screen.height)), layer: 0)
        return (place.x / Float(texture.width), place.y / Float(texture.height))
    }
}
