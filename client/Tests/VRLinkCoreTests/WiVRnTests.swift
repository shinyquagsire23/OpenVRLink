// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

final class WiVRnTests: XCTestCase {
    /// Serializes a WiVRn video shard packet, including view poses and foveation tables on the first shard of a frame.
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

    /// Verifies serialized packet lengths against the exact field sizes of the WiVRn 26.9 wire format.
    func testPacketsAreAsLongAsTheirFields() {
        let view = WiVRnView(pose: Pose(position: Vec3(0, 0, 0), quaternion: [1, 0, 0, 0]), frustum: .symmetric(halfAngleDegrees: 45))
        let tracking = WiVRnPacket.tracking(produced: 1, time: 2, views: [view, view], holding: [0, 0],
                                            poses: [WiVRnDevicePose(WiVRn.Device.head, TrackedPose(pose: view.pose))])
        // type, 3 interaction profiles, 2 timestamps, view flags, state flags, 2 views (44B each), pose count, 1 pose (54B), face-present flag
        XCTAssertEqual(tracking.count, 1 + 3 + 16 + 8 + 1 + 88 + 2 + 54 + 1)
        // type, frame ID, stream index, 10 timestamps, times-displayed count
        XCTAssertEqual(WiVRnFeedback(frame: 1, stream: 0).packet.count, 1 + 8 + 1 + 80 + 1)
        let info = WiVRnHeadsetInfo(renderPixels: (2048, 2048), streamPixels: (1536, 1536), refreshRates: [90, 120], preferredRate: 90,
                                    bitsPerSecond: 1, frusta: [view.frustum, view.frustum], codecs: [.h265], systemName: "abc")
        // type, 4 dimensions, 2 refresh rates, foveation/bitrate settings (21B), speaker config (6B), microphone flag,
        // 2 frusta, 7 feature flags, tracker count, 1 codec, depth flag, system name, language, country, subvariant
        XCTAssertEqual(info.packet.count, 1 + 8 + 10 + 21 + 6 + 1 + 32 + 7 + 4 + 6 + 1 + 5 + 4 + 4 + 2)
        // Enabling the microphone adds channel count and sample rate fields.
        var withMicrophone = info
        withMicrophone.microphone = true
        XCTAssertEqual(withMicrophone.packet.count, info.packet.count + 5)
        // Face tracking adds a timestamp, 70 blendshape weights, two confidence values, and two flags.
        let face = FaceExpressions(weights: [Float](repeating: 0.5, count: 70))
        let withFace = WiVRnPacket.tracking(produced: 1, time: 2, views: [view, view], holding: [0, 0],
                                            poses: [WiVRnDevicePose(WiVRn.Device.head, TrackedPose(pose: view.pose))], face: face)
        XCTAssertEqual(withFace.count, tracking.count + 8 + 280 + 8 + 2)
        // type, timestamp, payload length, PCM bytes
        XCTAssertEqual(WiVRnPacket.audio(time: 1, samples: [1, 2, 3, 4]).count, 1 + 8 + 2 + 4)
    }

    func testHandAndInputPacketsAreAsLongAsTheirFields() {
        let joints = TrackedHand.flat(wrist: HeadPose(position: Vec3(0, 1, 0)).pose, side: .left).joints
        // type, 2 timestamps, hand ID, present flag, 26 joints (43B each)
        XCTAssertEqual(WiVRnPacket.handTracking(produced: 1, time: 2, side: .left, joints: joints).count, 1 + 16 + 1 + 1 + 26 * 43)
        XCTAssertEqual(WiVRnPacket.handTracking(produced: 1, time: 2, side: .right, joints: nil).count, 1 + 16 + 1 + 1)
        // type, input count, 2 inputs (13B each)
        XCTAssertEqual(WiVRnPacket.inputs([(17, 1, 5), (26, 0.5, 6)]).count, 1 + 2 + 26)
        XCTAssertEqual(WiVRnPacket.battery(PowerState(level: 0.5, charging: true)).count, 1 + 4 + 2)
    }

