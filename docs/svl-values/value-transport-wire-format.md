# ValueTransportSystem (VTS) wire format

`ValueTransportSystem` is a small reliable "latest value wins" replication layer
that both peers run. Each side owns a table of up to 51 values indexed by a
`ValueTransportID` (the `VTE_*` enum, see [vte-id-table.md](vte-id-table.md)),
chops each value into 128-byte chunks, and keeps re-sending unacknowledged
chunks until the peer acks them. It has no socket of its own: its bytes are
piggy-backed on other SVL messages.

Binary: `libvrlink_scene.so` (Android arm64). Offsets below are file offsets
(Ghidra address = offset + 0x100000). All integers are little-endian.

Evidence classes: **static** = read from the binary at the named symbol;
**captured** = decoded from the streaming capture `vr3` (Klepton
`KL_TRACE_NET` trace of the real client against a real host: 80,035
datagrams, none torn, timestamped, complete from the session's first
datagram; payloads in the clear); **inferred** = a guess, with what would
confirm it. See §7 for exactly what the capture confirmed. Times are seconds
after the client's first datagram.

## 1. Where VTS bytes travel

| direction | carrier | where in the carrier | budget | evidence |
|---|---|---|---|---|
| client → host | the pose packet, dataset class 3 type `0x01` (`QSVLClient::SendPoses` +0xf4d34 writes `0x0103` into the first two header bytes) | appended after the 0x168-byte pose block, i.e. at dataset payload offset 0x168; dataset length field = `0x168 + vts_len` | 372 bytes (`TickUpdate(buf, 0x174)` at +0xf5154) | static + captured (17,446 pose datasets, payload lengths 360..731 — so at most 371 VTS bytes — and the VTS parse consumes every byte after 0x168; only the first 408, up to 0.926 s, carry any) |
| host → client | dataset class 3 type `0x0d` on the unreliable stream | the whole dataset payload (`payload_len` bytes at dataset +8) is handed to `RXMessage` | dataset size | static: `SVLRoot::RXUnreliableStream` +0x164ae0, `case 0xd`; captured (6 datasets, 12..216 bytes, zero bytes left over, all in the first 42 ms) |
| host → client | the video frame "bookend" (dataset class 5 type 2) trailer, see docs/svl-video/frame-descriptor.md | after the `TransportValue_t[]` and timing-event arrays; length is the `u8` at trailer +0x0f | 255 bytes per bookend | static: `QSVLClient::ReceivedBookend` +0xf6cf8; captured (8,632 bookends, all trailer version 3; the VTS section is non-empty in 30 of them and never longer than 252 bytes = 63 acks; parses exactly) |

The dataset header itself (type byte, length, sequence) belongs to the
transport (docs/svl-transport/). What this layer relies on: `dataset[1]` is the
message type, `u16 dataset[4..6]` is the payload length, payload starts at
`dataset + 8` (**static**, same function).

The two directions use different carriers (**captured**): the client never
sends a type-0x0d dataset, and the host never sends VTS inside a type-0x01
one. The host's two carriers do not overlap in time: type-0x0d datasets until
it decides to start video (the last at 0.042 s), bookends once video flows
(the first at 0.926 s), and **nothing in between** — see §7.4. The packet decoded in Klepton's notes (`kind=0x0d03 payload_len=168`,
elements id 2/6/0x19/0x1a/0x1b/0x1f/0x26/0x2e) is a host→client type-0x0d
dataset; the capture contains the same burst.

## 2. Elements

A VTS byte string is a concatenation of elements. There is no count and no
terminator; the parser walks until fewer than 4 bytes remain.

### 2.1 Data chunk (8-byte header + up to 128 payload bytes)

| off | size | field | notes |
|---|---|---|---|
| 0 | u8 | `0x80 \| version` | bit 7 set = data chunk. `version` is 7 bits. |
| 1 | u8 | `id` | `ValueTransportID`, 1..50 |
| 2 | u16 | `chunk_index` | chunk n covers value bytes `[n*128, n*128+128)` |
| 4 | u32 | `total_size` | size of the whole value in bytes, repeated in every chunk |
| 8 | ≤128 | payload | `min(128, total_size - chunk_index*128)` bytes |

