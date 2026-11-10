# Host address list (class 3, type 0x18)

A host→client message on the unreliable stream that lists the host's network
interface addresses. It is the one message in capture `vr3` that the reference
client has no code for.

Evidence: **captured** = capture `vr3` (20 of these messages); **static** =
`libvrlink_scene.so`, file offsets. The addresses themselves identify the
capture's network and are not reproduced here.

## 1. On the wire (**captured**)

- Element header `03 18`, `id = 0`, `index = 0`, `len = 179`.
- Sent every 2 s: 20 messages in 40 s, intervals 1.995..2.008 s, the first
  1.576 s after the client's first datagram (0.65 s after the first frame
  descriptor). None before video.
- It never has a datagram to itself: 16 times it led a datagram that also
  held a frame descriptor (`[3/0x18][5/0x02]`), 4 times it shared one with an
  audio message.
- All 20 payloads are byte-for-byte identical.
- The client sent nothing in response, then or later.

## 2. Payload

One leading byte, then variable-length records, each `u8 family`, `u8 n`,
`n` bytes. The lengths add up exactly: `1 + 3×27 + 70 + 27 = 179`.

| off | size | field | seen |
|---|---|---|---|
| 0 | u8 | version or flags | `01` |
| 1 | … | records | five |

Record header (**captured**; the split into two fields is the only reading
under which the records tile the payload):

| off | size | field |
|---|---|---|
| 0 | u8 | address family: `0` = IPv4, `1` = IPv6 |
| 1 | u8 | number of bytes that follow in this record: `0x19` (25) for IPv4, `0x44` (68) for IPv6 |

IPv4 record body, 25 bytes:

| off | size | field | seen |
|---|---|---|---|
| 0 | u16 **big-endian** | UDP port | `28 a0` = 10400 in every record |
| 2 | u8 | prefix length | 22, 24, 24, 20 |
| 3 | 4 | address, network byte order | first record: the address the session is connected to; the others: three more private addresses on other subnets |
| 7 | 8 | zero | |
| 15 | u32 | `32` | **inferred**: address width in bits |
| 19 | u16 | zero | |
| 21 | u32 | differs per address, constant for the session | 57,967; 762,673; 456,309; 3,991,686 — meaning unknown |

IPv6 record body, 68 bytes:

| off | size | field | seen |
|---|---|---|---|
| 0 | u16 big-endian | UDP port | 10400 |
| 2 | u8 | prefix length | 64 |
| 3 | 16 | address | a global `2001:0:…` address |
| 19 | 8 | zero | |
| 27 | u32 | `64` | the IPv6 counterpart of the IPv4 record's `32` |
| 31 | 12 | zero | |
| 43 | 8 | non-zero in its low five bytes, constant | meaning unknown |
| 51 | 8 | `28` | **inferred**: `sizeof(sockaddr_in6)`, which is 28 |
| 59 | 9 | `02` then zeros | unknown |

The port and address are in network byte order while the integers after them
are little-endian, which suggests the front of each record is copied out of a
socket address and the rest out of an interface-enumeration structure
(**inferred**). Field boundaries after the address are a best fit to one
host's data: only a host with different interfaces, or the same host after a
network change, can confirm them. The record order was: the interface the
session runs on, two other IPv4 interfaces, the IPv6 address, a fourth IPv4
interface.

Parsing sketch that reproduces the tiling:

```python
def parse_address_list(value):
    version, records, off = value[0], [], 1
    while off + 2 <= len(value):
        family, n = value[off], value[off + 1]
        body = value[off + 2: off + 2 + n]
        alen = 4 if family == 0 else 16
        port = int.from_bytes(body[0:2], "big")
        records.append((family, port, body[2], body[3:3 + alen], body[3 + alen:]))
        off += 2 + n
    return version, records
```

## 3. What the client does with it (**static**)

The client does nothing with it. The element reaches `SVLDataLink::ReceivedData` (+0x15a9b8) `case 3`,
which hands every class 3 element to `SVLRoot`'s vtable+0x28. That is
`QSVLClientXR::RXUnreliableStream` (+0xfab44), which tests only for type 0x0e;
it calls `QSVLClient::RXUnreliableStream` (+0xf5c00), which tests for 0x16 and
0x12; that calls `SVLRoot::RXUnreliableStream` (+0x164ae0), a switch with
cases 0x01, 0x07, 0x0d and 0x14 and no default. Type 0x18 falls through all
three and is dropped without a log line. No function that builds the message
was found either: a scan for an immediate move of `0x1803` (the way the
`0x0103`, `0x0703` and `0x1503` headers are built) finds none, though that
scan also misses the known writers of `0x1303` and `0x1703`, so it is weak
evidence. As far as this build shows, it has neither end of the message.

This fits the version gap already noted in `../svl-values/`: the host
announces protocol version 14 in its frame descriptors and this client was
built against 9. The message is newer than the client.

## 4. What it is for (**inferred**)

A periodic advertisement of every address and port the host can be reached
at, in the order "current first". Plausible uses in a newer client: moving
the session to another interface (the transport already tolerates the peer's
address changing — `connection-lifecycle.md` §2 — and has a sideband code for
"datagram from an unexpected address"), or telling the user whether the host
is wired. The 148-byte LAN-scanner reply (`lan-scanner.md`) is the other place
the host describes where it lives; whether the two share a layout is not
known.

For a new client: parse past it and ignore it. A client that logs it should
treat it as sensitive, since it lists the host's addresses on networks the
client may not otherwise see.

## Open questions

- The trailing fields of both record types (§2), and the leading byte.
- Whether a newer client build answers it or switches address on the strength
  of it. Needs a newer `libvrlink_scene.so`, or a probe that starts sending
  to one of the other listed addresses mid-session.
- Whether the host sends it from the start when it is already streaming (in
  `vr3` it began only after video did), and whether the list changes when an
  interface comes or goes.
- Whether the host expects anything back. vrlink sends nothing
  and streams normally for 40 s, so nothing is required.

## Purpose (from the project owner, not measured)

The list exists for interface switching on Valve's Steam Frame headset, which
has a dedicated 6 GHz radio (paired with a USB dongle on the PC) separate from
the one on ordinary Wi-Fi, and for direct wired streaming. If the interface in
use starts dropping packets, the headset can find another of the host's
addresses in this list that it can reach and move the stream there without
ending the session. That fits the host adopting the source address of whoever
sends it poses (see connection-lifecycle.md), and the `wifi_dongle_present` /
`connected_paired_network_hash` fields in the discovery Status. A client with
one network path can ignore the message.
