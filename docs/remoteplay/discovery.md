# Discovery

## Probe

The client sends `MsgDiscovery` to the IPv4 limited broadcast address
(`255.255.255.255`) and to the IPv6 link-local all-nodes multicast group
(`ff02::1`), both on UDP port 27036 — **captured**:

```
ffffffff214c5fa0            magic
0c000000                    header_len = 12
  08 <varint client_id>     header.client_id (the device id)
  10 00                     header.msg_type = 0 (Discovery)
02000000                    body_len = 2
  08 01                     CMsgRemoteClientBroadcastDiscovery.seq_num = 1
```

- `seq_num` starts at 1 and increments once per discovery round, where each
  round sends one IPv4 broadcast packet and one IPv6 multicast packet. Rounds
  are spaced roughly 3 s apart while the host list is visible — **captured**
  (49 rounds, typical gap 2.8 s between rounds and 0.2 s within a pair).
- `client_ids` (field 2) was never set by the client — **captured**. Steam hosts
  populate `client_ids` in their own outgoing `MsgDiscovery` messages —
  **inferred** to list already-known peer IDs that do not need to re-announce.
- Hosts reply the same way to a unicast `MsgDiscovery` probe sent from any
  source port — **captured by probe** (`python3 -m ovrlink discover <ip>`).

Steam hosts also broadcast their own `MsgDiscovery` datagrams (42 bytes, with
`seq_num` in the 80s after a few minutes of uptime), so any socket bound to port
27036 receives periodic probes from every Steam installation on the LAN. Clients
should ignore incoming `MsgDiscovery` packets.

## Status reply

Hosts reply with `MsgStatus` and also broadcast `MsgStatus` unsolicited roughly
every 3 s — **captured**. Fields observed from a Windows host with SteamVR
installed (identifying values redacted):

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

Fields used by a VR Link client:

| field | use |
|---|---|
| header `client_id` | names the host in later requests (`CMsgRemoteDeviceStreamingRequest.client_id`) and keys the stored pairing secret |
| `vr_link_caps` | `k_EVRLinkCapsAvailable` (1) means the host can serve VR Link. Others: `Unknown` 0, `Unimplemented` 2, `MissingHardwareEncoding` 3 — **static** (enum) |
| `euniverse` | selects the RSA key for the pairing ticket ([crypto.md](crypto.md)); 1 is Public |
| `users[].steamid` | the account the pairing secret belongs to (`vrlink` stores secrets per host *and* per SteamID) |
| `vr_active`, `screen_locked`, `remoteplay_active` | absent when false; the request fails with the matching `ERemoteDeviceStreamingResult` if set — **inferred** from the enum names |
| `wifi_dongle_present`, `connected_paired_network_hash` | Steam Frame wireless-adapter pairing — **inferred**, not exercised |

A second host on the same LAN (Linux, `ostype: -184`, `enabled_services: 98`)
replied with the same message structure.

## Unicast subnet discovery

Broadcast and multicast are optional for discovery. Sending unicast
`MsgDiscovery` probes to each address in the local subnet discovers the same
hosts; Klepton uses this approach for `vrlink` on visionOS, where broadcast and
multicast sends fail without an Apple entitlement (1022 unicast probes across a
`/22` subnet returned a normal `MsgStatus` reply). See
[../client-architecture.md](../client-architecture.md).

## Negative results

- On one occasion, immediately after a streaming session was cut short by
  killing the client mid-stream, the Windows host stopped replying to both
  unicast and broadcast `MsgDiscovery` probes for at least ten minutes while
  still answering ICMP ping. The host-side cause is unknown (Steam may require a
  restart), so a missing `MsgStatus` reply after an abrupt disconnect does not
  necessarily indicate a client bug.

## Open questions

- Meaning of the undocumented bits in `enabled_services` beyond
  `ERemoteClientService` (1 RemoteControl, 2 GameStreaming, 4 SiteLicense,
  8 ContentCache, 16 ContentServer): `114 = 64 + 32 + 16 + 2` sets bits 32 and
  64.
- Purpose of `vr_link_invite_client_id` (possibly used when a host targets an
  invite at a specific headset).
