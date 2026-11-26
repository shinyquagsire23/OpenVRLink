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
// fill: solid RGBA color used instead of texture sampling when fill.a > 0. When host chroma keying is active
// (keyColor.a == 2) and fill.a == 0, fill.xy holds the texture dimensions in texels.
// keyColor.a: 1 for client HSV chroma keying (KEYED builds), or 2 for SteamVR host chroma keying (hostKeyed),
// where keyColor.rgb holds the key color (0 or 1 per channel) and keyRange holds (noiseFloor, dimOpacity).
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
    // Overall stream opacity in 0...1 applied to textured quads.
    float opacity;
    // Row-major 3x4 affine matrix applied to (r, g, b, 1) to invert unwanted Y'CbCr sampler range expansion or
    // matrix conversions.
    vec4 fix0;
    vec4 fix1;
    vec4 fix2;
    // Normalized bounds (left, top, right, bottom) of an overlapping feathered quad when host chroma keying is
    // active (all zero when uncovered); that quad's feather width is stored in fill.z.
    vec4 coveredRect;
} style;

vec3 corrected(vec3 raw) {
    vec4 from = vec4(raw, 1.0);
    return vec3(dot(style.fix0, from), dot(style.fix1, from), dot(style.fix2, from));
}

vec3 linearFromSRGB(vec3 encoded) {
    return mix(encoded / 12.92, pow((encoded + 0.055) / 1.055, vec3(2.4)), greaterThan(encoded, vec3(0.04045)));
}

