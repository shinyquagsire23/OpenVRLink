# WiVRn protocol

[WiVRn](https://github.com/WiVRn/WiVRn) streams OpenXR applications from a Linux
host. Its wire protocol is open source; everything documented here was read from
the WiVRn **26.9** source tree (`common/wivrn_packets.h`,
`wivrn_serialization.h`, `wivrn_sockets.cpp`,
`server/driver/wivrn_connection.cpp`, tagged **source**) or verified against a
live 26.9 host on 2026-11-13 (tagged **measured**). Because WiVRn is licensed
under GPL-3, this repository contains no WiVRn code—only this wire-protocol
description and a clean-room Swift implementation in
`client/Sources/VRLinkCore/WiVRn/`.

Encryption, PIN pairing (the host must currently be started with
`--no-encrypt`), and querying the host's application list are not implemented
yet.

## Protocol versioning

The first packet sent by a client carries a 64-bit protocol ID that the host
compares against its own, rejecting the connection on any mismatch (**source**).
The ID is an FNV-1a hash of the type definitions of every packet in both
directions, including each field's type and each enum's member names and values.
Adding even a single controller input enum entry changes the hash. Consequently,
a client build speaks to a specific WiVRn release, and `WiVRnPackets.swift` must
be updated whenever the packet definitions change.

| release | protocol ID | verification |
|---|---|---|
| 26.9 | `fc26e619b7ab80f8` | **measured**: advertised by a 26.9 host |

A host advertises itself via mDNS as `_wivrn._tcp` with TXT records `version`,
`protocol` (the 64-bit protocol ID in hex), and `cookie` (**measured**). The
default port is 9757 unless configured otherwise (**source**).

## Wire format (**source**; packets used by this client **measured**)

Each packet begins with a 1-byte packet type index (its zero-based position in
the packet list for that direction), followed by its fields serialized in
declaration order with no alignment padding and little-endian byte order for
multi-byte scalars.

| type | wire encoding |
|---|---|
| integer, float, enum | little-endian bytes; an enum with no explicit underlying size is 32 bits |
| `bool` | 1 byte (`0` or `1`) |
| string, list, byte array | length prefix followed by the elements |
| length prefix | 16 bits when `< 0x7fff`; otherwise the low 15 bits with the top bit set, followed by the upper bits in a second 16-bit word |
| optional (`std::optional`) | 1-byte presence flag (`0` or `1`), followed by the value when `1` |
| variant (`std::variant`) | 1-byte alternative index, followed by the selected type |
| `XrPosef` | orientation quaternion `x, y, z, w` followed by position `x, y, z` as float32 (28 bytes) |
| `XrFovf` | left, right, upper, and lower half-angles in radians as float32 (16 bytes) |
| timestamp / duration | signed 64-bit integer, nanoseconds on the headset's clock |

A session uses two sockets connected to the same host port:

- **Control (TCP)**: Each packet is prefixed with a 32-bit byte length.
- **Stream (UDP)**: Each datagram carries a single packet with no length prefix.

Any packet type can travel over either socket; in practice, the host sends video
shards, audio frames, and clock-sync queries over the UDP stream socket and
sends control messages over TCP.

## Connecting (**source**; **measured** with encryption disabled)

| | headset | host |
|---|---|---|
| 1 | control: `crypto_handshake` (protocol ID, client public key in PEM format, headset name) | |
| 2 | | control: `crypto_handshake` (host public key, state: `0` encryption disabled, `1` PIN needed, `2` already paired, `3` pairing disabled, `4` incompatible protocol ID) |
| 3 | control: empty `crypto_handshake` | |
| 4 | | control: `handshake` (host UDP port) |
| 5 | stream: `handshake`, repeated over UDP until acknowledged | |
| 6 | | control: `handshake` confirmation |
| 7 | control: `headset_info_packet` | |

Even when encryption is disabled (`--no-encrypt`), the host parses the PEM
public key in step 1 and rejects the connection if it is missing or invalid. Any
valid PEM public key is accepted; this client sends an ephemeral X25519 public
key generated at connection time.

`headset_info_packet` declares the per-eye render resolution, per-eye encoded
video resolution, supported and preferred refresh rates, target bitrate, speaker
and microphone audio formats, per-eye FOV frusta, supported tracking features,
and supported video codecs in preference order. When this client requested
2048 x 2048 rendered and 1536 x 1536 encoded with HEVC first and a 50 Mbit/s
total bitrate, a host with NVENC selected 10-bit HEVC for both eyes at
24.6 Mbit/s per eye (**measured**).

If the requested encoded pixel rate exceeds hardware encoder capacity, the host
reports no error and simply delivers fewer frames per second. Throughput on an
NVIDIA GB10 (NVENC, two HEVC streams, 120 Hz requested; **measured** 2026-11-13,
identical for 8-bit and 10-bit):

| per-eye encoded resolution | frames/s | megapixels/s, both eyes |
|---|---|---|
| 2560 x 2048 | 66 | 692 |
| 2208 x 1792 | 84 | 665 |
| 2048 x 1632 | 98 | 655 |
| 1536 x 1536 | 120 | 566 (below encoder limit) |

Accordingly, the client computes its encoded video resolution from a pixel-rate
budget (`WiVRnSession.encodedPixelsPerSecond`) rather than using a fixed ratio
of the render resolution.

A host withdraws its mDNS announcement while a headset is connected and
re-announces itself when the TCP control connection closes (**source**,
`server/main.cpp`).

The host streams no media until an OpenXR application opens a session
(**measured**). Sending `session_state_changed` with state `5` (focused) tells
the host that the headset is actively worn.

## Video (**source**, **measured**)

Each eye uses its own video stream (stream 0 for the left eye, stream 1 for the
right eye, and stream 2 at half dimensions for passthrough alpha).
`video_stream_description` gives the per-eye encoded dimensions and the codec
selected for each stream.

Each encoded frame arrives as indexed UDP **shards** carrying up to 1400 bytes
of Annex B bitstream data. The first shard of a frame includes metadata covering
both eyes:

- target display time
- rendered eye poses in the headset's head-tracking space
- per-eye FOV frusta
- per-eye foveation band parameters (described below)

The final shard carries four host timestamps (encode start/end and send
start/end). WiVRn uses neither retransmission nor FEC parity. For every frame on
every stream, the headset sends a `feedback` packet reporting timestamps for
first-shard arrival, last-shard arrival, decode submission, decode completion,
drawing, and display. Omitting the decode-submission timestamp tells the host
that the frame was lost, causing the next frame on that stream to be encoded as
a keyframe.

### Foveation

The host compresses each eye's image along both X and Y in rectilinear scale
bands. For each axis, it sends an odd-length list of encoded pixel counts per
band: the center band runs at 1:1 (one source pixel per encoded pixel), the
adjacent bands on either side at 2:1, the next pair at 3:1, and so on outward.
Crossing the horizontal bands with the vertical bands produces a grid of
constant-scale rectangular tiles, each drawn by the client as a world-space quad
(`WiVRnSession.layout`). Because rectilinear projection is linear in FOV tangent
space, each band's fraction of the unscaled image equals its fraction of the
tangent frustum.

A 2048 x 2048 render target compressed into 1536 x 1536 used five bands per axis
(**measured**); rendered as 25 quads per eye, `hello_xr`'s cubes appear square
with no visible seams.

Foveation bands can change mid-stream and do not need to match between eyes: in
one capture without eye gaze (**measured**, 2026-11-14), one eye used 11
horizontal bands while the other used 17. Zero-pixel bands are omitted, so the
two eyes can produce different quad counts.

### Alpha passthrough (**source**; **measured** with WayVR see-through mode)

When a headset advertises alpha-blend passthrough support, OpenXR applications
can submit frames with transparent regions. A flag in the first shard indicates
whether the frame includes alpha; when set, stream 2 delivers a companion frame
as wide as one eye's image and half as tall, where luma encodes opacity. The
left eye's alpha occupies the left half and the right eye's alpha occupies the
right half, compressed with the same foveation bands as the color streams (so
normalized coordinates `(u, v)` in an eye's color image map to
`((u + eye) / 2, v)` in the alpha image). RGB color streams arrive premultiplied
by alpha.

Stream 2 runs on the hardware encoder alongside the color streams and shares the
same throughput budget: streaming 1600 x 1600 per eye for a 120 Hz display
dropped to 97 fps when WayVR enabled its transparent background (**measured**),
so the client reserves encoder pixel budget for stream 2 from the start.

## Tracking (**source**; head tracking **measured**)

The host sends `tracking_control` packets (~1 Hz) listing the device IDs to
report and how many nanoseconds ahead to predict poses (retuned continuously
from measured latency; typically 20–25 ms for the head over wired Ethernet). The
headset replies over UDP with `tracking` packets containing a production
timestamp, the target pose timestamp, the head pose with world-space velocities,
and per-eye head-relative poses and frusta (allowing eye geometry to update
mid-stream).

This client extrapolates the latest known head pose forward using its velocities
(`TrackedPose.predicted`); platforms whose tracking API supports querying a
future timestamp directly should do so instead. Controller poses are
extrapolated the same way, but using half of their angular velocity
(`ControllerState.spinSent`, matching the scale used for Steam hosts) and
reporting that halved angular velocity to the host. Using the full angular
velocity caused small controller motions to overshoot noticeably on the headset
(2026-11-14), and querying ARKit at the future timestamp showed the same
overshoot.

### Controllers and hand input (**source**; poses **measured**, button inputs and haptics unverified)

Every `tracking` packet declares each hand's active `interaction_profile` (`0`
none, `2` bare hand as OpenXR's hand-interaction profile, `17` Oculus Touch
controller, among roughly two dozen supported controller profiles) and carries
poses keyed by device ID:

