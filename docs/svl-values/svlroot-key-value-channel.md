# The SVLRoot key/value channel (`TransportValue_t`)

Separate from the VTS id table, `SVLRoot` keeps a `map<string, double>` that
both peers mirror to each other: mostly statistics and tunables. Keys are short
ASCII names whose first letter says who owns them (`c` client, `s` server,
`g` global, plus a few unprefixed debug names).

Binary: `libvrlink_scene.so`; offsets are file offsets. Little-endian.

## 1. `TransportValue_t` — 32 bytes, packed

| off | size | field | notes |
|---|---|---|---|
| 0x00 | char[20] | key | NUL-padded; a 20-character key has no terminator. An entry whose first byte is 0 is empty and skipped. |
| 0x14 | float64 | value | unaligned |
| 0x1c | int32 | timestamp | sender's SVL timestamp (µs, 32-bit, the transport clock) of the last `SetValue` |

**static**: `SVLRoot::PopulatePeerValueSettings` +0x165684 (writer: `memcpy`
of up to 20 key bytes, zero fill, 8-byte value at +0x14, 4-byte time at +0x1c),
`SVLRoot::ParsePeerValueSettings` +0x164c28 (reader).

**captured** (capture `vr3`): e.g. the first client record is
`63 50 68 61 73 65 4f 66 66 00…` (`cPhaseOff`), value `3500.0`, followed by a
32-bit timestamp; all 17,444 client type-7 datasets are exactly 96 bytes and
decode to sensible key/value pairs (52,332 records, 51 distinct keys, no
empty slot). The timestamp is the sender's SVL clock: for `cPhaseOff`, which
the client sets every frame, it is between 8 µs and 31 ms older than the
"now" field of the pose packet in the same datagram, on the same 32-bit
microsecond clock.

### String values

`SetValue(key, const char*)` +0x1652e0 stores a string of at most 8 bytes *in
the 8 bytes of the double* (zero padded) and marks the key by setting bit 7 of
its first character (`key[0] |= 0x80`) (**static**). `GetValueS` +0x165108 is
the reader. No caller of either function was found in the client's own code
paths, so whether the host ever sends such entries is **unknown**; a parser
should accept a key whose first byte is ≥ 0x80 and treat the value bytes as
text.

## 2. Carriers

| direction | carrier | layout | evidence |
|---|---|---|---|
| client → host | dataset type `0x07` | dataset header (`03 07 00 00`, `u16 len = n*32`, `u16 0`) + `n` × `TransportValue_t`; n ≤ 31 | static: `SVLRoot::SendValues(int)` +0x1655e0 |
| host → client | dataset type `0x07` | same; count = `len >> 5` | static: `SVLRoot::RXUnreliableStream` +0x164ae0 `case 7` |
| host → client | video bookend trailer | count = `u8` at trailer +0x0d, entries start at trailer +0x10 (trailer version byte at +0x0c must be 3) | static: `QSVLClient::ReceivedBookend` +0xf6cf8 |

The dataset header fields are the transport's (docs/svl-transport/); the
`03 07` pair is the literal `0x0703` the client writes into the first two
header bytes.

**captured** (`vr3`): the client's type-7 dataset rides in the same UDP
datagram as the pose dataset, directly before the frame report and the pose —
in 17,444 of 17,446 datagrams; the two without are the session's first two,
which client init sends before the tick that calls `SendValues`. The host
sent no type-7 dataset in 40 s; all host values arrived in bookend trailers
(8,632 bookends, always exactly 4 records each, cycling through the host's
table: 34,528 records). So in practice the two directions use different
carriers, the client 3 records 433 times a second and the host 4 records 217
times a second.

