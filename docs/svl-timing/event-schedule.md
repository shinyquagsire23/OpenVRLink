# The client's per-frame event schedule

Sources: `XrSceneStream::OnTopOfFrame(XRQContext&)` +0x11906c,
`QSVLClient::OnTopOfFrame(int, int)` +0xf6270, `QSVLClient::VSyncEvent(int)`
+0xf6630, `QSVLClient::HandleEvent(VRLinkPostedEvent_t const&)` +0xf4bec,
`SVLRoot::HandleEvent` +0x165dbc, `SVLRoot::PostMultipleEvents` +0x165fbc,
`QSVLClient::SendPoses` +0xf4d34. All **static** unless marked.

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
        if delta >  ft // 2: schedule(anchor = now)                  # phase wrapped backwards: extra batch
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

So the client sends **four pose packets per display frame**, a quarter frame
apart, tagged with a sub-index 0..3 and the frame index (**captured** in
`vr3`, below: the quarter is a quarter of the *reported* display period, not
of the time the frame loop actually takes). With an old host
(version < 6) the batch is delayed by `cStandoff` after the frame wait returns;
`cStandoff` is simply `cPhaseOff` re-expressed relative to "now" given how far
away the display time is.

## The pose packet's timing header

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

Log format, sub-index 0:
`[SVLC] SendPoses: lnFrameID=%d(%d) (mod64=%d) (mod256=%d) rst=%d toff=%d`.

## Confirmed against capture `vr3`

`vr3`: real client under Klepton, 40.26 s, every datagram timestamped. The
display advertised 120 Hz (`frametime` 8,333 µs); the client's frame loop
actually ran at 108.3 Hz. 17,423 pose elements parsed; the client made 17,446
sends and used 17,446 sequence numbers, so 23 pose datagrams are missing from
the parsed capture (they were sent). Video began 0.926 s after the first pose
packet. Offsets here are dataset offsets as in the table above.

### Layout

- **captured**: all 17,423 pose elements have header bytes `03 01`, both
  other header u16s 0, byte 8 = 10, byte 0x0a = 0x20, byte 0x0b = 0 (holdoff
  never requested), byte 9 in 0..3. The reset counter at 0x20 stayed 0.
- **captured**: payload length is 360 (= 0x168) in 17,015 packets; the other
  408 are 396–731, i.e. 0x168 plus appended ValueTransportSystem bytes (the
  largest, 731, is 371 bytes of VTS data against the 0x174 = 372 budget).
- **captured**: the page's byte offsets were right throughout: 0x0c offset
  estimate, 0x10 / 0x14 send / build timestamps (send − build 3–15 µs,
  median 5), 0x18 target time, 0x1c frame index.
- **captured**: the pose element is the last element of its datagram and the
  order is `03 11` (17 bytes), `03 07` (96 bytes = three `TransportValue_t`,
  `SendValues(3)`), `04 0f` (the frame report, 24 bytes of value — 32 with
  its header, which is the "32-byte type-4 packet" this page predicted),
  `03 01` (pose). 17,020 datagrams have all four; 401 lack the `03 11` and
  2 are report + pose only — together the first 403 datagrams, up to 4 ms
  after the first frame descriptor. vr1's 1233 / 401 / 3 were the same pattern, undercounted.

### Frame counter and sub-indices

