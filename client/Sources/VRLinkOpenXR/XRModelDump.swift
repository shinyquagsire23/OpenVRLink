// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import COpenXR
import Foundation
import VRLinkCore

/// Dumps controller glTF binary models exposed by the OpenXR runtime to disk so they can be inspected off
/// the headset when adding support for new controller render models.
///
/// `XRModelDump` queries `XR_EXT_interaction_render_model` (with `XR_EXT_render_model`), `XR_FB_render_model`,
/// and `XR_MSFT_controller_model`. Runtimes typically only expose a controller's model while it is powered on
/// and tracked, so `save(now:)` retries several times during the first minute of the session.
final class XRModelDump {
    private let instance: XRInstance
    private let session: XrSession
    private let folder: String
    private let log: (String) -> Void
    /// Previously logged messages, deduplicated across retries.
    private var said: Set<String> = []
    private var tries = 0, nextTry: UInt64 = 0

    init(instance: XRInstance, session: XrSession, folder: String, log: @escaping (String) -> Void) {
        self.instance = instance
        self.session = session
        self.folder = folder
        self.log = log
        let wanted = ["XR_EXT_interaction_render_model", "XR_EXT_render_model", "XR_FB_render_model", "XR_MSFT_controller_model"]
        log("controller models: runtime extensions: " + (wanted.filter { instance.offered.contains($0) }.joined(separator: ", ").nilIfEmpty ?? "none")
            + "; saving dumped models to \(folder)")
    }

    private func say(_ line: String) {
        if said.insert(line).inserted { log("controller models: " + line) }
    }

    private func write(_ bytes: [UInt8], as name: String) {
        let path = "\(folder)/\(name)"
        let written = FileManager.default.createFile(atPath: path, contents: Data(bytes))
        say(written ? "saved \(name), \(bytes.count) bytes" : "could not write \(path)")
    }

    /// Polls all three render-model extensions at 3, 10, 30, and 60 seconds into the session. Called each frame.
    func save(now: UInt64) {
        let waits: [UInt64] = [3, 10, 30, 60]
        if nextTry == 0 { nextTry = now + waits[0] * 1_000_000_000 }
        guard tries < waits.count, now >= nextTry else { return }
        tries += 1
        if tries < waits.count { nextTry = now + (waits[tries] - waits[tries - 1]) * 1_000_000_000 }
        let hands = [("left", try? instance.path("/user/hand/left")), ("right", try? instance.path("/user/hand/right"))]
        saveInteractionModels(hands)
        saveMetaModels()
        saveMicrosoftModels(hands)
    }

