# Audio packet format

Sources: `SVLAudio::TransmitAudioPacket(dataset*, unsigned short)` +0x1575a8,
`SVLAudio::TransportRXAudioFrames(dataset*)` +0x1571b8,
`SVLDataLink::ReceivedData(dataset*)` +0x15a9b8.

## The `dataset` header as audio uses it

Every message handed to/received from the data link is a `dataset`: an 8-byte
header followed by the payload. Audio fills it like this (**static**, both
functions above; little-endian):

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
type-0x0c packet whose `seq % 3 == 2` (that one carries a length instead).
Note a type-0x0b parity packet still carries a normal format word.

When the decoded rate differs from the rate the output stream is running at
(`SVLAudio+0xc4c`), the client logs
`[Audio] frame rate change, reinitializing: %d %d to %d %d` (old rate, old
channels, new rate, new channels) and re-opens its audio streams at the new
rate (vtable +0x10 = `QSVLClientAudioNdk::Init(true, rate)` +0xf4184).

## Payload

Interleaved signed 16-bit PCM, native (little-endian) byte order, no
compression (**static**: payload pointer `dataset+8` is passed as `short*` to
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

## Confirmed against a wire capture

Capture: `vr3` (real client under Klepton, 40.26 s of streaming, 80,011 SVL
datagrams, none torn, each with a CLOCK_MONOTONIC receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. The earlier
capture `vr1` had a third of its datagrams torn and no timestamps, so its
counts were lower bounds; every figure here is a complete count.

- **captured**: the 8-byte header in the table above is the transport's
  element header, byte for byte. All 2,913 audio elements are byte 0 `0x0c`,
  byte 1 `0x10`, host -> client. In the transport's vocabulary that is
  "class 0x0c, type 0x10" (which is how `svldump.py` and the capture census
  print it); in this folder's vocabulary it is "type 0x0c, flags 0x10". Same
  bytes: the prediction "type 0x0c" was right, and the "type 0x10" in a census
  line is this page's `flags`. Likewise the transport's `id` is `seq` and its
  `index` is `aux`.
- **captured**: no element with byte 0 = 0x06 or 0x0b exists in `vr3`, in
  either direction.
- **captured**: `seq` runs 0, 1, 2, ... 2912 with every step +1 (2,912 of
  2,912): no loss, no duplicate, no reordering.
- **captured**: on data packets (`seq % 3` = 0 or 1) the format word is
  `19201 = 0x4b01` in all 1,942 cases -> 48000 Hz, 2 channels. On the 971
  parity packets it is a length (896 x851, 1024 x60, 768 x60).
- **captured**: payload lengths: 1024 x2,002, 896 x851, 768 x60 (256 / 224 /
  192 stereo frames); never above 1024, never anything else. Position 0 (A)
  is always 1024; position 1 (B) is 896 (851), 1024 (60) or 768 (60);
  position 2 (parity) is always 1024.
- **captured**: a group (A + B) carries 480 frames = 10 ms in 851 of 971
  groups. The other 120 groups come as 60 adjacent pairs, always 512 frames
  (1024 + 1024) followed by 448 (1024 + 768), so every pair is again 960
  frames. Total 466,080 frames = 971 x 480 = 9.710 s of audio.
- **captured**: sample rate from timing. A least-squares fit of cumulative
  frames against the arrival time of each group's A packet gives
  47,998.4 frames/s over the whole burst (47,997.7 excluding the first 20
  groups) - 48 kHz to within 35 ppm of the client machine's clock, i.e. the
  rate the format word announces. 2,913 messages in 9.701 s = 300.3
  messages/s = 100.1 groups/s.
- **captured**: datagram packing. 2,909 of the 2,913 audio elements are alone
  in their datagram. The other 4 share a datagram with the host's class 3
  type 0x18 message (which comes every 2 s; either order was seen). Audio
  never shares a datagram with a video packet or frame descriptor.
- **captured** (client log in the same run):
  `[aaudio] openStream: 48000 Hz, 2 ch, int16, burst 240 frames`,
  `[Audio] AAudioStream_getFramesPerBurst = 240`.
- **captured, negative**: PCM content is still unconfirmed. All 1,942 data
  payloads in `vr3` are all-zero bytes (peak 0, RMS 0 in every second of the
  burst), exactly as in `vr1`. So bit depth, endianness and interleave order
  remain **static** only; no channel-correlation or spectrum check was
  possible. (The WAV written from the capture, 9.71 s, is digital silence.)
  See "Timing" below for what this says about when the host sends.
- **captured, negative**: no client -> host audio element exists in `vr3`
  (see [microphone-uplink.md](microphone-uplink.md)), so the uplink header
  and format word are still unconfirmed.

### Timing of the downlink (`vr3`)

- **captured**: audio is a single burst: first message at t = 1.855 s, last
  at t = 11.556 s (9.701 s), then nothing for the remaining 28.7 s of the
  session while video continues. For reference, the first video packet is at
  t = 0.926 s. The burst begins at `seq` 0 on an A packet and ends on a parity
  packet, i.e. on whole groups. There are no gaps inside it: the longest
  inter-arrival is 18.1 ms.
- **captured**: nothing in-band delimits the burst. No other host message
  sits within 20 ms of its start or end except video frame descriptors, the
  payload is zeros from the first message to the last (so there is no ramp
  to or from silence to see), and no value-transport value completes in
  either direction after t = 1.05 s.
- The owner's live probes (docs/svl-values/startup-exchange.md, "Audio,
  settled (probe)") established that the host sends audio only while
  something is playing on the host and nothing otherwise, so the absence of
  audio after t = 11.6 s is expected, not loss. What `vr3` adds: the roughly
  ten-second burst at session start is 9.71 s of digital silence, not an
  audible sound. **inferred**: the host's gate is on its capture stream being
  active rather than on sample values; a capture with known audio playing
  would show whether zeros are ever sent in the middle of real sound.
- **captured**: within a group, B follows A after a median 0.20 ms (p95
  0.27 ms) - consistent with the 250 us minimum gap in "Send pacing" being
  the host's too (**inferred**: same code). A to next A: median 10.09 ms,
  mean 9.994 ms. Occasionally two groups arrive back to back (A to A under
  2.5 ms, 59 times) after a double-length gap (16 to 21 ms, 60 times).
- **captured**: the parity packet does not follow B immediately. B to parity
  is spread evenly over 0 to 10 ms (median 4.43 ms). 907 of the 971 parity
  packets arrive within 0.3 ms of the first frame descriptor (class 5 type 2,
  index 0) of a video frame, and in 884 cases the parity datagram is the one
  immediately before that descriptor's datagram in transport sequence, with B
  immediately before the parity. A and B show no such alignment (41 and 44 of
  971 within 0.3 ms). **inferred**: the host queues the parity and flushes it
  on its video frame tick (video frames were 9.10 ms apart during the burst),
  so a recovery by parity can lag the lost packet by up to one video frame.
- **captured**: start of the burst. The first groups arrive slightly faster
  than real time (group starts at 0, 9.3, 18.4, 26.7, 35.9 ms; 3,136 frames
  = 65 ms of audio in the first 54 ms), then settle to 10 ms. There is no
  large initial flush.

## Open questions / to confirm on the wire

- PCM content: two captures in a row are all zeros. A capture with a known
  signal playing on the host (e.g. a tone in one channel) is needed to confirm
  s16le and the L/R interleave order.
- Why the host sends 9.71 s of silence at session start and then stops; and
  whether it ever sends type 0x06 or 0x0b (only reachable by advertising
  capabilities 0 or 1 in VTE 0x18 - a probe).
- Whether the host ever sends `len` > 1024 (never in 2,913 messages).
- What the host's `flags` byte is on type 6 (predicted `0x00`).
- Whether the parity packet really waits for the video frame tick, or the
  alignment is a side effect of something else on the host.
- The uplink format word: the writer of `SVLAudio+0x0c` was not located (the
  constructor zeroes it and `QSVLClientAudioNdk::Init` only sets the channel
  count at +0x08 to 1). If nothing sets it, the client's mic packets carry
  `aux == 0x0000`; a capture of a client mic packet decides this.

## Client results (2026-11-10): the PCM format, confirmed by ear

The Swift client (`client`) plays the downlink as interleaved signed
16-bit little-endian PCM, 48 kHz, two channels, exactly as described above,
with real audio playing on the host. The project owner listened and reports it
sounds perfect. So sample format, byte order, channel count and rate are no
longer static-only. Under 3 % simulated loss, packets rebuilt from the XOR
parity (55 in 16 s) were not audible as faults.
