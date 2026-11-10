# Discovery

## Probe

The client sends `MsgDiscovery` to the IPv4 broadcast address and to the IPv6
all-nodes group `ff02::1`, both on port 27036 — **captured**:

```
ffffffff214c5fa0            magic
0c000000                    header_len = 12
  08 <varint client_id>     header.client_id (the device id)
  10 00                     header.msg_type = 0 (Discovery)
02000000                    body_len = 2
  08 01                     CMsgRemoteClientBroadcastDiscovery.seq_num = 1
```

- `seq_num` starts at 1 and increments once per round; each round is the pair
  of sends (v4 broadcast, v6 multicast). Rounds are about 3 s apart while the
  host list is on screen — **captured** (49 rounds, typical gap 2.8 s + 0.2 s).
- `client_ids` (field 2) was never set by the client — **captured**. Hosts set
  it in their own Discovery messages — **inferred** to be "the ids I already
  know about, do not re-announce".
- A probe sent unicast to one host is answered the same way — **captured by
  probe** (`python3 -m ovrlink discover <ip>`), from any source port.

Steam hosts send their own `MsgDiscovery` datagrams too (42 bytes, their
`seq_num` in the 80s after a few minutes), so a listener on 27036 sees probes
from every Steam install on the LAN. They are not replies; ignore them.

## Status reply

A host answers with `MsgStatus`, and also repeats it unprompted about every
3 s — **captured**. Fields seen from a Windows host with SteamVR installed
(identifying values replaced):

```
header   client_id: <host id>   msg_type: Status   instance_id: <u64>
body     version: 8                 min_version: 6
         connect_port: 27036        hostname: "<HOSTNAME>"
         enabled_services: 114      supported_services: 2
         ostype: 20                 is64bit: true
         users { steamid: <id64>  auth_key_id: <u32> }
         euniverse: 1               timestamp: <unix seconds>
         games_running: false
         mac_addresses: "AA-BB-CC-DD-EE-FF" (one per NIC)
         ip_addresses: "<lan ip>"   (one per NIC)
         public_ip_address: "<wan ip>"
         steam_version: <u64>
         vr_link_caps: k_EVRLinkCapsAvailable
         vr_link_invite_client_id: 0
         wifi_dongle_present: false
```

What a VR Link client needs from it:

| field | use |
|---|---|
| header `client_id` | names the host in later requests (`CMsgRemoteDeviceStreamingRequest.client_id`) and keys the stored pairing secret |
| `vr_link_caps` | `k_EVRLinkCapsAvailable` (1) means the host can serve VR Link. Others: `Unknown` 0, `Unimplemented` 2, `MissingHardwareEncoding` 3 — **static** (enum) |
| `euniverse` | selects the RSA key for the pairing ticket ([crypto.md](crypto.md)); 1 is Public |
| `users[].steamid` | the account the pairing secret belongs to (vrlink stores secrets per host *and* per SteamID) |
| `vr_active`, `screen_locked`, `remoteplay_active` | absent when false; the request fails with the matching `ERemoteDeviceStreamingResult` if set — **inferred** from the enum names |
| `wifi_dongle_present`, `connected_paired_network_hash` | Steam Frame wireless-adapter pairing — **inferred**, not exercised |

A second host on the same LAN (Linux, `ostype: -184`, `enabled_services: 98`)
answered with the same shape.

## Clients that cannot broadcast

A client does not need broadcast at all. Unicast probes to each address of the
local subnet find the same hosts; Klepton does this for vrlink
on visionOS, where broadcast and multicast are refused without an entitlement
(1022 unicast probes on a /22, host reply received). See
[../client-architecture.md](../client-architecture.md).

## Negative results

- A host can stop answering discovery entirely while its machine still answers
  ping. Seen once, immediately after a streaming session was cut off by killing
  the client mid-stream; unicast and broadcast probes both went unanswered for
  at least ten minutes. Cause unknown (Steam may need a restart). Do not read
  "no Status" as a client bug.

## Open questions

- The meaning of the `enabled_services` bits beyond `ERemoteClientService`
  (1 RemoteControl, 2 GameStreaming, 4 SiteLicense, 8 ContentCache,
  16 ContentServer): 114 = 64+32+16+2 has two undocumented bits.
- `vr_link_invite_client_id`: a host inviting one specific headset?
