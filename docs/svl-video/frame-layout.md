# Frame layout, foveation, and the unwarp pass

The decoded video picture is an **atlas** of per-eye tiles containing a wide
"base" view and a narrower, higher-resolution "foveal" inset for each eye.
Rather than applying lens distortion on the client, `vrlink` crops each tile
out of the atlas into its own OpenXR swapchain and submits two
`XrCompositionLayerProjection` layers—the base layer underneath and the foveal
inset on top with a feathered alpha edge—leaving lens warp and reprojection to
the OpenXR compositor.

## Atlas modes

`QSVLRendererXR::FlipFrame` (+0x10ae78) selects the atlas mode on each frame
from `TransportFrameMetadata_t` ([frame-metadata.md](frame-metadata.md),
**static**):

```python
if atlas_h / tile_h > 3.0:   mode = 0      # four tiles stacked vertically
elif atlas_w / tile_w > 1.5: mode = 1      # 2 x 2
else:                        mode = 2      # two tiles stacked, no foveal layer
```

Whenever `(tile_w, tile_h, mode)` changes from the current swapchain state, all
four swapchains are recreated (`SetupSwapchains`, +0x10aa64: each `tile_w x
tile_h`, `GL_SRGB8_ALPHA8` `0x8c43`, logging `"[XRRenderer] Swapchains were
regenerated"`).

The two vertex shaders (shown below) map atlas regions using `group = eye*2`
for the foveal pass and `group = eye*2 + 1` for the base pass
(`SRGBCorrectionPass::RenderSpecific`, +0xf19f4). Below, `u` and `v` are
normalized texture coordinates of the decoded image, with `v = 0` at the first
decoded row:

| mode | left fovea | left base | right fovea | right base |
|---|---|---|---|---|
| 0 "4-way" | v 0..1/4 | v 1/4..1/2 | v 1/2..3/4 | v 3/4..1 |
| 1 "2x2" | u 1/2..1, v 0..1/2 | u 0..1/2, v 0..1/2 | u 1/2..1, v 1/2..1 | u 0..1/2, v 1/2..1 |
| 2 | not drawn | v 0..1/2 | not drawn | v 1/2..1 |

**captured** (`vr3`): metadata reports `atlas 1536 x 6144, tile 1536 x 1536` on
all 8,631 descriptors (4,260 frames), the SPS specifies `1536 x 6144`, and
every access unit contains four slices. Mode 0 is used throughout, ordered from
top to bottom as **left fovea, left base, right fovea, right base**, each
`1536 x 1536`. Modes 1 and 2 did not occur. `vrlink` logged `[XRRenderer]
Swapchains were regenerated` once, on the first frame.

**captured** (`vr3`): the four HEVC slices correspond directly to the four
tiles. With a `32 x 32` CTB, each tile spans `48 x 48 = 2,304` CTBs, and the
slice segment addresses are `0`, `2304`, `4608`, and `6912` in all 4,260 access
units ([decode-handoff.md](decode-handoff.md)). Deblocking across slice
boundaries is disabled in every slice header, and the decoded image has a clean
cut at row 1536 with no guard band or cross-tile bleed (verified on a zoomed
crop of rows `1488..1584`).

Inspecting decoded frames (**captured**: frames 300, 2000, and 4000 of `vr3`
plus frames 200 and 1500 of the probe stream, decoded with `ffmpeg` to raw
10-bit YUV and converted with `numpy`; the scene shows the SteamVR dashboard
with two controllers in view) confirms the tile assignments:

- Tiles 0 and 2 are magnified central crops of tiles 1 and 3 (fovea, base,
  fovea, base); quantitative measurements are under "Field of view of each
  layer" below.
