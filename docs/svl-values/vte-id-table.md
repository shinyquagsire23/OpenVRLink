# `ValueTransportID` table (the `VTE_*` enum)

The enum has 51 slots (ids 0..50; `InternalUpdateValue` rejects `id >= 0x33`,
`TickUpdate` iterates 0x33 slots — **static**, +0x169584 / +0x169aac). Enum
names are not in the binary as a table; a name is given below only where a log
string next to the call site spells it. Everything else is labeled by what the
code does with it.

See [value-transport-wire-format.md](value-transport-wire-format.md) for the
chunk and ack framing. All offsets below are file offsets in
`libvrlink_scene.so`, and all multi-byte values are little-endian.

Claims are tagged **static** (read from `libvrlink_scene.so`), **captured**
(decoded from streaming capture `vr3`, a complete, untorn, timestamped Klepton
`KL_TRACE_NET` trace of `vrlink` against a SteamVR host, reassembled in full
with `ovrlink/vts.py`), or **inferred**. The "seen in capture" column gives the
byte size and initial bytes observed in `vr3`; `vr1` is cited only where it
showed behavior absent from `vr3`.

In `vr3`, `vrlink` sent 17 distinct ids and the host sent 19; ids listed in the
tables below and marked "not seen" did not occur in either capture.

## Client → host

| id | name | size | payload | sent when | evidence | seen in capture |
|---|---|---|---|---|---|---|
| 0x01 | *(client instance id)* | 8 | `u64` random from `/dev/urandom`, bit 0 forced to 1 | once in `QSVLClient::Init` +0xf5e84 | static | 8 bytes, bit 0 set, v1 and v2 identical — captured |
| 0x04 | `VTE_PROJECTION_RAW_PRAMS` | 32 | `float[2][4]`: per eye (left, right) `tan(angleLeft), tan(angleRight), tan(angleDown), tan(angleUp)` of the OpenXR view FOV (signed: left and down are negative) | together with 0x08 | static: `QSVLClientXR::GetDisplayProjections` +0xfb0d4 + reorder in `UpdateFrameVariables` +0xf5248 | `-1, 1, -1, 1` ×2 (a ±45° viewer) — captured |
| 0x05 | `VTE_CLIENT_CHAPERONE` | variable | UTF-8 JSON text, no terminator (SteamVR `chaperone_info` format) — see below | at init, when the play area changes, when the host updates VTE 0x16, on prop refresh | static: `QSVLClientXR::GetChaperone` +0xfb218 | 507 bytes, 4 chunks — captured |
| 0x08 | `VTE_EYE_TO_HEAD` | 96 | two `vr::HmdMatrix34_t` (row-major 3×4 `float`), left eye then right eye: rotation from the OpenXR view pose quaternion in VIEW space, translation in column 3 | whenever `abs(cached − new) > 0.0001` for the float at offset 0x3c (right eye x translation = +IPD/2) | static: `QSVLClientXR::GetEyeToHeadTransform` +0xfac78 | identity rotation, left x = −0.0315 — captured |
| 0x0c | `VTE_REQ_FRAMETIME_US` | 4 | `u32` frame period in µs = `(uint)(1000000.5 / hz)` of the refresh rate the client actually set | as an event, in reply to every host update of 0x21 | static: watch lambda +0xf8034 | `8d 20 00 00` = 8333 (120 Hz), sent 5 ms after the host's 0x21 arrived and acked 3.4 ms later; one version in `vr3` (one request), two in `vr1` — captured |
| 0x0d | `VTE_PROPS_STATIC_HMD` | 1161 | `VTE_StaticProps_t`, [static-and-power-props.md](static-and-power-props.md) | init, prop refresh | static | captured, all strings decoded |
| 0x0e | `VTE_PROPS_STATIC_L` | 1161 | same, left controller | init, prop refresh, interaction-profile change (sent as event) | static | captured |
| 0x0f | `VTE_PROPS_STATIC_R` | 1161 | same, right controller | same | static | captured |
| 0x10 | *(power props, HMD)* | 12 | `VTE_PowerProps_t` | 1 Hz re-check, sent on change | static | `3f000000 1b000000 3333733f` (0.95) — captured |
| 0x11 | *(power props, left)* | 12 | same | same | static | `3f000000 1a000000 00000000` — captured |
| 0x12 | *(power props, right)* | 12 | same | same | static | same — captured |
| 0x13 | *(dashboard / focus event)* | 52 | byte 0 = event code, rest zero. `vrlink` sends `4` on losing OpenXR focus and `5` on gaining it | `QSVLClientXR::OnUnFocused` +0xfb578 / `OnFocused` +0xfb600, as events | static | `05` + 51 zero bytes, once, 30 ms in; not repeated after the invalidation — captured |
| 0x15 | `VTE_HOST_DEFAULTS` | 8 | constant `03 00 00 00 01 00 00 00` | init, prop refresh | static | identical — captured |
| 0x18 | *(client audio FEC capabilities)* | 4 | `u32` = 3 | `SVLAudio` ctor +0x156c88 | static (docs/svl-audio/) | `03 00 00 00` — captured |
| 0x1d | *(network test)* | variable | string from `AppPaths` entry 10; log `[SVLClient] Sending Network Test: %s` | init, prop refresh | static | **not on the wire**: the string was empty and a zero-length value is never transmitted — captured (log line present, no element) |
| 0x20 | `VTE_AVAILABLE_FRAMETIMES_US` | 16 + 4·n | `u32 1`, `u32 n` (≤ 250), 8 zero bytes, `float[n]` supported refresh rates **in Hz** (despite the name) | init; then re-sent as an event once a second until the host has made a 0x21 request | static: `UpdateFrameVariables` + `QSVLClientXR::GetAvailableDisplayFrequencies` +0xfafc8 | `01000000 01000000 00×8 0000f042` (one rate, 120.0) — captured |
| 0x22 | `VTE_STRING_VERSION_NUMBER` | variable | ASCII `"qvlclient;" + product name + ";" + app version` | init, prop refresh | static | `qvlclient;hollywood;2.0.20.1812` (31 bytes) — captured |
| 0x23 | `VTE_CLIENT_AUDIO_STATE` | 10 | see below | as an event when system volume / mute changes | static: `QSVLClientXR::HandleEvent` +0xfa6e0 | `01 01 01 00 00 00 10 0f ff ff`, first sent 71 ms in, at the end of the startup values and before any video — captured |
| 0x25 | *(Wi-Fi id)* | variable | second output string of `GetWifiSSID(a, b)` +0x1437f8, which calls `getSSID` then `getBSSID` — **inferred** the BSSID | once in `QSVLClientXR::Init` +0xfa22c | static call, inferred content | not on the wire (empty string; the capture host had no Wi-Fi info) |

