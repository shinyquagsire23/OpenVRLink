# Decode handoff: `QSVLCodecNDK` and `QSVLFrameServer`

This page covers how reassembled frames reach the decoder and how decoded
images pass to the renderer. `QSVLCodecNDK` is the Android MediaCodec backend
for the abstract `SVLCodec` interface; its vtable is at file offset 0x210bb0
(**static**):

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

`QSVLCodecNDK::Init` configures MediaCodec as follows (**static**):

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

Several constraints follow from this configuration:

- **static**: HEVC is the only supported codec. There is no codec negotiation
  and no other MIME string in `libvrlink_scene.so`.
- **static**: no `csd-0` buffer is supplied at configure time. **captured**
  (see below): parameter sets (VPS/SPS/PPS) arrive in-band and the stream uses
  Annex-B start codes.
- **static**: `vrlink` requests P010 output and sets BT.2020 full range with
  linear transfer (`COLOR_TRANSFER_LINEAR`). **captured**: the stream is 10-bit
  HEVC Main 10, and its VUI specifies full range and BT.2020 primaries, but
  gamma 2.2 transfer and an `identity` matrix (see "Color description" below).
  The MediaFormat keys and the VUI agree only on range and primaries.
- **static**: the decoded atlas can be up to 1536 wide and 7680 tall. The
  active picture dimensions come from the SPS, while the renderer reads tile
  dimensions from the frame metadata rather than the decoder.
- **static**: `vrlink` does not parse the bitstream on the client—there is no
  start-code scan, NAL type check, or keyframe detection.

## Decoder input

The input path writes one complete access unit into one MediaCodec buffer per
frame (**static**):

1. When a receive slot is initialized for a new frame
   (`SVLFECRXFrame::Initialize` +0x15f6f4), it calls
   `AcquireEncodedDataBuffer(frame_id, &capacity)`, which invokes
   `AMediaCodec_dequeueInputBuffer(codec, 20000 us)` followed by
   `AMediaCodec_getInputBuffer`. The buffer index is stored per
   `frame_id & 0xf`. On failure, the frame cannot be received (`"Could
   not acquire encoded data buffer from codec for frame: %i"`); error `-10000`
   triggers `Stop()` followed by `Init()`.
2. Data packets and FEC-recovered blocks are written **directly into that
   input buffer** at `packet_id * 1024`, with no intermediate frame buffer.
3. Once the frame is complete and next in sequence
   ([retransmit.md](retransmit.md)), `SubmitFrameForDecode(&buf, size,
   frame_id, true)` calls

   ```
   AMediaCodec_queueInputBuffer(codec, index, offset = 0, size = frame_size,
                                presentationTimeUs = frame_id, flags = 0)
   ```

   then pushes `(frame_id, submit_time)` onto a marker queue and calls
   `QSVLClient::GotNetworkFrame()`.

Key properties of the input submission:

- **One access unit per frame id, queued whole.** The buffer contents are the
  concatenated data-packet payloads truncated to `frame_size`.