- **captured**: the frame index runs 0…4,361 and increases by exactly one per
  group, 4,361 times out of 4,361. It is constant across the sub-indices of a
  group. (vr1 listed it as "0, 0, 1, 1, 2, 2 …": it held only some of each
  group's packets.)
- **captured**: 4,339 groups are the full `0, 1, 2, 3`. Frame 0 is two
  packets, both sub-index 0, with target time 0 (sent before the first top of
  frame). The other 22 groups lack one or two sub-indices, 23 packets in all,
  and each sits at one of the 23 one-datagram gaps in the outbound sequence
  numbers — they are the unparsed datagrams, not skipped sends.
- **captured**: frame groups per second: 108.3 while streaming (mean group
  period 9,231 µs by the build timestamp; 5th–95th percentile 8.1–10.1 ms,
  one 20 ms gap), 108.8 before video. This is the Klepton frame loop's real
  rate; nothing in the capture is at 90 Hz or at the advertised 120 Hz.

### Schedule within a frame

Times are the build timestamp (0x14) of each sub-index minus that of
sub-index 0 of the same frame, µs. Capture timestamps give the same figures
to within the tracer's jitter.

| | static prediction (`frametime` 8,333) | before video, 101 frames: median (5th–95th) | streaming, 4,212 frames: median (5th–95th) |
|---|---|---|---|
| sub 1 | 2,083 | 2,110 (1,978–2,286) | 2,181 (2,039–2,436) |
| sub 2 | 4,166 | 4,174 (3,980–4,365) | 4,265 (4,027–4,474) |
| sub 3 | 6,249 | 6,249 (6,016–6,674) | 6,382 (6,051–6,554) |
| next frame's sub 0, after sub 3 | 2,084 if the loop kept 120 Hz | 2,996 (1,351–3,971) | 2,832 (1,752–3,832) |

- **captured**: so the quarter-frame spacing is confirmed, and it is a quarter
  of the 8,333 µs display period the runtime reports, not of the ~9,231 µs the
  loop takes: the fourth gap absorbs the difference. Jitter of one sub-index
  against sub 0 is ±0.2 ms (5th–95th); the worst case in the run was a
  sub-packet 5 ms late.
- **captured**, before video (the host-version field is still 0, so the
  `< 6` path runs): the target-time field is the batch anchor. Sub-index 0 is
  built a median 206 µs after it (the event thread's wake-up latency), and
  the field changes about 3.5 ms *before* the frame index does, so sub 2 and
  sub 3 of a frame usually already carry the next batch's anchor (only 23 of
  101 groups have one target value). This comes from the `cStandoff`
  delay: the anchor is set at top of frame to `now + cStandoff`
  (`cStandoff` 3,490–3,500 on the wire).
- **captured**, streaming (host version 14, the `≥ 6` path): target −
  sub 0 build time is 8,314 µs at the median, 8,065–8,324 (5th–95th), never
  above 8,330: the predicted display time is top of frame plus one 8,333 µs
  period and sub 0 is built within 0.3 ms of top of frame — no stand-off.
  The target advances by the real loop period from frame to frame (median
  9,169 µs). It is the same in all sub-packets of a frame in 4,208 of 4,212
  groups; in the other 4 a sub-packet went out after the next top of frame
  (for example frame 2,723: sub 3 was built 5.3 ms after sub 2 and carries
  the frame index 2,723 with the next frame's target).

### Relation to the video coming back

- **captured**: the host sent 4,260 frames in 39.33 s — 108.4 per second by
  its own `tx_time`, the client's frame-loop rate and not the negotiated
  120 Hz ([refresh-rate.md](refresh-rate.md)). One video frame begins to
  arrive in each client frame in 3,927 of 4,199 frame periods (none in 135,
  two in 137).
- **captured**: a frame's first descriptor arrives a median 3.4 ms after the
  most recent sub-index 0 send (5th–95th percentile 0.7–8.6 ms); the host's
  `tx_time`, mapped to the client clock, is a median 3.1 ms after it (IQR
  2.5–3.8 ms; last 15 s). That is less than the host's own encode time
  (`dbgEncTimeMS` about 4.6), so the frame that arrives was started from an
  earlier group, at least one client frame back.
- **captured**: the host's `tsLastWGP` key is its receive time for a
  sub-index 0 packet (166 of 167 samples; see [clock-sync.md](clock-sync.md)).
  With its event names `SN Got WaitGetPoses0` / `…N` this says the host
  treats sub-index 0 as the frame's "WaitGetPoses" and the other three as
  extra samples (**inferred** for what it does with them).
- A live probe (docs/svl-values/startup-exchange.md, "Refresh rate and
  pacing (probe)") found the host's frame rate changes when the target-time
  field is not constant within a frame; docs/svl-tracking-input/poses.md has
  the field's full characterization.

## Open questions

- Whether the host needs all four sub-packets or only sub-index 0.
- What the host does when the target time changes inside a frame index: the
  real client does it in 4 of 4,212 streaming groups and in most groups
  before video, with no visible effect in `vr3`.
- Meaning of the constant bytes 10 and 0x20 at offsets 8 and 0x0a.
- What "holdoff" makes the host do (never set in `vr3`).
- Whether the "mod64 / mod256" in the log reflects narrower frame-id fields
  elsewhere in the protocol (the frame-report path masks decoder frame ids
  with 0x7f — see [frame-reports.md](frame-reports.md)).
- The schedule on a display whose frame loop really runs at the advertised
  rate: `vr3`'s loop was 10% slow, so "fourth gap absorbs the difference" was
  seen but a true 4 × quarter cadence was not.