The client sends one type-7 packet with **3 entries** on every pose tick:
`QSVLClient::HandleEvent` +0xf4bec, posted event type 0, calls `SendValues(3)`
and then `SendPoses`. (`SubmitMessage(ds, false, false)` — the two flags are
the transport's; **inferred** unreliable, unacked.)

### Which entries go into a packet

```python
def populate(n):
    out = []
    for i in range(n):
        if i == 0 or not dirty_keys:
            # slot 0 (and any slot when nothing is dirty): round-robin over ALL keys
            it = values.find(cursor_key)
            it = values.begin() if it == values.end() else it
            if it == values.end(): out.append(bytes(32)); continue   # map empty
            it = next(it); it = values.begin() if it == values.end() else it
            cursor_key = key = it.key
        else:
            key = dirty_keys.pop_first()          # std::set order = lexicographic
        out.append(key[:20].ljust(20, b"\0") + f64(values[key]) + i32(timestamps[key]))
    return out
```

**static**: +0x165684. So every key is eventually repeated (slot 0 cycles the
whole map, including keys learned from the peer), and changed keys are pushed
promptly through the other slots. There is no ack: loss is repaired by the
cycle.

**captured** (`vr3`): the slot statistics match. Keys that never change
(`cFramePhase`, `cAudDrop`, `encResets`, every echoed host key) each appear
about 720–800 times in 17,444 datasets — once per round-robin lap of the
51-key map, roughly 18 times a second — and are spread over all three slots,
as they are when nothing is dirty. Keys the client rewrites every frame are
far more frequent and sit mostly in slots 1 and 2: `cPhaseOff` 5,020 times
(4,089 of them in slot 1), `cPingAMS` 4,967, `cPingMS` 3,738, `cAudUnd` 3,613.
A changed value therefore reaches the host within a pose tick or two, and an
unchanged one is refreshed about every 55 ms.

### Receive rule

For each non-empty entry: if the key is in the receiver's *locally-set* set
(any key this side has ever passed to `SetValue`), the entry is **ignored** —
local ownership wins. Otherwise `values[key] = value` and
`timestamps[key] = peer_ts` converted to the local clock with the transport's
clock-offset estimate (`ts + (A − B)/2` with `A = SVLRoot+0xc7c`,
`B = SVLRoot+0xc84`; see the transport/timing docs for those two) (**static**
+0x164c28). A received value does not mark the key dirty, but it does enter the
round-robin, so each side echoes the other's keys back.

`SetValue(key, double)` +0x164fec (**static**): stores the value, adds the key
to the dirty set only if the value changed, adds it to the locally-set set, and
stamps `GetCurrentTimestamp()`.

## 3. Key list

Keys the client **writes** (all **static**, key literal at the named call site):

| key | written by | value |
|---|---|---|
| `cRXpps` | `SVLDataLink::CheckUpdateCounters` +0x15b15c | datagram sequence numbers accounted for in the last ≥1 s window (received plus counted-missing) |
| `cRXerr` | same | missing datagrams, **cumulative** since the link object was created (`SVLDataLink+0xbc`); not a per-window figure. One discontinuity adds at most 999. docs/svl-transport/reliable-stream.md §3 |
| `cRXpass` | same | `100 * (window − window_missing) / window` percent, for the last window only |
| `cPingMS` | `QSVLClient::OnRenderComplete` +0xf671c | `(SVLRoot+0xc84 + SVLRoot+0xc7c) / 1000.0` — the sum of the two one-way clock-delta estimates, i.e. round-trip time in ms |
| `cPingAMS` | same | `SVLRoot+0x19c / 1000.0` — a peak-hold of the latency sample that decays by `SVLRoot+0x198` µs per update and is capped at 100 000 µs (`SVLRoot::SymmetricTimingUpdate` +0x165a38). The decay step is set by the host through VTE 0x1c. |
| `cPhaseOff` | `OnRenderComplete`, `AdjustPhaseOffset`, `PhaseEventControlLoop` | current phase offset in µs (`SVLRoot+0xcc0`); see docs/svl-timing/ |
| `cStandoff` | `QSVLClient::OnTopOfFrame` | per-frame standoff in µs; see docs/svl-timing/ |
| `cFramePhase` | `QSVLClientXR` ctor | initial frame phase (0.3 observed by Klepton); see docs/svl-timing/ |
| `dbgPhaFault` | `QSVLClient::HandleEvent` (event type 4) | `SVLRoot+0xe00`, a phase-fault counter |
| `cAudDrop`, `cAudFEC`, `cAudUnd`, `cAudOvf`, `cAudBufAvg`, `cAudBufMin`, `cAudBufMax`, `cAudBufVar`, `cAudRew`, `cAudFwd`, `cAudFade` | `SVLAudio::UpdateStats` | audio jitter-buffer statistics; see docs/svl-audio/ |
| `cSoundSPS` | `SoundLogger::CheckStatus` | measured audio samples per second |
| `rexmitReq` | `SVLFECRXFrame::CheckRetry`, `SVLFEC::RerequestBookend` | retransmit requests issued; see docs/svl-video/ |
| `rexmitSent` | `SVLFECTXFrame::HandleRetransmitRequest` | retransmits served (uplink) |
| `txTimeMS` | `SVLFECRAID6TXFrame::InitializeAndSend` | uplink frame send time |

`CheckUpdateCounters` contains both the `c…` and `s…` spellings (`cRXerr` /
`sRXerr`, …): the code is shared with the host and picks the prefix by role
(**static** strings; role selection **inferred**).

Keys the client **reads** (so the host may set them):

| key | read by | effect |
|---|---|---|
| `sFramePhase` | `QSVLClient::OnRenderComplete` | if the host has set it, it overrides `cFramePhase`; stored as float at `SVLRoot+0xcc4` |
| `cFramePhase` | same | used when `sFramePhase` is absent |
| `gLimitMBPS` | `SVLDataLink::Tick` (per Klepton SL-23) | link rate limit |
| `sBWFECLim` | `SVLFECRAID6TXFrame::InitializeAndSend` (per Klepton SL-23) | uplink FEC limit |

Other key-shaped strings present in the binary whose call sites were not traced
here: `gTfT`, `sRFTXRate`, `cTXerr`/`sTXerr`, `cRXFailFuzz`/`sRXFailFuzz`,
`cTXFailFuzz`/`sTXFailFuzz`, `cVTXFailFuzz`/`sVTXFailFuzz` (deliberate loss
injection), `dbgEncTimeMS`, `dbgStartEnc`, `dbgTXWaitMS` (host-side encoder
debug names). Their meanings are **inferred from the names only**.

Not keys of this channel, despite the prefix (they are JSON config keys or
launch-option names): `sTrackingSystem`, `sSerialNumber`, `sManufacturerName`,
`sModelNumber`, `sRenderModelName`, `sResourceRoot`, `sInputProfilePath`,
`sControllerType`, `sDeviceType`, `sNetworkTest`, `sStartInfo`, `sTCPIp`,
`sUDPIp`, `sDescription`, `sPermission`, `sText`, `sTitle`,
`sOriginalPackage`, `sOriginalActivity`. The `cA9h`-style names in Klepton's
SL-23 list are machine-code bytes that happen to be printable, not keys.

### Keys seen on the wire (**captured**, capture `vr3`)

Client-owned keys observed in client packets, with the range of values over
the 40 s session: `cPhaseOff` 3..8331, `cFramePhase` 0.3, `cStandoff`
3490..3500, `cPingMS` −6.3..1.4 (negative while the clock estimate settles;
docs/svl-transport/time-sync.md §3), `cPingAMS` −0.5..100, `cRXpps`
6..11350 (1,128..1,738 after the startup burst), `cRXerr` 0, `cRXpass` 100,
`dbgPhaFault` 0, and the eleven `cAud*` keys (`cAudUnd` climbing from 4,080
to 1.47 million, `cAudBufAvg` 0..50, `cAudBufMax` 0..64; docs/svl-audio/).
20 client keys in all. `rexmitReq` and
`rexmitSent` never appear: `vr3` lost no datagram and the client asked for no
retransmission (`vr1`, with real loss, showed `rexmitReq` 9..186, `cRXerr` up
to 43 and `cRXpass` down to 91.7).

The client's keys start at once — `cPhaseOff` and `cFramePhase` are in its
third datagram — except `cRXpps`, `cRXpass` and `cRXerr`, which first appear
0.91 s in, when `CheckUpdateCounters` first has a second's worth to report.
The host's keys first reach the client in the first bookend (0.926 s), and
the client is echoing them back within 15 ms.

Host-owned keys. These were decoded both from bookend trailers and from the
client's own packets, because the client's round-robin slot echoes every key
it has learned from the host back to it (as the static reading predicts — and
the host likewise echoes `c*` keys back in its bookends):

| key | values seen | meaning (**inferred** from the name unless noted) |
|---|---|---|
| `sRXpps`, `sRXerr`, `sRXpass` | 247 then 410..451; 0; 100 | host's receive counters (same code as the client's): `sRXpps` tracks the client's real 433 datagrams per second |
| `sPingMS` | −6.25..0.65 | host's round-trip estimate (negative for the same reason as `cPingMS`; `vr1`'s 2399..3727 was that capture's broken clock sync) |
| `sTimeConf` | 387, then 400 from 1.39 s | time-sync confidence counter (`SVLRoot+0xc80` saturates at 400 in `SymmetricTimingUpdate`) |
| `dCurBW`, `dTargetBW`, `dEstLinkBW`, `dProblemBW`, `dHitchMaxBW` | 0.06..208, 27.9..199, 120..199, 120..200, 27.6..347.5 | bitrate controller state, Mbit/s. `dTargetBW` starts at 198.7, drops to 67.5 within 35 ms of the first frame and then moves between about 28 and 153 |
| `dPingThr`, `dQThrottle`, `dFBwThr`, `dPresThr` | 0.11..1, 0.89..1, 0.37..1, 0.56..1 | throttle factors (ping, queue, bandwidth, presentation) |
| `dTXQ` | 0..3 | host transmit queue depth |
| `dFrmsEarly`, `dFrmsLate`, `dFrmsAddl` | 0..46, 0..12, 1..4 | frame timing counters |
| `dRunStart` | 0.01..76 | — (76 at the first frame, under 10 from 1.3 s) |
| `dbgEncTimeMS`, `dbgSendTimeMS`, `dbgTXWaitMS`, `dbgSyncOff`, `encSubmitFrameMS`, `GetData`, `StartNvEnc` | 4.3..7.4, 0.02..0.31, 0, 8.0..17.6, 0.003..0.01, 3.7..7.1, 0.11..0.44 | encoder pipeline timings, ms |
| `nLayerCount` | 2 | number of stream layers (matches the two foveation layers) |
| `nFramesSkippedPS` | 1, 6, then 0 from 3.2 s | frames skipped per second |
| `encResets` | 3 | encoder resets (constant through the session) |
| `tsLastWGP` | 2.005e9..2.044e9, advancing 1e6 per second | a timestamp on the host's SVL microsecond clock |
| `txTimeMS` | 0.017..0.156 | time to send a frame's packets, ms. Listed above among the keys the client's code can write (the FEC transmit path), but in `vr3` it first appears in the client's packets only after the host's bookends have delivered it: here it is the host's, echoed |