- **The `pts` is the zero-extended 16-bit `frame_id`** passed in the
  microseconds field. It is a frame counter that wraps to 0 after 65535. A
  decoder backend must pass it through unmodified (`vrlink` uses it to look up
  the frame's metadata) and must not reorder output by `pts`. Klepton observed
  the same behavior externally ("the pts the guest hands the decoder is a frame
  counter").
- `flags` is always 0: neither codec-config nor keyframe flags are ever set.

## Decoder output

On the output side (**static**):

- `QSVLCodecNDK::MediaThread` (+0xfd5b4, thread name `SVLMediaThread`) loops on
  `AMediaCodec_dequeueOutputBuffer(1000 us)` and immediately calls
  `AMediaCodec_releaseOutputBuffer(index, render = true)`, pushing the decoded
  picture to the `AImageReader` surface. On a dequeue timeout or failure, it
  checks `BIsStuck()`.
- `BIsStuck()` returns true when the oldest entry in the marker queue was
  submitted more than 300,000 us ago. When triggered, it clears the marker
  queue and calls `SVLFEC::ExperiencedAnUnrecoverableError()` (see the reset
  path in [retransmit.md](retransmit.md)).
- `QSVLCodecNDK::HandleOnImageAvailable` (+0xfde30) runs on the reader's
  listener thread:
  1. Calls `QSVLClient::GotDecodedFrame()` and `PhaseEventDecodeComplete()`.
  2. Calls `AImageReader_acquireLatestImage` (the reader discards older
     undelivered images). Failure logs `"[SVLDecoder] Failed to acquire latest
     image!"`.
  3. Computes `frame_id = AImage_getTimestamp() / 1000` (the reader reports
     nanoseconds, so dividing by 1000 undoes the microsecond-to-nanosecond
     scaling of `pts`).
  4. Pops markers with id <= `frame_id`.
  5. Calls `SVLFEC::GetMetadataForFrameId(frame_id)`; if absent, logs
     `"[SVLDecoder] Invalid frame metadata for frame [ %d ], dropping."` and
     deletes the image.
  6. Calls `SVLDataLink::FrameHasBeenDecoded(metadata.present_number, now)`.
  7. Calls `QSVLFrameServer::EnqueueHardwareBuffer({AImage*, frame_id, width,
     height, decode_time})`.

## Frame selection in `QSVLFrameServer`

`QSVLFrameServer` buffers decoded images and selects which one to display
(**static**):

- Decoded images sit in a deque capped at 5 entries; enqueueing a sixth deletes
  the oldest entries (`EnqueueHardwareBuffer` +0x102274) and wakes a waiting
  renderer via `std::promise<bool>`.
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
- `ServeNextHardwareBuffer(out, age)` (+0x10270c), used for `version < 9`, pops
  from the front, deleting images until one is newer than the given age or the
  queue is empty, and optionally waits up to 5 ms for a new frame.

The served `AImage`'s `AHardwareBuffer` is wrapped as an `EGLImage` and bound
to a `GL_TEXTURE_EXTERNAL_OES` texture for the render pass described in
[frame-layout.md](frame-layout.md).

## Notes for a non-Android client

- Feed each completed frame to the decoder as one Annex-B access unit and parse
  parameter sets in-band. Parameter sets can be resent with modified non-layout
  fields (**captured** in `vr3`: the SPS of the second IDR differs from the
  first only in `vui_time_scale`), so avoid tearing down and recreating the
  decoder session unless the picture dimensions change.
- Retain `frame_id -> metadata` mappings for at least the 16 most recent
  frames so decoded images can be matched back to their metadata by `frame_id`.
- Decode order equals display order (`low-latency` and `picture-order.enable`
  are set, and frames are matched by `frame_id` without reordering).
  **captured** (`vr3`): the stream contains no B-frames and
  `sps_max_num_reorder_pics` is 0.
- Do not pass the SPS color description straight through to a platform decoder
  framework as-is (`matrix_coefficients` is `identity` on a 4:2:0 stream);
  override the Y'CbCr matrix explicitly ([frame-layout.md](frame-layout.md)).

## Captured

The observations below come from `vr3`, comparing the wire capture against the
elementary stream `vrlink` fed to its decoder (`vr3.h265`, accompanied by a
per-buffer `access_unit, pts, bytes` index; neither file is in the repo).
Everything in this section is **captured**. Bitstream headers were inspected
with ffmpeg's `trace_headers` bitstream filter.

### Wire vs. decoder input

- All 4,260 frames (ids `0..4259`) reassemble cleanly from the wire. Frames
  `0..4258` appear in the decoder dump byte for byte, in `frame_id` order,
  back to back with no extra bytes between them. `vrlink` queued every frame
  once in order, and each input buffer equals the concatenated data-packet
  payloads truncated to the descriptor's `frame_size`.
- Frame 4259 (the final frame) is truncated in the dump file, which ends after
  the first 6,155 of its 7,724 bytes at a 4,096-byte block boundary when the
  run stopped (the full frame finished arriving on the wire 1.3 ms before the
  last captured element). Up to that cutoff, the wire capture and decoder dump
  match byte for byte.
- Across the buffer index (which covers buffers `0..4219` before its own
  buffered cutoff), every row satisfies **`pts == access unit number == frame
  id`** with a byte length matching the reassembled wire frame and no gaps or
  repeats in the `pts` sequence. Klepton's media layer logged the first buffer
  as `2512 bytes, pts 0 us, flags 0x0`.
- The bitstream uses **Annex-B framing with 4-byte start codes** throughout
  (17,046 NAL units, zero 3-byte start codes).

### Access-unit structure

- Only five NAL types appear in the capture: `1` (`TRAIL_R`, 17,032), `19`
  (`IDR_W_RADL`, 8), and `32`, `33`, `34` (VPS, SPS, PPS, 2 each)—with no SEI,
  no AUD, and no B-frames or leading pictures. Every NAL has layer 0 and
  temporal id 0.
- **Every one of the 4,260 access units has four slices.** (`vr1` had one
  three-slice access unit, likely caused by datagram truncation across a third
  of that capture; none occur in `vr3`.) An IDR access unit consists of `VPS,
  SPS, PPS` followed by four IDR slices (I slices); every other access unit
  consists of four `TRAIL_R` P slices and begins with `00 00 00 01 02 01`.
- **The four slices correspond to the four atlas tiles.** With a 32 x 32 coding
  tree block (minimum coding block 16, one level up), the full picture is
  48 x 192 CTBs and each 1536 x 1536 tile spans 2,304 CTBs. Across all 4,260
  access units, the four slices have `first_slice_segment_in_pic_flag = 1`
  followed by `slice_segment_address` values `2304`, `4608`, and `6912`. HEVC
  tiles and wavefront parallel processing are disabled, there are no dependent
  slice segments, and `slice_loop_filter_across_slices_enabled_flag` is 0 in
  all 17,040 slice headers, so loop filtering does not cross slice boundaries.
  Motion vectors may still cross slice boundaries, so slices are not
  independently decodable across frames.
- Slice QP alternates by tile type: in 4,188 of 4,259 complete frames, the left
  base slice starts 27 or 28 QP steps above the left foveal slice, and the
  right eye's two slices start within 1 QP step of the corresponding left-eye
  slices. Initial slice QP ranged from `5..30` for foveal slices (median 5 to
  6) and `33..51` for base slices (median 33), with CU-level QP deltas enabled
  within each slice. Mean slice sizes in tile order are 2,927, 2,105, 2,988,
  and 2,024 bytes. Across the 4,220 indexed access units, frame size spans 302
  bytes minimum, 7,735 median, 10,061 mean, and 283,768 maximum.
- In the reference structure, `sps_max_dec_pic_buffering` is 5, with no
  long-term references and no temporal MVP. Every P slice signals its own
  short-term reference picture set of up to four previous pictures and marks
  **only the immediately preceding picture as used for reference**. Each frame
  therefore depends on the frame immediately before it, so any lost frame
  breaks decoding until the next IDR. Picture order count is an 8-bit counter
  that resets on each IDR.

### IDR frames and parameter sets

- **Only two IDRs occur in the run, at frames 0 and 4**, with none across the
  remaining 4,255 frames (39.3 s). Parameter sets are sent only with those two
  IDRs. `vr1` had five IDRs (frames 0, 5, 39, 74, and 82 out of 113) and
  Klepton once logged parameter sets "roughly every fifth frame" in another
  session, so IDR frequency depends on session conditions rather than a fixed
  interval. In `vr3`, `vrlink` never requested a reset: the `rst` field was 0
  in all 17,423 pose packets (`docs/svl-tracking-input/poses.md`). Frame 4's
  IDR was therefore sent without an `rst` bump, and a clean session has no
  periodic keyframes. Wire events preceding each IDR are covered in
  [retransmit.md](retransmit.md).
- Frames 0..3 (the first IDR plus three P frames of 2,512, 566, 536, and 620
  bytes) decode to a solid gray fill; rendered scene content begins with the
  second IDR at frame 4 (2,378 bytes, followed by 13,043 bytes on frame 5).
  **inferred**: the host restarted its encoder once client configuration
  finished arriving.
- VPS and PPS are byte-identical in both IDRs. The two SPS NALs differ only in
  `vui_time_scale`: `40` at frame 0 and **`114`** at frame 4 (with
  `vui_num_units_in_tick = 1`, signaling nominal rates of 40 and 114 fps
  compared to the measured 108.2 fps). The probe stream contains a single IDR
  with the same VPS and PPS and `vui_time_scale = 117`. **inferred**: the host
  writes its current frame-rate target into `vui_time_scale`, and decoders
  should ignore it.

### SPS and PPS

- The SPS specifies HEVC **Main 10** (profile 2), high tier, level 6.1
  (`level_idc` 183), 4:2:0 chroma, **1536 x 6144** resolution with no
  conformance window, and 10-bit luma and chroma. AMP and SAO are enabled
  (`slice_sao_luma_flag = 1` on every slice); scaling lists, PCM, and strong
  intra smoothing are disabled.
- The PPS specifies one default reference, `init_qp` 26, CU QP delta enabled,
  constrained intra prediction enabled, sign data hiding enabled, no weighted
  prediction, no tiles, no wavefront, and deblocking enabled with zero offsets.

### Color description (SPS VUI)

| Field | Value | Meaning |
|---|---|---|
| `video_full_range_flag` | 1 | full range |
| `colour_primaries` | 9 | BT.2020 |
| `transfer_characteristics` | 4 | gamma 2.2 (BT.470 System M) |
| `matrix_coefficients` | 0 | identity (GBR) |
| `aspect_ratio_idc` | 1 | square pixels |
| `chroma_loc_info_present_flag` | 0 | chroma siting not signaled |

These VUI fields are identical in both SPS NALs of `vr3` and in the probe
stream. Comparing them with `vrlink`'s MediaFormat (BT.2020, full range,
linear) and fragment shader:

- Range and primaries match the MediaFormat keys.
- For transfer characteristics, the VUI signals gamma 2.2 while the MediaFormat
  key specifies linear (`1`). Because the shader applies no transfer curve and
  writes directly to an sRGB swapchain with sRGB encoding disabled, it treats
  decoded values as display-referred—matching the VUI rather than the
  MediaFormat key. **inferred**: `COLOR_TRANSFER_LINEAR` is ignored or harmless
  on the Android devices `vrlink` targets.
- For matrix coefficients, `identity` (`0`) is defined only for 4:4:4 GBR
  streams, whereas the decoded planes are 4:2:0 luma and subsampled chroma.
  Because the VUI does not specify a valid Y'CbCr matrix, `vrlink`'s
  `COLOR_STANDARD_BT2020` MediaFormat key is the only declaration of one.
  `ffprobe` reports the stream as `gbr/bt2020/bt470m`, and a decoder that
  trusts the VUI literally may apply the wrong matrix or reject the stream. See
  [frame-layout.md](frame-layout.md) for measurements of the decoded image.

### Client log (`vr3`)

- Klepton's media layer logged `AMediaCodec_createDecoderByType("video/hevc")`,
  `AImageReader 1x1 format 0x22 usage 0x100, 20 images` (format `PRIVATE`,
  usage `GPU_SAMPLED_IMAGE`), `AMediaCodec_configure ... flags=0x0`, the first
  access unit as `2512 bytes, pts 0 us, flags 0x0`, and the first decoded frame
  (`pts 0`) published to the reader as `1536x6144`, matching the static
  analysis above.
- `vrlink` logged `[SVLDecoder] Began decoder init` and `Finished decoder init`
  once each, followed by `[SVLDecoder] Failed to acquire latest image!`
  **once** right after the first image became available (when Klepton logged
  its first `acquireLatestImage` at `pts 1`), and then `[XRRenderer]
  Initializing swapchains...` and `Swapchains were regenerated`. None of the
  error logs (`Invalid frame metadata`, `late metadata`, `Could not acquire
  encoded data buffer`, or unrecoverable error) appeared during the run; a
  single decoder instance decoded all 4,260 frames without resetting.

## Open questions / to confirm on the wire

`vr3` resolved the SPS VUI fields (above), confirmed that the four slices map
to the four atlas tiles, verified `pts == frame_id` on every buffer, and showed
that clean sessions have no periodic IDRs. Remaining open questions:

1. Which Y'CbCr matrix the host encoder uses (since the VUI's `identity` value
   is invalid for 4:2:0); see [frame-layout.md](frame-layout.md).
