# Hand tracking packet and skeleton compression

Hand tracking skeletons are sent from client to host in unreliable message type
`0x17`, with one message per tracked hand queued right after each pose packet
while the link is active.

## Sending

Implemented in `QSVLClientXR::HandleHandTracking` (0xfb794, **static**):

- Runs only when `XRQContext+0x118c` is non-zero (**inferred**: hand trackers
  were created; log strings `[SVLClientXR] Creating hand trackers` and
  `[XRQ] Hand tracking supported: %s`).
- Calls `QSVLInput::GetHandTracking(SVLHandTrackingPacket_t[2])` (vtable slot
  0x28 → `QSVLXRInput::GetHandTracking` 0x108770) on a zeroed `2 × 0x13b`
  buffer.
- For each hand whose `flags` bit1 is set, writes the 8-byte header
  `03 17 00 00 33 01 00 00` and calls `SubmitMessage(msg, false, false)`.

## `SVLHandTrackingPacket_t` (0x13b = 315 bytes including header)

Populated by `QSVLXRInput::GetHandTracking` (0x108770, **static**). The struct
is byte-packed (floats sit at odd byte offsets):

| off | size | type | field |
|---|---|---|---|
| 0x000 | 8 | header | class 3, type 0x17, length 0x133 |
| 0x008 | 248 | bytes | compressed skeleton, 31 bones × 8 bytes (below) |
| 0x100 | 1 | u8 | flags: bit0 = hand (0 left, 1 right), bit1 = hand is tracked |
| 0x101 | 2 | u16 | gesture bits (low 6 bits; upper bits preserved as zero), table below |
| 0x103 | 12 | f32×3 | position A |
| 0x10f | 16 | f32×4 | orientation A |
| 0x11f | 12 | f32×3 | position B |
| 0x12b | 16 | f32×4 | orientation B, written as (w, −x, −y, −z) of the per-hand offset quaternion at `QSVLXRInput+0x288 + hand*0x1c` |