**static**: writer `ValueTransportSystem::TickUpdate` +0x169aac (tail loop),
reader `ValueTransportSystem::RXMessage` +0x16a618.

This is what Klepton's notes read as "id/len/value triples with ids like
0x0281": `81 02` is version 1, id 2; the "len" was `total_size` of a
single-chunk value.

### 2.2 Ack (4 bytes)

| off | size | field |
|---|---|---|
| 0 | u8 | `version` (bit 7 clear) |
| 1 | u8 | `id` |
| 2 | u16 | `chunk_index` |

**static**: `VTEAckPacket` is a 4-byte struct (vector element size in the ctor
+0x168bb8); written first in `TickUpdate`, consumed in `RXMessage` (branch with
bit 7 clear) and applied in `TickUpdate`.

### 2.3 Limits and rejects (all **static**, `RXMessage` / `InternalUpdateValue` +0x169584)

- `id < 0x33` (51) on send; values above are refused locally. On receive, an id
  byte of 0 or ≥ 0x80 logs `Unknown VTE: %d [%d/%d/%d]` (arguments: version,
  offset, buffer length, id) but parsing continues.
- `total_size ≤ 0x800000` (8 MiB) and `total_size > chunk_index*128`, otherwise
  parsing of the *whole buffer stops* (no log). A zero-length value therefore
  cannot be transported; the sender never emits one (a value with zero chunks is
  "complete").
- A data header that does not fit logs `Error: Payload VTE is too small.` and
  stops.

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

**static**: `RXMessage` +0x16a618. The `vid < 4` exception is read directly
from the compare at the "completed value, same version" branch; why ids 0..3
are special is **inferred** (they behave as non-deduplicated). To confirm:
see whether the host ever re-sends an already-acked chunk of id 2.

The ack queue and the changed-id queue are 1024-entry rings; when the ack ring
is full the ack is silently not queued (the peer will re-send the chunk).

Readers use `GetRemoteValue(id, dst, max)` (+0x16a2bc: copies
`min(max, size)` bytes, returns the count or -1 if nothing was received),
`GetRemoteValueAsFloat` (+0x16a1c8: first 4 bytes as float if size ≥ 4) and
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

**static**: `InternalUpdateValue` +0x169584 (mode 0 = update-if-changed, 1 =
event/forced, 2 = invalidate re-send), `UpdateValue` +0x169574 (tail call, the
`bool` argument becomes the mode), `SendEvent(id)` +0x169928 (sends 4 zero
bytes, mode 1), `SendEvent(id, data, len)` +0x16997c (mode 1), `TickUpdate`
+0x169aac, `InvalidateAll` +0x16ab14 (sets a flag consumed by the next tick),
`AdvanceMessageSend` +0x16a1a4 (moves the round-robin cursor to the next id).

Consequences a compatible implementation must reproduce:

- **Retransmission is tick-driven, not timer-driven.** Every un-acked chunk of
  every active value is re-sent in every carrier packet that has room, until its
  ack arrives. There is no backoff.
- **Versions** start at 1 for the first value of an id and increment modulo 128
  each time a new value replaces a fully-acked one. A receiver must treat "same
  version as the completed value" as a duplicate (ack it, do not re-deliver).
- **Events are values.** `SendEvent` is just a forced update: sending the same
  bytes twice produces two versions and two deliveries. Events are not re-sent
  by `InvalidateAll`; plain values are.
- **Acks carry the version**; an ack for an old version is ignored.
- Nothing is sent until the first local update (`dirty`), except acks.

## 5. Watches

`AddWatch(id, std::function<void(ValueTransportID, bool)>, owner)` +0x1691c0
registers a callback. The `bool` is `true` when a new remote value for `id` has
been completely received, `false` when the peer has acked all chunks of our
local value. Every client-side handler examined ignores the `false` case
(**static**: the lambdas listed in the id table test the flag first).

## 6. Session restart detection