The static ctor code of `SVLAudio` also calls `UpdateValue` for ids 0x19 and
0x26 (+0x156e50, +0x156e98); those are the host-role branch (docs/svl-audio/),
and the capture shows the client never sends them.

## Host → client

| id | name | size | payload / effect on the client | evidence | seen in capture |
|---|---|---|---|---|---|
| 0x02 | *(host instance id)* | 8 | opaque `u64`. When it differs from the last one seen (initially 0) the client calls `InvalidateAll()` and re-sends all its values | static: `QSVLClient::OnRenderComplete` +0xf671c | 8 bytes, in the host's first datagram (3.8 ms); the client logged `All VTEs Invalidated.` once and every plain client value went out a second time as version 2. The host re-sent it as version 2 with the same bytes at 23 ms — captured |
| 0x06 | unknown | 32 | never read by the client | — | first sent once video has started (1.051 s), in bookend trailers. In `vr3` a single version: a 64-bit little-endian value with six non-zero bytes at +0, zeros in the other 24 bytes. In `vr1` later versions also filled +16 with a nearly equal value (pattern `xx xx xx xx xx xx 00 00 | 00×8 | xx xx xx xx xx xx 00 00 | 00×8`). **inferred** two 64-bit timestamps: read as 100 ns ticks the `vr3` value is about 55 days, a plausible host uptime — captured |
| 0x13 | *(dashboard event)* | 52 | byte 0 == 2 → `[SVLClientXR] Remote dashboard requested` (opens the client's dashboard UI) | static: lambda +0xfbb9c | not seen |
| 0x14 | *(debug: dump byte log)* | any | any update calls `ByteLogger::DumpLogToDisk()` | static: lambda +0x16c558 | not seen |
| 0x16 | *(recenter / chaperone request)* | any | any update makes the client re-locate its stage space and, if valid, re-publish VTE 0x05. Sent by `driver_vrlink.dll` from the `svl/driver` mailbox's `handle_recenter` handler (`0x180a0c6f0`, log scope `SVLServer mailbox handle_recenter`) | static: lambda +0xfbce0; host side static | not seen |
| 0x17 | `VTE_PROP_COLOR_CONTROL` | 104 | `u32 version` first; `version >= 1` → copy the 104 bytes into the renderer's color parameters; `version >= 2` → also update swapchain sampler state. Field layout beyond the version: docs/svl-video/ (shader uniforms) | static: lambda +0x10c474 | in bookend trailers: 104 bytes = `03 00 00 00` + 100 zero bytes (version 3, everything else zero); client logged `VTE_PROP_COLOR_CONTROL updated` — captured |
| 0x19 | *(host audio FEC capabilities)* | 4 | `u32` bit 0 / bit 1, docs/svl-audio/ | static | `03 00 00 00` — captured |
| 0x1a | *(unguided retransmit enable)* | 4 | `i32`; 0 disables the client's unguided video re-request sweep (`SVLFEC::Tick` +0x160a18), default 1 | static (docs/svl-video/) | `01 00 00 00`, first datagram — captured |
| 0x1b | unknown | 4 | never read by the client | — | `01 00 00 00`, first datagram — captured |
| 0x1c | *(ping peak decay)* | 4 | `u32` stored at `SVLRoot+0x198`: µs subtracted per update from the peak-hold latency published as `cPingAMS` (`SVLRoot::SymmetricTimingUpdate` +0x165a38) | static: lambda +0x16652c; which of the two `SVLRoot::Init` lambdas belongs to 0x1c vs 0x29 is **inferred** from registration order | in bookend trailers from 1.051 s: `e8 03 00 00` (1000) — captured |
| 0x1e | *(shader push)* | 24 + n | header `u32 ?, u32 shader_id, u32 vertex_len, u32 fragment_len, 8 bytes ?` then vertex source, fragment source (lengths sum ≤ 0x10000). `shader_id`: 0 = `VTE_SHADER_SCENE_BACKGROUND` ("not implemented!"), 1 and 2 = the two stream-layer shaders of `QSVLRendererXR`, 3 = a UI shader. Client hot-reloads the GLSL. Bad sizes log `[SVLClientXR] Invalid shader push (%d, %d, %d) ... %d` | static: lambda +0xfc0b0 | not seen |
| 0x1f | unknown | 4 | never read by the client | — | `01 00 00 00` — captured |
| 0x21 | *(display frequency request)* | 4 | `float` Hz. Client rounds to an integer, calls `TrySetPreferredDisplayFrequency`, replies with 0x0c. Logs `[SVLClient] Received display frequency request update` | static: lambda +0xf8034 | `00 00 f0 42` (120.0) at 33 ms, 3 ms after the client's 0x20 left; one version in `vr3`, two in `vr1` — captured |
| 0x23 | `VTE_CLIENT_AUDIO_STATE` | 10 | host can set mute / volume on the headset, see below | static: lambda +0xfbdfc | not seen inbound |
| 0x24 | *(max frame queue latency)* | 4 | `u32` µs → renderer; log `QSVLClientXR::SetMaximumFrameQueueLatency: %d us` | static: lambda +0xfc36c | not seen |
| 0x26 | *(audio jitter-buffer settings)* | 47 | packed struct, docs/svl-audio/ | static | `01 01 01 32000000 19000000 0f000000 14000000 07000000 f4010000 f4010000 02000000 32000000 0a000000 05000000` — captured |
| 0x27 | *(wireless timeout)* | 4 | `u32`; log `[SVLClientXR] Wireless timeout updated to: %i`; forwarded to the app shell | static: lambda +0xfbf7c | `1e 00 00 00` = 30, sent once as an event in the host's second datagram (3.9 ms); the client logged `Wireless timeout updated to: 30`. The probe found SteamVR exits about 30 s after the client goes away, so the unit is seconds — captured |
| 0x28 | `VTE_COMPOSITION_LAYER_SETTINGS` | 8 | two `u32` flag words (one per stream layer): bit 0 quality sharpening, bit 1 normal sharpening, bit 2 quality super-sampling, bit 3 normal super-sampling (mapped onto `XR_FB_composition_layer_settings`) | static: lambda +0x10c654 | not seen |
| 0x29 | *(QoS on/off)* | 4 | `u32` bool → `SVLDataLinkUDP::ChangeQoSState(bool)` +0x1685a0 | static: lambda +0x1665d8 | `01 00 00 00`, as an event in the host's second datagram (3.9 ms) and again as version 2 in bookend trailers at 1.051 s. On the first event `vrlink` tore down its socket and recreated it on the same local port with `IP_TOS` 255 (log: `SVLDataLinkUDP::Disconnect()` … `Changing tos opt = 255`; docs/svl-transport/connection-lifecycle.md §1.1); the second event carried the same value and was a no-op — captured |
| 0x2b | *(prop refresh request)* | any | any update: `[SVLClient] Server requested prop refresh`; `vrlink` marks 0x04, 0x05, 0x08, 0x0d–0x12, 0x15, 0x1d, 0x20, 0x22 dirty | static: lambda +0xf81d0 | `00 00 00 00` (the 4 zero bytes `SendEvent(id)` sends), once, in the host's second datagram (3.9 ms), i.e. before the host had received anything beyond `vrlink`'s first two packets; `vrlink` logged the refresh and regenerated its chaperone — captured |
| 0x2e | *(hand tracking enable)* | 1 | `u8` bool: create / destroy the OpenXR hand trackers; log `[XRQ] Hand tracking status updated: %s` | static: lambda +0xfc478 | `01`, first datagram; `vrlink` logged `Hand tracking status updated: On` — captured |

Ids with no reader and no writer in `vrlink`: 0x00, 0x03, 0x07, 0x09, 0x0a,
0x0b, 0x2a, 0x2c, 0x2d, 0x2f–0x32. Id 0 cannot be used because `RXMessage` logs
`Unknown VTE` for it.

### Out-of-table host ids (**captured**)

The host (bookend protocol version 14) sends values that this `vrlink` build
has no enum slot for. They arrive in bookend trailers as ordinary single-chunk
values—in `vr3` all five first appear at 1.052 s, in the bookend following the
one that introduced 0x06, 0x17, 0x1c, and 0x29, and repeat across 12
consecutive bookends (18 ms) until `vrlink`'s acks are processed—and `vrlink`
acks them (it acks every valid data chunk before checking the id) and never
reads them:

| id | size | value seen |
|---|---|---|
| 0x35 | 4 | `00 00 00 00` |
| 0x64 | 1 | `00` |
| 0x65 | 1 | `00` |
| 0x67 | 1 | `00` |
| 0x72 | 1 | `00` |

A compatible client must parse and ack these ids. Their meanings are unknown
apart from 0x35 (see below).

### Host values during application launch (**captured**)

Two sessions were recorded with the Swift client logging every host VTS value
and unhandled message whenever payload bytes changed (`OPENVRLINK_LOG_HOST=1`):

- Mac viewer, 190 s from a cold SteamVR start with no app launched: every value
  below was sent once and never changed, including 0x06.
- Vision Pro, ~3 minutes: bare hands, dashboard dismissed, two controllers
  connected, dashboard opened, The Lab (`steam.app.450390`) launched from the
  dashboard, and The Lab quit from the dashboard ~12 s later.

| id | size | idle | while The Lab ran | notes |
|---|---|---|---|---|
| 0x35 | 4 | `00 00 00 00` | `01 00 00 00` (version 2), back to `00 00 00 00` (version 3) as it quit | **inferred**: `u32`, non-zero while a scene application is running. The host's `vrserver.txt` logs The Lab connecting and `"Clearing application steam.app.450390"` at timestamps matching both transitions (the client log lacked wall-clock timestamps, so alignment is within ~1 s via its 1 Hz status lines) |
| 0x06 | 32 | `6e cf bd fe 6f 2b 00 …` then zeros | unchanged | unrelated to scene applications. Identical six non-zero bytes in both sessions despite different host instance ids (0x02), so it is not per-session either; still unknown |
| 0x1b, 0x1f | 4 | `01 00 00 00` | unchanged | unknown |
| 0x64, 0x65, 0x67, 0x72 | 1 | `00` | unchanged | unknown |
| 0x17 | 104 | `03 00 00 00` then zeros | unchanged | color control was unused in both scenes |
| 0x21 | 4 | 120.0, then 90.0 on the headset (version 5) | unchanged | tracks display refresh rate rather than the running application |

Opening and closing the dashboard and connecting controllers changed no host
values. The only unhandled transport message was the host address list (class 3
type 0x18), repeated identically every 2 s.

Thus the host indicates **whether** a scene application is running (via 0x35),
without identifying **which** application: no app ID, title, or key appears in
any VTS value, in discovery packets (`games_running` is a single boolean flag;
see docs/remoteplay/), or in strings from either `vrlink` build. Only one title
was tested, so whether 0x35 ever takes values other than 0 and 1 (such as an
app count or a loading state) is unknown. Per-title client behavior is
therefore not supported by the protocol as currently understood.

The Swift client uses 0x35 for `chromaKeyOffInGames`: chroma-key passthrough
stays active in SteamVR's construct grid and turns off while 0x35 is non-zero
(`StreamSession.sceneApplicationRunning`).

## Payload details

### `VTE_CLIENT_AUDIO_STATE` (0x23), 10 bytes

| off | field |
|---|---|
| 0 | speaker-mute field valid |
| 1 | mic-mute field valid |
| 2 | speaker-volume field valid |
| 3 | mic-volume field valid |
| 4 | speaker muted (0/1) |
| 5 | mic muted (0/1) |
| 6 | speaker volume maximum (number of steps) |
| 7 | speaker volume (step) |
| 8 | mic volume maximum |
| 9 | mic volume |

In `libvrlink_scene.so` (**static**), the receive lambda (+0xfbdfc) logs
`VTE_CLIENT_AUDIO_STATE %d(%d) %d/%d(%d) - %d(%d) %d/%d(%d)` with bytes
`4(0) 7/6(2) - 5(1) 9/8(3)` and applies: byte 0 → `SetSystemVolumeMute(b4)`,
byte 1 → `SetMicrophoneMute(b5)`, byte 2 → `SetSystemVolume(b7)`. Outbound,
`vrlink` sends `01 01 01 00, muted, micMuted, steps, volume, ff ff` (+0xfa6e0);
`vr3` **captured** `01 01 01 00 00 00 10 0f ff ff` (16 steps, volume 15).

### `VTE_CLIENT_CHAPERONE` (0x05)

Decoded from `vr3` (**captured**, formatted for readability; one universe; this
run had no guardian configured, so the bounds are degenerate):

```json
{"jsonid":"chaperone_info",
 "universes":[{
   "collision_bounds":[[[0,0,0],[0,2.43,0],[0,2.43,0],[0,0,0]], "... 4 quads total ..."],
   "play_area":[0,0],
   "seated":{"translation":[-0,-0,-0],"yaw":-0},
   "setup_standing2":{"translation":[-0,-0,-0],"yaw":-0},
   "standing":{"translation":[-0,-0,-0],"yaw":-0},
   "time":"<asctime-style local time>",
   "universeID":1794315439}],
 "version":5}
```

Each collision-bounds quad represents one wall: two floor corners and the same
two corners at height 2.43 m (**inferred** from the geometry; SteamVR's
`chaperone_info.vrchap` uses the same layout). `play_area` is `[width, depth]`
in meters. Key strings come from `ChaperoneXR::Generate` (+0x12ec58,
**static**).

`ChaperoneXR::Generate` (**static**) builds four walls from OpenXR's play-area
rectangle using corners `(-w/2, -d/2)`, `(w/2, -d/2)`, `(w/2, d/2)`, and
`(-w/2, d/2)` on the `(x, z)` plane, transformed by the stage space's pose.
Each wall `i` is `[corner i at y=0, corner i at y=2.43, corner i+1 at y=2.43,
corner i+1 at y=0]`. Whenever the rectangle changes from the previous one,
`vrlink` logs `Play area changed since last chaperone` and sets `universeID` to
the current Unix timestamp so each update arrives as a new universe.

On the host (**static**, `driver_vrlink.dll` `0x1809f20f0`), `driver_vrlink`
parses only `universes[0].universeID` from the JSON and passes the entire
string to SteamVR as the HMD's `Prop_DriverProvidedChaperoneJson_String`
(0x82f) along with `Prop_CurrentUniverseId_Uint64` (0x7d4). The host does not
limit the number of walls.

OpenVRLink sends one wall per edge of the room's boundary in the same corner
order, setting `play_area` to the largest origin-centered axis-aligned
rectangle that fits inside (`PlaySpace.chaperone`). In a **live** session
(macOS viewer with `--boundary` against SteamVR 2.19.4 on Windows), publishing
a six-wall boundary mid-session with a new `universeID`—followed by a four-wall
boundary eight seconds later with another `universeID`—updated SteamVR
immediately both times. `vrserver.txt` logged `UpdateChaperone got new universe
(len 792)`, `Configuring VRLINK Chaperone Prop container`, `Found universe
1795199424 in chaperone file`, and broadcast `ChaperoneUniverseHasChanged` to
other drivers on each update.

By default, SteamVR hides this boundary during normal VR gameplay, displaying
it only while SteamVR's Chaperone settings menu is open. Static analysis of
`vrcompositor.exe` (SteamVR 2.19.4, sha256 `1f23a1da...`, **static**) shows two
hardcoded overrides with no settings keys to disable them:

- At startup, `vrcompositor` checks whether the HMD imports bounds from its
  driver (`collisionBounds/enableDriverBoundsImport`, true by default, with
  Prop 0x800 or 0x82f non-empty) and sets `[this+0x1559] = 1` (`0x1400f5670`:
  `test al, al; je; mov byte [rdi+0x1559], 1`). While that flag is set, every
  frame forces the bounds style to 4 regardless of `CollisionBoundsStyle`
  (`0x1400f11e8`), which disables vertical chaperone walls.
- During HMD activation (`0x1809e9940`), `driver_vrlink.dll` sets a flag in
  `vrserver` that makes `vrcompositor` treat `CollisionBoundsGroundPerimeterOn`
  as false without reading the setting (`0x1400fdaeb`: `call; test al, al; je
  <read setting>; xor eax, eax`).

That `vrserver` call is the final instruction in `SVLHMDDriver::Activate`,
invoking vtable slot 69 (`+0x228`) of `IVRServerInternal_XXX`. On Windows,
`driver_openvrlink` patches this call to a 6-byte NOP
(`Scan.keepFloorPerimeter`) so `CollisionBoundsGroundPerimeterOn` is respected
(not yet tested live).

`CollisionBoundsCenterMarkerOn` and `CollisionBoundsPlaySpaceOn` are not
overridden. Patching the `je` instructions in `vrcompositor.exe` at
`0x1400f5672` (file offset `0xF4A72`) and `0x1400fdaf2` (`0xFCEF2`) from `74`
to `EB` would leave both walls and floor perimeter controlled by user settings
(not tested).

### Recentering (0x16)

SteamVR has two separate recenter paths:

- SteamVR's standard zero-pose reset (such as `vrcmd --recenter`) is handled
  entirely on the host. `vrserver.txt` logs `Update ZeroPose for the chaperone
  universe <id>` and sends nothing to the client (**live**: no 0x16 packet
  arrived).
- Sending `handle_recenter` to the `svl/driver` mailbox causes `driver_vrlink`
  to send VTE event 0x16 to the client (**static**). The sender of that mailbox
  message has not been traced (**inferred**: the recenter button in the Steam
  Link dashboard), so 0x16 has not been observed on the wire yet. `vrlink`
  responds by republishing its chaperone JSON, whereas OpenVRLink recenters the
  active play space to the user's current position and heading (see "Rooms" in
  [docs/client-architecture.md](../client-architecture.md)).

