// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Vulkan fragment shader for VulkanXRGraphics, matching VRLinkMetal's Quad.metal. Compiled in three variants so
// each pipeline includes only the code needed for its keying mode: standard alpha blending, -DKEYED for client
// chroma keying via dual-source blending, and -DHOST for SteamVR host chroma keying.
//
// Both textures use an immutable VkSamplerYcbcrConversion sampler. Sampled values are transformed by
// style.fix0..fix2 (ColorProbe.Treatment.correction) to restore full-range BT.2020 gamma-encoded RGB.
#version 450

// Color math uses mediump (16-bit float), which is sufficient for 8- and 10-bit video and much faster on mobile
// GPUs. Texture coordinates, texel positions, and the initial color-matrix correction stay in highp (32-bit float).
precision mediump float;
precision highp int;

layout(location = 0) in highp vec2 uv;
layout(location = 1) in highp vec2 alphaUV;
layout(location = 2) in highp vec2 tile;
layout(location = 3) in highp float ahead;

#ifdef KEYED
layout(location = 0, index = 0) out vec4 color;
layout(location = 0, index = 1) out vec4 cover;
#else
layout(location = 0) out vec4 color;
#endif

// Settings that stay constant across frames are specialized via Vulkan specialization constants
// (VulkanXRGraphics.pipeline) so the driver compiler can eliminate unused branches and fold constant math.
// GAMMA: FrameLayout.encodingGamma (1.0 leaves values unchanged).
layout(constant_id = 0) const float GAMMA = 1.0;
// True when rendering to an sRGB attachment that expects linear-light output.
layout(constant_id = 1) const bool LINEAR_TARGET = false;
// True when alphaPicture provides a separate alpha plane.
layout(constant_id = 2) const bool HAS_ALPHA = false;
// True during ColorProbe readback, encoding unclamped values as sampled * 0.5 + 0.25 within an 8-bit target.
layout(constant_id = 3) const bool PROBE = false;
// True when the quad's edges are feathered by style.feather.
layout(constant_id = 4) const bool FEATHERED = false;
// True when the render target is cleared to transparent and alpha-blended by the OpenXR compositor, which
// interprets RGB as premultiplied in linear light.
layout(constant_id = 5) const bool COMPOSITED = false;
// True when this quad is rendered into its own dedicated layer (the sharp foveal layer), meaning the compositor
// blends its feathered edge. When false, the feathered edge blends directly over the base quad in the target's
// color encoding.
layout(constant_id = 6) const bool ALONE = false;

layout(set = 0, binding = 0) uniform highp sampler2D picture;
layout(set = 0, binding = 1) uniform highp sampler2D alphaPicture;

// feather: edge feather width as a fraction of quad size, used when FEATHERED.
// fill: solid RGBA color used instead of texture sampling when fill.a > 0. When host chroma keying is active
// (keyColor.a == 2) and fill.a == 0, fill.xy holds the texture dimensions in texels.
// keyColor.a: 1 for client HSV chroma keying (KEYED builds), or 2 for SteamVR host chroma keying (hostKeyed),
// where keyColor.rgb holds the key color (0 or 1 per channel) and keyRange holds (noiseFloor, dimOpacity).
// keyColor: gamma-encoded chroma-key target color; keyRange: (near, far) HSV distance thresholds
// (see Settings.chromaKeyNear). Used only when compiled with KEYED.
layout(push_constant) uniform Style {
    float feather;
    // Kept for push-constant layout compatibility; superseded by specialization constants HAS_ALPHA, GAMMA, and LINEAR_TARGET.
    float hasAlpha;
    float gamma;
    float linearTarget;
    highp vec4 fill;
    vec4 keyColor;
    vec2 keyRange;
    // Kept for push-constant layout compatibility; superseded by specialization constant PROBE.
    float probe;
    // Overall stream opacity in 0...1 applied to textured quads.
    float opacity;
    // Row-major 3x4 affine matrix applied to (r, g, b, 1) to invert unwanted Y'CbCr sampler range expansion or
    // matrix conversions.
    highp vec4 fix0;
    highp vec4 fix1;
    highp vec4 fix2;
    // Normalized bounds (left, top, right, bottom) of an overlapping feathered quad when host chroma keying is
    // active (all zero when uncovered); that quad's feather width is stored in fill.z.
    highp vec4 coveredRect;
} style;

