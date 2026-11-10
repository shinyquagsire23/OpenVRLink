# Decode hand-off - `QSVLCodecNDK` and `QSVLFrameServer`

How a reassembled frame reaches the decoder and how decoded images reach the
renderer. `QSVLCodecNDK` is the Android MediaCodec backend of the abstract
`SVLCodec`; its virtual table is at file offset 0x210bb0 (**static**):

| Slot | Function | Offset |
|---|---|---|
| +0x10 | `Init()` | 0xfd1b4 |
| +0x18 | `SubmitFrameForDecode(uchar**, int size, uint frame_id, bool)` | 0xfda94 |
| +0x20 | `AcquireEncodedDataBuffer(uint frame_id, ulong* capacity)` | 0xfd99c |
| +0x28 / +0x30 | `SoftReset()` / `HardReset()` (empty in this build) | 0xfe4dc / 0xfe4e0 |
| +0x38 | `Flush()` | 0xfe0a8 |
| +0x40 | `Stop()` | 0xfe1e8 |
| +0x48 | `BIsStuck()` | 0xfdda8 |

## Codec configuration

**static** - `QSVLCodecNDK::Init`:

```
AMediaCodec_createDecoderByType("video/hevc")
format:
  mime            "video/hevc"
  width, height   896 x 3584          (0x380 x 0xe00)  - initial only
  max-width/height 1536 x 7680        (0x600 x 0x1e00)
  color-transfer  1    (Android COLOR_TRANSFER_LINEAR)
  color-standard  6    (Android COLOR_STANDARD_BT2020)
  color-range     1    (Android COLOR_RANGE_FULL)
  color-format    0x36 (54 = COLOR_FormatYUVP010)
  priority        0
  operating-rate  0x7fff
  "low-latency" = 1
  "vendor.qti-ext-dec-low-latency.enable" = 1
  "vendor.qti-ext-dec-picture-order.enable" = 1
  "vendor.qti-ext-dec-heif-mode.value" = 1
output: AImageReader_newWithUsage(1, 1, AIMAGE_FORMAT_PRIVATE,
                                  AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, maxImages = 20)
AMediaCodec_configure(codec, format, readerWindow, nullptr, 0); AMediaCodec_start
```

What follows from it:

- **static**: HEVC is the only codec. There is no codec negotiation and no
  other mime string in the library.
- **static**: no `csd-0` is supplied. **captured** (see the end): parameter
  sets (VPS/SPS/PPS) arrive in-band and the stream is Annex-B framed.
- **static**: the client asks for P010 output and declares BT.2020 full range
  with transfer "linear". **captured**: the stream is 10-bit HEVC Main 10 and
  its VUI says full range and BT.2020 primaries, but transfer gamma 2.2 and
  matrix "identity" - see "Color description" below. The MediaFormat keys
  and the VUI agree only on range and primaries.
- **static**: the picture can be up to 1536 wide and 7680 tall. The size
  actually in use comes from the SPS; the renderer learns tile sizes from the
  frame metadata, not from the decoder.
- **static**: nothing on the client parses the bitstream - no start-code scan,
  no NAL type check, no keyframe detection.

## Input: one frame = one input buffer

**static**:

1. When a receive slot is initialized for a new frame
   (`SVLFECRXFrame::Initialize` +0x15f6f4) it calls
   `AcquireEncodedDataBuffer(frame_id, &capacity)`:
   `AMediaCodec_dequeueInputBuffer(codec, 20000 us)` then
   `AMediaCodec_getInputBuffer`. The buffer index is remembered per
   `frame_id & 0xf`. On failure the frame cannot be received at all (`"Could
   not acquire encoded data buffer from codec for frame: %i"`); error -10000
   triggers `Stop()` + `Init()`.
2. Data packets and FEC-recovered blocks are written **directly into that
   input buffer** at `packet_id * 1024`. There is no intermediate frame buffer.
3. When the frame is complete and it is its turn
   ([retransmit.md](retransmit.md)), `SubmitFrameForDecode(&buf, size,
   frame_id, true)` calls

   ```
   AMediaCodec_queueInputBuffer(codec, index, offset = 0, size = frame_size,
                                presentationTimeUs = frame_id, flags = 0)
   ```

   then pushes `(frame_id, submit_time)` on a marker queue and calls
   `QSVLClient::GotNetworkFrame()`.

