# Connection lifecycle: socket, handshake, keepalive, teardown

Source: `SVLDataLinkUDP::Reconnect` (`+0x1677a8`), `RXThread` (`+0x16709c`),
`InternalTX` (`+0x167fbc`), `XMITData` (`+0x1683f8`), `HandleSidebandPacket`
(`+0x167688`), ctor (`+0x1669d0`), `HandleStreamIsActiveEvent` (`+0x166e48`),
`HandleStreamIsInactiveEvent` (`+0x167060`), `ChangeQoSState` (`+0x1685a0`),
`PrepareForPossibleShutdown` (`+0x168608`). **Static** unless marked;
**captured** means capture `vr3`, whose log interleaves the socket calls
Klepton traced with the client's own log lines.

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

Notes:
- **IPv4 only** here (`AF_INET`). Host *discovery* is IPv6 and lives in the Qt
  shell, not this transport (Klepton §3.1); the VR transport is handed a
  resolved v4 host and connects to it.
- The socket is **`connect()`ed**, yet `InternalTX` still calls
  `sendto(fd, buf, len, MSG_NOSIGNAL, dst, 16)` with an explicit destination
  each datagram (this is the BSD `EISCONN` divergence Klepton SL-fixed).
- `SO_RCVBUF`/`SO_SNDBUF` both request `0x1800000` = **24 MiB**; on failure only
  "warning: could not set socket buffer size". (The `SO_SNDBUF=7` path is taken
  in the alternate *bind-a-range* branch, `this[0x44] != 0`, which also sets
  `SO_REUSEADDR` and scans up to 100 ports — that is the host/relay side, not
  the client.)
- `MSG_NOSIGNAL` is `0x4000` on both send and recv calls.

**Captured** (`vr3`): `socket(AF_INET, SOCK_DGRAM, 17)`, an `SO_RCVBUF` request
of 25,165,824 bytes (which macOS under Klepton clamped — the failure is
harmless, as the code says), `connect` to port 10400, then
`recvfrom(fd, 2084 B, flags 0x4000)` and `sendto(..., flags 0x4000, <dest>)`.
No `bind` on this first socket, and no "Changing tos opt" line: the first
socket has no QoS marking.

### 1.1 The socket is replaced once, a few milliseconds in (**captured**)

The host's second datagram carries value-transport id 0x29 = 1
(`../svl-values/vte-id-table.md`: QoS on). The client acts on it at once
(`ChangeQoSState(true)`), and the log shows a full `Reconnect`:

```
SVLDataLinkUDP::Disconnect()
SVLDataLinkUDP::RXThread() Cleaned up
socket(AF_INET, SOCK_DGRAM, 17)            # new socket
bind(fd, <same local address and port as before>)
connect(fd, <host>:10400)
Changing tos opt = 255
SVLDataLinkUDP::Reconnect() Joining Thread … / Join Complete / Thread Create Complete
```

This sits between the host datagram received at 3.9 ms and the client's
third datagram at 4.4 ms after the session's first, so it costs under half a
millisecond and no datagram: the client's `seq` continues (0, 1, then 2 on the
new socket) and the host's datagrams 5, 6, 7… all arrive. It confirms three
things the static reading only suggested: the local-bind branch of `Reconnect`
exists to keep the source port across a reconnect; `IP_TOS = 0xff` is applied
only when the host has turned QoS on; and the host turns it on in its first
burst of values. A client that never applies the TOS marking still streams
(see the probe results below).

## 2. Handshake — the first packets (CAPTURED)

**There is no UDP-level handshake on port 10400.** The session is already
authorized by the token (the XOR0 `session_id`, obtained on UDP 27036). The
client simply **starts streaming**, and `vr3` — which is complete from the
first datagram the socket ever sent — shows nothing before it: no class 9
element, no connection-info exchange, no 12-byte frame. Times are seconds
after the client's first datagram; all **captured**:

