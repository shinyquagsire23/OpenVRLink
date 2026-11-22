# Reliable stream, acks, and loss accounting

Source: `SVLDataLink::SubmitMessage` (`+0x15a4fc`), `SVLDataLink::ReceivedData`
cases 1/2 (`+0x15a9b8`), `SVLDataLink::ReportRXSeqid` (`+0x15bd1c`),
`SVLDataLink::CheckUpdateCounters` (`+0x15b15c`), `SVLDataLink::SendLastRXID`
(`+0x15c648`), and `SVLDataLink::ReportDropCount` (`+0x15bdd0`). Code analysis
below is **static**. The reliable stream (§1 and §2) **never appears in capture
`vr3`** — none of the 80,035 datagrams (including startup) carry class 1 or
class 2 elements, so those two sections remain unverified on the wire.
Unreliable loss accounting (§3) and per-frame latency feedback (§4) run on
every datagram and are verified against `vr3`.

## 1. Reliable channel (kind low-byte 2)

`SubmitMessage(elem, own, flush)` routes by the element's low-byte kind:
- `kind != 2` → passed straight to `XMITData` as fire-and-forget (unreliable).
- `kind == 2` → **reliable**: assigns a monotonic 16-bit seqid from `this+0x90`
  (written into element offset 2), inserts the element (optionally a `malloc`'d
  copy) into a `std::map`/red-black tree keyed by seqid at `this+0x80`
  (`"ReliableDataElement map"`), and transmits it. The node is retained for
  retransmission until acked; `this+0x88` holds the map size.

Retransmission is driven from `SVLDataLink::Tick` (`+0x15ad64`) /
`CheckUpdateCounters` (not traced in full), using the map at `this+0x80` as the
retransmit queue.

## 2. Acks (kind low-byte 1)

- When **receiving reliable data** (`ReceivedData` case 2), let
  `s = elem.seqid` and `d = s - m_LastRXReliableSeq` (`this+0x94`). If `d == 1`
  (next in order) or the force flag `this+0x96` is set, the element is
  delivered to `SVLRoot::RXReliableStream` (vtable+0x20) and an **ack** is sent
  back via `GenSimpleDataset(1, 0, s, 0)` → `SubmitMessage` (a kind-1 element
  carrying the acked seqid), advancing `m_LastRXReliableSeq`. A window check
  (`(d - 0x33) & 0xffff < 0xff9b`) tolerates limited reordering, while `d < 1`
  (duplicate/old) re-sends the ack without re-delivering the payload.
- When **receiving an ack** (`ReceivedData` case 1), `ReceivedData` searches
  the reliable map (`this+0x80`) for nodes with seqid ≤ the acked ID, `free()`s
  the matching node's buffer, and removes the node, stopping retransmission for
  delivered elements.

In summary, the sender assigns a monotonic seqid, buffers a copy, and
retransmits until a kind-1 ack for that seqid (or higher) arrives, while the
receiver delivers elements in order within a small reorder window and sends an
ack for each element.

## 3. Unreliable loss accounting (`ReportRXSeqid`)

Unreliable loss accounting is **separate** from the reliable stream and runs on
every datagram. `ReportRXSeqid(seqid, width)` (`+0x15bd1c`) has a single caller,
`RXThread`, which passes the datagram header's `seq` with `width = 0x10`
immediately after checksum validation and before inspecting any elements. No
element field (`id` or `index`) feeds it. The reconstructed logic is
(**static**):

