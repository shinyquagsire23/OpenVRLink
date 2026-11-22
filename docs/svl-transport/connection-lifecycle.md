# Connection lifecycle: socket, handshake, keepalive, teardown

Source: `SVLDataLinkUDP::Reconnect` (`+0x1677a8`), `RXThread` (`+0x16709c`),
`InternalTX` (`+0x167fbc`), `XMITData` (`+0x1683f8`), `HandleSidebandPacket`
(`+0x167688`), ctor (`+0x1669d0`), `HandleStreamIsActiveEvent` (`+0x166e48`),
`HandleStreamIsInactiveEvent` (`+0x167060`), `ChangeQoSState` (`+0x1685a0`), and
`PrepareForPossibleShutdown` (`+0x168608`). Claims are **static** unless marked
otherwise; **captured** refers to capture `vr3`, whose log interleaves traced
socket calls from Klepton with `vrlink`'s own log lines.

## 1. Socket setup (`Reconnect`, client path `this[0x44] == 0`)

```python
fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)   # socket(2, 2, 17)
# SO_RCVTIMEO: {tv_sec=0, tv_usec=rcv_timeout}; default 10000 us (10 ms),
#   or host-supplied *(SVLRoot+0x178) if in 0x3e9..0xf423f range
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO=0x14, timeval)
# dest = host:10400  (this+0x240 = sockaddr_in; 0xa0280002 = fam 2, port 0x28a0)
dst.sin_family = AF_INET; dst.sin_port = htons(10400); dst.sin_addr = inet_addr(host)
setsockopt(fd, SOL_SOCKET, SO_RCVBUF=8, 0x1800000)   # 24 MiB request
# optional SO_BINDTODEVICE (0x19) to an interface name; optional local bind
if local_bind_port: bind(fd, local)                  # this+0x230, if set
connect(fd, dst, 16)                                 # CONNECTED udp socket
getsockname(fd, this+0x230)                          # record local addr
# IP_TOS = 0xff  (QoS/DSCP marking), only when this[0xc0] set
setsockopt(fd, IPPROTO_IP=0, IP_TOS=1, 0xff, 4); getsockopt(...)   # logs "Changing tos opt = %d"
start_thread(RXThread)
```

Socket details:
- The transport uses **IPv4 only** (`AF_INET`). IPv6 host discovery runs in the
  Steam Link Qt shell (Klepton §3.1), which hands a resolved IPv4 host address
  to `vrlink`.
- Even though the socket is **`connect()`ed**, `InternalTX` calls
  `sendto(fd, buf, len, MSG_NOSIGNAL, dst, 16)` with an explicit destination
  for each datagram (the BSD `EISCONN` divergence fixed in Klepton).
- Both `SO_RCVBUF` and `SO_SNDBUF` request `0x1800000` (**24 MiB**), logging
  only `"warning: could not set socket buffer size"` if `setsockopt` fails.
  (The `SO_SNDBUF=7` call sits in the `this[0x44] != 0` host/relay branch,
  which also sets `SO_REUSEADDR` and scans up to 100 ports to bind.)
- Both send and receive calls pass `MSG_NOSIGNAL` (`0x4000`).

In capture `vr3` (**captured**), `vrlink` calls `socket(AF_INET, SOCK_DGRAM, 17)`,
requests a 25,165,824-byte `SO_RCVBUF` (which macOS under Klepton clamps
harmlessly), calls `connect` to port 10400, and then runs
`recvfrom(fd, 2084 B, flags 0x4000)` and `sendto(..., flags 0x4000, <dest>)`.
The initial socket skips `bind` and logs no `"Changing tos opt"` line because
QoS marking starts disabled.

### 1.1 QoS socket replacement at startup (**captured**)

The host's second datagram carries value-transport ID `0x29 = 1`
(`../svl-values/vte-id-table.md`: QoS enabled). `vrlink` immediately calls
`ChangeQoSState(true)`, triggering a full `Reconnect`:

```
SVLDataLinkUDP::Disconnect()
SVLDataLinkUDP::RXThread() Cleaned up
socket(AF_INET, SOCK_DGRAM, 17)            # new socket
bind(fd, <same local address and port as before>)
connect(fd, <host>:10400)
Changing tos opt = 255
SVLDataLinkUDP::Reconnect() Joining Thread … / Join Complete / Thread Create Complete
```

