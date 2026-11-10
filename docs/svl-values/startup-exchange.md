# Startup exchange above the transport

What the client publishes, in what order, what the host answers, and what a
minimal client has to send before video flows. Transport bring-up (handshake,
keys, time sync) is in docs/svl-transport/ and is assumed complete.

Evidence: **static** (symbol + file offset in `libvrlink_scene.so`),
**captured** (capture `vr3`: real client ↔ real host, complete and
timestamped, plus the client's own logcat lines in the same log),
**inferred**.

## 1. What the client does at init (**static**)

`QSVLClientXR::Init` +0xfa22c, then `QSVLClient::Init` +0xf5e84:

1. Register watches for host ids 0x13, 0x16, 0x23, 0x27, 0x1e, 0x24, 0x2e
   (and, from the renderer and audio objects, 0x17, 0x28, 0x18, 0x19, 0x26;
   from `SVLRoot::Init`, 0x1c and 0x29; from `ByteLogger`, 0x14).
2. `UpdateValue(0x25, wifi string)` (skipped on the wire when empty).
3. `UpdateValue(0x01, random_u64 | 1)`.
4. Mark dirty: 0x22, 0x05, 0x15, 0x20, 0x1d, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12.
5. `UpdateFrameVariables()` +0xf5248, which publishes in this fixed order
   whatever is dirty: **0x08 + 0x04** (only when the IPD test passes, below),
   0x1d, 0x20, 0x22, 0x05, 0x15, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12.
6. `SVLRoot::Init()`, audio init at 48000 Hz, two `SendPoses(0, 0)` calls.
7. Register watches for 0x21 and 0x2b.

After that `UpdateFrameVariables` runs once per frame (posted event type 2) and
`SendPoses` on every pose tick; each `SendPoses` drains up to 372 bytes of VTS
output ([value-transport-wire-format.md](value-transport-wire-format.md)).

The audio object separately publishes 0x18 = 3 (docs/svl-audio/).

### The IPD gate (**static**)

`VTE_EYE_TO_HEAD` (0x08) and `VTE_PROJECTION_RAW_PRAMS` (0x04) are published
together, and only when the float at offset 0x3c of the new eye-to-head value
(right-eye x translation, i.e. +IPD/2 in meters) differs from the cached copy by
more than 0.0001. The cache starts at zero. **So a runtime that reports an IPD
of 0 never publishes either value** — this is the mechanism behind Klepton's
"a host told IPD 0 never sends video" (the host never receives an IPD of 0; it
receives no IPD at all). The same test is the only trigger afterwards, so a FOV change without
an IPD change is not re-published until a prop refresh. (**inferred**: the
0x2b handler sets byte flags for ids 4 and 8, but `UpdateFrameVariables` does
not consult them — it only uses the float comparison; so even a prop refresh
does not re-send 0x04/0x08. `InvalidateAll` does.)

## 2. The exchange as captured

From capture `vr3`, which is complete from the first datagram and
timestamped (**captured**; times are milliseconds after the client's first
datagram; client log lines in quotes). The host had just been started by this
session: its datagram counter was at 5 when the client first heard it.

| time | direction | what |
|---|---|---|
| 0.0–0.2 | C→H | the first two pose packets, value transport piggy-backed, version 1: 0x01 (8 bytes), 0x04 (32), 0x05 (507-byte chaperone JSON, 4 chunks), 0x08 (96). Log: "VTE_EYE_TO_HEAD was updated", "VTE_PROJECTION_RAW_PRAMS was updated" |
| 3.8 | H→C | first type-0x0d dataset: acks for all seven chunks so far, and the host's 0x02 (8), 0x19 (`03 00 00 00`), 0x1a (`01 00 00 00`), 0x1b (`01 00 00 00`), 0x1f (`01 00 00 00`), 0x26 (47), 0x2e (`01`) |
| 3.9 | H→C | second dataset: the same seven again, plus three events: 0x27 = 30, 0x29 = 1, 0x2b (4 zero bytes) |
| 3.9–4.4 | C | acts on them in arrival order. "Hand tracking status updated: On" (0x2e); "Wireless timeout updated to: 30" (0x27); the transport reconnects with QoS marking (0x29; docs/svl-transport/connection-lifecycle.md §1.1); "Server requested prop refresh" (0x2b), which regenerates the chaperone |
| 4.4–30 | C→H | acks, then the rest of version 1 in `UpdateFrameVariables` order: 0x0d, 0x0e, 0x0f (1161 each, 10 chunks, two chunks per pose packet), then in one packet 0x10, 0x11, 0x12 (12 each), 0x13 (focus event, code 5), 0x15 (`03 00 00 00 01 00 00 00`), 0x18 (`03 00 00 00`), 0x20 (20: one rate, 120.0 Hz), 0x22 (`qvlclient;hollywood;2.0.20.1812`). Log: "VTE_PROPS_STATIC_HMD was updated" … |
| 6–8 | C | first sight of host id 0x02 → "All VTEs Invalidated." (takes effect on the wire once version 1 is delivered) |
| 23 | H→C | acks for 0x0d, 0x0e and the start of 0x0f; the host's seven plain values again as **version 2** (its own invalidation, triggered by the client's 0x01) |
| 32–71 | C→H | every non-event client value again as version 2 (0x05 also as version 3), plus 0x23 (audio state, 10 bytes) for the first time |
| 33.4 | H→C | acks through 0x22 — and, in the same dataset, **0x21 = 120.0** (float). The rate request arrives 3.1 ms after 0x20 left the client. Log: "Received display frequency request update", "XRQRequestRefreshRate: Set refresh rate to 120.0Hz" |
| 38.4 | C→H | 0x0c = 8333 (u32 µs). Log: "VTE_REQ_FRAMETIME_US was set to 8333" |
| 41.7 | H→C | acks up to and including 0x0c. **The host's last type-0x0d dataset** |
| 42–926 | C→H | the client repeats its 39 still-unacked chunks 27 times over (value-transport-wire-format.md §7.4); the host sends nothing but one text message, `[SVLS] ResetVideoStream`, at 209 |
| 926 | H→C | first frame descriptor of frame 0 and its video packets; the descriptor's trailer acks everything outstanding. The client's value transport falls silent for the rest of the session |
| 1037 | H→C | frame 0 complete; a burst of queued frames follows |
| 1051–1069 | H→C | in descriptor trailers: 0x06 (32), 0x17 (104 bytes, `03 00 00 00` then zeros), 0x1c = 1000, 0x29 = 1 again (version 2), and the out-of-table ids 0x35, 0x64, 0x65, 0x67, 0x72. Log: "VTE_PROP_COLOR_CONTROL updated" |
| 1576 | H→C | first host address list (class 3 type 0x18), every 2 s after |
| 1855 | H→C | first audio |

