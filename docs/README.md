# Steam VR Link protocol documentation

How a headset client finds a Steam host, pairs with it, and streams SteamVR
from it. Written from the outside: wire captures of Valve's client running
under Klepton, plus static reading of that client's libraries.

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

Read in that order to follow a session from power-on to first frame.

[client-architecture.md](client-architecture.md) is separate from the protocol:
it is the plan for the cross-platform client built on these layers.

## Evidence classes

Every claim is tagged:

- **captured** -> seen on the wire, or recomputed from wire bytes.
- **static** -> read from a binary; cited as `library+offset` (file offsets) or
  a symbol name.
- **inferred** -> a guesstimate

Each page ends with what is still open. A probe from `prototype/minimal/` that
confirms or refutes an inference should be recorded on the page it settles.

## Sources

- Client: `steamlink-vr.apk` (`com.valvesoftware.steamlinkvr`), arm64.
  `libshell_arm64-v8a.so` is the 2D shell (the remoteplay layer);
  `libvrlink_scene.so` is the VR client (every SVL layer). Both export C++
  symbols.
- Captures: Klepton with `KL_TRACE_NET=1 KL_TRACE_NET_HEX=1600`, parsed by
  `prototype/minimal/tools/kltrace.py` and `svldump.py`. Captures hold live
  credentials and stay out of the repository.
- Host: Steam for Windows with SteamVR, on the same LAN.

Nothing here comes from the host's binaries; host behavior is described only
as observed.

## Captures

| name | what | quality |
|---|---|---|
| `vr1` | real client, ~20 s of streaming | a third of datagrams torn by the tracer, no timestamps. Most "captured" claims in the SVL folders were checked against this one, so their counts are lower bounds |
| `vr3` | real client, 40 s of streaming, 2026-11-10 | 80,011 SVL datagrams, none torn, microsecond timestamps; a 120 Hz session delivering 108.3 frames per second. 4,260 frames rebuilt by `replay_video.py`, 4,259 found byte-for-byte in the client's decoder dump (the last frame's dump was cut when the client was killed). The log itself is complete — 80,035 datagrams (17,446 client→host, 62,589 host→client), every `seq` present in both directions — but `kltrace.py` looks back only 8 lines (`LOOKBACK`) for a hex dump's `[net]` line and 24 dumps (23 outbound, 1 inbound) sit further away, so the stock tools yield 80,011 with 24 apparent gaps; `kltrace.LOOKBACK = 400` recovers all of them. `svl-transport/` and `svl-values/` have been re-checked against this capture. No loss recovery, reset or controller input occurred in it, and its audio is silence |
| probe runs | `prototype/minimal` against the host | recorded as "Probe results" sections on the pages they settle |

`vr3` also shows a host-to-client message vrlink has no handler
for: class 3 type 0x18, 179 bytes, one every 2 s. It is a list of the host's
interface addresses; see [svl-transport/host-address-list.md](svl-transport/host-address-list.md).
