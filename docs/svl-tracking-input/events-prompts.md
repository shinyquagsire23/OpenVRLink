# Events, message prompts, shutdown, sideband, debug

## Local timer queue (`VRLinkPostedEvent_t`)

`VRLinkPostedEvent_t` is an internal timer queue entry rather than a wire
message (**static**). `SVLRoot::PostEvent` (0x165fb4) and `PostMultipleEvents`
(0x165fbc) insert 16-byte events into a time-sorted `std::list` protected by
the mutex at `SVLRoot+0x20`. `SVLRoot::EventsThread` (0x1646fc, thread name
`EventsThread`) sleeps until the head event's timestamp (or 10 ms when the
queue is empty) and dispatches the virtual `HandleEvent` method (vtable slot
0x98). This struct is never serialized onto the wire, so a custom client only
needs equivalent periodic timers.

```
struct VRLinkPostedEvent_t {     // 16 bytes
    u8  type;                    // +0
    i32 time;                    // +4  GetCurrentTimestamp() units (µs) at which to fire
    u64 arg;                     // +8
};
```

The event types below are dispatched through the handler chain
`QSVLClientXR::HandleEvent` (0xfa6e0) → `QSVLClient::HandleEvent` (0xf4bec) →
`SVLRoot::HandleEvent` (0x165dbc), logged under ATrace label
`HandleEvent(%d, %lu)` (**static**):

