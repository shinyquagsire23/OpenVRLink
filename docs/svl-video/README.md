# SVL video path (host -> client)

This folder documents the video pipeline in `libvrlink_scene.so` (Android arm64),
from decrypted SVL messages arriving on the client to eye textures submitted to
the OpenXR compositor. Transport framing—including the UDP header, encryption,
handshake, and reliable stream—is covered in `docs/svl-transport/`.

These documents tag findings with three evidence classes:

- **static** - read from the binary, with symbol names and *file offsets*
  (Ghidra address = file offset + 0x100000).
- **inferred** - deduced from static evidence; each entry notes what would confirm it.
- **captured** - verified against a wire capture and its matching decoder
  input stream. The primary capture is `vr3` (neither the capture nor the decoder
  dump is in the repo because the log contains live credentials): `vrlink`
  running under Klepton for 40 s on a clean LAN, covering 4,260 video frames
  across 60,945 video elements, with no torn datagrams and a timestamp on every
  datagram. Because `vr3` is a desktop-viewer session, poses and frusta are
  placeholders, and only a single datagram was lost across the entire run, so
  loss-driven paths (retransmit requests, live FEC repair, and client resets)
  were never triggered. A few loss-related observations come from an older,
  lossy capture with truncated datagrams (`vr1`) and are marked accordingly.
  Each file includes a "Captured" section detailing what was verified on the
  wire, followed by open questions.

One caveat applies throughout: `libvrlink_scene.so` contains both halves of the
FEC (`SVLFECRAID6TXFrame` and `SVLFECRAID6RXFrame`) because it shares source
code with the host. `vrlink` runs the *receive* half. Descriptions of host
behavior drawn from the *transmit* half are **inferred**, since the host is a
separate build that may differ in detail. Each page notes where `vr3` confirms
that the host matches the shared TX code (such as send order, parity bytes, and
bookend counts).

| File | Topic |
|---|---|
| [packets.md](packets.md) | The `dataset` message header, video message kinds, the data/parity packet, numbering, send order |
| [frame-descriptor.md](frame-descriptor.md) | `SVLVideoFrameDescriptor_t` (the "bookend"): header, piggy-backed values / timing events / VTE bytes |
| [fec.md](fec.md) | The RAID-6 FEC: Liber8tion bit-matrix code, stripe geometry, encode, tested reconstruct code |
| [retransmit.md](retransmit.md) | Retransmit requests, the per-pose frame report (`LastVideoPacket_t`), frame ordering window, error/reset path |
| [frame-metadata.md](frame-metadata.md) | `TransportFrameMetadata_t` (0x154 bytes): render pose, per-eye projection, foveal inset rect, atlas size, display time |
| [decode-handoff.md](decode-handoff.md) | `QSVLCodecNDK` / `QSVLFrameServer`: MediaCodec configuration, how a frame is queued, pts, frame selection |
| [frame-layout.md](frame-layout.md) | How the decoded atlas maps to eyes and foveation layers; shaders and uniforms; foveal FOV math |

## Overview

Everything below is **static** unless marked otherwise. For each encoded frame,
the host sends an initial frame descriptor ("bookend 0") followed by the HEVC
access unit split into 1024-byte data packets, inserting parity packets and
another bookend after every 64 data packets (**captured**: 4,259 of 4,260
frames arrived in this exact order). On the client, `SVLFEC::AcceptVideoPacket`
(+0x160684) maintains 16 receive slots indexed by `frame_id & 15`, copies each
data packet directly into a MediaCodec input buffer at `packet_id * 1024`,
repairs up to two erasures per 10-packet stripe using jerasure's Liber8tion
RAID-6 code, and sends retransmit requests for any remaining gaps. Once the
contiguous received prefix covers the frame, `vrlink` submits the buffer via
`AMediaCodec_queueInputBuffer` with `presentationTimeUs = frame_id`. Frames go
to the decoder strictly in frame-id order. Decoded images return through an
`AImageReader` and are matched back to their `TransportFrameMetadata_t` by
frame id; the renderer selects the image whose host display time is closest to
the compositor's predicted display time. Finally, two small shaders crop the
decoded atlas into per-eye base and foveal-inset tiles and submit them as two
`XrCompositionLayerProjection` layers.

## Constants and captured metrics