    /// Verifies `packedRotation` round-trips through the unpacking formula from WiVRn's `packed_quaternion.h`.
    func testAPackedRotationUnpacksToItself() {
        func unpack(_ value: UInt32) -> [Float] {
            let scale = 1 / (511 * Float(2).squareRoot())
            let q = [20, 10, 0].map { Float(Int((value >> UInt32($0)) & 0x3FF) - 512) * scale }
            let largest = (1 - q[0] * q[0] - q[1] * q[1] - q[2] * q[2]).squareRoot()
            var xyzw = q
            xyzw.insert(largest, at: Int(value >> 30))
            return [xyzw[3], xyzw[0], xyzw[1], xyzw[2]]                 // reorder to [w, x, y, z]
        }
        for (yaw, pitch) in [(Float(0), Float(0)), (0.7, -0.3), (2.9, 0.4), (-1.6, 1.2), (3.1, -1.4)] {
            let q = HeadPose(position: Vec3(0, 0, 0), yaw: yaw, pitch: pitch).pose.quaternion
            let back = unpack(WiVRnPacket.packedRotation(q))
            // q and -q represent the same rotation.
            let sign: Float = zip(q, back).reduce(0) { $0 + $1.0 * $1.1 } < 0 ? -1 : 1
            for (a, b) in zip(q, back) { XCTAssertEqual(a, b * sign, accuracy: 0.003) }
        }
    }

    func testAControllerIsATouchControllerOnTheRightInputs() {
        var state = ControllerState(grip: TrackedPose(pose: HeadPose(position: Vec3(0, 1, 0)).pose))
        state.trigger = 0.5
        state.lowerButton = true
        state.menuButton = true
        let left = Dictionary(uniqueKeysWithValues: state.wivrnInputs(.left).map { ($0.id, $0.value) })
        XCTAssertEqual(left[17], 1)             // X click
        XCTAssertEqual(left[21], 1)             // menu click
        XCTAssertEqual(left[26], 0.5)           // left trigger value
        XCTAssertEqual(left[32], 0)             // left thumbstick x
        let right = Dictionary(uniqueKeysWithValues: state.wivrnInputs(.right).map { ($0.id, $0.value) })
        XCTAssertEqual(right[53], 1)            // A click
        XCTAssertEqual(right[62], 0.5)          // right trigger value
        XCTAssertNil(right[21])
        XCTAssertEqual(right[72], 0)            // right thumb rest touch
    }