2. Whether every client reset triggers a single IDR from the host: `vr3` had no
   resets, and its second IDR (frame 4) arrived without an `rst` bump during
   startup; whether the host ever sends unprompted IDRs later in a session is
   unknown.
3. How the decoder handles the `pts` wrap to 0 at frame 65536 on a long
   session.
4. What causes the single `Failed to acquire latest image!` message on the
   first frame (**inferred**: the reader callback raced the first frame under
   Klepton and may not occur on a physical headset).
5. Whether lost frames are always repaired by retransmission before the decoder
   sees the next frame, given that each P frame references the immediately
   preceding frame ([retransmit.md](retransmit.md)).

## Codec support

- Across two `vrlink` builds (**static**)—2.0.20.1812 (analyzed throughout
  these docs) and 2.0.25.2532 (bundled inside the host SteamVR beta)—
  `libvrlink_scene.so` contains a single MIME string (`video/hevc`) and one
  decoder class. Nothing in the session request, values, or frame descriptor
  names a codec, so an unmodified host streaming to an unmodified `vrlink`
  client always sends HEVC.
- The newer APK includes `libpyrowave-shared.so` and an AV1 parser
  (`libobuparse.so`), but only the 2D Remote Play library (`libmain.so`) links
  against them.
- A third-party mod (`github.com/elliotttate/SteamFrame-Advanced-Options`)
  streams AV1 and H.264 over this transport to a Steam Frame by patching both
  the host encoder and headset decoder; its documentation states that it adds
  no codec negotiation. This indicates that the SVL packet framing is
  codec-agnostic, though we have not verified the mod directly.
