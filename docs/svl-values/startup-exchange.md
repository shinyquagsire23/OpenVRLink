# Startup value exchange

This document describes the startup value exchange above the transport layer:
which values `vrlink` publishes and in what order, how the host responds, and
which subset a client must send before video starts. Transport bring-up
(handshake, keys, and time sync; see docs/svl-transport/) is assumed to be
complete.

Claims are tagged **static** (symbol and file offset in `libvrlink_scene.so`),
**captured** (capture `vr3` between `vrlink` and a SteamVR host, complete and
timestamped alongside `vrlink`'s logcat lines in the same log), or **inferred**.

## 1. Client initialization sequence (**static**)

During initialization, `QSVLClientXR::Init` (+0xfa22c) runs first, followed by
`QSVLClient::Init` (+0xf5e84):

1. Register watches for host ids 0x13, 0x16, 0x23, 0x27, 0x1e, 0x24, 0x2e
   (and, from the renderer and audio objects, 0x17, 0x28, 0x18, 0x19, 0x26;
   from `SVLRoot::Init`, 0x1c and 0x29; from `ByteLogger`, 0x14).
2. Call `UpdateValue(0x25, wifi string)` (skipped on the wire when empty).
3. Call `UpdateValue(0x01, random_u64 | 1)`.
4. Mark ids 0x22, 0x05, 0x15, 0x20, 0x1d, 0x0d, 0x0e, 0x0f, 0x10, 0x11, and
   0x12 dirty.
5. Call `UpdateFrameVariables()` (+0xf5248), which publishes dirty values in
   this fixed order: **0x08 + 0x04** (only when the IPD gate passes; see below),
   0x1d, 0x20, 0x22, 0x05, 0x15, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12.
6. Run `SVLRoot::Init()`, initialize audio at 48000 Hz, and make two
   `SendPoses(0, 0)` calls.
7. Register watches for 0x21 and 0x2b.

After initialization, `UpdateFrameVariables` runs once per frame (posted event
type 2) and `SendPoses` runs on every pose tick; each `SendPoses` call drains
up to 372 bytes of VTS output
([value-transport-wire-format.md](value-transport-wire-format.md)).

The audio object separately publishes 0x18 = 3 (docs/svl-audio/).

### IPD gate (**static**)

`VTE_EYE_TO_HEAD` (0x08) and `VTE_PROJECTION_RAW_PRAMS` (0x04) are published
together, and only when the float at offset 0x3c of the new eye-to-head value
(right-eye x translation, i.e. +IPD/2 in meters) differs from the cached copy by
more than 0.0001. The cache starts at zero. **As a result, a runtime reporting
an IPD of 0 never publishes either value**, which explains Klepton's observation
that "a host told IPD 0 never sends video" (the host never receives 0x08 or
0x04 when IPD is 0). Because that float comparison is the only trigger
afterward, an FOV change without an IPD change is not re-published until
invalidation (**inferred**: the 0x2b handler sets byte flags for ids 4 and 8,
but `UpdateFrameVariables` ignores those flags and checks only the float
comparison, so a prop refresh does not re-send 0x04 or 0x08, whereas
`InvalidateAll` does).

## 2. Captured startup sequence

The timeline below comes from capture `vr3`, which is complete from the first
datagram and timestamped (**captured**; times are milliseconds after `vrlink`'s
first datagram, with `vrlink` log lines in quotes). This session cold-started
the host: its datagram counter was at 5 when `vrlink` received its first packet.

| time (ms) | direction | event |
|---|---|---|
| 0.0–0.2 | C→H | first two pose packets, value transport piggy-backed, version 1: 0x01 (8 bytes), 0x04 (32), 0x05 (507-byte chaperone JSON, 4 chunks), 0x08 (96). Log: "VTE_EYE_TO_HEAD was updated", "VTE_PROJECTION_RAW_PRAMS was updated" |
| 3.8 | H→C | first type-0x0d dataset: acks for all seven chunks so far, and the host's 0x02 (8), 0x19 (`03 00 00 00`), 0x1a (`01 00 00 00`), 0x1b (`01 00 00 00`), 0x1f (`01 00 00 00`), 0x26 (47), 0x2e (`01`) |
| 3.9 | H→C | second dataset: the same seven values again, plus three events: 0x27 = 30, 0x29 = 1, 0x2b (4 zero bytes) |
| 3.9–4.4 | C | processes them in arrival order: "Hand tracking status updated: On" (0x2e); "Wireless timeout updated to: 30" (0x27); transport reconnects with QoS marking (0x29; docs/svl-transport/connection-lifecycle.md §1.1); "Server requested prop refresh" (0x2b), which regenerates the chaperone |
| 4.4–30 | C→H | acks, then the rest of version 1 in `UpdateFrameVariables` order: 0x0d, 0x0e, 0x0f (1161 each, 10 chunks, two chunks per pose packet), then in one packet 0x10, 0x11, 0x12 (12 each), 0x13 (focus event, code 5), 0x15 (`03 00 00 00 01 00 00 00`), 0x18 (`03 00 00 00`), 0x20 (20: one rate, 120.0 Hz), 0x22 (`qvlclient;hollywood;2.0.20.1812`). Log: "VTE_PROPS_STATIC_HMD was updated" … |
| 6–8 | C | first sight of host id 0x02 → "All VTEs Invalidated." (takes effect on the wire once version 1 is delivered) |
| 23 | H→C | acks for 0x0d, 0x0e, and the start of 0x0f; the host's seven plain values again as **version 2** (its own invalidation, triggered by `vrlink`'s 0x01) |
| 32–71 | C→H | every non-event client value again as version 2 (0x05 also as version 3), plus 0x23 (audio state, 10 bytes) for the first time |
| 33.4 | H→C | acks through 0x22 and, in the same dataset, **0x21 = 120.0** (float). The rate request arrives 3.1 ms after 0x20 left `vrlink`. Log: "Received display frequency request update", "XRQRequestRefreshRate: Set refresh rate to 120.0Hz" |
| 38.4 | C→H | 0x0c = 8333 (u32 µs). Log: "VTE_REQ_FRAMETIME_US was set to 8333" |
| 41.7 | H→C | acks up to and including 0x0c. **This is the host's last type-0x0d dataset.** |
| 42–926 | C→H | `vrlink` repeats its 39 still-unacked chunks 27 times (value-transport-wire-format.md §7.4); the host sends only one text message, `[SVLS] ResetVideoStream`, at 209 ms |
| 926 | H→C | first frame descriptor of frame 0 and its video packets; the descriptor's trailer acks everything outstanding. `vrlink`'s value transport stays silent for the rest of the session |
| 1037 | H→C | frame 0 complete; a burst of queued frames follows |
| 1051–1069 | H→C | in descriptor trailers: 0x06 (32), 0x17 (104 bytes, `03 00 00 00` then zeros), 0x1c = 1000, 0x29 = 1 again (version 2), and the out-of-table ids 0x35, 0x64, 0x65, 0x67, 0x72. Log: "VTE_PROP_COLOR_CONTROL updated" |
| 1576 | H→C | first host address list (class 3 type 0x18), repeated every 2 s afterward |
| 1855 | H→C | first audio packet |

