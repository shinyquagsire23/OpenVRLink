# Reliable stream, acks, and loss accounting

Source: `SVLDataLink::SubmitMessage` (`+0x15a4fc`), `SVLDataLink::ReceivedData`
cases 1/2 (`+0x15a9b8`), `SVLDataLink::ReportRXSeqid` (`+0x15bd1c`),
`SVLDataLink::CheckUpdateCounters` (`+0x15b15c`), `SVLDataLink::SendLastRXID`
(`+0x15c648`), `SVLDataLink::ReportDropCount` (`+0x15bdd0`). All **static**.
The reliable stream (§1, §2) **does not occur in capture `vr3` at all**: no
class 1 or class 2 element in 80,035 datagrams, startup included, so treat
those two sections as unverified. The loss accounting (§3) and the frame
report (§4) run on every datagram and are checked against `vr3`.

## 1. Reliable channel (kind low-byte 2)

`SubmitMessage(elem, own, flush)` routes by the element's low-byte kind:
- `kind != 2` → straight to `XMITData` — fire-and-forget (unreliable).
- `kind == 2` → **reliable**: assign a monotonic 16-bit seqid from `this+0x90`
  (written into element offset 2), insert the element (optionally a malloc'd
  copy) into a `std::map`/red-black tree keyed by seqid at `this+0x80`
  ("ReliableDataElement map"), then send. The node is retained for
  retransmission until acked. `this+0x88` is the map size.

Retransmission itself is driven from `SVLDataLink::Tick` (`+0x15ad64`) /
`CheckUpdateCounters` (not fully traced); the map is the retransmit queue.

## 2. Acks (kind low-byte 1)

- **Receiving reliable data** (`ReceivedData` case 2): let `s = elem.seqid`,
  `d = s - m_LastRXReliableSeq` (`this+0x94`). If `d == 1` (next in order) or
  the force flag `this+0x96` is set, the element is delivered to
  `SVLRoot::RXReliableStream` (vtable+0x20) and an **ack** is sent back:
  `GenSimpleDataset(1, 0, s, 0)` → `SubmitMessage` (a kind‑1 element carrying
  the acked seqid). `m_LastRXReliableSeq` is advanced. A window test
  (`(d - 0x33) & 0xffff < 0xff9b`) tolerates limited reordering; `d < 1`
  (duplicate/old) re-acks without re-delivering.
- **Receiving an ack** (`ReceivedData` case 1): the reliable map (`this+0x80`)
  is searched for nodes with seqid ≤ the acked id; the matching node's buffer is
  `free()`d and the node removed. This clears retransmission for delivered
  elements.

So the reliable protocol is: sender assigns seqid, keeps a copy, retransmits
until a kind‑1 ack for that seqid (or higher) arrives; receiver delivers
in-order with a small reorder window and acks each.

## 3. Unreliable loss accounting (ReportRXSeqid)

This is **separate** from the reliable stream and runs on every datagram.
`ReportRXSeqid(seqid, width)` (`+0x15bd1c`) has exactly one caller, `RXThread`,
which passes the datagram header's `seq` with `width = 0x10` as soon as the
checksum has passed and before any element is looked at. No element field
(`id`, `index`) feeds it. **Static**:

```python
# this+0x38  last      last seq seen; -1 in a new link object
# this+0x3c  window    datagrams accounted for since the last publish
# this+0x40  window_err  of those, how many were counted missing
# this+0xbc  total_err   missing datagrams since the link object was created (atomic, never cleared)
def report_rx_seqid(seq, width=16):
    if last == -1:                       # very first datagram: just remember it
        last = seq; return
    gap = (seq - last) & ((1 << width) - 1)
    if gap == 1:
        last = (last + 1) & ((1 << width) - 1)
    else:
        if gap > 999: gap = 1000         # signed compare; the clamp is on the gap
        missing = gap - 1                # so at most 999 (and -1 for a repeated seq, gap 0)
        if missing != 0:
            total_err  += missing
            window_err += missing
            check_update_counters()      # before `window` gets this gap
        last = seq
    window += gap

def check_update_counters():             # also called from Tick, ReportTXFailures, ReportDropCount
    if window != 0 and now_us() - last_publish > 1_000_000:
        p = "s" if root.is_server else "c"        # SVLRoot+0x18c
        root.SetValue(p + "RXerr",  total_err)                              # cumulative
        root.SetValue(p + "RXpass", 100.0 * (window - window_err) / window)  # this window only
        root.SetValue(p + "RXpps",  window)
        last_publish = now_us(); window = 0; window_err = 0
```

Three things in this differ from what this page said before, and they matter
for reading the statistics:

- **`RXerr` is cumulative** over the life of the link object. It never goes
  down (apart from the −1 a repeated `seq` produces) and is not reset by a
  publish. `RXpass` and `RXpps` describe the last window of at least one
  second.
- The clamp is applied to the gap, so a single discontinuity costs **at most
  999 errors**, and adds 1000 to that window's datagram count.
- `RXpps` counts sequence numbers accounted for, missing ones included, not
  datagrams received.

`ReportDropCount(n)` (`+0x15bdd0`) adds `n` to both error counters the same
way; nothing in the client calls it.

**Captured** (`vr3`): both directions' `seq` advance by exactly 1 for the
whole session (17,446 and 62,589 datagrams), and the statistics agree: the
client published `cRXerr` 0 and `cRXpass` 100 throughout, with `cRXpps` 6 in
the first window, 11,350 in the window holding the startup burst, 3,173 in the
next, then 1,128–1,738; the host published `sRXerr` 0, `sRXpass` 100 and `sRXpps`
247, then 410–451 — the client's real send rate of 433 datagrams per second.
All six travel in the string→double records (`../svl-values/`), the client's
in its `3/0x07` elements and the host's in frame descriptors, so the "to
confirm" on that point is settled.

