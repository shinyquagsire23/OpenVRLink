// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shaders used by `StereoShrink.swift` to downsample decoded video tiles into
// single-channel luma textures and run multi-scale stereo patch matching on the GPU.
// Struct layouts (`Corner` and `MatchSettings`) are packed manually in `StereoShrink.swift`.

#include <metal_stdlib>
using namespace metal;

// `position` is clip-space XY (`-1...1`) in the downsampled target, `uv` is the
// normalized texture coordinate in the source image, and `bounds` clamps UVs
// (`minU, minV, maxU, maxV`) to keep bilinear filtering inside the tile.
struct Corner { float2 position; float2 uv; float4 bounds; };
struct Piece { float4 position [[position]]; float2 uv; float4 bounds [[flat]]; };

vertex Piece shrinkVertex(uint index [[vertex_id]], const device Corner *corners [[buffer(0)]]) {
    Piece out;
    out.position = float4(corners[index].position, 0.0, 1.0);
    out.uv = corners[index].uv;
    out.bounds = corners[index].bounds;
    return out;
}

// Hardware YCbCr samplers return RGB. Because each output pixel spans several
// source pixels, average a 2x2 grid of bilinear samples (clamped to the tile's
// UV bounds so adjacent atlas tiles don't bleed in) and convert to Rec. 709 luma.
fragment float4 shrinkFragment(Piece in [[stage_in]], texture2d<float> picture [[texture(0)]],
                               sampler pictureSampler [[sampler(0)]]) {
    float2 across = dfdx(in.uv) * 0.25, down = dfdy(in.uv) * 0.25;
    float3 sum = float3(0.0);
    for (int i = 0; i < 4; i++) {
        float2 at = in.uv + (i % 2 == 0 ? -across : across) + (i < 2 ? -down : down);
        sum += picture.sample(pictureSampler, clamp(at, in.bounds.xy, in.bounds.zw)).rgb;
    }
    float brightness = dot(sum * 0.25, float3(0.2126, 0.7152, 0.0722));
    return float4(brightness, 0.0, 0.0, 1.0);
}

// GPU implementation of `StereoMatcher.measure` (`VRLinkCore/StereoDepth.swift`),
// dispatching one thread per `(column, row)` grid cell. Keep matching math in sync
// with `StereoMatcher`. All fields are passed as `float` from `StereoShrink.swift`.
struct MatchSettings {
    // Mipmap `level` to sample (`halvings`) and vertical row offset (`firstRow`) in `found`.
    float level, firstRow;
    float columns, rows, reach, stride, most;
    float leftFirstX, leftEndX, leftFirstY, leftEndY;
    float rightFirstX, rightEndX, rightFirstY, rightEndY;
    float pixelsPerNearness, grain, least, full;
};

// Upper bound on tested pixel disparities; `StereoShrink.swift` clamps `most` to this limit.
constant int MOST_SHIFTS = 160;

kernel void matchCells(texture2d<float, access::read> left [[texture(0)]],
                       texture2d<float, access::read> right [[texture(1)]],
                       texture2d<float, access::write> found [[texture(2)]],
                       constant MatchSettings &s [[buffer(0)]],
                       uint2 cell [[thread_position_in_grid]]) {
    int columns = int(s.columns), rows = int(s.rows);
    if (int(cell.x) >= columns || int(cell.y) >= rows) { return; }
    uint level = uint(s.level);
    uint2 answer = uint2(cell.x, cell.y + uint(s.firstRow));
    // Initialize output `(nearness, trust)` to zero before testing disparities.
    found.write(float4(0.0), answer);
    int width = int(left.get_width(level)), height = int(left.get_height(level));
    int reach = int(s.reach), stride = max(1, int(s.stride)), most = min(int(s.most), MOST_SHIFTS);
    int cy = int((float(cell.y) + 0.5) / float(rows) * float(height));
    int cx = int((float(cell.x) + 0.5) / float(columns) * float(width));
    if (cy - reach < int(max(s.leftFirstY, s.rightFirstY)) || cy + reach >= int(min(s.leftEndY, s.rightEndY))) { return; }

    float costs[MOST_SHIFTS + 1];
    int best = -1;
    for (int shift = 0; shift <= most; shift++) {
        costs[shift] = INFINITY;
        // Split integer disparity `shift` symmetrically around the cyclopean cell center.
        int lx = cx + (shift + 1) / 2, rx = cx - shift / 2;
        if (lx - reach < int(s.leftFirstX) || lx + reach >= int(s.leftEndX)
            || rx - reach < int(s.rightFirstX) || rx + reach >= int(s.rightEndX)) { continue; }
        float sumLeft = 0.0, sumRight = 0.0, compared = 0.0;
        for (int dy = -reach; dy <= reach; dy += stride) {
            for (int dx = -reach; dx <= reach; dx += stride) {
                sumLeft += round(left.read(uint2(lx + dx, cy + dy), level).r * 255.0);
                sumRight += round(right.read(uint2(rx + dx, cy + dy), level).r * 255.0);
                compared += 1.0;
            }
        }
        // Subtract each patch's mean luma so per-eye brightness differences cancel out.
        float meanLeft = sumLeft / compared, meanRight = sumRight / compared;
        float unlike = 0.0, variedLeft = 0.0, variedRight = 0.0;
        for (int dy = -reach; dy <= reach; dy += stride) {
            for (int dx = -reach; dx <= reach; dx += stride) {
                float a = round(left.read(uint2(lx + dx, cy + dy), level).r * 255.0) - meanLeft;
                float b = round(right.read(uint2(rx + dx, cy + dy), level).r * 255.0) - meanRight;
                unlike += abs(a - b);
                variedLeft += abs(a);
                variedRight += abs(b);
            }
        }
        // Zero-mean SAD normalized by mean patch contrast plus `grain`.
        costs[shift] = (unlike / compared) / ((variedLeft + variedRight) / (2.0 * compared) + s.grain);
        if (best < 0 || costs[shift] < costs[best]) { best = shift; }
    }
    if (best < 0) { return; }
    // Require a clear margin below the mean shift cost and no close non-adjacent competitor.
    float total = 0.0, rival = INFINITY;
    int tried = 0;
    for (int shift = 0; shift <= most; shift++) {
        if (isinf(costs[shift])) { continue; }
        total += costs[shift];
        tried += 1;
        if (abs(shift - best) > 2) { rival = min(rival, costs[shift]); }
    }
    if (tried < 4) { return; }
    float margin = total / float(tried) - costs[best];
    if (!(margin > s.least) || !(rival - costs[best] > 0.35 * margin)) { return; }
    // Parabolic sub-pixel refinement using the two neighboring shift costs.
    float shift = float(best);
    if (best > 0 && best < most && !isinf(costs[best - 1]) && !isinf(costs[best + 1])) {
        float before = costs[best - 1], after = costs[best + 1], bend = before + after - 2.0 * costs[best];
        if (bend > 1e-6) { shift += clamp((before - after) / (2.0 * bend), -0.5, 0.5); }
    }
    found.write(float4(max(0.0, shift) / s.pixelsPerNearness, min(1.0, (margin - s.least) / (s.full - s.least)), 0.0, 0.0), answer);
}
