# Client per-frame event schedule

Sources: `XrSceneStream::OnTopOfFrame(XRQContext&)` +0x11906c,
`QSVLClient::OnTopOfFrame(int, int)` +0xf6270, `QSVLClient::VSyncEvent(int)`
+0xf6630, `QSVLClient::HandleEvent(VRLinkPostedEvent_t const&)` +0xf4bec,
`SVLRoot::HandleEvent` +0x165dbc, `SVLRoot::PostMultipleEvents` +0x165fbc,
`QSVLClient::SendPoses` +0xf4d34. All details below are **static** unless
marked otherwise.

## `VRLinkPostedEvent_t` (internal, 16 bytes — never on the wire)

| off | type | field |
|---|---|---|
| 0 | u8 | event type |
| 4 | i32 | due time (SVL timestamp, µs) |
| 8 | i64 | argument |

`PostMultipleEvents` inserts into a list sorted by due time and wakes
`SVLRoot::EventsThread` (+0x1646fc), which calls the virtual `HandleEvent` when
each comes due.

| type | posted by | handler does |
|---|---|---|
| 0 | `OnTopOfFrame` / `VSyncEvent`, four per frame | `SVLRoot::SendValues(3)` then `SendPoses(sub = arg & 0xf, frame = arg >> 4)` |
| 1 | itself, every 1000 µs | tick every data link and the audio object; run the 3 s connection-lost test |
| 2 | `OnTopOfFrame` / `VSyncEvent`, 500 µs after the frame anchor | `QSVLClient::UpdateFrameVariables()` (publishes changed VTE values — see docs/svl-values/); posts a type 3; `SVLAudio::UpdateStats()` |
| 3 | type 2 | `FileTimeCheckTickInternal()`; once per second posts a type 4 |
| 4 | type 3, 1 Hz | publish `dbgPhaFault`; mark the three power-prop VTEs (0x10, 0x11, 0x12) dirty; mark the available-frametimes VTE (0x20) dirty until the host has sent a refresh-rate request |

## Top of frame

`XrSceneStream::OnTopOfFrame` runs right after the OpenXR frame wait and calls

```
QSVLClient::OnTopOfFrame( (predictedDisplayTime - xrNow) / 1000,     # µs until display
                          predictedDisplayPeriod / 1000 )             # µs per frame
```

```python
def on_top_of_frame(until_display_us, period_us):
    ft = period_us if 2000 <= period_us <= 20000 else 11111          # 90 Hz fallback
    if not (2000 <= until_display_us <= 80000): ft = 30000
    self.frametime = ft                                              # SVLRoot+0x178
    now = timestamp()
    self.top_of_frame = now                                          # +0xcb4
    self.display_time = now + until_display_us                       # +0xcbc
    report(CR_WaitGetPoses_Up /*0x50*/, self.frame_index)

    if self.host_version < 6:                                        # +0xba8, see phase-loop.md
        standoff = (until_display_us + 10*ft + self.phase_off) % ft
        delta = standoff - self.prev_standoff
        if delta >  ft // 2: schedule(anchor = now)                  # phase wrapped backward: extra batch
        if delta >= -(ft // 2): schedule(anchor = now + standoff)    # normal batch (skipped on forward wrap)
        set_value("cStandoff", standoff)
        self.prev_standoff = standoff
    else:
        schedule(anchor = now)
    report(CR_Render_VSYNC_Done /*0x51*/, self.frame_index)

def schedule(anchor):
    self.frame_index += 1                                            # +0xdf8 ("lnFrameID")
    self.anchor_time = anchor                                        # +0x3e20
    q = ft // 4
    post(type 0, anchor        , arg = frame_index*16 | 0)
    post(type 0, anchor +   q  , arg = frame_index*16 | 1)
    post(type 0, anchor + 2*q  , arg = frame_index*16 | 2)
    post(type 0, anchor + 3*q  , arg = frame_index*16 | 3)
    post(type 2, anchor + 500  , arg = 0)
```

`QSVLClient::VSyncEvent(t)` is the same `schedule(anchor = t)` without
incrementing the frame index; no static caller was found (**inferred**: an
alternative entry for platforms with a real vsync callback).

So the client sends **four pose packets per display frame**, spaced a quarter
frame apart and tagged with sub-index 0..3 and the frame index (**captured** in
`vr3` below, where the step is a quarter of the *reported* display period
rather than the actual duration of the frame loop). With a host older than
version 6, the batch is delayed by `cStandoff` after the frame wait returns;
`cStandoff` is `cPhaseOff` re-expressed relative to "now" given the remaining
time until display.

## Pose packet timing header

Only the timing-relevant front of the packet is listed here; the pose and
controller body is in docs/svl-tracking-input/. Offsets are from the start of
the `dataset`.

