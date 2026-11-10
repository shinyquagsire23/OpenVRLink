# Frame layout, foveation and the unwarp pass

The decoded picture is an **atlas** of per-eye tiles: for each eye a wide
"base" image and a narrow, sharper "foveal" inset. The client does not warp or
resample by any lens model: it crops each tile out of the atlas into its own
OpenXR swapchain and submits two projection layers (base, then fovea on top
with a feathered alpha edge). The compositor does the rest.

## Atlas modes

**static** - `QSVLRendererXR::FlipFrame` (+0x10ae78) picks the mode per frame
from `TransportFrameMetadata_t` ([frame-metadata.md](frame-metadata.md)):

```python
if atlas_h / tile_h > 3.0:   mode = 0      # four tiles stacked vertically
elif atlas_w / tile_w > 1.5: mode = 1      # 2 x 2
else:                        mode = 2      # two tiles stacked, no foveal layer
```

If `(tile_w, tile_h, mode)` differs from the current state the four swapchains
are recreated (`SetupSwapchains`, +0x10aa64: each `tile_w x tile_h`,
`GL_SRGB8_ALPHA8` 0x8c43; log `"[XRRenderer] Swapchains were regenerated"`).

Tile placement, from the two vertex shaders (text below) with
`group = eye*2` for the foveal pass and `group = eye*2 + 1` for the base pass
(`SRGBCorrectionPass::RenderSpecific`, +0xf19f4). `u`,`v` are texture
coordinates of the decoded image, v = 0 at the first decoded row:

| mode | left fovea | left base | right fovea | right base |
|---|---|---|---|---|
| 0 "4-way" | v 0..1/4 | v 1/4..1/2 | v 1/2..3/4 | v 3/4..1 |
| 1 "2x2" | u 1/2..1, v 0..1/2 | u 0..1/2, v 0..1/2 | u 1/2..1, v 1/2..1 | u 0..1/2, v 1/2..1 |
| 2 | not drawn | v 0..1/2 | not drawn | v 1/2..1 |

**captured** (`vr3`): metadata reads `atlas 1536 x 6144, tile 1536 x 1536` on
all 8,631 descriptors (4,260 frames), the SPS says 1536 x 6144, and every
access unit has four slices. So mode 0 is the one in use, top to bottom:
**left fovea, left base, right fovea, right base**, each 1536 x 1536. Modes 1
and 2 did not occur. The client logged `[XRRenderer] Swapchains were
regenerated` exactly once, at the first frame.

**captured** (`vr3`): the four slices are the four tiles. The CTB is 32 x 32,
so a tile is 48 x 48 = 2,304 CTBs, and the slice segment addresses are 0,
2304, 4608, 6912 in every one of the 4,260 access units
([decode-handoff.md](decode-handoff.md)). Deblocking across slice boundaries
is off in every slice header, and the decoded picture shows a hard cut at row
1536 with no guard band or bleed between tiles (zoomed crop of rows
1488..1584).

What the picture shows (**captured**: frames 300, 2000 and 4000 of `vr3` and
frames 200 and 1500 of the probe stream, decoded with ffmpeg to raw 10-bit YUV
and converted with numpy; the scene is the SteamVR dashboard with two
controllers in view):

- Tiles 0 and 2 are magnified central crops of tiles 1 and 3: fovea, base,
  fovea, base. The measurement is under "Field of view of each layer".
- **The first pair is the left eye.** Horizontal position in tile 1 minus
  position in tile 3, by normalized cross-correlation of luma patches (`vr3`
  frame 2000): far backdrop 0 px, dashboard panel (posters, clock) +47..+50
  px, both controllers +111 px. Nearer things sit further right in the first
  pair, growing with nearness, with 0 px vertical shift throughout - that is
  the left eye. In the fovea tiles the panel shift is +80..+81 px, which is
  the base shift times the density ratio minus the 21-pixel difference in
  `inset_x` (47 x 2.1445 - 21 = 80). This agrees with the static reading
  (`group = eye*2`) and with the first eye-to-head matrix the client
  published having x = -0.0315 m. **inferred** from the same numbers: with
  that 63 mm eye separation and 768 px per unit tangent, the panel is about
  1.0 m away and the controllers about 0.44 m.