    /// WiVRn rejects a returning headset if its reported frusta change slightly, so small measurement drift reuses the previously saved frusta.
    func testAHostIsToldTheSameFrustaAgain() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wivrn-displays-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = [Frustum(left: -1, right: 0.8, down: -0.9, up: 1), Frustum(left: -0.8, right: 1, down: -0.9, up: 1)]
        XCTAssertEqual(WiVRnDisplayMemory.settled(first, host: "a", file: file)[0].left, -1)
        var again = first
        again[0].left = -1.01
        again[1].up = 1.02
        let settled = WiVRnDisplayMemory.settled(again, host: "a", file: file)
        XCTAssertEqual(settled[0].left, -1)
        XCTAssertEqual(settled[1].up, 1)
        // A new host gets the current frusta directly, and a large frustum change updates the saved values.
        XCTAssertEqual(WiVRnDisplayMemory.settled(again, host: "b", file: file)[0].left, -1.01)
        again[0].left = -1.3
        XCTAssertEqual(WiVRnDisplayMemory.settled(again, host: "a", file: file)[0].left, -1.3)
    }

    func testMicrophoneAudioIsCutToFitADatagramAndNotKeptForever() {
        let microphone = WiVRnSession.microphoneQueue()
        microphone.capture(Bytes(repeating: 1, count: 3000))
        XCTAssertEqual(microphone.take().map(\.count), [1200, 1200, 600])
        XCTAssertTrue(microphone.take().isEmpty)
        // Exceeding the half-second limit drops an entire 1200-byte chunk so 16-bit samples stay aligned.
        microphone.capture(Bytes(repeating: 1, count: 48_000 + 500))
        let kept = microphone.take()
        XCTAssertEqual(kept.reduce(0) { $0 + $1.count }, 48_000 + 500 - 1200)
        XCTAssertTrue(kept.allSatisfy { $0.count % 2 == 0 })
        // Audio packets consist of a 1-byte type, 8-byte timestamp, 2-byte byte length, and the raw PCM bytes.
        XCTAssertEqual(WiVRnPacket.audio(time: 1, samples: kept[0][...]).count, 1 + 8 + 2 + 1200)
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

    /// Tests a 3-band foveation profile (10 px at 2:1, 60 px at 1:1, 10 px at 2:1), mapping 100 source pixels into 80 encoded pixels.
    func testBandsCoverThePictureAndItsSource() {
        let bands = WiVRnFoveation.bands([10, 60, 10], encodedSize: 80)
        XCTAssertEqual(bands.count, 3)
        XCTAssertEqual(bands[0].encoded.upperBound, 0.125, accuracy: 1e-6)
        XCTAssertEqual(bands[0].source.upperBound, 0.2, accuracy: 1e-6)
        XCTAssertEqual(bands[1].source.upperBound, 0.8, accuracy: 1e-6)
        XCTAssertEqual(bands[2].encoded.upperBound, 1, accuracy: 1e-6)
        XCTAssertEqual(WiVRnFoveation.sourceSize([10, 60, 10]), 100)
        // Without foveation, the entire axis is a single 1:1 band.
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
        XCTAssertEqual(tiles[0].frustum.right, -0.7, accuracy: 1e-6)           // 20% across the [-1, 0.5] frustum
        XCTAssertEqual(tiles[1].frustum.left, tiles[0].frustum.right, accuracy: 1e-6)
        XCTAssertEqual(tiles[2].frustum.right, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tiles[0].frustum.up, 1, accuracy: 1e-6)
        XCTAssertEqual(tiles[0].frustum.down, -0.8, accuracy: 1e-6)
    }

    /// In alpha-packed streams, the third image stores left-eye alpha in its left half and right-eye alpha in its right half.
    func testTransparencyIsFoundInItsHalfOfTheThirdPicture() {
        let view = WiVRnView(pose: Pose(position: Vec3(0, 0, 0), quaternion: [1, 0, 0, 0]), frustum: .symmetric(halfAngleDegrees: 45))
        let squeeze = WiVRnFoveation(across: [10, 60, 10], down: [80])
        let opaque = WiVRnSession.layout(views: [view, view], foveation: [squeeze, squeeze], encoded: (80, 80))
        XCTAssertFalse(opaque.transparent)
        XCTAssertEqual(opaque.pictures, 2)
        let layout = WiVRnSession.layout(views: [view, view], foveation: [squeeze, squeeze], encoded: (80, 80), alpha: true)
        XCTAssertTrue(layout.transparent)
        XCTAssertEqual(layout.pictures, 3)
        let left = layout.views[0].tiles[1].alpha, right = layout.views[1].tiles[1].alpha
        XCTAssertEqual(left?.picture, 2)
        XCTAssertEqual(left?.left ?? -1, 0.0625, accuracy: 1e-6)          // (10 / 80) * 0.5 within the left half of the alpha image
        XCTAssertEqual(left?.right ?? -1, 0.4375, accuracy: 1e-6)
        XCTAssertEqual(right?.left ?? -1, 0.5625, accuracy: 1e-6)
        XCTAssertEqual(right?.bottom ?? -1, 1, accuracy: 1e-6)
        XCTAssertNotNil(Composition.quads(for: .right, layout: layout)[1].alpha)
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
        // Late shards for an already-abandoned frame are ignored.
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

    func testAPoseGivenRelativeToAnotherIsPutBackByPlacing() {
        let grip = HeadPose(position: Vec3(1, 2, 3), yaw: 0.7, pitch: -0.3).pose
        let aim = HeadPose(position: Vec3(1.1, 1.9, 2.8), yaw: 0.2, pitch: 0.4).pose
        let back = grip.placing(grip.relative(aim))
        for (a, b) in [(aim.position, back.position), (aim.forward, back.forward), (aim.up, back.up)] {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-5)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-5)
            XCTAssertEqual(a.z, b.z, accuracy: 1e-5)
        }
    }

    /// Turning left at 1 rad/s for 0.5 s rotates the forward vector 0.5 radians to the left.
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