    private func saveInteractionModels(_ hands: [(String, XrPath?)]) {
        guard instance.extensions.contains("XR_EXT_interaction_render_model"), instance.extensions.contains("XR_EXT_render_model"),
              let enumerate = try? instance.function("xrEnumerateInteractionRenderModelIdsEXT", as: PFN_xrEnumerateInteractionRenderModelIdsEXT.self),
              let create = try? instance.function("xrCreateRenderModelEXT", as: PFN_xrCreateRenderModelEXT.self),
              let destroy = try? instance.function("xrDestroyRenderModelEXT", as: PFN_xrDestroyRenderModelEXT.self),
              let properties = try? instance.function("xrGetRenderModelPropertiesEXT", as: PFN_xrGetRenderModelPropertiesEXT.self),
              let createAsset = try? instance.function("xrCreateRenderModelAssetEXT", as: PFN_xrCreateRenderModelAssetEXT.self),
              let destroyAsset = try? instance.function("xrDestroyRenderModelAssetEXT", as: PFN_xrDestroyRenderModelAssetEXT.self),
              let assetData = try? instance.function("xrGetRenderModelAssetDataEXT", as: PFN_xrGetRenderModelAssetDataEXT.self)
        else { return }
        let assetProperties = try? instance.function("xrGetRenderModelAssetPropertiesEXT", as: PFN_xrGetRenderModelAssetPropertiesEXT.self)
        let whose = try? instance.function("xrGetRenderModelPoseTopLevelUserPathEXT", as: PFN_xrGetRenderModelPoseTopLevelUserPathEXT.self)
        var which = XrInteractionRenderModelIdsEnumerateInfoEXT()
        which.type = XR_TYPE_INTERACTION_RENDER_MODEL_IDS_ENUMERATE_INFO_EXT
        var count: UInt32 = 0
        var result = enumerate(session, &which, 0, &count, nil)
        guard result.rawValue >= 0 else { return say("XR_EXT_interaction_render_model: \(XRFailure.name(of: result))") }
        var ids = [XrRenderModelIdEXT](repeating: 0, count: Int(count))
        result = enumerate(session, &which, count, &count, &ids)
        guard result.rawValue >= 0, count > 0 else { return say("XR_EXT_interaction_render_model: no models yet") }
        for (index, id) in ids.prefix(Int(count)).enumerated() {
            var info = XrRenderModelCreateInfoEXT()
            info.type = XR_TYPE_RENDER_MODEL_CREATE_INFO_EXT
            info.renderModelId = id
            var model: XrRenderModelEXT?
            result = create(session, &info, &model)
            guard result.rawValue >= 0, let model else { say("XR_EXT_render_model: model \(index) not created (\(XRFailure.name(of: result)))"); continue }
            defer { _ = destroy(model) }
            var name = "\(index)"
            if let whose {
                let paths = hands.compactMap(\.1)
                var asked = XrInteractionRenderModelTopLevelUserPathGetInfoEXT()
                asked.type = XR_TYPE_INTERACTION_RENDER_MODEL_TOP_LEVEL_USER_PATH_GET_INFO_EXT
                var found: XrPath = 0
                let got = paths.withUnsafeBufferPointer { both -> XrResult in
                    asked.topLevelUserPathCount = UInt32(both.count)
                    asked.topLevelUserPaths = both.baseAddress
                    return whose(model, &asked, &found)
                }
                if got.rawValue >= 0, let hand = hands.first(where: { $0.1 == found && found != 0 }) { name = hand.0 }
            }
            var askProperties = XrRenderModelPropertiesGetInfoEXT()
            askProperties.type = XR_TYPE_RENDER_MODEL_PROPERTIES_GET_INFO_EXT
            var described = XrRenderModelPropertiesEXT()
            described.type = XR_TYPE_RENDER_MODEL_PROPERTIES_EXT
            guard properties(model, &askProperties, &described).rawValue >= 0 else { continue }
            var assetInfo = XrRenderModelAssetCreateInfoEXT()
            assetInfo.type = XR_TYPE_RENDER_MODEL_ASSET_CREATE_INFO_EXT
            assetInfo.cacheId = described.cacheId
            var asset: XrRenderModelAssetEXT?
            result = createAsset(session, &assetInfo, &asset)
            guard result.rawValue >= 0, let asset else { say("XR_EXT_render_model: no asset for \(name) (\(XRFailure.name(of: result)))"); continue }
            defer { _ = destroyAsset(asset) }
            var askData = XrRenderModelAssetDataGetInfoEXT()
            askData.type = XR_TYPE_RENDER_MODEL_ASSET_DATA_GET_INFO_EXT
            var data = XrRenderModelAssetDataEXT()
            data.type = XR_TYPE_RENDER_MODEL_ASSET_DATA_EXT
            guard assetData(asset, &askData, &data).rawValue >= 0, data.bufferCountOutput > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: Int(data.bufferCountOutput))
            result = bytes.withUnsafeMutableBufferPointer { all -> XrResult in
                data.bufferCapacityInput = UInt32(all.count)
                data.buffer = all.baseAddress
                return assetData(asset, &askData, &data)
            }
            guard result.rawValue >= 0 else { continue }
            write(bytes, as: "controller-model-ext-\(name).glb")
            // Log animatable glTF node names reported by XR_EXT_render_model.
            if let assetProperties, described.animatableNodeCount > 0 {
                var nodes = [XrRenderModelAssetNodePropertiesEXT](repeating: XrRenderModelAssetNodePropertiesEXT(), count: Int(described.animatableNodeCount))
                var askNodes = XrRenderModelAssetPropertiesGetInfoEXT()
                askNodes.type = XR_TYPE_RENDER_MODEL_ASSET_PROPERTIES_GET_INFO_EXT
                var listed = XrRenderModelAssetPropertiesEXT()
                listed.type = XR_TYPE_RENDER_MODEL_ASSET_PROPERTIES_EXT
                let got = nodes.withUnsafeMutableBufferPointer { all -> XrResult in
                    listed.nodePropertyCount = UInt32(all.count)
                    listed.nodeProperties = all.baseAddress
                    return assetProperties(asset, &askNodes, &listed)
                }
                if got.rawValue >= 0 { say("\(name): \(nodes.count) animatable nodes: " + nodes.map { text(of: $0.uniqueName) }.joined(separator: ", ")) }
            }
        }
    }

    private func saveMetaModels() {
        guard instance.extensions.contains("XR_FB_render_model"),
              let enumerate = try? instance.function("xrEnumerateRenderModelPathsFB", as: PFN_xrEnumerateRenderModelPathsFB.self),
              let properties = try? instance.function("xrGetRenderModelPropertiesFB", as: PFN_xrGetRenderModelPropertiesFB.self),
              let load = try? instance.function("xrLoadRenderModelFB", as: PFN_xrLoadRenderModelFB.self)
        else { return }
        var count: UInt32 = 0
        guard enumerate(session, 0, &count, nil).rawValue >= 0, count > 0 else { return say("XR_FB_render_model: no model paths") }
        var blank = XrRenderModelPathInfoFB()
        blank.type = XR_TYPE_RENDER_MODEL_PATH_INFO_FB
        var paths = [XrRenderModelPathInfoFB](repeating: blank, count: Int(count))
        guard enumerate(session, count, &count, &paths).rawValue >= 0 else { return }
        for path in paths.prefix(Int(count)) {
            let named = instance.string(path.path)
            var wanted = XrRenderModelCapabilitiesRequestFB()
            wanted.type = XR_TYPE_RENDER_MODEL_CAPABILITIES_REQUEST_FB
            wanted.flags = XR_RENDER_MODEL_SUPPORTS_GLTF_2_0_SUBSET_2_BIT_FB
            var described = XrRenderModelPropertiesFB()
            described.type = XR_TYPE_RENDER_MODEL_PROPERTIES_FB
            let result = withUnsafeMutablePointer(to: &wanted) { chained -> XrResult in
                described.next = UnsafeMutableRawPointer(chained)
                return properties(session, path.path, &described)
            }
            guard result.rawValue >= 0, described.modelKey != 0 else { say("\(named): not available (\(XRFailure.name(of: result)))"); continue }
            var info = XrRenderModelLoadInfoFB()
            info.type = XR_TYPE_RENDER_MODEL_LOAD_INFO_FB
            info.modelKey = described.modelKey
            var buffer = XrRenderModelBufferFB()
            buffer.type = XR_TYPE_RENDER_MODEL_BUFFER_FB
            guard load(session, &info, &buffer).rawValue >= 0, buffer.bufferCountOutput > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: Int(buffer.bufferCountOutput))
            let loaded = bytes.withUnsafeMutableBufferPointer { all -> XrResult in
                buffer.bufferCapacityInput = UInt32(all.count)
                buffer.buffer = all.baseAddress
                return load(session, &info, &buffer)
            }
            guard loaded.rawValue >= 0 else { continue }
            let file = named.split(separator: "/").joined(separator: "-")
            write(bytes, as: "controller-model-fb-\(file).glb")
            say("\(named) is \"\(text(of: described.modelName))\", version \(described.modelVersion)")
        }
    }

    private func saveMicrosoftModels(_ hands: [(String, XrPath?)]) {
        guard instance.extensions.contains("XR_MSFT_controller_model"),
              let key = try? instance.function("xrGetControllerModelKeyMSFT", as: PFN_xrGetControllerModelKeyMSFT.self),
              let load = try? instance.function("xrLoadControllerModelMSFT", as: PFN_xrLoadControllerModelMSFT.self)
        else { return }
        for (name, path) in hands {
            guard let path else { continue }
            var state = XrControllerModelKeyStateMSFT()
            state.type = XR_TYPE_CONTROLLER_MODEL_KEY_STATE_MSFT
            guard key(session, path, &state).rawValue >= 0, state.modelKey != 0 else { say("XR_MSFT_controller_model: no model for the \(name) hand yet"); continue }
            var count: UInt32 = 0
            guard load(session, state.modelKey, 0, &count, nil).rawValue >= 0, count > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: Int(count))
            guard load(session, state.modelKey, count, &count, &bytes).rawValue >= 0 else { continue }
            write(bytes, as: "controller-model-msft-\(name).glb")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
