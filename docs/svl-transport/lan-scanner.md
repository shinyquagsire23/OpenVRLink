# VRLinkScanner — LAN discovery

Source: `VRLinkScanner::ScanThread` (`+0x153f2c`), probe constant at Ghidra
`0x1b05ad`. Everything on this page is **static**. Capture `vr3` is a *direct*
(already-paired) session and contains **no** discovery traffic (no class 9
element, 12-byte probe, 148-byte datagram, or non-session UDP traffic on port
10400) because the scanner never ran during that launch. (Klepton's discovery
findings in STEAMLINK.md §3.1 cover the **Steam Link Qt shell's IPv6**
discovery on port 27036, which is separate from `VRLinkScanner` in
`libvrlink_scene.so`.)

## Scan thread

`ScanThread` sets its thread name to `SVL_ScanThread` and loops while enabled
(`this[0x30]`), logging `[VRLinkScanner] Starting scan....`. On each pass, it:

1. Calls `GetIPAddresses()` to enumerate local interface `IPSet`s (base IP +
   CIDR prefix length), logging `[VRLinkScanner] Scanning %s/%d` for each.
2. Opens `socket(AF_INET, SOCK_DGRAM, 0)` and sets `setsockopt(SO_BROADCAST=6, 1)`.
3. Computes the subnet broadcast address from the base IP and prefix, sets
   destination **port 10400** (`sa_data` bytes `0x28,0xa0` = `htons(10400)`),
   and calls **`sendto` with a 12-byte probe** (`MSG_NOSIGNAL`).
4. Polls each socket (`poll`, 100 ms) and reads replies with `recvfrom`
   (`0x400`-byte buffer). A valid reply is **exactly 0x94 = 148 bytes**; any
   other length is ignored. Valid replies have their source IP formatted via
   `inet_ntop` and tracked in a seen-servers list with a **6-second**
   (5,999,999 µs) per-server timeout (logging `[VRLinkScanner] Found server: %s`
   and `[VRLinkScanner] Server %s timed out`).
5. Sleeps 1 s (`0x3b9aca00` ns) and repeats.

## Probe packet (12 bytes, `0x1b05ad`)

The 12-byte constant at `0x1b05ad` is `00 00 00 00  09 0a 00 00  00 00 00 00`,
which is a **clear-mode (mode 0) SVL datagram** (see `packet-format.md`) using
the standard element layout:

| off | bytes | meaning |
|-----|-------|---------|
| 0   | `00 00` | `seq` = 0 |
| 2   | `00 00` | `res` = 0 (mode-0 header ends here, 4 bytes) |
| 4   | `09 0a` | element `kind` = `0x0a09` → **channel 9 (broadcast), sub-type 0x0a** |
| 6   | `00 00` | element `seqid` = 0 |
| 8   | `00 00` | element `len` = 0 |
| 10  | `00 00` | element `field6` = 0 |

This encodes a single zero-length **kind-9 broadcast element** inside a mode-0
datagram. `vrlink` sends it to `<subnet-broadcast>:10400`, and a Steam host
replies with a 148-byte datagram whose body the scanner stores as the server's
connection info (`SVLRoot::CreateConnectionInfo` / `GetRequestedConnectionInfo`,
`+0x164f7c` / `+0x164f0c`).

## Open questions / to confirm on the wire

- Capturing a live discovery exchange to confirm the 12-byte probe byte-for-byte
  and decode the **148-byte** reply layout (which `CreateConnectionInfo`
  consumes).
- Whether the 148-byte reply uses mode 0 (clear) or carries an 8-byte session
  header.
- How discovered server info feeds into direct-session setup (`SetPairAddress`
  at `+0x15caa8` only stores a printable peer label of up to 47 characters at
  `this+0xc2` — **static**).
- Whether the 148-byte reply shares structure with the 179-byte host address
  list sent during an active session (`host-address-list.md`), since both
  advertise reachable host addresses.
- What triggers `VRLinkScanner` in `vrlink`, since sessions launched via the
  Steam Link shell's `sArgs` handoff skip it.