Gesture bits (**static**: `SkeletalGestures::Compute` 0x130be0; see "Hand
gestures" in [controllers.md](controllers.md)) are read from the per-hand
`SkeletalGestureInfo` at `QSVLXRInput+0x380 + hand*0x18`:

| bit | source byte | meaning |
|---|---|---|
| 0 | `info+0x08` | index pinch (also click bit 0) |
| 1 | `info+0x11` | middle pinch |
| 2 | `info+0x12` | ring pinch |
| 3 | `info+0x13` | little pinch |
| 4 | `info+0x00` | menu gesture (left hand only) |
| 5 | `info+0x14` | index finger pointing, other three curled |

Poses A and B (**static**, matched term-by-term against the inlined quaternion
algebra) are computed from `W` (the wrist joint pose, joint 1 of the same joint
set used to build the skeleton), `O` (the per-hand offset pose at
`QSVLXRInput+0x288 + hand*0x1c`; values in [controllers.md](controllers.md)),
`aim` (`XrHandTrackingAimStateFB.aimPose` at `QSVLXRInput+0x210 + hand*0x48`),
and `G = W ∘ O` (orientation `W.q · O.q`, position `W.p + W.q·O.p`):

- **Pose A** = `inverse(G) ∘ aim`: orientation `conj(G.q) · aim.q` written as
  **(w, x, y, z)**; position `conj(G.q) · (aim.p − G.p)`.
- **Pose B** = `inverse(O)`: orientation `conj(O.q)` written as (w, x, y, z);
  position `conj(O.q) · (−O.p)`.

A hand is considered tracked when `XrHandJointLocationsEXT.isActive` is true or
became false less than 2 s ago (**static**, using the same 2 s grace timer as
`BIsHandTrackingActive` at 0x1081f8). Joints are located at **now + 30 ms**
(`XRQLocateHandJoints(ctx, hand, now + 30000000 ns, …)`).

## Skeleton source

`ConvertJointsToSkeleton(array<XrHandJointLocationEXT,26>, XRQHand,
XrPosef const&, array<vr::VRBoneTransform_t,31>&)` (0x130490, **static**),
together with its helpers `FlexionJointsToBoneTransforms` (0x12fef4) and
`AuxJointsToBoneTransform` (0x13007c), converts the 26 OpenXR hand joints into
31 OpenVR bones. The `XrPosef` argument is unused (the caller passes a static at
`+0x21f140`). `XRQHand` is 0 = left, 1 = right. Each output
`vr::VRBoneTransform_t` (32 bytes) stores position `(x, y, z, w=1)` followed by
orientation `(w, x, y, z)`.

Bones 2..25 match both OpenXR joint indices and OpenVR bone order: 0 root,
1 wrist, 2..5 thumb (metacarpal, proximal, distal, tip), 6..10 index
(metacarpal..tip), 11..15 middle, 16..20 ring, 21..25 little, and 26..30 aux
(thumb, index, middle, ring, little). All bones are **parent-relative**; the
absolute wrist pose travels separately as the hand's controller pose rather than
inside the skeleton. Quaternions below are `(w, x, y, z)`; `J[i]` is OpenXR
joint *i* (orientation `q`, position `p`), `W = J[1]`, and `s = 0.70710678`.

The function fails (returns 0, leaving bones 2+ unchanged) unless every joint
in 2..25 has both valid location bits set; the wrist's flags are not checked
here.

**Bones 0 and 1: constants** (`.rodata` +0xaf360 left, +0xaf3a0 right):

| bone | hand | position (x, y, z, 1) | orientation (w, x, y, z) |
|---|---|---|---|
| 0 root | both | 0, 0, 0 | 1, 0, 0, 0 |
| 1 wrist | left | −0.034038, 0.036503, 0.164722 | −0.055147, −0.078608, −0.920279, 0.379296 |
| 1 wrist | right | +0.034038, 0.036503, 0.164722 | −0.055147, −0.078608, 0.920279, −0.379296 |

**Bones 2, 6, 11, 16, 21 (metacarpals), relative to the wrist.** With
`R = conj(W.q) · J[i].q` and `d = conj(W.q) · (J[i].p − W.p)` (the joint in
the OpenXR wrist's own frame):

```
left :  bone.q = C1 · R · C2,  C1 = (0, s,  s, 0),  C2 = ( 0, −s, 0, s)
        bone.p = ( d.y,  d.x, −d.z)          (= C1 rotating d)
right:  bone.q = C1 · R · C2,  C1 = (0, s, −s, 0),  C2 = (−s,  0, s, 0)
        bone.p = (−d.y, −d.x, −d.z)          (= C1 rotating d)
```

(The binary computes this by mirroring `R` and multiplying once by
`(±0.5, ±0.5, ±0.5, ±0.5)`; the two-sided form above was verified numerically
against a transcription of the decompiled arithmetic for both hands.)

**Bones 3..5, 7..10, 12..15, 17..20, 22..25 (remaining finger bones),
relative to the previous joint.** With `R = conj(J[i−1].q) · J[i].q` and
`len = |J[i].p − J[i−1].p|`:

```
left :  bone.q = (R.w, −R.z, −R.y, −R.x)    bone.p = (+len, 0, 0)
right:  bone.q = (R.w,  R.z,  R.y, −R.x)    bone.p = (−len, 0, 0)
```

Only the scalar distance between consecutive joints is used; the bone always
lies along its parent's x axis.

**Bones 26..30 (aux), relative to the wrist joint**, computed from the distal
joints `J[4]`, `J[9]`, `J[14]`, `J[19]`, `J[24]` using the same formulas as the
finger bones with `R = conj(W.q) · J[k].q` and `len = |J[k].p − W.p|`. (An aux
bone's position therefore encodes distance along the x axis rather than the
joint's 3D offset.)

## Compression: 8 bytes per bone

Implemented in `SVLCompressSkeleton` (0x16cb44, **static**) and
`SVLDecompressSkeleton` (0x16cdfc, **static**), encoding two little-endian `u32`
words per bone.

Word 0 — position, 10 bits per axis, range ±0.175 m:

```
bits  0..9   x
bits 10..19  y
bits 20..29  z
bits 30..31  0
```

Word 1 — orientation, "smallest three" with 10 bits per stored component:

```
bits 30..31  L = index of the largest-magnitude component in (w, x, y, z) = (0,1,2,3)
bits 20..29  first  remaining component (lowest index)
bits 10..19  second remaining component
bits  0..9   third  remaining component (highest index)
each 10-bit field: bit 9 = "sign differs from the largest component's sign",
                   bits 0..8 = round(|c| / 0.70710677 * 511)
```

```python
import math, struct

INV_SQRT2 = 0.70710677

def q10(p):                      # position axis -> 10 bits
    v = int(((p + 0.175) * 5.714286 + 0.0019550342) * 511.5)   # C float->int truncation
    return 0 if v < 0 else min(v, 0x3ff)

def compress_bone(pos, quat):    # pos = (x, y, z); quat = (w, x, y, z)
    w0 = q10(pos[0]) | q10(pos[1]) << 10 | q10(pos[2]) << 20

    c = quat
    L = 1 if abs(c[0]) < abs(c[1]) else 0        # ties keep the lower index
    if abs(c[2]) > abs(c[L]): L = 2
    if abs(c[3]) > abs(c[L]): L = 3
    w1 = L
    for i in range(4):
        if i == L:
            continue
        sign = 0x200 if ((c[i] < 0.0) != (c[L] < 0.0)) else 0
        w1 = (w1 << 10) | sign | int(abs(c[i]) / INV_SQRT2 * 511.0 + 0.5)
    return struct.pack('<II', w0, w1 & 0xffffffff)

def compress_skeleton(bones):    # 31 x (pos, quat) -> 248 bytes
    return b''.join(compress_bone(p, q) for p, q in bones)

def dq10(v):                     # 10 bits -> position axis (bin center)
    return (v * 0.0019550342 - 0.0009775171) * 0.175 - 0.175

def decompress_skeleton(data):   # len(data) // 8 bones
    out = []
    for i in range(len(data) // 8):
        w0, w1 = struct.unpack_from('<II', data, i * 8)
        pos = (dq10(w0 & 0x3ff), dq10(w0 >> 10 & 0x3ff), dq10(w0 >> 20 & 0x3ff), 1.0)
        L = w1 >> 30
        c = [0.0] * 4
        s = 0.0
        bits = w1
        for idx in (3, 2, 1, 0):                 # fields are stored highest index lowest
            if idx == L:
                continue
            mag = (bits & 0x1ff) * 0.7071067811865476 / 511.0
            c[idx] = -mag if bits & 0x200 else mag
            s += c[idx] * c[idx]
            bits >>= 10
        c[L] = math.sqrt(1.0 - s)                # largest is reconstructed positive
        out.append((pos, tuple(c)))              # quat = (w, x, y, z); position.w = 1.0
    return out
```

Notes (**static**):

- The compressor always emits 31 bones (loop ends at 0xf8); the decompressor
  takes a byte length and decodes `len >> 3` bones into a zeroed 0x3e0-byte
  array.
- Because the sign bit is relative to the largest component, the decoder returns
  either `q` or `−q` (representing the same 3D rotation).
- The encoder's quantizer is `floor(u·511.5 + 1)` with `u = p/0.175 + 1` in
  `[0, 2]`, and the decoder returns `(v − 0.5)/511.5 − 1` (bin centers), giving
  a round-trip error of at most ~0.17 mm per axis. A position of `−0.175`
  encodes as 1 rather than 0.
- The decoder does not clamp `1 − s < 0` (producing `NaN` if the three stored
  magnitudes overshoot 1.0), so an encoder must supply normalized quaternions.
- `vrlink` only calls `SVLCompressSkeleton`; `SVLDecompressSkeleton` is compiled
  into the binary but its caller was not traced (**inferred**: shared code with
  the host driver).

## Capture check (`vr3`)

`vr3` contains no type-`0x17` messages among its 69,287 client→host elements
(**captured** negative; only `3/0x01`, `3/0x07`, `3/0x11`, and `4/0x0f` occur).
This matches the gating condition under "Sending": Klepton's OpenXR runtime does
not offer `XR_EXT_hand_tracking`, and `vrlink` logs
`[XRQ] Hand tracking supported: No`, followed twice during startup by
`[XRQ] Hand tracking status updated: On`,
`[SVLClientXR] Creating hand trackers`, and
`[XRQ] Could not setup hand tracking as hand tracking was not supported`.
Enabling the hand-tracking status flag alone therefore produces no `0x17`
traffic when the runtime has no hand tracker, and the host streams normally
without it (what sets that status flag was not traced). Both hands were reported
as Touch controllers in the pose packet throughout
([controllers.md](controllers.md)), with byte 0x10 of each input block equal
to 0.

Neither the `0x17` packet layout nor the skeleton codec was captured on the wire
in `vr3`; both remain **static**.

## Client results (2026-11-10)

Tested with `client` (**captured**): sending `0x17` for a synthetic flat hand
built from the formulas on this page is accepted by the host (see "Client
results" in [controllers.md](controllers.md)), confirming that the packet size
and framing are accepted. Because SteamVR Home did not draw a hand skeleton in
that macOS test, bone transforms required headset testing.

In Vision Pro runs later the same day using ARKit hand joints (reported by the
user), the rendered SteamVR hands tracked the user's hands and pinch worked in
SteamVR, confirming the bone formulas and the index-pinch button bit. Once the
eye-to-head transform included the displays' canted rotation, the rendered hands
no longer appeared rolled, though they sat roughly 1 cm away from the physical
hands.

Recomputing from `vrlink`'s **static** constants shows that the hand offset pose
`O` and constant wrist bone 1 do not cancel out: `O.p + O.q·bone1.p =
(−0.0007, 0.0140, −0.0077)` m in the left wrist joint's frame, placing the
drawn wrist 16 mm from the reported wrist joint (14 mm out the back of the
hand). These constants are likely tuned for the wrist joint convention of the
headsets `vrlink` runs on (**inferred**). `client` briefly shifted the sent
wrist pose by the opposite offset, which the user reported aligned the hands,
but the 1 cm discrepancy turned out to come from publishing canted eye frusta
(docs/svl-video/frame-layout.md). Once eye canting was corrected, the wrist
shift was removed and `client` sends the tracked wrist joint directly. Whether
the 16 mm offset is noticeable on its own remains open.

## Open questions / to confirm on the wire

- Capture a `03 17 00 00 33 01` message per hand per pose tick when hands are
  tracked, with byte 0x100 = 0x02 (left) / 0x03 (right).
- Decode a captured skeleton with the pseudocode above and check that bone
  lengths are anatomically plausible and parent-relative (confirming bone order
  and coordinate frames).
- What the host does with poses A and B and with the gesture bits.
- Whether the host requires `0x17` messages for hands that are also reported as
  controllers in the pose packet (host version ≥ 7), or treats either one as
  sufficient.
