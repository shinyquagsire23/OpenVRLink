# SVL video path (host -> client)

This folder covers the path from a decrypted SVL message arriving to an eye
texture being handed to the compositor, read out of `libvrlink_scene.so` (Android arm64).
The UDP header, encryption, handshake and reliable stream are the transport
(docs/svl-transport/) and are not described here.

Evidence classes used in these files:

- **static** - read out of the binary. Symbol and *file offset* are given
  (Ghidra address = file offset + 0x100000).
- **inferred** - a guess from static evidence; each one says what would confirm it.
- **captured** - checked against a wire capture and the matching decoder
  input stream. The capture is `vr3` (neither it nor the decoder dump is in
  the repo; the log holds live credentials): the real client under Klepton,
  40 s of streaming on a clean LAN, 4,260 video frames in 60,945 video
  elements, no datagram torn, every datagram timestamped. It is a
  desktop-viewer session, so poses/frusta are placeholders, and it has no
  packet loss worth the name (one datagram), so nothing that needs loss -
  retransmit requests, real FEC repair, client resets - is in it. A few such
  observations survive from an older, torn and lossy capture, `vr1`, and are
  marked as such. Each file has a "Captured" section saying exactly what was
  checked, then what is still open.

One caveat applies to every file: the library contains both halves of the FEC
(`SVLFECRAID6TXFrame` and `SVLFECRAID6RXFrame`) because the code is shared with
the host. The *receive* half is what this client runs. The *transmit* half is
used here as a description of what the host sends, which is **inferred** - the
host is a different build and may differ in detail. Where `vr3` confirms the
host doing what the TX half does (send order, parity bytes, bookend counts),
the page says so.

| File | Topic |
|---|---|
| [packets.md](packets.md) | The `dataset` message header, video message kinds, the data/parity packet, numbering, send order |
| [frame-descriptor.md](frame-descriptor.md) | `SVLVideoFrameDescriptor_t` (the "bookend"): header, piggy-backed values / timing events / VTE bytes |
| [fec.md](fec.md) | The RAID-6 FEC: Liber8tion bit-matrix code, stripe geometry, encode, tested reconstruct code |
| [retransmit.md](retransmit.md) | Retransmit requests, the per-pose frame report (`LastVideoPacket_t`), frame ordering window, error/reset path |
| [frame-metadata.md](frame-metadata.md) | `TransportFrameMetadata_t` (0x154 bytes): render pose, per-eye projection, foveal inset rect, atlas size, display time |
| [decode-handoff.md](decode-handoff.md) | `QSVLCodecNDK` / `QSVLFrameServer`: MediaCodec configuration, how a frame is queued, pts, frame selection |
| [frame-layout.md](frame-layout.md) | How the decoded atlas maps to eyes and foveation layers; shaders and uniforms; foveal FOV math |

## The path in one paragraph

**static** unless marked. The host sends each encoded frame as: one frame
descriptor ("bookend 0"), then the HEVC access unit cut into 1024-byte data
packets, with parity packets and a further bookend after every 64 data
packets (**captured**: exactly this order in 4,259 of 4,260 frames). The client (`SVLFEC::AcceptVideoPacket`, +0x160684) keeps 16 receive
slots indexed by `frame_id & 15`, copies each data packet straight into a
MediaCodec input buffer at `packet_id * 1024`, repairs up to two losses per
10-packet stripe with a Liber8tion RAID-6 code (jerasure), asks for anything
still missing with a retransmit request, and when the contiguous prefix covers
the frame hands the buffer to `AMediaCodec_queueInputBuffer` with
`presentationTimeUs = frame_id`. Frames are submitted strictly in frame-id
order. Decoded images come back through an `AImageReader`, are matched to
their `TransportFrameMetadata_t` by frame id, and the renderer picks the image
whose host display time is closest to the compositor's predicted display time.
The atlas is cut into per-eye base and foveal-inset tiles by two tiny shaders
and submitted as two `XrCompositionLayerProjection` layers.

## Numbers worth remembering

| Constant | Value | Where (static) |
|---|---|---|
| data packet payload | 1024 bytes (last one shorter) | `SVLFECRXFrame::AcceptVideoPacket` +0x15edc8 |
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

Measured in `vr3` (**captured**; one run of a mostly static scene, not a
specification - details in [packets.md](packets.md) and
[retransmit.md](retransmit.md)):

| Quantity | Value |
|---|---|
| frame rate | 108.3 frames/s; interval median 9.2 ms, 94.5 % within 8.0 .. 10.5 ms |
| frame size | median 7.7 kB (8 data packets); largest 283,768 bytes (278 data packets, 5 groups) |
| bitrate | 6.8 Mbit/s steady, 116 Mbit/s during a 0.64 s burst half a second after start |
| wire overhead | video elements total 1.42 x the encoded bytes |
| time to receive one frame | median 0.77 ms first to last element; 13.8 ms for the largest |
| parity | P on every stripe; Q as well for the first 8.64 s (frames 0..941), then never |
| FEC check | 8,404 of 8,404 host parity packets equal the documented code |
| IDR frames | 2: frames 0 and 4; none afterwards, no periodic keyframe |
| loss | 1 datagram of 62,589 (a closing bookend); no retransmit request, no client reset |
| frame reports | one per pose datagram, 433/s; accept = arrival of last data packet; decode +3.0 ms median |

## Thin areas

See the "Open questions" section of each file. Confirmed by capture (`vr3`,
complete data): the packet header and numbering, the send order end to end
including multi-group frames, reassembly (4,259 frames byte-exact against
the decoder input; the 4,260th is cut short in the dump, not on the wire),
P and Q parity over every stripe, the descriptor header and trailer over all
8,631 descriptors, the frame-report layout and its accepted/decoded/display
ids, the metadata atlas fields, and the bitstream (Annex-B, Main 10,
1536 x 6144, four slices per frame). Still open: everything that needs loss -
what the host sends in answer to a retransmit request and how fast, the
0xffff descriptor request, a real two-erasure repair, and the link between a
client reset (`rst` in the pose packet) and the next IDR - because `vr3` is
clean and `vr1` was too torn to trace; why the host sends Q parity for the
first 8.64 s and a second IDR at frame 4; several unnamed metadata and
descriptor fields (descriptor +0x14, metadata +0xc4/+0xee); why both eyes
get one pose; the color pipeline; tile order by eye (static only); and
anything that needs a real headset session (moving pose, asymmetric frusta,
moving fovea).
