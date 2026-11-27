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

// The atlas texture uses a hardware YCbCr pixel format whose sampler outputs RGB directly.
// For client chroma keying, keyColor is in the render target's color space (linear or sRGB-encoded) and
// keyRange holds the (near, far) HSV distance thresholds.
// When keyColor.a == 2 (hostKeyed), keyColor.rgb holds the host key color (0 or 1 per channel) and
// keyRange holds (noiseFloor, dimOpacity).
// The hasAlpha, gamma, and linearLight fields are kept for layout compatibility; the shader reads the
// function constants HAS_ALPHA, GAMMA, and TARGET_LINEAR instead.
struct QuadStyle { float feather; float hasAlpha; float gamma; float linearLight; float4 fill; float4 keyColor; float2 keyRange; };

// Settings that stay constant across frames are specialized via function constants (QuadRenderer.pipeline) so the
// Metal compiler can eliminate unused branches and fold constant math. Client chroma-key colors and thresholds are
// still passed per draw in QuadStyle so users can adjust them live.
// True when client HSV chroma keying is enabled.
constant bool CHROMAKEY_ENABLED [[ function_constant(0) ]];
// Host encoding gamma from FrameLayout.encodingGamma (1.0 means no adjustment).
constant float GAMMA [[ function_constant(1) ]];
// True when the atlas texture uses an sRGB pixel format and returns linear light on sample (used only when
// encoding gamma and host chroma keying are both inactive).
constant bool SAMPLED_LINEAR [[ function_constant(2) ]];
// True when the render target expects linear-light RGB output.
constant bool TARGET_LINEAR [[ function_constant(3) ]];
// True when the frame includes a separate alpha texture plane.
constant bool HAS_ALPHA [[ function_constant(4) ]];
// True when SteamVR host chroma keying is active for this draw.
constant bool HOST_KEY [[ function_constant(5) ]];
// True when quad edges are feathered using style.feather.
constant bool FEATHERED [[ function_constant(6) ]];

// Color math uses half precision, which has enough precision for 8- and 10-bit video and runs faster on Apple GPUs.
// Texture coordinates and texel positions stay in 32-bit float.
half3 linearFromSRGB(half3 c) {
    return mix(c / 12.92h, pow(max((c + 0.055h) / 1.055h, 0.0h), half3(2.4h)), half3(c >= 0.04045h));
}

half3 srgbFromLinear(half3 c) {
    return mix(c * 12.92h, 1.055h * pow(abs(c), half3(1.0h / 2.4h)) - 0.055h, half3(c >= 0.0031308h));
}

// Fast polynomial approximations of the sRGB transfer functions that avoid pow(). `linearNear` is accurate to
// within 0.002, and `srgbNear` is within 0.01 (with the largest error in deep shadows). Host chroma-key edge
// pixels perform around a dozen transfer conversions per pixel, making exact pow() calls the main bottleneck.
// Opaque scene pixels bypass this path, so approximation error only affects blended key edges.
half linearNear(half encoded) {
    return encoded * (encoded * (encoded * 0.305306011h + 0.682171111h) + 0.012522878h);
}

half3 linearNear(half3 encoded) {
    return encoded * (encoded * (encoded * 0.305306011h + 0.682171111h) + 0.012522878h);
}

half srgbNear(half c) {
    half root = sqrt(c), fourth = sqrt(root), eighth = sqrt(fourth);
    return max(0.585122381h * root + 0.783140355h * fourth - 0.368262736h * eighth, 0.0h);
}

half3 srgbNear(half3 c) {
    half3 root = sqrt(c), fourth = sqrt(root), eighth = sqrt(fourth);
    return max(0.585122381h * root + 0.783140355h * fourth - 0.368262736h * eighth, 0.0h);
}

// Inverts the host's v^(1/gamma) encoding used to preserve shadow detail, using fast paths for gamma 2.0 and 1.5
// to avoid pow().
half3 hostGammaUndone(half3 v) {
    if (GAMMA == 2.0) {
        return v * v;
    }
    if (GAMMA == 1.5) {
        return v * sqrt(v);
    }
    return GAMMA > 1.0 ? pow(v, half3(GAMMA)) : v;
}

