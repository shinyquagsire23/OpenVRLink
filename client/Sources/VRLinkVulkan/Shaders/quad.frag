// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Vulkan fragment shader for VulkanXRGraphics, matching VRLinkMetal's Quad.metal (without chroma keying,
// which requires dual-source blending).
//
// Both textures use an immutable VkSamplerYcbcrConversion sampler, producing gamma-encoded RGB values.
#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec2 alphaUV;
layout(location = 2) in vec2 tile;
layout(location = 3) in float ahead;

layout(location = 0) out vec4 color;

layout(set = 0, binding = 0) uniform sampler2D picture;
layout(set = 0, binding = 1) uniform sampler2D alphaPicture;

// feather: edge feather width as a fraction of quad size.
// hasAlpha: non-zero when alphaPicture provides a separate alpha plane.
// gamma: FrameLayout.encodingGamma (1.0 leaves values unchanged).
// linearTarget: non-zero when rendering to an sRGB attachment that expects linear-light output.
// fill: solid RGBA color used instead of texture sampling when fill.a > 0.
layout(push_constant) uniform Style {
    float feather;
    float hasAlpha;
    float gamma;
    float linearTarget;
    vec4 fill;
} style;

vec3 linearFromSRGB(vec3 encoded) {
    return mix(encoded / 12.92, pow((encoded + 0.055) / 1.055, vec3(2.4)), greaterThan(encoded, vec3(0.04045)));
}

void main() {
    if (style.fill.a > 0.0) {
        color = vec4(style.fill.rgb * style.fill.a, style.fill.a);
        return;
    }
    vec3 sampled = clamp(texture(picture, uv / ahead).rgb, 0.0, 1.0);
    // Invert the host's v^(1/gamma) transfer adjustment used to preserve shadow detail.
    if (style.gamma > 1.0) {
        sampled = pow(sampled, vec3(style.gamma));
    }
    if (style.linearTarget != 0.0) {
        sampled = linearFromSRGB(sampled);
    }
    // Separate alpha streams encode opacity in the red/luma channel with premultiplied RGB in `picture`.
    float opacity = 1.0;
    if (style.hasAlpha != 0.0) {
        opacity = texture(alphaPicture, alphaUV / ahead).r;
        if (opacity < 0.02) {
            discard;
        }
    }
    // Feather foveated inset edges into the background quad using premultiplied alpha blending.
    vec2 within = tile / ahead;
    float toEdge = min(min(within.x, 1.0 - within.x), min(within.y, 1.0 - within.y));
    float feather = style.feather > 0.0 ? clamp(toEdge / style.feather, 0.0, 1.0) : 1.0;
    color = vec4(sampled, opacity) * feather;
}
