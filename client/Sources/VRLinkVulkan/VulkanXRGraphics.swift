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
/// All methods on `VulkanXRGraphics` run on the OpenXR render thread. Chroma keying (which requires Vulkan
/// dual-source blending) and depth-layer submission are not implemented yet.
public final class VulkanXRGraphics: XRGraphics {
    public typealias Frame = HardwareFrame

    public static let extensions = ["XR_KHR_vulkan_enable2"]

    /// Stored to conform to `XRGraphics`; chroma keying is not implemented in the Vulkan shader yet.
    public var chromaKey: ChromaKey?

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
    private var linearTarget = false
    /// Per-eye Vulkan image views and framebuffers for the OpenXR swapchains.
    private var targets: [[Target]] = []
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
        var descriptors: VkDescriptorPool?
    }
    private var sampling: Sampling?

    /// Cached `VkImage`, device memory, and `VkImageView` for an imported `AHardwareBuffer`.
    private struct Imported {
        var image: VkImage?
        var memory: VkDeviceMemory?
        var view: VkImageView?
        var lastUsed: Int
    }
    /// Imported Vulkan images keyed by `AHardwareBuffer_getId` across the decoder's buffer pool.
    private var imports: [UInt64: Imported] = [:]
    private var retired: [Imported] = []
    private var frameCount = 0
    /// Retains the frame currently in flight on the GPU so its `AHardwareBuffer`s are not recycled prematurely.
    private var drawing: HardwareFrame?
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
        var deviceInfo = VkDeviceCreateInfo()
        deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
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

        made.pipeline = try makePipeline(layout: made.layout)
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

    private func makePipeline(layout: VkPipelineLayout?) throws -> VkPipeline? {
        let arena = Arena()
        defer { arena.free() }
        let vertex = try shader(QuadShaders.vertex), fragment = try shader(QuadShaders.fragment)
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
        blend.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        blend.colorBlendOp = VK_BLEND_OP_ADD
        blend.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
        blend.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
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
        if imports[id] != nil {
            imports[id]?.lastUsed = frameCount
            return imports[id]?.view
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
        imports[id] = imported
        return imported.view
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
        // Wait for the previous frame's command buffer to complete before reusing vertex buffers or releasing frames.
        if submitted {
            var waiting = fence
            vkWaitForFences(device, 1, &waiting, 1, UInt64.max)
            vkResetFences(device, 1, &waiting)
            submitted = false
        }
        retired.forEach(destroy)
        retired = []
        drawing = frame
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

        let meshes = eyes.map { QuadMesh($0.quads, from: $0.view, yDown: true) }
        let floats = meshes.reduce(0) { $0 + $1.vertices.count }, indexCount = meshes.reduce(0) { $0 + $1.indices.count }
        try reserve(&vertexBuffer, bytes: floats * MemoryLayout<Float>.size, usage: VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
        try reserve(&indexBuffer, bytes: indexCount * MemoryLayout<UInt16>.size, usage: VK_BUFFER_USAGE_INDEX_BUFFER_BIT)
        if let sampling { vkResetDescriptorPool(device, sampling.descriptors, 0) }
        var sets: [Int: VkDescriptorSet?] = [:]

        var vertexBase = 0, indexBase = 0
        for (eye, mesh) in zip(eyes, meshes) {
            let size = sizes[eye.eye]
            var clear = VkClearValue(color: VkClearColorValue(float32: (0, 0, 0, transparent ? 0 : 1)))
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
            vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, sampling.pipeline)
            var vertexHandle = vertexBuffer.handle
            var offset = VkDeviceSize(vertexBase * MemoryLayout<Float>.size)
            vkCmdBindVertexBuffers(commands, 0, 1, &vertexHandle, &offset)
            vkCmdBindIndexBuffer(commands, indexBuffer.handle, VkDeviceSize(indexBase * MemoryLayout<UInt16>.size), VK_INDEX_TYPE_UINT16)

            for draw in mesh.draws {
                let filled = draw.fill != nil
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
                                      linearTarget: linearTarget ? 1 : 0, fill: draw.fill ?? [0, 0, 0, 0])
                vkCmdPushConstants(commands, sampling.layout, VK_SHADER_STAGE_FRAGMENT_BIT.rawValue, 0,
                                   UInt32(MemoryLayout<Float>.size * QuadStyle.floats), &style.values)
                vkCmdDrawIndexed(commands, UInt32(draw.indexCount), 1, UInt32(draw.firstIndex), Int32(draw.firstVertex), 0)
            }
            vertexBase += mesh.vertices.count
            indexBase += mesh.indices.count
        }

        try Vulkan.check(vkEndCommandBuffer(commands), "vkEndCommandBuffer")
        var submit = VkSubmitInfo()
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        submit.commandBufferCount = 1
        try withUnsafePointer(to: &commands) {
            submit.pCommandBuffers = $0
            try Vulkan.check(vkQueueSubmit(queue, 1, &submit, fence), "vkQueueSubmit")
        }
        submitted = true
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
    static let floats = 8
    var values: [Float]

    init(feather: Float, hasAlpha: Float, gamma: Float, linearTarget: Float, fill: [Float]) {
        values = [feather, hasAlpha, gamma, linearTarget] + fill
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