```python
# this+0x38  last        last seq seen; -1 in a new link object
# this+0x3c  window      datagrams accounted for since the last publish
# this+0x40  window_err  of those, how many were counted missing
# this+0xbc  total_err   missing datagrams since the link object was created (atomic, never cleared)
def report_rx_seqid(seq, width=16):
    if last == -1:                       # very first datagram: just record seq
        last = seq; return
    gap = (seq - last) & ((1 << width) - 1)
    if gap == 1:
        last = (last + 1) & ((1 << width) - 1)
    else:
        if gap > 999: gap = 1000         # signed compare; clamp applies to gap
        missing = gap - 1                # at most 999 (and -1 for a duplicate seq, gap 0)
        if missing != 0:
            total_err  += missing
            window_err += missing
            check_update_counters()      # runs before `window` includes this gap
        last = seq
    window += gap

def check_update_counters():             # also called from Tick, ReportTXFailures, ReportDropCount
    if window != 0 and now_us() - last_publish > 1_000_000:
        p = "s" if root.is_server else "c"        # SVLRoot+0x18c
        root.SetValue(p + "RXerr",  total_err)                              # cumulative
        root.SetValue(p + "RXpass", 100.0 * (window - window_err) / window) # current window only
        root.SetValue(p + "RXpps",  window)
        last_publish = now_us(); window = 0; window_err = 0
```

Three details of this logic shape how the published statistics behave:

- **`RXerr` is cumulative** across the lifetime of the link object. Aside from
  the −1 produced by a duplicate `seq`, it never decreases and is not cleared
  when counters are published. By contrast, `RXpass` and `RXpps` cover only the
  most recent ≥1 s window.
- Because the clamp is applied to `gap` at 1000, a single sequence
  discontinuity adds **at most 999 errors** and adds 1000 to that window's
  `window` count.
- `RXpps` counts total sequence numbers spanned by the window (including
  missing ones) rather than datagrams actually received.

`ReportDropCount(n)` (`+0x15bdd0`) adds `n` to both error counters in the same
manner, though nothing in `vrlink` calls it.

In capture `vr3` (**captured**), `seq` advances by 1 on every datagram in both
directions (17,446 client and 62,589 host datagrams), matching the published
statistics: `vrlink` reported `cRXerr = 0` and `cRXpass = 100` throughout, with
`cRXpps = 6` in the initial window, 11,350 during the startup video burst,
3,173 in the next window, and 1,128–1,738 afterward; the host reported
`sRXerr = 0`, `sRXpass = 100`, and `sRXpps = 247` initially followed by
410–451, matching the client's 433/s transmit rate. All six metrics travel in
string→double records (`../svl-values/`), sent by the client in `3/0x07`
elements and by the host inside frame descriptors.

### 3.1 Per-session `sRXerr` step of ~1000 (**inferred**)

In probe runs (`../svl-values/startup-exchange.md`), the host's `sRXerr`
climbs by nearly 1000 on each 8 s Python probe session while `sRXpass` reads
100, whereas in capture `vr3` against `vrlink`, `sRXerr` stays 0.

The counter logic above produces that exact signature from a **single sequence
discontinuity per session**: only a gap of 2 or more adds errors, a single
large gap is clamped to +999, and because `check_update_counters()` runs
*before* the gap is added to `window`, any dip in `sRXpass` is confined to a
single 1 s publish window (or applied against the previous session's stale
window) before returning to 100. Genuine packet loss or reordering would
instead increment `sRXerr` gradually and depress `sRXpass` continuously.

Because the probe sequences packets identically to `vrlink` (`seq` = 0, 1, 2, …
from the first datagram, one per datagram, with all class 3 `id` fields set to
0), the jump occurs at the **session boundary**. The shared host-role code that
adopts a new peer (`HandleStreamIsActiveEvent` and `SetPairAddress`,
`connection-lifecycle.md` §2) does not reset `last`, so a host link object that
outlives a session retains the final `seq` of the previous client. When the
next session starts at `seq = 0`, `(0 - last) & 0xffff` wraps into a large
positive gap, clamping to 1000 and adding +999 to the never-cleared `total_err`
counter. In `vr3`, the host had just created its link object (its own initial
`seq` was 5), so `last` was still −1 and the client's first datagram
initialized it cleanly with zero errors. The probe sessions, by contrast, ran
back-to-back against an already-running SteamVR instance.

Because this comes from the client binary's copy of the shared transport code,
the host implementation could differ, but it yields four testable predictions:

