# Audio negotiation and settings (ValueTransportSystem ids 0x18, 0x19, 0x26)

Source: `SVLAudio::SVLAudio(SVLRoot*)` +0x156c88 and its three
`std::function` watch callbacks (operator() at +0x159504, +0x159610,
+0x15971c). The ValueTransportSystem wire format itself is documented in
docs/svl-values/. The VTE names for these three ids were not found as strings;
the names below are descriptive (**inferred**).

`SVLRoot+0x18c` is the "I am the host" flag: when it is zero (the client build
always takes this branch at runtime — **inferred** from the branch that
creates a stereo jitter buffer and publishes `cAud*` keys only when it is
zero) the constructor does the client half.

| id | direction | size | payload | who writes / reads |
|---|---|---|---|---|
| 0x18 | client → host | 4 | u32 client audio FEC capabilities | written once in the client's `SVLAudio` ctor, value **3**; host watches it |
| 0x19 | host → client | 4 | u32 host audio FEC capabilities | host writes 3 (same code, host branch); client watches it (callback +0x159610) |
| 0x26 | host → client | 47 | jitter-buffer settings (packed struct below) | host writes; client watches it (callback +0x15971c) |

All **static**. The Klepton capture in `STEAMLINK.md` §3.1 shows ids 0x19
(len 4) and 0x26 (len 47) in the same host→client message, which matches.

## Capability word (0x18 / 0x19)

| bit | meaning |
|---|---|
| 0 | peer can receive type-0x0b FEC audio |
| 1 | peer can receive type-0x0c FEC audio (variable length) |

On receipt (**static**, +0x159610):

```python
use_0c  = (caps >> 1) & 1            # SVLAudio+0x1d61
use_fec = (caps | use_0c) & 1        # SVLAudio+0x1d60
```

So a peer advertising 0 gets plain type-6 audio with no parity packets. The
client applies the value only when at least 4 bytes are available.
`use_0c` additionally makes the client flush a (short) mic packet at the end of
every capture callback, see [microphone-uplink.md](microphone-uplink.md).

## Jitter-buffer settings (0x26), 47 bytes, packed, little-endian

Field names are **inferred** from how `SVLAudio::InitJitterBuffer(int rate)`
+0x158e08 and `CAudioJitterBuffer<short>` use each value; offsets, types and
defaults are **static**. Millisecond values are converted to frames with
`ms * sample_rate / 1000`.

| off | type | default | goes to | meaning |
|---|---|---|---|---|
| 0 | u8 | 1 | `SVLAudio+0xc5e` | use the adaptive `Pop` (1) or the plain FIFO `BasicPop` (0) |
| 1 | u8 | 1 | `+0xc5f` | publish `cAudRew` / `cAudFwd` / `cAudFade` / `cAudBufVar` |
| 2 | u8 | 1 | `+0xc60` | on a sequence gap, crossfade the next push into the buffered tail |
| 3 | i32 | 50 | JB+0x00 | start-up fill (ms): playback starts once this much is buffered |
| 7 | i32 | 25 | JB+0x04 | upper bound (ms) for the windowed minimum fill; above it → fast-forward |
| 11 | i32 | 15 | JB+0x0c | lower bound (ms) for the windowed minimum fill; below it → rewind |
| 15 | i32 | 20 | JB+0x08 | target fill (ms) that a resync aims for |
| 19 | i32 | 7 | JB+0x10 | low-water mark (ms): emergency rewind / fade-out threshold |
| 23 | i32 | 500 | JB+0x14 | statistics / decision window (ms of played audio) |
| 27 | i32 | 500 | (`+0xc79`) | unknown — stored but not copied into the jitter buffer |
| 31 | i32 | 2 | JB+0x24 | maximum consecutive emergency rewinds before fading out (a count, not ms) |
| 35 | i32 | 50 | JB+0x18 | fade-in length (ms) |
| 39 | i32 | 10 | JB+0x20 | fast-forward crossfade length (ms) |
| 43 | i32 | 5 | JB+0x1c | rewind crossfade length (ms) |

The same defaults are compiled into both sides, so a client that never
receives 0x26 behaves as in the "default" column (the constructor's own
compiled-in low-water value is 280 frames ≈ 5.8 ms at 48 kHz until
`InitJitterBuffer` recomputes it as 7 ms).