The client publishes a random non-zero 64-bit instance id in VTE 1 at init and
watches the host's 8-byte VTE 2. When VTE 2 changes, it calls
`InvalidateAll()`, which re-sends every non-event local value and forgets the
versions of everything received (**static**: `QSVLClient::Init` +0xf5e84,
`QSVLClient::OnRenderComplete` +0xf671c). That VTE 2 is "the host's instance
id" is **inferred** from the symmetry, and `vr3` supports it from the other
side (**captured**): 19 ms after the host first acked the client's VTE 1, it
re-sent all of its own plain values under version 2 — ids 0x02, 0x19, 0x1a,
0x1b, 0x1f, 0x26, 0x2e — and not the three it had sent as events (0x27, 0x29,
0x2b). That is exactly what `InvalidateAll` does, run by the host on seeing a
new client instance id. Still to be seen: a VTE 2 that changes when SteamVR
restarts.

## 7. What the capture confirmed

Decoded from capture `vr3` with the two algorithms above (the repository's
`ovrlink/vts.py`). All **captured**. The session's whole value exchange is in
it: 59 distinct (id, version) values, 32 from the client and 27 from the
host, every chunk of every one acked.

### 7.1 Framing

- Every client pose dataset parses as `0x168` pose bytes followed by a whole
  number of VTS elements, with nothing left over (17,446 of 17,446).
- Every host type-0x0d dataset (6) and every bookend VTS section (8,632)
  parses with nothing left over.
- Example, the host's first datagram (type 0x0d, 156 bytes, 3.8 ms after the
  client's first): seven 4-byte acks — `01 01 00 00`, `01 04 00 00`,
  `01 05 00 00` … `01 05 03 00`, `01 08 00 00` (version 1; ids 1, 4, the four
  chaperone chunks, 8) — followed by seven data chunks, ids 0x02, 0x19, 0x1a,
  0x1b, 0x1f, 0x26, 0x2e.
- Example data chunk, host: `82 02 00 00 08 00 00 00` + 8 bytes = version 2,
  id 2, chunk 0, total 8. Client: `81 20 00 00 14 00 00 00` + 20 bytes.
- Multi-chunk values: `0x0d`/`0x0e`/`0x0f` (1161 bytes) travel as chunks 0..9
  with `total_size = 1161` in each; the 507-byte chaperone JSON as chunks 0..3.
  The pose packet's 372-byte budget holds two full chunks, so a 1161-byte
  value takes five pose packets, about 10 ms.
- An ack-only message exists: the host's sixth dataset (28 bytes) is seven
  acks and nothing else.

### 7.2 Versions and `InvalidateAll`

- Both sides start each id at version 1.
- The client received host id 2 at 3.8 ms, logged `All VTEs Invalidated.`
  once, and re-sent every non-event value with version 2 (ids 0x01, 0x04,
  0x05, 0x08, 0x0d–0x12, 0x15, 0x18, 0x20, 0x22). The event-type value 0x13
  (focus) was *not* re-sent, as the static reading predicts. Version 2 of an
  id did not start until every chunk of its version 1 had been acked — the
  "staged value waits" rule of §4 — so the re-send ran from 32 ms to 71 ms,
  directly after the first pass finished at 30 ms.
- The host did the same in the other direction (§6): versions 1 at 3.8 ms,
  versions 2 at 23 ms.
- The chaperone (0x05) reached version 3 at 71 ms, and shows both causes of
  a new version. Version 2 differs from version 1 in one byte — the JSON's
  `time` string, one second later — because the host's prop-refresh request
  (0x2b, at 3.9 ms) made the client regenerate it: a real change. Version 3 is
  byte-identical to version 2: the forced re-send of `InvalidateAll`, which
  for every other id produced version 2. (Which version came from which cause
  is **inferred** from the order of the client's log lines: prop refresh
  first, invalidation second.)
- Events re-sent with identical bytes still get a new version: the host's
  0x29 went out as version 1 at 3.9 ms and again as version 2 at 1.051 s with
  the same four bytes. (`vr1` showed the same for the client's 0x0c; in `vr3`
  the host asked for a refresh rate only once, so 0x0c has a single version.)
- The host sent id 2 version 1 in two consecutive datagrams, 0.16 ms apart,
  before any ack could have reached it. The client acked both and logged one
  invalidation, so re-accepting a duplicate of ids 0..3 (§3) does not by
  itself re-trigger the watch when the bytes are unchanged.

### 7.3 Ids outside this client's table

