# Host address list (class 3, type 0x18)

Class 3, type 0x18 is a host→client message on the unreliable stream that
advertises the host's network interface addresses. Among all message types seen
in capture `vr3`, `vrlink` has no receive handler for type 0x18.

Claims marked **captured** come from capture `vr3` (20 instances), and
**static** claims come from `libvrlink_scene.so` file offsets. Specific IP
addresses from the capture network are omitted here.

## 1. Wire behavior (**captured**)

- Each message has element header `03 18`, `id = 0`, `index = 0`, and `len = 179`.
- The host sends one every 2 s (20 messages over 40 s at 1.995..2.008 s
  intervals), starting 1.576 s after the client's first datagram (0.65 s after
  the first frame descriptor); none appear before video starts.
- Every instance shared a datagram with another element rather than traveling
  alone: 16 preceded a frame descriptor (`[3/0x18][5/0x02]`) and 4 shared a
  datagram with an audio message.
- All 20 payloads in `vr3` are byte-for-byte identical.
- `vrlink` sent no response to any of them.

## 2. Payload layout

The payload starts with one version/flags byte followed by variable-length
records, each framed as `u8 family`, `u8 n`, and `n` body bytes. The record
lengths sum to the full payload size: `1 + 3×27 + 70 + 27 = 179`.

| off | size | field | seen |
|---|---|---|---|
| 0 | u8 | version or flags | `01` |
| 1 | … | records | five |

Record header (**captured**; splitting the two leading bytes into `family` and
`n` tiles the entire 179-byte payload with zero remainder):

| off | size | field |
|---|---|---|
| 0 | u8 | address family: `0` = IPv4, `1` = IPv6 |
| 1 | u8 | byte count of this record's body: `0x19` (25) for IPv4, `0x44` (68) for IPv6 |

IPv4 record body, 25 bytes:

| off | size | field | seen |
|---|---|---|---|
| 0 | u16 **big-endian** | UDP port | `28 a0` = 10400 in every record |
| 2 | u8 | prefix length | 22, 24, 24, 20 |
| 3 | 4 | IPv4 address, network byte order | first record: active session interface; remaining three: private addresses on other subnets |
| 7 | 8 | zero | |
| 15 | u32 | `32` | **inferred**: address width in bits |
| 19 | u16 | zero | |
| 21 | u32 | differs per address, constant across the session | 57,967; 762,673; 456,309; 3,991,686 — meaning unknown |

IPv6 record body, 68 bytes:

| off | size | field | seen |
|---|---|---|---|
| 0 | u16 big-endian | UDP port | 10400 |
| 2 | u8 | prefix length | 64 |
| 3 | 16 | IPv6 address | a global `2001:0:…` address |
| 19 | 8 | zero | |
| 27 | u32 | `64` | IPv6 counterpart to the IPv4 record's `32` |
| 31 | 12 | zero | |
| 43 | 8 | non-zero in its low five bytes, constant | meaning unknown |
| 51 | 8 | `28` | **inferred**: `sizeof(sockaddr_in6)` (28) |
| 59 | 9 | `02` then zeros | unknown |

The port and IP address use network byte order while the trailing integers are
little-endian, suggesting the start of each record is copied from a socket
address struct and the remainder from an interface-enumeration struct
(**inferred**). Field boundaries after the IP address are inferred from a
single host's data and need confirmation against another host or a network
change. In `vr3`, the records appeared in order: the active session's IPv4
interface, two other IPv4 interfaces, the IPv6 address, and a fourth IPv4
interface.

The following parser matches the captured layout:

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

## 3. Client handling (**static**)

`vrlink` ignores type 0x18 completely. The element reaches
`SVLDataLink::ReceivedData` (`+0x15a9b8`) `case 3`, which forwards every class 3
element to `SVLRoot` vtable+0x28 (`QSVLClientXR::RXUnreliableStream`,
`+0xfab44`). That method checks only for type 0x0e before calling
`QSVLClient::RXUnreliableStream` (`+0xf5c00`), which checks for 0x16 and 0x12
before calling `SVLRoot::RXUnreliableStream` (`+0x164ae0`), whose `switch`
covers cases 0x01, 0x07, 0x0d, and 0x14 with no `default`. Type 0x18 falls
through all three handlers and is silently dropped. A binary scan for an
immediate move of `0x1803` (matching how `0x0103`, `0x0703`, and `0x1503`
headers are constructed) also finds no sender, though that heuristic misses the
known writers of `0x1303` and `0x1703`; regardless, this build of
`libvrlink_scene.so` neither parses nor constructs type 0x18.

This matches the protocol version gap noted in `../svl-values/`: the host
advertises protocol version 14 in its frame descriptors, whereas this `vrlink`
build targets version 9, predating type 0x18.

## 4. Inferred purpose (**inferred**)

Type 0x18 periodically advertises every IP address and port where the host is
reachable, listing the active session interface first. Newer clients could use
this list to migrate an active session to another interface (the transport
already tolerates peer address changes in `connection-lifecycle.md` §2 and
defines a sideband code for packets from unexpected addresses) or to report
whether the host is on a wired connection. Whether this payload shares a layout
with the 148-byte LAN-scanner reply (`lan-scanner.md`) is unknown.

Clients with a single network path can skip past type 0x18 and ignore it. Any
client that logs raw traffic should treat type 0x18 as sensitive because it
exposes all of the host's local and global IP addresses.

## Open questions

- Meaning of the leading byte and the trailing fields in both record types (§2).
- Whether a newer `vrlink` build responds to type 0x18 or switches interfaces
  using it, which can be tested with a newer `libvrlink_scene.so` or by sending
  traffic to another listed address mid-session.
- Whether the host sends type 0x18 immediately when joining an already-active
  stream (in `vr3` it started only after video began), and whether the list
  updates dynamically when host interfaces come up or go down.
- Whether the host ever expects a client reply (`vrlink` sends none and streams
  normally for 40 s).

## Purpose (from the project owner, not measured)

This message supports interface switching on Valve's Steam Frame headset, which
has a dedicated 6 GHz radio (paired with a PC USB dongle) separate from its
standard Wi-Fi radio, as well as direct wired streaming. If the active
interface starts dropping packets, the headset can pick another reachable host
address from this list and move the stream there without ending the session.
That matches the host adopting the source address of incoming pose packets (see
`connection-lifecycle.md`) and the `wifi_dongle_present` /
`connected_paired_network_hash` fields in the discovery `Status` protobuf. A
client with a single network path can ignore this message.
