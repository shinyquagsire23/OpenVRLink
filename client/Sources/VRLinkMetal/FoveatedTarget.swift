// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import VRLinkCore

/// A texture both eyes are drawn into foveated (core `Foveation`): sharp
/// around straight ahead and coarser towards the edges.
///
/// Metal draws through a rasterization rate map: the caller draws as if
/// into a large "screen" (6018 by 5814 for an eye), and the pixels really
/// stored are fewer, squeezed together where the rates are low. `stored`
/// says where a place on an eye's screen ended up in the texture, for
/// whoever shows it.
///
/// The right eye's picture is above the left's. The two need different
/// rates across (each is sharp towards the nose) and a rate map has one
/// set of rates across for its whole texture, so each eye has a map of its
/// own: that eye's rates across, and the same rates down in both halves so
/// that the two maps agree on where each half is. Each eye is drawn in a
/// render pass of its own, with its map.
public struct FoveatedTarget {
    /// One per eye (left, right). Each covers the whole texture.
    public let maps: [MTLRasterizationRateMap]
    /// One eye's picture as drawn, before squeezing, in pixels.
    public let screen = (width: Foveation.zonesAcross * Foveation.zoneSize, height: Foveation.zonesDown * Foveation.zoneSize)
    /// The texture both eyes are squeezed into, in pixels.
    public let texture: (width: Int, height: Int)

    public init?(device: MTLDevice, frusta: [Frustum]) {
        guard frusta.count == 2, device.supportsRasterizationRateMap(layerCount: 1) else { return nil }
        var maps: [MTLRasterizationRateMap] = []
        for eye in Eye.allCases {
            let rates = Foveation.rates(for: eye, frustum: frusta[eye.rawValue])
            let down = rates.down + rates.down                    // the right eye's half, then the left's
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

    /// Where on the screen an eye's picture is drawn: the left eye in the lower half.
    public func viewport(_ eye: Eye) -> MTLViewport {
        MTLViewport(originX: 0, originY: eye == .left ? Double(screen.height) : 0,
                    width: Double(screen.width), height: Double(screen.height), znear: 0, zfar: 1)
    }

    /// Where a place in an eye's picture (`x` from its left, `y` from its
    /// top, both 0 ... 1) is stored: as fractions of the texture, from its
    /// left and from its top.
    public func stored(_ eye: Eye, x: Float, y: Float) -> (fromLeft: Float, fromTop: Float) {
        let top = eye == .left ? Float(screen.height) : 0
        let place = maps[eye.rawValue].physicalCoordinates(
            screenCoordinates: MTLCoordinate2D(x: x * Float(screen.width), y: top + y * Float(screen.height)), layer: 0)
        return (place.x / Float(texture.width), place.y / Float(texture.height))
    }
}