After 1.07 s, no value-transport data moved in either direction for the
remaining 39 s because no values changed.

Timing observations from this capture:

- **Negotiation finishes in 42 ms**, 0.88 s before the first video packet. The
  0.88 s gap is the host starting its encoder, and `vrlink` published no new
  values during that window.
- **The rate request follows the rate list within 3 ms**, in the same dataset
  that acks 0x20. By then all three static-prop values had already been acked
  in full, so this capture alone does not show whether the host waits for
  static props before sending 0x21; the probe results below show that it does
  not.
- **The host does not wait for version 2.** It requested the refresh rate and
  accepted the 0x0c reply while `vrlink`'s post-invalidation re-send had
  barely started, and began streaming video with that re-send still unacked.
- 0x20 was published twice on the wire (versions 1 and 2). The log line
  "Sending Available Frequency (0/1) = 120.000000 Hz" appears three times, all
  within the first 25 ms: at init, after the prop refresh, and after the
  invalidation. An earlier draft of this document misread those three lines in
  `vr1` (which lacked timestamps) as a 1 Hz repeat. The **static** finding that
  0x20 is re-sent every second until 0x21 arrives
  ([vte-id-table.md](vte-id-table.md)) is therefore unverified by either
  capture, since 0x21 arrived after 33 ms.