After 1.07 s no value-transport data moved in either direction for the
remaining 39 s: nothing changed, so nothing was sent.

What the timestamps tell us:

- **The whole negotiation takes 42 ms**, and is over 0.88 s before the first
  video packet. The 0.88 s is the host starting its encoder; nothing the
  client sent in that time was new.
- **The rate request follows the rate list immediately** (3 ms), in the same
  dataset that acks it. By then all three static-prop values had been acked
  in full, so this capture cannot say whether the host waits for them; the
  probe results below can (it does not).
- **The host does not wait for version 2.** It requested the rate, and
  accepted the 0x0c reply, while the client's post-invalidation re-send had
  barely begun, and started video with that re-send still un-acked.
- 0x20 was published twice on the wire (versions 1 and 2). The log line
  "Sending Available Frequency (0/1) = 120.000000 Hz" appears three times, all
  within the first 25 ms: at init, after the prop refresh, and after the
  invalidation. An earlier version of this page read the same three lines in
  `vr1` (which has no timestamps) as a once-a-second repeat. The **static**
  claim that 0x20 is re-sent every second until a 0x21 arrives
  ([vte-id-table.md](vte-id-table.md)) is therefore not confirmed by either
  capture: here the request came after 33 ms.
- The client's first datagram is sent **before** it has heard anything, with
  the values that happen to be first in line. A client does not need to wait
  for the host's 0x02.

In parallel: from the third datagram on, one type-7 dataset per pose packet
with three `TransportValue_t` records ([svlroot-key-value-channel.md](svlroot-key-value-channel.md)),
and from 930 ms a 17-byte type-0x11 eye-gaze dataset (docs/svl-tracking-input/).