| off | type | value | meaning |
|---|---|---|---|
| 0 | u16 | `0x0103` | `dataset` type 3 (unreliable stream), flags 0x01 |
| 2 | u16 | 0 | |
| 4 | u16 | `0x168 + n` | payload length; `n` = bytes of ValueTransportSystem data appended at payload offset 0x168 (`TickUpdate` is given a 0x174-byte budget) |
| 6 | u16 | 0 | |
| 8 | u8 | 10 | constant (**inferred**: pose-packet layout version) |
| 9 | u8 | 0..3 | sub-index within the frame |
| 0x0a | u8 | 0x20 | constant (meaning unknown) |
| 0x0b | u8 | 0/1 | "holdoff" request (`[SVLClient] Client requested holdoff`), an atomic flag at `SVLRoot+0xf0` |
| 0x0c | i32 | | client clock-offset estimate (see [clock-sync.md](clock-sync.md)) |
| 0x10 | i32 | | client timestamp immediately before submit |
| 0x14 | i32 | | client timestamp when the packet build began (pose sample time) |
| 0x18 | i32 | | target time: `display_time` (`+0xcbc`) for host version ≥ 6, else the batch anchor time (`+0x3e20`). Both read at send time, so a sub-packet that is sent late can carry the next frame's value (**captured**, below) |
| 0x1c | i32 | | frame index (`lnFrameID`) |
| 0x20 | u16 | | reset counter `QSVLClient+0xe04` (logged as `rst=`) |

Immediately **before** each pose packet, in the same datagram, the client
sends the type-4 frame report ([frame-reports.md](frame-reports.md)): 32 bytes
counting its 8-byte element header, 24 bytes of value. After it, the client reports
timing event `CN Send WaitGetPoses0` (0x40, sub-index 0) or
`CN Send WaitGetPosesN` (0x41), with the frame index as argument.