- `vrlink` sends its first datagram **before** receiving anything from the
  host, carrying whichever values are queued first. A client does not need to
  wait for the host's 0x02.

In parallel, starting with the third datagram, `vrlink` sends one type-7
dataset per pose packet containing three `TransportValue_t` records
([svlroot-key-value-channel.md](svlroot-key-value-channel.md)), and starting at
930 ms it sends a 17-byte type-0x11 eye-gaze dataset
(docs/svl-tracking-input/).

Ids 0x1d (network test, empty; `vrlink` logs `"Sending Network Test: "` without
sending the value) and 0x25 (Wi-Fi id, empty; log: `"GetWifiSSID: No connection
info"`) were absent from this session and are therefore **not required**.

## 3. Baseline startup values for a new client (**inferred**)

This conservative baseline reproduces every value `vrlink` sent during startup.
It was written prior to live probing; the probe results later on this page
narrow down what a host actually requires (six values on a cold host, and none
on a warm host).

| id | value for a first prototype |
|---|---|
| 0x01 | 8 random bytes, bit 0 of byte 0 set |
| 0x08 | two 3×4 row-major matrices: identity rotation, x translation −IPD/2 and +IPD/2 (non-zero IPD!) |
| 0x04 | `tan` of left/right/down/up half-angles per eye, e.g. `-1, 1, -1, 1` twice |
| 0x20 | `01 00 00 00`, `n`, 8 zero bytes, `n` floats in Hz (n ≥ 1) |
| 0x22 | `qvlclient;<product>;<version>` |
| 0x05 | chaperone JSON ([vte-id-table.md](vte-id-table.md)) |
| 0x15 | `03 00 00 00 01 00 00 00` |
| 0x0d, 0x0e, 0x0f | static props ([static-and-power-props.md](static-and-power-props.md)) |
| 0x10, 0x11, 0x12 | power props |
| 0x18 | `03 00 00 00` (or 0 to ask for audio without FEC — docs/svl-audio/) |

After publishing this initial set, the client should ack every host chunk
(including unknown ids), reply to each 0x21 request with 0x0c, re-send all
non-event values when host id 0x02 changes, and re-send device properties on
0x2b.

Klepton observed that when no refresh rates are available (`"Supported refresh
rates was empty!"`), the host never sends video—consistent with the host
needing 0x20 to pick a rate—and that an IPD of 0 yields no video, which is
explained by the IPD gate withholding 0x08 and 0x04. From static analysis and
passive capture alone, whether static props, chaperone, host defaults, or the
version string were individually required was **unknown** (resolved by the
cold-host probes below).

## Open questions

Two earlier questions have since been resolved: the probe results below
establish which values a host requires, and §2 plus the probe show that the
host sends 0x21 within 3 ms of receiving 0x20 without waiting for static props.

1. Does the host parse the version string in 0x22 (e.g. to gate features by
   client version), and does the `qvlclient` prefix matter?
2. How does the host behave when 0x0c reports a different frame time than 0x21
   requested?
3. What causes the host to send 0x2b, and does it expect 0x04 and 0x08 to be
   re-sent afterward (`vrlink` does not re-send them)?
