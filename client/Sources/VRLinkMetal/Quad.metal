// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The shaders of QuadRenderer.swift. The layouts of Vertex and QuadStyle are
// filled in by hand there (`draw`), so change both together.

#include <metal_stdlib>
using namespace metal;

// One corner of a quad, for up to two eyes: each eye has its own position
// on screen and its own part of the decoded frame to show.
// alphaUV is where the same corner is in the picture of transparency, when there is one.
// `ahead` stores each vertex's forward distance from the rendering eye for projective UV interpolation.
struct Vertex { float4 position[2]; float2 uv[2]; float2 alphaUV[2]; float2 tile; float2 ahead; };
struct Fragment { float4 position [[position]]; float2 uv; float2 alphaUV; float2 tile; float ahead; uint eye [[flat]]; };

// With vertex amplification every triangle is drawn once per eye, and
// amplification_id selects the target eye.
vertex Fragment vertexMain(uint index [[vertex_id]], ushort eye [[amplification_id]],
                           const device Vertex *vertices [[buffer(0)]]) {
    Fragment out;
    // Texture UVs are perspective-projected from the host's rendering eye. When a
    // quad is depth-warped and viewed from a translated display eye, standard
    // perspective-correct rasterization interpolates linearly across the warped
    // triangle surface rather than the rendering eye's view plane. Multiplying UVs
    // by the rendering-eye depth (`ahead`) here and dividing in the fragment shader
    // restores projective texturing from the rendering eye (and reduces to standard
    // UV interpolation when `ahead` is constant across a flat quad).
    float ahead = vertices[index].ahead[eye];
    out.position = vertices[index].position[eye];
    out.uv = vertices[index].uv[eye] * ahead;
    out.alphaUV = vertices[index].alphaUV[eye] * ahead;
    out.tile = vertices[index].tile * ahead;
    out.ahead = ahead;
    out.eye = eye;
    return out;
}

// The atlas texture has a YCbCr pixel format whose sampler returns RGB,
// so there is no color conversion here.
// keyColor is in the same light as the sampled picture; keyRange is
// the near and far blend distances.
// hasAlpha: the frame has a picture of transparency (not zero), or is opaque.
// gamma is FrameLayout.encodingGamma (1 means no gamma adjustment).
// linearLight is non-zero when the atlas texture is sampled as linear light rather than sRGB.
// keyColor.a is 2 for host chroma keying (hostKeyed): keyColor.rgb holds the key color (0 or 1 per channel)
// and keyRange holds (noiseFloor, dimOpacity).
struct QuadStyle { float feather; float hasAlpha; float gamma; float linearLight; float4 fill; float4 keyColor; float2 keyRange; };

float3 linearFromSRGB(float3 c) {
    return mix(c / 12.92, pow(max((c + 0.055) / 1.055, 0.0), float3(2.4)), float3(c >= 0.04045));
}

float3 srgbFromLinear(float3 c) {
    return mix(c * 12.92, 1.055 * pow(abs(c), float3(1.0 / 2.4)) - 0.055, float3(c >= 0.0031308));
}

// Host chroma-key shader ported from libvrlink_scene.so (matching hostKeyed in VRLinkVulkan/Shaders/quad.frag).
// Makes the host's key color transparent, despills blended edge pixels, and samples 2x2 chroma blocks to
// distinguish edges against the key from similarly colored scene content.

// Key fractions at or above this threshold are treated as fully transparent.
constant float hostKeyFull = 0.85;

// Samples the texture and reconstructs BT.709 Y'CbCr alongside gamma-decoded sRGB.
void hostKeyTap(texture2d<float> picture, sampler pictureSampler, float2 st, QuadStyle style,
                thread float3 &yCbCr, thread float3 &rgbGamma) {
    float3 rgb = picture.sample(pictureSampler, st).rgb;
    if (style.linearLight != 0.0) {
        rgb = srgbFromLinear(saturate(rgb));
    }
    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    yCbCr = float3(y, (rgb.b - y) / 1.8556 + 128.0 / 255.0, (rgb.r - y) / 1.5748 + 128.0 / 255.0);
    // Encoding gamma leaves primary and secondary key colors (0 or 1 per channel) unchanged.
    rgbGamma = style.gamma > 1.0 ? pow(saturate(rgb), float3(style.gamma)) : rgb;
}