The host sent single-chunk values with ids **0x35** (4 bytes, `00 00 00 00`),
**0x64**, **0x65**, **0x67** and **0x72** (1 byte each, `00`) inside bookend
trailers, and the client acked each of them (`01 35 00 00`, …). So the host's
enum is larger than this client build's 51 slots (the bookend's protocol
version field read 14; this client was built against 9 — docs/svl-video/), and
a client must ack ids it does not understand or the host will repeat them
forever. The real client stores them in its 128-entry receive table and never
reads them.

### 7.4 Ack latency, and the retransmission storm at startup

With timestamps the picture `vr1` only hinted at (a 4-byte `0x0c` value sent
in 373 consecutive pose packets) is clear. The host had
**no carrier for acks** for most of a second; the acks were not stuck in a slow queue.

Ack latency, measured from the first transmission of a chunk to the arrival
of its first ack:

| who acks | when | carrier | latency |
|---|---|---|---|
| host | first 42 ms | type-0x0d datasets | 0.8–18.7 ms, typically 3–4 ms: the host answers a burst of client chunks with one dataset |
| client | always | the next pose packet | 0.6–2.3 ms (one pose tick) |
| host | 0.042 s – 0.926 s | none | **0.85–0.88 s** |
| host | after 0.926 s | bookend trailers, at most 63 acks each | about a thousand queued acks, drained over the first 18 bookends, by 1.051 s |

The sequence: the host sent its last type-0x0d dataset at 0.042 s, acking
the client's 0x0c reply to the rate request, and then sent no value-transport
bytes at all until the first bookend of the first video frame, 0.884 s later.
At 0.042 s the client was in the middle of its version-2 re-send. Everything
it transmitted after that moment — chunks 3..9 of 0x0d, all of 0x0e and 0x0f,
0x10, 0x11, 0x12, 0x15, 0x18, 0x20, 0x22, 0x23 and the four chunks of 0x05
version 3: 39 chunks, 4.0 kB — stayed un-acked, so the client cycled through
all of it again and again, filling every pose packet to the 372-byte limit:
**27 complete passes** (one every 31 ms), 1,062 chunk transmissions where 39
would have done. The first bookend acked the whole set at once and the
re-sending stopped with the next pose packet. The host had queued an ack for
every copy it received; the surplus thousand arrived in the following
bookends and were ignored.

Cost: the client's uplink carried 338 kB in the first second against 233 kB
in a normal one — about 100 kB of repeats. Harmless on a LAN.

The host does the same on a small scale: the nine values it
first sent in bookends at 1.051 s (0x06, 0x17, 0x1c, 0x29, 0x35, 0x64, 0x65,
0x67, 0x72) were repeated in each of the next 12–13 bookends, for 18 ms,
although the client's acks left within 1.6 ms. So neither side throttles: an
un-acked chunk goes into every carrier that has room.

For a new client: do not expect acks between the rate reply and the first
frame; send each chunk once, then again only after a pause (the reference
client's behavior is legal but wasteful); tolerate duplicate acks and acks for
versions already complete. Whether the acks' absence is tied to the host
*starting* video, or the host simply never sends type-0x0d datasets except in
reply to a client's first values, is not settled — on a host that is already
streaming to no one, a probe's values were all acked "within 2 s"
(`startup-exchange.md`, probe results), which fits either reading.

## Open questions / to confirm on the wire

Resolved by `vr3` (see §7): carrier and offset of client→host VTS; both
host→client carriers are used, one after the other; versions start at 1 on
both sides; the host runs `InvalidateAll` too; host acks take milliseconds
when it has a carrier and 0.85 s when it has none (the old "ack backlog"
question); the host retransmits through whichever carrier it is currently
using, in every one, until acked.

Still open:

1. Whether the host applies the same `id < 4` duplicate exception.
2. Version wrap: after 127 the next version is 0. `0x80|0` is a valid data
   header; confirm the host handles it (needs a long session with a frequently
   changing id, e.g. 0x23).
3. What exactly stops the host's type-0x0d datasets (§7.4, last paragraph),
   and whether a value the client publishes mid-gap is *applied* by the host
   on arrival or only when it gets round to acking it. Probe: publish a
   changed 0x20 during the gap and see which rate the host requests.
4. Whether the host ever sends a type-0x0d dataset once video is running (in
   `vr3`: never, in 39 s).
