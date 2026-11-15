// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
import CompositorServices
import Metal
import VRLinkCore
import VRLinkVisionTracking
import simd

/// Estimates eye gaze from the compositor's dynamic foveation map, since
/// visionOS does not expose raw eye-tracking rays to immersive apps.
///
/// `CompositorServices` concentrates the highest pixel density in each frame's
/// rasterization rate map around the user's current gaze point. Locating the
/// peak-density region for each eye yields a 3D gaze target accurate enough to
/// steer foveated encoding on the host.
final class GazeFromFoveation {
    private let lock = NSLock()
    private var gaze: Vec3?

    /// Returns the estimated 3D gaze fixation point in head space (in meters:
    /// `+x` right, `+y` up, `-z` forward), or `nil` when foveation is inactive.
    func current() -> Vec3? {
        lock.lock()
        defer { lock.unlock() }
        return gaze
    }

    /// Finds the midpoint (in virtual screen coordinates) of the highest-density
    /// region of `map` along one axis, or `nil` if the rate profile is uniform.
    private static func densest(_ map: MTLRasterizationRateMap, layer: Int, alongX: Bool, at other: Double,
                                from start: Double, length: Double) -> Double? {
        let samples = 64
        var densities: [Double] = []
        for index in 0..<samples {
            // Measure physical pixels per virtual screen unit around this sample point.
            let position = start + length * (Double(index) + 0.5) / Double(samples)
            func physical(_ p: Double) -> Double {
                let point = alongX ? MTLCoordinate2D(x: Float(p), y: Float(other)) : MTLCoordinate2D(x: Float(other), y: Float(p))
                let mapped = map.physicalCoordinates(screenCoordinates: point, layer: layer)
                return Double(alongX ? mapped.x : mapped.y)
            }
            densities.append(physical(position + 1) - physical(position - 1))
        }
        guard let highest = densities.max(), let lowest = densities.min(), highest > lowest * 1.05 else { return nil }
        let dense = densities.indices.filter { densities[$0] >= highest * 0.98 }
        let middle = (Double(dense.first!) + Double(dense.last!)) / 2 + 0.5
        return start + length * middle / Double(samples)
    }

    /// Updates the estimated gaze point by sampling `drawable`'s rasterization rate map.
    func update(from drawable: LayerRenderer.Drawable, frustum: (Int) -> Frustum) {
        guard drawable.views.count == 2, let map = drawable.rasterizationRateMaps.first else { return }
        // Per-eye gaze directions expressed as `(x/-z, y/-z)` tangents in head space.
        var looks: [(x: Float, y: Float)] = []
        for (index, view) in drawable.views.enumerated() {
            let layer = min(view.textureMap.sliceIndex, map.layerCount - 1)
            let port = view.textureMap.viewport
            guard let x = GazeFromFoveation.densest(map, layer: layer, alongX: true, at: port.originY + port.height / 2,
                                                    from: port.originX, length: port.width),
                  let y = GazeFromFoveation.densest(map, layer: layer, alongX: false, at: x,
                                                    from: port.originY, length: port.height)
            else {
                lock.lock()
                gaze = nil
                lock.unlock()
                return
            }
            // Convert virtual screen coordinates to tangents in the canted eye frame, then rotate into head space.
            let f = frustum(index)
            let tx = f.left + Float((x - port.originX) / port.width) * (f.right - f.left)
            let ty = f.up - Float((y - port.originY) / port.height) * (f.up - f.down)
            let eye = HeadTracking.pose(view.transform)
            let direction = eye.right * tx + eye.up * ty + eye.forward
            looks.append((direction.x / -direction.z, direction.y / -direction.z))
        }
        // Estimate fixation depth from stereo vergence: as the eyes rotate inward
        // on a nearby object, horizontal tangent difference equals IPD / distance.
        let apart = simd_length(drawable.views[0].transform.columns.3 - drawable.views[1].transform.columns.3)
        let convergence = looks[0].x - looks[1].x
        let distance = min(10, max(0.25, convergence > 0 ? apart / convergence : 10))
        let point = Vec3((looks[0].x + looks[1].x) / 2, (looks[0].y + looks[1].y) / 2, -1) * distance
        lock.lock()
        gaze = point
        lock.unlock()
    }
}
#endif