On sub-index 0, `SendPoses` logs:
`[SVLC] SendPoses: lnFrameID=%d(%d) (mod64=%d) (mod256=%d) rst=%d toff=%d`.

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` under Klepton with per-datagram
timestamps. Although the display advertised 120 Hz (`frametime` 8,333 µs),
`vrlink`'s frame loop ran at 108.3 Hz. Out of 17,446 sends (and 17,446
sequence numbers) transmitted by `vrlink`, 17,423 pose elements were parsed,
leaving 23 pose datagrams missing from the parsed capture. Video began 0.926 s
after the first pose packet. Offsets below are dataset offsets matching the
table above.

### Layout

- **captured**: All 17,423 pose elements have header bytes `03 01`, both
  other header u16s set to 0, byte 8 = 10, byte 0x0a = 0x20, byte 0x0b = 0
  (holdoff never requested), and byte 9 in 0..3. The reset counter at 0x20
  stayed 0.
- **captured**: Payload length is 360 (= 0x168) in 17,015 packets; the other
  408 are 396–731 bytes, i.e. 0x168 plus appended ValueTransportSystem bytes
  (the largest, 731, carries 371 bytes of VTS data within the 0x174 = 372-byte
  budget).
- **captured**: All byte offsets in the table above match the wire capture:
  0x0c offset estimate, 0x10 / 0x14 send / build timestamps (send − build is
  3–15 µs, median 5 µs), 0x18 target time, and 0x1c frame index.
- **captured**: The pose element is the last element of its datagram, preceded
  by `03 11` (17 bytes), `03 07` (96 bytes = three `TransportValue_t`,
  `SendValues(3)`), and `04 0f` (the frame report: 24 bytes of value, or 32
  bytes including its 8-byte header). Out of 17,423 datagrams, 17,020 contain
  all four elements, 401 omit `03 11`, and 2 carry report + pose only —
  accounting for the first 403 datagrams up to 4 ms after the first frame
  descriptor. The 1233 / 401 / 3 counts in `vr1` reflected the same pattern
  with torn datagrams omitted.

### Frame counter and sub-indices

- **captured**: The frame index runs from 0 to 4,361, incrementing by 1 per
  group in all 4,361 steps and staying constant across the sub-indices of a
  group. (`vr1` saw "0, 0, 1, 1, 2, 2 …" because torn datagrams dropped part of
  each group.)
- **captured**: Out of 4,362 groups, 4,339 contain the full `0, 1, 2, 3`
  sequence. Frame 0 consists of two packets, both sub-index 0 with target time
  0 (sent before the first `OnTopOfFrame`). The remaining 22 groups lack one or
  two sub-indices (23 packets total), and each aligns with one of the 23
  single-datagram gaps in outbound sequence numbers — confirming they are
  unparsed capture datagrams rather than skipped sends.
- **captured**: Pose groups were sent at 108.3 groups/s while streaming (mean
  group period 9,231 µs by build timestamp; 5th–95th percentile 8.1–10.1 ms,
  with one 20 ms gap) and 108.8 groups/s before video started. That matches
  Klepton's actual frame-loop rate rather than 90 Hz or the advertised 120 Hz.

### Schedule within a frame

Times below are the build timestamp (0x14) of each sub-index minus that of
sub-index 0 of the same frame, in microseconds. Capture timestamps give the
same figures to within tracer jitter.

| | static prediction (`frametime` 8,333) | before video, 101 frames: median (5th–95th) | streaming, 4,212 frames: median (5th–95th) |
|---|---|---|---|
| sub 1 | 2,083 | 2,110 (1,978–2,286) | 2,181 (2,039–2,436) |
| sub 2 | 4,166 | 4,174 (3,980–4,365) | 4,265 (4,027–4,474) |
| sub 3 | 6,249 | 6,249 (6,016–6,674) | 6,382 (6,051–6,554) |
| next frame's sub 0, after sub 3 | 2,084 if the loop kept 120 Hz | 2,996 (1,351–3,971) | 2,832 (1,752–3,832) |

- **captured**: Quarter-frame spacing is confirmed at one quarter of the
  8,333 µs display period reported by the runtime rather than the ~9,231 µs the
  frame loop took, with the fourth gap absorbing the difference. Jitter of a
  sub-index relative to sub 0 is ±0.2 ms (5th–95th percentile), with a
  worst-case delay of 5 ms.
- **captured**: Before video starts (while `host_version` is still 0, selecting
  the `< 6` path), the target-time field holds the batch anchor. Sub-index 0 is
  built a median 206 µs after the anchor (event-thread wake-up latency), and
  the target field updates about 3.5 ms *before* the frame index increments, so
  sub 2 and sub 3 usually carry the next batch's anchor (only 23 of 101 groups
  have a single target value). This comes from the `cStandoff` delay, where top
  of frame sets the anchor to `now + cStandoff` (`cStandoff` = 3,490–3,500 µs
  on the wire).
- **captured**: Once video is streaming (host version 14, selecting the `≥ 6`
  path), target minus sub-0 build time has a median of 8,314 µs (5th–95th
  percentile 8,065–8,324 µs, max 8,330 µs): predicted display time is top of
  frame plus one 8,333 µs period, and sub 0 is built within 0.3 ms of top of
  frame with no stand-off delay. The target advances by the actual loop period
  from frame to frame (median 9,169 µs). All sub-packets of a frame carry the
  same target time in 4,208 of 4,212 groups; in the remaining 4 groups, a
  delayed sub-packet went out after the next top of frame (for example, in
  frame 2,723, sub 3 was built 5.3 ms after sub 2 and carried frame index 2,723
  with the next frame's target).

### Timing relative to downlink video

- **captured**: The host sent 4,260 frames in 39.33 s — 108.4 fps by its own
  `tx_time`, matching the client's frame-loop rate rather than the negotiated
  120 Hz ([refresh-rate.md](refresh-rate.md)). One video frame begins arriving
  during each client frame in 3,927 of 4,199 frame periods (none in 135, two in
  137).
- **captured**: A frame's first descriptor arrives a median 3.4 ms after the
  most recent sub-index 0 send (5th–95th percentile 0.7–8.6 ms); the host's
  `tx_time`, mapped to the client clock, is a median 3.1 ms after it (IQR
  2.5–3.8 ms over the last 15 s). Because that interval is shorter than the
  host's encode time (`dbgEncTimeMS` ≈ 4.6 ms), each arriving video frame was
  started from an earlier pose group at least one client frame back.
- **captured**: The host's `tsLastWGP` key matches its receive time for a
  sub-index 0 packet in 166 of 167 samples (see [clock-sync.md](clock-sync.md)).
  Combined with the host timing event names `SN Got WaitGetPoses0` and
  `SN Got WaitGetPosesN`, this indicates that the host treats sub-index 0 as
  the frame's `WaitGetPoses` trigger and sub-indices 1..3 as supplemental pose
  samples (**inferred**).
- A live probe (docs/svl-values/startup-exchange.md, "Refresh rate and
  pacing (probe)") found that the host's frame rate changes when the
  target-time field varies within a frame; see docs/svl-tracking-input/poses.md
  for full details on that field.

## Open questions

- Test whether the host requires all four sub-packets per frame or operates
  with sub-index 0 alone.
- Determine how the host handles target-time changes within a single frame
  index: `vrlink` changed target time mid-group in 4 of 4,212 streaming groups
  and in most pre-video groups with no visible effect in `vr3`.
- Identify the meaning of the constant bytes 10 and 0x20 at offsets 8 and 0x0a.
- Determine what setting the "holdoff" flag at offset 0x0b causes the host to
  do (never set in `vr3`).
- Check whether `mod64` and `mod256` in the `SendPoses` log correspond to
  narrower frame-id fields elsewhere in the protocol (the frame-report path
  masks decoder frame ids with 0x7f; see [frame-reports.md](frame-reports.md)).
- Capture the sub-packet schedule on a display whose frame loop runs at the
  full advertised refresh rate (`vr3`'s loop ran ~10% slow, widening the fourth
  sub-packet gap rather than running at an even 4 × quarter-frame cadence).