This replacement completes between the host datagram received at 3.9 ms and the
client's third datagram at 4.4 ms, taking under 0.5 ms with zero lost
datagrams: client `seq` continues seamlessly (0 and 1 on the first socket, then
2 on the new socket) and host datagrams 5, 6, 7… all arrive. This confirms
three details from the static code: the local-bind branch in `Reconnect`
preserves the client's source port across a socket replacement, `IP_TOS = 0xff`
is applied only after the host enables QoS, and the host enables QoS in its
first value burst. A client that never sets `IP_TOS` still streams normally
(see the probe results below).

## 2. Initial packet exchange (CAPTURED)

**Port 10400 has no UDP-level handshake.** Because the session is already
authorized by the token obtained over UDP 27036 (carrying the XOR0
`session_id`), `vrlink` **starts streaming immediately**. Capture `vr3` records
the socket from its very first transmitted datagram and shows no preceding
class 9 element, connection-info exchange, or 12-byte control frame. All times
below are in seconds after the client's first datagram (**captured**):

| time | direction | event |
|---|---|---|
| 0.0000 | C→H | `seq 0`, 736 B: `[4/0x0f frame report, 24][3/0x01 pose + value transport, 688]`. A second 779 B datagram with the same element types follows 0.2 ms later; these come from the two `SendPoses(0, 0)` calls during client init |
| 0.0038 | H→C | host's first datagram (`seq 5`): `[3/0x0d]` acking the client's initial value chunks and carrying the host's first values. A second `[3/0x0d]` datagram follows 0.16 ms later |
| 0.0039–0.0044 | C | `vrlink` replaces its socket to enable `IP_TOS` (§1.1) |
| 0.0044 | C→H | `seq 2`: from here onward every datagram is `[3/0x07][4/0x0f][3/0x01]`, one per pose tick (~2.1 ms apart) |
| 0.0231–0.0417 | H→C | four more `[3/0x0d]` datagrams (six total from the host before video begins) |
| 0.2086 | H→C | `[8/0x06]` `[SVLS] ResetVideoStream` |
| 0.9262 | H→C | first frame descriptor (frame 0, group 0), immediately followed by video packets |
| 0.9299 | C→H | client datagrams gain a leading `[3/0x11]` eye element and poses begin reporting a non-zero clock offset |
| 1.0372 | H→C | closing descriptor of frame 0, followed by an initial burst of 12,654 datagrams (13.1 MB) in the first second of video versus ~1,200 datagrams/s afterward |
| 1.576 | H→C | first `[3/0x18]` host address list, then one every 2 s |
| 1.855 | H→C | first audio packet |

During a healthy cold start, both sides exchange values within 42 ms, the host
sends one `ResetVideoStream` text event during a 0.88 s gap, and video begins
at 0.93 s. The contents of that initial 42 ms value exchange are documented in
`../svl-values/startup-exchange.md`.

Both endpoints seed the XOR0 checksum with the **same** `session_id`. A packet
with a mismatched ID is dropped (`"received packet with invalid session ID"`)
and answered with a 12-byte sideband NAK (none occurred in `vr3`).

Host-side peer adoption is visible in the shared transport code (**static**;
the host role sets `this+0x44`). While the link is not marked active
(`this+0xac == 0`), the first class 3 element of type `0x01` or `0x07` calls
`HandleStreamIsActiveEvent` (`+0x166e48`), which copies the datagram's source
address into the peer address (`this+0x240`), records it with `SetPairAddress`,
and marks the link active. Receiving a datagram from the same IP on a different
port, or experiencing more than 3 s of silence followed by a datagram from
another IP, calls `HandleStreamIsInactiveEvent` (`+0x167060`), clearing the
peer address so the next valid pose or values packet is adopted. Rather than
maintaining an explicit connection handshake, the host simply streams to
whichever endpoint last sent it a valid pose or values message. **Inferred**
(host binaries were not read): this explains why a second client, or the same
client rebinding to a new port, immediately takes over an active host session
in probe tests. Neither handler resets the receive sequence tracker — see
`reliable-stream.md` §3.

The `XMITData` pre-connect gate (`dVar1 == 9` allowed before `this+0x1f8`) and
`SVLRoot::CreateConnectionInfo` belong to the **LAN-discovery** path rather
than direct session startup.

## 3. Keepalive / NAK (12-byte sideband)

`HandleSidebandPacket` (`+0x167688`) and the RX stale-link branches emit the
12-byte `[magic=0x459b4c34][code][0]` control frame (`packet-format.md`),
rate-limited to **at most once per 500 ms** (`GetCurrentTimestamp` delta ≥
499,999 µs at `this+0x2bc`). Observed codes are `0x10` and `0x11` (reject /
invalid-session-ID NAKs) and `0x13` (stale-link or address-change probe).
Incoming 12-byte frames whose first word matches the local magic invoke a
handler at vtable+0x90. This is the only dedicated liveness signaling in the
transport; normal data traffic also keeps the link active by updating the last-RX
timestamp at `this+0xb0`.