- Rather than assuming HEVC, OpenVRLink inspects each keyframe to detect the
  codec (`VRLinkCore/Bitstream.swift`). HEVC and H.264 are supported (H.264 has
  been verified only against a synthetic `ffmpeg` stream, never a live host).
  AV1 is also wired to VideoToolbox using the sequence-header parser from the
  ALVR visionOS client to construct the format description; that parser is
  unit-tested against an `ffmpeg`-generated keyframe, though end-to-end AV1
  hardware decoding has not run on macOS hardware lacking AV1 decode support.
  Loss recovery uses the same multi-codec keyframe check instead of scanning
  specifically for HEVC parameter sets.
- OpenVRLink checks the descriptor's `fec_mode` (`0x20` in every capture) and
  logs once if a different value appears.

## Broken chroma from a Linux Vulkan Video host

A stream **captured** by the probe from a Linux host (SteamVR beta on an ARM
machine with an NVIDIA GB10, running Steam under an x86 translation layer; host
logs show the `vrlink` driver encoding 10-bit, four-slice, `1024x4096` atlases
via Vulkan Video) exhibited broken chroma:

- The bitstream is HEVC with the same VUI parameters as the Windows host
  (Main 10, 4:2:0, 10-bit, full range, BT.2020 primaries, gamma 2.2, `identity`
  matrix), differing only in standard encoder settings: loop filtering across
  slices is off, strong intra smoothing is on, and reference picture sets are
  signaled in slice headers rather than the SPS. Keyframes consist of VPS, SPS,
  PPS, and IDR slices; non-keyframes are trailing P slices.
- The picture decodes bright green both on the headset and in software: in a
  frame decoded with `ffmpeg`, the V plane sits at `512` everywhere (standard
  deviation `0.2`) and the U plane sits near `124` almost everywhere (neutral
  10-bit chroma is `512`). On the Windows host in the same test, both chroma
  planes carry normal scene variation (mean U `561`, mean V `488`, mean luma
  `138`).

Because both chroma planes are flat in the encoded bitstream (99% of U samples
fall within `123..125`), the stream contains luma only and no client can
recover color from it. **inferred**: the host's pre-encode color conversion has
a bug on that GPU or driver stack; we did not investigate further.