- The fovea tiles are noticeably sharper than the same region of the base
  tiles, by more than the 2.14x density alone: the encoder gives the base
  slices a much coarser quantizer (slice QP 27 or 28 above the fovea slice's
  in 4,188 of 4,259 frames, [decode-handoff.md](decode-handoff.md)).
- The first frames are not picture: `vr3` frames 0..3 decode to a flat fill
  (10-bit Y 352..355, Cb 532..536, Cr 486..490 over the whole atlas); the
  dashboard starts with the second IDR at frame 4.

The quad is drawn with `vPos.y *= -1` ("Flip image"), so the first decoded row
of a tile lands on the bottom row of the GL framebuffer, i.e. the swapchain
image is stored top-row-first in the usual GL-upside-down sense. **inferred**:
this just undoes GL's origin; a Metal/Vulkan client copies rows straight.

## The pass

**static** - per served frame, `FlipFrame` does, with `GL_FRAMEBUFFER_SRGB`
disabled:

1. bind the decoded image as `GL_TEXTURE_EXTERNAL_OES`;
2. `RenderSpecific(eye=0, fovea=false)` into the left base swapchain;
3. `RenderSpecific(0, true)` into the left foveal swapchain;
4. `RenderSpecific(1, false)`, `RenderSpecific(1, true)` for the right eye;
5. write the frame's pose into all four `XrCompositionLayerProjectionView`s.

Each `RenderSpecific` clears to (0,0,0,0), sets the viewport to the tile size
and draws one 4-vertex triangle strip. Layers are returned base first, fovea
second (`GetProjectionLayers`, +0x10a570).

### Uniforms

| Location | Name | Value |
|---|---|---|
| 2 | `tex0` (`samplerExternalOES`) | decoded frame |
| 3 | `fFadeAmount` | `Fader::GetCurrentFadeAmount()` - 0..1 fade in/out |
| 4, 5 | `UniReserved1/2` | unused |
| 6 | `UniDitherOffsets` | set only when a flag is on; the dither line is commented out in the shader |
| 12 | `group` | `eye*2` (fovea shader) or `eye*2 + 1` (base shader) |
| 13 | `mode` | atlas mode 0/1/2 |

There are no per-frame foveation uniforms: the per-frame inset position only
changes the *FOV submitted with the foveal layer* (below), never the crop.

### Vertex shader, base (string at file offset 0x9da82)

```glsl
uv = vec2(gl_VertexID & 1, gl_VertexID >> 1);
vec2 vPos = (uv - 0.5) * 2.;
vPos.y *= -1.0; // Flip image.
gl_Position = vec4(vPos, 0, 1);
if( mode > 1.5 )      { uv.y = (uv.y + group * .5) * 0.5 - .25; }
else if( mode > 0.5 ) { uv.y = (uv.y + group*0.5) * 0.5 - 0.25; uv.x = uv.x * 0.5; }   // 2x2
else                  { uv.y = (uv.y + group) * 0.25; }                               // 4-way
```

### Vertex shader, fovea (0xac6f9)

```glsl
uvmask = uv;
if( mode > 1.5 )      { gl_Position = vec4( 0.0, 0.0, 0.0, 1.0 ); }
else if( mode > 0.5 ) { uvmask = uv * vec2( 1.0, 0.25 ); uv.y = (uv.y + group*0.5) * 0.5; uv.x = uv.x * 0.5 + 0.5; }
else                  { uvmask = uv * vec2( 1.0, 0.25 ); uv.y = (uv.y + group) * 0.25; }
```

### Fragment shader (0x9b3ca, plus one of two tails)

```glsl
color = texture(tex0, uv);
mat3 _valve1_d2020d709 = mat3(
     1.04988847,  0.05442289,  0.00393458,
    -0.04433306,  0.96052738,  0.01122383,
    -0.005557,   -0.01509698,  0.98628952 );
color.rgb = _valve1_d2020d709 * color.rgb;
color.rgb *= fFadeAmount;
// base tail (0x9d182):
color.a = 1.0;
// fovea tail (0xa6503):
vec2 placeInSection = fract(uvmask * vec2( 1.0, 4.0 ));
vec2 distCenter = abs( placeInSection - 0.5 );
color.a = pow( 1.05 - (pow( distCenter.y*2.0, 10.0 ) + pow( distCenter.x*2.0, 10.0 )) * 1.06, 1.5 );
```