| | left | right |
|---|---|---|
| grip | 11 | 14 |
| aim | 12 | 15 |
| pinch pose (bare hand) | 45 | 81 |
| poke pose (bare hand) | 48 | 84 |

Testing with a simulated Touch controller in one hand and a simulated bare hand
in the other caused `hello_xr` to render a cube at each grip and added six pose
IDs to the host's `tracking_control` list (**measured**).

Buttons, triggers, and thumbsticks are sent in `inputs` packets as a list of
`(input_id, value, last_change_time)` entries. This client includes every active
input in each tracking update so a dropped UDP packet is recovered by the next
packet. Input ID definitions live in `WiVRnInput.swift`, with right-hand IDs
following left-hand IDs in the same order. For bare hands, the reported inputs
are pinch, aim-and-pinch, and grasp, each paired with a `ready` boolean.

Skeletal hand tracking sends 26 joints per hand once per frame in
`hand_tracking` packets whenever requested by the host (device IDs 90 and 91).
Each joint carries position, a 32-bit smallest-three quaternion (2 bits naming
the largest component among `x, y, z, w`, followed by the remaining three
components at 10 bits each), linear and angular velocities, joint radius, and
tracking flags.

The host triggers vibration with `haptics` packets specifying a target actuator
ID (`1` and `2` for the left and right controllers, `3`–`6` for trigger and
thumbrest actuators), duration in nanoseconds, frequency, and amplitude. Headset
battery state is sent in `battery` packets.