Not present in this session and therefore **not required**: 0x1d (network
test, empty — the log line "Sending Network Test: " is there, the value is
not), 0x25 (Wi-Fi id, empty; log: "GetWifiSSID: No connection info").

## 3. Minimum a new client should send (**inferred**)

This is the conservative set: reproduce everything the real client sent, with
real values. It was written before any probe; the probe results at the end of
this page show which of it a host actually needs (six values on a cold host,
none on a warm one).

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

and then: ack every host chunk (including unknown ids), answer each 0x21 with
0x0c, re-send everything when host id 0x02 changes, re-send props on 0x2b.

Why each probably matters: Klepton observed that with no refresh rates
("Supported refresh rates was empty!") the host never sends video — consistent
with the host needing 0x20 to pick a rate before step 5; and that IPD 0 gives
no video — explained by the IPD gate withholding 0x08/0x04. Whether static
props, chaperone, host defaults or the version string are individually
required is **unknown**.

## Open questions / to confirm on the wire

Settled since this list was first written: which values a host needs (probe
results below), and when the host sends 0x21 (3 ms after 0x20 reaches it, §2;
independent of the static props, per the probe).

3. Does the host parse the version string in 0x22 (e.g. to enable features by
   client version), and does the `qvlclient` prefix matter?
4. What the host does when 0x0c answers with a different frame time than it
   asked for.
5. What makes the host send 0x2b, and whether it expects 0x04/0x08 again
   afterwards (this client would not re-send them).
6. Render resolution: no VTE carries a client render-target size in either the
   static reading or the capture (the decoder is configured from the stream).
   `QSVLClientXR::GetTargetRenderSize` (+0xfac5c) copies two `u32` out of the
   XR context and is referenced only from vtables: nothing in the library
   calls it (**static**). The sizes are the host's own choice, from its
   settings; see "Host log results (2026-11-11): resolution" below.
7. What the host is doing between 42 ms and 926 ms, and whether the gap is
   shorter on a warm host. The probe's "first frame after 0.23–0.30 s" on a
   warm host and 1.25 s on a cold one suggest most of it is start-up cost;
   `[SVLS] ResetVideoStream` at 209 ms is the only marker inside it.
8. Whether the host's three startup events have a fixed meaning for a client
   that ignores them: 0x29 (vrlink re-creates its socket), 0x27
   and 0x2b. The probe ignores 0x29 and 0x27 and streams.

## Probe results (2026-11-10)

The Python probe (`prototype/minimal/ovrlink/client.py`) published exactly
the section-3 set, as a motionless head with no controllers, and got video:
2217 complete frames in 20 s with none incomplete, all of its values acked
within 2 s. **Captured by probe.** So the conservative set is *sufficient*;
the necessary subset is under "Cold host: the minimum set" below.

Observed on the way:

- Host values arrived in the order 0x1f, 0x26, 0x27, 0x29, 0x2b (prop
  refresh, twice), 0x2e, 0x1b, 0x19, 0x1a, then 0x21, then
  `[SVLS] ResetVideoStream`, then video with 0x1c, 0x29, 0x35, 0x64, 0x65,
  0x67, 0x72, 0x06, 0x17 in the descriptors.
- The first run delivered about 120 frames per second against an agreed
  90 Hz. Explained below: the probe's pose packets carried a bad target time.
- Audio messages (class 0x0c) arrived at about 300 per second from t = 2 s and
  **stopped at t = 12 s** while video continued. Unexplained; the probe sends
  none of the `cAud*` statistics the real client does.
- The probe's frame reports claim every frame decoded and displayed the
  moment it completed, and its pose timestamps are all "now". The host
  accepted this.

### Which values does a host need? (probe, 8 s sessions)

`prototype/minimal/tools/ablate.py` ran one session per omitted value against
a host where **SteamVR was already running from an earlier session**. All
**captured by probe**:

- Omitting any single startup value changed nothing: first complete frame
  0.23-0.30 s after the first datagram, about 900 frames in 8 s, none
  incomplete.
- Publishing **no values at all** - only pose, frame-report and statistics
  messages - still produced video within 0.24 s.
- Without value 0x01 (the client instance id) the host never sent its own
  instance id (0x02) and never sent a rate request (0x21).