float hostKeyFraction(float3 cLinear, float3 kLinear) {
    float3 onMask = step(0.5, kLinear);
    float3 onRatio = mix(float3(1.0), cLinear / max(kLinear, 0.001), onMask);
    float3 offValue = cLinear * (1.0 - onMask);
    return saturate(min(onRatio.r, min(onRatio.g, onRatio.b)) - max(offValue.r, max(offValue.g, offValue.b)));
}

float hostKeyShare(float2 cbCr, float2 keyCbCr) {
    float2 key = keyCbCr - 0.5;
    return saturate(dot(cbCr - 0.5, key) / max(dot(key, key), 0.001));
}

float hostKeyShareAt(texture2d<float> picture, sampler pictureSampler, float2 st, QuadStyle style, float3 keyYCbCr) {
    float3 yCbCr, rgbGamma;
    hostKeyTap(picture, pictureSampler, st, style, yCbCr, rgbGamma);
    return hostKeyShare(yCbCr.yz, keyYCbCr.yz);
}

float hostKeyExcess(float3 cGamma, float3 kLinear, float noise) {
    float3 onMask = step(0.5, kLinear);
    float3 onLevel = mix(float3(1.0), cGamma, onMask);
    float3 offLevel = cGamma * (1.0 - onMask);
    float onGamma = min(onLevel.r, min(onLevel.g, onLevel.b));
    float offLinear = linearFromSRGB(float3(max(offLevel.r, max(offLevel.g, offLevel.b)))).x;
    return onGamma - srgbFromLinear(float3(min(offLinear + 0.5 * noise, 1.0))).x;
}

// Returns rgb premultiplied in linear light, and alpha.
float4 hostKeyUnmix(float3 cLinear, float3 kLinear, float keyFraction, float bleed, float cameraSide, float noise) {
    float rampStart = min(1.5 * noise, hostKeyFull - 0.1);
    float rampOpacity = 1.0 - saturate((keyFraction - rampStart) / max(hostKeyFull - rampStart, 0.001));
    float a = mix(rampOpacity, 1.0 - keyFraction, cameraSide);
    float allowance = keyFraction * (1.0 - smoothstep(noise, rampStart, keyFraction));
    float contentKeyness = allowance * (1.0 - bleed) * (1.0 - cameraSide);
    float3 premulLinear = max(cLinear - kLinear * max(keyFraction - contentKeyness, 0.0), 0.0);
    float3 s = saturate(premulLinear / mix(max(a, 0.001), 1.0, cameraSide));
    return float4(s * a, a);
}

// Returns rgb premultiplied in linear light, and alpha.
float4 hostKeyed(texture2d<float> picture, sampler pictureSampler, float2 st, QuadStyle style) {
    float3 yCbCr, rgbGamma;
    hostKeyTap(picture, pictureSampler, st, style, yCbCr, rgbGamma);

    float3 k = style.keyColor.rgb;
    float noise = style.keyRange.x;
    float3 onMask = step(0.5, k);
    float3 on = mix(float3(1.0), rgbGamma, onMask);
    float3 off = rgbGamma * (1.0 - onMask);
    float3 c = linearFromSRGB(saturate(rgbGamma));
    if (min(on.r, min(on.g, on.b)) - max(off.r, max(off.g, off.b)) <= 1.5 / 255.0) {
        return float4(c, 1.0);
    }

    float keyFraction = hostKeyFraction(c, k);
    if (keyFraction >= hostKeyFull) {
        return float4(0.0);
    }

    // Sample the current 2x2 chroma block and the neighboring block on the opposite side in X and Y.
    float2 size = float2(picture.get_width(), picture.get_height());
    float2 texel = st * size;
    float2 part = fract((texel - 1.0) * 0.5);
    float2 lower = step(part, float2(0.5));
    float2 own = texel - 2.0 * part + 2.0 * (1.0 - lower);
    float2 far = texel - 2.0 * part + 2.0 * lower;
    float keyY = dot(k, float3(0.2126, 0.7152, 0.0722));
    float3 keyYCbCr = float3(keyY, (k.b - keyY) / 1.8556 + 128.0 / 255.0, (k.r - keyY) / 1.5748 + 128.0 / 255.0);
    float3 ownYCbCr, ownGamma, farXYCbCr, farXGamma, farYYCbCr, farYGamma;
    hostKeyTap(picture, pictureSampler, own / size, style, ownYCbCr, ownGamma);
    hostKeyTap(picture, pictureSampler, float2(far.x, texel.y) / size, style, farXYCbCr, farXGamma);
    hostKeyTap(picture, pictureSampler, float2(texel.x, far.y) / size, style, farYYCbCr, farYGamma);
    float ownShare = hostKeyShare(ownYCbCr.yz, keyYCbCr.yz);
    float farShare = max(hostKeyShare(farXYCbCr.yz, keyYCbCr.yz), hostKeyShare(farYYCbCr.yz, keyYCbCr.yz));

    float blockHoldsKey = saturate((ownShare - 0.15) / 0.1);
    float cameraSide = blockHoldsKey * saturate((max(ownShare, farShare) - 0.75) / 0.25);

    float keyBeside = saturate((max(ownShare, farShare) - 0.7) / 0.2);
    float keyTexel = keyBeside * (1.0 - smoothstep(0.03, 0.1, abs(yCbCr.x - keyYCbCr.x)));

    float keyBeyondBlock = 0.0;
    if (ownShare > 0.15) {
        float2 beyond = 2.0 * own - far;
        float beyondShare = max(hostKeyShareAt(picture, pictureSampler, float2(beyond.x, texel.y) / size, style, keyYCbCr),
                                hostKeyShareAt(picture, pictureSampler, float2(texel.x, beyond.y) / size, style, keyYCbCr));
        keyBeyondBlock = blockHoldsKey * saturate((beyondShare - 0.7) / 0.2);
    }

    float excess = max(hostKeyExcess(ownGamma, k, noise), max(hostKeyExcess(farXGamma, k, noise), hostKeyExcess(farYGamma, k, noise)));
    float bleed = max(saturate((excess - 0.18) / 0.1), keyBeyondBlock);

    return hostKeyUnmix(c, k, keyFraction, bleed, cameraSide, noise) * (1.0 - keyTexel);
}

