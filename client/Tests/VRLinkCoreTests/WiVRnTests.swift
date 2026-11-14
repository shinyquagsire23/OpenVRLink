// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class WiVRnTests: XCTestCase {
    /// A video shard as a host would send it: the first of a frame carries the views.
    private func shard(stream: UInt8 = 0, frame: UInt64, index: UInt16, first: Bool, last: Bool, payload: Bytes) -> Bytes {
        var out: Bytes = [WiVRn.ToHeadsetKind.videoShard.rawValue, stream]
        out.append(integer: frame)
        out.append(integer: index)
        out.append(first ? 1 : 0)
        if first {
            out.append(integer: Int64(123_456))
            for x in [Float(0), 1] { out.append(pose: Pose(position: Vec3(x, 1.5, 0), quaternion: [1, 0, 0, 0])) }
            for _ in 0..<2 { out.append(frustum: Frustum(left: -1, right: 1, down: -1, up: 1)) }
            for _ in 0..<2 {
                for counts: [UInt16] in [[10, 60, 10], [80]] {
                    out.append(size: counts.count)
                    for count in counts { out.append(integer: count) }
                }
            }
            out.append(0)
        }
        out.append(last ? 1 : 0)
        if last { for time in [Int64(1), 2, 3, 4] { out.append(integer: time) } }
        out.append(size: payload.count)
        out.append(contentsOf: payload)
        return out
    }

    func testAShardIsReadBack() throws {
        let packet = shard(stream: 1, frame: 7, index: 0, first: true, last: true, payload: [9, 8, 7])
        guard case .videoShard(let read)? = WiVRnToHeadset(packet) else { return XCTFail("not read as a shard") }
        XCTAssertEqual(read.stream, 1)
        XCTAssertEqual(read.frame, 7)
        XCTAssertEqual(Bytes(read.payload), [9, 8, 7])
        XCTAssertEqual(read.timing, [1, 2, 3, 4])
        let views = try XCTUnwrap(read.views)
        XCTAssertEqual(views.displayTime, 123_456)
        XCTAssertEqual(views.views[1].pose.position.x, 1)
        XCTAssertEqual(views.views[0].pose.forward.z, -1, accuracy: 1e-6)
        XCTAssertEqual(views.views[0].frustum.left, -1, accuracy: 1e-5)
        XCTAssertEqual(views.views[0].frustum.up, 1, accuracy: 1e-5)
        XCTAssertEqual(views.foveation[0].across, [10, 60, 10])
    }

    func testAPacketCutShortIsRefused() {
        let packet = shard(frame: 7, index: 0, first: true, last: true, payload: [9, 8, 7])
        XCTAssertNil(WiVRnToHeadset(Bytes(packet.dropLast(2))))
    }

    /// Sizes worked out from the fields of WiVRn 26.9's packets, laid end to end.
    func testPacketsAreAsLongAsTheirFields() {
        let view = WiVRnView(pose: Pose(position: Vec3(0, 0, 0), quaternion: [1, 0, 0, 0]), frustum: .symmetric(halfAngleDegrees: 45))
        let tracking = WiVRnPacket.tracking(produced: 1, time: 2, head: TrackedPose(pose: view.pose), views: [view, view])
        // kind, 3 profiles, 2 times, view flags, state flags, 2 views of 44, a count, one pose of 54, no face
        XCTAssertEqual(tracking.count, 1 + 3 + 16 + 8 + 1 + 88 + 2 + 54 + 1)
        // kind, frame, stream, ten times, a count
        XCTAssertEqual(WiVRnFeedback(frame: 1, stream: 0).packet.count, 1 + 8 + 1 + 80 + 1)
        let info = WiVRnHeadsetInfo(renderPixels: (2048, 2048), streamPixels: (1536, 1536), refreshRates: [90, 120],
                                    bitsPerSecond: 1, frusta: [view.frustum, view.frustum], codecs: [.h265], systemName: "abc")
        // kind, 4 sizes, 2 rates, settings (21), speaker (6), no microphone,
        // 2 frusta, 7 flags, trackers, 1 codec, no depth, name, language, country, variant
        XCTAssertEqual(info.packet.count, 1 + 8 + 10 + 21 + 6 + 1 + 32 + 7 + 4 + 6 + 1 + 5 + 4 + 4 + 2)
    }

    func testLongListsHaveATwoPartLength() {
        var out = Bytes()
        out.append(size: 0x7FFE)
        XCTAssertEqual(out, [0xFE, 0x7F])
        out = []
        out.append(size: 0x12345)
        XCTAssertEqual(out, [0x45, 0xA3, 0x02, 0x00])
        var reader = WireReader(out)
        XCTAssertEqual(reader.size(), 0x12345)
    }

    /// 10 pixels at 2:1, 60 at 1:1, 10 at 2:1: 100 source pixels in 80.
    func testBandsCoverThePictureAndItsSource() {
        let bands = WiVRnFoveation.bands([10, 60, 10], encodedSize: 80)
        XCTAssertEqual(bands.count, 3)
        XCTAssertEqual(bands[0].encoded.upperBound, 0.125, accuracy: 1e-6)
        XCTAssertEqual(bands[0].source.upperBound, 0.2, accuracy: 1e-6)
        XCTAssertEqual(bands[1].source.upperBound, 0.8, accuracy: 1e-6)
        XCTAssertEqual(bands[2].encoded.upperBound, 1, accuracy: 1e-6)
        XCTAssertEqual(WiVRnFoveation.sourceSize([10, 60, 10]), 100)
        // A picture not squeezed is one band.
        XCTAssertEqual(WiVRnFoveation.bands([], encodedSize: 80).count, 1)
    }

    func testTilesFillTheFrustumEdgeToEdge() {
        let view = WiVRnView(pose: Pose(position: Vec3(0, 0, 0), quaternion: [1, 0, 0, 0]),
                             frustum: Frustum(left: -1, right: 0.5, down: -0.8, up: 1))
        let squeeze = WiVRnFoveation(across: [10, 60, 10], down: [80])
        let layout = WiVRnSession.layout(views: [view, view], foveation: [squeeze, squeeze], encoded: (80, 80))
        XCTAssertEqual(layout.pictures, 2)
        XCTAssertEqual(layout.eyePixels.width, 100)
        let tiles = layout.views[1].tiles
        XCTAssertEqual(tiles.count, 3)
        XCTAssertTrue(tiles.allSatisfy { $0.picture == 1 })
        XCTAssertEqual(tiles[0].frustum.left, -1, accuracy: 1e-6)
        XCTAssertEqual(tiles[0].frustum.right, -0.7, accuracy: 1e-6)           // a fifth of the way across
        XCTAssertEqual(tiles[1].frustum.left, tiles[0].frustum.right, accuracy: 1e-6)
        XCTAssertEqual(tiles[2].frustum.right, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tiles[0].frustum.up, 1, accuracy: 1e-6)
        XCTAssertEqual(tiles[0].frustum.down, -0.8, accuracy: 1e-6)
    }

    private func parsed(_ packet: Bytes) -> WiVRnShard {
        guard case .videoShard(let shard)? = WiVRnToHeadset(packet) else { fatalError("not a shard") }
        return shard
    }

    func testShardsOutOfOrderMakeAFrame() {
        var assembler = ShardAssembler(stream: 0)
        XCTAssertNil(assembler.accept(parsed(shard(frame: 3, index: 2, first: false, last: true, payload: [5, 6])), now: 10).complete)
        XCTAssertNil(assembler.accept(parsed(shard(frame: 3, index: 0, first: true, last: false, payload: [1, 2])), now: 11).complete)
        let result = assembler.accept(parsed(shard(frame: 3, index: 1, first: false, last: false, payload: [3, 4])), now: 12)
        let whole = result.complete
        XCTAssertEqual(whole.map { Bytes($0.data.bytes) }, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(whole?.feedback.firstPacket, 10)
        XCTAssertEqual(whole?.feedback.lastPacket, 12)
        XCTAssertEqual(whole?.feedback.hostTiming, [1, 2, 3, 4])
        XCTAssertTrue(result.abandoned.isEmpty)
    }

    func testAFrameShortOfAShardIsGivenUpWhenTheNextIsWhole() {
        var assembler = ShardAssembler(stream: 1)
        _ = assembler.accept(parsed(shard(frame: 3, index: 0, first: true, last: false, payload: [1])), now: 1)
        let result = assembler.accept(parsed(shard(frame: 4, index: 0, first: true, last: true, payload: [2])), now: 2)
        XCTAssertEqual(result.complete?.frame, 4)
        XCTAssertEqual(result.abandoned.map(\.frame), [3])
        XCTAssertEqual(result.abandoned.first?.sentToDecoder, 0)
        // What comes late for the frame given up is ignored.
        XCTAssertNil(assembler.accept(parsed(shard(frame: 3, index: 1, first: false, last: true, payload: [9])), now: 3).complete)
    }

    func testPosesGoRoundThroughAQuaternion() {
        let pose = HeadPose(position: Vec3(1, 2, 3), yaw: 0.7, pitch: -0.3).pose
        let back = Pose(position: pose.position, quaternion: pose.quaternion)
        for (a, b) in [(pose.right, back.right), (pose.up, back.up), (pose.forward, back.forward)] {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-5)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-5)
            XCTAssertEqual(a.z, b.z, accuracy: 1e-5)
        }
    }

    /// Turning left at one radian a second for half a second faces half a radian left.
    func testAPoseIsCarriedForwardByItsVelocities() {
        var head = HeadPose(position: Vec3(0, 1.6, 0))
        head.yawRate = 1
        head.velocity = Vec3(2, 0, 0)
        let later = head.tracked.predicted(seconds: 0.5)
        let expected = HeadPose(position: Vec3(1, 1.6, 0), yaw: 0.5).pose
        XCTAssertEqual(later.pose.position.x, 1, accuracy: 1e-5)
        XCTAssertEqual(later.pose.forward.x, expected.forward.x, accuracy: 1e-5)
        XCTAssertEqual(later.pose.forward.z, expected.forward.z, accuracy: 1e-5)
    }
}
