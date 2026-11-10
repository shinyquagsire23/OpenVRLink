# Events, message prompts, shutdown, sideband, debug

## `VRLinkPostedEvent_t` is a local timer queue, not a wire message

**static**: `SVLRoot::PostEvent` (0x165fb4) / `PostMultipleEvents` (0x165fbc)
insert 16-byte events into a time-sorted `std::list` under the mutex at
`SVLRoot+0x20`; `SVLRoot::EventsThread` (0x1646fc, thread name `EventsThread`)
sleeps until the head event's time (or 10 ms when the queue is empty) and
calls the virtual `HandleEvent` (vtable slot 0x98). Nothing serializes this
struct. A reimplementation needs equivalent timers, not this format.

```
struct VRLinkPostedEvent_t {     // 16 bytes
    u8  type;                    // +0
    i32 time;                    // +4  GetCurrentTimestamp() units (µs) at which to fire
    u64 arg;                     // +8
};
```

Event types (**static**; handlers chain
`QSVLClientXR::HandleEvent` 0xfa6e0 → `QSVLClient::HandleEvent` 0xf4bec →
`SVLRoot::HandleEvent` 0x165dbc; ATrace label `HandleEvent(%d, %lu)`):

| type | handled in | what it does |
|---|---|---|
| 0 | QSVLClient | `SVLRoot::SendValues(3)` then `SendPoses(arg & 0xf, arg >> 4)` — the pose tick ([poses.md](poses.md)) |
| 1 | SVLRoot | 1 ms housekeeping tick: re-posts itself at `time + 1000` when its own `time` is within about ±1 ms of now, otherwise at `now + 1000`, ticks every data link (and each link's attached object) and the audio object, and flips connection state: if `GetCurrentTimeUS() − lastRx(+0xc70)` crosses 3,000,000 µs it calls `HandleConnectionLostEvent` (slot 0x50) or `HandleConnectionRegained` (slot 0x58) |
| 2 | QSVLClient, SVLRoot, QSVLClientXR | `QSVLClient::UpdateFrameVariables()`; posts event 3 at `now`; `SVLAudio::UpdateStats()`; in the XR subclass polls one Android audio property per event (round-robin of 5) and, on change, sends the VTE event described below |
| 3 | SVLRoot | `FileTimeCheckTickInternal()`; once per second (with ≤ 200 ms catch-up) posts event 4 |
| 4 | QSVLClient | once per second: `SetValue("dbgPhaFault", this+0xe00)` and sets flags `+0x3e34/35/36` (and `+0x3e44` unless `+0x3eb9`) — **inferred**: "re-publish frame variables / stats now" |

Who posts events 0 and 2 (frame timing) belongs to docs/svl-timing/.

### Side effect of event 2: client audio state (VTE id 0x23)

**static**: `QSVLClientXR::HandleEvent` (0xfa6e0) calls
`ValueTransportSystem::SendEvent(0x23, buf, 10)` when system volume, volume
steps, speaker mute or microphone mute changed (or a force flag at `+0x3f54`
is set):

| off | type | field |
|---|---|---|
| 0 | u8×3 | `01 01 01` |
| 3 | u8 | 0 |
| 4 | u8 | system volume muted |
| 5 | u8 | microphone muted |
| 6 | u8 | system volume steps (`GetSystemVolumeSteps`) |
| 7 | u8 | system volume (`GetSystemVolume`) |
| 8 | u16 | `0xffff` |

**inferred**: this is `VTE_CLIENT_AUDIO_STATE` (log string
`[SVLClientXR] VTE_CLIENT_AUDIO_STATE %d(%d) %d/%d(%d) - %d(%d) %d/%d(%d)`).
The id table is owned by docs/svl-values/.

**captured** (`vr3`): value id 0x23 is on the wire with exactly this layout,
10 bytes `01 01 01 00 00 00 10 0f ff ff`: not muted, microphone not muted,
16 volume steps, volume 15, `0xffff`. It is published once, 71 ms into the
session, as version 1 inside the pose packet's value-transport bytes, and
that one chunk is sent 27 times in all before video starts
([poses.md](poses.md), "Why the length varies"). No second version appears
in the 40 s, so nothing in `vr3` shows the bytes changing with volume.

## Message prompt (host → client, type `0x12`)

**static**: `QSVLClient::HandleMessagePromptMessageReceived` (0xf5c90), called
from both `RXUnreliableStream` and `RXReliableStream`;
`QSVLClientXR::OnMessagePrompt` (0xfac20).

`MessagePrompt_t`:

| off | type | field |
|---|---|---|
| 0x00 | 8 | dataset header, type 0x12; payload length must be ≥ 0x11 else `[SVLClient] Message prompt size mismatch!` |
| 0x08 | u32 | flags; the XR client shows the prompt only when `(flags & 3) == 2` |
| 0x0c | u32 | not read by this client |
| 0x10 | u32 | passed to `XrUIManager::AddTemporaryDialog` as its `unsigned int` argument — **inferred**: display duration (ms or s) or a prompt id |
| 0x14 | u32 | not read by this client |
| 0x18 | char[] | title, NUL-terminated |
| after | char[] | body text, NUL-terminated (starts one byte after the title's NUL) |

The strings are bounded by `length − 0x18` (string area = payload bytes after
the 16 fixed ones). The client only displays a temporary dialog
(`AddTemporaryDialog(ctx, title, text, value@0x10, true)`); **no reply message
is sent from this path**. **inferred**: `flags & 3` is a prompt kind (2 =
informational toast); other kinds (e.g. a question needing an answer) are
ignored by this build. Related SVLRoot string keys `sTitle`, `sText`,
`sDescription`, `sPermission` exist (docs/svl-values/).

## Server shutdown (host → client, type `0x0e`)

**static**: `QSVLClientXR::RXUnreliableStream` (0xfab44) logs
`Received SYST_SERVER_SHUTDOWN` and invokes the app callback
(`std::function<void(QSVLClientEvent, variant<QSVLClientStreamState,
QSVLClientWirelessTimeout>)>` at `+0x3f20`) with event 1 and a zero payload.
No body bytes are read. **inferred**: QSVLClientEvent 1 = "stream state
changed", state 0 = stopped; the scene then leaves the stream.

## Sideband events

**static**: `QSVLClientXR::HandleSidebandEvent(SVLRoot::SidebandEventType)`
(0xfa998), raised by the transport (`SVLDataLinkUDP::HandleSidebandPacket`
0x167688; owned by docs/svl-transport/).

- Type `0x10`, when the link has `+0xac == 0 && +0xad != 0`: reported to the
  app as event 1 / payload 0 (same as shutdown).
- Anything else: logs `[SVLClientXR] Received sideband event: %d` and reports
  app event 2 with payload `type | timestamp << 32`.

UI strings that name the outcomes (**static**, string table):
`#StreamSideBand_ConnectionStarted`, `#StreamSideBand_AlreadyActive`,
`#StreamSideBand_BadConnectionStatus`, `#StreamSideBand_WrongId…`,
`#StreamSideBand_VersionIncompatible…`, `#StreamSideBand_UnknownIssue`. The
numeric type ↔ string mapping lives in the scene/UI code and was not traced.

## Debug messages

**static**: `QSVLClient::RXDebugMessage(dataset*)` (0xf4bd8, vtable slot 0x40)
is an empty function in this build, and `SVLRoot::RXBroadcast` /
`RXBroadcastReply` (0x164f04 / 0x164f08) are empty too. The client ignores
debug and broadcast messages; nothing needs to be implemented.

**captured** (`vr3`): the host does send them. Exactly one inbound element of
class `8`, type `0x06` in the 40 s session, alone in its datagram, element id
and index 0: 27 payload bytes = a u32 then the 23 ASCII characters
`[SVLS] ResetVideoStream`, with no terminator inside the length. `vr1` had
the same single message.

- The u32 is a **host-clock timestamp in µs**. The client's own timestamp at
  the moment of arrival minus this u32 is −839,207,490, and the client's
  clock-offset estimate `toff` (pose packet 0x0c, local minus peer;
  docs/svl-timing/clock-sync.md) is −839,206,786 when it first appears and
  stays between −839,214,499 and −839,206,406 all session. The difference is
  0.7 ms.
- Timing: it arrives 0.209 s after the client's first datagram, 0.17 s after
  the last start-up value message from the host and 0.72 s **before** the
  first video packet. It is the host announcing that it is (re)starting the
  video stream at session start.
- It is not a reaction to the pose packet's `rst` counter: `rst` is 0 in
  every pose packet of `vr3`. (The `vr1` note that it "coincides with `rst`
  climbing" was a coincidence of that session, in which `rst` rose 0 → 18.)
  The client log has no `ResetVideoStream` line of its own; the text exists
  only in this message.

**inferred**: class 8 is the debug channel routed to `RXDebugMessage`, and
the text is the host's own log line, useful to a reimplementation as free
diagnostics. Whether the host sends it again when a client does bump `rst`
is untested.

## Other host → client requests seen from this layer

- Refresh rate: `QSVLClientXR::TrySetPreferredDisplayFrequency(float)`
  (0xfaef0, vtable slot 0x158) and `GetAvailableDisplayFrequencies` (0xfafc8,
  slot 0x110) are the hooks; they are driven by VTE values
  (`VTE_REQ_FRAMETIME_US`, `VTE_AVAILABLE_FRAMETIMES_US`), see docs/svl-values/.
- Log strings for app-level requests that arrive as client events rather than
  as distinct wire messages here: `[SVLClientXR] Received remote dashboard
  event`, `[SceneStream] QSVL_CLIENT_REQUEST_QUIT Received quit event`,
  `[SceneStream] QSVL_CLIENT_SWITCH_DESKTOP_CLICK: Received switch desktops
  event`. Their wire origin was not traced (**inferred**: VTE events watched
  via `AddWatch`).

## Not seen in `vr3`

**captured** negatives, over all 133,172 elements of the capture: no `0x12`
message prompt, no `0x0e` server shutdown, no `0x14` / `0x15` echo in either
direction, and no class-8 message other than the one above. The inbound
element kinds are only `3/0x0d`, `3/0x18`, `5/0x02`, `5/0x03`, `8/0x06` and
`0xc/0x10`. No shutdown message appears before the capture ends, so the
prompt and shutdown layouts above remain **static** only.

## Open questions / to confirm on the wire

- A `0x12` prompt capture: the four u32 at 0x08..0x17, and whether hosts ever
  send kinds other than `(flags & 3) == 2`.
- Whether `0x0e` has a body, and whether the host repeats it.
- The sideband type numbers the host actually sends and their mapping to the
  `#StreamSideBand_*` strings.
- VTE 0x23 when volume or mute changes (the start-up value is captured,
  above; bytes 0..3 and 8..9 are constants and their meaning is unknown).
- Whether a change of the pose packet's `rst` makes the host send another
  `[SVLS] ResetVideoStream`, and whether other `[SVLS]` texts exist.
- Where the remote-dashboard / quit / switch-desktop requests originate.