So a warm host streams to anyone holding a valid session, using whatever
device description it already has. This does **not** answer what a cold host
needs: the very first session of a SteamVR run took 1.3 s to first frame and
is the case Klepton's "no IPD, no video" observation comes from. To test it,
SteamVR has to be quit on the host between runs.

### Refresh rate and pacing (probe)

These runs were 3 s apart, so the host was **warm** throughout - it still held
the device description from the probe's first session, which offered 90 Hz.
Read them with that in mind.

- The host sent 0x21 = 90.0 Hz whatever the probe offered in 0x20 (72 only,
  90 only, 120 only). This does **not** show that 0x21 ignores the client's
  list: in `vr3` the real client offered 120 Hz to a cold host and was asked
  for 120.0. **Inferred**: the host fixes the rate when it creates the HMD
  device and repeats that rate to later sessions. To confirm: offer a
  different single rate to a cold host (60 s+ gap).
- Delivered frame rate was 90.0 with 90 offered and about 73 with 72 offered,
  and stayed near 90 (88.6) when the probe's own frame counter ran at only 60
  per second. Unreconciled with `vr3`, where the agreed rate was 120 and the
  host delivered 108.3 frames per second, the rate of the client's own loop.
- The one clean A/B here: with everything else equal, writing the current
  time into the pose target-time field (payload +0x10) on every pose made the
  host deliver about 115 frames per second, and holding it constant within a
  frame gave 90.0 - alternated four times. A constant 0 also gave 90.0.
  See docs/svl-tracking-input/poses.md.

### Audio, first observation (probe)