- The foveal alpha is a super-ellipse feather: 1 over most of the tile, falling
  to 0 at the edges, so the inset blends into the base layer.
- **captured** (`vr3` frame 2000): the feather exists only in this shader. The
  encoded fovea tile carries full-strength picture right up to its last row
  and column: the ratio of fovea luma to the matching base luma is 0.98..1.00
  in every band from 0..2 px to 256..768 px from the tile edge, for both eyes,
  with no fall-off, and zoomed corner crops show ordinary scene content at the
  border. A client has to apply the alpha itself.
- **inferred**: which tail belongs to which program follows from `uvmask` only
  existing in the fovea vertex shader; the string concatenation itself was not
  traced.
- Color: the decoder is configured BT.2020 / full range / P010 and the
  sampler delivers RGB; the 3x3 (GLSL column-major, so the first three numbers
  are the first column) is a small gamut correction; the result is written
  unconverted into an sRGB swapchain with sRGB encoding disabled. The shader has no YUV->RGB
  step; the external sampler does that.
- **captured** (`vr3` and the probe stream, SPS VUI): full range, primaries 9
  (BT.2020), transfer 4 (gamma 2.2), and **matrix_coefficients 0** (identity /
  GBR). The first three back the earlier inference that the video is
  display-referred and gamma-encoded, not linear. The matrix code cannot be
  taken literally: the stream is 4:2:0 and the planes are ordinary
  luma/chroma (converting them as Y'CbCr gives the dashboard in its expected
  colors; a flat frame has Cb and Cr near but not at 512). So the VUI does
  **not** say which Y'CbCr matrix to use. The client's MediaFormat asks for
  BT.2020, which on Android selects the BT.2020 matrix; converting with
  BT.2020 or BT.709 coefficients both give a plausible picture and they
  cannot be told apart by eye on this scene. Use BT.2020 non-constant
  luminance, full range, as the client declares, until a test pattern says
  otherwise.
- The 3x3 has rows summing to 1.000, 1.000, 1.001, so it leaves white alone;
  its diagonal is 1.05, 0.96, 0.99, nowhere near a BT.2020-to-BT.709
  conversion (diagonal 1.66, 1.13, 1.12). It is a small fixed adjustment and not a
  gamut conversion. **captured** (`vr3` logcat): the client asked the runtime
  for `XR_FB_color_space` value 3 and logged `Failed to find requested color
  space 3`, then `VTE_PROP_COLOR_CONTROL updated` / `Updating color props`.
  **inferred**: the matrix is tied to that color-space choice; what the
  client does when the request succeeds was not seen.
- The constants `DIV12`, `DIV1`, `THRESHOLD`, `GAMMA` are declared in the
  fragment shader and unused: no sRGB<->linear conversion happens here.

## Field of view of each layer

**static** - `FlipFrame`. Base layer: the per-eye `XrFovf` derived from the
metadata projection matrix. Foveal layer: computed from the base FOV and the
per-eye inset record `{inset_x, inset_y, virt_w, virt_h}` (metadata +0xc8,
i16 each). Read it as: *imagine the base frustum rendered at foveal pixel
density; that virtual image is `virt_w x virt_h` pixels; the inset tile is the
`tile_w x tile_h` rectangle whose top-left corner is at `(inset_x, inset_y)`
in it.* (**inferred** wording; the arithmetic is static.)

```python
tl, tr, tu, td = tan(base.left), tan(base.right), tan(base.up), tan(base.down)   # tl, td negative

# vertical: T = rows from the top of the virtual image to the optical center
T = tu * virt_h / (tu - td)
fovea.up   = atan(tu * (T - inset_y)            / T)
fovea.down = atan(tu * (T - (inset_y + tile_h)) / T)

# horizontal: S = columns from the optical center to the right edge
S = tr * virt_w / (tr - tl)
fovea.left  = atan(tr * (inset_x - virt_w + S)          / S)
fovea.right = atan(tr * (inset_x + tile_w - virt_w + S) / S)
```