- **The first tile pair belongs to the left eye.** Measuring horizontal feature
  positions in tile 1 minus tile 3 via normalized cross-correlation of luma
  patches (`vr3` frame 2000) gives `0 px` on the far backdrop, `+47..+50 px` on
  the dashboard panel (posters and clock), and `+111 px` on both controllers,
  with `0 px` vertical shift throughout. Closer objects shift further right in
  the first pair in proportion to proximity, matching left-eye parallax. In the
  foveal tiles, the panel shift is `+80..+81 px`, matching the base shift
  multiplied by the pixel-density ratio minus the 21-pixel difference in
  `inset_x` (`47 * 2.1445 - 21 = 80`). This agrees with both the static shader
  indexing (`group = eye*2`) and `vrlink`'s first published eye-to-head matrix
  (`x = -0.0315 m`). **inferred**: given a 63 mm eye separation and 768 px per
  unit tangent, the dashboard panel sits roughly 1.0 m away and the controllers
  sit roughly 0.44 m away.
- Foveal tiles are substantially sharper than the corresponding region of the
  base tiles, beyond what the `2.14x` pixel-density increase provides on its
  own: the host encoder assigns a much coarser quantizer to the base slices
  (slice QP 27 or 28 steps above the foveal slice in 4,188 of 4,259 frames; see
  [decode-handoff.md](decode-handoff.md)).
- Frames `0..3` of `vr3` decode to a solid gray fill (`10-bit` Y `352..355`,
  Cb `532..536`, Cr `486..490` across the whole atlas); the rendered dashboard
  scene begins on the second IDR at frame 4.

The vertex shader flips `vPos.y *= -1` (`"Flip image"`), placing the first
decoded row of each tile at the bottom row of the OpenGL framebuffer so the
swapchain image is stored top-row-first in OpenGL's bottom-up convention.
**inferred**: this compensates for OpenGL's origin, so a Metal or Vulkan client
copies rows without flipping.

## Render pass and shaders

For each served frame, `FlipFrame` disables `GL_FRAMEBUFFER_SRGB` and performs
five steps (**static**):

1. Bind the decoded image as `GL_TEXTURE_EXTERNAL_OES`.
2. Call `RenderSpecific(eye=0, fovea=false)` into the left base swapchain.
3. Call `RenderSpecific(0, true)` into the left foveal swapchain.
4. Call `RenderSpecific(1, false)` and `RenderSpecific(1, true)` for the right
   eye.
5. Copy the frame's render pose into all four
   `XrCompositionLayerProjectionView` structs.

Each `RenderSpecific` call clears to `(0, 0, 0, 0)`, sets the viewport to the
tile dimensions, and draws a 4-vertex triangle strip. `GetProjectionLayers`
(+0x10a570) returns the base layer first and the foveal layer second.

### Uniforms

| Location | Name | Value |
|---|---|---|
| 2 | `tex0` (`samplerExternalOES`) | decoded frame |
| 3 | `fFadeAmount` | `Fader::GetCurrentFadeAmount()` - 0..1 fade in/out |
| 4, 5 | `UniReserved1/2` | unused |
| 6 | `UniDitherOffsets` | set only when a flag is on; the dither line is commented out in the shader |
| 12 | `group` | `eye*2` (fovea shader) or `eye*2 + 1` (base shader) |
| 13 | `mode` | atlas mode 0/1/2 |

There are no per-frame foveation uniforms: per-frame inset coordinates adjust
only the *FOV submitted on the foveal layer* (below), never the shader crop.

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

- The foveal alpha mask is a super-ellipse feather that stays near `1` across
  most of the tile and drops to `0` at the border so the inset blends smoothly
  over the base layer.
- **captured** (`vr3` frame 2000): feathering happens entirely in this client
  shader. The encoded foveal tile carries unattenuated scene content right up
  to its outer pixel row and column: the ratio of foveal luma to matching base
  luma stays at `0.98..1.00` across every distance band from `0..2 px` to
  `256..768 px` from the tile edge in both eyes with no falloff, and zoomed
  corner crops show normal scene detail at the boundary. Every client must
  apply its own edge alpha mask.
- **inferred**: pairing each fragment tail with its vertex shader follows from
  `uvmask` being written only by the foveal vertex shader; the C++ shader
  string assembly itself was not traced.
