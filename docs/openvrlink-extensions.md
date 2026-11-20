# OpenVRLink extensions

OpenVRLink supports optional extensions to the Steam VR Link protocol when the
host is running `driver_openvrlink` (`companion/`), which patches `driver_vrlink`
in memory. Both sides remain compatible with stock peers: an unpatched
`driver_vrlink` host or stock `vrlink` client ignores the extension key/value
records.

Claims in this document use the same evidence tags as the rest of `docs/`.
**static** host claims cite `driver_vrlink.dll` (Windows build from 2026-11-13,
SHA-256 `c2a2e70e…920d1b`, image base `0x180000000`) or `driver_vrlink.so`
(Linux build ID `b30b2657…`, which retains its symbol table). **tested** means
covered by the test suites in `companion/` and `client/`. **live** means
verified on 2026-11-19 using the macOS viewer against a Windows 11 host running
SteamVR 2.19.4 with `driver_openvrlink` installed.

## 1. Key/value channel transport

The handshake runs over the SVLRoot key/value channel
([svl-values/svlroot-key-value-channel.md](svl-values/svlroot-key-value-channel.md)),
which carries 32-byte `TransportValue_t` records consisting of a NUL-padded key
(up to 20 bytes) and a `double`. We use this channel for two reasons:

- Stock peers store and echo every key regardless of whether they recognize it,
  and only act on specific keys they query by name (**static** on `vrlink`; on
  the host, `SVLRoot::ParsePeerValueSettings` at `driver_vrlink.dll`
  `0x180a56120` inserts all incoming keys into the same table). Unknown keys are
  harmless to unpatched peers.
- Records are sent continuously without acknowledgments, so state converges
  automatically without extra ordering rules.

All extension keys begin with `ox`, which does not collide with any key found in
packet captures or static analysis of `vrlink` and `driver_vrlink`.

| key | from | value |
|---|---|---|
| `oxClient` | client | heartbeat: `version * 65536 + tick`, `tick` = milliseconds / 250, low 16 bits |
| `oxWant` | client | bitmask of features supported by the client |
| `oxHost` | host | heartbeat, using the same encoding |
| `oxAvail` | host | bitmask of features patched into `driver_vrlink` on this host |
| `oxOn` | host | bitmask of features applied to outgoing frames |
| `oxGamma` | host | active encoding gamma (`1` when gamma is inactive) |

The handshake version is 1. A feature is active while its bit is set in
`available & enabled & wanted` and the peer's heartbeat is live.

### Heartbeat detection

Stock peers echo back every key in their table. A stock `driver_vrlink` host
echoes `oxClient` back to OpenVRLink, and a stock `vrlink` client can echo stale
`oxHost` records from an earlier session back to a patched host. Similarly, a
client switching from a patched host to a stock host could receive its own
previous keys back.

To distinguish a live peer from echoed records, both sides increment a heartbeat
counter every 250 ms (`oxClient` and `oxHost`). Echoed keys repeat a static
value, while a live peer's heartbeat keeps advancing. Each side considers its
peer active only if the peer's heartbeat has changed within the last 1.5 s; if
the heartbeat stops advancing, all extensions turn off (**tested**:
`HostSideTests`, `HostExtensionsTests`).

### Sending records

On the client, `StreamSession.statistics()` rotates `oxClient` and `oxWant`
through the third slot of the three-record statistics element sent with each
pose packet, transmitting each key roughly 85 times per second.

On the host, `SVLRoot::PopulatePeerValueSettings` (`0x180a565e0`) builds the
record list for each frame descriptor. When `driver_openvrlink` detects a live
OpenVRLink client, it hooks that call and overwrites the first record (the slow
round-robin slot) on every second batch, cycling through `oxHost`, `oxAvail`,
`oxOn`, and `oxGamma`. Non-OpenVRLink clients never receive `ox` keys
(**tested**: `companion/Tests/DriverHarness`).

Visual features take effect within a few frames of negotiation rather than on a
synchronized frame boundary. OpenVRLink tags each incoming frame with the active
`encodingGamma` when reassembly finishes (`FrameLayout.encodingGamma`), so
toggling the setting while streaming can cause a brief brightness step.

## 2. Encoding gamma (feature bit 0)

Video encoders allocate relatively few codewords to dark values, which causes
visible banding and crushed shadow detail on OLED headsets. When encoding gamma
is active, the host raises each sRGB channel to `1/gamma` prior to video
encoding, and the client raises the decoded sRGB channel back to `gamma`:

