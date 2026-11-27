# OpenVRLink extensions

OpenVRLink supports optional extensions to the Steam VR Link protocol when the
host is running `driver_openvrlink` (`companion/`), which patches `driver_vrlink`
in memory. Both sides remain compatible with stock peers: an unpatched
`driver_vrlink` host or stock `vrlink` client ignores the extension key/value
records.

Claims in this document use the same evidence tags as the rest of `docs/`.
**static** host claims cite `driver_vrlink.dll` (SteamVR 2.19.4 on Windows,
SHA-256 `c2a2e70e…920d1b`, image base `0x180000000`) or `driver_vrlink.so`
(Linux build ID `b30b2657…`, which retains its symbol table). **tested** means
covered by the test suites in `companion/` and `client/`. **live** means
verified using the macOS viewer against a Windows 11 host running SteamVR 2.19.4
with `driver_openvrlink` installed.

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
| `oxAvail` | host | bitmask of available host features: bit 0 = encoding gamma (section 2), bit 1 = native OpenVRLink headset settings (section 3) |
| `oxModels` | host | bitmask of installed controller model sets, with bit 0 for Play For Dream MR and bit 1 for Galaxy XR |
| `oxAddr` | client | client IPv4 address for the data link, packed big-endian as a 32-bit integer |
| `oxPort` | client | TCP port the client's data link listens on |
| `oxKey0`, `oxKey1` | client | low and high 48-bit halves of the 96-bit data link authentication token |
| `oxOffer` | client | bitmask of controller model sets the client can upload over the data link, using the same bits as `oxModels` |
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
(default 1.6), clamped to `[1, 3]` on both the host and client.

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

## 3. Native headset profile settings (feature bit 1)