4. How is render resolution chosen when `automaticStreamFormatWidth` is
   enabled? No VTE carries a client render-target size in either static
   analysis or the capture (the decoder is configured from the stream).
   `QSVLClientXR::GetTargetRenderSize` (+0xfac5c) copies two `u32` values out
   of the XR context and is referenced only from vtables; nothing in
   `libvrlink_scene.so` calls it (**static**). Stream dimensions come from the
   host's own settings; see
   [Stream and render resolution from host logs (2026-11-11)](#stream-and-render-resolution-from-host-logs-2026-11-11)
   below.
5. What is the host doing between 42 ms and 926 ms? Measuring 0.23–0.30 s to
   the first frame on a warm host versus 1.25 s on a cold host suggests most of
   the gap is startup overhead; `[SVLS] ResetVideoStream` at 209 ms is the only
   message sent during that interval.
6. Do the host's three startup events—0x29 (`vrlink` recreates its socket with
   QoS), 0x27, and 0x2b—have any effect on a client that ignores them? The
   probe ignores 0x29 and 0x27 and still receives video.

## Probe results (2026-11-10)

The Python probe (`prototype/minimal/ovrlink/client.py`) published the §3
baseline set as a stationary headset with no controllers and received video:
2217 complete frames in 20 s with none incomplete, and all client values acked
within 2 s (**captured by probe**). Thus the conservative set is *sufficient*;
the minimal required subset is covered under
[Minimum startup set on a cold host (probe)](#minimum-startup-set-on-a-cold-host-probe)
below.

Additional observations from that initial run:

- Host values arrived in the order 0x1f, 0x26, 0x27, 0x29, 0x2b (prop
  refresh, twice), 0x2e, 0x1b, 0x19, 0x1a, then 0x21, then
  `[SVLS] ResetVideoStream`, then video with 0x1c, 0x29, 0x35, 0x64, 0x65,
  0x67, 0x72, 0x06, 0x17 in the descriptors.
- The first run delivered about 120 frames per second despite negotiating
  90 Hz, because the probe's pose packets carried a changing target time (see
  below).
- Audio messages (class 0x0c) arrived at about 300 per second from t = 2 s and
  **stopped at t = 12 s** while video continued. At the time this was
  unexplained (note that the probe sends none of the `cAud*` statistics that
  `vrlink` sends; see the audio probe sections below for the actual cause).
- The probe's frame reports claim every frame decoded and displayed the
  moment it completed, and its pose timestamps are all "now". The host
  accepted both.

### Warm-host value ablation (probe, 8 s sessions)

`prototype/minimal/tools/ablate.py` ran one session per omitted value against
a host where **SteamVR was already running from an earlier session** (all
**captured by probe**):

- Omitting any single startup value changed nothing: the first complete frame
  arrived 0.23–0.30 s after the first datagram, with about 900 frames in 8 s
  and none incomplete.
- Publishing **no values at all**—only pose, frame-report, and statistics
  messages—still produced video within 0.24 s.
- Without value 0x01 (the client instance id), the host never sent its own
  instance id (0x02) and never sent a rate request (0x21).

A warm host therefore streams to any valid session using whatever device
description it already holds. This does **not** show what a cold host requires:
the first session of a fresh SteamVR run took 1.3 s to first frame and is the
case behind Klepton's "no IPD, no video" observation. Testing cold-host
requirements requires letting SteamVR exit between runs.

### Refresh rate and pacing (probe)

These runs were spaced 3 s apart, so the host stayed **warm** throughout and
retained the device description from the probe's first session, which had
offered 90 Hz:

- The host sent 0x21 = 90.0 Hz regardless of what the probe offered in 0x20
  (72 only, 90 only, or 120 only). This does **not** mean 0x21 ignores the
  client's list: in `vr3`, `vrlink` offered 120 Hz to a cold host and received
  120.0. **Inferred**: the host locks in the refresh rate when creating the HMD
  device and repeats that rate on subsequent warm sessions. Offering a
  different single rate to a cold host after a 60 s+ idle gap confirms this
  (see below).
- Delivered frame rate was 90.0 fps with 90 Hz offered and about 73 fps with
  72 Hz offered, and stayed near 90 (88.6 fps) even when the probe's own frame
  counter ran at 60 Hz. At first this looked inconsistent with `vr3`, where the
  agreed rate was 120 Hz and the host delivered 108.3 fps (matching `vrlink`'s
  own loop rate).