```
host:    v' = clamp(v, 0, 1) ^ (1 / gamma)      v = driver_vrlink's sRGB-encoded R, G, or B
client:  v  = v' ^ gamma                          applied before converting sRGB to linear light
```

`gamma` comes from the SteamVR setting `driver_openvrlink/encodingGammaValue`
(default 1.2), clamped to `[1, 3]` on both the host and client.

### Host (Linux)

On Linux, encoding gamma was verified **live** against the October 2026
`driver_vrlink.so` build (stripped, build ID `f677267e…`, running x86-64 under
FEX on an arm64 Ubuntu 24.04 machine): `driver_openvrlink` patched all three
Vulkan compute shaders when the client connected, and the macOS viewer streamed
at 120 fps with encoding gamma 1.8.

`driver_vrlink.so` prepares each eye for encoding with Vulkan compute shaders
loaded via `LoadSpirvFile` (**static**):
`resources/shaders/genforencode_comp_{rgb,luma,chroma}.spv` in the July 2026
build, and `resources/shaders/vulkan/genforencode_cs_{rgb,luma,chroma}.spv` in
the October 2026 build. Each shader finishes by converting the filtered linear
color to sRGB one channel at a time. `SPIRV.patchGamma`
(`companion/Sources/PatchCore`) patches the SPIR-V bytecode to raise those three
sRGB channels to `1/gamma`.

The patched shader reads `gamma` from its uniform constant block. Because the
October 2026 shaders strip debug names and expand the block from 80 bytes to
128 bytes, `SPIRV.patchGamma` scans the SPIR-V instructions for the last float
or float-vector member that the shader never reads and returns its float offset.
That selects `g_GameTexSize` (float 12) in the July 2026 shaders and float 30 in
the October 2026 shaders, which `UpdateConstantBuffer` (`0xbe410`) leaves zeroed
(**static**). The patched shader only applies gamma when the constant is in
`(1, 4]`, so unpatched constants leave the output unchanged. All six shaders
across both Linux builds patch cleanly and pass `spirv-val` (**tested**).

At runtime, `driver_openvrlink` intercepts `LoadSpirvFile`, substitutes a
patched shader written to `/tmp`, and writes the active gamma value into the
constant buffer after `UpdateConstantBuffer` runs. Because
`UpdateConstantBuffer`'s signature changed between the July and October 2026
builds (passing the float buffer in argument 5 in July and argument 6 in
October), the hook wrapper forwards all six integer/pointer register arguments
and writes to whichever parameter holds the buffer for the matched signature.
`gammaAvailable` becomes true once at least one encode shader has been patched
and none have failed. On unstripped builds (July 2026), `driver_openvrlink`
resolves functions from `.symtab`; on stripped builds (October 2026), it matches
function prologues by byte signature.

### Host (Windows)

On Windows, encoding gamma was verified **live**: `vrserver` loaded
`driver_openvrlink`, patched both copy-view shaders when the client connected,
reported `"handshake and encoding gamma active"`, and streamed to the macOS
viewer at 120 fps. Static analysis of `driver_vrlink.dll` shows how shader
loading works (**static**):

- Function `0x1809faed0` (called during device initialization at `0x1809f7df0`)
  loads all eleven Direct3D 11 shaders from `{vrlink}/shaders/d3d11/<name>.fxo`:
  `encode_rgb_to_yuv_vs`, `clock_vs`, `genforencode_ps_copy_view`,
  `genforencode_ps_copy_view_cas`, `encode_rgb_to_yuv_ps_{chroma,uv,y}`,
  `encode_rgb_to_yuv_legacy_ps_{chroma,y}`, and `clock_ps_{luma,chroma}`.
- Each shader path is converted to UTF-16, read via `D3DReadFileToBlob`
  (imported from `D3DCOMPILER_47.dll`), and passed to
  `ID3D11Device::CreateVertexShader` or `CreatePixelShader` (helper
  `0x1809f7330`). `D3DReadFileToBlob` is `driver_vrlink.dll`'s only import from
  `D3DCOMPILER_47.dll`.
- `driver_vrlink.dll` has no embedded fallback shaders; if any `.fxo` file fails
  to load, initialization fails with error 200.
- `driver_vrlink` also has a `watchForShaderChanges` option, which reloads
  client-side GLSL override shaders
  (`{vrlink}/shaders/client_{construct,fov,nf}_override.{frag,vert}`,
  `cursor.{frag,vert}`, and `override_shader_params.json`, up to 64 kB total)
  and does not affect the host's Direct3D encode shaders.