`driver_vrlink` gates headset capabilities by HMD model name
(see [svl-values/static-and-power-props.md](svl-values/static-and-power-props.md#unknown-hmd-models-and-vrlink_model-settings)).
No built-in profile enables eye tracking, 10-bit video, and the client's
requested render resolution at the same time, so against a stock host OpenVRLink
reports `"Vive Focus Vision"` when eye or face tracking is enabled, which locks
the render target to 2480 x 2480.

When `driver_vrlink` encounters an unrecognized HMD model name, it looks up a
`vrlink_<model>` section via `IVRSettings`. Because SteamVR merges
`default.vrsettings` across all active drivers, `driver_openvrlink` ships
default sections for OpenVRLink's two native model names:
`vrlink_Apple Vision Pro (OpenVRLink)` (used on visionOS) and `vrlink_OpenVRLink Headset`
(used on other platforms). Each section enables `enable`, `supports10bit`, and
`supportsEyeTracking`, repeats the six static HMD string properties that
`driver_vrlink` reads from settings when `enable` is true, and sets
`recommendedRenderWidth` and `recommendedRenderHeight` to `-1` so
`driver_vrlink` honors the client's requested resolution. Any user overrides in
`steamvr.vrsettings` under the same section names take precedence over these
defaults. In a **live** session (macOS viewer reporting `Apple Vision Pro`
against SteamVR 2.19.4 on Windows) with only `driver_openvrlink`'s defaults
installed, `vrserver.txt` logged `Found settings for unknown hmd`, `Found
properties for unknown hmd`, `Using 10bit mode: 1`, and `Render Target: 3008
2404` for a requested 3000 x 2400 eye resolution. End-to-end eye tracking
delivery under this profile has not been verified yet, and the `(OpenVRLink)`
model-name suffix (added so a future `driver_vrlink` build that recognizes plain
`Apple Vision Pro` does not override these settings) has not been exercised
against a live host yet.

`driver_openvrlink` sets bit 1 of `oxAvail` whenever both `vrlink_<model>`
sections are present with `enable` set to `true`. However, the client must send
its static HMD properties before the host starts sending `ox` records: even when
static HMD properties were delayed by 6 s in a **live** session, the host did
not send its first `ox` record until 2.8 s after those properties arrived. To
work around that ordering, the client caches whether each host supports bit 1 in
`hosts.json` (`KnownHosts`, keyed by discovery `clientID`) and reports its
native model name starting on the next session with that host
(`DeviceProfile.hostKnowsHeadset`). If a host streams for 15 s without sending
extension records, or sends `oxAvail` without bit 1, the cached flag is cleared.
With the macOS viewer (**live**), the first session recorded support for the
host and the second session connected under its native model name; this has not
been verified on a Vision Pro yet.

## 3a. Controller model sets (`oxModels`)

`driver_openvrlink` can serve custom controller render models from its
`resources/rendermodels` directory so SteamVR displays the headset's physical
controllers instead of Quest 2 Touch controllers. Each supported controller
family has a bit in `oxModels` (`ControllerModelSet` on the client and
`ControllerModels` in `openvrlink-companion`):

| bit | set | models | source |
|---|---|---|---|
| 0 | Play For Dream MR | `pfd_mr_controller_left`, `_right` | bundled with `openvrlink-companion` |
| 1 | Galaxy XR | `galaxy_xr_controller_left`, `_right` | converted by `openvrlink-companion` from the headset's glTF assets |

`openvrlink-companion` writes the bitmask of installed sets to
`driver_openvrlink/controllerModels` in `default.vrsettings`, and
`driver_openvrlink` sends that bitmask in `oxModels`. SteamVR creates each
controller device once from the first static properties it receives and keeps
that render model until `vrserver` restarts. Because of that, headsets with
custom controller models wait up to 1.5 s at session startup for `oxModels` to
arrive (which usually takes about 0.5 s) before falling back to the value cached
for that host in `hosts.json` (`StreamSession.profileForControllers`).

If the host has the headset's model set installed, the client reports
`{openvrlink}<model>_<side>` with resource root `openvrlink`; otherwise it falls
back to the Quest 2 Touch models. Either way, the input profile and controller
type stay `oculus_touch`, and each model's component JSON binds its animations
to the Oculus Touch input paths (`/input/trigger`, `/input/joystick`,
`/input/a/click`, `/input/grip`, and `/input/system/click`) (**tested**:
`HostExtensionsTests`, `CompanionKitTests`, `PatchCoreTests`).

To add another controller model set, add a case to `ControllerModelSet` on the
client, add a bit to `ControllerModels` in `openvrlink-companion`, install the
model files into `resources/rendermodels`, and include the set in
`HeadsetModel.setsPresent`.

### Play For Dream MR

`openvrlink-companion` bundles the Play For Dream MR controller models extracted
from the `vrlink_pfd_mr` resource driver in Play For Dream's "MR SteamLink
Driver" 1.0.1.0 installer (redistributed with Play For Dream's permission) and
writes them into `driver_openvrlink` during driver installation. Older Play For
Dream software also installs `yvr_d1_*` models in `SteamVR/drivers/pfd`, which
belong to an earlier YVR headset.

### Galaxy XR

Android XR's OpenXR runtime does not implement any controller render-model
extensions, but Galaxy XR ships glTF controller models inside a preinstalled
system APK at `/system/priv-app/ImmersiveAvatarEditor/ImmersiveAvatarEditor.apk`
under `assets/models/Left` and `Right`. The Android client reads each side's
`.gltf`, `.bin` buffer, and base color PNG directly from that APK using
`ZipArchive` (`ControllerModelSource.galaxyXR`), so OpenVRLink does not need to
redistribute Samsung's assets. Those files are uploaded to the host over the
data link, where `openvrlink-companion` converts them into SteamVR render models
with `GLTFControllerModel`. You can also convert manually copied files with
`openvrlink-companion import-models galaxy-xr LEFT.gltf RIGHT.gltf`.

Each glTF defines a node per moving part (`Trigger`, `Grip`, `ThumbStick`,
`UpperButton`, `LowerButton`, and `MenuButton`) and a keyframe animation per
control (`Trigger_Press`, `ThumbStick_Left`, and so on). `GLTFControllerModel`
exports each part as a Wavefront OBJ in model space and builds its SteamVR
component motion from those animation channels. Rotation channels become
`rotate` motions around the node's pivot, and translation channels become
`translate` motions. For the thumbstick, it uses the two tilt axes to build a
`joystick` frame with +Y along the shaft and +Z toward the user instead of
relying on the clip names (`"ThumbStick_Up"` in Samsung's asset tilts the stick
backward).

OpenVRLink reports Galaxy XR controllers to SteamVR as Oculus Touch controllers,
so the client offsets Samsung's reported grip pose to match the Quest Touch grip
frame (`HeadsetQuirks.GripOffset.towardQuest`). Samsung's glTF mesh is authored
around the unadjusted runtime pose, so `GLTFControllerModel.galaxyXRPlace`
starts from the Quest 2 model's `openxr_grip` transform and applies the inverse
of the client's translation and pitch offset. It also shifts the origin 8 mm
outboard onto the handle axis and 14 mm forward (`galaxyXRGrip`); the 8 mm
offset comes from the handle mesh geometry, and the 14 mm offset was tuned
visually so touching the physical controllers together lines up in VR. If the
client's Galaxy XR grip offset changes, `galaxyXRPlace` needs to be updated to
match.

## 3b. Data link

The SVLRoot key/value channel only carries a few hundred bytes per second, so
OpenVRLink opens a separate TCP connection alongside the session for larger
transfers. Right now this connection uploads custom controller model assets,
though the message format can also carry other bulk data later, such as camera
or tracking streams.

### Connection and authentication

When connected to a live `driver_openvrlink` host that is missing controller
models the client can provide, the client opens a TCP listener on its session
IPv4 address using an ephemeral port and closes the listener when the session
ends. The headset listens and `driver_openvrlink` connects out from `vrserver`
so the PC does not have to open a listening port or trigger a Windows Firewall
prompt.

The client sends its listener address and port in `oxAddr` and `oxPort`, along
with a random 96-bit token split across `oxKey0` and `oxKey1`. Because those
records travel over the encrypted SVL session transport, only the paired host
receives the token. The host must send a 20-byte handshake containing that token
before any messages. The client closes unauthenticated connections without
replying and rotates the token as soon as a valid connection is accepted so each
token is single-use. After that initial token check, the TCP stream itself is
**unencrypted and unauthenticated**, so any private data sent over this link in
the future will need stream encryption and authentication.

### Wire format

All multi-byte integers are little-endian.

| part | bytes |
|---|---|
| hello (host first) | `OVRL`, version `1`, three zero bytes, 12-byte token |
| message | kind `u16`, flags `u16` (zero), payload length `u32`, payload |

Payloads are limited to 32 MiB, and unrecognized message kinds are skipped.

| kind | from | payload | meaning |
|---|---|---|---|
| 1 `wantModels` | host | set `u8` | request all files for this controller model set |
| 2 `file` | client | set `u8`, name length `u8`, name, bytes | one file belonging to the set |
| 3 `done` | client | set `u8`, status `u8` | transfer complete (`0`) or unavailable (non-zero) |
| 4 `result` | host | set `u8`, status `u8` | files stored (`0`) or write failed (non-zero) |

File names must consist of one or two `/` path components containing only ASCII
letters, digits, `_`, `-`, and `.`, with no component starting with a dot
(`DataLink.isSafe`). Both sides reject any other file name.

### Host handling

On the host, `Link.swift` drives a non-blocking socket (`DriverABI/link.c`)
directly from `vrserver`'s frame callback without spawning background threads.
When a live client offers a model set that the driver has not yet installed or
requested during the current `vrserver` run, the driver connects, requests the
set, and writes up to 32 files (64 MiB total) under `incoming/<set>/` inside the
driver directory, followed by a `complete` marker file. Using the `folder` and
`companion` paths that `openvrlink-companion` writes to `default.vrsettings`,
the driver then runs `openvrlink-companion import-models pending` to convert the
downloaded files into SteamVR render models. Running
`openvrlink-companion install` also converts any completed uploads in
`incoming/` so converter updates reprocess cached files. Once the converted
render model appears on disk, `driver_openvrlink` adds its bit to `oxModels`, so
the headset learns about it during the current session and uses the models
starting on the next session (**tested**: `LinkTests`, `DataLinkTests`,
`PatchCoreTests`).

## 4. Settings

Extension settings use a dedicated `driver_openvrlink` section in
`steamvr.vrsettings` so `driver_vrlink` never sees unrecognized keys:

| `driver_openvrlink/…` | written by | meaning |
|---|---|---|
| `encodingGamma` | user | enable encoding gamma when supported by the client |
| `encodingGammaValue` | user | gamma exponent |
| `gammaAvailable` | driver | whether `driver_openvrlink` patched `driver_vrlink` for gamma |
| `status` | driver | one-line patch status summary |
| `controllerModels` | `openvrlink-companion` (driver defaults) | bitmask of controller model sets installed in `driver_openvrlink/resources/rendermodels` |
| `folder`, `companion` | `openvrlink-companion` (driver defaults) | paths to the driver directory and `openvrlink-companion` executable used by the data link |

By default, `openvrlink-companion install` adds UI controls for these keys to
SteamVR's VR Link settings tab by editing `driver_vrlink`'s
`resources/settings/settingsschema.vrsettings` (passing `--own-tab` writes a
separate schema file instead). The gamma controls specify
`"requires": { "/settings/driver_openvrlink/gammaAvailable": true }`. Cross-section
support for `requires` and `label` controls in the SteamVR dashboard is
**inferred** from existing entries in `driver_vrlink`'s schema.

## 5. Adding a feature

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
- The data link uses unencrypted TCP after the single-use token handshake. Before carrying camera or tracking data, it should encrypt and authenticate the stream end-to-end (for example, using a session key exchanged over `ox` records).
- The data link assumes the client's session address is IPv4 and directly reachable from the host, which works on a local network but not across NAT.