That is 31 host keys. The host's bookends carry all 51 keys — its own 31
and the client's 20 echoed back — under the same selection rule as the
client's: keys that change every frame are in about every second bookend
(`dCurBW`, `dEstLinkBW`, `GetData`, `StartNvEnc` 4,200–4,400 times in 8,632;
`dHitchMaxBW`, `dProblemBW` 3,200–3,700), while a constant such as
`nLayerCount` or an echoed client key comes round about 170 times, four a
second.

Not seen in either capture: `sFramePhase`, `gLimitMBPS`, `sBWFECLim`, `gTfT`,
`sRFTXRate`, any `*FailFuzz` key, and any string-valued entry (no key with
bit 7 set in its first byte among 86,860 records).

## Open questions / to confirm on the wire

Resolved by `vr3`: record layout, 3 records per pose tick, the round-robin +
echo behavior and its cadence, the host key list above, and that the
timestamp field is the sender's SVL clock.

3. Whether the host needs any client key to keep streaming well. The probe
   has shown none is needed to *start* (startup-exchange.md: video with only
   pose, frame-report and three statistics keys). Klepton's SL-26 suspects
   `cPhaseOff` drives the host's bitrate; a probe client can hold
   `cRXpass = 100`, `cPhaseOff` constant and observe `dTargetBW`.
4. Whether string-valued entries (key byte 0 ≥ 0x80) ever appear. None in
   either capture.
6. Whether the host ever uses a type-0x07 dataset (the client can parse one),
   for instance before video when it has no bookend to put its keys in. In
   `vr3` it sent none in the 0.93 s before the first frame.
7. What the host does with the client keys it receives, beyond echoing them.
