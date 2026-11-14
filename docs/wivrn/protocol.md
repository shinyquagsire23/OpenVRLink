# WiVRn: what this client speaks of it

[WiVRn](https://github.com/WiVRn/WiVRn) streams OpenXR applications from a Linux
computer. Its protocol is open; everything here was read from its source at
release **26.9** (`common/wivrn_packets.h`, `wivrn_serialization.h`,
`wivrn_sockets.cpp`, `server/driver/wivrn_connection.cpp`) and is marked
**source**, or was seen working against a 26.9 host on 2026-11-13 and is marked
**measured**. WiVRn is GPL-3; none of its code is in this repository, only a
description of what goes over the wire and an implementation written from it
(`client/Sources/VRLinkCore/WiVRn/`).

Not done yet: encryption and pairing (the host must be started with
`--no-encrypt`), the host's list of applications.

## One release, one protocol

The first packet a client sends carries a 64-bit number that the host compares
with its own and refuses on any difference (**source**). The number is an FNV-1a
hash of a description of every packet in both directions: each field's type,
and for enumerations each name and value. Adding a button to the list of
controller inputs changes it. So a client speaks to exactly one release, and
`WiVRnPackets.swift` is written again for each.

| release | number | how it was had |
|---|---|---|
| 26.9 | `fc26e619b7ab80f8` | **measured**: what a 26.9 host announces |

A host announces itself by mDNS as `_wivrn._tcp` with TXT records `version`,
`protocol` (the number above, in hex) and `cookie` (**measured**). The port is
9757 unless configured otherwise (**source**).

## Wire format (**source**; the packets this client uses, **measured**)

A packet is one byte saying which packet it is (its place in the list of all
packets of that direction), then its fields in order with no padding, numbers
little-endian.

| type | on the wire |
|---|---|
| integer, float, enumeration | its bytes; an enumeration with no stated size is 32 bits |
| `bool` | one byte |
| string, list, byte run | a length, then the elements |
| length | 16 bits when under `0x7fff`; otherwise the low 15 bits with the top bit set, then the rest in 16 more |
| optional | one byte 0 or 1, then the value if 1 |
| one of several types | one byte saying which, then that type |
| `XrPosef` | orientation x, y, z, w, then position x, y, z (28 bytes) |
| `XrFovf` | angles to the left, right, upper and lower edges, radians (16 bytes) |
| time | signed 64 bits, nanoseconds on the headset's clock |

Two sockets to the same port:

- **control**, TCP: each packet has its length in front as 32 bits.
- **stream**, UDP: one packet to a datagram.

Either packet may arrive on either socket; the host sends video, audio and
time queries on the stream and the rest on control.

## Connecting (**source**, **measured** with encryption off)

| | headset | host |
|---|---|---|
| 1 | control: `crypto_handshake` (the number, a public key in PEM, the headset's name) | |
| 2 | | control: `crypto_handshake` (its key, and a state: 0 encryption off, 1 PIN needed, 2 already paired, 3 no new headsets, 4 wrong number) |
| 3 | control: `crypto_handshake` with nothing in it | |
| 4 | | control: `handshake` (its UDP port) |
| 5 | stream: `handshake`, repeated until answered | |
| 6 | | control: `handshake` again |
| 7 | control: `headset_info_packet` | |

With encryption off the host still reads the key in step 1 and refuses the
connection if it is not one; any key will do (this client sends an X25519 one
made up on the spot).

`headset_info_packet` says what one eye is rendered at and what it is encoded
at, the refresh rates, the bitrate, a speaker and microphone format, the eyes'
frusta, what tracking there is, and the codecs the headset decodes in order of
preference. Asked for 2048 x 2048 rendered and 1536 x 1536 encoded with HEVC
first, a host with NVENC chose 10-bit HEVC for both eyes at 24.6 Mbit/s each of
the 50 asked for (**measured**).

An encoder asked for more pixels than it can do says nothing and delivers
fewer frames. NVENC on an NVIDIA GB10, two HEVC streams, 120 Hz asked for
(**measured**, 2026-11-13; 8-bit and 10-bit alike):

| one eye encoded | frames/s | megapixels/s, both eyes |
|---|---|---|
| 2560 x 2048 | 66 | 692 |
| 2208 x 1792 | 84 | 665 |
| 2048 x 1632 | 98 | 655 |
| 1536 x 1536 | 120 | 566 (not the limit) |

So the client sizes the encoded picture from a budget of pixels a second
(`WiVRnSession.encodedPixelsPerSecond`), not from a fixed share of the
rendered one.

A host withdraws its mDNS announcement while a headset is connected and
announces again when the control connection closes (**source**, `server/main.cpp`).

The host streams nothing until an OpenXR application has a session
(**measured**). A `session_state_changed` of 5 (focused) tells it the headset is
being looked through.

## Video (**source**, **measured**)

Each eye is a video stream of its own (stream 0 left, 1 right; 2, at half size,
carries transparency for passthrough). `video_stream_description` gives one
eye's encoded size and the codec of each.

A frame of one stream arrives as numbered **shards** of at most 1400 bytes of
Annex B. The first shard of a frame carries, for both eyes:

- when the frame is meant to be seen
- the pose each eye was rendered from, in the space the headset reports its head in
- each eye's frustum
- how each eye's picture was squeezed (below)

and the last carries four times of the host's own (encoding and sending begun
and ended). Nothing is sent twice and there is no parity. The headset reports
on every frame of every stream with `feedback`: when its first and last shards
came, when it went to the decoder and came out, when it was drawn and shown.
A report without "went to the decoder" tells the host the frame was lost, and
its next frame of that stream is a keyframe.

### Foveation

The host squeezes each eye's picture along both axes in bands. For one axis it
sends a list of an odd number of counts: how many encoded pixels each band has.
The middle band is one source pixel to an encoded pixel, the bands either side
two to one, the next three to one, and so on. A band of one axis crossed with a
band of the other is a rectangle at one scale, so the client draws each as a
quad (`WiVRnSession.layout`): its share of the unsqueezed picture is its share
of the frustum, the picture being linear in the tangent of the angle.

2048 x 2048 squeezed into 1536 x 1536 came as five bands each way
(**measured**); drawn as 25 quads per eye, hello_xr's cubes are square and no
seams show.

The bands change while streaming, and the two eyes' need not match: one eye
came in 11 bands across while the other came in 17 (**measured**, 2026-11-14,
with no gaze sent). A band of no pixels is left out, so the eyes do not have
the same number of quads.

### Transparency (**source**, **measured** with WayVR's see-through mode)

A headset that declares passthrough lets applications ask for a picture with
transparent parts. The first shard of each frame says whether this frame has
any; when it has, a frame of stream 2 comes with it: one picture, as wide as
an eye's and half as tall, whose brightness is how opaque the colors are. The
left eye's is in its left half and the right eye's in its right, each squeezed
by the same bands as the colors (so a point at `(u, v)` of an eye's picture is
at `((u + eye) / 2, v)` of this one, in fractions). The colors come already
multiplied by the opacity.

The third stream is encoded like the others and counts against the encoder:
1600 x 1600 per eye for a 120 Hz display fell to 97 frames a second when
WayVR's transparent background brought it in (**measured**), so the client's
budget counts it from the start.

## Tracking (**source**, **measured** for the head)

The host says which devices it wants located and how far ahead of the asking
(`tracking_control`: a list of device and nanoseconds, retuned about once a
second as it measures the delay; 20 to 25 ms for the head on a wired LAN). The
headset answers with `tracking` packets on the stream, each saying when it was
made and what time its poses are for: the head, with velocities along the
world's axes, and each eye's pose on the head and its frustum. Eye geometry can
therefore change while streaming.

This client sends the head's last known pose carried forward by its velocities
(`TrackedPose.predicted`); a platform that can be asked for the pose at a time
should be asked instead. Controllers are carried forward the same way, with
half their turning rate (`ControllerState.spinSent`, the figure settled on for
Steam hosts), and the host is told that reduced rate too: with all of it,
small movements overshot badly on the headset (2026-11-14), and asking ARKit
for the controller at the later time was no better.

### What the hands hold (**source**; poses **measured**, inputs and haptics not yet seen to act)

Every tracking packet says what each hand holds (`interaction_profile`: 0
nothing, 2 a bare hand as OpenXR's hand-interaction device, 17 a Touch
controller, and two dozen other controllers), and carries poses for it by
device number:

| | left | right |
|---|---|---|
| grip | 11 | 14 |
| aim | 12 | 15 |
| pinch pose (bare hand) | 45 | 81 |
| poke pose (bare hand) | 48 | 84 |

With a pretend Touch controller in one hand and a pretend bare hand in the
other, hello_xr drew its cube at each grip, and the host's list of what to
locate grew by six poses (**measured**).

Buttons, triggers and sticks go in `inputs`: a list of input number, value
and the time the value last changed. This client sends every input with every
tracking packet, so one lost is made good by the next. The numbers used are
in `WiVRnInput.swift`; the right hand's follow the left's in the same order.
For a bare hand the inputs are pinch, aim-and-pinch and grasp, each a value
and a "ready".

A hand's 26 joints go in `hand_tracking`, once a frame, for the hands the
host's list asks for (devices 90 and 91): position, rotation packed into 32
bits (two bits name the largest of x, y, z, w; the other three follow at ten
bits each), velocities, a radius, flags.

The host asks for vibration with `haptics`: a device (1 and 2 the
controllers, 3 to 6 their triggers and thumb rests), a duration in
nanoseconds, a frequency, an amplitude. The headset's battery goes in
`battery`.

### Coming back to a session

The host keeps a session while an application is attached to it, and takes a
headset back into it only if the headset describes itself as before
(**source**, `wivrn_session.cpp`): the same system name, the same list of
refresh rates, the same palm, presence, passthrough and body-tracking
answers, and frusta equal to the bit. Otherwise it sends a message,
"Headset incompatible with session: headset features changed", and closes
(**measured**, on reconnecting with hand tracking newly declared; hand, eye
and face tracking only earn a warning in the source). A display measured
twice does not give the same frusta twice, so the client keeps what it told
each host and tells it the same again while the display measures about the
same (`WiVRnDisplayMemory`), and sends its refresh rates in one order.

### The rate asked for

The headset names the rate it wants in `headset_info_packet`, and the host
streams at it until told the display runs at another (`refresh_rate_changed`).
A WiVRn host does not ask for rates itself. This client asks for the lowest
rate the display offers, and asks the display for the same: the encoder's
budget (above) then buys the most pixels a frame.

### Eyes and face (**source**; not yet seen to act)

Where the eyes look is one more pose in the tracking packet, device 89: on
the head, at its origin, facing the point looked at. The face goes at the end
of the tracking packet as one of several forms; this client sends
XR_FB_face_tracking2's (form 2): a sample time, 70 weights, the confidence in
the lower and the upper face, and two flags. `headset_info_packet` says
whether either will come.

## Clock

All times are the headset's. The host sends `timesync_query` with a time of its
own and the headset returns it with its own time beside it; from those the host
works out the offset. The headset estimates nothing.

## Audio (**source**; the speaker **measured**, the microphone not yet heard)

Raw interleaved 16-bit PCM at the format the headset offered, in `audio_data`
packets on the stream, with no parity.

The microphone goes the other way in the same packet, at the format offered
for it (one channel at 48 kHz here), but only while the host wants it: it
sends `feature_control` (feature 1) on and off as something on the host
starts and stops listening.

## Loss

A picture given up for want of a shard is reported to the host, which makes
that eye's next frame a keyframe. What arrives for that eye before the
keyframe builds on the missing picture: the client reports those as lost
too and gives none of them to the decoder.
