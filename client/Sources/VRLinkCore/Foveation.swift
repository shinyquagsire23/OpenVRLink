// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Computes fixed foveated rendering rates by dividing each eye's image into a
/// grid of zones, each assigned a rasterization rate from `lowest` to 1.0. The
/// graphics backend converts these rates into a Metal rasterization rate map or
/// equivalent.
///
/// The grid dimensions and the size of the full-rate center region match the
/// ALVR visionOS client's RealityKit renderer, with two differences:
///
/// - Higher peak resolution: ALVR uses 72 pixels per zone (4248 pixels across
///   an eye), preserving about 70% of the host's foveal tile (2048 pixels over
///   a ~0.93 tangent width versus the eye's 2.75). Using 102 pixels per zone
///   preserves the full foveal tile resolution.
/// - Quadratic falloff: To offset the higher peak pixel count, the rate falls
///   off quadratically rather than linearly (0.25 instead of 0.5 halfway to the
///   edge). In the periphery only the host's base tile remains, at roughly a
///   third of the foveal tile's detail, so little detail is lost.
public enum Foveation {
    /// Grid dimensions per eye and the full-rate pixel size of each zone (6018x5814 pixels total at full rate).
    public static let zonesAcross = 59, zonesDown = 57, zoneSize = 102
    /// Number of full-rate zones along each axis.
    public static let sharpZones = 11
    /// Minimum rasterization rate, since a zone cannot have a rate of zero.
    public static let lowest: Float = 1.0 / 256
    /// Number of zones clamped to the minimum rate along the outer edge of each eye's image, outside the visible area.
    public static let outerZonesUnseen = 2

    /// Computes per-zone rasterization rates along one axis of `zones` zones.
    /// `center` is the normalized position of the optical axis from 0 (start of
    /// the first zone) to 1 (end of the last zone). `unseenAtStart` and
    /// `unseenAtEnd` clamp that many edge zones to `lowest`.
    public static func rates(zones: Int, center: Float, unseenAtStart: Int = 0, unseenAtEnd: Int = 0) -> [Float] {
        let sharp = min(sharpZones, zones)
        let firstSharp = max(unseenAtStart, min(zones - unseenAtEnd - sharp, Int((center * Float(zones) - Float(sharp) / 2).rounded())))
        let afterSharp = firstSharp + sharp
        var rates = [Float](repeating: lowest, count: zones)
        // Ramp up linearly from the start edge to the full-rate region.
        for zone in unseenAtStart..<firstSharp {
            rates[zone] = Float(zone - unseenAtStart) / Float(firstSharp - unseenAtStart)
        }
        for zone in firstSharp..<afterSharp { rates[zone] = 1 }
        // Ramp down linearly from the full-rate region to the end edge.
        for zone in afterSharp..<max(afterSharp, zones - unseenAtEnd) {
            rates[zone] = Float(zones - unseenAtEnd - zone) / Float(zones - unseenAtEnd - afterSharp)
        }
        return rates.map { max(lowest, $0 * $0) }
    }

    /// Computes horizontal and vertical rasterization rates for `eye` given `frustum`.
    /// The full-rate region is centered where the eye's forward axis intersects
    /// the image, and `down` is ordered top-to-bottom.
    public static func rates(for eye: Eye, frustum: Frustum) -> (across: [Float], down: [Float]) {
        let across = rates(zones: zonesAcross, center: -frustum.left / (frustum.right - frustum.left),
                           unseenAtStart: eye == .left ? outerZonesUnseen : 0,
                           unseenAtEnd: eye == .right ? outerZonesUnseen : 0)
        let down = rates(zones: zonesDown, center: frustum.up / (frustum.up - frustum.down))
        return (across, down)
    }
}