## Open questions

1. What are the names and meanings of host ids 0x06 (32 bytes), 0x1b, and 0x1f
   (4 bytes, value 1)? `vrlink` ignores all three, so only the host binary can
   answer this.
2. What do out-of-table ids 0x64, 0x65, 0x67, and 0x72 represent, and does 0x35
   (scene application running, **inferred**) ever take values besides 0 and 1?
   The newer `vrlink` 2.0.25 build has not yet been searched for readers of
   these ids.
3. What are the non-zero fields of 0x17 (`VTE_PROP_COLOR_CONTROL`) when color
   control is active? Both captures had version word 3 followed by zeros.
   (Payloads for 0x27 and 0x2b are now captured: 30 and four zero bytes.)
4. Is 0x20 actually re-sent once per second while waiting for 0x21 (**static**)?
   In `vr3` the host replied after 33 ms, so the 1 s timer never fired.
5. What triggers updates to 0x06? Capture `vr3` had one version in 40 s, `vr1`
   had three, and both application-launch sessions above (one of which launched
   and quit The Lab) had a single version each.
6. Does the host read 0x13 event codes other than 4 and 5, or send codes other
   than 2?
7. Do 0x1d (network test) and 0x25 (Wi-Fi BSSID) affect host behavior when
   non-empty? Both were empty—and therefore omitted—in a session that streamed
   normally, so neither is required.