| time | direction | what |
|---|---|---|
| 0.0000 | C→H | `seq 0`, 736 B: `[4/0x0f frame report, 24][3/0x01 pose + value transport, 688]`. A second like it (779 B) 0.2 ms later. These are the two `SendPoses(0, 0)` calls of client init |
| 0.0038 | H→C | the host's first datagram (`seq 5`): `[3/0x0d]` acking the client's first value chunks and carrying the host's first values. A second follows 0.16 ms later |
| 0.0039–0.0044 | C | the client replaces its socket (§1.1) |
| 0.0044 | C→H | `seq 2`: from here every datagram is `[3/0x07][4/0x0f][3/0x01]`, one per pose tick (about 2.1 ms apart) |
| 0.0231–0.0417 | H→C | four more `[3/0x0d]` datagrams. These six are the only ones the host sends before video |
| 0.2086 | H→C | `[8/0x06]` `[SVLS] ResetVideoStream` |
| 0.9262 | H→C | first frame descriptor (frame 0, group 0), immediately followed by video packets |
| 0.9299 | C→H | the client's datagrams gain a leading `[3/0x11]` eye element and its poses start carrying a non-zero clock offset |
| 1.0372 | H→C | closing descriptor of frame 0; then a burst — 12,654 datagrams (13.1 MB) in the second after video started, against about 1,200 per second afterwards |
| 1.576 | H→C | first `[3/0x18]` host address list, then one every 2 s |
| 1.855 | H→C | first audio |

So a healthy cold start is: values exchanged within 42 ms, then 0.88 s in
which the host sends one text event and nothing else, then video. What the two
sides say to each other in those first 42 ms is in
`../svl-values/startup-exchange.md`.

Both sides seed the XOR0 checksum with the **same** `session_id`. A wrong id
would be dropped ("received packet with invalid session ID") and answered by
a 12-byte sideband NAK (not observed — every datagram was valid).

How the *host* side accepts a client is visible in the shared code
(**static**; the role flag is `this+0x44`, set on the host): while the link is
not marked active (`this+0xac == 0`), the first class 3 element of type 0x01
or 0x07 calls `HandleStreamIsActiveEvent` (`+0x166e48`), which copies the
datagram's source address into the peer address (`this+0x240`), records it
with `SetPairAddress`, and marks the link active. A datagram from the same IP
but a different port, or silence for more than 3 s followed by a datagram from
another IP, calls `HandleStreamIsInactiveEvent` (`+0x167060`), which clears the
peer address so the next pose or values message is adopted again. That is the
whole "connection": the host follows whoever last sent it a valid pose or
values message. **Inferred** (host binaries are not read): this is why a
second client, or the same client from a new port, takes over a warm host
without ceremony, as the probe found. Neither function touches the receive
sequence tracker — see `reliable-stream.md` §3.

The `XMITData` pre-connect gate (`dVar1 == 9` allowed before `this+0x1f8`) and
`SVLRoot::CreateConnectionInfo` are the **LAN-discovery** path, not the
direct-session opener.

## 3. Keepalive / NAK (12-byte sideband)

`HandleSidebandPacket` (`+0x167688`) and the RX stale-link branches emit the
12-byte `[magic=0x459b4c34][code][0]` control frame (see `packet-format.md`),
**at most once per 500 ms** (`GetCurrentTimestamp` delta ≥ 499999 µs,
`this+0x2bc`). Codes: `0x10`, `0x11` (reject/wrong-id NAKs), `0x13` (stale /
address-change probe). Incoming 12-byte frames whose first word matches the
local magic drive a handler (vtable+0x90). This is the only liveness signaling
in the code; normal data also implicitly keeps the link fresh (RX updates
`this+0xb0`).

**Captured** (`vr3`): no sideband frame in either direction in 40 s, and no
dedicated keepalive of any kind. None is needed: the client sends a datagram
every pose tick whether or not anything has changed (433 per second; the
longest gap between two client datagrams after startup was 9.5 ms, and 68.6 ms
during startup), and the host is never silent for long once video runs. The
only fixed-period message is the host's 2-second address list
(`host-address-list.md`).