1. Against a cold host (SteamVR launched by that session), `sRXerr` stays 0;
   against a warm host, `sRXerr` steps by 999 once in the first second and
   remains flat afterward.
2. During that first second, `sRXpps` reads roughly 1000 above the send rate,
   or `sRXpass` briefly reports a low (potentially negative) single-window
   sample.
3. Starting a new session at `seq = (previous session's last seq) + 1` instead
   of 0 eliminates the step completely.
4. On a warm host, the host's own `seq` on its first datagram continues from
   the previous session rather than starting near 0.

Steady-state probe traffic needs no changes. Carrying `seq + 1` across sessions
tests prediction (3) directly. For normal session teardown, `vrlink` sends the
teardown datagram (`seq = 0xffff`, one zero-length `3/0x13` element) five times
at 100 ms intervals (`connection-lifecycle.md` §6). After a packet numbered
`0xffff`, a new session starting at `seq = 0` lands at `gap == 1` with zero
error — though if the host does not clear `last` on `3/0x13`, the `0xffff`
teardown packet itself still registers one clamped gap on exit, leaving (3) as
the only way to avoid incrementing `sRXerr`. Either way, the counter is
cosmetic because `sRXpass` recovers to 100 within a second.

## 4. Per-frame latency feedback (`SendLastRXID`)

`SendLastRXID` (`+0x15c648`) drains up to four ring buffers of `(id, time)`
pairs (decode, display, and submit latency queues at
`this+0x140 / 0x158 / 0x188 / 0x1b8`, each `0x400` entries deep) and packs them
into a single element (`kind = 0x0f04, len = 0x18`, channel 4) sent via
`SubmitMessage`. In capture `vr3` (**captured**), this `0x0f04` element is
present in every client datagram (17,446 of 17,446, including the very first
datagram with all-zero IDs before any video frame arrives). It provides the
frame-latency half of the host's rate-control inputs (Klepton SL-23); its
payload format is documented in `../svl-video/` and `../svl-timing/`.

## Open questions / to confirm on the wire

Capture `vr3` confirmed that the reliable stream is unused during startup and
steady-state streaming, that `cRX*` and `sRX*` travel as string→double records,
and that zero datagrams were lost or reordered in either direction.

Remaining open questions:
- Which features, if any, use reliable classes 1/2 (candidates not exercised in
  `vr3` include controller input, message prompts, and UI-initiated session
  shutdown). Until captured, the ack format (`GenSimpleDataset(1, 0, seqid, 0)`),
  reorder window, and retransmit timing remain static-only.
- Testing prediction (3) in §3.1 with the probe (see results for the other
  predictions below).
- Whether the host's rate controller inspects cumulative `cRXerr` or only
  windowed `cRXpass`, which can be tested by publishing a growing `cRXerr`
  alongside `cRXpass = 100` while monitoring `dTargetBW`.

## Probe results: the `sRXerr` step

Across five 6 s probe sessions spaced 3 s apart starting from a cold host, the
host's reported `sRXerr` at the end of each session was 0, 999, 1998, 2997, and
3996 (**captured** by probe).

- This confirms the §3.1 analysis: the host retains its last-received datagram
  `seq` across sessions, a new session starting at `seq = 0` incurs a single
  clamped gap of 999, and the counter is never cleared while SteamVR remains
  running. The increment is cosmetic, as `sRXpass` stays at 100.
- Sending `vrlink`'s teardown datagram (`seq = 0xffff`, one empty class-3
  type-0x13 element, sent five times) at the end of sessions 3 and 4 did
  **not** prevent the +999 step in sessions 4 and 5, showing that the teardown
  packet does not reset the host's sequence tracker.
- However, the two sessions that followed a teardown datagram received their
  first complete frame at 0.03–0.04 s instead of 0.23–0.29 s, for reasons not
  yet determined.
- Starting a session at the previous session's last `seq + 1` remains untested.
