# ValueTransportSystem (VTS) wire format

`ValueTransportSystem` is a small reliable "latest value wins" replication layer
that both peers run. Each side owns a table of up to 51 values indexed by a
`ValueTransportID` (the `VTE_*` enum, see [vte-id-table.md](vte-id-table.md)),
chops each value into 128-byte chunks, and keeps re-sending unacknowledged
chunks until the peer acks them. It has no socket of its own: its bytes are
piggy-backed on other SVL messages.

File offsets below refer to `libvrlink_scene.so` (Android arm64; Ghidra
address = offset + 0x100000). All multi-byte integers are little-endian.

Claims are tagged **static** (read from `libvrlink_scene.so` at the named
symbol), **captured** (decoded from streaming capture `vr3`, a complete,
untorn, timestamped 80,035-datagram Klepton `KL_TRACE_NET` trace of `vrlink`
against a SteamVR host with cleartext payloads), or **inferred** (a deduction
paired with how to test it). See §7 for capture verification details.
Timestamps are in seconds after `vrlink`'s first datagram.

## 1. Carriers

| direction | carrier | where in the carrier | budget | evidence |
|---|---|---|---|---|
| client → host | the pose packet, dataset class 3 type `0x01` (`QSVLClient::SendPoses` +0xf4d34 writes `0x0103` into the first two header bytes) | appended after the 0x168-byte pose block, i.e. at dataset payload offset 0x168; dataset length field = `0x168 + vts_len` | 372 bytes (`TickUpdate(buf, 0x174)` at +0xf5154) | static + captured (17,446 pose datasets, payload lengths 360..731 — so at most 371 VTS bytes — and the VTS parse consumes every byte after 0x168; only the first 408 pose datasets, up to 0.926 s, carry VTS bytes) |
| host → client | dataset class 3 type `0x0d` on the unreliable stream | the whole dataset payload (`payload_len` bytes at dataset +8) is handed to `RXMessage` | dataset size | static: `SVLRoot::RXUnreliableStream` +0x164ae0, `case 0xd`; captured (6 datasets, 12..216 bytes, zero bytes left over, all in the first 42 ms) |
| host → client | the video frame "bookend" (dataset class 5 type 2) trailer, see docs/svl-video/frame-descriptor.md | after the `TransportValue_t[]` and timing-event arrays; length is the `u8` at trailer +0x0f | 255 bytes per bookend | static: `QSVLClient::ReceivedBookend` +0xf6cf8; captured (8,632 bookends, all trailer version 3; the VTS section is non-empty in 30 of them and never longer than 252 bytes = 63 acks; parses exactly) |

The dataset header itself (type byte, length, sequence) belongs to the
transport layer (docs/svl-transport/); VTS relies only on `dataset[1]` holding
the message type, `u16 dataset[4..6]` holding the payload length, and the
payload starting at `dataset + 8` (**static**, same function).