Audio arrived only in the first session after the host came up (about 300
messages per second from t = 2 s to t = 12 s) and in none of some thirty later
sessions, including full-profile ones. **Inferred**: the host sends audio only
while something is playing (SteamVR's startup sounds), rather than a
continuous stream. Supporting it: the real client's `vr3` capture got 2913
audio messages in 40 s, almost exactly the 2907 the probe got in its first
session - a fixed ten-second burst rather than a continuous stream. To confirm: play audio on
the host during a session.

### Host statistics seen in descriptors

Among the host's string->double keys: `dTargetBW` / `dEstLinkBW` about 90-97,
`dCurBW` about 135-150, `nLayerCount` 2, `sRXpps` 360 (the probe's send rate),
`sPingMS` 0.7, `sTimeConf` 400, `dFrmsEarly` 64, `dFrmsLate` 0. `sRXerr` rose
by almost exactly 1000 per 8 s session while `sRXpass` stayed 100: the host
counts something about the probe's datagrams as errors without treating them
as loss. Unexplained.

### Cold host: the minimum set (probe)

SteamVR on the host exits about 30 s after the last client drops (the host's
value 0x27 is 30, which vrlink logs as "Wireless timeout updated
to: 30"; SteamVR's window shows "Awaiting Wireless Connection (215)"
meanwhile), and the next streaming request starts it again. So a probe gets a
cold host by waiting. **A 45 s gap was not always enough** and produced false
"video" results from a host that was still warm; with 60 s or more every
configuration below repeated identically. All **captured by probe**, 10-20 s
sessions.

**A cold host sends video once it has these six values, and not before:**

| id | value | without it (other five present) |
|---|---|---|
| 0x04 | projection | no video (4 of 4 runs) |
| 0x05 | chaperone JSON | no video |
| 0x0d | HMD static props | no video |
| 0x10 | HMD power props | no video |
| 0x15 | host defaults | no video |
| 0x20 | available refresh rates | no video |

The six alone were sufficient in 2 of 2 runs (first frame 3.0 s after the
first datagram, 90 frames per second). Not needed: 0x01 (client instance id),
0x08 (eye-to-head), 0x22 (version string), controller static and power props
(0x0e, 0x0f, 0x11, 0x12), 0x18 (audio capabilities), 0x13 (focus event), and
the string->double statistics.

Other observations:

- With every startup value published the first frame came at 1.25 s; with
  only the six (or the six plus 0x01, 0x08, 0x22) at 3.0 s, every time.
  **Inferred**: the host waits a couple of seconds for controller
  descriptions before starting without them.
- While values are missing the host keeps sending the prop-refresh request
  (0x2b). The probe answers each one by re-sending everything under a new
  version, so its values never settle as acked in those sessions; that comes
  from the probe, and the host behaves normally.
- The host's rate request (0x21) appears as soon as 0x20 is published, long
  before video.
- This revises the reading of Klepton's "IPD 0, no video": 0x08 is not
  required, but 0x04 is, and vrlink publishes the two together
  behind its IPD test - so an IPD of zero withholds the projection.
- Once video has started the host is warm (see above) for as long as SteamVR
  stays up. Sending the unfocus event (0x13 code 4) did not stop video, and a
  session started 3 s later, publishing nothing, got video in 0.25 s.

### Likely reason for these six (context, not measured)

From the project owner's knowledge of SteamVR drivers, offered as the likely
reason rather than something this project has verified: an OpenVR device's
properties cannot be redefined once the device exists, so the host has to have
the HMD's description - including its projection, which is part of the HMD
device - before it can create it. Controllers have the same constraint, which
would explain the host holding startup for about two seconds to see whether
controller descriptions arrive.

A consequence for client design: SteamVR does not support a dynamic
eye-to-head transform, and wired drivers are recalled to hitch every time it
is updated. Until a probe shows otherwise, a client should publish 0x04 and
0x08 once per session from the display's nominal geometry and not chase IPD
or pupil position frame to frame. To test: change 0x08 mid-session and watch
the host's frame cadence and `encResets`.

### Audio (probe, refined by `vr3`)

- With audio playing on the host, every session received about 300 audio
  messages per second for its whole length, warm or newly started, with or
  without value 0x18 published. **Captured by probe.**
- With nothing playing, a session on a warm host received none.
- The first session after SteamVR starts gets a burst of about 9.7 s of audio
  regardless (2907 messages to the probe, 2913 to the real client in `vr3`).
  In `vr3` that burst is digital silence, so it is not startup sounds.
  **Inferred**: the host opens its audio stream at startup, finds nothing
  playing, and stops it after about ten seconds.

### Client results (2026-11-10): rate follows the offer on a cold host

The Swift viewer on a 120 Hz display offered 120 Hz as its only rate to a cold
host. The host asked for 120.0 Hz and delivered 119-120 complete frames per
second. **Captured by client.** Together with the probe's 90 Hz sessions this
confirms the inference above: the host takes its rate from the client's list
when it creates the HMD device.

It also bears on the `vr3` puzzle (120 Hz agreed, 108.3 delivered to vrlink under Klepton): a client whose own frame loop holds the
agreed rate gets that rate. The 108 was the rate of that client's loop.

## Host log results (2026-11-11): resolution

**Captured** from the host's `vrserver.txt` and `steamvr.vrsettings`
(observing the host; not its binaries). Three sessions the same day:

| client | identity published | frusta published | host log |
|---|---|---|---|
| Mac viewer | Quest 2 | the viewer's | `Render Target: 2048 1844`, `Target square view size 2048`, `Stream views 2048x2048 (... aspect ratio 1.00), atlas 2048x8192, mode 0` |
| Vision Pro | Quest Pro | the displays', widened (lopsided, about 2.75 by 2.21 in tangents) | the same three lines |
| Vision Pro, later | Quest Pro | the same | the same |

The host's settings had `driver_vrlink.streamFormatWidth = 2048` with
`automaticStreamFormatWidth = false` (set by the user in SteamVR's Steam Link
settings). So:

- The tile size of the stream is that setting: every tile, base and foveal,
  is `streamFormatWidth` square. (`vr3`'s 1536 was the same host at an earlier
  setting or on automatic; which was not recorded.)
- The render target the driver reports to SteamVR followed neither the
  headset identity nor the frusta: 2048 by 1844 (0.9 of the width) in all
  three. SteamVR's own supersampling setting is applied on top of it.
- The client is asked for no resolution and has nowhere to give one. A
  headset whose displays are sharper than the setting is simply sent less
  than it could show, until the setting on the host is raised.

The setting does not reach far, though. Reported by the host's owner the same
day (not read from a log here): asked for 4096, SteamVR wrote 3200 into the
config, and the stream was still 2048 square. With four tiles stacked in an
atlas and the encoder's 8192 limit, 2048 is the tallest tile that fits this
layout; **inferred** that this is why.

Not known: what `automaticStreamFormatWidth` chooses, and from what
(bandwidth, GPU, or something the client publishes).