// Restores sRGB values that the host encoded as v^(1/gamma) to preserve dark detail.
// If the atlas was sampled as linear light, convert to sRGB before applying pow(v, gamma)
// and convert back to linear light afterward.
float3 undoEncodingGamma(float3 color, float gamma, bool linearLight) {
    float3 encoded = saturate(color);
    if (linearLight) {
        encoded = mix(encoded * 12.92, 1.055 * pow(encoded, float3(1.0 / 2.4)) - 0.055, float3(encoded > 0.0031308));
    }
    encoded = pow(encoded, float3(gamma));
    if (linearLight) {
        encoded = mix(encoded / 12.92, pow((encoded + 0.055) / 1.055, float3(2.4)), float3(encoded > 0.04045));
    }
    return encoded;
}

// Whether there is chroma keying at all is fixed when the pipeline is
// built, so that it costs nothing when off. Its color and distances
// come with every draw, so they can be tuned while watching.
constant bool CHROMAKEY_ENABLED [[ function_constant(0) ]];

// The two functions below and the keying itself are the ALVR visionOS
// client's, unchanged.
// 0 where a color is within tol.x of the key color (in weighted hue,
// saturation, value), 1 beyond tol.y, a ramp between.
half colorclose_hsv(half3 hsv, half3 keyHsv, half2 tol)
{
    // Saturation or value too low, don't consider it at all.
    if (hsv.b < 0.001 || hsv.g < 0.001) {
        return 1.0;
    }
    half3 weights = half3(4., 1., 2.);
    half tmp = length(weights * (keyHsv - hsv));
    if (tmp < tol.x)
      return 0.0;
    else if (tmp < tol.y)
      return (tmp - tol.x)/(tol.y - tol.x);
    else
      return 1.0;
}

half3 rgb2hsv(half3 rgb) {
    half Cmax = max(rgb.r, max(rgb.g, rgb.b));
    half Cmin = min(rgb.r, min(rgb.g, rgb.b));
    half delta = Cmax - Cmin;
    half3 hsv = half3(0., 0., Cmax);

    if(Cmax > Cmin) {
        hsv.y = delta / Cmax;

        if(rgb.r == Cmax) {
            hsv.x = (rgb.g - rgb.b) / delta;
        } else {
            if (rgb.g == Cmax) {
                hsv.x = 2. + (rgb.b - rgb.r) / delta;
            } else {
                hsv.x = 4. + (rgb.r - rgb.g) / delta;
            }
        }
        hsv.x = fract(hsv.x / 6.);
    }

    return hsv;
}

// Two outputs for the one target: the color to add, and how much of
// what is already there this quad covers.
struct Blended {
    float4 color [[color(0), index(0)]];
    float4 cover [[color(0), index(1)]];
};

