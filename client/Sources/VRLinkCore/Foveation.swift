// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// How a picture is drawn sharper where the eye looks straight ahead than
/// at its edges: the picture is cut into zones across and down, and each
/// zone is drawn at a rate between 0 (hardly any pixels) and 1 (all of
/// them). A graphics backend turns the rates into a rasterization rate map
/// (Metal) or its like.
///
/// The zones and the block at full rate around straight ahead are the ALVR
/// visionOS client's, for its RealityKit renderer. Two things are not:
///
/// - Full rate is finer: ALVR's is 72 pixels to a zone (4248 across an
///   eye), which keeps about 70% of what the host's foveal tile carries
///   (2048 pixels over a window about 0.93 wide in tangents, against an
///   eye's 2.75). At 102 it keeps all of it.
/// - To pay for that, the rate falls away from the block as a square, not
///   in a straight line: half way out it is a quarter, not a half. Out
///   there only the host's base tile is left, which carries a third of
///   the foveal tile's detail, so little is lost.
public enum Foveation {
    /// Zones across and down one eye's picture, and the pixels in each at
    /// full rate: 6018 by 5814 pixels at full rate.
    public static let zonesAcross = 59, zonesDown = 57, zoneSize = 102
    /// How many zones each way are at full rate.
    public static let sharpZones = 11
    /// The lowest rate there is: a zone cannot be left out altogether.
    public static let lowest: Float = 1.0 / 256
    /// Zones left at the lowest rate along the outer edge of each eye's
    /// picture, which the eye cannot see.
    public static let outerZonesUnseen = 2

    /// The rates along one axis of `zones` zones. `center` is where
    /// straight ahead falls along it, 0 at the first zone's edge to 1 at
    /// the last's. `unseenAtStart` and `unseenAtEnd` zones at either end
    /// stay at the lowest rate.
    public static func rates(zones: Int, center: Float, unseenAtStart: Int = 0, unseenAtEnd: Int = 0) -> [Float] {
        let sharp = min(sharpZones, zones)
        let firstSharp = max(unseenAtStart, min(zones - unseenAtEnd - sharp, Int((center * Float(zones) - Float(sharp) / 2).rounded())))
        let afterSharp = firstSharp + sharp
        var rates = [Float](repeating: lowest, count: zones)
        // Rising from the start to the sharp block.
        for zone in unseenAtStart..<firstSharp {
            rates[zone] = Float(zone - unseenAtStart) / Float(firstSharp - unseenAtStart)
        }
        for zone in firstSharp..<afterSharp { rates[zone] = 1 }
        // Falling from the sharp block to the end.
        for zone in afterSharp..<max(afterSharp, zones - unseenAtEnd) {
            rates[zone] = Float(zones - unseenAtEnd - zone) / Float(zones - unseenAtEnd - afterSharp)
        }
        return rates.map { max(lowest, $0 * $0) }
    }

    /// The rates across and down for one eye's picture through `frustum`:
    /// the sharp block sits where the eye's own axis meets the picture.
    /// Down runs from the top of the picture.
    public static func rates(for eye: Eye, frustum: Frustum) -> (across: [Float], down: [Float]) {
        let across = rates(zones: zonesAcross, center: -frustum.left / (frustum.right - frustum.left),
                           unseenAtStart: eye == .left ? outerZonesUnseen : 0,
                           unseenAtEnd: eye == .right ? outerZonesUnseen : 0)
        let down = rates(zones: zonesDown, center: frustum.up / (frustum.up - frustum.down))
        return (across, down)
    }
}