- In a controlled A/B test holding everything else equal, writing the current
  time into the pose target-time field (payload +0x10) on every pose packet
  caused the host to deliver about 115 fps, whereas holding target time
  constant within each frame yielded 90.0 fps across four alternating runs. A
  constant 0 also yielded 90.0 fps (see docs/svl-tracking-input/poses.md).

### Initial audio observation (probe)

Audio arrived only in the first session after the host started (~300 messages/s
from t = 2 s to t = 12 s) and in none of roughly thirty subsequent warm
sessions, including full-profile runs. **Inferred**: the host sends audio only
while audio is actively playing, rather than streaming silence continuously.
Consistent with this, `vrlink`'s `vr3` capture received 2913 audio messages in
40 s—nearly identical to the 2907 messages the probe received in its first
session—indicating a fixed 10 s startup burst rather than a continuous stream.
Playing audio on the host during a session confirms this (see below).

### Host statistics seen in descriptors

In the bookend descriptors' string-to-double channel, the host reported
`dTargetBW` and `dEstLinkBW` around 90–97, `dCurBW` around 135–150,
`nLayerCount` = 2, `sRXpps` = 360 (matching the probe's send rate),
`sPingMS` = 0.7, `sTimeConf` = 400, `dFrmsEarly` = 64, and `dFrmsLate` = 0.
Meanwhile, `sRXerr` climbed by almost 1000 per 8 s session while `sRXpass`
stayed at 100, meaning the host counts something in the probe's datagrams as an
error without treating it as packet loss; the cause remains unknown.

### Minimum startup set on a cold host (probe)

SteamVR on the host exits about 30 s after the last client disconnects (the
host's value 0x27 is 30, which `vrlink` logs as `"Wireless timeout updated to:
30"` while SteamVR's status window shows `"Awaiting Wireless Connection
(215)"`), and the next streaming request launches it again. Waiting between
runs therefore gives a cold host. **A 45 s gap was not always long enough** and
produced false positives from a still-warm host; with a 60 s+ gap, every
configuration below reproduced consistently (all **captured by probe** across
10–20 s sessions).

**A cold host starts sending video once it has these six values:**

| id | value | without it (other five present) |
|---|---|---|
| 0x04 | projection | no video (4 of 4 runs) |
| 0x05 | chaperone JSON | no video |
| 0x0d | HMD static props | no video |
| 0x10 | HMD power props | no video |
| 0x15 | host defaults | no video |
| 0x20 | available refresh rates | no video |

Those six values alone were sufficient in 2 of 2 runs (first frame 3.0 s after
the first datagram, 90 fps). The remaining items are not required to start
video on a cold host: 0x01 (client instance id), 0x08 (eye-to-head), 0x22
(version string), controller static and power props (0x0e, 0x0f, 0x11, 0x12),
0x18 (audio capabilities), 0x13 (focus event), and the string-to-double
statistics.

Other observations:

- With every startup value published, the first frame arrived at 1.25 s; with
  only the six required values (or those six plus 0x01, 0x08, and 0x22), it
  arrived at 3.0 s on every run. **Inferred**: the host waits roughly two
  seconds for controller descriptions before starting without them.
- While required values are missing, the host repeatedly sends the prop-refresh
  request (0x2b). Because the probe responds to each 0x2b by re-sending all of
  its values under a new version, its values never settle as acked in those
  runs; that churn is an artifact of the probe's refresh handler, and the host
  behaves normally.
- The host's rate request (0x21) arrives as soon as 0x20 is published, well
  before video starts.
- This refines the explanation of Klepton's "IPD 0, no video" finding: 0x08 is
  not required, 0x04 is, and `vrlink` gates both behind its IPD check, so an
  IPD of zero withholds the projection parameters.
- Once video has started, the host stays warm (see above) for as long as
  SteamVR remains open. Sending the unfocus event (0x13 code 4) did not stop
  video, and a session started 3 s later publishing no values received video in
  0.25 s.

### Why these six values are required (context, not measured)

Based on how SteamVR drivers work (background context rather than something
verified directly in this project), an OpenVR device's properties cannot be
redefined after the device is registered. The host therefore needs the HMD's
description—including its projection frusta—before creating the HMD device.
Controllers have the same constraint, which explains why the host waits about
two seconds to see whether controller descriptions arrive before proceeding
without them.

Because SteamVR does not support dynamic eye-to-head transforms (updating them
in wired drivers is known to cause frame hitches), a client should publish 0x04
and 0x08 once per session from the display's nominal geometry rather than
updating them frame by frame to track IPD or pupil position. To check whether
mid-session updates cause hitches over SVL, a probe can modify 0x08 mid-stream
and monitor the host's frame cadence and `encResets`.

### Audio (probe, refined by `vr3`)

- With audio playing on the host, every session received about 300 audio
  messages per second for its entire duration, whether warm or cold and with or
  without value 0x18 published (**captured by probe**).
- With nothing playing, a session on a warm host received no audio messages.
- The first session after SteamVR starts receives a ~9.7 s burst of audio
  regardless (2907 messages to the probe, 2913 to `vrlink` in `vr3`). In `vr3`
  that burst decodes to digital silence rather than startup sound effects.
  **Inferred**: the host opens its audio stream at startup, detects silence,
  and stops sending after about ten seconds.

### Refresh-rate selection on a cold host (2026-11-10)

The Swift viewer on a 120 Hz display offered 120 Hz as its sole refresh rate to
a cold host. The host requested 120.0 Hz and delivered 119–120 complete frames
per second (**captured by client**). Combined with the probe's 90 Hz runs, this
confirms that the host selects its refresh rate from the client's 0x20 list
when creating the HMD device.

This also explains the `vr3` rate discrepancy (120 Hz agreed, 108.3 fps
delivered to `vrlink` under Klepton): a client whose frame loop sustains the
agreed rate receives frames at that rate, whereas `vrlink`'s loop in `vr3` was
running at 108.3 Hz.

## Stream and render resolution from host logs (2026-11-11)

The table below is **captured** from the host's `vrserver.txt` and
`steamvr.vrsettings` across three sessions on 2026-11-11 (inspecting logs and
settings files only, not host binaries):

| client | identity published | frusta published | host log |
|---|---|---|---|
| Mac viewer | Quest 2 | viewer frusta | `Render Target: 2048 1844`, `Target square view size 2048`, `Stream views 2048x2048 (... aspect ratio 1.00), atlas 2048x8192, mode 0` |
| Vision Pro | Quest Pro | widened display frusta (asymmetric, ~2.75 × 2.21 in tangents) | same three lines |
| Vision Pro, later | Quest Pro | same as above | same three lines |

The host's settings had `driver_vrlink.streamFormatWidth = 2048` with
`automaticStreamFormatWidth = false` (configured by the user in SteamVR's Steam
Link settings):

- Stream tile dimensions come directly from `streamFormatWidth`: every tile,
  both base and foveal, is `streamFormatWidth` square. (In `vr3`, the 1536 tile
  size came from the same host using either an earlier setting or automatic
  mode; the setting at the time was not recorded.)
- The render target that `driver_vrlink` reports to SteamVR ignored both the
  headset identity and the published frusta, staying at 2048 × 1844 (0.9 of the
  width) in all three sessions. SteamVR's own supersampling multiplier is
  applied on top of that size.
- The protocol provides no way for the client to request a render or stream
  resolution. A headset with sharper displays receives only what the host is
  configured to send unless the setting is raised in SteamVR.

Raising that setting hits a ceiling at 2048. When the user set the slider to
4096 on the same day (reported directly, not read from a log), SteamVR wrote
3200 into `steamvr.vrsettings`, yet the stream tiles remained 2048 × 2048.
Because four tiles are stacked vertically in the encoded atlas and video
encoders cap height at 8192 pixels, 2048 is the tallest square tile that fits
this layout (**inferred**).

How `automaticStreamFormatWidth` chooses a tile width—whether from measured
bandwidth, host GPU tier, or client-published properties—remains **unknown**.