- `vrlink` configures the decoder for BT.2020, full range, and P010 output, and
  the `samplerExternalOES` sampler converts Y'CbCr to RGB before the fragment
  shader runs. The shader multiplies RGB by the column-major 3x3 matrix above
  (the first three floats are column 0) and writes the result unconverted into
  an sRGB swapchain with `GL_FRAMEBUFFER_SRGB` disabled.
- **captured** (`vr3` and the probe stream, SPS VUI): full range, primaries `9`
  (BT.2020), transfer `4` (gamma 2.2), and **`matrix_coefficients = 0`**
  (`identity` / GBR). The first three fields match the earlier inference that
  the video is display-referred and gamma-encoded rather than linear. The
  `identity` matrix code cannot be used literally: the stream is 4:2:0 and its
  planes contain standard luma and chroma (converting them as Y'CbCr produces
  the SteamVR dashboard in its expected colors, and flat frames have Cb and Cr
  near 512). Because the VUI omits a valid Y'CbCr matrix, `vrlink`'s
  MediaFormat request for BT.2020 (which selects the BT.2020 Y'CbCr matrix on
  Android) is the only indication of which matrix to apply; decoding this scene
  with either BT.2020 or BT.709 coefficients looks visually plausible and
  indistinguishable by eye. Clients should use BT.2020 non-constant luminance,
  full range (matching `vrlink`'s MediaFormat) until a color-bar test pattern
  is measured.
- The 3x3 shader matrix has row sums `1.000`, `1.000`, and `1.001` (preserving
  neutral white) and diagonal entries `1.05`, `0.96`, and `0.99`, which is much
  smaller than a full BT.2020-to-BT.709 gamut conversion (diagonal `1.66`,
  `1.13`, `1.12`) and acts instead as a minor color trim. **captured** (`vr3`
  logcat): `vrlink` requested `XR_FB_color_space` value `3` from the runtime
  and logged `Failed to find requested color space 3`, followed by
  `VTE_PROP_COLOR_CONTROL updated` and `Updating color props`. **inferred**:
  this 3x3 matrix corresponds to that target color space; `vrlink`'s behavior
  when the runtime accepts color space `3` was not observed.
- Constants `DIV12`, `DIV1`, `THRESHOLD`, and `GAMMA` are declared in the
  fragment shader source without being referenced, so no sRGB-to-linear
  conversion occurs in the shader.

## Field of view of each layer

In `FlipFrame` (**static**), the base layer uses the per-eye `XrFovf` derived
from the metadata projection matrix, while the foveal layer's `XrFovf` is
computed from that base FOV and the per-eye inset record `{inset_x, inset_y,
virt_w, virt_h}` (`i16` each at metadata `+0xc8`). Geometrically (**inferred**
interpretation of the **static** math below), if the full base frustum were
rendered at foveal pixel density it would span `virt_w x virt_h` pixels, and
the foveal tile is the `tile_w x tile_h` sub-rectangle whose top-left corner
sits at `(inset_x, inset_y)` within that virtual image:

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

In `vr3` (**captured**; identical across all 4,260 frames and matching `vr1`),
the inset records are `(889, 1043, 3294, 3294)` for the left eye and `(868,
1043, 3294, 3294)` for the right eye, with `1536 x 1536` tiles. With the
symmetric +/-45 degree frustum in that capture (`vrlink` published tangents
`-1, 1, -1, 1` for both eyes), the left inset covers columns `889..2425` of
`3294` (center `1657` vs. `1647`) and rows `1043..2579` (center `1811` vs.
`1647`)—a 1536-pixel window inside a 3294-pixel virtual eye, giving the foveal
tile `2.1445x` the linear pixel density of the base tile. Plugging these values
into the formulas yields a left foveal FOV of left `-24.7`, right `+25.3`, up
`+20.1`, down `-29.5` degrees (and `-25.3`, `+24.7` horizontally for the right
eye). Rather than sitting centered on the optical axis, the inset is shifted
about 5.7 degrees downward and nudged about 0.35 degrees toward the nose in
each eye. These values remained constant throughout `vr3` (which had no eye
tracking).

**captured** (`vr3`, Klepton OpenXR layer log): `vrlink` submitted two
projection layers—`fov 90x90 deg, 1536x1536 px` followed by `fov 50x50 deg,
1536x1536 px`—matching the formula output (`49.99 x 49.65` degrees).

Measuring the decoded pixels directly (**captured**) confirms that the inset
record describes the exact region of the base tile shown in the foveal tile. In
base-tile pixel coordinates, the record predicts that foveal pixel `f` maps to
`(inset + f) * 1536 / 3294`: a scale of `0.46630` and an offset of `(414.54,
486.35)` for the left eye and `(404.75, 486.35)` for the right eye, spanning
`x = 415..1131, y = 486..1203` of the left base tile. Fitting the foveal tile's
luma onto the base tile via least squares (free scale and offset, bilinear
sampling, initialized 3 px away from the prediction) yields:

| frame | eye | scale | offset x, y | implied `inset_x, inset_y, virt` |
|---|---|---|---|---|
| `vr3` 2000 | left | 0.46625 | 414.54, 486.38 | 889.1, 1043.2, 3294.4 |
| `vr3` 2000 | right | 0.46637 | 404.71, 486.27 | 867.8, 1042.7, 3293.5 |
| `vr3` 4000 | left | 0.46625 | 414.54, 486.38 | 889.1, 1043.2, 3294.4 |
| `vr3` 4000 | right | 0.46637 | 404.71, 486.27 | 867.8, 1042.7, 3293.6 |
| probe 1500 | left | 0.46624 | 414.55, 486.37 | 889.1, 1043.2, 3294.4 |
| probe 1500 | right | 0.46638 | 404.69, 486.27 | 867.7, 1042.6, 3293.5 |

All fits agree within `0.1` base pixel and 1 part in 5,000 of scale. Allowing
independent horizontal and vertical scales shifts neither by more than
`0.0002`, confirming a uniform scale and translation as expected for two
pinhole projections sharing an eye position. (The probe stream's metadata was
not re-read separately, and its pixels match the same inset geometry.) This
verifies that `(inset_x, inset_y)` is measured from the top-left corner of the
virtual image and confirms the foveal FOV formulas for symmetric frusta;
asymmetric frusta were tested subsequently below.

All four projection views receive the frame's render pose
([frame-metadata.md](frame-metadata.md)), and `subImage` covers the full
swapchain dimensions.

## Open questions / to confirm on the wire

`vr3` confirmed the tile order and eye assignment (left eye first, verified by
stereo parallax), the 1:1 correspondence between the four HEVC slices and four
atlas tiles, that edge feathering is applied only on the client, and that the
inset record matches the rendered pixels. Open questions following `vr3`
(several addressed in the later client results below):

1. Whether atlas mode 1 or mode 2 ever occurs (for example, on other headsets
   or when foveation is disabled); neither appeared in `vr3`.
2. Whether `inset_x` and `inset_y` update dynamically at runtime when eye
   tracking is active; they stayed constant across `vr3`, which had no eye
   tracking.
3. Which Y'CbCr matrix the host encoder uses: the VUI signals `identity`, which
   is invalid for 4:2:0, and both BT.2020 and BT.709 look plausible on the
   dashboard scene. Capturing a pure-primary test pattern on the host desktop
   would settle this.
4. What the 3x3 shader color matrix targets, and what changes when the OpenXR
   runtime accepts the requested `XR_FB_color_space` (which Klepton declined).
5. Verifying the foveal FOV formulas with an asymmetric base frustum (only the
   symmetric +/-45 degree case was present in `vr3`).
6. Why both eyes receive the same pose in metadata (see the open item in
   [frame-metadata.md](frame-metadata.md)), given that stereo parallax in the
   decoded image confirms the host renders the two eyes from separated
   positions.

## Probe results

Decoding a frame from the probe's saved stream with `ffmpeg` shows the SteamVR
dashboard stacked four times down the `1536x6144` atlas: a magnified central
crop, the wide view, and then the same pair repeated. That confirms the
fovea-then-base ordering for each eye (**captured**), though a single frame
with a stationary head viewing a distant dashboard had too little disparity on
its own to distinguish which eye came first without the cross-correlation
check above.

## Client results: asymmetric frusta on a headset

The visionOS client published each eye's physical frustum from an Apple Vision
Pro—left eye tangents left `-1.73`, right `1.00`, down `-1.19`, up `1.00` (with
the right eye mirrored)—along with an IPD of roughly 65 mm, and composited the
base and foveal tiles using the formulas above. Observed on the headset, stereo
depth is accurate and the central foveal region is sharp with no visible seam.
This confirms visually that the host renders asymmetric frusta as requested,
that the tile order (left fovea, left base, right fovea, right base) holds on a
stereo headset, and that the foveal FOV formulas hold for an asymmetric base
frustum (open question 5 above).

## Client results: rotated eye poses

Running OpenVRLink on macOS against a SteamVR host (**captured**) shows that
the host honors the rotation component of `VTE_EYE_TO_HEAD` (`0x08`). Across
two sessions with the same stationary head pose and identical frustum tangents,
the left eye was published once facing straight ahead and once rotated 15
degrees to the left. OpenVRLink places each base tile by composing the eye's
published head-relative pose onto the frame's render pose. In the rotated
session, world geometry remained stationary while the tile's outline rotated 15
degrees with the eye, proving the host rendered through the rotated eye pose;
if the host had ignored eye rotation, the scene would have shifted by 15
degrees along with the tile.

In principle, a headset with canted displays can publish each eye's physical
orientation along with frustum tangents measured around that eye's axes,
placing the tiles with the matching orientation. (Publishing identity rotations
with frusta measured around canted axes is internally self-consistent—the host
renders a forward-aimed cone and the client displays it straight ahead—but
under-samples the outer display margin.)

## Client results: asymmetric frusta and eye spacing, measured

To verify frustum and IPD handling quantitatively (**captured** with OpenVRLink
on macOS), we measured the pixel centroid of a controller model rendered by
SteamVR Home at a fixed pose roughly 0.5 m in front of a stationary head,
projected into an 1800-pixel window spanning tangents `-1..1`:

| published | centroid, pixels |
|---|---|
| symmetric +-1 frusta, eyes 63 mm apart (twice) | 1376.9, 1407.6 both times |
| left eye -1.73 / 1.0 / -1.19 / 1.0, right eye mirrored | 1377.3, 1406.7 |
| left eye -1.0 / 1.73 / -1.0 / 1.19, right eye mirrored | 1377.1, 1406.8 |
| symmetric, eyes 126 mm apart | 1433.3, 1404.2 |

The host renders through the exact published frustum whether symmetric or
asymmetric (the controller stays within 1 pixel when the tile is placed using
matching tangents) and honors the published eye spacing (shifting the left eye
31.5 mm further left moves the controller by 56 pixels, or `0.063` in tangent
space, matching 31.5 mm at 0.50 m depth).

## Headset result: canted displays and parallel projection

When OpenVRLink published the Vision Pro's physical eye rotations (each display
canted roughly 0.5 degrees outward and 1.2 degrees upward), game-rendered hands
appeared further away than physical hands, with the depth error increasing with
distance. Local debug markers drawn by OpenVRLink at the same tracked
coordinates aligned directly with physical hands, confirming that tracking and
local display composition were accurate while the streamed video had wrong
stereo convergence. In SteamVR's empty construct scene, the hands aligned much
more closely.

**inferred**: Although SteamVR and the `vrlink` host driver honor
`VTE_EYE_TO_HEAD` rotations (as measured above), many VR titles render assuming
parallel eye views—the same issue seen on other canted headsets, where SteamVR
works around it via "parallel projection". Losing 1 degree of convergence
pushes a hand at 0.5 m roughly 20% further away. OpenVRLink therefore publishes
parallel forward-facing eyes with each frustum widened to enclose the canted
display's FOV (`Frustum.enclosing`), then renders the received image through
the physical canted views. With parallel eyes published, stereo depth looks
natural and virtual hands align with physical hands both on a fresh SteamVR
launch and on reconnect.