8. What are the first `u32` and trailing 8 bytes of the 24-byte shader-push
   header (0x1e)?

## Chroma key passthrough (ids 0x33, 0x34, 0x36, 0x37, and bits of 0x06)

All entries below are **static** unless noted otherwise, read from
`driver_vrlink.dll` (sha256 `9cd7d253…`) on the host and from the unstripped
`libvrlink_scene.so` bundled in
`drivers/vrlink/resources/android-steamlinkvr-release.apk`
(`QSVLClient::UpdateFrameVariables`, `UpdateHostChromaKeyNoiseFloor`,
`GetChromaKeyPayload`, `SRGBCorrectionPass::SetChromaKey`, and
`QSVLRendererXR::FlipFrame`).

| id | from | size | contents |
|---|---|---|---|
| 0x06 `VTE_CAPABILITIES` | both | 32 | two 64-bit capability bitfields at +0 and +16. `vrlink` always sets bit 0 of the first word, plus bit 45 (host chroma-key passthrough) and bit 47 (host threshold via 0x37) when supported. `vrserver` checks the client's capability bits (bit 46 adjusts the chosen stream width), and `vrlink` checks host bit 47 before reading 0x37. |
| 0x33 `VTE_PROP_CHROMA_KEY` | client | 8 | byte 0: requested key color, non-zero to enable chroma-key passthrough (`vrlink` sends 2 for green). Byte 1: client threshold (logged by the host). Byte 2 bit 0: translucent optical display flag. When client bit 45 is set in 0x06, the host waits for 0x33 before starting the stream. |
| 0x34 `VTE_ROOMVIEW_ENABLED` | client | 4 | `u32`, non-zero while passthrough is active behind the stream; sent in reply to 0x36. |
| 0x36 | host | 4 | `u32`, non-zero requests passthrough on the client (`"Host asked for room view on/off"`). **inferred** from the SteamVR settings description of the key modes: indicates whether passthrough cameras need to run for the current scene. |
| 0x37 | host | 8 | byte 0: per-application key threshold `round(chromaKeyNoiseFloor * 255)` in `0...128`; `0` means unset, in which case `vrlink` uses `0.04`. |

