// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Vulkan fragment shader for VulkanXRGraphics, matching VRLinkMetal's Quad.metal. Compiled twice: once for
// standard alpha blending and once with -DKEYED for chroma keying via dual-source blending.
//
// Both textures use an immutable VkSamplerYcbcrConversion sampler. Sampled values are transformed by
// style.fix0..fix2 (ColorProbe.Treatment.correction) to restore full-range BT.2020 gamma-encoded RGB.
#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec2 alphaUV;
layout(location = 2) in vec2 tile;
layout(location = 3) in float ahead;

#ifdef KEYED
layout(location = 0, index = 0) out vec4 color;
layout(location = 0, index = 1) out vec4 cover;
#else
layout(location = 0) out vec4 color;
#endif

layout(set = 0, binding = 0) uniform sampler2D picture;
layout(set = 0, binding = 1) uniform sampler2D alphaPicture;

// feather: edge feather width as a fraction of quad size.
// hasAlpha: non-zero when alphaPicture provides a separate alpha plane.
// gamma: FrameLayout.encodingGamma (1.0 leaves values unchanged).
// linearTarget: non-zero when rendering to an sRGB attachment that expects linear-light output.
// fill: solid RGBA color used instead of texture sampling when fill.a > 0.
// keyColor: gamma-encoded chroma-key target color; keyRange: (near, far) HSV distance thresholds
// (see Settings.chromaKeyNear). Used only when compiled with KEYED.
layout(push_constant) uniform Style {
    float feather;
    float hasAlpha;
    float gamma;
    float linearTarget;
    vec4 fill;
    vec4 keyColor;
    vec2 keyRange;
    // Non-zero during ColorProbe readback to encode unclamped values as sampled * 0.5 + 0.25 within an 8-bit target.
    float probe;
    float unused;
    // Row-major 3x4 affine matrix applied to (r, g, b, 1) to invert unwanted Y'CbCr sampler range expansion or
    // matrix conversions.
    vec4 fix0;
    vec4 fix1;
    vec4 fix2;
} style;

vec3 corrected(vec3 raw) {
    vec4 from = vec4(raw, 1.0);
    return vec3(dot(style.fix0, from), dot(style.fix1, from), dot(style.fix2, from));
}

vec3 linearFromSRGB(vec3 encoded) {
    return mix(encoded / 12.92, pow((encoded + 0.055) / 1.055, vec3(2.4)), greaterThan(encoded, vec3(0.04045)));
}

#ifdef KEYED
// HSV chroma-keying functions matching Quad.metal (adapted from the ALVR visionOS client).
// Returns 0 within tol.x of keyHSV, 1 beyond tol.y, and a linear ramp in between.
float colorCloseHSV(vec3 hsv, vec3 keyHSV, vec2 tol) {
    // Saturation or value too low, don't consider it at all.
    if (hsv.b < 0.001 || hsv.g < 0.001) {
        return 1.0;
    }
    float distance = length(vec3(4.0, 1.0, 2.0) * (keyHSV - hsv));
    if (distance < tol.x) {
        return 0.0;
    } else if (distance < tol.y) {
        return (distance - tol.x) / (tol.y - tol.x);
    }
    return 1.0;
}

vec3 hsvFromRGB(vec3 rgb) {
    float most = max(rgb.r, max(rgb.g, rgb.b));
    float least = min(rgb.r, min(rgb.g, rgb.b));
    float delta = most - least;
    vec3 hsv = vec3(0.0, 0.0, most);
    if (most > least) {
        hsv.y = delta / most;
        if (rgb.r == most) {
            hsv.x = (rgb.g - rgb.b) / delta;
        } else if (rgb.g == most) {
            hsv.x = 2.0 + (rgb.b - rgb.r) / delta;
        } else {
            hsv.x = 4.0 + (rgb.r - rgb.g) / delta;
        }
        hsv.x = fract(hsv.x / 6.0);
    }
    return hsv;
}
#endif

void main() {
    if (style.fill.a > 0.0) {
        color = vec4(style.fill.rgb * style.fill.a, style.fill.a);
#ifdef KEYED
        cover = vec4(style.fill.a);
#endif
        return;
    }
    vec3 sampled = corrected(texture(picture, uv / ahead).rgb);
    if (style.probe != 0.0) {
        vec3 kept = clamp(sampled * 0.5 + 0.25, 0.0, 1.0);
        color = vec4(style.linearTarget != 0.0 ? linearFromSRGB(kept) : kept, 1.0);
#ifdef KEYED
        cover = vec4(1.0);
#endif
        return;
    }
    sampled = clamp(sampled, 0.0, 1.0);
    // Invert the host's v^(1/gamma) transfer adjustment used to preserve shadow detail.
    if (style.gamma > 1.0) {
        sampled = pow(sampled, vec3(style.gamma));
    }
    // Evaluate the chroma key in gamma-encoded RGB space before converting to linear light.
    float kept = 1.0;
#ifdef KEYED
    kept = colorCloseHSV(hsvFromRGB(sampled), hsvFromRGB(style.keyColor.rgb), style.keyRange);
    if (kept <= 0.0) {
        discard;                                 // fully keyed out; leave passthrough visible
    }
    sampled = max(sampled * kept - style.keyColor.rgb * (1.0 - kept), vec3(0.0));
#endif
    if (style.linearTarget != 0.0) {
        sampled = linearFromSRGB(sampled);
    }
    // Separate alpha streams encode opacity in the red/luma channel with premultiplied RGB in `picture`.
    float opacity = 1.0;
    if (style.hasAlpha != 0.0) {
        opacity = corrected(texture(alphaPicture, alphaUV / ahead).rgb).g;
        if (opacity < 0.02) {
            discard;
        }
    }
    // Feather foveated inset edges into the background quad using premultiplied alpha blending.
    vec2 within = tile / ahead;
    float toEdge = min(min(within.x, 1.0 - within.x), min(within.y, 1.0 - within.y));
    float feather = style.feather > 0.0 ? clamp(toEdge / style.feather, 0.0, 1.0) : 1.0;
#ifdef KEYED
    // Match Quad.metal's dual-source blend: scale color and alpha by the feather weight while
    // preserving the underlying tile across feathered fovea edges.
    color = vec4(sampled * kept, kept * kept * opacity) * feather;
    cover = vec4(feather * opacity);
#else
    color = vec4(sampled, opacity) * feather;
#endif
}
