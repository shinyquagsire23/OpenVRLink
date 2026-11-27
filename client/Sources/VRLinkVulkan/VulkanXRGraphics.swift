// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Android)
import CAndroidNDK
import COpenXR
import Foundation
import VRLinkCore
import VRLinkMediaCodec
import VRLinkOpenXR

/// Renders OpenXR swapchains on Android using Vulkan (`XR_KHR_vulkan_enable2`), importing `MediaCodecDecoder`
/// `AHardwareBuffer` images directly and converting YCbCr to RGB via `VkSamplerYcbcrConversion`.
///
/// All methods on `VulkanXRGraphics` run on the OpenXR render thread. Chroma keying is enabled when the
/// Vulkan device supports `dualSrcBlend` (`supportsChromaKey`).
public final class VulkanXRGraphics: XRGraphics {
    public typealias Frame = HardwareFrame

    public static let extensions = ["XR_KHR_vulkan_enable2"]

    /// Active chroma-key configuration applied when `supportsChromaKey` is true.
    public var chromaKey: ChromaKey?
    /// Whether the physical device supports Vulkan dual-source blending for chroma keying. Valid after `prepare`.
    public private(set) var supportsChromaKey = false
    /// Host chroma keying uses standard premultiplied alpha blending rather than dual-source blending.
    public var supportsHostChromaKey: Bool { true }
    /// Current passthrough dimming opacity behind host-keyed frames (`0...dimmedBy`), ramping in over 50 ms
    /// and out over 100 ms to match `vrlink`. Accessed on the render thread.
    private var dimNow: Float = 0, dimMoved: UInt64 = 0
    private static let dimmedBy: Float = 0.75

    private let log: (String) -> Void
    private var instance: VkInstance?
    private var physical: VkPhysicalDevice?
    private var device: VkDevice?
    private var queue: VkQueue?
    private var family: UInt32 = 0
    private var pool: VkCommandPool?
    private var commands: VkCommandBuffer?
    private var fence: VkFence?
    private var submitted = false

    private var renderPass: VkRenderPass?
    private var targetFormat = VK_FORMAT_UNDEFINED
    private var linearTarget = false
    /// Per-eye Vulkan image views and framebuffers for the OpenXR swapchains.
    private var targets: [[Target]] = []
    public private(set) var lastGPUWait: UInt64 = 0
    public private(set) var lastDrawSteps: [(name: String, nanoseconds: UInt64)] = []
    private var sizes: [VkExtent2D] = []

    private struct Target {
        var view: VkImageView?
        var framebuffer: VkFramebuffer?
    }

    /// Vulkan objects tied to a specific hardware-buffer pixel format. Because `VkSamplerYcbcrConversion` is
    /// baked into the immutable sampler, descriptor set layout, and graphics pipeline, all of them are
    /// recreated if the decoder's output format changes.
    private struct Sampling {
        var externalFormat: UInt64
        var format: VkFormat
        var conversion: VkSamplerYcbcrConversion?
        var sampler: VkSampler?
        var setLayout: VkDescriptorSetLayout?
        var layout: VkPipelineLayout?
        var pipeline: VkPipeline?
        /// Chroma-keyed graphics pipeline using dual-source blending, when supported.
        var keyedPipeline: VkPipeline?
        var descriptors: VkDescriptorPool?
    }
    private var sampling: Sampling?

    /// Cached `VkImage`, device memory, and `VkImageView` for an imported `AHardwareBuffer`.
    private struct Imported {
        var image: VkImage?
        var memory: VkDeviceMemory?
        var view: VkImageView?
        var lastUsed: Int
        /// Frame index in which this image was last acquired from `VK_QUEUE_FAMILY_FOREIGN_EXT`.
        var acquiredIn = 0
    }
    /// Imported Vulkan images keyed by `AHardwareBuffer_getId` across the decoder's buffer pool.
    private var imports: [UInt64: Imported] = [:]
    private var retired: [Imported] = []
    private var frameCount = 0
    /// Retains the frame currently in flight on the GPU so its `AHardwareBuffer`s are not recycled prematurely.
    private var drawing: HardwareFrame?
    /// Initial decoded frames of each stream read back to log average sampled brightness alongside `encodingGamma`.
    private var streamRead = 0, streamLast: UInt16?
    private var streamReadings: [(gamma: Float, mean: Float)] = []
    private static let streamReads = 90
    private static let importsKept = 16

    private var vertexBuffer = Buffer(), indexBuffer = Buffer()

    private struct Buffer {
        var handle: VkBuffer?
        var memory: VkDeviceMemory?
        var mapped: UnsafeMutableRawPointer?
        var capacity = 0
    }

    private let quirks: HeadsetQuirks

    public init(quirks: HeadsetQuirks = HeadsetQuirks(), log: @escaping (String) -> Void) {
        self.quirks = quirks
        self.log = log
        heldCorrection = VulkanXRGraphics.treatment(from: quirks).correction
    }

    // MARK: Device

