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
struct Vertex { float4 position[2]; float2 uv[2]; float2 alphaUV[2]; float2 tile; };
struct Fragment { float4 position [[position]]; float2 uv; float2 alphaUV; float2 tile; uint eye [[flat]]; };

// With vertex amplification every triangle is drawn once per eye, and
// amplification_id says which eye this copy is for.
vertex Fragment vertexMain(uint index [[vertex_id]], ushort eye [[amplification_id]],
                           const device Vertex *vertices [[buffer(0)]]) {
    Fragment out;
    out.position = vertices[index].position[eye];
    out.uv = vertices[index].uv[eye];
    out.alphaUV = vertices[index].alphaUV[eye];
    out.tile = vertices[index].tile;
    out.eye = eye;
    return out;
}

// The atlas texture has a YCbCr pixel format whose sampler returns RGB,
// so there is no color conversion here.
// keyColor is in the same light as the sampled picture; keyRange is
// the near and far blend distances.
// hasAlpha: the frame has a picture of transparency (not zero), or is opaque.
struct QuadStyle { float feather; float hasAlpha; float4 fill; float4 keyColor; float2 keyRange; };

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
    half3 color = in.eye == 0 ? half3(atlas.sample(atlasSampler, in.uv).rgb)
                              : half3(otherEyeAtlas.sample(atlasSampler, in.uv).rgb);
    half4 colorOut = half4(color.rgb, 1.0);
    // A host that sends transparency sends it as a picture of its own,
    // whose brightness is how opaque the colors are; the colors come
    // already multiplied by it. Where nothing is opaque nothing is
    // drawn, and no depth: the room shows.
    float opacity = 1.0;
    if (style.hasAlpha != 0.0) {
        opacity = in.eye == 0 ? alpha.sample(atlasSampler, in.alphaUV).r : otherEyeAlpha.sample(atlasSampler, in.alphaUV).r;
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
    float toEdge = min(min(in.tile.x, 1.0 - in.tile.x), min(in.tile.y, 1.0 - in.tile.y));
    float feather = style.feather > 0.0 ? saturate(toEdge / style.feather) : 1.0;
    out.color = keyed * feather;
    out.cover = float4(feather * opacity);
    return out;
}