So:

- **One access unit per frame id, queued whole.** The bytes are exactly the
  concatenation of the data-packet payloads, truncated to `frame_size`.
- **The pts is the 16-bit frame id**, zero-extended, in the microseconds field.
  It is a frame counter and wraps to 0 after 65535. A decoder backend
  must carry it through untouched (the client uses it to find the frame's
  metadata) and must not reorder by it. Klepton observed the same thing from
  the outside ("the pts the guest hands the decoder is a frame counter").
- Flags are always 0: no codec-config or key-frame flag is ever set.

## Output

**static**:

- `QSVLCodecNDK::MediaThread` (+0xfd5b4, thread name `SVLMediaThread`) loops on
  `AMediaCodec_dequeueOutputBuffer(1000 us)` and immediately
  `AMediaCodec_releaseOutputBuffer(index, render = true)`, which pushes the
  picture to the `AImageReader` surface. On a dequeue failure it checks
  `BIsStuck()`.
- `BIsStuck()`: true when the oldest entry of the marker queue was submitted
  more than 300 000 us ago. Then the marker queue is cleared and
  `SVLFEC::ExperiencedAnUnrecoverableError()` is raised (reset path in
  [retransmit.md](retransmit.md)).
- `QSVLCodecNDK::HandleOnImageAvailable` (+0xfde30), on the reader's listener
  thread:
  1. `QSVLClient::GotDecodedFrame()` and `PhaseEventDecodeComplete()`.
  2. `AImageReader_acquireLatestImage` (older undelivered images are discarded
     by the reader). Failure logs `"[SVLDecoder] Failed to acquire latest
     image!"`.
  3. `frame_id = AImage_getTimestamp() / 1000` (the reader reports ns; this
     undoes the us -> ns scaling of the pts).
  4. Markers with id <= `frame_id` are popped.
  5. `SVLFEC::GetMetadataForFrameId(frame_id)`; if absent,
     `"[SVLDecoder] Invalid frame metadata for frame [ %d ], dropping."` and the
     image is deleted.
  6. `SVLDataLink::FrameHasBeenDecoded(metadata.present_number, now)`.
  7. `QSVLFrameServer::EnqueueHardwareBuffer({AImage*, frame_id, width, height,
     decode_time})`.

## `QSVLFrameServer` - choosing the frame to show

**static**:

- A deque of decoded images, capped at 5: when a sixth is enqueued the oldest
  are deleted (`EnqueueHardwareBuffer` +0x102274). An awaiting renderer is woken
  through a `std::promise<bool>`.
- `ServeBestHardwareBuffer(out, root, target_local_us, period_us)` (+0x102830),
  used when descriptor `version >= 9`:

  ```python
  best, best_abs, best_diff = None, 1_000_000, 0
  for i, img in enumerate(queue):
      md = metadata_for(img.frame_id)
      if md is None: continue
      diff = to_local(md.display_time) - target_local_us
      if abs(diff) < best_abs: best, best_abs, best_diff = i, abs(diff), diff
  if best is None: return False
  delete queue[0:best]                       # everything older than the best match
  if best_diff <= period_us / 2:             # not more than half a period early
      return pop(queue)                      # serve it
  return False                               # keep it for the next vsync
  ```

  `target_local_us` is `now + (predictedDisplayTime - xr_now)`; `period_us` is
  the third argument of `FlipFrame` in microseconds (**inferred**: the display
  period).
- `ServeNextHardwareBuffer(out, age)` (+0x10270c), used for `version < 9`: pops
  from the front, deleting images until one is newer than the given age or the
  queue is empty; optionally waits up to 5 ms for a new frame.

The served `AImage`'s `AHardwareBuffer` is wrapped as an `EGLImage` and bound
to a `GL_TEXTURE_EXTERNAL_OES` texture for the pass described in
[frame-layout.md](frame-layout.md).

## Notes for a non-Android client

- Feed each completed frame to the decoder as one Annex-B access unit; absorb
  parameter sets from the stream; they can be re-sent with different bytes
  (**captured** in `vr3`: the SPS of the second IDR differs from the first in
  `vui_time_scale` only), so do **not** rebuild the decoder session each time
  unless the picture size changes.