SteamVR reads `chromaKeyMode` (0 auto, 1 protect content, 2 key content),
`chromaKeyColor` (1 red, 2 green, 3 blue, 4 cyan, 5 magenta, 6 yellow), and
`chromaKeyNoiseFloor` (`0...0.5`, labeled "Key Threshold" in the UI, default
`0.3`) from the active application's settings section, or from `steamvr` when no
application is running. Only the threshold is sent over value transport (0x37).
The active key color and room-dimming flag travel in every frame's metadata
`u16` at +0xEE: bits 11...13 store the color index (0 and 7 disable keying), and
bit 10 requests passthrough dimming (`vrlink` fades passthrough to 25% brightness
over 50 ms). Key mode is handled entirely on the host, which shifts scene colors
away from the key color in the "protect content" modes so only explicitly keyed
pixels reveal passthrough.

`vrlink` implements chroma keying in the `vChromaKeyColor` fragment shader
(ported to `hostKeyed` in `quad.frag` and `Quad.metal`). That shader also
confirms the stream's Y'CbCr matrix: it reconstructs Y'CbCr from sampled RGB
using BT.2020 constants, while `SetChromaKey` computes the expected sampled key
color by encoding the RGB key with the BT.709 matrix and decoding it with
BT.2020. Every `vrlink` stream shader applies the 3x3 `_valve1_d2020d709`
matrix, which matches the inverse of that BT.709-to-BT.2020 pair to three
decimal places, confirming that SteamVR hosts encode using the BT.709 matrix and
should be decoded as BT.709 (`FrameLayout.encodedWith`, `ColorProbe`).