### Reconnecting to an existing session

The host keeps an OpenXR session alive while an application remains attached,
and allows a reconnecting headset to rejoin only if its `headset_info_packet`
matches the original session (**source**, `wivrn_session.cpp`): identical system
name, identical refresh-rate list, identical palm-pose, user-presence,
passthrough, and body-tracking flags, and bitwise-equal eye FOV frusta. On any
mismatch, the host sends `"Headset incompatible with session: headset features
changed"` and closes the connection (**measured** when reconnecting with hand
tracking newly enabled, although hand, eye, and face tracking changes only log a
warning in upstream source). Because querying display geometry across runs can
return slightly different floating-point frusta, `WiVRnDisplayMemory` caches the
frusta previously reported to each host, reuses them while newly measured values
stay within tolerance, and sends refresh rates in a deterministic order.

### Refresh rate selection

The headset specifies its target refresh rate in `headset_info_packet`, and the
host streams at that rate until the client sends `refresh_rate_changed`; WiVRn
hosts never initiate refresh-rate changes on their own. This client requests the
lowest refresh rate supported by the display (and configures the display to
match) so the encoder's pixel-per-second budget yields the highest spatial
resolution per frame.

### Eye gaze and face tracking (**source**; unverified end-to-end)

Eye gaze is carried as device ID 89 in the `tracking` packet: a head-relative
pose at the head origin oriented toward the gazed point. Face tracking data is
appended to the end of the `tracking` packet as a variant payload; this client
sends variant 2 (`XR_FB_face_tracking2`), carrying a sample timestamp, 70
blendshape weights, lower- and upper-face confidence values, and two flags.
Support for both features is declared in `headset_info_packet`.

## Clock synchronization

All protocol timestamps use the headset's monotonic clock. The host periodically
sends `timesync_query` carrying a host timestamp, and the headset echoes that
timestamp alongside its current local time so the host can compute the clock
offset; the client does not maintain a clock offset estimate of its own.

## Audio (**source**; speaker output **measured**, microphone uplink unverified)

Speaker audio arrives over UDP in `audio_data` packets as raw interleaved 16-bit
PCM matching the format advertised by the headset, with no FEC parity.

Microphone audio travels from headset to host in the same `audio_data` packet
format (configured here as 48 kHz mono), gated by the host: the host sends
`feature_control` (feature `1`) to enable and disable microphone capture as host
applications start and stop recording.

## Frame loss

When a video frame cannot be reassembled due to a missing UDP shard, the client
sends a `feedback` report omitting the decode-submission timestamp, which
prompts the host to emit a keyframe on the next frame for that eye stream. Any
frames arriving on that stream prior to the recovery keyframe depend on the
missing reference frame, so the client reports them as lost as well and does not
submit them to the decoder.