- Keep `frame_id -> metadata` for at least the 16 most recent frames; the
  decoder output must be joined back to its metadata by frame id.
- Decode order is display order (no reordering is tolerated by this design:
  `low-latency`, `picture-order.enable`, and frames are matched by id).
  **captured** (`vr3`): the stream has no B-frames and
  `sps_max_num_reorder_pics` is 0.
- The SPS color description cannot be handed to a decoder framework as it
  stands (matrix "identity" on a 4:2:0 stream); override the Y'CbCr matrix
  ([frame-layout.md](frame-layout.md)).

## Captured

Capture `vr3`: the wire capture and the elementary stream the same client fed
its decoder (`vr3.h265`, with an index of `access_unit, pts, bytes` per queued
buffer; neither is in the repo). Everything in this section is **captured**.
Header fields were read with ffmpeg's `trace_headers` bitstream filter.

### Wire against decoder input

- 4,260 frames (ids 0..4259) rebuild from the wire, none incomplete. Frames
  0..4258 appear in the decoder stream byte for byte, in id order, back to
  back with nothing between them. So the client queued every frame exactly
  once and in order, and each input buffer is exactly the data-packet
  payloads truncated to the descriptor's `frame_size`.
- The one frame "missing" from the dump is the last, 4259: the dump ends with
  its first 6,155 of 7,724 bytes because the file was cut at a 4,096-byte
  boundary when the run was stopped (the frame completed on the wire 1.3 ms
  before the capture's last element). The two agree.
- **pts = frame id**: the index covers buffers 0..4219 (it too stops short of
  the file's end) and every row reads `pts == access unit number == frame
  id`, size equal to the rebuilt frame, with no gap or repeat in the pts
  sequence. Klepton's media layer logged the first buffer as `2512 bytes,
  pts 0 us, flags 0x0`.
- The stream is **Annex-B with 4-byte start codes** throughout (17,046 NAL
  units, no 3-byte start codes).

### Access-unit structure

- NAL types present are only 1 (`TRAIL_R`, 17,032), 19 (`IDR_W_RADL`, 8), 32,
  33, 34 (VPS, SPS, PPS, 2 each) - no SEI, no AUD, no B or leading pictures.
  All NALs are layer 0, temporal id 0.
- **Every one of the 4,260 access units has exactly four slices.** (`vr1`
  reported one with three; with a third of that capture torn it was probably
  damage, and nothing like it occurs here.) An IDR access unit is `VPS, SPS, PPS`
  then four IDR slices (I slices); every other is four `TRAIL_R` P slices
  and begins `00 00 00 01 02 01`.
- **The four slices are the four atlas tiles.** The coding tree block is
  32 x 32 (min coding block 16, one level up), so the picture is 48 x 192
  CTBs and a 1536 x 1536 tile is 2,304 CTBs. The slices have
  `first_slice_segment_in_pic_flag` 1 and then `slice_segment_address` 2304,
  4608, 6912, in all 4,260 access units. Tiles (the HEVC tool) and wavefront
  are off, there are no dependent slice segments, and
  `slice_loop_filter_across_slices_enabled_flag` is 0 in all 17,040 slice
  headers, so the four slices are filtered independently. Motion vectors may
  still cross slice boundaries, so the slices are not independently decodable
  across frames.
- Slice QP alternates with the tile kind: in 4,188 of 4,259 complete frames
  the left base slice starts 27 or 28 QP steps above the left fovea slice,
  and the right eye's two slices start within 1 step of the left eye's.
  Slice QP ranged 5..30 for fovea slices (median 5 to 6) and 33..51 for base
  slices (median 33); CU-level QP deltas are enabled, so these are starting
  points. Mean slice sizes in tile order: 2,927, 2,105, 2,988, 2,024 bytes.
  Access units: 302 bytes minimum, 7,735 median, 10,061 mean, 283,768
  maximum (over the indexed 4,220).
- Reference structure: `sps_max_dec_pic_buffering` 5, no long-term
  references, no temporal MVP. Every P slice codes its own short-term
  reference set of up to four previous pictures and marks **only the
  immediately preceding picture as used**. So each frame depends on exactly
  the one before it; a lost frame breaks everything until the next IDR.
  Picture order count is an 8-bit counter that restarts at each IDR.

### IDR frames and parameter sets

- **Two IDRs in the run, at frames 0 and 4**, and none in the remaining 4,255
  frames (39.3 s). Parameter sets appear only with those two. `vr1` had five
  (frames 0, 5, 39, 74, 82 of 113) and Klepton once reported parameter sets
  "roughly every fifth frame" in another session, so the count is not a
  property of the stream format. In `vr3` the client never asked for a
  reset: the `rst` field was 0 in all 17,423 pose packets
  (docs/svl-tracking-input/poses.md). So the IDR at frame 4 was not asked
  for through `rst`, and a session without resets has no periodic IDR at
  all. What precedes each IDR on the wire belongs to
  [retransmit.md](retransmit.md).
- Frames 0..3 (the first IDR and three P frames, 2,512, 566, 536 and 620
  bytes) decode to a flat fill; real picture starts with the second IDR
  (2,378 bytes, then 13,043). **inferred**: the encoder was restarted once
  the host had the client's configuration.
- VPS and PPS are identical in both IDRs. The two SPS differ only in
  `vui_time_scale`: 40 at frame 0, **114** at frame 4 (with
  `vui_num_units_in_tick` 1, i.e. a nominal 40 then 114 frames per second;
  the measured rate was 108.2). The probe stream has one IDR, the same VPS
  and PPS, and time scale 117. **inferred**: the host writes its current
  frame-rate target there; a decoder should ignore it.

### SPS and PPS

- SPS: HEVC **Main 10** (profile 2), high tier, level 6.1 (`level_idc` 183),
  4:2:0, **1536 x 6144**, no conformance window, 10-bit luma and chroma. AMP
  and SAO on (`slice_sao_luma_flag` 1 on every slice); scaling lists, PCM and
  strong intra smoothing off.
- PPS: one reference by default, `init_qp` 26, CU QP delta on, constrained
  intra prediction on, sign data hiding on, no weighted prediction, no tiles,
  no wavefront, deblocking on with zero offsets.

### Color description (SPS VUI)

| Field | Value | Meaning |
|---|---|---|
| `video_full_range_flag` | 1 | full range |
| `colour_primaries` | 9 | BT.2020 |
| `transfer_characteristics` | 4 | gamma 2.2 (BT.470 System M) |
| `matrix_coefficients` | 0 | identity (GBR) |
| `aspect_ratio_idc` | 1 | square pixels |
| `chroma_loc_info_present_flag` | 0 | chroma siting not signaled |

Identical in both SPS of `vr3` and in the probe stream. Against the client's
MediaFormat (BT.2020, full range, "linear") and the shader:

- Range and primaries agree with the keys.
- Transfer: the stream says gamma 2.2, the key says linear (1). The shader
  does no transfer conversion and writes into an sRGB swapchain with sRGB
  encoding off, which treats the samples as display-referred, i.e. agrees
  with the VUI, not with the key. **inferred**: the key is ignored or
  harmless on the reference devices.
- Matrix: "identity" is not usable as written - it is only defined for 4:4:4,
  and the decoded planes are plainly luma and subsampled chroma. The VUI
  therefore gives no Y'CbCr matrix; the client's BT.2020 key is the only
  statement of one. ffprobe reports the stream as `gbr/bt2020/bt470m`, and a
  decoder that trusts the VUI may mis-convert or refuse. See
  [frame-layout.md](frame-layout.md) for what the picture shows.

### Client log (`vr3`)

- Klepton's media layer: `AMediaCodec_createDecoderByType("video/hevc")`,
  `AImageReader 1x1 format 0x22 usage 0x100, 20 images` (format PRIVATE,
  usage GPU_SAMPLED_IMAGE), `AMediaCodec_configure ... flags=0x0`, first
  access unit `2512 bytes, pts 0 us, flags 0x0`, first decoded frame `pts 0`,
  published to the reader as `1536x6144`. All as the static reading says.
- The client's own lines: `[SVLDecoder] Began decoder init` / `Finished
  decoder init` once each; `[SVLDecoder] Failed to acquire latest image!`
  **once**, right after the first image became available (Klepton logged
  its first `acquireLatestImage` with pts 1 at that point); then
  `[XRRenderer] Initializing swapchains...`, `Swapchains were regenerated`.
  No "Invalid frame metadata", "late metadata", "Could not acquire encoded
  data buffer" or unrecoverable-error line in the whole run: one decoder
  instance, no reset, for 4,260 frames.

## Open questions / to confirm on the wire

Settled by `vr3`: the SPS VUI is decoded (above); the four slices are the
four atlas tiles; pts is the frame id on every buffer; there is no periodic
IDR.

1. Which Y'CbCr matrix the host really encodes with (the VUI's "identity"
   cannot be it). Owned by [frame-layout.md](frame-layout.md).
2. Whether every client reset is answered by exactly one IDR: `vr3` had no
   reset. Its second IDR (frame 4) came without one, so the host does send
   IDRs for its own reasons at start-up; whether it ever does later in a
   session is unknown.
3. The pts wrap at frame 65536 on a long session.
4. Why the single `Failed to acquire latest image!` at the first frame
   (**inferred**: the reader's callback raced the first image under Klepton;
   it may not happen on a headset).
5. Whether a lost frame is always repaired by retransmission before the
   decoder sees its successor, given that each frame references only the
   previous one ([retransmit.md](retransmit.md)).

## Which codec (checked 2026-11-10)

- **static**, two client builds: 2.0.20.1812 (the one studied here) and
  2.0.25.2532 (shipped inside the SteamVR beta on the host). In both,
  `libvrlink_scene.so` contains exactly one MIME string, `video/hevc`, and one
  decoder class. Nothing in the session request, the values or the frame
  descriptor names a codec, so a stock host talking to a stock client must
  send HEVC.
- The newer APK does carry `libpyrowave-shared.so` and an AV1 parser
  (`libobuparse.so`), but only the flat Remote Play client `libmain.so` links
  them.
- A third-party tool (github.com/elliotttate/SteamFrame-Advanced-Options)
  streams AV1 and H.264 over this transport to a Steam Frame by replacing the
  host's encoder and the headset's decoder together; its documentation says
  it adds no codec negotiation. That shows the packet layer does not care
  what the elementary stream is. Not verified here.
- So the client does not assume: `client` reads the codec off each
  keyframe (`VRLinkCore/Bitstream.swift`). HEVC and H.264 are decoded (H.264
  only against an ffmpeg-made stream, never from a host). AV1 is handed to
  VideoToolbox too, with its sequence header turned into a format
  description by the parser from the ALVR visionOS client; that parser is
  tested against an ffmpeg-made keyframe, but AV1 decoding itself has not
  run anywhere yet (it needs AV1 hardware, which the development Mac lacks). Keyframe detection, which loss recovery
  depends on, uses the same test instead of looking for an HEVC parameter
  set.
- The descriptor's `fec_mode` (0x20 in every capture) is checked, and a
  different value is reported once.

## A second host with a broken picture (2026-11-10)

**Captured by probe** from a Linux host (SteamVR beta on an ARM machine with
an NVIDIA GB10, Steam running through an x86 layer; its log shows the vrlink
driver encoding with Vulkan Video, 10-bit, four slices, a 1024x4096 atlas):

- The stream is HEVC with the same declared format as the Windows host's
  (Main 10, 4:2:0, 10-bit, full range, BT.2020 primaries, gamma 2.2, identity
  matrix). It differs in three ordinary encoder choices: no loop filter
  across slices, strong intra smoothing on, and reference picture sets
  carried in the slices instead of the SPS. Keyframes are VPS, SPS, PPS, IDR
  slices; other frames are plain trailing slices.
- The picture decodes green on the headset, and equally in software: one
  frame decoded by ffmpeg has its V plane at exactly 512 everywhere (standard
  deviation 0.2) and its U plane at 124 almost everywhere, where neutral is
  512. The Windows host's planes in the same test are
  ordinary (U 561, V 488, both varying; luma mean 138).

So that host's encoder is being fed bad chroma, and no client can show its
stream correctly. Both chroma planes are flat (99 % of U lies within 123 to
125), so the stream carries no color information, only luma. **inferred**: a fault in the host's color-conversion
step on that GPU or driver. Not pursued.
