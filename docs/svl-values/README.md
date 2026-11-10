# SVL values layer

This layer covers everything in the Steam VR Link ("SVL") protocol that is a
*named value* rather than a media stream: device descriptions, display
geometry, refresh-rate negotiation, settings pushed by the host, and the
statistics both ends share. Two independent mechanisms exist, both riding on other SVL messages:

| mechanism | keyed by | reliability | carriers |
|---|---|---|---|
| **ValueTransportSystem (VTS)** | `ValueTransportID` byte (`VTE_*`) | chunked, versioned, acked, re-sent until acked | client→host: tail of every pose packet; host→client: type-0x0d datasets and video bookend trailers |
| **SVLRoot key/value channel** | ASCII name ≤ 20 chars → `double` | none; round-robin repetition | client→host: type-0x07 dataset each pose tick; host→client: bookend trailers (and type-0x07) |

Source: static analysis of `libvrlink_scene.so` (the Android arm64 Steam Link
VR client; offsets in the docs are file offsets, Ghidra = offset + 0x100000),
then checked against capture `vr3` of a real streaming session (40 s,
complete from the first datagram, timestamped; an earlier torn capture, `vr1`,
is cited only where it showed something `vr3` did not). Every claim is
tagged **static**, **captured** or **inferred**. The UDP header, encryption and
handshake are the transport's (docs/svl-transport/) and are not described here.

## Files

| file | contents |
|---|---|
| [value-transport-wire-format.md](value-transport-wire-format.md) | VTS element encoding (data chunk, ack), versions, sender/receiver algorithms in Python, restart detection, what the capture confirmed |
| [vte-id-table.md](vte-id-table.md) | every `ValueTransportID` the client reads or writes: id → name → payload → direction → evidence, plus host ids seen on the wire that this client ignores |
| [static-and-power-props.md](static-and-power-props.md) | `VTE_StaticProps_t` (1161 bytes), `VTE_PowerProps_t` (12), `VTE_HostDefaults_t` (8); how the APK's JSON config maps onto them; worked example |
| [startup-exchange.md](startup-exchange.md) | order of the startup exchange, the IPD gate, refresh-rate request/reply, minimum set for a new client |
| [svlroot-key-value-channel.md](svlroot-key-value-channel.md) | `TransportValue_t` (32 bytes), selection and receive rules, client and host key lists |

## Headline facts

- A VTS data chunk is `[0x80|version][id][u16 chunk][u32 total]` + ≤128 bytes;
  an ack is `[version][id][u16 chunk]`. Static and captured in both directions.
- Device properties are **packed structs, not JSON**. JSON is only the client's
  local config format.
- The client's table has 51 ids; the captured host (protocol version 14) also
  sends ids 0x35, 0x64, 0x65, 0x67, 0x72. Unknown ids must still be acked.
- The whole startup negotiation takes 42 ms and ends 0.88 s before the first
  video packet. In that gap the host sends no acks at all, and the reference
  client re-sends its 39 un-acked chunks 27 times over; the first frame
  descriptor acks them in one go.
- Both sides re-send all their plain values under a new version when they
  first see the other's instance id.
- `VTE_AVAILABLE_FRAMETIMES_US` carries refresh rates in **Hz as floats**;
  the host answers with a float Hz request (id 0x21) and the client confirms
  with `VTE_REQ_FRAMETIME_US` in µs (id 0x0c).
- Eye-to-head and projection are only published when the IPD is non-zero.
- The key/value channel is 3 records per pose packet (433 packets a second)
  from the client and 4 per frame descriptor (217 a second) from the host,
  and each side echoes the other's keys back.
- `cRXerr` / `sRXerr` are cumulative counters, not rates.

## Not determined

- Names of ids that have no log string (only 14 of the enum names are
  recoverable from this binary), and the meaning of host ids 0x06, 0x1b, 0x1f
  and the out-of-table ones.
- What the host does between the end of the negotiation and the first frame,
  and why it stops acking then.
- Power-prop flag names; `VTE_HostDefaults_t` field meaning; non-zero layout of
  `VTE_PROP_COLOR_CONTROL` beyond its version word.
- Whether string-valued `TransportValue_t` entries are ever used.
