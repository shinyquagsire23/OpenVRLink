# Minimal protocol probe

A Python client whose job is to test the protocol documentation in `docs/` by
talking to a real Steam host, one layer at a time, with things changed.
Needs Python 3.11+, `protobuf` and `cryptography`.

```
python3 -m ovrlink discover [host ...]        find Steam hosts (docs/remoteplay/discovery.md)
python3 -m ovrlink pair <host>                PIN pairing (docs/remoteplay/pairing.md)
python3 -m ovrlink session <host>             ask for a SteamVR session (session-request.md)
python3 -m ovrlink stream <host> out.h265     run a session and save the video
```

`pair` prints a PIN to type into Steam on the host. The resulting secret is
stored in `identity.json` in the OpenVRLink data folder
(`~/Library/Application Support/OpenVRLink` on macOS; see
`docs/client-architecture.md`), never in this repository.

| module | layer |
|---|---|
| `ovrlink/broadcast.py` | UDP 27036 datagram format, discovery |
| `ovrlink/steamcrypto.py` | Steam's symmetric scheme, the PIN-masked key exchange, the RSA ticket |
| `ovrlink/pairing.py` | authorization and the streaming request; produces the session string |
| `ovrlink/svl.py` | SVL datagrams and elements, the XOR checksum |
| `ovrlink/vts.py` | the value-transport system |
| `ovrlink/video.py` | frame descriptors and frame reassembly (no FEC yet) |
| `ovrlink/profile.py` | the values this probe publishes about itself |
| `ovrlink/client.py` | the live loop: poses up, video down |

## Tools for captures

Captures come from Klepton running the real client:

```
KL_TRACE_NET=1 KL_TRACE_NET_HEX=1600 KL_VTDEC_DUMP=/tmp/ovl/run.h265 \
  ./build_run_host.sh steamlink-vr --shell --view      > /tmp/ovl/run.log
```

| tool | use |
|---|---|
| `tools/kltrace.py <log>` | list every traced packet |
| `tools/svldump.py <log> [--list]` | census or listing of SVL elements |
| `tools/replay_video.py <log> --reference run.h265` | rebuild video from the capture and compare with what the real client decoded |
| `tools/extract_protos.py <lib.so> <dir>` | recover `.proto` files from a binary |

Captures contain a live session token and account identifiers. Keep them
outside the repository.

## What has been run

All four commands have run against Steam for Windows with SteamVR: `pair`
completed by PIN, and `stream` saved 20 s of video that ffmpeg decodes
(HEVC Main 10, 1536x6144). Not implemented: FEC repair, retransmit requests,
audio, controllers, head motion.