Capture `vr3` (**captured**) contains no sideband frames in either direction
and no dedicated keepalive packets across 40 s. Because `vrlink` transmits a
datagram on every pose tick regardless of motion (433/s, with a maximum
inter-packet gap of 68.6 ms during startup and 9.5 ms afterward) and the host
transmits continuously once video starts, regular traffic keeps the session
alive. The only fixed-period message on the wire is the host's 2 s address list
(`host-address-list.md`).

## 4. Timeouts and the TX failure streak

- On **RX timeout** (`recvfrom` returning ≤0 when `SO_RCVTIMEO` expires),
  `RXThread` calls `SVLDataLink::ReceiveTimedOut`. If the link remains idle for
  more than 3 s (`lVar10 - this+0xb0 > 3000000`), it invokes the reset path at
  vtable+0x68.
- In `InternalTX` (`+0x167fbc`), each `sendto` call that fails to write the
  full length retries up to ~10 times (spinning via `SVLSpinwait(100)` between
  tries while `10 - this+0x22c < i`), logs `sendto error %d (return value: %d)`
  at most once per second, and calls `SVLDataLink::ReportTXFailures(1)`. When
  the **TX failure streak** counter at `this+0x22c` exceeds `0x31` (49), the
  client logs **`TX Failure Streak Hit %d; Aborting and reconnecting.`**, sets
  `this+0x1fa = 1`, and reconnects (Klepton observed `"Hit 51"`). `XMITData`
  enforces an earlier guard before the link comes up, logging `Early TX Failure
  Streak Hit %d; Aborting and reconnecting.` after 200 failed submits.

## 5. Rate pacing

Before each `sendto`, `InternalTX` runs a token-bucket pacer controlled by
`*(this+8)` (the `gLimitMBPS` float updated in `SVLDataLink::Tick`; Klepton
SL-23). When `gLimitMBPS > 0`, it accumulates byte budget (`this+0x220`) from
the inter-send interval and calls `usleep` to cap uplink bandwidth at the
host-supplied limit. When `gLimitMBPS == 0`, pacing is skipped. This is the
only client-side uplink rate limiter.

## 6. Reconnect / teardown

`Reconnect` (`+0x1677a8`) performs an idempotent socket reset: it logs
`SVLDataLinkUDP::Disconnect()`, clears the running flag (`this+0x260 = 0`),
calls `shutdown(fd, SHUT_RDWR)` and `close(fd)`, joins the old RX thread
(`"Joining Thread %p"` / `"Join Complete"`), recreates the socket, and starts a
new RX thread (`"Thread Create Complete"`). This sequence occurs once in `vr3`
(**captured**, §1.1).

### Teardown datagram (**static**; not in `vr3`)

`PrepareForPossibleShutdown` (`+0x168608`, link vtable+0x88) pre-builds a
single teardown datagram and stores it alongside the peer and local addresses
in a static closure (`SVLDataLink::SetPostTeardownShutdown`):

| part | bytes (mode 1) |
|---|---|
| header | `seq = 0xffff`, `res = 0`, XOR0 checksum computed as usual |
| element | `class 3`, `type 0x13`, `id 0`, `len 0`, `index 0` (stored as the 64-bit constant `0x1303`) |

The packet totals 16 bytes in mode 1 (12 bytes in mode 0, or padded to 32 bytes
and encrypted in mode 2 with tag word `0x02ffffff`). Its fixed `seq = 0xffff`
is independent of the normal datagram sequence counter.

`SVLDataLink::SendPostTeardownShutdown` (`+0x15c920`), called from
`XrSceneStream::~XrSceneStream`, runs that closure if it was armed less than
10 s earlier: it logs `SVLDataLink::SendPostTeardownShutdown() attempting
shutdown message`, opens a **new** UDP socket (`SVLDataLinkUDP -> Post Shutdown
Sock: %d`), binds to the previous local address if it had a nonzero port,
connects to the peer, and transmits the datagram **five times, 100 ms apart**
(`SVLDataLinkUDP -> Sending: %d`).

