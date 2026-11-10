# VRLinkScanner — LAN discovery

Source: `VRLinkScanner::ScanThread` (`+0x153f2c`), probe constant at Ghidra
`0x1b05ad`. All **static** — capture `vr3` is a *direct* (already-paired)
session and contains **no** discovery traffic: no class 9 element, no 12-byte
probe, no 148-byte datagram, and no UDP traffic to port 10400 other than the
session itself. The scanner did not run in that launch, so none of this is
captured yet. (Note:
Klepton's own discovery findings in STEAMLINK.md §3.1 are about the **Qt shell's
IPv6** discovery on port 27036, which is a *different* mechanism from this
`libvrlink_scene` scanner.)

## Thread

`ScanThread` names itself `SVL_ScanThread` and loops while enabled
(`this[0x30]`), logging `[VRLinkScanner] Starting scan....`. Each pass:

1. `GetIPAddresses()` → a list of local interface `IPSet`s (base IP + CIDR
   prefix length). For each, logs `[VRLinkScanner] Scanning %s/%d`.
2. `socket(AF_INET, SOCK_DGRAM, 0)`, `setsockopt(SO_BROADCAST=6, 1)`.
3. Compute the subnet broadcast address from the base IP and prefix, set
   destination **port 10400** (`sa_data` bytes `0x28,0xa0` = `htons(10400)`),
   and **`sendto` a 12-byte probe** (`MSG_NOSIGNAL`).
4. `poll` each socket (100 ms) and `recvfrom` (0x400 buf). A valid reply is
   **exactly 0x94 = 148 bytes**; anything else is ignored. The source IP is
   `inet_ntop`'d and tracked in a "seen servers" list, with a **6-second**
   (5 999 999 µs) timeout per server (logs `[VRLinkScanner] Found server: %s`
   and `[VRLinkScanner] Server %s timed out`).
5. Sleep 1 s (`0x3b9aca00` ns) and repeat.

## The probe (12 bytes, `0x1b05ad`)

Raw bytes: `00 00 00 00  09 0a 00 00  00 00 00 00`. This is a **clear-mode
(mode 0) SVL datagram** (see `packet-format.md`) that uses the ordinary layout:

| off | bytes | meaning |
|-----|-------|---------|
| 0   | `00 00` | `seq` = 0 |
| 2   | `00 00` | `res` = 0 (mode‑0 header ends here, 4 bytes) |
| 4   | `09 0a` | element `kind` = `0x0a09` → **channel 9 (broadcast), sub-type 0x0a** |
| 6   | `00 00` | element `seqid` = 0 |
| 8   | `00 00` | element `len` = 0 |
| 10  | `00 00` | element `field6` = 0 |

i.e. a single zero-length **kind‑9 broadcast element** in a mode‑0 datagram. The
client sends this to `<subnet-broadcast>:10400`; a Steam host replies with a
148-byte datagram whose body the scanner stores as the server's info
(`SVLRoot::CreateConnectionInfo` / `GetRequestedConnectionInfo`,
`+0x164f7c`/`+0x164f0c`).

## Open questions / to confirm on the wire

- Capture a discovery exchange and confirm the 12-byte probe byte-for-byte and
  the **148-byte** reply layout (it is the connection-info the direct-session
  opener presumably mirrors).
- Does the reply itself use mode 0 (clear) or carry a session tag? The probe is
  clear; the reply length (148) is fixed regardless.
- How the discovered server info feeds the direct-session setup.
  (`SetPairAddress` `+0x15caa8` is not it: it only stores a printable peer
  label of up to 47 characters at `this+0xc2` — **static**.)
- Whether the 148-byte reply is related to the 179-byte address list the host
  sends during a session (`host-address-list.md`); both describe where the
  host can be reached.
- What makes the client run the scanner at all. A session started from the
  shell's handoff (`sArgs`) does not.