The two directions use different carriers (**captured**): `vrlink` never sends
a type-0x0d dataset, and the host never sends VTS inside a type-0x01 dataset.
The host's two carriers do not overlap in time: it sends type-0x0d datasets
until it begins preparing video (last seen at 0.042 s), switches to bookends
once video flows (first seen at 0.926 s), and sends **no VTS carrier in
between** (see §7.4). The packet decoded in Klepton's notes (`kind=0x0d03
payload_len=168`, elements id 2/6/0x19/0x1a/0x1b/0x1f/0x26/0x2e) is a
host→client type-0x0d dataset; `vr3` contains the same startup burst.

## 2. Elements

A VTS byte string is a concatenation of elements with no element count and no
terminator; the parser advances until fewer than 4 bytes remain.

### 2.1 Data chunk (8-byte header + up to 128 payload bytes)

| off | size | field | notes |
|---|---|---|---|
| 0 | u8 | `0x80 \| version` | bit 7 set = data chunk. `version` is 7 bits. |
| 1 | u8 | `id` | `ValueTransportID`, 1..50 |
| 2 | u16 | `chunk_index` | chunk n covers value bytes `[n*128, n*128+128)` |
| 4 | u32 | `total_size` | size of the whole value in bytes, repeated in every chunk |
| 8 | ≤128 | payload | `min(128, total_size - chunk_index*128)` bytes |

Chunk serialization is in `ValueTransportSystem::TickUpdate` (+0x169aac, tail
loop) and parsing is in `ValueTransportSystem::RXMessage` (+0x16a618)
(**static**).

This framing explains what Klepton's notes read as "id/len/value triples with
ids like 0x0281": `81 02` is version 1, id 2, and "len" was `total_size` on a
single-chunk value.

### 2.2 Ack (4 bytes)

| off | size | field |
|---|---|---|
| 0 | u8 | `version` (bit 7 clear) |
| 1 | u8 | `id` |
| 2 | u16 | `chunk_index` |

`VTEAckPacket` is a 4-byte struct (per the vector element size in the
constructor at +0x168bb8, **static**), written first in `TickUpdate`, queued in
`RXMessage` (the branch with bit 7 clear), and applied in `TickUpdate`.

### 2.3 Limits and rejects (all **static**, `RXMessage` / `InternalUpdateValue` +0x169584)

- On send, `id` must be `< 0x33` (51); ids `>= 0x33` are rejected locally. On
  receive, an id byte of 0 or ≥ 0x80 logs `Unknown VTE: %d [%d/%d/%d]`
  (arguments: version, offset, buffer length, id) and parsing continues.
- `total_size ≤ 0x800000` (8 MiB) and `total_size > chunk_index*128`;
  otherwise parsing of the *entire buffer stops* without logging. A zero-length
  value therefore cannot be transported, and the sender never emits one (a
  value with zero chunks is already marked complete).
- A data header that does not fit in the remaining buffer logs `Error: Payload
  VTE is too small.` and stops.

## 3. Receiver algorithm

Per id the receiver holds `complete[id]` (last fully received value) and
`inprogress[id]`. Each holder has `data`, `chunk_received[]`, `remaining`,
`version`.

```python
def rx_message(buf):
    off = 0
    while off < len(buf) and off + 4 <= len(buf):
        b0, vid = buf[off], buf[off + 1]
        version = b0 & 0x7F
        if not (b0 & 0x80):                       # ack from peer
            rx_acks.push(buf[off:off + 4]); off += 4; continue
        if off + 8 > len(buf): break              # "Payload VTE is too small"
        chunk, total = u16(buf, off + 2), u32(buf, off + 4)
        if total > 0x800000 or total <= chunk * 128: break
        tx_acks.push((version, vid, chunk))       # every data chunk is acked, duplicates too
        size = min(128, total - chunk * 128)

        cur, done = inprogress[vid], complete[vid]
        if cur is not None:
            start_new = cur.version != version
        elif done is None:
            start_new = True
        else:
            # duplicate of the completed value: ignore, EXCEPT ids 0..3 which are re-accepted
            start_new = done.version != version or vid < 4
            if not start_new: off += 8 + size; continue
        if start_new:
            cur = inprogress[vid] = Holder(bytearray(total), nchunks=(total + 127) // 128, version=version)
        if chunk < cur.nchunks and not cur.chunk_received[chunk]:
            cur.data[chunk * 128: chunk * 128 + size] = buf[off + 8: off + 8 + size]
            cur.remaining -= 1
            if cur.remaining == 0:
                complete[vid], inprogress[vid] = cur, None
                changed_ids.push(vid)             # watch callbacks fire on the next tick
            else:
                cur.chunk_received[chunk] = True
        off += 8 + size
```

This logic comes from `ValueTransportSystem::RXMessage` (+0x16a618, **static**).
The `vid < 4` exception is read directly from the comparison on the "completed
value, same version" branch; why ids 0..3 bypass deduplication is **inferred**.
Checking whether the host ever re-sends an already-acked chunk of id 2 would
clarify its purpose.

The ack queue and the changed-id queue are 1024-entry rings; when the ack ring
is full the ack is silently dropped (the peer will re-send the chunk).

Readers use `GetRemoteValue(id, dst, max)` (+0x16a2bc: copies
`min(max, size)` bytes, returns the count or -1 if nothing was received),
`GetRemoteValueAsFloat` (+0x16a1c8: first 4 bytes as float if size ≥ 4), and
`GetRemoteValueVersion` (+0x16a530).

## 4. Sender algorithm

```python
def update_value(vid, data, force=False):        # UpdateValue / SendEvent
    if vid >= 0x33 or len(data) > 0x800000: return
    if not force and local[vid] is not None and local[vid].data == data: return   # unchanged: nothing sent
    h = Holder(data, nchunks=(len(data) + 127) // 128)
    h.is_event = force
    local[vid] = h          # what GetLocalValue returns
    staged[vid] = h         # map<id, holder>; a newer update replaces an unsent staged one
    dirty = True

def tick_update(max_len):                         # called once per outgoing carrier packet
    out = b""
    if invalidate_requested:                      # InvalidateAll()
        for vid in range(0x33):
            if local[vid] and not local[vid].is_event:
                update_value_forced_resend(vid)   # mode 2: re-stage even though unchanged
        for h in inprogress + complete: h.version = -1   # anything the peer now sends is "new"
        log("All VTEs Invalidated.")
    # 1. acks owed to the peer, 4 bytes each, while they fit
    while tx_acks and len(out) + 4 <= max_len: out += tx_acks.pop()
    # 2. fire watch callbacks (id, from_remote=True) for values completed since last tick
    # 3. apply acks received from the peer
    for (version, vid, chunk) in rx_acks.drain():
        h = active[vid]
        if h and chunk < h.nchunks and not h.acked[chunk] and h.version == version:
            mark_acked(h, chunk)                  # also maintains run lengths so the sender can skip acked runs
            h.remaining -= 1
            if h.remaining == 0:
                fire_watch(vid, from_remote=False)    # "delivered" notification
                h.fully_acked = True
    # 4. promote staged values whose slot is free
    for vid, h in staged.items():
        cur = active[vid]
        if cur is None:            h.version = 1
        elif cur.fully_acked:      h.version = (cur.version + 1) & 0x7F
        else: continue             # previous value still in flight; staged one waits
        active[vid] = h; del staged[vid]
    # 5. round-robin over ids 0..50 from a persistent cursor: emit every un-acked chunk
    for (vid, chunk) in round_robin_unacked():
        size = min(128, h.total - chunk * 128)
        if len(out) + 8 + size > max_len: break
        out += bytes([0x80 | h.version, vid]) + p16(chunk) + p32(h.total) + h.data[chunk*128:][:size]
    return out
```

These routines correspond to `InternalUpdateValue` (+0x169584; mode 0 =
update-if-changed, 1 = event/forced, 2 = invalidate re-send), `UpdateValue`
(+0x169574, a tail call where the `bool` argument selects mode 0 or 1),
`SendEvent(id)` (+0x169928, sends 4 zero bytes with mode 1),
`SendEvent(id, data, len)` (+0x16997c, mode 1), `TickUpdate` (+0x169aac),
`InvalidateAll` (+0x16ab14, sets a flag consumed on the next tick), and
`AdvanceMessageSend` (+0x16a1a4, moves the round-robin cursor to the next id)
(**static**).

Key behaviors a compatible implementation must preserve:

- **Retransmission is tick-driven rather than timer-driven.** Every unacked
  chunk of every active value is re-sent in every carrier packet that has room
  until its ack arrives, with no backoff.
- **Versions** start at 1 for the first value of an id and increment modulo 128
  each time a new value replaces a fully acked value. A receiver must treat
  "same version as the completed value" as a duplicate (ack it without
  re-delivering).
- **Events use the same chunk mechanism.** `SendEvent` is a forced update:
  sending identical bytes twice produces two versions and two deliveries.
  Events are skipped by `InvalidateAll`, whereas plain values are re-staged.
- **Acks carry the version**; an ack for an older version is ignored.
- Aside from acks, nothing is transmitted until the first local update sets
  `dirty`.

## 5. Watches

`AddWatch(id, std::function<void(ValueTransportID, bool)>, owner)` +0x1691c0
registers a callback. The `bool` is `true` when a new remote value for `id` has
been completely received, and `false` when the peer has acked all chunks of our
local value. Every `vrlink` handler examined ignores the `false` case
(**static**: the lambdas listed in the id table check the flag first).

## 6. Session restart detection

`vrlink` publishes a random non-zero 64-bit instance id in VTE 1 at init and
watches the host's 8-byte VTE 2. When VTE 2 changes, `vrlink` calls
`InvalidateAll()`, which re-sends every non-event local value and resets the
received versions of all remote ids (**static**: `QSVLClient::Init` +0xf5e84,
`QSVLClient::OnRenderComplete` +0xf671c). Treating VTE 2 as the host's instance
id is **inferred** from this symmetry, and `vr3` confirms the reverse direction
(**captured**): 19 ms after the host first acked `vrlink`'s VTE 1, it re-sent
all of its own plain values under version 2—ids 0x02, 0x19, 0x1a, 0x1b, 0x1f,
0x26, and 0x2e—while omitting the three values it had sent as events (0x27,
0x29, and 0x2b). That matches `InvalidateAll` running on the host in response
to a new client instance id. Observing VTE 2 change across a mid-session
SteamVR restart remains untested.

## 7. Capture verification

Capture `vr3` was decoded with the sender and receiver algorithms above
(implemented in `ovrlink/vts.py`; all findings in this section are
**captured**). The capture contains the session's entire value exchange: 59
distinct `(id, version)` values—32 from `vrlink` and 27 from the host—with
every chunk acknowledged.

### 7.1 Framing

- Every client pose dataset parses as `0x168` pose bytes followed by an exact
  number of VTS elements with zero trailing bytes (all 17,446 datasets).
- Every host type-0x0d dataset (6) and every bookend VTS section (8,632)
  parses with zero trailing bytes.
- For example, the host's first datagram (type 0x0d, 156 bytes, 3.8 ms after
  `vrlink`'s first datagram) carries seven 4-byte acks—`01 01 00 00`,
  `01 04 00 00`, `01 05 00 00` … `01 05 03 00`, `01 08 00 00` (version 1; ids
  1, 4, the four chaperone chunks, and 8)—followed by seven data chunks for ids
  0x02, 0x19, 0x1a, 0x1b, 0x1f, 0x26, and 0x2e.
- Example host data chunk: `82 02 00 00 08 00 00 00` + 8 bytes (version 2, id
  2, chunk 0, total 8). Example client data chunk: `81 20 00 00 14 00 00 00` +
  20 bytes.
- Multi-chunk values: `0x0d`, `0x0e`, and `0x0f` (1161 bytes each) travel as
  chunks 0..9 with `total_size = 1161` in each chunk; the 507-byte chaperone
  JSON travels as chunks 0..3. Because the pose packet's 372-byte VTS budget
  fits two full chunks, a 1161-byte value spans five pose packets (~10 ms).
- Ack-only messages occur on the wire: the host's sixth type-0x0d dataset
  (28 bytes) consists of seven acks and no data chunks.

### 7.2 Versions and `InvalidateAll`

- Both sides start each id at version 1.
- `vrlink` received host id 2 at 3.8 ms, logged `All VTEs Invalidated.` once,
  and re-sent every non-event value as version 2 (ids 0x01, 0x04, 0x05, 0x08,
  0x0d–0x12, 0x15, 0x18, 0x20, 0x22). Event value 0x13 (focus) was *not*
  re-sent, matching the static analysis. Version 2 of each id waited until all
  chunks of version 1 were acked (the "staged value waits" rule in §4), so the
  re-send ran from 32 ms to 71 ms, immediately after the version-1 pass
  finished at 30 ms.
- The host ran the same sequence in reverse (§6): version 1 at 3.8 ms,
  version 2 at 23 ms.
- Chaperone (0x05) reached version 3 at 71 ms, illustrating both causes of a
  version bump. Version 2 differs from version 1 in a single byte—the JSON's
  `time` string, one second later—because the host's prop-refresh request
  (0x2b at 3.9 ms) caused `vrlink` to regenerate it. Version 3 is
  byte-identical to version 2, produced by `InvalidateAll`'s forced re-send.
  (Assigning version 2 to prop refresh and version 3 to invalidation is
  **inferred** from the order of `vrlink`'s log lines: prop refresh first,
  invalidation second.)
- Events re-sent with identical bytes still increment the version: the host's
  0x29 went out as version 1 at 3.9 ms and again as version 2 at 1.051 s with
  the same four bytes. (`vr1` showed the same behavior for `vrlink`'s 0x0c; in
  `vr3` the host requested a refresh rate only once, so 0x0c stayed at version
  1.)
- The host sent id 2 version 1 in two consecutive datagrams 0.16 ms apart,
  before any ack could have arrived. `vrlink` acked both and logged a single
  invalidation, showing that re-accepting duplicate chunks for ids 0..3 (§3)
  does not re-trigger `OnRenderComplete`'s invalidation check when the payload
  bytes are unchanged.

### 7.3 Out-of-table host ids

The host sent single-chunk values with ids **0x35** (4 bytes, `00 00 00 00`),
**0x64**, **0x65**, **0x67**, and **0x72** (1 byte each, `00`) inside bookend
trailers, and `vrlink` acked each of them (`01 35 00 00`, …). The host's enum
is therefore larger than this `vrlink` build's 51 slots (the bookend's protocol
version field was 14, whereas this `vrlink` binary was built for version 9; see
docs/svl-video/). A client must ack unknown ids or the host will retransmit
them indefinitely. `vrlink` stores them in its 128-entry receive table and
never reads them.

### 7.4 Startup ack gap and retransmission storm

Capture timestamps explain why `vr1` showed a 4-byte `0x0c` value repeated in
373 consecutive pose packets: rather than draining a slow ack queue, the host
had **no outgoing VTS carrier** for nearly 0.9 s while starting its video
stream.

Measured ack latency from the first transmission of a chunk to the arrival of
its first ack:

| who acks | when | carrier | latency |
|---|---|---|---|
| host | first 42 ms | type-0x0d datasets | 0.8–18.7 ms, typically 3–4 ms: the host answers a burst of client chunks with one dataset |
| client | always | the next pose packet | 0.6–2.3 ms (one pose tick) |
| host | 0.042 s – 0.926 s | none | **0.85–0.88 s** |
| host | after 0.926 s | bookend trailers, at most 63 acks each | about a thousand queued acks, drained over the first 18 bookends, by 1.051 s |

Specifically, the host sent its last type-0x0d dataset at 0.042 s (acking
`vrlink`'s 0x0c reply to the rate request) and then sent no VTS bytes until the
first bookend of frame 0, 0.884 s later. At 0.042 s `vrlink` was partway
through its version-2 re-send. Everything `vrlink` transmitted after that
point—chunks 3..9 of 0x0d, all of 0x0e and 0x0f, 0x10, 0x11, 0x12, 0x15, 0x18,
0x20, 0x22, 0x23, and the four chunks of 0x05 version 3 (39 chunks, 4.0 kB)—remained
unacked, so `vrlink` cycled through those chunks on every pose tick, filling
each pose packet up to its 372-byte VTS limit for **27 complete passes** (one
pass every 31 ms, or 1,062 chunk transmissions for 39 unique chunks). The first
bookend acked the entire set, stopping retransmissions on the very next pose
packet. Because the host had queued an ack for every duplicate chunk received,
roughly a thousand extra acks drained across the next 17 bookends and were
ignored.

During that first second, `vrlink`'s uplink carried 338 kB versus 233 kB/s
during steady-state streaming—about 100 kB of duplicate chunks, which is
negligible on a LAN.

The host exhibits the same unthrottled behavior on a smaller scale: the nine
values it first sent in bookends at 1.051 s (0x06, 0x17, 0x1c, 0x29, 0x35,
0x64, 0x65, 0x67, 0x72) were repeated in each of the next 12–13 bookends over
18 ms, even though `vrlink`'s acks went out within 1.6 ms. Neither peer
throttles retransmissions; an unacked chunk is emitted into every carrier
packet with available space.

A new client implementation should not expect acks between sending 0x0c and
receiving frame 0. Sending each chunk once and pacing retransmissions after a
short delay avoids `vrlink`'s redundant burst (though `vrlink`'s behavior is
valid under the protocol), and the receiver should tolerate duplicate acks as
well as acks for already-completed versions. Whether the ack gap occurs because
the host is busy initializing video or because the host only sends type-0x0d
datasets during initial handshake is unresolved; on an idle warm host, a
probe's values were all acked "within 2 s" ([startup-exchange.md](startup-exchange.md)),
which is consistent with either explanation.

## Open questions

Capture `vr3` resolved several earlier questions (see §7): the carrier and
offset of client→host VTS data, sequential use of the two host→client carriers,
initial version numbering (1 on both sides), host-side `InvalidateAll`
behavior, the cause of the 0.85 s startup ack delay, and unthrottled host
retransmissions.

1. Does the host apply the same `id < 4` duplicate exception?
2. After version 127, the 7-bit version wraps to 0 (`0x80 | 0` is a valid data
   header); does the host handle version 0 cleanly? Confirming this requires a
   long session with a frequently updated id such as 0x23.
3. What causes the host to stop sending type-0x0d datasets (§7.4), and does the
   host apply a client value arriving during the gap immediately or only once
   bookends start and drain the acks? A probe can test this by publishing an
   updated 0x20 during the gap and checking which refresh rate the host
   requests.
4. Does the host ever send a type-0x0d dataset after video has started (in
   `vr3`, none appeared over 39 s)?