**captured** values (`vr3`: identical on all 4,260 frames; the same numbers as
in `vr1`): left `(889, 1043, 3294, 3294)`, right `(868, 1043, 3294, 3294)`,
tiles 1536. With the symmetric +-45 degree frustum that run's matrices carry
(the client published tangents -1, 1, -1, 1 for both eyes), the left inset
spans columns 889..2425 of 3294 (center 1657 vs 1647) and rows 1043..2579
(center 1811 vs 1647) - a 1536-pixel window on a 3294-pixel virtual eye, i.e.
the fovea has 2.1445x the linear pixel density of the base tile. The formulas
give the fovea layer left -24.7, right +25.3, up +20.1, down -29.5 degrees
(right eye: -25.3, +24.7 horizontally). So the inset is not centered: it sits
about 5.7 degrees below the optical axis, and each eye's is nudged about 0.35
degrees toward the nose. The values did not move during the run (no eye
tracking in that setup).

**captured** (`vr3`, Klepton's OpenXR layer log): the client submitted two
projection layers, `fov 90x90 deg, 1536x1536 px` then `fov 50x50 deg,
1536x1536 px`, which is what the formulas give (49.99 x 49.65 degrees).

**captured**, measured in the picture: the inset record describes exactly
which part of the base tile the fovea tile shows. In base-tile pixels the
record predicts that fovea pixel `f` lands at `(inset + f) * 1536 / 3294`:
scale 0.46630, offset (414.54, 486.35) for the left eye and (404.75, 486.35)
for the right, i.e. the rectangle x 415..1131, y 486..1203 of the left base
tile. A least-squares fit of the luma of the fovea tile onto the base tile
(scale and offset free, bilinear sampling, started 3 px off the prediction)
gives:

| frame | eye | scale | offset x, y | implied `inset_x, inset_y, virt` |
|---|---|---|---|---|
| `vr3` 2000 | left | 0.46625 | 414.54, 486.38 | 889.1, 1043.2, 3294.4 |
| `vr3` 2000 | right | 0.46637 | 404.71, 486.27 | 867.8, 1042.7, 3293.5 |
| `vr3` 4000 | left | 0.46625 | 414.54, 486.38 | 889.1, 1043.2, 3294.4 |
| `vr3` 4000 | right | 0.46637 | 404.71, 486.27 | 867.8, 1042.7, 3293.6 |
| probe 1500 | left | 0.46624 | 414.55, 486.37 | 889.1, 1043.2, 3294.4 |
| probe 1500 | right | 0.46638 | 404.69, 486.27 | 867.7, 1042.6, 3293.5 |

That is within 0.1 base pixel and 1 part in 5,000 of scale. Letting the
horizontal and vertical scales differ changes neither by more than 0.0002, so
the mapping is a plain uniform scale and shift, as two pinhole views from one
eye point should be. (The probe session's own metadata was not re-read; its
picture fits the same record.) This confirms the reading of the record given
above, including that `inset_x, inset_y` are the top-left corner counted from
the top-left of the virtual image, and fixes the foveal FOV formulas'
geometry for a symmetric frustum. An asymmetric frustum has not been seen.

The pose written to all four views is the frame's render pose
([frame-metadata.md](frame-metadata.md)); the `subImage` rect is the whole
swapchain.

## Open questions / to confirm on the wire

Settled by `vr3`: tile order and which eye is first (left; disparity), the
four slices are the four tiles, the feather is client-side only, and the
inset record matches the picture.

1. Whether mode 1 or mode 2 ever occur (other headsets, foveation disabled).
   Not in `vr3`.
2. Whether `inset_x/inset_y` change at run time with eye tracking. Constant
   over `vr3`, which had no eye tracking.
3. Which Y'CbCr matrix the host encodes with. The VUI says identity, which
   cannot be true of a 4:2:0 stream; BT.2020 and BT.709 both look plausible.
   A known test pattern (pure primaries on the host desktop) would settle it.
4. What the 3x3 is for, and what changes when the runtime accepts the
   requested `XR_FB_color_space` (it was refused under Klepton).
5. The foveal FOV formulas with an asymmetric base frustum (only the symmetric
   +-45 degree case has been measured).
6. Both eyes receive the same pose - see the open item in frame-metadata.md.
   The picture does have stereo disparity, so the host renders the two eyes
   from separated positions.


## Probe results (2026-11-10)

A frame from the probe's saved stream, decoded with ffmpeg, shows the SteamVR
dashboard four times down the 1536x6144 atlas: a magnified central crop, the
full view, then the same pair again. That is fovea then base for one eye, then
fovea then base for the other - the tile order above is now **captured**.
Which eye is first is still static only (a motionless head and a dashboard at
a distance give too little disparity to tell from one frame).

## Client results (2026-11-10): an asymmetric frustum, on a headset

The visionOS client published each eye's real frustum from an Apple Vision
Pro - left eye tangents left -1.73, right 1.00, down -1.19, up 1.00 (the
right eye mirrored) - and an IPD of about 65 mm, and composed the base and
foveal tiles with the formulas above. Seen in the headset by the project
owner: stereo is correct and the picture is sharp in the center with no
visible seam. So the host renders asymmetric frusta as given, the tile order
(left fovea, left base, right fovea, right base) holds on a real stereo
display, and the foveal frustum formulas hold for an asymmetric base
(open question 5 above), by eye rather than by measurement.

## Client results (2026-11-10): a rotated eye

**Captured by client** (`client` on macOS against the real host): the
host honors the rotation part of `VTE_EYE_TO_HEAD` (0x08). Two sessions,
the same motionless head, the left eye published once facing straight ahead
and once turned 15 degrees to the left, with the same frustum both times. The
client places the base tile from "render pose, then the eye's published pose
in the head". In the second session the scene stayed exactly where it was in
the world and the tile's outline turned 15 degrees with the eye: the host had
rendered through the turned eye. Had the host ignored the rotation, the scene
would have moved 15 degrees with the tile.

So a headset with canted displays should publish each eye's real orientation
and the frustum measured about that eye's own axes, and the client must
place the tiles with the same orientation. The earlier headset run published
identity rotations with frusta measured about canted axes; that is
self-consistent (the host rendered a cone aimed straight ahead and the client
showed it straight ahead) but covers the wrong part of each display.

## Client results (2026-11-10): asymmetric frusta and eye spacing, measured

**Captured by client** (`client` on macOS; the centroid of a
controller model drawn by SteamVR Home at a fixed pose about 0.5 m from a
motionless head, in a 1800-pixel window spanning tangents -1..1):

| published | centroid, pixels |
|---|---|
| symmetric +-1 frusta, eyes 63 mm apart (twice) | 1376.9, 1407.6 both times |
| left eye -1.73 / 1.0 / -1.19 / 1.0, right eye mirrored | 1377.3, 1406.7 |
| left eye -1.0 / 1.73 / -1.0 / 1.19, right eye mirrored | 1377.1, 1406.8 |
| symmetric, eyes 126 mm apart | 1433.3, 1404.2 |

The host renders through exactly the frustum it is given, asymmetric or not
(the model stays within a pixel when the tile is placed by the same
tangents), and uses the published eye spacing (moving the left eye 31.5 mm
further left shifts the model 56 pixels, 0.063 in tangent, which is 31.5 mm
seen from 0.50 m).

## Headset result (2026-11-10): do not publish turned eyes

With the Vision Pro's real eye rotations published (each display about 0.5
degrees outwards and 1.2 up), the wearer saw host-drawn hands sit further
away than the real ones, more so with distance, in a game; markers drawn by
the client at the same tracked points sat exactly on the real hands, so
tracking and display were right and the picture's stereo was wrong. In
SteamVR's own empty scene the hands lined up much better.

**inferred** (the known cause of the same symptom on other canted headsets,
where it is worked around with "parallel projection"): the host and SteamVR
honor eye rotation, as measured above, but many applications render as if
the eyes were parallel. A degree of lost convergence moves a hand at half a
meter about a fifth further away. `client` now publishes eyes facing
straight ahead, with each frustum widened to enclose the turned display's
(`Frustum.enclosing`), and draws the picture through the real turned views.
Reported by the wearer: with parallel eyes the picture renders fine and the
hands line up in the same game, on a fresh SteamVR start and on a rejoin.