## 4. Timeouts and the TX failure streak

- **RX timeout:** `recvfrom` returns ≤0 on `SO_RCVTIMEO` expiry →
  `SVLDataLink::ReceiveTimedOut`. A link idle > 3 s (`lVar10 - this+0xb0 >
  3000000`) triggers a reset path (vtable+0x68).
- **TX failure streak** (`InternalTX` `+0x167fbc`): each `sendto` that doesn't
  write the full length retries up to ~10 times (spin `SVLSpinwait(100)` between
  tries, `10 - this+0x22c < i`), logs `sendto error %d (return value: %d)` at
  most once/sec, and calls `SVLDataLink::ReportTXFailures(1)`. `this+0x22c` is
  the streak counter; when it exceeds `0x31` (49) the client logs
  **`TX Failure Streak Hit %d; Aborting and reconnecting.`**, sets
  `this+0x1fa = 1`, and bails to reconnect. (Klepton observed "Hit 51".)
  `XMITData` has an earlier guard: 200 failed submits before the link is up →
  `Early TX Failure Streak Hit %d; Aborting and reconnecting.`

## 5. Rate pacing

Before each `sendto`, `InternalTX` runs a token-bucket pacer keyed on
`*(this+8)` (the `gLimitMBPS` float from `SVLDataLink::Tick`; Klepton SL-23).
If `gLimitMBPS > 0` it accumulates a budget
(`this+0x220`) from the inter-send interval and `usleep`s to hold the uplink
under the host-imposed limit. With `gLimitMBPS == 0` the pacer is skipped. This
is the only client-side uplink rate control.

## 6. Reconnect / teardown

`Reconnect` (`+0x1677a8`) is idempotent re-setup: logs
`SVLDataLinkUDP::Disconnect()`, clears the "running" flag (`this+0x260 = 0`),
`shutdown(fd, SHUT_RDWR)` + `close(fd)`, joins the old RX thread
("Joining Thread %p" / "Join Complete"), rebuilds the socket, and starts a new
RX thread ("Thread Create Complete"). **Captured** once, in `vr3` (§1.1).

### The teardown datagram (**static**; not captured)

`PrepareForPossibleShutdown` (`+0x168608`, link vtable+0x88) builds one
datagram ahead of time and stores it, with the peer address and the local
address, in a static closure (`SVLDataLink::SetPostTeardownShutdown`):

| part | bytes (mode 1) |
|---|---|
| header | `seq = 0xffff`, `res = 0`, XOR0 checksum computed as usual |
| element | `class 3`, `type 0x13`, `id 0`, `len 0`, `index 0` (the code stores the 64-bit constant `0x1303`) |

16 bytes in all (12 in mode 0; padded to 32 and encrypted in mode 2, where
the tag word is written as `0x02ffffff`). The fixed `seq = 0xffff` is not taken
from the datagram counter.

`SVLDataLink::SendPostTeardownShutdown` (`+0x15c920`), called from
`XrSceneStream::~XrSceneStream`, runs the closure if it was prepared less than
10 s ago: it logs `SVLDataLink::SendPostTeardownShutdown() attempting shutdown
message`, opens a **new** UDP socket (`SVLDataLinkUDP -> Post Shutdown Sock:
%d`), binds it to the old local address when that had a port, connects to the
peer, and sends the datagram **five times, 100 ms apart**
(`SVLDataLinkUDP -> Sending: %d`).

**Inferred**: type 0x13 is the client's "I am leaving" message, the
counterpart of the host's type 0x0e `SYST_SERVER_SHUTDOWN`; nothing in the
client handles an incoming 0x13. What the host does on receiving it is
unknown. `vr3` cannot show it: that capture ends because the client process
was killed by a timeout mid-stream — its last datagram is an ordinary pose
datagram (`seq 17445`), the host was still sending video 1 ms earlier, and no
`3/0x13`, no `seq 0xffff`, no `3/0x0e` and no sideband frame appear.

