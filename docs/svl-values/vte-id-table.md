# `ValueTransportID` table (the `VTE_*` enum)

The enum has 51 slots (ids 0..50; `InternalUpdateValue` rejects `id >= 0x33`,
`TickUpdate` iterates 0x33 slots — **static**, +0x169584 / +0x169aac). Enum
names are not in the binary as a table; a name is given below only where a log
string next to the call site spells it. Everything else is labeled by what the
code does with it.

Wire format: [value-transport-wire-format.md](value-transport-wire-format.md).
Offsets are file offsets in `libvrlink_scene.so`. Little-endian throughout.

Evidence: **static** = read from the binary; **captured** = decoded from the
streaming capture `vr3` (Klepton `KL_TRACE_NET` trace of the real client
against a real host: complete, untorn, timestamped; every value below was
reassembled in full with `ovrlink/vts.py`); the "seen" column gives the size
and first bytes observed there. Where `vr1` showed something `vr3` did not, it
is named. **inferred** = guess.

In `vr3` the client sent 17 ids and the host 19; ids present in the tables
below and marked "not seen" did not occur in either capture.

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
| 0x13 | *(dashboard / focus event)* | 52 | byte 0 = event code, rest zero. Client sends `4` on losing OpenXR focus, `5` on gaining it | `QSVLClientXR::OnUnFocused` +0xfb578 / `OnFocused` +0xfb600, as events | static | `05` + 51 zero bytes, once, 30 ms in; not repeated after the invalidation — captured |
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
| 0x16 | *(chaperone request)* | any | any update makes the client re-locate its stage space and, if valid, re-publish VTE 0x05 | static: lambda +0xfbce0 | not seen |
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
| 0x29 | *(QoS on/off)* | 4 | `u32` bool → `SVLDataLinkUDP::ChangeQoSState(bool)` +0x1685a0 | static: lambda +0x1665d8 | `01 00 00 00`, as an event in the host's second datagram (3.9 ms) and again as version 2 in bookend trailers at 1.051 s. On the first the client tore down its socket and re-created it on the same local port with `IP_TOS` 255 (log: `SVLDataLinkUDP::Disconnect()` … `Changing tos opt = 255`; docs/svl-transport/connection-lifecycle.md §1.1); the second, being no change, did nothing — captured |
| 0x2b | *(prop refresh request)* | any | any update: `[SVLClient] Server requested prop refresh`; client marks 0x04, 0x05, 0x08, 0x0d–0x12, 0x15, 0x1d, 0x20, 0x22 dirty | static: lambda +0xf81d0 | `00 00 00 00` (the 4 zero bytes `SendEvent(id)` sends), once, in the host's second datagram (3.9 ms), i.e. before the host had received anything but the client's first two packets; the client logged the refresh and re-generated its chaperone — captured |
| 0x2e | *(hand tracking enable)* | 1 | `u8` bool: create / destroy the OpenXR hand trackers; log `[XRQ] Hand tracking status updated: %s` | static: lambda +0xfc478 | `01`, first datagram; the client logged `Hand tracking status updated: On` — captured |

Ids with no reader and no writer in the client: 0x00, 0x03, 0x07, 0x09, 0x0a,
0x0b, 0x2a, 0x2c, 0x2d, 0x2f–0x32. Id 0 cannot be used: `RXMessage` logs
`Unknown VTE` for it.

### Ids outside this client's table (**captured**)

The host (bookend protocol version 14) sends values this client build has no
slot for. They arrive in bookend trailers as ordinary single-chunk values —
in `vr3` all five first appear at 1.052 s, in the bookend after the one that
introduced 0x06, 0x17, 0x1c and 0x29, and are carried by 12 bookends in a
row (18 ms) until the client's acks are processed — and the client acks them (it
acks any data chunk before looking at the id) and never reads them:

| id | size | value seen |
|---|---|---|
| 0x35 | 4 | `00 00 00 00` |
| 0x64 | 1 | `00` |
| 0x65 | 1 | `00` |
| 0x67 | 1 | `00` |
| 0x72 | 1 | `00` |

A compatible client must parse and ack them. What they mean is unknown apart
from 0x35 (next section).

### What the host tells a client about what is running (**captured**, 2026-11-11)

Two sessions with the Swift client logging every host value and every
message it does not act on, whenever the bytes changed (`OPENVRLINK_LOG_HOST=1`):

- Mac viewer, 190 s from a cold SteamVR start, nothing launched: every value
  below was sent once and never changed, 0x06 included.