Type `0x13` is the client's shutdown notification (**inferred**), serving as
the counterpart to the host's type `0x0e` `SYST_SERVER_SHUTDOWN`; `vrlink` has
no receive handler for incoming `0x13` elements. Capture `vr3` ends without a
teardown datagram because the client process was killed by a timeout mid-stream:
its final packet is an ordinary pose datagram (`seq 17445`), the host was still
sending video 1 ms earlier, and no `3/0x13`, `seq 0xffff`, `3/0x0e`, or
sideband frame appears.

### Host behavior on client disconnect

Host disconnect behavior (**captured** in `driver_vrlink.txt` across four
12–14 s probe sessions on an earlier host build):

- When client datagrams stop, the host logs `Connection inactive at <seconds>`,
  and 30 s later logs `Connection inactive for 30.1 > 30 seconds. Sending quit
  event.`, shutting down SteamVR. This occurred consistently across runs.
- On that earlier host build, the teardown datagram did not shorten the 30 s
  timeout. When sent validly (five times, 100 ms apart; in mode 2 with tag word
  `0x02ffffff`), the host logged `"inactive"` within ~1 s, versus ~3 s when the
  datagram was malformed (mode 2 using an ordinary sequence word) and the host
  timed out on silence alone — indicating the host recognized the teardown
  packet as a disconnect but still ran its 30 s quit timer.
- Sending `DeviceStreamingCancelRequest` for the session's request ID on port
  27036 after teardown had no additional effect.
- In `vrlink` 2.0.25 (**static**), this `3/0x13` teardown datagram is the only
  shutdown packet the VR client sends.

Against a protocol-version-14 host (**captured** in `vrserver.txt`), the
teardown datagram quits SteamVR immediately:

- The host acts on the teardown datagram immediately, logging `Client sent
  SYST_CLIENT_SHUTDOWN` followed by `Sending quit event because SteamVR launched
  for streaming and client has quit.`, closing SteamVR and the running VR
  application within 2 s.
- A client that stops sending without a teardown packet triggers the inactivity
  timer: `Connection inactive at <seconds>`, followed after 30 s
  (`driver_vrlink.wirelessShutdownTimeout`) by either `Sending quit event.` or,
  while a scene application is running, `Waiting to quit for scene app
  steam.app.<id>.` In that state, the host waited 80 s and 59 s across two
  sessions before sending the quit event, and in a third session a client
  reconnected after 64 s (`Connection active at …`) and resumed the existing
  SteamVR session.

Because `3/0x13` quits SteamVR immediately on current hosts, a client that may
reconnect (for example, when the headset is removed or backgrounded) should
omit it. The OpenVRLink client sends the teardown datagram only when the user
explicitly ends the session.

The same host log shows the server calling its own `PrepareForPossibleShutdown`
during shutdown (**captured**), confirming that the teardown mechanism exists
in both directions.

## Open questions / to confirm on the wire

Capture `vr3` settled several earlier questions: the initial client datagram
and host reply use standard stream classes with no class 9 handshake (§2),
neither side sends dedicated keepalives and the client is never idle (§3), the
client replaces its socket once while keeping its local port to set
`IP_TOS = 255` after the host enables QoS (§1.1), and cold-start phase timings
are measured (§2).

Remaining open questions:
- Capturing `vrlink`'s own transmitted teardown datagram on the wire (host
  handling of OpenVRLink's teardown packet is documented above).
- Tracing which call sites invoke `PrepareForPossibleShutdown` to arm the
  teardown closure.
- Determining the effective `SO_RCVTIMEO` value chosen at runtime
  (host-supplied versus the 10 ms default, since `vr3` omits that `setsockopt`)
  and the actual socket buffer sizes granted on Android hardware.
- Whether the host inspects or reacts to the client's `IP_TOS` marking.
- How the host responds if the client's very first datagram has an invalid
  session ID.

## Probe results

The Python probe opened a session with no handshake: its first datagram was
`[3/0x07 values][4/0x0f frame report][3/0x01 pose + value transport]` sent from
an unbound, connected UDP socket with default socket options (no `IP_TOS`,
8 MiB receive buffer), and the host answered within 1 s. The probe exchanged
37,842 datagrams over 20 s with every checksum valid (**captured** by probe).

## Client results: concurrent clients with the same device ID

When two instances of the Swift client accidentally streamed from the same host
at the same time using the same device identity, each requested its own session
and both subsequently received only 1–2 complete frames per second, thousands
of retransmit requests, and continuous audio loss (**captured** by client).
This matches the static analysis of host-side peer adoption: the host maintains
a single stream and directs packets to whichever client endpoint it most
recently adopted. Severe frame starvation and retransmit storms on a clean LAN
can therefore indicate a second client instance competing for the same host.