vec3 srgbFromLinear(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(abs(c), vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// Host chroma-key shader ported from libvrlink_scene.so (the vChromaKeyColor fragment shader). Makes the
// host's key color transparent, despills blended edge pixels, and samples 2x2 chroma blocks to distinguish
// edges against the key from similarly colored scene content.

// Key fractions at or above this threshold are treated as fully transparent.
const float hostKeyFull = 0.85;

// Samples the texture and reconstructs BT.709 Y'CbCr alongside gamma-decoded sRGB.
void hostKeyTap(vec2 st, out vec3 yCbCr, out vec3 rgbGamma) {
    vec3 rgb = corrected(texture(picture, st).rgb);
    float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    yCbCr = vec3(y, (rgb.b - y) / 1.8556 + 128.0 / 255.0, (rgb.r - y) / 1.5748 + 128.0 / 255.0);
    // Encoding gamma leaves primary and secondary key colors (0 or 1 per channel) unchanged.
    rgbGamma = style.gamma > 1.0 ? pow(clamp(rgb, 0.0, 1.0), vec3(style.gamma)) : rgb;
}

vec3 hostKeyYCbCr() {
    vec3 k = style.keyColor.rgb;
    float y = dot(k, vec3(0.2126, 0.7152, 0.0722));
    return vec3(y, (k.b - y) / 1.8556 + 128.0 / 255.0, (k.r - y) / 1.5748 + 128.0 / 255.0);
}

float hostKeyFraction(vec3 cLinear, vec3 kLinear) {
    vec3 onMask = step(0.5, kLinear);
    vec3 onRatio = mix(vec3(1.0), cLinear / max(kLinear, 0.001), onMask);
    vec3 offValue = cLinear * (1.0 - onMask);
    return clamp(min(onRatio.r, min(onRatio.g, onRatio.b)) - max(offValue.r, max(offValue.g, offValue.b)), 0.0, 1.0);
}

float hostKeyShare(vec2 cbCr, vec2 keyCbCr) {
    vec2 key = keyCbCr - 0.5;
    return clamp(dot(cbCr - 0.5, key) / max(dot(key, key), 0.001), 0.0, 1.0);
}

float hostKeyShareAt(vec2 st, vec3 keyYCbCr) {
    vec3 yCbCr, rgbGamma;
    hostKeyTap(st, yCbCr, rgbGamma);
    return hostKeyShare(yCbCr.yz, keyYCbCr.yz);
}

float hostKeyExcess(vec3 cGamma, vec3 kLinear) {
    vec3 onMask = step(0.5, kLinear);
    vec3 onLevel = mix(vec3(1.0), cGamma, onMask);
    vec3 offLevel = cGamma * (1.0 - onMask);
    float onGamma = min(onLevel.r, min(onLevel.g, onLevel.b));
    float offLinear = linearFromSRGB(vec3(max(offLevel.r, max(offLevel.g, offLevel.b)))).x;
    return onGamma - srgbFromLinear(vec3(min(offLinear + 0.5 * style.keyRange.x, 1.0))).x;
}

// Returns rgb premultiplied in linear light, and alpha.
vec4 hostKeyUnmix(vec3 cLinear, vec3 kLinear, float keyFraction, float bleed, float cameraSide) {
    float noise = style.keyRange.x;
    float rampStart = min(1.5 * noise, hostKeyFull - 0.1);
    float rampOpacity = 1.0 - clamp((keyFraction - rampStart) / max(hostKeyFull - rampStart, 0.001), 0.0, 1.0);
    float a = mix(rampOpacity, 1.0 - keyFraction, cameraSide);
    float allowance = keyFraction * (1.0 - smoothstep(noise, rampStart, keyFraction));
    float contentKeyness = allowance * (1.0 - bleed) * (1.0 - cameraSide);
    vec3 premulLinear = max(cLinear - kLinear * max(keyFraction - contentKeyness, 0.0), 0.0);
    vec3 s = clamp(premulLinear / mix(max(a, 0.001), 1.0, cameraSide), 0.0, 1.0);
    return vec4(s * a, a);
}

// Returns rgb premultiplied in linear light, and alpha.
vec4 hostKeyed(vec2 st) {
    vec3 yCbCr, rgbGamma;
    hostKeyTap(st, yCbCr, rgbGamma);

    vec3 k = style.keyColor.rgb;
    vec3 onMask = step(0.5, k);
    vec3 on = mix(vec3(1.0), rgbGamma, onMask);
    vec3 off = rgbGamma * (1.0 - onMask);
    vec3 c = linearFromSRGB(clamp(rgbGamma, 0.0, 1.0));
    if (min(on.r, min(on.g, on.b)) - max(off.r, max(off.g, off.b)) <= 1.5 / 255.0) {
        return vec4(c, 1.0);
    }

    float keyFraction = hostKeyFraction(c, k);
    if (keyFraction >= hostKeyFull) {
        return vec4(0.0);
    }

    // Sample the current 2x2 chroma block and the neighboring block on the opposite side in X and Y.
    vec2 size = style.fill.xy;
    vec2 texel = st * size;
    vec2 part = fract((texel - 1.0) * 0.5);
    vec2 lower = step(part, vec2(0.5));
    vec2 own = texel - 2.0 * part + 2.0 * (1.0 - lower);
    vec2 far = texel - 2.0 * part + 2.0 * lower;
    vec3 keyYCbCr = hostKeyYCbCr();
    vec3 ownYCbCr, ownGamma, farXYCbCr, farXGamma, farYYCbCr, farYGamma;
    hostKeyTap(own / size, ownYCbCr, ownGamma);
    hostKeyTap(vec2(far.x, texel.y) / size, farXYCbCr, farXGamma);
    hostKeyTap(vec2(texel.x, far.y) / size, farYYCbCr, farYGamma);
    float ownShare = hostKeyShare(ownYCbCr.yz, keyYCbCr.yz);
    float farShare = max(hostKeyShare(farXYCbCr.yz, keyYCbCr.yz), hostKeyShare(farYYCbCr.yz, keyYCbCr.yz));

    float blockHoldsKey = clamp((ownShare - 0.15) / 0.1, 0.0, 1.0);
    float cameraSide = blockHoldsKey * clamp((max(ownShare, farShare) - 0.75) / 0.25, 0.0, 1.0);

    float keyBeside = clamp((max(ownShare, farShare) - 0.7) / 0.2, 0.0, 1.0);
    float keyTexel = keyBeside * (1.0 - smoothstep(0.03, 0.1, abs(yCbCr.x - keyYCbCr.x)));

    float keyBeyondBlock = 0.0;
    if (ownShare > 0.15) {
        vec2 beyond = 2.0 * own - far;
        float beyondShare = max(hostKeyShareAt(vec2(beyond.x, texel.y) / size, keyYCbCr),
                                hostKeyShareAt(vec2(texel.x, beyond.y) / size, keyYCbCr));
        keyBeyondBlock = blockHoldsKey * clamp((beyondShare - 0.7) / 0.2, 0.0, 1.0);
    }

    float excess = max(hostKeyExcess(ownGamma, k), max(hostKeyExcess(farXGamma, k), hostKeyExcess(farYGamma, k)));
    float bleed = max(clamp((excess - 0.18) / 0.1, 0.0, 1.0), keyBeyondBlock);

    return hostKeyUnmix(c, k, keyFraction, bleed, cameraSide) * (1.0 - keyTexel);
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
    vec2 within = tile / ahead;
    float toEdge = min(min(within.x, 1.0 - within.x), min(within.y, 1.0 - within.y));
    float feather = style.feather > 0.0 ? clamp(toEdge / style.feather, 0.0, 1.0) : 1.0;
    if (style.keyColor.a > 1.5) {
        vec4 keyed = hostKeyed(uv / ahead);
        // Dim passthrough behind the scene by blending toward premultiplied black (raising alpha while keeping RGB unchanged).
        float a = keyed.a + style.keyRange.y * (1.0 - keyed.a);
        // Where a feathered foveal quad with alpha a * c will be blended over this base quad using standard
        // premultiplied "over" blending, choose `under` so the combined alpha equals `a`:
        // a * c + (1 - a * c) * under = a  =>  under = a * (1 - c) / (1 - a * c).
        float under = a;
        vec2 span = style.coveredRect.zw - style.coveredRect.xy;
        if (span.x > 0.0 && span.y > 0.0) {
            vec2 p = (within - style.coveredRect.xy) / span;
            float edge = min(min(p.x, 1.0 - p.x), min(p.y, 1.0 - p.y));
            float c = edge <= 0.0 ? 0.0 : (style.fill.z > 0.0 ? clamp(edge / style.fill.z, 0.0, 1.0) : 1.0);
            under = clamp(a * (1.0 - c) / max(1.0 - a * c, 0.0001), 0.0, 1.0);
        }
        vec3 shown = style.linearTarget != 0.0 ? keyed.rgb : srgbFromLinear(keyed.rgb);
        color = vec4(shown * (under / max(a, 0.0001)), under) * feather * style.opacity;
#ifdef KEYED
        cover = vec4(under * feather * style.opacity);
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
#ifdef KEYED
    // Match Quad.metal's dual-source blend: scale color and alpha by the feather weight while
    // preserving the underlying tile across feathered fovea edges.
    color = vec4(sampled * kept, kept * kept * opacity) * feather * style.opacity;
    cover = vec4(feather * opacity * style.opacity);
#else
    color = vec4(sampled, opacity) * feather * style.opacity;
#endif
}
