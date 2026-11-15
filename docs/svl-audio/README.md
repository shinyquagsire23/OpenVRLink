# SVL audio

This folder documents how game audio (host to client) and microphone audio
(client to host) run over the SVL transport, based on static analysis of
`libvrlink_scene.so` (`vrlink` on Android arm64) and wire captures (primarily
`vr3`).

| file | topic |
|---|---|
| [packet-format.md](packet-format.md) | audio `dataset` header, the three packet types, payload format (raw PCM) |
| [fec.md](fec.md) | 2+1 XOR parity scheme, receive state machine, loss accounting |
| [negotiation-and-settings.md](negotiation-and-settings.md) | VTE 0x18 / 0x19 (FEC capability bits), VTE 0x26 (jitter-buffer settings, 47 bytes) |
| [jitter-buffer.md](jitter-buffer.md) | `CAudioJitterBuffer<short>`: start-up fill, rewind / fast-forward crossfades, fade-out, `cAud*` statistics |
| [microphone-uplink.md](microphone-uplink.md) | capture format, packet aggregation, send pacing |

## Summary

- **Uncompressed PCM**: Both directions carry interleaved signed 16-bit
  little-endian PCM with no Opus or AAC codec on the path (**static**:
  `SVLAudio::TransportRXAudioFrames` +0x1571b8 passes the packet payload
  directly to `AcceptAudioFramesFromPeer(short*, frames)`).
- **Downlink**: Downlink audio is stereo, with the sample rate announced in
  every packet header (`rate/10` in 14 bits). The client reopens its output
  stream whenever the rate changes and falls back to 48000 Hz on stream
  disconnect (**static**: `QSVLClientAudioNdk::Tick` +0xf4758).
- **Uplink**: Uplink audio is mono at the output stream's sample rate, carrying
  at most 1024 payload bytes (512 frames) per packet.
- **FEC**: Forward error correction is optional and negotiated via two
  capability bits. Packets carry a sequence number, and every third packet holds
  the XOR parity of the previous two.
- **Jitter buffer**: A 16384-frame ring buffer with host-tunable thresholds
  (VTE 0x26) keeps the *minimum* fill over a 500 ms window between 15 and 25 ms
  by splicing (crossfaded rewind or fast-forward at zero crossings), and fades
  to silence when it runs dry.
- **Transport**: Audio packets are sent unreliably through the data link
  (`SVLDataLink` vtable +0x58); see docs/svl-transport/ for the underlying
  transport layer.

## Capture status

Wire behavior was verified against capture `vr3` (40 s of `vrlink` under
Klepton with intact, timestamped datagrams); each topic file has a capture
verification section. `vr3` supersedes the earlier `vr1` counts, which were
lower bounds from torn datagrams.

In this folder, byte 0 of the 8-byte header is called "type" and byte 1 is
called "flags", matching the audio code. The transport docs and tools call the
same bytes "class" and "type", so the downlink packet described here as "type
0x0c, flags 0x10" appears in a capture census as "class 0x0c type 0x10".

Confirmed in `vr3` (**captured**):

- 2,913 downlink messages arrived, all type 0x0c / flags 0x10 with contiguous
  `seq` 0..2912. All 1,942 data packets carried format word 0x4b01 with payload
  lengths of 1024, 896, or 768 bytes. Nearly every datagram carried one audio
  element (4 shared a datagram with the host's class 3 type 0x18 message, and
  none shared with video).
- All 971 A / B / parity triples satisfied the XOR parity and max/min length
  rules.
- Groups carried 480 frames per 10.0 ms (47,998 frames/s measured, matching
  48 kHz, at 300 messages/s).
- Audio arrived in a single burst from t = 1.86 to 11.56 s of the 40 s session.
  Live probes show that the host sends audio only while something plays on the
  host, so the silence afterward is normal idle behavior rather than packet
  loss.
- VTE 0x18 and 0x19 were set to 3, and the 47-byte VTE 0x26 carried default
  settings whose mapping to jitter-buffer thresholds matched `vrlink`'s init
  log.
- The jitter buffer faded in at 2400+ frames, published 500 ms window
  statistics in milliseconds, performed one fast-forward splice that pulled the
  windowed minimum from 39 to 19 ms, faded out when the stream stopped, and
  incremented `cAudUnd` at 48,000 frames/s whenever no audio was flowing.
- Parity packets were held back and arrived alongside the next video frame's
  first descriptor in 907 of 971 groups.

Several areas remain **static** only: PCM sample content (every payload in both
captures is all zeros), FEC recovery and loss accounting (no packets were lost),
sequence wrap, rewind / overflow / gap-splice paths in the jitter buffer, and
the entire microphone uplink (neither capture contains client-to-host audio
elements because `vrlink`'s input stream fails to open under Klepton).

## Unresolved details

- `CAudioJitterBuffer<short>::FindBestCrossfadeEndpoint` (+0x15991c) was not
  decompiled; its role is known from the call site only.
- The writer of the uplink sample-rate field (`SVLAudio+0x0c`) was not found.
- Host-side handling of the `cAud*` statistics is unknown.
