# Steam VR Link protocol documentation

This documentation describes how a headset client discovers a Steam host, pairs
with it, and streams SteamVR over the network. Everything here is derived from
packet captures of `vrlink` running under Klepton and static analysis of the
client's shared libraries.

## Layers

| folder | layer | transport |
|---|---|---|
| [remoteplay/](remoteplay/) | discovery, pairing, session request — ends with the session string `sArgs` | UDP 27036, protobuf |
| [svl-transport/](svl-transport/) | SVL datagrams: header, checksum/cipher modes, elements, channels, connection lifecycle, reliable stream | UDP 10400 |
| [svl-values/](svl-values/) | the value-transport system (`VTE_*` ids), device property JSON, the string→double tuning channel | SVL elements |
| [svl-video/](svl-video/) | HEVC video packets, frame descriptors, FEC, retransmission, the foveated frame layout | SVL elements |
| [svl-tracking-input/](svl-tracking-input/) | head and controller poses, buttons, skeletons, haptics, prompts | SVL elements |
| [svl-audio/](svl-audio/) | audio downlink, microphone uplink, audio FEC, jitter buffer | SVL elements |
| [svl-timing/](svl-timing/) | clock sync, the frame phase loop, per-frame timing reports | SVL elements |

The sections above are ordered to follow a session from discovery to the first
rendered frame. [client-architecture.md](client-architecture.md) covers the
design of the cross-platform client built on top of these protocol layers.

## Evidence classes

Claims are tagged by how they were verified:

- **captured** — observed on the wire, or recomputed from captured packet bytes.
- **static** — read from a binary via static analysis, cited as `library+offset`
  (file offsets) or a symbol name.
- **inferred** — an unverified estimate based on surrounding behavior or names.

Each page ends with open questions. When a probe in `prototype/minimal/`
confirms or refutes an inference, record the result on the corresponding page.

## Sources

- **Client**: `steamlink-vr.apk` (`com.valvesoftware.steamlinkvr`), arm64.
  `libshell_arm64-v8a.so` implements the 2D Steam Link shell (the Remote Play
  layer), and `libvrlink_scene.so` implements `vrlink` (all SVL layers). Both
  libraries export C++ symbols.
- **Captures**: Recorded under Klepton with
  `KL_TRACE_NET=1 KL_TRACE_NET_HEX=1600`, parsed by
  `prototype/minimal/tools/kltrace.py` and `svldump.py`. Capture files contain
  live credentials and are excluded from the repository.
- **Host**: Steam for Windows running SteamVR on the same LAN.

Host binaries were not inspected; host behavior is documented strictly from
network observations.

## Captures

| name | what | quality |
|---|---|---|
| `vr1` | `vrlink`, ~20 s of streaming | a third of datagrams torn by the tracer, no timestamps. Most "captured" claims in the SVL folders were checked against `vr1`, so their counts are lower bounds |
| `vr3` | `vrlink`, 40 s of streaming, 2026-11-10 | 80,011 SVL datagrams, none torn, microsecond timestamps; a 120 Hz session delivering 108.3 frames per second. 4,260 frames rebuilt by `replay_video.py`, 4,259 found byte-for-byte in the client's decoder dump (the last frame's dump was cut when the client was killed). The log itself is complete — 80,035 datagrams (17,446 client→host, 62,589 host→client), every `seq` present in both directions — but `kltrace.py` looks back only 8 lines (`LOOKBACK`) for a hex dump's `[net]` line and 24 dumps (23 outbound, 1 inbound) sit further away, so the stock tools yield 80,011 with 24 apparent gaps; `kltrace.LOOKBACK = 400` recovers all 80,035 datagrams. `svl-transport/` and `svl-values/` have been re-checked against this capture. No loss recovery, reset, or controller input occurred during the capture, and the audio stream is silent |
| probe runs | `prototype/minimal` against the host | recorded as "Probe results" sections on the pages they settle |

`vr3` also captures a 179-byte host-to-client message (class 3, type `0x18`,
sent every 2 s) that `vrlink` has no handler for. It carries a list of the
host's network interface addresses; see
[svl-transport/host-address-list.md](svl-transport/host-address-list.md).