    public func prepare(instance xr: XRInstance) throws {
        let arena = Arena()
        defer { arena.free() }
        let requirements = try xr.function("xrGetVulkanGraphicsRequirements2KHR", as: PFN_xrGetVulkanGraphicsRequirements2KHR.self)
        var wanted = XrGraphicsRequirementsVulkanKHR()
        wanted.type = XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR
        try XRFailure.check(requirements(xr.handle, xr.system, &wanted), "xrGetVulkanGraphicsRequirements2KHR")

        // Create the VkInstance and VkDevice through XR_KHR_vulkan_enable2 so the runtime can inject any
        // extensions required by its compositor.
        var application = VkApplicationInfo()
        application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        application.pApplicationName = arena.keep(cString: "OpenVRLink")
        application.apiVersion = Vulkan.version(1, 1)
        var instanceInfo = VkInstanceCreateInfo()
        instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        instanceInfo.pApplicationInfo = UnsafePointer(arena.keep(application))

        var made = XrVulkanInstanceCreateInfoKHR()
        made.type = XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR
        made.systemId = xr.system
        made.pfnGetInstanceProcAddr = vkGetInstanceProcAddr
        made.vulkanCreateInfo = UnsafePointer(arena.keep(instanceInfo))
        var result = VK_SUCCESS
        let createInstance = try xr.function("xrCreateVulkanInstanceKHR", as: PFN_xrCreateVulkanInstanceKHR.self)
        try XRFailure.check(createInstance(xr.handle, &made, &instance, &result), "xrCreateVulkanInstanceKHR")
        try Vulkan.check(result, "vkCreateInstance")

        var which = XrVulkanGraphicsDeviceGetInfoKHR()
        which.type = XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR
        which.systemId = xr.system
        which.vulkanInstance = instance
        let graphicsDevice = try xr.function("xrGetVulkanGraphicsDevice2KHR", as: PFN_xrGetVulkanGraphicsDevice2KHR.self)
        try XRFailure.check(graphicsDevice(xr.handle, &which, &physical), "xrGetVulkanGraphicsDevice2KHR")

        var count: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nil)
        var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(count))
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, &families)
        guard let graphics = families.firstIndex(where: { $0.queueFlags & VK_QUEUE_GRAPHICS_BIT.rawValue != 0 })
        else { throw XRFailure.unsupported("a Vulkan graphics queue") }
        family = UInt32(graphics)

        var queueInfo = VkDeviceQueueCreateInfo()
        queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        queueInfo.queueFamilyIndex = family
        queueInfo.queueCount = 1
        queueInfo.pQueuePriorities = UnsafePointer(arena.keep(Float(1)))
        // Enable YCbCr sampler conversion and Android external hardware-buffer memory imports.
        var conversion = VkPhysicalDeviceSamplerYcbcrConversionFeatures()
        conversion.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES
        conversion.samplerYcbcrConversion = 1
        let names = ["VK_ANDROID_external_memory_android_hardware_buffer", "VK_EXT_queue_family_foreign"]
        var offered = VkPhysicalDeviceFeatures()
        vkGetPhysicalDeviceFeatures(physical, &offered)
        supportsChromaKey = offered.dualSrcBlend != 0
        var enabled = VkPhysicalDeviceFeatures()
        enabled.dualSrcBlend = offered.dualSrcBlend
        log("vulkan: chroma keying \(supportsChromaKey ? "available" : "unavailable (dualSrcBlend unsupported)")")
        var deviceInfo = VkDeviceCreateInfo()
        deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        deviceInfo.pEnabledFeatures = UnsafePointer(arena.keep(enabled))
        deviceInfo.pNext = UnsafeRawPointer(arena.keep(conversion))
        deviceInfo.queueCreateInfoCount = 1
        deviceInfo.pQueueCreateInfos = UnsafePointer(arena.keep(queueInfo))
        deviceInfo.enabledExtensionCount = UInt32(names.count)
        deviceInfo.ppEnabledExtensionNames = UnsafePointer(arena.keep(names.map { arena.keep(cString: $0) }))

        var deviceMade = XrVulkanDeviceCreateInfoKHR()
        deviceMade.type = XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR
        deviceMade.systemId = xr.system
        deviceMade.pfnGetInstanceProcAddr = vkGetInstanceProcAddr
        deviceMade.vulkanPhysicalDevice = physical
        deviceMade.vulkanCreateInfo = UnsafePointer(arena.keep(deviceInfo))
        let createDevice = try xr.function("xrCreateVulkanDeviceKHR", as: PFN_xrCreateVulkanDeviceKHR.self)
        try XRFailure.check(createDevice(xr.handle, &deviceMade, &device, &result), "xrCreateVulkanDeviceKHR")
        try Vulkan.check(result, "vkCreateDevice")
        vkGetDeviceQueue(device, family, 0, &queue)

        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue
        poolInfo.queueFamilyIndex = family
        try Vulkan.check(vkCreateCommandPool(device, &poolInfo, nil, &pool), "vkCreateCommandPool")
        var allocate = VkCommandBufferAllocateInfo()
        allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocate.commandPool = pool
        allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocate.commandBufferCount = 1
        try Vulkan.check(vkAllocateCommandBuffers(device, &allocate, &commands), "vkAllocateCommandBuffers")
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        try Vulkan.check(vkCreateFence(device, &fenceInfo, nil, &fence), "vkCreateFence")
    }

    public func withSessionBinding<Result>(_ body: (UnsafeRawPointer) throws -> Result) throws -> Result {
        var binding = XrGraphicsBindingVulkan2KHR()
        binding.type = XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR
        binding.instance = instance
        binding.physicalDevice = physical
        binding.device = device
        binding.queueFamilyIndex = family
        binding.queueIndex = 0
        return try withUnsafePointer(to: &binding) { try body(UnsafeRawPointer($0)) }
    }

    /// Preferred swapchain formats, prioritizing sRGB attachments for hardware linear-to-sRGB encoding.
    private static let formats = [VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM]

    public func chooseFormat(among offered: [Int64]) -> Int64? {
        let wanted = (quirks.floatTarget ? [VK_FORMAT_R16G16B16A16_SFLOAT] : []) + VulkanXRGraphics.formats
        return wanted.map { Int64($0.rawValue) }.first { offered.contains($0) }
    }

    // MARK: Targets

    public func adopt(_ swapchains: [XRSwapchain], instance xr: XRInstance) throws {
        guard let first = swapchains.first else { return }
        let format = VkFormat(rawValue: UInt32(first.format))
        targetFormat = format
        // sRGB attachments encode linear output automatically on write. Float swapchain encoding is left
        // unspecified by OpenXR and varies across headsets (`HeadsetQuirks.floatTargetIsEncoded`).
        if format == VK_FORMAT_R16G16B16A16_SFLOAT {
            linearTarget = !quirks.floatTargetIsEncoded
        } else {
            linearTarget = format == VK_FORMAT_R8G8B8A8_SRGB || format == VK_FORMAT_B8G8R8A8_SRGB
        }
        log("vulkan: swapchain format \(format.rawValue), written as \(linearTarget ? "linear light" : "sRGB-encoded")")

        // OpenXR acquires and releases swapchain images in VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL.
        var attachment = VkAttachmentDescription()
        attachment.format = format
        attachment.samples = VK_SAMPLE_COUNT_1_BIT
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
        attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE
        attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
        attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
        attachment.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        attachment.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        var reference = VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        try withUnsafePointer(to: &reference) { reference in
            var subpass = VkSubpassDescription()
            subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
            subpass.colorAttachmentCount = 1
            subpass.pColorAttachments = reference
            var info = VkRenderPassCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
            info.attachmentCount = 1
            info.subpassCount = 1
            try withUnsafePointer(to: &attachment) { attachment in
                try withUnsafePointer(to: &subpass) { subpass in
                    info.pAttachments = attachment
                    info.pSubpasses = subpass
                    try Vulkan.check(vkCreateRenderPass(device, &info, nil, &renderPass), "vkCreateRenderPass")
                }
            }
        }

        let enumerate = try xr.function("xrEnumerateSwapchainImages", as: PFN_xrEnumerateSwapchainImages.self)
        for swapchain in swapchains {
            var count: UInt32 = 0
            try XRFailure.check(enumerate(swapchain.handle, 0, &count, nil), "xrEnumerateSwapchainImages")
            var blank = XrSwapchainImageVulkan2KHR()
            blank.type = XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR
            var images = [XrSwapchainImageVulkan2KHR](repeating: blank, count: Int(count))
            // xrEnumerateSwapchainImages populates the array of XrSwapchainImageVulkan2KHR via its base header pointer.
            try XRFailure.check(images.withUnsafeMutableBytes { all in
                enumerate(swapchain.handle, count, &count, all.baseAddress?.assumingMemoryBound(to: XrSwapchainImageBaseHeader.self))
            }, "xrEnumerateSwapchainImages")
            let size = VkExtent2D(width: UInt32(swapchain.width), height: UInt32(swapchain.height))
            sizes.append(size)
            targets.append(try images.map { image in
                var target = Target()
                var viewInfo = VkImageViewCreateInfo()
                viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
                viewInfo.image = image.image
                viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
                viewInfo.format = format
                viewInfo.subresourceRange = Vulkan.wholeColor
                try Vulkan.check(vkCreateImageView(device, &viewInfo, nil, &target.view), "vkCreateImageView")
                var framebuffer = VkFramebufferCreateInfo()
                framebuffer.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
                framebuffer.renderPass = renderPass
                framebuffer.attachmentCount = 1
                framebuffer.width = size.width
                framebuffer.height = size.height
                framebuffer.layers = 1
                try withUnsafePointer(to: &target.view) { view in
                    framebuffer.pAttachments = view
                    try Vulkan.check(vkCreateFramebuffer(device, &framebuffer, nil, &target.framebuffer), "vkCreateFramebuffer")
                }
                return target
            })
        }
    }

    // MARK: Decoded pictures

    /// Queries Vulkan memory allocation and YCbCr format properties for an `AHardwareBuffer`.
    private func describe(_ buffer: OpaquePointer) throws -> (VkAndroidHardwareBufferPropertiesANDROID, VkAndroidHardwareBufferFormatPropertiesANDROID) {
        var format = VkAndroidHardwareBufferFormatPropertiesANDROID()
        format.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID
        var properties = VkAndroidHardwareBufferPropertiesANDROID()
        properties.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID
        try withUnsafeMutablePointer(to: &format) { chained in
            properties.pNext = UnsafeMutableRawPointer(chained)
            try Vulkan.check(vkGetAndroidHardwareBufferPropertiesANDROID(device, buffer, &properties),
                             "vkGetAndroidHardwareBufferPropertiesANDROID")
        }
        properties.pNext = nil
        return (properties, format)
    }

    /// Creates the YCbCr conversion, immutable sampler, descriptor layout, and graphics pipeline for `format`.
    private func makeSampling(for format: VkAndroidHardwareBufferFormatPropertiesANDROID) throws -> Sampling {
        let arena = Arena()
        defer { arena.free() }
        var made = Sampling(externalFormat: format.externalFormat, format: format.format)

        // Vendor-proprietary decoder formats report VK_FORMAT_UNDEFINED and bind via VkExternalFormatANDROID.
        var external = VkExternalFormatANDROID()
        external.sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID
        external.externalFormat = format.format == VK_FORMAT_UNDEFINED ? format.externalFormat : 0
        let linear = format.formatFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER_BIT.rawValue != 0
        var conversion = VkSamplerYcbcrConversionCreateInfo()
        conversion.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO
        conversion.pNext = UnsafeRawPointer(arena.keep(external))
        conversion.format = format.format
        conversion.ycbcrModel = format.suggestedYcbcrModel
        switch quirks.videoRange {
        case .narrow: conversion.ycbcrRange = VK_SAMPLER_YCBCR_RANGE_ITU_NARROW
        case .full: conversion.ycbcrRange = VK_SAMPLER_YCBCR_RANGE_ITU_FULL
        case nil: conversion.ycbcrRange = format.suggestedYcbcrRange
        }
        if quirks.shaderColorConversion {
            // Request raw Y'CbCr values (RGB_IDENTITY, full range) so quad.frag performs the BT.2020 conversion.
            conversion.ycbcrModel = VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY
            conversion.ycbcrRange = VK_SAMPLER_YCBCR_RANGE_ITU_FULL
            log("vulkan: converting decoded pictures to RGB in the shader (BT.2020, full range) instead of in the sampler")
        }
        log("vulkan: decoded pictures are format \(format.format.rawValue) (external \(format.externalFormat)), model "
            + "\(format.suggestedYcbcrModel.rawValue), range \(format.suggestedYcbcrRange.rawValue) suggested and "
            + "\(conversion.ycbcrRange.rawValue) used")
        conversion.components = format.samplerYcbcrConversionComponents
        conversion.xChromaOffset = format.suggestedXChromaOffset
        conversion.yChromaOffset = format.suggestedYChromaOffset
        conversion.chromaFilter = linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST
        try Vulkan.check(vkCreateSamplerYcbcrConversion(device, &conversion, nil, &made.conversion), "vkCreateSamplerYcbcrConversion")

        var bound = VkSamplerYcbcrConversionInfo()
        bound.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO
        bound.conversion = made.conversion
        var sampler = VkSamplerCreateInfo()
        sampler.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        sampler.pNext = UnsafeRawPointer(arena.keep(bound))
        // Vulkan requires magFilter and minFilter to match the YCbCr conversion's chromaFilter.
        sampler.magFilter = conversion.chromaFilter
        sampler.minFilter = conversion.chromaFilter
        sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST
        sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        try Vulkan.check(vkCreateSampler(device, &sampler, nil, &made.sampler), "vkCreateSampler")

        // Bind both the color and optional alpha textures with the immutable YCbCr conversion sampler.
        let samplers = arena.keep([made.sampler, made.sampler])
        var bindings = [VkDescriptorSetLayoutBinding](repeating: VkDescriptorSetLayoutBinding(), count: 2)
        for index in 0..<2 {
            bindings[index].binding = UInt32(index)
            bindings[index].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
            bindings[index].descriptorCount = 1
            bindings[index].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT.rawValue
            bindings[index].pImmutableSamplers = UnsafePointer(samplers + index)
        }
        var setInfo = VkDescriptorSetLayoutCreateInfo()
        setInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
        setInfo.bindingCount = 2
        setInfo.pBindings = UnsafePointer(arena.keep(bindings))
        try Vulkan.check(vkCreateDescriptorSetLayout(device, &setInfo, nil, &made.setLayout), "vkCreateDescriptorSetLayout")

        var constants = VkPushConstantRange()
        constants.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT.rawValue
        constants.size = UInt32(MemoryLayout<Float>.size * QuadStyle.floats)
        var layoutInfo = VkPipelineLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        layoutInfo.setLayoutCount = 1
        layoutInfo.pSetLayouts = UnsafePointer(arena.keep(made.setLayout))
        layoutInfo.pushConstantRangeCount = 1
        layoutInfo.pPushConstantRanges = UnsafePointer(arena.keep(constants))
        try Vulkan.check(vkCreatePipelineLayout(device, &layoutInfo, nil, &made.layout), "vkCreatePipelineLayout")

        var sizes = VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: 2 * VulkanXRGraphics.setsPerFrame)
        var poolInfo = VkDescriptorPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        poolInfo.maxSets = VulkanXRGraphics.setsPerFrame
        poolInfo.poolSizeCount = 1
        try withUnsafePointer(to: &sizes) {
            poolInfo.pPoolSizes = $0
            try Vulkan.check(vkCreateDescriptorPool(device, &poolInfo, nil, &made.descriptors), "vkCreateDescriptorPool")
        }

        made.pipeline = try makePipeline(layout: made.layout, keyed: false)
        if supportsChromaKey { made.keyedPipeline = try makePipeline(layout: made.layout, keyed: true) }
        log(String(format: "vulkan: sampling decoded pictures of format %d (external %llx), %@ chroma", format.format.rawValue,
                   format.externalFormat, linear ? "linear" : "nearest"))
        return made
    }

    /// Maximum descriptor sets allocated per frame across all eye draws and texture pairs.
    private static let setsPerFrame: UInt32 = 32

    private func shader(_ words: [UInt32]) throws -> VkShaderModule? {
        var module: VkShaderModule?
        try words.withUnsafeBufferPointer { code in
            var info = VkShaderModuleCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
            info.codeSize = code.count * MemoryLayout<UInt32>.size
            info.pCode = code.baseAddress
            try Vulkan.check(vkCreateShaderModule(device, &info, nil, &module), "vkCreateShaderModule")
        }
        return module
    }

    /// Creates the quad graphics pipeline, using the dual-source chroma-key fragment shader when `keyed` is true.
    private func makePipeline(layout: VkPipelineLayout?, keyed: Bool) throws -> VkPipeline? {
        let arena = Arena()
        defer { arena.free() }
        let vertex = try shader(QuadShaders.vertex), fragment = try shader(keyed ? QuadShaders.keyedFragment : QuadShaders.fragment)
        defer {
            vkDestroyShaderModule(device, vertex, nil)
            vkDestroyShaderModule(device, fragment, nil)
        }
        let entry = arena.keep(cString: "main")
        var stages = [VkPipelineShaderStageCreateInfo](repeating: VkPipelineShaderStageCreateInfo(), count: 2)
        for (index, stage) in [(VK_SHADER_STAGE_VERTEX_BIT, vertex), (VK_SHADER_STAGE_FRAGMENT_BIT, fragment)].enumerated() {
            stages[index].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            stages[index].stage = stage.0
            stages[index].module = stage.1
            stages[index].pName = UnsafePointer(entry)
        }

        // Vertex layout matching QuadMesh: clip position (4), color UV (2), alpha UV (2), quad UV (2), ahead (1).
        let float = UInt32(MemoryLayout<Float>.size)
        var binding = VkVertexInputBindingDescription()
        binding.stride = UInt32(QuadMesh.floatsPerVertex) * float
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX
        let attributes = [
            VkVertexInputAttributeDescription(location: 0, binding: 0, format: VK_FORMAT_R32G32B32A32_SFLOAT, offset: 0),
            VkVertexInputAttributeDescription(location: 1, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: 4 * float),
            VkVertexInputAttributeDescription(location: 2, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: 6 * float),
            VkVertexInputAttributeDescription(location: 3, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: 8 * float),
            VkVertexInputAttributeDescription(location: 4, binding: 0, format: VK_FORMAT_R32_SFLOAT, offset: 10 * float),
        ]
        var input = VkPipelineVertexInputStateCreateInfo()
        input.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        input.vertexBindingDescriptionCount = 1
        input.pVertexBindingDescriptions = UnsafePointer(arena.keep(binding))
        input.vertexAttributeDescriptionCount = UInt32(attributes.count)
        input.pVertexAttributeDescriptions = UnsafePointer(arena.keep(attributes))

        var assembly = VkPipelineInputAssemblyStateCreateInfo()
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST

        // Viewport and scissor are set per eye.
        var viewport = VkPipelineViewportStateCreateInfo()
        viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewport.viewportCount = 1
        viewport.scissorCount = 1
        let dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
        var dynamic = VkPipelineDynamicStateCreateInfo()
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamic.dynamicStateCount = UInt32(dynamicStates.count)
        dynamic.pDynamicStates = UnsafePointer(arena.keep(dynamicStates))

        var raster = VkPipelineRasterizationStateCreateInfo()
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        raster.polygonMode = VK_POLYGON_MODE_FILL
        raster.cullMode = VK_CULL_MODE_NONE.rawValue
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE
        raster.lineWidth = 1

        var samples = VkPipelineMultisampleStateCreateInfo()
        samples.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        samples.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT

        // Render quads back-to-front using premultiplied alpha blending.
        var blend = VkPipelineColorBlendAttachmentState()
        blend.blendEnable = 1
        blend.srcColorBlendFactor = VK_BLEND_FACTOR_ONE
        blend.dstColorBlendFactor = keyed ? VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA : VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        blend.colorBlendOp = VK_BLEND_OP_ADD
        blend.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
        blend.dstAlphaBlendFactor = keyed ? VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA : VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        blend.alphaBlendOp = VK_BLEND_OP_ADD
        blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue
            | VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue
        var blending = VkPipelineColorBlendStateCreateInfo()
        blending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        blending.attachmentCount = 1
        blending.pAttachments = UnsafePointer(arena.keep(blend))

        var info = VkGraphicsPipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        info.stageCount = 2
        info.pStages = UnsafePointer(arena.keep(stages))
        info.pVertexInputState = UnsafePointer(arena.keep(input))
        info.pInputAssemblyState = UnsafePointer(arena.keep(assembly))
        info.pViewportState = UnsafePointer(arena.keep(viewport))
        info.pRasterizationState = UnsafePointer(arena.keep(raster))
        info.pMultisampleState = UnsafePointer(arena.keep(samples))
        info.pColorBlendState = UnsafePointer(arena.keep(blending))
        info.pDynamicState = UnsafePointer(arena.keep(dynamic))
        info.layout = layout
        info.renderPass = renderPass
        var pipeline: VkPipeline?
        try Vulkan.check(vkCreateGraphicsPipelines(device, nil, 1, &info, nil, &pipeline), "vkCreateGraphicsPipelines")
        return pipeline
    }

    private func destroy(_ sampling: Sampling) {
        vkDestroyPipeline(device, sampling.pipeline, nil)
        if let keyed = sampling.keyedPipeline { vkDestroyPipeline(device, keyed, nil) }
        vkDestroyDescriptorPool(device, sampling.descriptors, nil)
        vkDestroyPipelineLayout(device, sampling.layout, nil)
        vkDestroyDescriptorSetLayout(device, sampling.setLayout, nil)
        vkDestroySampler(device, sampling.sampler, nil)
        vkDestroySamplerYcbcrConversion(device, sampling.conversion, nil)
    }

    private func destroy(_ imported: Imported) {
        vkDestroyImageView(device, imported.view, nil)
        vkDestroyImage(device, imported.image, nil)
        vkFreeMemory(device, imported.memory, nil)
    }

    /// Returns a `VkImageView` for `picture`, importing its `AHardwareBuffer` on first use.
    private func view(of picture: HardwarePicture, with commands: VkCommandBuffer?) throws -> VkImageView? {
        // Android < 12 (API 31) lacks `AHardwareBuffer_getId`, so fall back to the buffer pointer address,
        // which stays stable while pooled by `AImageReader`.
        var id = UInt64(UInt(bitPattern: Int(bitPattern: picture.buffer)))
        if #available(Android 31, *) { AHardwareBuffer_getId(picture.buffer, &id) }
        if let known = imports[id] {
            imports[id]?.lastUsed = frameCount
            if known.acquiredIn != frameCount {
                // Acquire ownership from VK_QUEUE_FAMILY_FOREIGN_EXT once per frame so writes from the hardware
                // decoder are visible to shader reads rather than served from stale GPU caches.
                imports[id]?.acquiredIn = frameCount
                var barrier = VkImageMemoryBarrier()
                barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
                barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT.rawValue
                barrier.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                barrier.srcQueueFamilyIndex = Vulkan.foreignQueueFamily
                barrier.dstQueueFamilyIndex = family
                barrier.image = known.image
                barrier.subresourceRange = Vulkan.wholeColor
                vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue,
                                     0, 0, nil, 0, nil, 1, &barrier)
            }
            return known.view
        }
        let (properties, format) = try describe(picture.buffer)
        if let current = sampling, current.externalFormat != format.externalFormat || current.format != format.format {
            // Rebuild the YCbCr pipeline and discard cached imports if the decoder output format changes.
            vkDeviceWaitIdle(device)
            imports.values.forEach(destroy)
            imports = [:]
            destroy(current)
            sampling = nil
        }
        if sampling == nil { sampling = try makeSampling(for: format) }
        guard let sampling else { return nil }

        let arena = Arena()
        defer { arena.free() }
        var described = AHardwareBuffer_Desc()
        AHardwareBuffer_describe(picture.buffer, &described)
        var external = VkExternalFormatANDROID()
        external.sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID
        external.externalFormat = format.format == VK_FORMAT_UNDEFINED ? format.externalFormat : 0
        var shared = VkExternalMemoryImageCreateInfo()
        shared.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
        shared.pNext = UnsafeRawPointer(arena.keep(external))
        shared.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID.rawValue
        var imageInfo = VkImageCreateInfo()
        imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.pNext = UnsafeRawPointer(arena.keep(shared))
        imageInfo.imageType = VK_IMAGE_TYPE_2D
        imageInfo.format = format.format
        imageInfo.extent = VkExtent3D(width: described.width, height: described.height, depth: 1)
        imageInfo.mipLevels = 1
        imageInfo.arrayLayers = 1
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
        imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        var imported = Imported(lastUsed: frameCount)
        try Vulkan.check(vkCreateImage(device, &imageInfo, nil, &imported.image), "vkCreateImage")

        // Import the AHardwareBuffer directly as dedicated VkDeviceMemory.
        var dedicated = VkMemoryDedicatedAllocateInfo()
        dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        dedicated.image = imported.image
        var source = VkImportAndroidHardwareBufferInfoANDROID()
        source.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID
        source.pNext = UnsafeRawPointer(arena.keep(dedicated))
        source.buffer = picture.buffer
        var memoryInfo = VkMemoryAllocateInfo()
        memoryInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        memoryInfo.pNext = UnsafeRawPointer(arena.keep(source))
        memoryInfo.allocationSize = properties.allocationSize
        memoryInfo.memoryTypeIndex = UInt32(properties.memoryTypeBits.trailingZeroBitCount)
        do {
            try Vulkan.check(vkAllocateMemory(device, &memoryInfo, nil, &imported.memory), "vkAllocateMemory (hardware buffer)")
            try Vulkan.check(vkBindImageMemory(device, imported.image, imported.memory, 0), "vkBindImageMemory")
            var bound = VkSamplerYcbcrConversionInfo()
            bound.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO
            bound.conversion = sampling.conversion
            var viewInfo = VkImageViewCreateInfo()
            viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            viewInfo.pNext = UnsafeRawPointer(arena.keep(bound))
            viewInfo.image = imported.image
            viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
            viewInfo.format = format.format
            viewInfo.subresourceRange = Vulkan.wholeColor
            try Vulkan.check(vkCreateImageView(device, &viewInfo, nil, &imported.view), "vkCreateImageView (hardware buffer)")
        } catch {
            destroy(imported)
            throw error
        }

        // Acquire ownership of the image from VK_QUEUE_FAMILY_FOREIGN_EXT and transition it for shader sampling.
        var barrier = VkImageMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT.rawValue
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED
        barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        barrier.srcQueueFamilyIndex = Vulkan.foreignQueueFamily
        barrier.dstQueueFamilyIndex = family
        barrier.image = imported.image
        barrier.subresourceRange = Vulkan.wholeColor
        vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue,
                             0, 0, nil, 0, nil, 1, &barrier)
        imported.acquiredIn = frameCount
        imports[id] = imported
        return imported.view
    }

    /// Releases all hardware-buffer images acquired during this frame back to `VK_QUEUE_FAMILY_FOREIGN_EXT`.
    private func releasePictures() {
        for imported in imports.values where imported.acquiredIn == frameCount {
            var barrier = VkImageMemoryBarrier()
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
            barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT.rawValue
            barrier.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            barrier.srcQueueFamilyIndex = family
            barrier.dstQueueFamilyIndex = Vulkan.foreignQueueFamily
            barrier.image = imported.image
            barrier.subresourceRange = Vulkan.wholeColor
            vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT.rawValue,
                                 0, 0, nil, 0, nil, 1, &barrier)
        }
    }

    // MARK: Drawing

    /// Ensures `buffer` has at least `bytes` of host-visible, host-coherent capacity.
    private func reserve(_ buffer: inout Buffer, bytes: Int, usage: VkBufferUsageFlagBits) throws {
        guard bytes > buffer.capacity else { return }
        if buffer.handle != nil {
            vkUnmapMemory(device, buffer.memory)
            vkDestroyBuffer(device, buffer.handle, nil)
            vkFreeMemory(device, buffer.memory, nil)
            buffer = Buffer()
        }
        let capacity = max(bytes * 2, 64 * 1024)
        var info = VkBufferCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size = VkDeviceSize(capacity)
        info.usage = usage.rawValue
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        try Vulkan.check(vkCreateBuffer(device, &info, nil, &buffer.handle), "vkCreateBuffer")
        var needs = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(device, buffer.handle, &needs)
        var memory = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(physical, &memory)
        let visible = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
        let types = withUnsafeBytes(of: &memory.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self)) }
        guard let type = (0..<Int(memory.memoryTypeCount)).first(where: {
            needs.memoryTypeBits & (1 << UInt32($0)) != 0 && types[$0].propertyFlags & visible == visible
        }) else { throw XRFailure.unsupported("host-visible coherent Vulkan memory") }
        var allocate = VkMemoryAllocateInfo()
        allocate.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocate.allocationSize = needs.size
        allocate.memoryTypeIndex = UInt32(type)
        try Vulkan.check(vkAllocateMemory(device, &allocate, nil, &buffer.memory), "vkAllocateMemory")
        try Vulkan.check(vkBindBufferMemory(device, buffer.handle, buffer.memory, 0), "vkBindBufferMemory")
        try Vulkan.check(vkMapMemory(device, buffer.memory, 0, Vulkan.wholeSize, 0, &buffer.mapped), "vkMapMemory")
        buffer.capacity = capacity
    }

    // MARK: Depth

    /// Offscreen side-by-side stereo render target used to downsample frames for depth estimation, allocated in
    /// `targetFormat` so it can reuse the main `renderPass` and quad pipeline.
    private struct ShrinkTarget {
        var image: VkImage?
        var memory: VkDeviceMemory?
        var view: VkImageView?
        var framebuffer: VkFramebuffer?
        var eyeWidth = 0, height = 0
    }
    private var shrinkTarget = ShrinkTarget()
    private var shrinkVertices = Buffer(), shrinkPixels = Buffer()
    private let shrinkLock = NSLock()
    /// Pending downsampling request queued for the next `draw` call (guarded by `shrinkLock`).
    private var shrinkAsked: (frame: HardwareFrame, width: Int, done: (StereoPair?) -> Void)?
    /// In-flight downsampling request whose GPU copy into `shrinkPixels` will complete with the current frame fence.
    private var shrinkDrawn: (frame: HardwareFrame, plan: StereoPlan, done: (StereoPair?) -> Void)?
    private var shrinkComplained = false

    /// Fallback 3x4 color correction matrix (`QuadStyle` `correction`) derived from `HeadsetQuirks` until
    /// overridden by `ColorProbe`. Guarded by `shrinkLock`.
    private var heldCorrection: [Float]
    /// Per-external-format 3x4 color correction matrices measured by `ColorProbe` (8-bit and 10-bit streams use
    /// distinct external formats). Guarded by `shrinkLock`.
    private var measuredCorrections: [UInt64: [Float]] = [:]
    /// Active 3x4 color correction matrix for the current video sampler format.
    private var colorCorrection: [Float] {
        shrinkLock.lock()
        defer { shrinkLock.unlock() }
        return sampling.flatMap { measuredCorrections[$0.externalFormat] } ?? heldCorrection
    }
    /// Returns the active color correction for `layout`, or an identity matrix when the bitstream specifies
    /// its own color matrix.
    private func correction(for layout: FrameLayout?) -> [Float] {
        layout?.encodedWith == nil ? ColorProbe.noCorrection : colorCorrection
    }
    /// Pending and in-flight `ColorProbe` readback requests (analogous to `shrinkAsked` / `shrinkDrawn`).
    private var probeAsked: (frame: HardwareFrame, corrected: Bool, done: ((colors: [[Float]], format: UInt64)?) -> Void)?
    private var probeDrawn: (frame: HardwareFrame, format: UInt64, done: ((colors: [[Float]], format: UInt64)?) -> Void)?

    /// Returns the fallback `ColorProbe.Treatment` configured by `quirks`.
    public static func treatment(from quirks: HeadsetQuirks) -> ColorProbe.Treatment {
        ColorProbe.Treatment(matrix: quirks.shaderColorConversion ? nil : .bt2020, stretched: quirks.undoRangeStretch)
    }

    /// Stores the inverse color matrix for `treatment` on external buffer format `format` (at `bits` bits per
    /// sample), taking effect on the next rendered frame. Thread-safe.
    public func correct(for treatment: ColorProbe.Treatment, bits: Int, format: UInt64) {
        shrinkLock.lock()
        measuredCorrections[format] = treatment.correction(bits: bits)
        shrinkLock.unlock()
    }

    /// Renders a decoded `ColorProbe` frame through the stream's Y'CbCr sampler with no color correction, reads
    /// back the center of each of the 16 patches, and delivers the unclamped RGB values and external buffer
    /// format on the render thread.
    ///
    /// When `corrected` is `true`, applies the active color correction for the frame's external format so the
    /// readback reflects rendered stream output.
    public func probeColors(_ frame: HardwareFrame, corrected: Bool = false, done: @escaping ((colors: [[Float]], format: UInt64)?) -> Void) {
        shrinkLock.lock()
        let passedOver = probeAsked
        probeAsked = (frame, corrected, done)
        shrinkLock.unlock()
        passedOver?.done(nil)
    }

    /// Samples the initial frames of each stream uncorrected and logs average brightness grouped by `encodingGamma`
    /// to verify that the host's shader patch brightened frames once `encodingGamma > 1` took effect.
    private func noteStreamStart(_ frame: HardwareFrame?) {
        guard let frame else {
            streamRead = 0
            streamLast = nil
            streamReadings = []
            return
        }
        guard quirks.measureColors, streamRead < VulkanXRGraphics.streamReads, frame.frameID != streamLast else { return }
        streamLast = frame.frameID
        streamRead += 1
        let gamma = frame.layout.encodingGamma, last = streamRead == VulkanXRGraphics.streamReads
        probeColors(frame) { [self] read in
            if let colors = read?.colors {
                let all = colors.flatMap { $0.prefix(3) }
                streamReadings.append((gamma, all.reduce(0, +) / Float(max(1, all.count))))
            }
            guard last, !streamReadings.isEmpty else { return }
            // Group consecutive frames with identical gamma and log their mean brightness.
            var runs: [(gamma: Float, count: Int, sum: Float)] = []
            for reading in streamReadings {
                if let end = runs.last, end.gamma == reading.gamma {
                    runs[runs.count - 1] = (end.gamma, end.count + 1, end.sum + reading.mean)
                } else {
                    runs.append((reading.gamma, 1, reading.mean))
                }
            }
            log("colors: initial stream frames as sampled: "
                + runs.map { String(format: "%d with gamma %.2f averaging %.3f", $0.count, $0.gamma, $0.sum / Float($0.count)) }.joined(separator: ", then "))
            streamReadings = []
        }
    }

    /// Records the pass for `probeAsked`: the whole picture into `shrinkTarget`, then into `shrinkPixels`.
    /// Returns whether it took the target, in which case no stereo downsample is recorded this frame.
    private func recordProbe(_ sets: inout [Int: VkDescriptorSet?]) -> Bool {
        shrinkLock.lock()
        let asked = probeAsked
        // The target and its readback buffer are shared with the stereo downsample: wait for one in flight.
        let free = shrinkDrawn == nil
        if free { probeAsked = nil }
        shrinkLock.unlock()
        guard let asked, free else { return false }
        do {
            guard supportsDepth, let picture = asked.frame.pictures.first, let color = try view(of: picture, with: commands),
                  let sampling else {
                asked.done(nil)
                return false
            }
            let side = ColorProbe.side
            try readyShrinkTarget(eyeWidth: side / 2, height: side)
            // Two triangles over the whole target, in QuadMesh's vertex layout.
            var corners: [Float] = []
            for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 0), (1, 1), (0, 1)] as [(Float, Float)] {
                corners += [x * 2 - 1, y * 2 - 1, 0, 1, x, y, x, y, 0.5, 0.5, 1]
            }
            try reserve(&shrinkVertices, bytes: corners.count * MemoryLayout<Float>.size, usage: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
            try reserve(&shrinkPixels, bytes: side * side * readbackPixelBytes, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT)
            guard let mapped = shrinkVertices.mapped else {
                asked.done(nil)
                return false
            }
            corners.withUnsafeBytes { mapped.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

            var barrier = VkImageMemoryBarrier()
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
            barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
            barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED
            barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            barrier.srcQueueFamilyIndex = UInt32.max
            barrier.dstQueueFamilyIndex = UInt32.max
            barrier.image = shrinkTarget.image
            barrier.subresourceRange = Vulkan.wholeColor
            vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue,
                                 VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue, 0, 0, nil, 0, nil, 1, &barrier)
            let size = VkExtent2D(width: UInt32(side), height: UInt32(side))
            var clear = VkClearValue(color: VkClearColorValue(float32: (0, 0, 0, 1)))
            var pass = VkRenderPassBeginInfo()
            pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            pass.renderPass = renderPass
            pass.framebuffer = shrinkTarget.framebuffer
            pass.renderArea.extent = size
            pass.clearValueCount = 1
            withUnsafePointer(to: &clear) {
                pass.pClearValues = $0
                vkCmdBeginRenderPass(commands, &pass, VK_SUBPASS_CONTENTS_INLINE)
            }
            vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, sampling.pipeline)
            var vertexHandle = shrinkVertices.handle
            var offset = VkDeviceSize(0)
            vkCmdBindVertexBuffers(commands, 0, 1, &vertexHandle, &offset)
            var style = QuadStyle(feather: 0, hasAlpha: 0, gamma: 1, linearTarget: linearTarget ? 1 : 0, fill: [0, 0, 0, 0], key: nil,
                                  correction: asked.corrected ? colorCorrection : ColorProbe.noCorrection, probe: true)
            vkCmdPushConstants(commands, sampling.layout, VK_SHADER_STAGE_FRAGMENT_BIT.rawValue, 0,
                               UInt32(MemoryLayout<Float>.size * QuadStyle.floats), &style.values)
            let key = 0xFE << 8 | 0xFF
            if sets[key] == nil { sets[key] = try descriptors(sampling, color: color, alpha: color) }
            var set: VkDescriptorSet? = sets[key] ?? nil
            var viewport = VkViewport(x: 0, y: 0, width: Float(side), height: Float(side), minDepth: 0, maxDepth: 1)
            var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: size)
            vkCmdSetViewport(commands, 0, 1, &viewport)
            vkCmdSetScissor(commands, 0, 1, &scissor)
            vkCmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, sampling.layout, 0, 1, &set, 0, nil)
            vkCmdDraw(commands, 6, 1, 0, 0)
            vkCmdEndRenderPass(commands)

            barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT.rawValue
            barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue,
                                 VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, 0, 0, nil, 0, nil, 1, &barrier)
            var region = VkBufferImageCopy()
            region.imageSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0,
                                                               baseArrayLayer: 0, layerCount: 1)
            region.imageExtent = VkExtent3D(width: size.width, height: size.height, depth: 1)
            vkCmdCopyImageToBuffer(commands, shrinkTarget.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, shrinkPixels.handle, 1, &region)
            probeDrawn = (asked.frame, sampling.externalFormat, asked.done)
            return true
        } catch {
            log("vulkan: could not read back color probe frame: \(error)")
            asked.done(nil)
            return false
        }
    }

    /// Extracts the 16 patch colors from the completed `recordProbe` readback buffer.
    private func finishProbe() {
        guard let drawn = probeDrawn else { return }
        probeDrawn = nil
        guard let mapped = shrinkPixels.mapped else {
            drawn.done(nil)
            return
        }
        let side = ColorProbe.side, patch = side / ColorProbe.across
        let bytes = mapped.assumingMemoryBound(to: UInt8.self)
        let blueFirst = targetFormat == VK_FORMAT_B8G8R8A8_SRGB || targetFormat == VK_FORMAT_B8G8R8A8_UNORM
        var colors: [[Float]] = []
        for index in 0..<(ColorProbe.across * ColorProbe.across) {
            // Average the center quarter of each patch to avoid chroma bleed from neighboring patches.
            var sums = [0, 0, 0], count = 0
            let left = (index % ColorProbe.across) * patch + patch * 3 / 8, top = (index / ColorProbe.across) * patch + patch * 3 / 8
            if readsFloats {
                let halves = mapped.assumingMemoryBound(to: UInt16.self)
                var totals: [Float] = [0, 0, 0]
                for row in top..<(top + patch / 4) {
                    for column in left..<(left + patch / 4) {
                        let (red, green, blue) = floatPixel(halves, row * side + column)
                        totals[0] += red; totals[1] += green; totals[2] += blue
                        count += 1
                    }
                }
                colors.append(totals.map { ($0 / Float(count) - 0.25) * 2 })
                continue
            }
            for row in top..<(top + patch / 4) {
                for column in left..<(left + patch / 4) {
                    let at = (row * side + column) * 4
                    for channel in 0..<3 { sums[channel] += Int(bytes[at + (blueFirst ? 2 - channel : channel)]) }
                    count += 1
                }
            }
            // Invert the probe pass's `sampled * 0.5 + 0.25` encoding.
            colors.append(sums.map { (Float($0) / Float(count) / 255 - 0.25) * 2 })
        }
        drawn.done((colors, drawn.format))
    }

    /// Stereo depth estimation and `ColorProbe` read back an offscreen render target matching the swapchain
    /// format (8-bit RGBA/BGRA or 16-bit float).
    public var supportsDepth: Bool { VulkanXRGraphics.formats.contains(targetFormat) || readsFloats }
    private var readsFloats: Bool { targetFormat == VK_FORMAT_R16G16B16A16_SFLOAT }
    /// Bytes per pixel in the offscreen readback buffer.
    private var readbackPixelBytes: Int { readsFloats ? 8 : 4 }

    /// Reads an `R16G16B16A16_SFLOAT` pixel and returns unclamped sRGB-encoded `(R, G, B)` values, applying the
    /// linear-to-sRGB transfer function when the render target stores linear light.
    private func floatPixel(_ halves: UnsafePointer<UInt16>, _ index: Int) -> (Float, Float, Float) {
        VulkanXRGraphics.floatPixel(halves, index, linear: linearTarget)
    }

    private static func floatPixel(_ halves: UnsafePointer<UInt16>, _ index: Int, linear: Bool) -> (Float, Float, Float) {
        func value(_ channel: Int) -> Float {
            let stored = Float(Float16(bitPattern: halves[index * 4 + channel]))
            guard linear else { return stored }
            let size = abs(stored)
            let encoded = size <= 0.0031308 ? size * 12.92 : 1.055 * Float(pow(Double(size), 1 / 2.4)) - 0.055
            return stored < 0 ? -encoded : encoded
        }
        return (value(0), value(1), value(2))
    }

    /// Vulkan downsamples on the GPU via `shrink` and runs stereo matching on the CPU.
    public var measure: StereoDepthEstimator<HardwareFrame>.Measure? { nil }

    public func shrink(_ frame: HardwareFrame, width: Int, done: @escaping (StereoPair?) -> Void) {
        shrinkLock.lock()
        let passedOver = shrinkAsked
        shrinkAsked = (frame, width, done)
        shrinkLock.unlock()
        passedOver?.done(nil)
    }

    private func destroy(_ target: ShrinkTarget) {
        vkDestroyFramebuffer(device, target.framebuffer, nil)
        vkDestroyImageView(device, target.view, nil)
        vkDestroyImage(device, target.image, nil)
        vkFreeMemory(device, target.memory, nil)
    }

    /// Allocates or resizes `shrinkTarget` to `2 * eyeWidth` by `height`. Must be called while the GPU queue is idle.
    private func readyShrinkTarget(eyeWidth: Int, height: Int) throws {
        if shrinkTarget.eyeWidth == eyeWidth, shrinkTarget.height == height, shrinkTarget.framebuffer != nil { return }
        if shrinkTarget.image != nil { destroy(shrinkTarget) }
        var made = ShrinkTarget()
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType = VK_IMAGE_TYPE_2D
        info.format = targetFormat
        info.extent = VkExtent3D(width: UInt32(eyeWidth * 2), height: UInt32(height), depth: 1)
        info.mipLevels = 1
        info.arrayLayers = 1
        info.samples = VK_SAMPLE_COUNT_1_BIT
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        try Vulkan.check(vkCreateImage(device, &info, nil, &made.image), "vkCreateImage(depth)")
        var needs = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, made.image, &needs)
        var memory = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(physical, &memory)
        let types = withUnsafeBytes(of: &memory.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self)) }
        let fitting = (0..<Int(memory.memoryTypeCount)).filter { needs.memoryTypeBits & (1 << UInt32($0)) != 0 }
        let local = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue
        guard let type = fitting.first(where: { types[$0].propertyFlags & local != 0 }) ?? fitting.first else {
            vkDestroyImage(device, made.image, nil)
            throw XRFailure.unsupported("Vulkan memory for stereo depth target")
        }
        var allocate = VkMemoryAllocateInfo()
        allocate.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocate.allocationSize = needs.size
        allocate.memoryTypeIndex = UInt32(type)
        try Vulkan.check(vkAllocateMemory(device, &allocate, nil, &made.memory), "vkAllocateMemory(depth)")
        try Vulkan.check(vkBindImageMemory(device, made.image, made.memory, 0), "vkBindImageMemory(depth)")
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = made.image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = targetFormat
        viewInfo.subresourceRange = Vulkan.wholeColor
        try Vulkan.check(vkCreateImageView(device, &viewInfo, nil, &made.view), "vkCreateImageView(depth)")
        var framebuffer = VkFramebufferCreateInfo()
        framebuffer.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
        framebuffer.renderPass = renderPass
        framebuffer.attachmentCount = 1
        framebuffer.width = UInt32(eyeWidth * 2)
        framebuffer.height = UInt32(height)
        framebuffer.layers = 1
        try withUnsafePointer(to: &made.view) { view in
            framebuffer.pAttachments = view
            try Vulkan.check(vkCreateFramebuffer(device, &framebuffer, nil, &made.framebuffer), "vkCreateFramebuffer(depth)")
        }
        made.eyeWidth = eyeWidth
        made.height = height
        shrinkTarget = made
    }

    /// Records an offscreen pass that renders both eyes of `shrinkAsked` side by side into `shrinkTarget` and
    /// copies the pixels into `shrinkPixels` for CPU readback on the next frame (`finishShrink`).
    private func recordShrink(_ sets: inout [Int: VkDescriptorSet?]) {
        shrinkLock.lock()
        let asked = shrinkAsked
        shrinkAsked = nil
        shrinkLock.unlock()
        guard let asked else { return }
        do {
            guard supportsDepth, let plan = StereoPlan(layout: asked.frame.layout, width: asked.width) else {
                asked.done(nil)
                return
            }
            // Import and acquire decoded buffers before beginning the render pass, since acquisition records a barrier.
            let views = try asked.frame.pictures.map { try view(of: $0, with: commands) }
            guard let sampling else {
                asked.done(nil)
                return
            }
            try readyShrinkTarget(eyeWidth: plan.width, height: plan.height)

            // Emit two triangles per tile using QuadMesh's vertex layout. Iterate tiles in reverse so the
            // lower-resolution base tile draws over the fovea, keeping sharpness matched between both eyes.
            var corners: [Float] = []
            var draws: [(eye: Int, picture: Int, first: Int)] = []
            let across = plan.window.right - plan.window.left, tall = plan.window.up - plan.window.down
            for (eye, view) in asked.frame.layout.views.enumerated() {
                for tile in view.tiles.reversed() {
                    guard views.indices.contains(tile.picture), views[tile.picture] != nil else { continue }
                    var described = AHardwareBuffer_Desc()
                    AHardwareBuffer_describe(asked.frame.pictures[tile.picture].buffer, &described)
                    // Inset UVs by half a texel to prevent bilinear filtering from bleeding across atlas tile borders.
                    let halfU = 0.5 / Float(max(1, described.width)), halfV = 0.5 / Float(max(1, described.height))
                    func corner(_ x: Float, _ y: Float, _ u: Float, _ v: Float) {
                        // Vulkan clip space has +Y pointing down, with row 0 at the top of the image.
                        corners += [(x - plan.window.left) / across * 2 - 1, 1 - (y - plan.window.down) / tall * 2, 0, 1,
                                    u, v, u, v, 0.5, 0.5, 1]
                    }
                    let f = tile.frustum
                    let (left, right, top, bottom) = (tile.left + halfU, tile.right - halfU, tile.top + halfV, tile.bottom - halfV)
                    draws.append((eye, tile.picture, corners.count / QuadMesh.floatsPerVertex))
                    corner(f.left, f.up, left, top); corner(f.right, f.up, right, top); corner(f.left, f.down, left, bottom)
                    corner(f.right, f.up, right, top); corner(f.right, f.down, right, bottom); corner(f.left, f.down, left, bottom)
                }
            }
            guard !draws.isEmpty else {
                asked.done(nil)
                return
            }
            try reserve(&shrinkVertices, bytes: corners.count * MemoryLayout<Float>.size, usage: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
            let bytes = plan.width * 2 * plan.height * readbackPixelBytes
            try reserve(&shrinkPixels, bytes: bytes, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT)
            guard let mapped = shrinkVertices.mapped else {
                asked.done(nil)
                return
            }
            corners.withUnsafeBytes { mapped.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

            var barrier = VkImageMemoryBarrier()
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
            barrier.srcAccessMask = 0
            barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
            barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED       // discard previous contents
            barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            barrier.srcQueueFamilyIndex = UInt32.max            // VK_QUEUE_FAMILY_IGNORED
            barrier.dstQueueFamilyIndex = UInt32.max
            barrier.image = shrinkTarget.image
            barrier.subresourceRange = Vulkan.wholeColor
            vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue,
                                 VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue, 0, 0, nil, 0, nil, 1, &barrier)

            let size = VkExtent2D(width: UInt32(plan.width * 2), height: UInt32(plan.height))
            var clear = VkClearValue(color: VkClearColorValue(float32: (0, 0, 0, 1)))
            var pass = VkRenderPassBeginInfo()
            pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            pass.renderPass = renderPass
            pass.framebuffer = shrinkTarget.framebuffer
            pass.renderArea.extent = size
            pass.clearValueCount = 1
            withUnsafePointer(to: &clear) {
                pass.pClearValues = $0
                vkCmdBeginRenderPass(commands, &pass, VK_SUBPASS_CONTENTS_INLINE)
            }
            vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, sampling.pipeline)
            var vertexHandle = shrinkVertices.handle
            var offset = VkDeviceSize(0)
            vkCmdBindVertexBuffers(commands, 0, 1, &vertexHandle, &offset)
            // Stereo matching only compares left and right luma, so skip gamma decoding and feathering.
            var style = QuadStyle(feather: 0, hasAlpha: 0, gamma: 1, linearTarget: linearTarget ? 1 : 0, fill: [0, 0, 0, 0], key: nil,
                                  correction: correction(for: asked.frame.layout))
            vkCmdPushConstants(commands, sampling.layout, VK_SHADER_STAGE_FRAGMENT_BIT.rawValue, 0,
                               UInt32(MemoryLayout<Float>.size * QuadStyle.floats), &style.values)
            for draw in draws {
                guard let color = views[draw.picture] else { continue }
                let key = draw.picture << 8 | 0xFF
                if sets[key] == nil { sets[key] = try? descriptors(sampling, color: color, alpha: color) }
                var set: VkDescriptorSet? = sets[key] ?? nil
                guard set != nil else { continue }
                var viewport = VkViewport(x: Float(draw.eye * plan.width), y: 0, width: Float(plan.width), height: Float(plan.height),
                                          minDepth: 0, maxDepth: 1)
                var scissor = VkRect2D(offset: VkOffset2D(x: Int32(draw.eye * plan.width), y: 0),
                                       extent: VkExtent2D(width: UInt32(plan.width), height: UInt32(plan.height)))
                vkCmdSetViewport(commands, 0, 1, &viewport)
                vkCmdSetScissor(commands, 0, 1, &scissor)
                vkCmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, sampling.layout, 0, 1, &set, 0, nil)
                vkCmdDraw(commands, 6, 1, UInt32(draw.first), 0)
            }
            vkCmdEndRenderPass(commands)

            barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT.rawValue
            barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue,
                                 VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, 0, 0, nil, 0, nil, 1, &barrier)
            var region = VkBufferImageCopy()
            region.imageSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0,
                                                               baseArrayLayer: 0, layerCount: 1)
            region.imageExtent = VkExtent3D(width: size.width, height: size.height, depth: 1)
            vkCmdCopyImageToBuffer(commands, shrinkTarget.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, shrinkPixels.handle, 1, &region)
            shrinkDrawn = (asked.frame, plan, asked.done)
        } catch {
            if !shrinkComplained {
                shrinkComplained = true
                log("vulkan: stereo depth downsample failed: \(error)")
            }
            asked.done(nil)
        }
    }

    /// Background queue that converts downsampled readback buffers into grayscale `LumaPicture` pairs off the render thread.
    private static let readbackQueue = DispatchQueue(label: "openvrlink.depth.readback", qos: .userInitiated)

    /// Converts the completed `shrinkPixels` readback buffer into a `StereoPair` of Rec. 709 luma images and
    /// invokes its completion handler.
    private func finishShrink() {
        guard let drawn = shrinkDrawn else { return }
        shrinkDrawn = nil
        guard let mapped = shrinkPixels.mapped else {
            drawn.done(nil)
            return
        }
        let width = drawn.plan.width, height = drawn.plan.height
        // Copy the mapped GPU buffer in a single bulk read on the render thread and convert to grayscale on
        // readbackQueue (per-pixel reads from mapped memory on the render thread took ~7 ms per frame on Quest Pro).
        let floats = readsFloats, linear = linearTarget
        let copied = [UInt8](UnsafeRawBufferPointer(start: mapped, count: width * 2 * height * readbackPixelBytes))
        // Compute Rec. 709 luma, swapping R and B weights for BGRA vs RGBA target formats.
        let blueFirst = targetFormat == VK_FORMAT_B8G8R8A8_SRGB || targetFormat == VK_FORMAT_B8G8R8A8_UNORM
        let (first, last) = blueFirst ? (18, 54) : (54, 18)
        VulkanXRGraphics.readbackQueue.async {
            var eyes = [LumaPicture(width: width, height: height), LumaPicture(width: width, height: height)]
            copied.withUnsafeBytes { raw in
                if floats {
                    let halves = raw.bindMemory(to: UInt16.self).baseAddress!
                    for eye in 0..<2 {
                        eyes[eye].pixels.withUnsafeMutableBufferPointer { out in
                            for row in 0..<height {
                                for column in 0..<width {
                                    let (red, green, blue) = VulkanXRGraphics.floatPixel(halves, row * width * 2 + eye * width + column, linear: linear)
                                    out[row * width + column] = UInt8(max(0, min(255, (red * 0.2126 + green * 0.7152 + blue * 0.0722) * 255)))
                                }
                            }
                        }
                    }
                } else {
                    let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
                    for eye in 0..<2 {
                        eyes[eye].pixels.withUnsafeMutableBufferPointer { out in
                            for row in 0..<height {
                                var at = (row * width * 2 + eye * width) * 4
                                for column in 0..<width {
                                    out[row * width + column] = UInt8((Int(bytes[at]) * first + Int(bytes[at + 1]) * 183 + Int(bytes[at + 2]) * last) >> 8)
                                    at += 4
                                }
                            }
                        }
                    }
                }
            }
            drawn.done(drawn.plan.pair(left: eyes[0], right: eyes[1]))
        }
    }

    // MARK: Panel

    private var panelImages: [VkImage?] = []
    private var panelSize = VkExtent2D()
    private var panelSwapsRedAndBlue = false
    private var panelBuffer = Buffer()
    private var panelCommands: VkCommandBuffer?
    private var panelFence: VkFence?

    public func choosePanelFormat(among offered: [Int64]) -> Int64? {
        VulkanXRGraphics.formats.map { Int64($0.rawValue) }.first { offered.contains($0) }
    }

    public func adoptPanel(_ swapchain: XRSwapchain, instance xr: XRInstance) throws {
        let enumerate = try xr.function("xrEnumerateSwapchainImages", as: PFN_xrEnumerateSwapchainImages.self)
        var count: UInt32 = 0
        try XRFailure.check(enumerate(swapchain.handle, 0, &count, nil), "xrEnumerateSwapchainImages")
        var blank = XrSwapchainImageVulkan2KHR()
        blank.type = XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR
        var images = [XrSwapchainImageVulkan2KHR](repeating: blank, count: Int(count))
        try XRFailure.check(images.withUnsafeMutableBytes { all in
            enumerate(swapchain.handle, count, &count, all.baseAddress?.assumingMemoryBound(to: XrSwapchainImageBaseHeader.self))
        }, "xrEnumerateSwapchainImages")
        panelImages = images.map(\.image)
        panelSize = VkExtent2D(width: UInt32(swapchain.width), height: UInt32(swapchain.height))
        let format = VkFormat(rawValue: UInt32(swapchain.format))
        panelSwapsRedAndBlue = format == VK_FORMAT_B8G8R8A8_SRGB || format == VK_FORMAT_B8G8R8A8_UNORM
        var allocate = VkCommandBufferAllocateInfo()
        allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocate.commandPool = pool
        allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocate.commandBufferCount = 1
        try Vulkan.check(vkAllocateCommandBuffers(device, &allocate, &panelCommands), "vkAllocateCommandBuffers")
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        try Vulkan.check(vkCreateFence(device, &fenceInfo, nil, &panelFence), "vkCreateFence")
    }

    public func drawPanel(_ pixels: [UInt8], image: Int) {
        do {
            try copyPanel(pixels, image: image)
        } catch {
            log("vulkan: panel: \(error)")
        }
    }

    /// Uploads the panel RGBA buffer into `image` via a staging buffer and waits on a fence so the swapchain
    /// image can be released and the staging buffer reused on return.
    private func copyPanel(_ pixels: [UInt8], image: Int) throws {
        guard panelImages.indices.contains(image), pixels.count == Int(panelSize.width * panelSize.height) * 4 else { return }
        try reserve(&panelBuffer, bytes: pixels.count, usage: VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
        guard let mapped = panelBuffer.mapped else { return }
        pixels.withUnsafeBytes { mapped.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if panelSwapsRedAndBlue {
            let bytes = mapped.assumingMemoryBound(to: UInt8.self)
            for at in stride(from: 0, to: pixels.count, by: 4) { (bytes[at], bytes[at + 2]) = (bytes[at + 2], bytes[at]) }
        }
        try Vulkan.check(vkResetCommandBuffer(panelCommands, 0), "vkResetCommandBuffer")
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
        try Vulkan.check(vkBeginCommandBuffer(panelCommands, &begin), "vkBeginCommandBuffer")
        // OpenXR acquires and releases swapchain images in VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL.
        var barrier = VkImageMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        barrier.srcAccessMask = 0
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        barrier.srcQueueFamilyIndex = UInt32.max        // VK_QUEUE_FAMILY_IGNORED
        barrier.dstQueueFamilyIndex = UInt32.max
        barrier.image = panelImages[image]
        barrier.subresourceRange = Vulkan.wholeColor
        vkCmdPipelineBarrier(panelCommands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue,
                             0, 0, nil, 0, nil, 1, &barrier)
        var region = VkBufferImageCopy()
        region.imageSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0,
                                                           baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: panelSize.width, height: panelSize.height, depth: 1)
        vkCmdCopyBufferToImage(panelCommands, panelBuffer.handle, panelImages[image], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        vkCmdPipelineBarrier(panelCommands, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue,
                             VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue, 0, 0, nil, 0, nil, 1, &barrier)
        try Vulkan.check(vkEndCommandBuffer(panelCommands), "vkEndCommandBuffer")
        var submit = VkSubmitInfo()
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        submit.commandBufferCount = 1
        try withUnsafePointer(to: &panelCommands) {
            submit.pCommandBuffers = $0
            try Vulkan.check(vkQueueSubmit(queue, 1, &submit, panelFence), "vkQueueSubmit")
        }
        var waiting = panelFence
        vkWaitForFences(device, 1, &waiting, 1, UInt64.max)
        vkResetFences(device, 1, &waiting)
    }

    public func draw(_ eyes: [XREyeDraw], frame: HardwareFrame?, transparent: Bool) {
        do {
            try record(eyes, frame: frame, transparent: transparent)
        } catch {
            log("vulkan: \(error)")
        }
    }

    private func record(_ eyes: [XREyeDraw], frame: HardwareFrame?, transparent: Bool) throws {
        var mark = Uptime.nanoseconds
        var steps: [(name: String, nanoseconds: UInt64)] = []
        func stepDone(_ name: String) {
            let now = Uptime.nanoseconds
            steps.append((name, now &- mark))
            mark = now
        }
        defer { lastDrawSteps = steps }
        // Wait for the previous frame's command buffer to complete before reusing vertex buffers or releasing frames.
        if submitted {
            var waiting = fence
            vkWaitForFences(device, 1, &waiting, 1, UInt64.max)
            vkResetFences(device, 1, &waiting)
            submitted = false
        }
        retired.forEach(destroy)
        retired = []
        stepDone("draw: previous frame fence")
        finishShrink()
        finishProbe()
        stepDone("draw: depth readback")
        drawing = frame
        // Ramp passthrough dimming toward the target opacity for this frame.
        let now = Uptime.nanoseconds, seconds = dimMoved == 0 ? 0 : min(0.25, Float(now &- dimMoved) / 1e9)
        dimMoved = now
        let wanted: Float = frame?.layout.hostKey?.dim == true ? VulkanXRGraphics.dimmedBy : 0
        let step = VulkanXRGraphics.dimmedBy * seconds / (wanted > dimNow ? 0.05 : 0.1)
        dimNow = wanted > dimNow ? min(wanted, dimNow + step) : max(wanted, dimNow - step)
        noteStreamStart(frame)
        frameCount += 1

        try Vulkan.check(vkResetCommandBuffer(commands, 0), "vkResetCommandBuffer")
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
        try Vulkan.check(vkBeginCommandBuffer(commands, &begin), "vkBeginCommandBuffer")

        // Import new hardware buffers before beginning a render pass because queue-family acquisition uses a pipeline barrier.
        var views: [VkImageView?] = []
        if let frame {
            do {
                views = try frame.pictures.map { try view(of: $0, with: commands) }
            } catch {
                log("vulkan: failed to import decoded hardware buffer: \(error)")
                views = []
            }
        }
        if imports.count > VulkanXRGraphics.importsKept {
            for (id, imported) in imports where frameCount - imported.lastUsed > VulkanXRGraphics.importsKept {
                retired.append(imported)
                imports[id] = nil
            }
        }

        stepDone("draw: importing frames")
        let meshes = eyes.map { QuadMesh($0.quads, from: $0.view, yDown: true) }
        stepDone("draw: building meshes")
        let floats = meshes.reduce(0) { $0 + $1.vertices.count }, indexCount = meshes.reduce(0) { $0 + $1.indices.count }
        try reserve(&vertexBuffer, bytes: floats * MemoryLayout<Float>.size, usage: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
        try reserve(&indexBuffer, bytes: indexCount * MemoryLayout<UInt16>.size, usage: VK_BUFFER_USAGE_INDEX_BUFFER_BIT)
        if let sampling { vkResetDescriptorPool(device, sampling.descriptors, 0) }
        var sets: [Int: VkDescriptorSet?] = [:]
        if !recordProbe(&sets) { recordShrink(&sets) }
        stepDone("draw: depth downsample")

        var vertexBase = 0, indexBase = 0
        for (eye, mesh) in zip(eyes, meshes) {
            var size = sizes[eye.eye]
            if let part = eye.size {
                size = VkExtent2D(width: min(size.width, UInt32(max(1, part.width))), height: min(size.height, UInt32(max(1, part.height))))
            }
            var clear = VkClearValue(color: VkClearColorValue(float32: (0, 0, 0, transparent || eye.clear ? 0 : 1)))
            var pass = VkRenderPassBeginInfo()
            pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            pass.renderPass = renderPass
            pass.framebuffer = targets[eye.eye][eye.image].framebuffer
            pass.renderArea.extent = size
            pass.clearValueCount = 1
            withUnsafePointer(to: &clear) {
                pass.pClearValues = $0
                vkCmdBeginRenderPass(commands, &pass, VK_SUBPASS_CONTENTS_INLINE)
            }
            defer { vkCmdEndRenderPass(commands) }
            guard let sampling, !mesh.draws.isEmpty, let vertices = vertexBuffer.mapped, let indices = indexBuffer.mapped else { continue }

            mesh.vertices.withUnsafeBytes { (vertices + vertexBase * MemoryLayout<Float>.size).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            mesh.indices.withUnsafeBytes { (indices + indexBase * MemoryLayout<UInt16>.size).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            var viewport = VkViewport(x: 0, y: 0, width: Float(size.width), height: Float(size.height), minDepth: 0, maxDepth: 1)
            var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: size)
            vkCmdSetViewport(commands, 0, 1, &viewport)
            vkCmdSetScissor(commands, 0, 1, &scissor)
            let keying = sampling.keyedPipeline == nil || frame?.layout.hostKey != nil ? nil : chromaKey
            vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, keying == nil ? sampling.pipeline : sampling.keyedPipeline)
            var vertexHandle = vertexBuffer.handle
            var offset = VkDeviceSize(vertexBase * MemoryLayout<Float>.size)
            vkCmdBindVertexBuffers(commands, 0, 1, &vertexHandle, &offset)
            vkCmdBindIndexBuffer(commands, indexBuffer.handle, VkDeviceSize(indexBase * MemoryLayout<UInt16>.size), VK_INDEX_TYPE_UINT16)

            // Host chroma keying overrides the client's chroma key for this frame.
            let hostKey = frame?.layout.hostKey
            for draw in mesh.draws {
                let filled = draw.fill != nil
                var size = (width: 1, height: 1)
                if hostKey != nil, let pictures = frame?.pictures, pictures.indices.contains(draw.picture) {
                    var described = AHardwareBuffer_Desc()
                    AHardwareBuffer_describe(pictures[draw.picture].buffer, &described)
                    size = (Int(described.width), Int(described.height))
                }
                guard filled || (views.indices.contains(draw.picture) && views[draw.picture] != nil) else { continue }
                // Solid-fill quads do not sample textures, but the descriptor layout still requires valid image views.
                let color = views.indices.contains(draw.picture) ? views[draw.picture] : views.first ?? nil
                guard let color else { continue }
                let alpha = draw.alphaPicture.flatMap { views.indices.contains($0) ? views[$0] : nil }
                let key = draw.picture << 8 | (draw.alphaPicture ?? 0xFF)
                if sets[key] == nil { sets[key] = try descriptors(sampling, color: color, alpha: alpha ?? color) }
                var set = sets[key] ?? nil
                vkCmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, sampling.layout, 0, 1, &set, 0, nil)
                var style = QuadStyle(feather: draw.feather, hasAlpha: alpha != nil && !filled ? 1 : 0, gamma: frame?.layout.encodingGamma ?? 1,
                                      linearTarget: linearTarget ? 1 : 0, fill: draw.fill ?? [0, 0, 0, 0], key: keying,
                                      correction: correction(for: frame?.layout), hostKey: hostKey.map { ($0, size.width, size.height) },
                                      dim: dimNow, covered: draw.covered)
                vkCmdPushConstants(commands, sampling.layout, VK_SHADER_STAGE_FRAGMENT_BIT.rawValue, 0,
                                   UInt32(MemoryLayout<Float>.size * QuadStyle.floats), &style.values)
                vkCmdDrawIndexed(commands, UInt32(draw.indexCount), 1, UInt32(draw.firstIndex), Int32(draw.firstVertex), 0)
            }
            vertexBase += mesh.vertices.count
            indexBase += mesh.indices.count
        }

        releasePictures()
        try Vulkan.check(vkEndCommandBuffer(commands), "vkEndCommandBuffer")
        var submit = VkSubmitInfo()
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        submit.commandBufferCount = 1
        try withUnsafePointer(to: &commands) {
            submit.pCommandBuffers = $0
            stepDone("draw: eye passes")
            try Vulkan.check(vkQueueSubmit(queue, 1, &submit, fence), "vkQueueSubmit")
        }
        stepDone("draw: queue submit")
        submitted = true
        lastGPUWait = 0
        if quirks.waitForGPU {
            // Wait for rendering to finish before the caller releases the swapchain images to the OpenXR runtime.
            var waiting = fence
            let began = Uptime.nanoseconds
            vkWaitForFences(device, 1, &waiting, 1, UInt64.max)
            lastGPUWait = Uptime.nanoseconds - began
        }
    }

    private func descriptors(_ sampling: Sampling, color: VkImageView, alpha: VkImageView) throws -> VkDescriptorSet? {
        var set: VkDescriptorSet?
        var layout = sampling.setLayout
        var allocate = VkDescriptorSetAllocateInfo()
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
        allocate.descriptorPool = sampling.descriptors
        allocate.descriptorSetCount = 1
        try withUnsafePointer(to: &layout) {
            allocate.pSetLayouts = $0
            try Vulkan.check(vkAllocateDescriptorSets(device, &allocate, &set), "vkAllocateDescriptorSets")
        }
        var images = [color, alpha].map {
            VkDescriptorImageInfo(sampler: nil, imageView: $0, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
        }
        images.withUnsafeMutableBufferPointer { images in
            var writes = [VkWriteDescriptorSet](repeating: VkWriteDescriptorSet(), count: 2)
            for index in 0..<2 {
                writes[index].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                writes[index].dstSet = set
                writes[index].dstBinding = UInt32(index)
                writes[index].descriptorCount = 1
                writes[index].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                writes[index].pImageInfo = UnsafePointer(images.baseAddress! + index)
            }
            vkUpdateDescriptorSets(device, 2, &writes, 0, nil)
        }
        return set
    }
}

/// Push-constant block matching `Style` in `quad.frag` (keep layout synchronized with the shader).
private struct QuadStyle {
    static let floats = 32
    var values: [Float]

    /// - Parameters:
    ///   - correction: Row-major 3x4 color correction matrix (`ColorProbe.Treatment.correction`).
    ///   - probe: Encode unclamped sampled colors for `ColorProbe` readback instead of normal rendering.
    ///   - hostKey: Host chroma key and texture dimensions in texels. Overrides `key` and reuses `fill.xy`
    ///     when `fill.a == 0`.
    ///   - dim: Passthrough dimming opacity behind a host-keyed frame (`0...1`).
    ///   - covered: Normalized bounds and feather width of an overlapping feathered quad (`Quad.covered`).
    ///   - opacity: Overall stream opacity (`0...1`).
    init(feather: Float, hasAlpha: Float, gamma: Float, linearTarget: Float, fill: [Float], key: ChromaKey?, correction: [Float],
         probe: Bool = false, hostKey: (key: FrameLayout.HostKey, width: Int, height: Int)? = nil, dim: Float = 0,
         covered: (left: Float, top: Float, right: Float, bottom: Float, feather: Float)? = nil, opacity: Float = 1) {
        var fill = fill, keyed = key.map { $0.color + [1, $0.near, $0.far] } ?? [0, 0, 0, 0, 0, 0]
        var cover: [Float] = [0, 0, 0, 0]
        if let hostKey, fill[3] == 0 {
            fill = [Float(hostKey.width), Float(hostKey.height), covered?.feather ?? 0, 0]
            // Use `vrlink`'s default threshold (0.04) when the host specifies 0.
            keyed = hostKey.key.rgb + [2, hostKey.key.noiseFloor > 0 ? hostKey.key.noiseFloor : 0.04, dim]
            if let covered { cover = [covered.left, covered.top, covered.right, covered.bottom] }
        }
        values = [feather, hasAlpha, gamma, linearTarget] + fill + keyed
            + [probe ? 1 : 0, opacity] + correction + cover
    }
}

/// Bump-style temporary allocator that keeps C structs and strings alive across synchronous Vulkan calls.
final class Arena {
    private var blocks: [UnsafeMutableRawPointer] = []

    func keep<Value>(_ value: Value) -> UnsafeMutablePointer<Value> {
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        pointer.initialize(to: value)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return pointer
    }

    func keep<Value>(_ values: [Value]) -> UnsafeMutablePointer<Value> {
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: max(values.count, 1))
        pointer.initialize(from: values, count: values.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return pointer
    }

    func keep(cString text: String) -> UnsafePointer<CChar>? {
        guard let copy = strdup(text) else { return nil }
        blocks.append(UnsafeMutableRawPointer(copy))
        return UnsafePointer(copy)
    }

    /// Deallocates all raw buffers (used only for trivial C structs and `strdup` strings).
    func free() {
        blocks.forEach { $0.deallocate() }
        blocks = []
    }
}

enum Vulkan {
    struct Failure: Error, CustomStringConvertible {
        var call: String
        var result: VkResult
        var description: String { "\(call) failed with VkResult \(result.rawValue)" }
    }

    static func check(_ result: VkResult, _ call: String) throws {
        guard result.rawValue >= 0 else { throw Failure(call: call, result: result) }
    }

    /// `VK_MAKE_API_VERSION(0, major, minor, 0)`.
    static func version(_ major: UInt32, _ minor: UInt32) -> UInt32 { major << 22 | minor << 12 }

    /// `VK_QUEUE_FAMILY_FOREIGN_EXT` queue family index for external hardware-buffer ownership transfers.
    static let foreignQueueFamily = UInt32.max - 2
    /// `VK_WHOLE_SIZE`.
    static let wholeSize = UInt64.max

    static let wholeColor = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0, levelCount: 1,
                                                    baseArrayLayer: 0, layerCount: 1)
}
#endif
