# Audio packet format

Sources: `SVLAudio::TransmitAudioPacket(dataset*, unsigned short)` +0x1575a8,
`SVLAudio::TransportRXAudioFrames(dataset*)` +0x1571b8,
`SVLDataLink::ReceivedData(dataset*)` +0x15a9b8.

## Audio `dataset` header

Every message handed to or received from the data link is a `dataset`: an 8-byte
header followed by the payload. Audio populates the header as follows
(**static**, both functions above; little-endian):

| off | size | field (transport's name) | audio meaning |
|---|---|---|---|
| 0 | u8 | type (class) | `0x06` plain audio, `0x0b` FEC audio (equal-length variant), `0x0c` FEC audio (variable-length variant) |
| 1 | u8 | flags (type) | type 0x06: `0x08` when the sender is the client, `0x00` when the sender is the host. Types 0x0b/0x0c: always `0x10` |
| 2 | u16 | seq (id) | audio packet sequence number (`SVLAudio+0xc38`), incremented once per transmitted audio packet, parity packets included |
| 4 | u16 | len (len) | payload bytes that follow the header |
| 6 | u16 | aux (index) | normally the format word (below); on a type-0x0c parity packet, the length of the *shorter* of the two packets it protects |
| 8 | len | payload | PCM, or XOR parity |

As 16-bit words the first field reads `0x0806` / `0x0006` / `0x100b` /
`0x100c`.

This 8-byte header is the transport's element header (docs/svl-transport/):
`u8 class | u8 type | u16 id | u16 len | u16 index`. The names in this folder
come from the audio code and differ from the transport's, given in brackets in
the table: what this folder calls **type** is the transport's *class*, and
this folder's **flags** is the transport's *type*. A tool that prints
"class 0x0c type 0x10" is showing the `0x100c` packet described here
(**captured**, `vr3`: all 2,913 audio elements).

`SVLDataLink::ReceivedData` routes `type` 6, 0x0b and 0x0c to
`SVLAudio::TransportRXAudioFrames` (**static**). On receive, types 0x0b/0x0c
are only processed when `flags == 0x10` (`(word0 & 0xff00) == 0x1000`); the
flags byte of type 6 is not checked.

## Format word (`aux`)

```
aux = (channels - 1) | ((sample_rate / 10) << 2)      # sender
sample_rate = (aux >> 2) * 10                          # receiver
channels    = (aux & 3) + 1
```

**static**: the sender builds it from `SVLAudio+0x08` (channels) and
`SVLAudio+0x0c` (rate, integer-divided by 10); the receiver decodes it into
`SVLAudio+0xc3c` (channels) and `+0xc40` (rate). Maximum encodable rate is
163830 Hz; 48000 Hz stereo is `0x4b01`, 48000 Hz mono is `0x4b00`.

The receiver decodes the format word from every audio packet **except** a
type-0x0c packet whose `seq % 3 == 2` (which carries a payload length instead).
Note that a type-0x0b parity packet still carries a normal format word.

When the decoded rate differs from the rate the output stream is running at
(`SVLAudio+0xc4c`), the client logs
`[Audio] frame rate change, reinitializing: %d %d to %d %d` (old rate, old
channels, new rate, new channels) and reopens its audio streams at the new
rate (vtable +0x10 = `QSVLClientAudioNdk::Init(true, rate)` +0xf4184).

## Payload

Payloads carry uncompressed, interleaved signed 16-bit little-endian PCM
(**static**: payload pointer `dataset+8` is passed as `short*` to
`AcceptAudioFramesFromPeer`, which pushes it into
`CAudioJitterBuffer<short>`).

Frame count on receive is `len / (2 * out_channels)` where `out_channels` is
the client's *output* channel count (`SVLAudio+0xc50`), which
`QSVLClientAudioNdk::Init` hard-sets to 2. A packet whose format word says
anything other than 2 channels only produces the log
`[Audio] Attempt to set audio rx channels to %d.`; the data is still
interpreted as stereo. A compatible host therefore always sends stereo.

The largest payload either side can protect with FEC is **1024 bytes** (the
XOR runs over a fixed 0x400 bytes, and the TX aggregate buffer is 0x400 bytes):
256 stereo frames (5.33 ms at 48 kHz) or 512 mono frames (10.67 ms).
**inferred**: the host uses the same 1024-byte ceiling for downlink packets,
because the client's receive-side parity buffer is exactly 0x400 bytes and a
longer packet would not be recoverable.

## Send pacing

`TransmitAudioPacket` enforces a minimum gap of **250 µs** between consecutive
audio packets (`SVLAudio+0xc44 = 0xfa`, spin-wait via `SVLSpinwait`), then
calls the data link's send (vtable +0x58 with both bool arguments 0)
(**static**).

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` streaming under Klepton (80,011
intact SVL datagrams, each with a `CLOCK_MONOTONIC` receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. Unlike the
earlier `vr1` capture, which had a third of its datagrams torn and no
timestamps (giving only lower-bound counts), every count here is complete.

- **captured**: The 8-byte header in the table above matches the transport's
  element header byte for byte. All 2,913 audio elements travel host to client
  with byte 0 `0x0c` and byte 1 `0x10`. Transport tools (`svldump.py` and the
  capture census) print this as "class 0x0c, type 0x10", corresponding to
  "type 0x0c, flags 0x10" in the audio code; likewise, the transport's `id` and
  `index` fields correspond to `seq` and `aux`.
- **captured**: No element with byte 0 = 0x06 or 0x0b exists in `vr3` in
  either direction.
- **captured**: `seq` runs contiguously from 0 to 2912 (+1 on all 2,912 steps),
  with no loss, duplicates, or reordering.
- **captured**: On data packets (`seq % 3` = 0 or 1), the format word is
  `19201 = 0x4b01` in all 1,942 packets (48000 Hz stereo). On the 971 parity
  packets, `aux` carries a payload length (896 ×851, 1024 ×60, 768 ×60).
- **captured**: Payload lengths are 1024 bytes (2,002 packets), 896 bytes (851
  packets), or 768 bytes (60 packets) — 256, 224, or 192 stereo frames — and
  never exceed 1024 bytes. Position 0 (A) is always 1024 bytes; position 1 (B)
  is 896 (851 times), 1024 (60 times), or 768 (60 times); position 2 (parity)
  is always 1024 bytes.
- **captured**: A group (A + B) carries 480 frames (10 ms) in 851 of 971
  groups. The other 120 groups come as 60 adjacent pairs, always 512 frames
  (1024 + 1024) followed by 448 frames (1024 + 768), so every pair totals 960
  frames. Across the burst, 466,080 frames arrive (971 × 480 = 9.710 s of
  audio).
- **captured**: A least-squares fit of cumulative frames against the arrival
  time of each group's A packet gives 47,998.4 frames/s over the whole burst
  (47,997.7 frames/s excluding the first 20 groups) — matching the announced
  48 kHz rate to within 35 ppm of the capture machine's clock. The 2,913
  messages arrive over 9.701 s (300.3 messages/s, or 100.1 groups/s).
- **captured**: Of the 2,913 audio elements, 2,909 occupy a datagram alone. The
  remaining 4 share a datagram with the host's class 3 type 0x18 message (sent
  every 2 s, seen in either element order). Audio never shares a datagram with
  a video packet or frame descriptor.
- **captured** (client log in the same run): `vrlink` logged
  `[aaudio] openStream: 48000 Hz, 2 ch, int16, burst 240 frames` and
  `[Audio] AAudioStream_getFramesPerBurst = 240`.
- **captured, negative**: PCM sample format was not exercised by `vr3` alone
  because all 1,942 data payloads are all-zero bytes (peak 0, RMS 0 in every
  second of the burst, producing 9.71 s of digital silence), just as in `vr1`.
  See "Client playback test" below for live audio verification.
- **captured, negative**: No client-to-host audio element exists in `vr3`
  (see [microphone-uplink.md](microphone-uplink.md)), leaving `vrlink`'s own
  uplink header and format word unconfirmed on the wire.

### Downlink timing (`vr3`)

- **captured**: Audio arrives in a single burst: the first message is at
  t = 1.855 s and the last is at t = 11.556 s (9.701 s total), followed by no
  audio packets for the remaining 28.7 s of the session while video continues
  (the first video packet arrives at t = 0.926 s). The burst begins at `seq` 0
  on an A packet and ends on a parity packet, aligned to whole groups, with a
  maximum inter-arrival time of 18.1 ms inside the burst.
- **captured**: No in-band message delimits the burst: no other host message
  sits within 20 ms of its start or end except video frame descriptors, the
  payload is all zeros from start to finish (with no ramp), and no
  value-transport update completes in either direction after t = 1.05 s.
- Live probes (docs/svl-values/startup-exchange.md, "Audio, settled (probe)")
  established that the host sends audio only while something is playing on the
  host, so the absence of audio after t = 11.6 s is normal idle behavior rather
  than packet loss. In `vr3`, the ~10 s burst at session start carries 9.71 s
  of digital silence. **inferred**: The host gates transmission on its audio
  capture stream being active rather than on non-zero sample values; a capture
  with audible playback would show whether zero payloads ever appear mid-stream.
- **captured**: Within a group, B follows A after a median 0.20 ms (p95
  0.27 ms), consistent with the host sharing the same 250 µs minimum send gap
  described in "Send pacing" (**inferred**). From one A packet to the next, the
  median interval is 10.09 ms and the mean is 9.994 ms. Occasionally two groups
  arrive back to back (A-to-A under 2.5 ms, 59 times) after a double-length gap
  (16 to 21 ms, 60 times).
- **captured**: Parity packets do not follow B immediately: the B-to-parity
  interval is spread evenly over 0 to 10 ms (median 4.43 ms). Out of 971 parity
  packets, 907 arrive within 0.3 ms of the first frame descriptor (class 5
  type 2, index 0) of a video frame, and in 884 cases the parity datagram sits
  immediately before that descriptor's datagram in transport sequence, with B
  immediately before the parity. A and B show no such alignment (41 and 44 of
  971 within 0.3 ms). **inferred**: The host queues the parity packet and
  flushes it on its video frame tick (video frames were 9.10 ms apart during
  the burst), so parity recovery can lag a lost packet by up to one video frame.
- **captured**: At the start of the burst, the first few groups arrive slightly
  faster than real time (group starts at 0, 9.3, 18.4, 26.7, and 35.9 ms,
  delivering 3,136 frames = 65 ms of audio in the first 54 ms) before settling
  to 10 ms intervals, with no large initial flush.

## Open questions

- Capture a known non-silent test signal on the host (for example, a tone in
  one channel) to verify s16le encoding and L/R channel interleave directly on
  the wire.
- Determine why the host sends 9.71 s of digital silence at session start and
  then stops, and probe whether advertising capability 0 or 1 in VTE 0x18
  causes the host to send type 0x06 or 0x0b.
- Check whether the host ever sends `len` > 1024 (never seen in 2,913 messages).
- Verify the host's `flags` byte on type 6 packets (predicted `0x00`).
- Determine whether parity packets explicitly wait for the video frame tick or
  align with descriptors as a side effect of host scheduling.
- Check `vrlink`'s uplink format word on the wire: no writer of `SVLAudio+0x0c`
  was found (the constructor zeroes it and `QSVLClientAudioNdk::Init` only sets
  the channel count at `+0x08` to 1). If nothing writes `+0x0c`, `vrlink`'s mic
  packets carry `aux == 0x0000`.

## Client playback verification

OpenVRLink plays downlink audio as interleaved signed 16-bit little-endian
stereo PCM at 48 kHz with live audio playing on the host. Listening checks
confirmed clean output, verifying sample format, byte order, channel count, and
sample rate beyond static analysis. Under 3% simulated packet loss, packets
reconstructed from XOR parity (55 packets in 16 s) produced no audible glitches.