// Host chroma-key shader ported from libvrlink_scene.so (matching hostKeyed in VRLinkVulkan/Shaders/quad.frag).
// Makes the host's key color transparent, despills blended edge pixels, and samples 2x2 chroma blocks to
// distinguish edges against the key from similarly colored scene content. Host-keyed frames are always sampled as
// sRGB-encoded values (SAMPLED_LINEAR is false) because keying operates in encoded space.

// Key fractions at or above this threshold are treated as fully transparent.
constant half hostKeyFull = 0.85h;

// Converts sampled sRGB to BT.709 Y'CbCr.
half3 hostKeyYCbCr(half3 rgb) {
    half y = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    return half3(y, (rgb.b - y) / 1.8556h + 128.0h / 255.0h, (rgb.r - y) / 1.5748h + 128.0h / 255.0h);
}

// Encoding gamma leaves primary and secondary key colors (0 or 1 per channel) unchanged.
half3 hostKeyGamma(half3 rgb) {
    return GAMMA > 1.0 ? hostGammaUndone(saturate(rgb)) : rgb;
}

// Explicitly sample mip level 0. Video textures are single-mip, and Metal disallows implicit-LOD sampling (which
// computes screen-space derivatives across quad neighbors) inside divergent edge-processing branches.
half3 hostKeySample(texture2d<float> picture, sampler pictureSampler, float2 st) {
    return half3(picture.sample(pictureSampler, st, level(0)).rgb);
}

// Samples the texture and reconstructs BT.709 Y'CbCr alongside gamma-decoded sRGB.
void hostKeyTap(texture2d<float> picture, sampler pictureSampler, float2 st, thread half3 &yCbCr, thread half3 &rgbGamma) {
    half3 rgb = hostKeySample(picture, pictureSampler, st);
    yCbCr = hostKeyYCbCr(rgb);
    rgbGamma = hostKeyGamma(rgb);
}

half hostKeyShare(half2 cbCr, half2 keyCbCr) {
    half2 key = keyCbCr - 0.5h;
    return saturate(dot(cbCr - 0.5h, key) / max(dot(key, key), 0.001h));
}

half hostKeyShareAt(texture2d<float> picture, sampler pictureSampler, float2 st, half3 keyYCbCr) {
    return hostKeyShare(hostKeyYCbCr(hostKeySample(picture, pictureSampler, st)).yz, keyYCbCr.yz);
}

half hostKeyExcess(half3 cGamma, half3 kLinear, half noise) {
    half3 onMask = step(0.5h, kLinear);
    half3 onLevel = mix(half3(1.0h), cGamma, onMask);
    half3 offLevel = cGamma * (1.0h - onMask);
    half onGamma = min(onLevel.r, min(onLevel.g, onLevel.b));
    half offLinear = linearNear(saturate(max(offLevel.r, max(offLevel.g, offLevel.b))));
    return onGamma - srgbNear(min(offLinear + 0.5h * noise, 1.0h));
}

// Returns premultiplied linear-light RGB and alpha. Sets `unchanged` when the pixel remains fully opaque with
// zero key spill removed.
half4 hostKeyUnmix(half3 cLinear, half3 kLinear, half keyFraction, half bleed, half cameraSide, half noise,
                   thread bool &unchanged) {
    half rampStart = min(1.5h * noise, hostKeyFull - 0.1h);
    half rampOpacity = 1.0h - saturate((keyFraction - rampStart) / max(hostKeyFull - rampStart, 0.001h));
    half a = mix(rampOpacity, 1.0h - keyFraction, cameraSide);
    half allowance = keyFraction * (1.0h - smoothstep(noise, rampStart, keyFraction));
    half contentKeyness = allowance * (1.0h - bleed) * (1.0h - cameraSide);
    half removed = max(keyFraction - contentKeyness, 0.0h);
    unchanged = a >= 1.0h && removed <= 0.0h;
    half3 premulLinear = max(cLinear - kLinear * removed, 0.0h);
    half3 s = saturate(premulLinear / mix(max(a, 0.001h), 1.0h, cameraSide));
    return half4(s * a, a);
}