| Constant | Value | Where (static) |
|---|---|---|
| data packet payload | 1024 bytes (last packet shorter) | `SVLFECRXFrame::AcceptVideoPacket` +0x15edc8 |
| data packet ids | 0x000..0x7ff | same |
| parity packet ids | 0x800..0xfff | same |
| stripe | 8 data + 2 parity packets | `SVLFECRAID6::SVLFECRAID6` +0x161e90 |
| group | 64 data + 16 parity packets (8 stripes) | same |
| max frame | 0x400000 bytes accepted by `Initialize`; 0x800 * 1024 = 2 MiB addressable by packet id | `SVLFECRXFrame::Initialize` +0x15f6f4 |
| receive slots | 16 (`frame_id & 0xf`) | `SVLFEC::AcceptVideoPacket` |
| completed-frame ring | 128 (`frame_id & 0x7f`) | `SVLFEC::InternalAcceptFrameFromRX` +0x160050 |
| reorder window | 5 frames | same |
| FEC mode byte | 0x20 | `SVLDataLink::SVLDataLink` +0x15a000 |
| metadata size | 0xf0 on the wire (captured, all 8,631 descriptors); 0x154 is the long form | `GetEndOfPacketFromVideoDescriptor` +0x155c14 |
| descriptor size | fixed 1024-byte message (`len` 0x3f8), trailer at +0x118; bytes after the trailer are not zeroed (captured) | [frame-descriptor.md](frame-descriptor.md) |
| descriptors per frame | 1 + number of groups, none repeated (captured) | [frame-descriptor.md](frame-descriptor.md) |
| descriptor `version` | 14 from this host (captured) | [frame-descriptor.md](frame-descriptor.md) |
| codec | `video/hevc`, P010 output | `QSVLCodecNDK::Init` +0xfd1b4 |

The table below lists metrics from `vr3` (**captured** from a single run of a
mostly static scene, rather than protocol limits; see [packets.md](packets.md)
and [retransmit.md](retransmit.md) for details):

| Quantity | Value |
|---|---|
| frame rate | 108.3 frames/s; interval median 9.2 ms, 94.5 % within 8.0 .. 10.5 ms |
| frame size | median 7.7 kB (8 data packets); largest 283,768 bytes (278 data packets, 5 groups) |
| bitrate | 6.8 Mbit/s steady, 116 Mbit/s during a 0.64 s burst half a second after start |
| wire overhead | video elements total 1.42 x the encoded bytes |
| time to receive one frame | median 0.77 ms first to last element; 13.8 ms for the largest |
| parity | P on every stripe; Q also sent for the first 8.64 s (frames 0..941), then omitted |
| FEC check | 8,404 of 8,404 host parity packets equal the documented code |
| IDR frames | 2 (frames 0 and 4); none afterward, no periodic keyframe |
| loss | 1 datagram of 62,589 (a closing bookend); no retransmit request, no client reset |
| frame reports | one per pose datagram, 433/s; accept = arrival of last data packet; decode +3.0 ms median |

## Coverage and open questions

See the "Open questions" section in each file for remaining unknowns.

`vr3` (**captured**) confirms the packet header and numbering, the end-to-end
send order (including multi-group frames), frame reassembly (4,259 frames match
the decoder input byte for byte, while frame 4259 was cut short in the local
dump file rather than on the wire), P and Q parity across every stripe, the
descriptor header and trailer across all 8,631 descriptors, the frame-report
layout and its accepted/decoded/display ids, the metadata atlas fields, and the
HEVC bitstream parameters (Annex-B, Main 10, 1536 x 6144, four slices per
frame).

Open items from `vr3` and `vr1` (several addressed in later probe and client
test sections in the individual pages) include loss-driven paths—what the host
sends in response to a retransmit request and how quickly, the `0xffff`
descriptor re-request, live two-erasure FEC repair, and how a client reset
(`rst` in the pose packet) triggers the next IDR—because `vr3` had almost no
loss and `vr1` was too truncated to trace. Other open questions cover why the
host sends Q parity for the first 8.64 s and a second IDR at frame 4, several
unnamed descriptor and metadata fields (descriptor +0x14, metadata +0xc4/+0xee),
why both eyes receive a single pose in metadata, the color pipeline, per-eye
tile order (static before pixel-disparity checks in
[frame-layout.md](frame-layout.md)), and behavior requiring a physical headset
session (moving poses, asymmetric frusta, and dynamic foveation).