- Vision Pro, about 3 minutes: bare hands, dashboard dismissed, two
  controllers connected, dashboard opened, The Lab (`steam.app.450390`)
  launched from it, The Lab quit from the dashboard about 12 s later.

| id | size | idle | while The Lab ran | reading |
|---|---|---|---|---|
| 0x35 | 4 | `00 00 00 00` | `01 00 00 00` (version 2), back to `00 00 00 00` (version 3) as it quit | **inferred**: `u32`, non-zero while a scene application is running. The host's `vrserver.txt` has The Lab connecting and "Clearing application steam.app.450390" at times that fit the two changes (the client's log had no clock, so the fit is to the second, by counting its once-a-second lines) |
| 0x06 | 32 | `6e cf bd fe 6f 2b 00 …` then zeros | unchanged | not tied to applications. The same six bytes in both sessions, which had different host instance ids (0x02), so it is not per session either; still unknown |
| 0x1b, 0x1f | 4 | `01 00 00 00` | unchanged | unknown |
| 0x64, 0x65, 0x67, 0x72 | 1 | `00` | unchanged | unknown |
| 0x17 | 104 | `03 00 00 00` then zeros | unchanged | color control was not in use by either scene |
| 0x21 | 4 | 120.0, then 90.0 on the headset (version 5) | unchanged | follows the display, not the application |

Opening and closing the dashboard, and connecting controllers, changed no
value. The only message not acted on was the host address list (class 3 type
0x18), identical every 2 s.

So a client is told **that** a scene application is running, and nothing
about **which**: no app id, name or key in any value, in discovery
(`games_running` is a single flag, docs/remoteplay/) or in either reference
client build's strings. One title was tried; whether 0x35 ever takes a value
other than 0 and 1 (a count, or a state such as loading) is not known.
Deciding anything per title is not possible from the protocol as understood.

The Swift client uses 0x35 for one thing: with the setting `chromaKeyOffInGames`
the chroma key applies in SteamVR's own grid and is dropped while 0x35 is not
zero (`StreamSession.sceneApplicationRunning`).

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

**static**: the receive lambda +0xfbdfc logs
`VTE_CLIENT_AUDIO_STATE %d(%d) %d/%d(%d) - %d(%d) %d/%d(%d)` with bytes
`4(0) 7/6(2) - 5(1) 9/8(3)` and applies: byte 0 → `SetSystemVolumeMute(b4)`,
byte 1 → `SetMicrophoneMute(b5)`, byte 2 → `SetSystemVolume(b7)`. The client
sends `01 01 01 00, muted, micMuted, steps, volume, ff ff` (+0xfa6e0);
**captured** `01 01 01 00 00 00 10 0f ff ff` (16 steps, volume 15).

### `VTE_CLIENT_CHAPERONE` (0x05)

**captured** (formatted; one universe; this run had no guardian so bounds are
degenerate):

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

Each collision-bounds quad is a wall: two floor corners and the same two
corners at height 2.43 m (**inferred** from the shape; SteamVR's
`chaperone_info.vrchap` uses the same layout). `play_area` is `[width, depth]`
in meters. Key strings are **static** in `ChaperoneXR::Generate` +0x12ec58.

## Open questions / to confirm on the wire

1. Names and meaning of host ids 0x06 (32 bytes), 0x1b, 0x1f (4 bytes, value 1)
   — only the host binary can say; the client ignores them.
2. Meaning of the out-of-table ids 0x64/0x65/0x67/0x72, and whether 0x35
   (scene application running, **inferred**) takes values besides 0 and 1.
   The newest client build (2.0.25) was not searched for readers of them.
3. The non-zero fields of 0x17 when color control is actually in use (both
   captures: version word 3, the rest zero). The payloads of 0x27 and 0x2b
   are now captured (30, and four zero bytes).
7. Whether 0x20 really is re-sent once a second while no 0x21 has arrived
   (static; in `vr3` the request came after 33 ms, so the timer never showed).
8. What updates 0x06 (`vr3`: one version in 40 s; `vr1`: three; two sessions
   on 2026-11-11, one with an application launched and quit: one version each).
4. Whether the host reads 0x13 codes other than 4/5, and what other codes it
   sends besides 2.
5. Whether 0x1d / 0x25 matter to the host (both were empty, hence absent, in a
   session that streamed fine — so they are not required).
6. The 24-byte shader-push header's first `u32` and last 8 bytes.
