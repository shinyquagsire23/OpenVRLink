// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
import VRLinkCore
@testable import VRLinkVideoToolbox

/// One keyframe of a 128x128 test pattern in each codec, made with
/// `ffmpeg -f lavfi -i testsrc=size=128x128 -frames:v 1 -c:v {h264,hevc}_videotoolbox`.
final class DecoderTests: XCTestCase {
    private static func bytes(_ hex: String) -> Bytes {
        var out = Bytes(), index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private static let h264Keyframe = bytes(
        "000000012764000bac56283047821d0000000128ee3cb00000000106052d47564adc5c4c433f94efc5113cd143a80100000300010300000300010200" +
        "0287ff0b000003000003000025b20c03912b01800000000125b8201fde08e54cff82cc21020bf3b0c5c7719c50ef84c9f85a7a5081966fbe6f294416" +
        "2b48d0cd286eb62f264dbbead9241f5736c985a9b6a2831e8dd79012b2fcb6d67b23cafd6bcf1b93823379bc4bcebd33585856e7c4fe941e868b849e" +
        "d1dafd6787a9c202bfaf51d403526a99fbee62468bfef53374dc2192e4ed342344cf9a451d56743e387cff8ac0c1aa3438fbf084093d6f3e3741e860" +
        "a83a60f68ef230eaddc435565b37b5d82799b25a351768548e944c04d7dbdc70b12d9bf9ebaf9c13578e132bee17efdc02df8b6adc8d2dd591b24bdd" +
        "ef8416a2c7e60d4f69f71a4e1440cd8c84b2b1fbca279a0902e21e6f8394799cfad62cda71e621a9debf6b452a48e0aa28d2f7af0c87a639d4a56cbc" +
        "756a281b9417db1d567d74f58e7b97c0dab5b5671978fd53f360ef27c2535255427200ce33d12253e1116fdeaee7ea9611d10f27967c06d786578ebb" +
        "de86d49c36587f2aa40e0fa57ee3897aa968b9ffce5fa1935ee89d63496d2e9491d500c2174e9d63b4969ddd928492c79420c7f52ffe7a13a7348935" +
        "49f883199d8f1d1816fd514977dbb921e20027c21286963e32ff648fb8516747040aab709143cb96c551a22aaf30425d12074121e651d2c062ddd080" +
        "ca615220317629705affadbfc15f6a631a82543a7dfbfebebe7c6c3efa9c3c771a946d7cc9461314593e96a65905c8f2fe3a8843bbc369e4103ffa05" +
        "6d0de7ef1ac26d93a36dad9ec094408d0aafb578e7671caab1ab4aa0fdd6a894633c6a0414418e4a2f8c5c03bd959e0c29d90a87c3df691feeebf4fa" +
        "a1c18d2ef54820597a08eca4ee6e0ee6a7e831b93b1dc2f6071ad8cbb9512d80ee3183ad6870f42c77e8f5c10147ab2d97740f172d2d51f2e9e12318" +
        "fe64453c62b70c4f26f9e3737577c697121f1b8ea044aaa707d8d6d6245d478a2827986cc0622d7d60131941f4a80f5b1768755ba1aef68fb7cd5f57" +
        "19fa1c5333a8aeabdb6d6fce074aef719fc6a001cc3399c511d53650488c17ebda83cec9f80e5e20199cd609443acd2c5f00fc1a039136118201b4e4" +
        "5f2dce32e20d064277c1cac5ef437beae3e90548e669e1bb4879a2a9c8d8038a1af3113375d579eabe499ee1b704f9cad8564d1419f4954b5f2cc73a" +
        "de67f94c95081f7e178fff054f2aa7284bfa88b38beb6a5f466b533d742b42abc4a33878bdc959c759ee6e331dd462184ea2d2722369b0bc44c059f6" +
        "d394dde27a58e09ab8d9ebea32aa364a440c17b078187acd37365127ae99b423f23e6249b3383914d32288837c68596dc38f1634916bfbbd3ede7fad" +
        "c5a805434ea67034dc274ca82fe9c7b2d87bb616e321bb6c1d8f7b6980193e190f8a7ff0a5a5d85d5add85f6a9a1f9fcf3ee1ff898d7eda1eff39d0b" +
        "a9ff8a39253f45e56ca7b9f5052a5d1fa0979c96671b4809cdc5f95cfdf8cd27adcceca06cb47db57fb67738ae5d0d84c04f34cbe4369184c3c52929" +
        "65d54731f4ec0d70845af243e43a542e8c1af604251e461d56dfeb36f6d1a3adfc8fa15ed0f0bf3ade03736ba1307fda5242571bde0703379eebe46f" +
        "182847855ca108bf8439dc28f803d9c2d6f0c684319623edfca7039883cd40d122d0832d869e9b37cbf8d8e9538b6c2b39f210743875b63cd1e695c7" +
        "1446d082a71bcb84d595d331357bba367f4d817cfea1026734a4cc6d634789fe2dd839f2af21740f06fe8bc2033186df788a4ba0d7770ed016a32cca" +
        "e9f720b6c03452fa967f22c6fb043d71b312467bf7611be2451d107209bfd5a2f130402ac7e13de4df621e7005a0fedd59fd004d0cc90ca48772df71" +
        "7c14cc4bf5435cf3134a08ba57f5645901402d462d7b3b31b8a1d9e0551d7c839303852b18131c1cbd686321a10d0ec34fdaaf675245992d62f18656" +
        "fc211b8bfd2366fa539dcb6d2584cf5e15ed4dec2f180a9d5b5864aaa5040aa6f8a03ad552f6d15abe25956e194b2dda24c2e12059b6b4e56a682029" +
        "87f885c05278d5f8402be4804418ccbe32bfa885ac18b8027acda7c525bb99558da531284672ddfa0e318b0f3548f608d346f8496c4b70a359afad40" +
        "8614ee7a8ba520b4a3ccc92ae49ee386e5d324632afea3073bd64a96abf23d26e7062d94ca4ceae4591c23b509893a5f2d977771f9dcedd73d2787c0" +
        "59df14e3b3d2960bf145fbb2dc61022b748ac0c0801891e048710e3ef7a469ba70730effb3be94d0ffb027cd9fa1d006dd9e305d9e6b356f4f071e76" +
        "e9f9dd47f76a57524e18fcdea4dd64446ee0082ef67415216dd9c6bd43da4a4a9600f0e4e37cf30ad0ea5b9dd19d413159e0cba410ec0dc5fbec1607" +
        "b5613cb425d6a37dc0b8d5e9f888cbf273c4f8aa146413468ee52f61ca52e52d4b0cee2a5a3fb0dbb56246ce818931829fcd6a57c879cbc267654e5a" +
        "3a2da185f9b3a440828cd14a9e9b2894fe5cf4")

    private static let hevcKeyframe = bytes(
        "0000000140010c01ffff016000000300b0000003000003003c0bc09000000001420101016000000300b0000003000003003ca0142020708f880bee45" +
        "914bff2e7f13fac05a8101010040000000014401c072f05324000000014e01053247564adc5c4c433f94efc5113cd143a80100000300010300000300" +
        "010200010e000b000003000003000025c60c03912b010dffffffff80000000012801af3104f558cc98f492af7ffdd19b16816430ae2cc0f7fce0637e" +
        "6caaa415e15caffa003f883297caaf544bc91b0a25f997e310eda1f611400a679ea0b0c364acca30a243bb61e1d8bef1070904db249906a5f33d5fea" +
        "fa9969165dd6f864a451e6f5dd9e7488adde918815b12461ad6a9e88a4ad4b1bc0c95a277fbfe316e9bbef9440bffc0ee9c21daca2d6e2bdc3f41238" +
        "a0f454438374fe94c7a990e0935b2c07b397957d931465d9d1033087120574b191652734bfcb7a38df5310345c817ad09da978d03b490280266841a5" +
        "5e028754c9943e2f8d169406930885804dd87694d9e2792bad98520bffb6781ac78a4e63f84371330ec3f3b152cbe5ce212ee7dbe6f6aa308034c34b" +
        "67b1a4b1d3da39d87d9c06f0a30de6a08903b0d0c37799bbadc4639f04077871e0f15d80b806653a1fd8427727ff3ffc38b86c607193ba0ef42780a0" +
        "25d8302d01ff1938f7c13a3280b5d32db8267bf0d7bce3d38c6bbcd0d067ea7d6c4a0ee9cf6f3e82fa6a9371dea5abbf44b2c103f7df6ee88c22b5e2" +
        "01a0b239ec0f43fb5d662f2edf391a77233ff49f76da49aaaa869019b84d4ddbb29b6d7d11aea3f33f04c45382ba4eaccc2cd73336b9778395aba716" +
        "7a82be0e0f778c1a62031f63084b796557103fe453fffbeb5ffc2e152c9ea09eeb7d7a2dc7a6b088fa034bc721bb95c8239bc7df54288b9b7d226fdc" +
        "60d3953c8a408595172a1ca6fb2baa77c376e05e5700c4cc01a124c612a5c670e64108385691a5768733097b140f173f818fada61b3aeeea4eacdd26" +
        "952073c31d026a15e3eef5ace92052f8cb025dcb39784e654c64a034ca4c2afd8b1fdd07294120851ea168f7bb9b989b6525927efd2d472fdd0ff143" +
        "2847a6b4b5217bb1cf587e742a1a8d995de06e92df0a1f4e1612748a7abf625b408ba7d3065803e8418c25b68c9822f6bfd80cb9d3067d805d4adcd8" +
        "b779fc19ebdc4a3a095c34f1cf7be18d71dceae8243540c5c74fb198d633b98b040d563afaaeda0037d05b997d6d1ad0ab00706848d351a0b3caedff" +
        "7e899fa85c82f34d0496c00236a9d8d3163002902e3eb09165d9a46f44764051e67802262ad84c22e882815f431665c8f252118a17c59d99a603f3f3" +
        "35f048c9266ca666372b6b68b4b904da08692e7468f214af30b2554ed939e46a05486e75a25ecd885c1cde0393f66ee3f8f256ff7f0e435e8bca9341" +
        "2fba8dc089f6393a4c8db28005c4802f03134e8022cc70f161f23c082abb23e5cd5e90be3316dec39d345d6fa617fe6d078aef67d137b128c6cf2129" +
        "cd2d9a455cfc67e91a38d6897e7307f2d42e90c2e13caf03352286a2c046663ea9bc10df67a6b43a2a70fc763333360c6239c642b082f7495032e413" +
        "6ba4db88d77d4ab55565ddabb835f104c01b53c9458b042cdb6a90f052b0c50a46e7c84a0429f9f776c234fdb080e16b9ac207148af2f2716980a84a" +
        "f90990a0f2907df218de65e586f6f6cde812e90e2ba3f593ba092a0ab4921c0235e68b18bfae5907ceb72a086a85657d12b89e699ebebcf33d6901b6" +
        "8728f9342ce12c99139b7ce3689a70e0ef38a5878384ab749daa5aebb606784fce339ea74af647d653f64fce85d80ea28bec64745395f287e3374857" +
        "6e9a3ed6c863177347eb5fb9e8355983fb8d387b76369aa7d55f81460b65f9cf7c44f358730ba8974364887d45c15c43b863d89aabb827926fb6c57d" +
        "ab8ea4b031beb9d84b35c5d1729cc9a718c69e188b0f5fecc753ad2ea3fdb2ad90d2d378377886d30905e0b37e415fd2a1aeb62f1ed23f24ff3a72f6" +
        "4ff56e30e9df8cb276591d06b00b0b3b92e865785e91696693edd08f4669cd1cc36264b99a72b79f0e323a14b74a7dbb6e3fc87249b9f99c5a0dc229" +
        "2ed7672d918d8ae62e37f504f9db90527aa2e1cfc17e2041ce3800a3a8348c4b533c18d4f7d71063ea9b502a54cf46dd039c4e33805be05030852649" +
        "6a9a5a73c27a10135ebd4b09ed000ff4e0f1f12ceaf0c508a513d71ea096a4eda92cf55d2c62a6a3fb5259cc8fc7fc4024f8")

    /// `ffmpeg ... -c:v libsvtav1 -f obu`, the same test pattern.
    private static let av1Keyframe = bytes(
        "12000a0a0000000337ffe357cc0232ad07140023a02082041013ef0080d8005aab2513fdfc997ca18c8795205c6e3bcf9513b505e10efd01f9060f5e" +
        "669d784ffd88d3826efbcdbd02b9d8dab594f9e3ac75f9b43b509404d3dca59fff88941ea0714ceaff5d0b34b0f7113b73bc6d5fe73e40d161659427" +
        "b8fc8fa7ff3c9b39134d1a68d6a0e9b28b313072392d116933a20e6346705a29aa2925e5098ca3fc983b82d996eee15dfbe53e0cb1a9ac844ce21efa" +
        "40f5bf26b9ccee0cb100cf728dcda0a12f3d9065f4eb2b6582a9b16e8430f67d29817ad5f5ed71078036b7095ad5c52e8241f08120767ff566977735" +
        "cc2fef5751442bd28c15f210c683baf62776f4db0686ba24de93778e1d7bac5de7046a585701737155abff194a9f7ebb6465197e95ea77da3013c4c1" +
        "54f2d712da84787baff6d22dbec12088df472311c3e1f13287ad857ec6c63c6e6abe98494e9d401f0c3f7de0e428526d26e885b3a8f6f0cb092a1350" +
        "fe2e8dc87156b4b4ac28c25b752f4ad92e95b11b8c005b5636209cd8a507d6abf38eab50da031597bbf96f6e98662de18928dc4320592d0b68f34582" +
        "51dcfca332a68d0859ee59e8f711f5480e07319d5913614f4fae93aed6b211bb9dadb9f3cb71f09ddb9d9dd27ddd53da61412dc26e40fe34059642ed" +
        "59bb5eee44d4a9bd6b976df3fde6f4cbc2f5080183e217896dc81dac31df4352dc8dd7709b8872023fac5cbf04df799cccf0b3b7cfbad5803231866f" +
        "156dfc7dcbebdc42ca72f03cadfeff4ef8b27d1dd6214cefa8c0e6b3f88fc993449f3ea5dbf6c2e9f41d96c2eb311e4da3e5ab632ef011a011ecc88f" +
        "edce886b442934c2bbd5a613d01a4dc32a0391af6b9269a0ff5df4b9fcace07381973fca8c5583850b1f94a9bb795f86778f36b7c93dd49eb82de4e0" +
        "cfafabe0cb7173f8889a7a4d110936a44136e55e598bcacbd76abcb879c60a1b0590a587255a7db82aff49843bffb9341d44f0885808c189e14d249f" +
        "2815b0003a3230035f7a2677bbcda66b949fcc790589474d64df2c7869f8845b9ce0937891502dc59aede827bc46da2c6ebe63d3b06a6c510cd8132e" +
        "429ec8a58ba55330498738a292843986a387aae55b6a6b7eef2af50b27c53a9c2eeb1d22c25e73d8f07573914d0ea70ad1226b922ca4713e1ae1d725" +
        "0be2965dc17b08af81483c75b08c11998266d5f9a1a926dcb96b367876406d179fbfc7380f40f63dbb992112c88c0a26e7ab7f2713296e6b7e4ffcbf" +
        "7ca3779d242f1b960ed0ffd3fd5c2d6c72d5ba5b65baf5b704536bb66fb7e78aca666de5d54a0bfb2a764ee426c613a074162aa349b1b1893ed5")

    func testAV1KeyframeIsUnderstood() throws {
        XCTAssertEqual(AnnexB.keyframeCodec(DecoderTests.av1Keyframe), .av1)
        var copy = DecoderTests.av1Keyframe
        let format = try copy.withUnsafeMutableBufferPointer {
            try CMVideoFormatDescriptionCreateFromAV1SequenceHeaderOBUWithAV1C($0)
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)
        // Decoding needs AV1 hardware, which not every Mac has.
        try XCTSkipUnless(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1), "no AV1 decoder on this machine")
        let decoded = decodedSize(DecoderTests.av1Keyframe)
        XCTAssertEqual(decoded?.width, 128)
    }