### 3.1 Why a probe sees `sRXerr` climb by 1000 per session (**inferred**)

Observed by probe (`../svl-values/startup-exchange.md`): against the Python
client the host's `sRXerr` goes up by almost exactly 1000 for each 8-second
session while `sRXpass` reads 100. Against vrlink in `vr3` it
stays 0.

The accounting above produces exactly that signature from **one sequence
discontinuity per session**, and nothing else in it can: a gap of 2 or more
is the only way to add errors, 999 is what one large gap adds, and because
the function publishes *before* adding the gap to the window, the damage to
`sRXpass` is confined to a single one-second window (and can even be
published against the stale window of the previous session), after which it
reads 100 again. A client that really dropped or reordered datagrams would
instead add a few errors at a time and depress `sRXpass` continuously.

Where the discontinuity comes from: the probe's traffic is, datagram for
datagram, sequenced like vrlink's — `seq` 0, 1, 2, … from the
first datagram, one per datagram, all class 3 `id` fields 0 — so the stream
itself is clean. The jump is at the **session boundary**. The host-role code
that adopts a new peer (`HandleStreamIsActiveEvent`, `SetPairAddress`,
`connection-lifecycle.md` §2) does not reset `last`, so a host whose link
object outlives a session still remembers where the previous client's `seq`
stopped. The next session opens with `seq 0`; `(0 − last) & 0xffff` is a huge
"gap", clamped to 1000: +999 on a counter that is never cleared. The host in
`vr3` had only just started its link (its own first `seq` was 5), so `last`
was still −1 and the first datagram was simply remembered — hence 0 there.
The probe runs were back-to-back sessions against a SteamVR that stayed up.

This is an inference from the client binary's copy of the shared code; the
host may differ. It predicts, and a probe can check each:

1. On a cold host (SteamVR started by this session) `sRXerr` stays 0. On a
   warm one it steps by 999 once, in the first second, and is flat afterwards.
2. In that first second `sRXpps` reads about 1000 above the send rate, or
   `sRXpass` shows one wildly low (possibly negative) sample.
3. Starting a session at `seq = (last seq of the previous session) + 1`
   instead of 0 produces no step at all.
4. The host's own `seq` in its first datagram of a warm session is large,
   continuing from the previous session, rather than near 0.

**What the probe should change.** Its steady-state traffic can stay as it is.
The cheap experiment is (3): keep the last `seq` between sessions (or simply pick
up from any remembered value) and confirm the step disappears. The proper fix
is to end sessions the way vrlink does: send the teardown
datagram — `seq = 0xffff`, one zero-length `3/0x13` element — five times at
100 ms intervals (`connection-lifecycle.md` §6). Its fixed `seq` is suggestive:
after a datagram numbered 0xffff, a new session's `seq 0` is exactly "the next
one", gap 1, no error. Whether the host also clears its link state on that
message is not known; if it does not, the teardown datagram itself would
register one clamped gap on the way out, and (3) is the only complete cure.
The count is cosmetic either way — it is not fed back as loss, since
`sRXpass` recovers within a second.

## 4. Per-frame latency feedback (SendLastRXID)

`SendLastRXID` (`+0x15c648`) drains up to four ring buffers of (id, time) pairs
(decode / display / submit latency queues at `this+0x140 / 0x158 / 0x188 /
0x1b8`, each 0x400-deep) and packs them into a single element
`kind = 0x0f04, len = 0x18` (channel 4), sent via `SubmitMessage`. **Captured**
(`vr3`): this `0x0f04` element is in every client datagram, 17,446 of 17,446,
the first one included (with all-zero ids before any frame has arrived). It
is the frame-latency half of the host's rate-control inputs (Klepton SL-23);
its body is decoded in `../svl-video/` and `../svl-timing/`.

## Open questions / to confirm on the wire

Settled by `vr3`: the reliable stream is not used during connection setup or
steady streaming; `cRX*` / `sRX*` travel as string→double records; neither
side lost or reordered a datagram, and the counters say so.

Still open:
- What, if anything, uses the reliable classes 1/2. Candidates not exercised
  in `vr3`: controller input, message prompts, a session ended from the UI.
  Until one is captured the ack format (`GenSimpleDataset(1,0,seqid,0)`), the
  reorder window and the retransmit timing stay static-only.
- The four predictions in §3.1, which decide whether the `sRXerr` explanation
  is right. None needs more than the existing probe.
- Whether the host's rate controller reads `cRXerr` (cumulative) or only
  `cRXpass`. A probe can publish a growing `cRXerr` with `cRXpass` 100 and
  watch `dTargetBW`.

## Probe results (2026-11-10): the `sRXerr` step

Five 6 s probe sessions, 3 s apart, the first on a cold host. The host's
`sRXerr` at the end of each: 0, 999, 1998, 2997, 3996. **Captured by probe.**

- This confirms the reading above: the host keeps its last-received datagram
  `seq` across sessions, a new session's `seq 0` is one clamped gap of 999,
  and the counter is never cleared while SteamVR stays up. It is cosmetic:
  `sRXpass` reads 100.
- Sending vrlink's goodbye (`seq 0xffff`, one empty class-3
  type-0x13 message, five times) at the end of sessions 3 and 4 did **not**
  prevent the step in sessions 4 and 5. So the goodbye does not reset the
  host's sequence tracker.
- It did change something: the two sessions that followed a goodbye got their
  first complete frame at 0.03-0.04 s instead of 0.23-0.29 s. Unexplained.
- Untested: starting a session at the previous session's last `seq` + 1.