// Despills and computes alpha for edge pixels that mix scene content with the key color, returning premultiplied
// linear-light RGB and alpha. Scene pixels that happen to have a tint near the key color also enter this path,
// and most set `unchanged` so the caller can output the original sampled color directly.
half4 hostKeyEdge(texture2d<float> picture, sampler pictureSampler, float2 st, QuadStyle style, half3 raw, half3 encoded,
                  half least, half most, thread bool &unchanged) {
    unchanged = false;
    half3 k = half3(style.keyColor.rgb);
    half noise = half(style.keyRange.x);
    // Estimate the linear-light key fraction as the minimum active key channel minus the maximum inactive channel.
    // Because the sRGB transfer curve is monotonic, we can take min/max before linearizing.
    half keyFraction = saturate(linearNear(saturate(least)) - linearNear(saturate(most)));
    if (keyFraction >= hostKeyFull) {
        return half4(0.0h);
    }
    half3 c = linearNear(encoded);
    half3 yCbCr = hostKeyYCbCr(raw);

    // Sample the current 2x2 chroma block and the neighboring block on the opposite side in X and Y.
    float2 size = float2(picture.get_width(), picture.get_height());
    float2 texel = st * size;
    float2 part = fract((texel - 1.0) * 0.5);
    float2 lower = step(part, float2(0.5));
    float2 own = texel - 2.0 * part + 2.0 * (1.0 - lower);
    float2 far = texel - 2.0 * part + 2.0 * lower;
    half3 keyYCbCr = hostKeyYCbCr(k);
    half3 ownYCbCr, ownGamma, farXYCbCr, farXGamma, farYYCbCr, farYGamma;
    hostKeyTap(picture, pictureSampler, own / size, ownYCbCr, ownGamma);
    hostKeyTap(picture, pictureSampler, float2(far.x, texel.y) / size, farXYCbCr, farXGamma);
    hostKeyTap(picture, pictureSampler, float2(texel.x, far.y) / size, farYYCbCr, farYGamma);
    half ownShare = hostKeyShare(ownYCbCr.yz, keyYCbCr.yz);
    half farShare = max(hostKeyShare(farXYCbCr.yz, keyYCbCr.yz), hostKeyShare(farYYCbCr.yz, keyYCbCr.yz));

    half blockHoldsKey = saturate((ownShare - 0.15h) / 0.1h);
    half cameraSide = blockHoldsKey * saturate((max(ownShare, farShare) - 0.75h) / 0.25h);

    half keyBeside = saturate((max(ownShare, farShare) - 0.7h) / 0.2h);
    half keyTexel = keyBeside * (1.0h - smoothstep(0.03h, 0.1h, abs(yCbCr.x - keyYCbCr.x)));

    half keyBeyondBlock = 0.0h;
    if (ownShare > 0.15h) {
        float2 beyond = 2.0 * own - far;
        half beyondShare = max(hostKeyShareAt(picture, pictureSampler, float2(beyond.x, texel.y) / size, keyYCbCr),
                               hostKeyShareAt(picture, pictureSampler, float2(texel.x, beyond.y) / size, keyYCbCr));
        keyBeyondBlock = blockHoldsKey * saturate((beyondShare - 0.7h) / 0.2h);
    }

    half excess = max(hostKeyExcess(ownGamma, k, noise), max(hostKeyExcess(farXGamma, k, noise), hostKeyExcess(farYGamma, k, noise)));
    half bleed = max(saturate((excess - 0.18h) / 0.1h), keyBeyondBlock);

    half4 unmixed = hostKeyUnmix(c, k, keyFraction, bleed, cameraSide, noise, unchanged);
    unchanged = unchanged && keyTexel <= 0.0h;
    return unchanged ? half4(0.0h, 0.0h, 0.0h, 1.0h) : unmixed * (1.0h - keyTexel);
}

