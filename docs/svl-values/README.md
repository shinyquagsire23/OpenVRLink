# SVL values layer

This layer covers everything in the Steam VR Link ("SVL") protocol that is a
*named value* rather than a media stream: device descriptions, display
geometry, refresh-rate negotiation, settings pushed by the host, and the
statistics both ends share. Two independent mechanisms exist, both riding on other SVL messages:

| mechanism | keyed by | reliability | carriers |
|---|---|---|---|
| **ValueTransportSystem (VTS)** | `ValueTransportID` byte (`VTE_*`) | chunked, versioned, acked, re-sent until acked | client→host: tail of every pose packet; host→client: type-0x0d datasets and video bookend trailers |
| **SVLRoot key/value channel** | ASCII name ≤ 20 chars → `double` | none; round-robin repetition | client→host: type-0x07 dataset each pose tick; host→client: bookend trailers (and type-0x07) |

These docs are based on static analysis of `libvrlink_scene.so` (the Android
arm64 `vrlink` client; file offsets are used throughout, where Ghidra address =
offset + 0x100000), verified against capture `vr3` from a 40 s `vrlink`
streaming session (complete from the first datagram and timestamped; an earlier
torn capture, `vr1`, is cited only where it showed behavior absent from `vr3`).
Every claim is tagged **static**, **captured**, or **inferred**. The UDP header,
encryption, and handshake belong to the transport layer (docs/svl-transport/)
and are not covered here.

## Files

| file | contents |
|---|---|
| [value-transport-wire-format.md](value-transport-wire-format.md) | VTS element encoding (data chunk, ack), versions, sender/receiver algorithms in Python, restart detection, capture verification |
| [vte-id-table.md](vte-id-table.md) | every `ValueTransportID` `vrlink` reads or writes: id → name → payload → direction → evidence, plus out-of-table host ids seen on the wire |
| [static-and-power-props.md](static-and-power-props.md) | `VTE_StaticProps_t` (1161 bytes), `VTE_PowerProps_t` (12), `VTE_HostDefaults_t` (8); how the APK's JSON config maps onto them; worked example |
| [startup-exchange.md](startup-exchange.md) | startup value sequence, the IPD gate, refresh-rate negotiation, and minimum startup set for a client |
| [svlroot-key-value-channel.md](svlroot-key-value-channel.md) | `TransportValue_t` (32 bytes), outgoing selection and receive rules, client and host key lists |

## Summary

- A VTS data chunk is `[0x80|version][id][u16 chunk][u32 total]` followed by up
  to 128 bytes, and an ack is `[version][id][u16 chunk]` (**static** and
  **captured** in both directions).
- Device properties travel on the wire as **packed C structs**; JSON is only
  `vrlink`'s local config format.
- `vrlink`'s table has 51 ids, while the captured host (protocol version 14)
  also sends ids 0x35, 0x64, 0x65, 0x67, and 0x72. Unknown ids must still be
  acked.
- Startup value negotiation finishes in 42 ms, 0.88 s before the first video
  packet. During that 0.88 s gap the host sends no acks, causing `vrlink` to
  re-send its 39 unacknowledged chunks 27 times until the first frame
  descriptor acks all of them.
- Both peers re-send all of their non-event values under a new version when
  they first receive the peer's instance id.
- `VTE_AVAILABLE_FRAMETIMES_US` carries refresh rates in **Hz as floats**;
  the host replies with a float Hz request (id 0x21) and the client confirms
  with `VTE_REQ_FRAMETIME_US` in µs (id 0x0c).
- Eye-to-head and projection parameters are published only when the IPD is
  non-zero.
- The key/value channel carries 3 records per pose packet (~433 packets/s)
  from the client and 4 records per frame descriptor (~217 descriptors/s) from
  the host, with each side echoing the other's keys back.
- `cRXerr` and `sRXerr` are cumulative counters rather than per-window rates.

## Open questions

- Enum names for ids without log strings (only 14 enum names are recoverable
  from `libvrlink_scene.so`), and the meaning of host ids 0x06, 0x1b, 0x1f, and
  the out-of-table ids (0x35, 0x64, 0x65, 0x67, 0x72).
- What the host is doing during the 0.88 s gap between startup negotiation and
  the first video frame, and why it stops sending type-0x0d acks during that
  window.
- Exact OpenVR property mappings for the `VTE_PowerProps_t` flag bits, field
  meanings in `VTE_HostDefaults_t`, and the non-zero layout of
  `VTE_PROP_COLOR_CONTROL` beyond its version word.
- Whether string-valued `TransportValue_t` entries are ever sent in practice.