// Each eye may show a picture of its own (a host that encodes the eyes
// apart); when both show the same one, it is bound twice.
fragment Blended fragmentMain(Fragment in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                              texture2d<float> otherEyeAtlas [[texture(1)]],
                              texture2d<float> alpha [[texture(2)]],
                              texture2d<float> otherEyeAlpha [[texture(3)]],
                              sampler atlasSampler [[sampler(0)]],
                              constant QuadStyle &style [[buffer(0)]]) {
    Blended out;
    if (style.fill.a > 0.0) {                            // a flat-colored quad
        out.color = float4(style.fill.rgb * style.fill.a, style.fill.a);
        out.cover = float4(style.fill.a);
        return out;
    }
    float2 uv = in.uv / in.ahead, alphaUV = in.alphaUV / in.ahead, tile = in.tile / in.ahead;
    if (style.keyColor.a > 1.5) {
        float4 hostKey = in.eye == 0 ? hostKeyed(atlas, atlasSampler, uv, style) : hostKeyed(otherEyeAtlas, atlasSampler, uv, style);
        // Dim passthrough behind the scene by blending toward premultiplied black (raising alpha while keeping RGB unchanged).
        float a = hostKey.a + style.keyRange.y * (1.0 - hostKey.a);
        // Convert output RGB to match the render target's color encoding.
        float3 shown = style.linearLight != 0.0 ? hostKey.rgb : srgbFromLinear(hostKey.rgb);
        float toEdge = min(min(tile.x, 1.0 - tile.x), min(tile.y, 1.0 - tile.y));
        float feather = style.feather > 0.0 ? saturate(toEdge / style.feather) : 1.0;
        // Dual-source blending cross-fades the feathered foveal quad with the underlying base tile,
        // preserving combined passthrough opacity without adjusting the base tile's alpha.
        out.color = float4(shown, a) * feather;
        out.cover = float4(feather);
        return out;
    }
    float3 sampled = in.eye == 0 ? atlas.sample(atlasSampler, uv).rgb : otherEyeAtlas.sample(atlasSampler, uv).rgb;
    if (style.gamma > 1.0) {
        sampled = undoEncodingGamma(sampled, style.gamma, style.linearLight != 0.0);
    }
    half3 color = half3(sampled);
    half4 colorOut = half4(color.rgb, 1.0);
    // A host that sends transparency sends it as a picture of its own,
    // whose brightness is how opaque the colors are; the colors come
    // already multiplied by it. Where nothing is opaque nothing is
    // drawn, and no depth: the room shows.
    float opacity = 1.0;
    if (style.hasAlpha != 0.0) {
        opacity = in.eye == 0 ? alpha.sample(atlasSampler, alphaUV).r : otherEyeAlpha.sample(atlasSampler, alphaUV).r;
        if (opacity < 0.02) {
            discard_fragment();
        }
    }
    if (CHROMAKEY_ENABLED) {
        half3 CHROMAKEY_COLOR = half3(style.keyColor.rgb);
        half2 CHROMAKEY_LERP_DIST_RANGE = half2(style.keyRange);
        half4 chromaKeyHSV = half4(rgb2hsv(half3(CHROMAKEY_COLOR)), 1.0);
        half4 newHSV = half4(rgb2hsv(color.rgb), 1.0);
        half mask = colorclose_hsv(newHSV.rgb, chromaKeyHSV.rgb, half2(CHROMAKEY_LERP_DIST_RANGE));
        if (mask <= 0.0) {
            discard_fragment();                          // nothing drawn, no depth: the room shows
        }
        colorOut = half4((colorOut.rgb * mask) - (half3(CHROMAKEY_COLOR) * (1.0 - mask)), colorOut.a * mask);
    }
    // ALVR blends that color with "source alpha" for color and alpha
    // alike, which leaves (rgb * a, a * a) in an empty target. The same
    // is written here directly.
    float4 keyed = float4(float3(colorOut.rgb) * float(colorOut.a), float(colorOut.a * colorOut.a) * opacity);

    // A feathered quad (the fovea) fades into the one behind it: it
    // adds its own color times the feather and keeps the rest of what
    // was there, whatever the key has done to either.
    float toEdge = min(min(tile.x, 1.0 - tile.x), min(tile.y, 1.0 - tile.y));
    float feather = style.feather > 0.0 ? saturate(toEdge / style.feather) : 1.0;
    out.color = keyed * feather;
    out.cover = float4(feather * opacity);
    return out;
}