When 0x26 arrives and the output stream is already running, the client
recomputes the frame thresholds, resets the read cursor to the write cursor,
goes back to the "waiting for start-up fill" state and logs
`CAudioJitterBuffer init: %d,%d,...` (**static**, +0x15971c).

## Related

`[SVLClientXR] VTE_CLIENT_AUDIO_STATE %d(%d) %d/%d(%d) - %d(%d) %d/%d(%d)` is a
different VTE (system volume / mute state, see `AndroidAudioManagerService` and
`SVLAudio::SyncAudioControls` +0xf4ae8); it is id 0x23, laid out in
docs/svl-values/vte-id-table.md.

## Confirmed against a wire capture

Capture: `vr3` (real client under Klepton, 40.26 s of streaming, 80,011 SVL
datagrams, none torn, each with a CLOCK_MONOTONIC receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. The earlier
capture `vr1` had a third of its datagrams torn and no timestamps, so its
counts were lower bounds; every figure here is a complete count.
The values below were reassembled from the value-transport bytes on the wire
with `ovrlink.vts` (docs/svl-values/). `vr3`'s `KL_SVL_TRACE` output (238
`[svl] key = value` lines, logged only when a key changes and at most about
once a second per key) holds string->double keys such as `cAud*`, not VTE
values; its `cAudUnd` lines agree with the wire values in
[jitter-buffer.md](jitter-buffer.md) (95,040 then 95,041 around the audio
burst, about +48,000 per second afterwards).

- **captured**: host -> client VTE 0x19 = `03 00 00 00` and VTE 0x26 (47
  bytes) arrive together in a class 3 type 0x0d message at t = 0.004 s (the
  first host datagram of the capture), as version 1, and again at
  t = 0.023 s as version 2 with identical contents.
- **captured**: VTE 0x26 is
  `01 01 01 | 32000000 19000000 0f000000 14000000 07000000 f4010000 f4010000
  02000000 32000000 0a000000 05000000` both times - exactly the compiled-in
  defaults in the table above (50, 25, 15, 20, 7, 500, 500, 2, 50, 10, 5).
- **captured**: client -> host VTE 0x18 = `03 00 00 00`, completed at
  t = 0.030 s (version 1) and t = 0.071 s (version 2), riding in pose packets.
- **captured**: the client never sent ids 0x19 or 0x26, and the host never
  sent 0x18. None of the three ids changes again in the remaining 40 s; in
  particular nothing is republished at the start or end of the audio burst
  (t = 1.855 to 11.556 s).
- **captured** (client log): `CAudioJitterBuffer init:
  48000,1,1,2400,1200,720,960,336,24000,2,2400,480,240` is printed three
  times: once when the output stream is created, before the first SVL
  datagram, and once after each of the two 0x26 arrivals (between the
  datagrams at t = 0.0039 and 0.0044 s, and at 0.0231 and 0.0241 s). That
  confirms both the field mapping (rate, settings byte 0, settings byte 2,
  then start-fill 2400, min-hi 1200, min-lo 720, target 960, low-water 336,
  window 24000, max rewinds 2, fade-in 2400, fwd crossfade 480, rew crossfade
  240 = `ms x 48000 / 1000`) and the static claim that every arrival of 0x26
  re-initializes the jitter buffer, even when the bytes are unchanged.
- **captured**: the first audio message comes 1.85 s after the host has VTE
  0x18, so `vr3` cannot say whether the host waits for it. The probe can:
  docs/svl-values/startup-exchange.md ("Audio, settled (probe)") records
  audio arriving with or without 0x18 published.

## Open questions / to confirm on the wire

- What the host sends when 0x18 is 0 or 1 instead of 3 (type 0x06 / 0x0b are
  predicted; the probe has only shown that audio still arrives).
- Whether a host ever sends a 0x26 that differs from the compiled-in
  defaults (two captures, both defaults).
- Meaning of the unused i32 at offset 27.
- `VTE_CLIENT_AUDIO_STATE` is id 0x23 and is documented in
  docs/svl-values/vte-id-table.md; whether the host ever writes it back to the
  client is open there.