    func testCodecIsReadFromTheStream() {
        XCTAssertEqual(AnnexB.keyframeCodec(DecoderTests.h264Keyframe), .h264)
        XCTAssertEqual(AnnexB.keyframeCodec(DecoderTests.hevcKeyframe), .hevc)
        // An access-unit delimiter in front does not hide it.
        XCTAssertEqual(AnnexB.keyframeCodec([0, 0, 0, 1, 0x09, 0xF0] + DecoderTests.h264Keyframe), .h264)
        XCTAssertEqual(AnnexB.keyframeCodec([0, 0, 0, 1, 0x46, 0x01, 0x50] + DecoderTests.hevcKeyframe), .hevc)
        // AV1: a temporal delimiter then a sequence header; then a delimiter and a frame.
        XCTAssertEqual(AnnexB.keyframeCodec([0x12, 0x00, 0x0A, 0x0B, 0x00, 0x00]), .av1)
        XCTAssertNil(AnnexB.keyframeCodec([0x12, 0x00, 0x32, 0x10]))
        // Parameter sets in front of an ordinary slice are not a keyframe (HEVC: VPS, SPS, PPS, then a trailing slice).
        XCTAssertNil(AnnexB.keyframeCodec([0, 0, 0, 1, 0x40, 0x01, 0x0C, 0, 0, 0, 1, 0x42, 0x01, 0x01, 0, 0, 0, 1, 0x44, 0x01, 0xC0,
                                           0, 0, 0, 1, 0x02, 0x01, 0xD0, 0x10]))
        // ... but in front of an IDR slice they are.
        XCTAssertEqual(AnnexB.keyframeCodec([0, 0, 0, 1, 0x40, 0x01, 0x0C, 0, 0, 0, 1, 0x42, 0x01, 0x01, 0, 0, 0, 1, 0x44, 0x01, 0xC0,
                                             0, 0, 0, 1, 0x26, 0x01, 0xAF, 0x10]), .hevc)
        // Slices alone are not keyframes: an H.264 non-IDR slice, an HEVC trailing slice.
        XCTAssertNil(AnnexB.keyframeCodec([0, 0, 0, 1, 0x41, 0x9A, 0x00]))
        XCTAssertNil(AnnexB.keyframeCodec([0, 0, 0, 1, 0x02, 0x01, 0xD0]))
    }

    private func decodedSize(_ keyframe: Bytes) -> (width: Int, height: Int)? {
        let decoder = VideoDecoder()
        let arrived = expectation(description: "a decoded picture")
        var size: (Int, Int)?
        decoder.onImage = { frame in
            size = (CVPixelBufferGetWidth(frame.image), CVPixelBufferGetHeight(frame.image))
            arrived.fulfill()
        }
        decoder.decode(EncodedFrame(frameID: 1, data: FrameBuffer(copying: keyframe), metadata: FrameMetadata(Bytes(repeating: 0, count: 0xF0))))
        wait(for: [arrived], timeout: 5)
        return size
    }

    func testH264KeyframeDecodes() {
        let size = decodedSize(DecoderTests.h264Keyframe)
        XCTAssertEqual(size?.width, 128)
        XCTAssertEqual(size?.height, 128)
    }

    func testHEVCKeyframeDecodes() {
        let size = decodedSize(DecoderTests.hevcKeyframe)
        XCTAssertEqual(size?.width, 128)
        XCTAssertEqual(size?.height, 128)
    }
}