// Video textures have a single mip level, so all texture fetches use textureLod(..., 0.0). Implicit-LOD texture()
// calls require screen-space derivatives from quad neighbors, which can prevent early-out branches in hostKeyed.
highp vec3 corrected(highp vec3 raw) {
    highp vec4 from = vec4(raw, 1.0);
    return vec3(dot(style.fix0, from), dot(style.fix1, from), dot(style.fix2, from));
}

vec3 linearFromSRGB(vec3 encoded) {
    return mix(encoded / 12.92, pow((encoded + 0.055) / 1.055, vec3(2.4)), greaterThan(encoded, vec3(0.04045)));
}

vec3 srgbFromLinear(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(abs(c), vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// Inverts the host's v^(1/gamma) transfer adjustment used to preserve shadow detail, with fast paths for gamma
// 2.0 and 1.5 to avoid pow().
vec3 hostGammaUndone(vec3 v) {
    if (GAMMA == 2.0) {
        return v * v;
    }
    if (GAMMA == 1.5) {
        return v * sqrt(v);
    }
    return GAMMA > 1.0 ? pow(v, vec3(GAMMA)) : v;
}

#ifdef HOST
// Fast polynomial approximations of the sRGB transfer functions that avoid pow(). `linearNear` is accurate to
// within 0.002, `srgbNear` is within 0.01 (largest error in deep shadows), and a round trip is within 0.03 in
// deep shadows. Host chroma-key edge pixels perform around a dozen conversions per pixel, making exact pow()
// calls the main bottleneck. Opaque scene pixels bypass these helpers, so approximation error only affects
// blended key edges.
float linearNear(float encoded) {
    return encoded * (encoded * (encoded * 0.305306011 + 0.682171111) + 0.012522878);
}

vec3 linearNear(vec3 encoded) {
    return encoded * (encoded * (encoded * 0.305306011 + 0.682171111) + 0.012522878);
}

float srgbNear(float c) {
    float root = sqrt(c), fourth = sqrt(root), eighth = sqrt(fourth);
    return max(0.585122381 * root + 0.783140355 * fourth - 0.368262736 * eighth, 0.0);
}

vec3 srgbNear(vec3 c) {
    vec3 root = sqrt(c), fourth = sqrt(root), eighth = sqrt(fourth);
    return max(0.585122381 * root + 0.783140355 * fourth - 0.368262736 * eighth, 0.0);
}

// Host chroma-key shader ported from libvrlink_scene.so (the vChromaKeyColor fragment shader). Makes the
// host's key color transparent, despills blended edge pixels, and samples 2x2 chroma blocks to distinguish
// edges against the key from similarly colored scene content.

// Key fractions at or above this threshold are treated as fully transparent.
const float hostKeyFull = 0.85;

// Converts sampled sRGB to BT.709 Y'CbCr.
vec3 hostKeyYCbCr(vec3 rgb) {
    float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    return vec3(y, (rgb.b - y) / 1.8556 + 128.0 / 255.0, (rgb.r - y) / 1.5748 + 128.0 / 255.0);
}

// Encoding gamma leaves primary and secondary key colors (0 or 1 per channel) unchanged.
vec3 hostKeyGamma(vec3 rgb) {
    return GAMMA > 1.0 ? hostGammaUndone(clamp(rgb, 0.0, 1.0)) : rgb;
}

// Samples the texture and reconstructs BT.709 Y'CbCr alongside gamma-decoded sRGB.
void hostKeyTap(highp vec2 st, out vec3 yCbCr, out vec3 rgbGamma) {
    highp vec3 rgb = corrected(textureLod(picture, st, 0.0).rgb);
    yCbCr = hostKeyYCbCr(rgb);
    rgbGamma = hostKeyGamma(rgb);
}


float hostKeyShare(vec2 cbCr, vec2 keyCbCr) {
    vec2 key = keyCbCr - 0.5;
    return clamp(dot(cbCr - 0.5, key) / max(dot(key, key), 0.001), 0.0, 1.0);
}

float hostKeyShareAt(highp vec2 st, vec3 keyYCbCr) {
    return hostKeyShare(hostKeyYCbCr(corrected(textureLod(picture, st, 0.0).rgb)).yz, keyYCbCr.yz);
}

float hostKeyExcess(vec3 cGamma, vec3 kLinear) {
    vec3 onMask = step(0.5, kLinear);
    vec3 onLevel = mix(vec3(1.0), cGamma, onMask);
    vec3 offLevel = cGamma * (1.0 - onMask);
    float onGamma = min(onLevel.r, min(onLevel.g, onLevel.b));
    float offLinear = linearNear(clamp(max(offLevel.r, max(offLevel.g, offLevel.b)), 0.0, 1.0));
    return onGamma - srgbNear(min(offLinear + 0.5 * style.keyRange.x, 1.0));
}

// Returns premultiplied linear-light RGB and alpha. Sets `unchanged` when the pixel remains fully opaque with
// zero key spill removed.
vec4 hostKeyUnmix(vec3 cLinear, vec3 kLinear, float keyFraction, float bleed, float cameraSide, out bool unchanged) {
    float noise = style.keyRange.x;
    float rampStart = min(1.5 * noise, hostKeyFull - 0.1);
    float rampOpacity = 1.0 - clamp((keyFraction - rampStart) / max(hostKeyFull - rampStart, 0.001), 0.0, 1.0);
    float a = mix(rampOpacity, 1.0 - keyFraction, cameraSide);
    float allowance = keyFraction * (1.0 - smoothstep(noise, rampStart, keyFraction));
    float contentKeyness = allowance * (1.0 - bleed) * (1.0 - cameraSide);
    float removed = max(keyFraction - contentKeyness, 0.0);
    unchanged = a >= 1.0 && removed <= 0.0;
    vec3 premulLinear = max(cLinear - kLinear * removed, 0.0);
    vec3 s = clamp(premulLinear / mix(max(a, 0.001), 1.0, cameraSide), 0.0, 1.0);
    return vec4(s * a, a);
}

vec4 hostKeyEdge(highp vec2 st, highp vec3 raw, vec3 encoded, float least, float most, out bool unchanged);

// Evaluates host chroma keying and returns premultiplied linear-light RGB and alpha. Most pixels are either
// fully opaque scene content or pure key color and can be classified with a single texture sample: opaque scene
// pixels set `solid = true` (with `encoded` holding the gamma-decoded sRGB color and `result.rgb` unused), and
// pure key pixels return transparent black.
vec4 hostKeyed(highp vec2 st, out bool solid, out vec3 encoded) {
    highp vec3 raw = corrected(textureLod(picture, st, 0.0).rgb);
    vec3 rgbGamma = hostKeyGamma(raw);
    encoded = clamp(rgbGamma, 0.0, 1.0);

    vec3 k = style.keyColor.rgb;
    vec3 onMask = step(0.5, k);
    vec3 on = mix(vec3(1.0), rgbGamma, onMask);
    vec3 off = rgbGamma * (1.0 - onMask);
    float least = min(on.r, min(on.g, on.b)), most = max(off.r, max(off.g, off.b));
    solid = least - most <= 1.5 / 255.0;
    // Pixels this close to the key color always exceed hostKeyFull (0.85): 0.96 and 0.25 linearize to 0.913 and
    // 0.051, giving a linear difference of 0.862.
    bool settled = solid || (least >= 0.96 && most <= 0.25);
    vec4 result = vec4(0.0, 0.0, 0.0, solid ? 1.0 : 0.0);
    // Only run the multi-tap neighborhood pass on blended edge pixels, which is ~30x more expensive than the fast path.
    if (!settled) {
        result = hostKeyEdge(st, raw, encoded, least, most, solid);
    }
    return result;
}

// Despills and computes alpha for edge pixels that mix scene content with the key color, returning premultiplied
// linear-light RGB and alpha. Scene pixels that happen to have a tint near the key color also enter this path,
// and most set `unchanged` so the caller can output the original sampled color directly.
vec4 hostKeyEdge(highp vec2 st, highp vec3 raw, vec3 encoded, float least, float most, out bool unchanged) {
    unchanged = false;
    vec3 k = style.keyColor.rgb;
    // Estimate the linear-light key fraction as the minimum active key channel minus the maximum inactive channel.
    // Because the sRGB transfer curve is monotonic, we can take min/max before linearizing.
    float keyFraction = clamp(linearNear(clamp(least, 0.0, 1.0)) - linearNear(clamp(most, 0.0, 1.0)), 0.0, 1.0);
    if (keyFraction >= hostKeyFull) {
        return vec4(0.0);
    }
    vec3 c = linearNear(encoded);
    vec3 yCbCr = hostKeyYCbCr(raw);

    // Sample the current 2x2 chroma block and the neighboring block on the opposite side in X and Y.
    highp vec2 size = style.fill.xy;
    highp vec2 texel = st * size;
    highp vec2 part = fract((texel - 1.0) * 0.5);
    highp vec2 lower = step(part, vec2(0.5));
    highp vec2 own = texel - 2.0 * part + 2.0 * (1.0 - lower);
    highp vec2 far = texel - 2.0 * part + 2.0 * lower;
    vec3 keyYCbCr = hostKeyYCbCr(k);
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
        highp vec2 beyond = 2.0 * own - far;
        float beyondShare = max(hostKeyShareAt(vec2(beyond.x, texel.y) / size, keyYCbCr),
                                hostKeyShareAt(vec2(texel.x, beyond.y) / size, keyYCbCr));
        keyBeyondBlock = blockHoldsKey * clamp((beyondShare - 0.7) / 0.2, 0.0, 1.0);
    }

    float excess = max(hostKeyExcess(ownGamma, k), max(hostKeyExcess(farXGamma, k), hostKeyExcess(farYGamma, k)));
    float bleed = max(clamp((excess - 0.18) / 0.1, 0.0, 1.0), keyBeyondBlock);

    vec4 unmixed = hostKeyUnmix(c, k, keyFraction, bleed, cameraSide, unchanged);
    unchanged = unchanged && keyTexel <= 0.0;
    return unchanged ? vec4(0.0, 0.0, 0.0, 1.0) : unmixed * (1.0 - keyTexel);
}
#endif

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
    highp vec2 within = tile / ahead;
    float toEdge = min(min(within.x, 1.0 - within.x), min(within.y, 1.0 - within.y));
    float feather = FEATHERED ? clamp(toEdge / style.feather, 0.0, 1.0) : 1.0;
#ifdef HOST
    bool solid;
    vec3 encoded;
    // Compute how much an overlapping feathered foveal quad covers this pixel. When fully covered (covering >= 1.0),
    // this base quad is completely hidden, so we can output transparent black and skip texture sampling.
    float covering = 0.0;
    highp vec2 span = style.coveredRect.zw - style.coveredRect.xy;
    if (span.x > 0.0 && span.y > 0.0) {
        highp vec2 p = (within - style.coveredRect.xy) / span;
        float edge = min(min(p.x, 1.0 - p.x), min(p.y, 1.0 - p.y));
        covering = edge <= 0.0 ? 0.0 : (style.fill.z > 0.0 ? clamp(edge / style.fill.z, 0.0, 1.0) : 1.0);
        if (covering >= 1.0) {
            color = vec4(0.0);
            return;
        }
    }
    vec4 keyed = hostKeyed(uv / ahead, solid, encoded);
    // Dim passthrough behind the scene by blending toward premultiplied black (raising alpha while keeping RGB unchanged).
    float a = keyed.a + style.keyRange.y * (1.0 - keyed.a);
    // Where a feathered foveal quad with alpha a * c will be blended over this base quad using standard
    // premultiplied "over" blending, choose `under` so the combined alpha equals `a`:
    // a * c + (1 - a * c) * under = a  =>  under = a * (1 - c) / (1 - a * c).
    float under = clamp(a * (1.0 - covering) / max(1.0 - a * covering, 0.0001), 0.0, 1.0);
    float shade = feather * style.opacity;
    // The OpenXR compositor blends layers using premultiplied linear light, so compositor-blended weights are
    // applied in linear space. When feathering over a base quad in the same render target (!ALONE), the hardware
    // blender operates on the attachment's written encoding instead.
    float scale = under / max(a, 0.0001) * style.opacity * (ALONE ? feather : 1.0);
    // Avoid color-space conversions in the common cases: fully keyed pixels stay black, and full-opacity scene
    // pixels on an sRGB-encoded target write `encoded` directly.
    vec3 shown = vec3(0.0);
    if (solid && !LINEAR_TARGET && scale >= 1.0) {
        shown = encoded;
    } else if (solid && scale > 0.0) {
        vec3 linear = linearFromSRGB(encoded) * scale;
        shown = LINEAR_TARGET ? linear : srgbFromLinear(linear);
    } else if (keyed.a > 0.0 && scale > 0.0) {
        vec3 linear = keyed.rgb * scale;
        shown = LINEAR_TARGET ? linear : srgbNear(linear);
    }
    color = vec4(ALONE ? shown : shown * feather, under * shade);
#else
    highp vec3 raw = corrected(textureLod(picture, uv / ahead, 0.0).rgb);
    if (PROBE) {
        highp vec3 kept = clamp(raw * 0.5 + 0.25, 0.0, 1.0);
        if (LINEAR_TARGET) {
            kept = mix(kept / 12.92, pow((kept + 0.055) / 1.055, vec3(2.4)), greaterThan(kept, vec3(0.04045)));
        }
        color = vec4(kept, 1.0);
#ifdef KEYED
        cover = vec4(1.0);
#endif
        return;
    }
    vec3 sampled = hostGammaUndone(clamp(raw, 0.0, 1.0));
    // Evaluate the chroma key in gamma-encoded RGB space before converting to linear light.
    float kept = 1.0;
#ifdef KEYED
    kept = colorCloseHSV(hsvFromRGB(sampled), hsvFromRGB(style.keyColor.rgb), style.keyRange);
    if (kept <= 0.0) {
        discard;                                 // fully keyed out; leave passthrough visible
    }
    sampled = max(sampled * kept - style.keyColor.rgb * (1.0 - kept), vec3(0.0));
#endif
    if (LINEAR_TARGET) {
        sampled = linearFromSRGB(sampled);
    }
    // Separate alpha streams encode opacity in the red/luma channel with premultiplied RGB in `picture`.
    float opacity = 1.0;
    if (HAS_ALPHA) {
        opacity = corrected(textureLod(alphaPicture, alphaUV / ahead, 0.0).rgb).g;
        if (opacity < 0.02) {
            discard;
        }
    }
    // Feather foveated inset edges into the background quad using premultiplied alpha blending.
    float shade = feather * style.opacity;
    // Apply compositor-blended weights in linear light: scaling sRGB-encoded values directly would decode too
    // dark and leave a dark fringe along feathered edges. Conversely, when blending a feathered quad over a base
    // quad in an UNORM target (!ALONE), apply `feather` in encoded space to match the hardware blender and avoid
    // a bright fringe.
    float weight = kept * style.opacity * (ALONE ? feather : 1.0);
    vec3 shown = sampled * weight;
    if (!LINEAR_TARGET && COMPOSITED && weight < 1.0) {
        shown = srgbFromLinear(linearFromSRGB(sampled) * weight);
    }
    if (!ALONE) {
        shown *= feather;
    }
#ifdef KEYED
    // Match Quad.metal's dual-source blend: scale color and alpha by the feather weight while
    // preserving the underlying tile across feathered fovea edges.
    color = vec4(shown, kept * kept * opacity * shade);
    cover = vec4(opacity * shade);
#else
    color = vec4(shown, opacity * shade);
#endif
#endif
}