### What the host does when a client leaves (measured 2026-11-10)

**Captured**, from the host's own `driver_vrlink.txt` log across four probe
sessions of 12 to 14 s each:

- When the client's datagrams stop, the host logs `Connection inactive at
  <seconds>`, and 30 s later `Connection inactive for 30.1 > 30 seconds.
  Sending quit event.`, after which SteamVR shuts down. This happened the
  same way every time.
- The teardown datagram does not shorten the 30 s. Sent correctly (five
  times, 100 ms apart; in mode 2 with the counter word `0x02ffffff`), the
  host logged "inactive" within about a second of it, against about three
  seconds when the datagram was malformed (mode 2 with the ordinary counter)
  and the host had only silence to go on. So the host probably does take it
  as "the client has gone", but its quit timer starts from there regardless.
- Sending `DeviceStreamingCancelRequest` for the session's request id on
  port 27036 after the teardown changed nothing.
- **static**, client 2.0.25: the only shutdown the VR client sends is still
  this teardown datagram. There is no "quit SteamVR now" message for a client
  to send.

**Captured** again on 2026-11-13, from the host's `vrserver.txt` with a
host that speaks version 14, and it no longer matches the second point
above:

- The teardown datagram is acted on at once. The host logs `Client sent
  SYST_CLIENT_SHUTDOWN`, then `Sending quit event because SteamVR launched
  for streaming and client has quit.`, and SteamVR and the application
  running in it are closed within two seconds.
- A client that only goes quiet gets the timer: `Connection inactive at
  <seconds>`, then after 30 s (`driver_vrlink.wirelessShutdownTimeout`)
  either `Sending quit event.` or, while an application has the scene,
  `Waiting to quit for scene app steam.app.<id>.` In that state the host
  waited 80 s and 59 s in two sessions before it did send the quit event,
  and in a third the client came back after 64 s (`Connection active at
  …`) and carried on in the same SteamVR session.

So the teardown datagram is the "quit SteamVR now" message, and a client
that may come back (a headset taken off, an app put away) should not send
it. The OpenVRLink client sends it only when the wearer ends the session.

The host calls its own `PrepareForPossibleShutdown` when it shuts down
(**captured**, same log): the teardown datagram exists in both directions.

## Open questions / to confirm on the wire

Settled by `vr3`: the first client datagram and the host's reply (§2; there
is no class 9 element); there are no keepalives and the client is never idle
(§3); the socket is replaced once when the host enables QoS, keeping the local
port, and `IP_TOS` is set to 255 only then (§1.1); the time from first
datagram to each startup step (§2).

Still open:
- The teardown datagram as vrlink sends it has still not been
  captured; what the host does with ours is above.
- Who calls `PrepareForPossibleShutdown`, i.e. at which moments the client
  arms the teardown.
- The real `SO_RCVTIMEO` value chosen (host-supplied vs 10 ms default) — the
  trace does not show that `setsockopt` — and the effective buffer sizes
  on-device.
- Whether the host does anything with the TOS marking, or with its absence.
- What the host sends if the first datagram is rejected (wrong session id).

## Probe results (2026-11-10)

The Python probe opened a session with no handshake at all: its first datagram
was `[3/0x07 values][4/0x0f frame report][3/0x01 pose + value transport]` from
an unbound, connected UDP socket with default socket options (no TOS, 8 MiB
receive buffer), and the host answered within the first second.
**Captured by probe.** 37,842 datagrams in 20 s, every checksum valid.

## Client results (2026-11-10): two clients, one device

Two copies of the Swift viewer with the same device identity streamed from the
same host at once, by accident. Each asked for its own session; both then got
1-2 complete frames per second, thousands of retransmit requests and a steady
stream of lost audio. **Captured by client.** That is what the static reading
of host-side peer adoption predicts: the host has one stream and sends it to
whichever client it last adopted. A client seeing this pattern on a clean
network should suspect a second client before suspecting its own code.