// Evaluates host chroma keying and returns premultiplied linear-light RGB and alpha. Most pixels are either
// fully opaque scene content or pure key color and can be classified with a single texture sample: opaque scene
// pixels set `solid = true` (with `encoded` holding the gamma-decoded sRGB color and `result.rgb` unused), and
// pure key pixels return transparent black.
half4 hostKeyed(texture2d<float> picture, sampler pictureSampler, float2 st, QuadStyle style,
                thread bool &solid, thread half3 &encoded) {
    half3 raw = hostKeySample(picture, pictureSampler, st);
    half3 rgbGamma = hostKeyGamma(raw);
    encoded = saturate(rgbGamma);

    half3 k = half3(style.keyColor.rgb);
    half3 onMask = step(0.5h, k);
    half3 on = mix(half3(1.0h), rgbGamma, onMask);
    half3 off = rgbGamma * (1.0h - onMask);
    half least = min(on.r, min(on.g, on.b)), most = max(off.r, max(off.g, off.b));
    solid = least - most <= 1.5h / 255.0h;
    // Pixels this close to the key color always exceed hostKeyFull (0.85): 0.96 and 0.25 linearize to 0.913 and
    // 0.051, giving a linear difference of 0.862.
    bool settled = solid || (least >= 0.96h && most <= 0.25h);
    half4 result = half4(0.0h, 0.0h, 0.0h, solid ? 1.0h : 0.0h);
    // Only run the multi-tap neighborhood pass on blended edge pixels, which is ~30x more expensive than the fast path.
    if (!settled) {
        result = hostKeyEdge(picture, pictureSampler, st, style, raw, encoded, least, most, solid);
    }
    return result;
}

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
    float2 uv = in.uv / in.ahead;
    // Compute edge feathering so the foveal inset blends smoothly into the background quad.
    half feather = 1.0h;
    if (FEATHERED) {
        float2 tile = in.tile / in.ahead;
        float toEdge = min(min(tile.x, 1.0 - tile.x), min(tile.y, 1.0 - tile.y));
        feather = half(saturate(toEdge / style.feather));
    }
    if (HOST_KEY) {
        bool solid;
        half3 encoded;
        half4 hostKey = in.eye == 0 ? hostKeyed(atlas, atlasSampler, uv, style, solid, encoded)
                                    : hostKeyed(otherEyeAtlas, atlasSampler, uv, style, solid, encoded);
        // Dim passthrough behind the scene by blending toward premultiplied black (raising alpha while keeping RGB unchanged).
        half a = hostKey.a + half(style.keyRange.y) * (1.0h - hostKey.a);
        // Convert RGB to the render target's color space. Fully keyed pixels stay zero, opaque scene pixels convert
        // directly from `encoded` (at most one exact sRGB-to-linear conversion), and only edge pixels use `srgbNear`.
        half3 shown = half3(0.0h);
        if (solid) {
            shown = TARGET_LINEAR ? linearFromSRGB(encoded) : encoded;
        } else if (hostKey.a > 0.0h) {
            shown = TARGET_LINEAR ? hostKey.rgb : srgbNear(hostKey.rgb);
        }
        // Dual-source blending cross-fades the feathered foveal quad with the underlying base tile,
        // preserving combined passthrough opacity without adjusting the base tile's alpha.
        out.color = float4(half4(shown, a) * feather);
        out.cover = float4(feather);
        return out;
    }
    half3 color = half3(in.eye == 0 ? atlas.sample(atlasSampler, uv).rgb : otherEyeAtlas.sample(atlasSampler, uv).rgb);
    // When the texture was sampled as sRGB-encoded values, undo any host encoding gamma and convert to linear
    // light if required by the render target. When SAMPLED_LINEAR is true, the hardware sampler already linearized
    // the color and no encoding gamma is active.
    if (!SAMPLED_LINEAR) {
        if (GAMMA > 1.0) {
            color = hostGammaUndone(saturate(color));
        }
        if (TARGET_LINEAR) {
            color = linearFromSRGB(color);
        }
    }
    half4 colorOut = half4(color.rgb, 1.0);
    // A host that sends transparency sends it as a picture of its own,
    // whose brightness is how opaque the colors are; the colors come
    // already multiplied by it. Where nothing is opaque nothing is
    // drawn, and no depth: the room shows.
    half opacity = 1.0h;
    if (HAS_ALPHA) {
        float2 alphaUV = in.alphaUV / in.ahead;
        opacity = half(in.eye == 0 ? alpha.sample(atlasSampler, alphaUV).r : otherEyeAlpha.sample(atlasSampler, alphaUV).r);
        if (opacity < 0.02h) {
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
    half4 keyed = half4(colorOut.rgb * colorOut.a, colorOut.a * colorOut.a * opacity);

    // Scale premultiplied color and dual-source coverage by the feather weight to cross-fade over the underlying quad.
    out.color = float4(keyed * feather);
    out.cover = float4(feather * opacity);
    return out;
}