Because `driver_vrlink.dll` loads shaders through an imported function,
`driver_openvrlink` hooks `D3DReadFileToBlob` in the PE import address table
without needing a byte signature. `driver_vrlink` reads the `.fxo` files when a
client connects, well after `driver_openvrlink` attaches (**live**: driver
attached at 16:23:43.7, shaders read at 16:23:46.4).

In the `"vrlink copy views to atlas"` pass (`0x1809f8aa0`, **static**),
`driver_vrlink.dll` maps pixel-shader constant buffer slot 2, calls `0x1809f2870`
`(this, bool layer, bool flag, uint width, uint height, float *constants)` to
populate it, unmaps it, and draws using `genforencode_ps_copy_view` or
`genforencode_ps_copy_view_cas`. Helper `0x1809f2870` zeroes `0x70` bytes and
populates only the first `0x28` bytes. According to the DXBC reflection chunk
(`VS_CONSTANT_BUFFER`), the layout is `g_nonFovealColor` (0), `g_RBSize` (16),
`g_unused2` (24), `g_CasSharp` (28), `g_flViewOriginX/Y` (32/36), `g_unused0`
(40), `g_unused1` (44), and `g_vViewRects` (48). `driver_openvrlink` hooks
`0x1809f2870` and writes gamma into `g_unused0` (`cb2[2].z`).

Both copy-view pixel shaders end with the linear-to-sRGB conversion
(`ge t, 0.0031308, c` followed by `movc o0.xyz, t, low, high`), whereas the
downstream `encode_rgb_to_yuv` shaders operate in sRGB space. `DXBC.patchGamma`
redirects that `movc` output into a new temporary register, appends:

```
max r.w, cb2[2].z, 1.0      min r.w, r.w, 4.0      div r.w, 1.0, r.w
mov_sat r.xyz, r            log r.xyz, r           mul r.xyz, r, r.w
exp r.xyz, r                mov o0.xyz, r
```

and recomputes the DXBC container checksum. When `g_unused0` is `0`, the
exponent evaluates to `1.0`. The patcher rejects shaders that lack `g_unused0`
in reflection data or do not contain a single sRGB `ge`/`movc` pair. All four
copy-view shaders (the two pixel shaders used at runtime and the two unused
compute-shader variants) disassemble as expected under `D3DDisassemble` and pass
`CreatePixelShader` / `CreateComputeShader` on hardware and WARP (**tested** on
Windows).

### Client

On the client, `QuadRenderer` inverts the encoding gamma inside its fragment
shader (`testTheRendererUndoesTheEncodingGamma`, **tested**). When sampling a
linear-light texture, it converts to sRGB before applying `pow(v, gamma)` and
converts back to linear light afterward. All three client render paths draw
video through `QuadRenderer`.

## 3. Settings

Extension settings use a dedicated `driver_openvrlink` section in
`steamvr.vrsettings` so `driver_vrlink` never sees unrecognized keys:

| `driver_openvrlink/…` | written by | meaning |
|---|---|---|
| `encodingGamma` | user | enable encoding gamma when supported by the client |
| `encodingGammaValue` | user | gamma exponent |
| `gammaAvailable` | driver | whether `driver_openvrlink` patched `driver_vrlink` for gamma |
| `status` | driver | one-line patch status summary |

By default, `openvrlink-companion install` adds UI controls for these keys to
SteamVR's VR Link settings tab by editing `driver_vrlink`'s
`resources/settings/settingsschema.vrsettings` (passing `--own-tab` writes a
separate schema file instead). The gamma controls specify
`"requires": { "/settings/driver_openvrlink/gammaAvailable": true }`. Cross-section
support for `requires` and `label` controls in the SteamVR dashboard is
**inferred** from existing entries in `driver_vrlink`'s schema.

## 4. Adding a feature

To add a new extension feature, assign the next bit in the feature bitmask. The
client sets the bit in `oxWant` when it supports the feature, and
`driver_openvrlink` sets the bit in `oxAvail` once all required hooks and shader
patches succeed, and in `oxOn` while actively applying the feature. Any
additional parameters use new `ox*` host keys with a defined inactive default
value. Breaking changes to existing keys or bit meanings require incrementing
the handshake version; peers ignore heartbeats with an unrecognized version.

## Open questions

- Visual quality in an OLED headset still needs evaluation; live testing has
  only verified that both ends negotiate and apply the gamma curve.
- Does the SteamVR dashboard render the injected `requires` and `label` settings
  entries as expected?
