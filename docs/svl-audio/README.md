# SVL audio

This folder describes how game audio (host to client) and microphone audio
(client to host) ride on the SVL transport. The mechanisms were read out of `libvrlink_scene.so`
(Android arm64 Steam Link VR client) and then checked against wire captures;
the current reference capture is `vr3`.

| file | topic |
|---|---|
| [packet-format.md](packet-format.md) | the audio `dataset` header, the three packet types, payload format (raw PCM) |
| [fec.md](fec.md) | the 2+1 XOR parity scheme, receive state machine, loss accounting |
| [negotiation-and-settings.md](negotiation-and-settings.md) | VTE 0x18 / 0x19 (FEC capability bits), VTE 0x26 (jitter-buffer settings, 47 bytes) |
| [jitter-buffer.md](jitter-buffer.md) | `CAudioJitterBuffer<short>`: start-up fill, rewind / fast-forward crossfades, fade-out, the `cAud*` statistics |
| [microphone-uplink.md](microphone-uplink.md) | capture format, aggregation into packets, pacing |

## Summary

- **No codec.** Both directions are interleaved signed 16-bit little-endian
  PCM. There is no Opus/AAC encoder or decoder call anywhere on the path
  (**static**: `SVLAudio::TransportRXAudioFrames` +0x1571b8 hands the packet
  payload straight to `AcceptAudioFramesFromPeer(short*, frames)`).
- **Downlink**: stereo, sample rate announced in every packet header
  (`rate/10` in 14 bits); the client re-opens its output stream when it changes.
  The client's own fallback rate is 48000 (**static**:
  `QSVLClientAudioNdk::Tick` +0xf4758).
- **Uplink**: mono, same sample rate as the output stream, at most 1024 payload
  bytes (512 frames) per packet.
- **FEC**: optional, negotiated by two capability bits. Packets are numbered;
  every third packet is the XOR of the previous two.
- **Jitter buffer**: 16384-frame ring with host-tunable thresholds (VTE 0x26).
  It keeps the *minimum* fill over a 500 ms window between 15 and 25 ms by
  splicing (crossfaded rewind or fast-forward at zero crossings), and fades to
  silence when it runs dry.
- Audio packets are sent unreliable through the data link
  (`SVLDataLink` vtable +0x58), i.e. below this layer is the transport
  (docs/svl-transport/).

## Capture status

Checked against `vr3` (real client under Klepton, 40 s, no torn datagrams,
timestamps); each topic file has a "Confirmed against a wire capture" section.
`vr3` replaces the earlier `vr1` figures, which were lower bounds.

Naming: this folder calls byte 0 of the 8-byte header "type" and byte 1
"flags" (the audio code's view). The transport docs and tools call the same
bytes "class" and "type", so the downlink packet described here as "type
0x0c, flags 0x10" appears in a capture census as "class 0x0c type 0x10".

**captured** in `vr3`:

- 2,913 downlink messages, all type 0x0c / flags 0x10, `seq` 0..2912 with no
  gap; format word 0x4b01 on all 1,942 data packets; payloads 1024 / 896 / 768
  bytes; one audio element per datagram (4 share one with the host's class 3
  type 0x18 message, none with video).
- 971 of 971 A / B / parity triples satisfy the XOR and the max/min length
  rules.
- 480 frames per group in 10.0 ms: 47,998 frames/s measured, i.e. 48 kHz;
  300 messages/s.
- Audio came as one burst, t = 1.86 to 11.56 s of a 40 s session. Live probes
  show the host sends audio only while something plays on the host, so the
  silence afterwards is not loss.
- VTE 0x18 / 0x19 = 3, the 47-byte VTE 0x26 (defaults) and its mapping to
  jitter-buffer thresholds via the client's init log.
- Jitter buffer: fade-in at 2400+ frames, 500 ms statistics windows in ms, one
  fast-forward that pulls the windowed minimum from 39 to 19 ms, fade-out when
  the stream stops, `cAudUnd` counting frames of silence at 48,000 per second
  whenever no audio is flowing.
- The parity packet is held back and arrives with the next video frame's
  first descriptor (907 of 971).

**Still static only**: PCM sample content (every payload in both captures is
zeros), FEC recovery and loss accounting (nothing was lost), sequence wrap,
rewind / overflow / gap-splice in the jitter buffer, and the whole microphone
uplink (no client -> host audio element in either capture; the client's input
stream fails to open under Klepton).

## Thin areas

- `CAudioJitterBuffer<short>::FindBestCrossfadeEndpoint` (+0x15991c) was not
  decompiled; its role is known from the call site only.
- The writer of the uplink sample-rate field (`SVLAudio+0x0c`) was not found.
- Nothing about host-side behavior (what the host does with `cAud*`) is known.