| type | handled in | what it does |
|---|---|---|
| 0 | QSVLClient | `SVLRoot::SendValues(3)` then `SendPoses(arg & 0xf, arg >> 4)` — the pose tick ([poses.md](poses.md)) |
| 1 | SVLRoot | 1 ms housekeeping tick: re-posts itself at `time + 1000` when its own `time` is within about ±1 ms of now, otherwise at `now + 1000`, ticks every data link (and each link's attached object) and the audio object, and flips connection state: if `GetCurrentTimeUS() − lastRx(+0xc70)` crosses 3,000,000 µs it calls `HandleConnectionLostEvent` (slot 0x50) or `HandleConnectionRegained` (slot 0x58) |
| 2 | QSVLClient, SVLRoot, QSVLClientXR | `QSVLClient::UpdateFrameVariables()`; posts event 3 at `now`; `SVLAudio::UpdateStats()`; in the XR subclass polls one Android audio property per event (round-robin of 5) and, on change, sends the VTE event described below |
| 3 | SVLRoot | `FileTimeCheckTickInternal()`; once per second (with ≤ 200 ms catch-up) posts event 4 |
| 4 | QSVLClient | once per second: `SetValue("dbgPhaFault", this+0xe00)` and sets flags `+0x3e34/35/36` (and `+0x3e44` unless `+0x3eb9`) — **inferred**: "re-publish frame variables / stats now" |

Scheduling for events 0 and 2 (frame timing) is covered in docs/svl-timing/.

### Client audio state event (VTE id 0x23)

During event 2, `QSVLClientXR::HandleEvent` (0xfa6e0, **static**) calls
`ValueTransportSystem::SendEvent(0x23, buf, 10)` whenever system volume, volume
steps, speaker mute, or microphone mute changes (or when the force flag at
`+0x3f54` is set):

| off | type | field |
|---|---|---|
| 0 | u8×3 | `01 01 01` |
| 3 | u8 | 0 |
| 4 | u8 | system volume muted |
| 5 | u8 | microphone muted |
| 6 | u8 | system volume steps (`GetSystemVolumeSteps`) |
| 7 | u8 | system volume (`GetSystemVolume`) |
| 8 | u16 | `0xffff` |

This corresponds to `VTE_CLIENT_AUDIO_STATE` (**inferred** from the log string
`[SVLClientXR] VTE_CLIENT_AUDIO_STATE %d(%d) %d/%d(%d) - %d(%d) %d/%d(%d)`).
Full VTE ID tables are documented in docs/svl-values/.

In `vr3` (**captured**), value id 0x23 appears on the wire with this exact
10-byte layout: `01 01 01 00 00 00 10 0f ff ff` (speaker unmuted, microphone
unmuted, 16 volume steps, volume 15, `0xffff`). `vrlink` publishes it once,
71 ms into the session, as version 1 inside the pose packet's value-transport
trailer, repeating that single chunk 27 times in total before video starts
([poses.md](poses.md), "Variable packet length (VTE trailer)"). Because volume
never changes during the 40 s capture, no second version is sent.

## Message prompt (host → client, type `0x12`)

Handled by `QSVLClient::HandleMessagePromptMessageReceived` (0xf5c90,
**static**), which is called from both `RXUnreliableStream` and
`RXReliableStream`, and `QSVLClientXR::OnMessagePrompt` (0xfac20, **static**).

`MessagePrompt_t`:

| off | type | field |
|---|---|---|
| 0x00 | 8 | dataset header, type 0x12; payload length must be ≥ 0x11 else `[SVLClient] Message prompt size mismatch!` |
| 0x08 | u32 | flags; `vrlink` shows the prompt only when `(flags & 3) == 2` |
| 0x0c | u32 | not read by `vrlink` |
| 0x10 | u32 | passed to `XrUIManager::AddTemporaryDialog` as its `unsigned int` argument — **inferred**: display duration (ms or s) or a prompt id |
| 0x14 | u32 | not read by `vrlink` |
| 0x18 | char[] | title, NUL-terminated |
| after | char[] | body text, NUL-terminated (starts one byte after the title's NUL) |

The strings are bounded by `length − 0x18` (the payload bytes after the 16-byte
fixed body). `vrlink` only displays a temporary dialog
(`AddTemporaryDialog(ctx, title, text, value@0x10, true)`); **no reply message
is sent from this path**. `flags & 3` appears to be a prompt type (**inferred**),
where 2 is an informational toast and other values (such as interactive
questions) are ignored by this build. Related `SVLRoot` string keys `sTitle`,
`sText`, `sDescription`, and `sPermission` exist in the binary
(docs/svl-values/).

## Server shutdown (host → client, type `0x0e`)

In `QSVLClientXR::RXUnreliableStream` (0xfab44, **static**), receiving type
`0x0e` logs `Received SYST_SERVER_SHUTDOWN` and invokes the app callback
(`std::function<void(QSVLClientEvent, variant<QSVLClientStreamState,
QSVLClientWirelessTimeout>)>` at `+0x3f20`) with event 1 and a zero payload.
No body bytes are read. Event 1 with state 0 represents a stream-stopped state
change (**inferred**), causing the scene to exit the stream.

## Sideband events

`QSVLClientXR::HandleSidebandEvent(SVLRoot::SidebandEventType)` (0xfa998,
**static**) handles sideband events raised by the transport layer
(`SVLDataLinkUDP::HandleSidebandPacket`, 0x167688; see docs/svl-transport/):

- **Type `0x10`** (when the link has `+0xac == 0 && +0xad != 0`): Reported to
  the app callback as event 1 with payload 0 (same as server shutdown).
- **Any other type**: Logs `[SVLClientXR] Received sideband event: %d` and
  reports app event 2 with payload `type | timestamp << 32`.

The string table (**static**) lists UI strings for these outcomes:
`#StreamSideBand_ConnectionStarted`, `#StreamSideBand_AlreadyActive`,
`#StreamSideBand_BadConnectionStatus`, `#StreamSideBand_WrongId…`,
`#StreamSideBand_VersionIncompatible…`, and `#StreamSideBand_UnknownIssue`. The
mapping between numeric event types and UI strings lives in the scene/UI code
and was not traced.

## Debug messages

`QSVLClient::RXDebugMessage(dataset*)` (0xf4bd8, vtable slot 0x40, **static**)
is an empty function in this build, as are `SVLRoot::RXBroadcast` and
`RXBroadcastReply` (0x164f04 / 0x164f08). `vrlink` ignores debug and broadcast
messages, so a client implementation does not need to handle them.

In `vr3` (**captured**), the host still sends debug messages. Exactly one
inbound element of class `8`, type `0x06` appears in the 40 s session, alone in
its datagram with element id and index 0. Its 27 payload bytes consist of a
`u32` followed by the 23 ASCII characters `[SVLS] ResetVideoStream` (with no NUL
terminator inside the length). `vr1` contained the same single message.

- The `u32` is a **host-clock timestamp in µs**. Subtracting this `u32` from
  `vrlink`'s local arrival timestamp gives −839,207,490 µs, while `vrlink`'s
  clock-offset estimate `toff` (pose packet 0x0c, local minus peer;
  docs/svl-timing/clock-sync.md) starts at −839,206,786 µs and stays between
  −839,214,499 and −839,206,406 µs across the session — a 0.7 ms difference.
- The message arrives 0.209 s after `vrlink`'s first datagram, 0.17 s after the
  host's last startup value message, and 0.72 s **before** the first video
  packet, announcing that the host is initializing the video stream at session
  start.
- Because `rst` is 0 in every pose packet of `vr3`, this message is unrelated
  to the pose packet's `rst` counter. (An earlier `vr1` note observed it
  coinciding with `rst` climbing 0 → 18, which was incidental to that session.)
  `vrlink`'s own log has no `ResetVideoStream` line; the string comes solely
  from this packet.

Class 8 appears to be the debug channel routed to `RXDebugMessage`, carrying
host log lines that a custom client can log for diagnostics (**inferred**).
Whether bumping `rst` causes the host to send another `ResetVideoStream`
message is untested.

## Other host → client requests seen from this layer

- **Refresh rate**: `QSVLClientXR::TrySetPreferredDisplayFrequency(float)`
  (0xfaef0, vtable slot 0x158) and `GetAvailableDisplayFrequencies` (0xfafc8,
  slot 0x110) are driven by VTE values (`VTE_REQ_FRAMETIME_US`,
  `VTE_AVAILABLE_FRAMETIMES_US`); see docs/svl-values/.
- **App-level client events**: Log strings exist for requests that arrive as
  client events rather than dedicated wire messages in this layer:
  `[SVLClientXR] Received remote dashboard event`,
  `[SceneStream] QSVL_CLIENT_REQUEST_QUIT Received quit event`, and
  `[SceneStream] QSVL_CLIENT_SWITCH_DESKTOP_CLICK: Received switch desktops
  event`. Their wire origin was not traced (**inferred**: VTE events watched
  via `AddWatch`).

## Captured negatives in `vr3`

Across all 133,172 elements in `vr3` (**captured** negatives), there are no
`0x12` message prompts, no `0x0e` server shutdown messages, no `0x14` / `0x15`
echo messages in either direction, and no class-8 messages beyond the single
`ResetVideoStream` packet above. Inbound elements consist solely of `3/0x0d`,
`3/0x18`, `5/0x02`, `5/0x03`, `8/0x06`, and `0xc/0x10`. Because the capture
ended before shutdown, the prompt and shutdown layouts above remain **static**
only.

## Open questions / to confirm on the wire

- Capture a `0x12` prompt to check the four `u32` fields at 0x08..0x17 and
  whether hosts ever send prompt types other than `(flags & 3) == 2`.
- Whether `0x0e` carries a body, and whether the host repeats it.
- Which sideband type numbers the host sends in practice and how they map to
  the `#StreamSideBand_*` strings.
- VTE 0x23 when volume or mute changes (the startup value is captured above;
  bytes 0..3 and 8..9 are constants whose meaning is unknown).
- Whether incrementing the pose packet's `rst` counter causes the host to send
  another `[SVLS] ResetVideoStream`, and whether other `[SVLS]` messages exist.
- Where the remote-dashboard, quit, and switch-desktop requests originate.
