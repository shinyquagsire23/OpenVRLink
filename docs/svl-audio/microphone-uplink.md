# Microphone uplink (client → host)

Sources: `QSVLClientAudioNdk::Init(bool, int)` +0xf4184,
`QSVLClientAudioNdk::OnInputAudioReady` +0xf46d4,
`SVLAudio::AcceptFramesFromDeviceForSendingOverNetwork(short*, int)` +0x15773c,
`SVLAudio::FlushAudioPacket` +0x157960, `SVLAudio::TransmitAndUpdateFEC`
+0x157854, `SVLAudio::TransmitAudioPacket` +0x1575a8. All **static** unless
marked.

## Device formats vrlink opens

| stream | direction | channels | sample format | rate | other |
|---|---|---|---|---|---|
| output | playback | 2 | PCM 16-bit (`AAUDIO_FORMAT_PCM_I16` = 1) | the rate passed to `Init` | performance mode 12 (low latency), sharing mode 1 (shared), buffer capacity = one burst |
| input | capture | 1 | PCM 16-bit | same rate as output | performance mode 12, sharing mode 1, input preset 7 (voice communication) |

`Init`'s rate argument is the downlink rate from the packet format word when
the stream is re-opened for a rate change, and 48000 when re-opened after an
`AAUDIO_ERROR_DISCONNECTED` (`QSVLClientAudioNdk::Tick` +0xf4758). The cold
initial call site was not traced; **inferred** 48000.

## Packetization

```python
def on_input_audio_ready(self, pcm, frames):          # mono s16
    if not root.is_connection_active(): return
    data = bytes of frames * channels(=1) * 2
    while data:
        take = min(len(data), 0x400 - self.agg_len)
        self.pkt.payload[self.agg_len:] = data[:take]; self.agg_len += take
        if self.agg_len == 0x400:
            self.transmit_and_update_fec()            # full 1024-byte packet
        data = data[take:]
    # FlushAudioPacket:
    if self.use_0c:                                   # peer caps bit 1
        self.transmit_and_update_fec()                # send the partial remainder now
```

- Without the type-0x0c capability, mic audio is sent only in full 1024-byte
  packets (512 mono frames = 10.67 ms at 48 kHz) and the remainder waits for
  the next capture callback.
- With it (the normal case, since the host code advertises 3), a packet is
  flushed at the end of every capture callback, so packets are variable length
  (≤ 1024 bytes) and the parity packet uses the min/max length convention
  described in [fec.md](fec.md).
- Nothing is sent while `SVLRoot::BIsConnectionActive()` is false.
- Packet header: type `0x0c`/`0x0b` with flags `0x10`, or type `0x06` with
  flags `0x08` (client marker) when the host advertised no FEC capability.
  `aux` is the format word `(channels-1) | (rate/10) << 2` with channels = 1.
- Minimum 250 µs between audio packets (spin-wait).

There is no gain control, VAD, echo cancellation or resampling in this path;
mute is done at the Android level (`AndroidAudioManagerService::
SetMicrophoneMute`), not in the stream (**inferred** from the absence of any
branch on a mute flag in the functions above; `SVLAudio::SyncAudioControls`
+0xf4ae8 only stores a bool at `+0x1d62`, whose reader was not traced).

## Confirmed against a wire capture

Capture: `vr3` (real client under Klepton, 40.26 s of streaming, 80,011 SVL
datagrams, none torn, each with a CLOCK_MONOTONIC receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. The earlier
capture `vr1` had a third of its datagrams torn and no timestamps, so its
counts were lower bounds; every figure here is a complete count.

- **captured, negative**: nothing in this file is confirmed. `vr3` contains
  no client -> host audio element at all: of 69,287 client -> host elements
  none has byte 0 (the transport's class) 0x06, 0x0b or 0x0c; the only
  classes the client sends are 3 and 4. All 2,913 audio elements in the
  capture are host -> client. Same result as `vr1`.
- **captured** (client log): the reason is on the client side -
  `[Audio] Creating input stream...` is followed by `[Audio] AAudio Error:
  AAudioStreamBuilder_openStream( inputBuilder, &m_pAAudioInputStream ) =
  AAUDIO_ERROR_UNAVAILABLE` (Klepton provides no capture device), before the
  first SVL datagram.
- **captured**: the host streamed video for the whole 40 s and audio for its
  9.7 s burst with no microphone packets, so the uplink is optional.
- **captured**: the host does advertise capabilities 3 in VTE 0x19
  ([negotiation-and-settings.md](negotiation-and-settings.md)), so a client
  with a working microphone would take the type-0x0c, flush-every-callback
  path described above (**static**).

## Client results (2026-11-10): the uplink works

**Captured by client** (`client` on macOS sending a generated 440 Hz
tone, amplitude 12000, as microphone audio; measured on the host by recording
three seconds from its default recording device, which SteamVR sets to its
"Steam Streaming Microphone" for the session):

- Packets sent as class `0x0c`, type `0x10`, format word `0x4b00` (48 kHz,
  one channel), up to 1024 bytes of mono 16-bit samples, two data packets
  then their XOR with the shorter length in the index field; one packet per
  datagram, after the first video has arrived.
- The host's microphone carried the tone: RMS 8467 of 32768 (12000 / sqrt 2
  is 8485, so the gain is one), pitch 459 Hz by zero crossings, 37 % of the
  power exactly at 440 Hz and none at 220 or 880. So the format word is
  honored as mono 48 kHz and parity packets are not played as sound.
- The remainder (a few discontinuities in three seconds) came with a sender
  that delivered in 10 ms bursts from a sleeping thread. An earlier sender
  that fell behind real time measured 1539 Hz from the same tone: the host
  does not smooth over an uplink that under-delivers.

Not measured: a real microphone (the capture path on Apple platforms is
written and builds, but has only been exercised by this tone), and what the
host does with stereo or other rates.

## Open questions / to confirm on the wire

- Everything on the wire: a capture from a client whose input stream opens is
  needed (Klepton would have to supply an AAudio input device), or a probe
  that sends mic packets and listens on the host.
- The rate half of the uplink format word: no writer of `SVLAudio+0x0c` was
  found, so vrlink may send `aux = 0x0000` on mic data packets.
  A capture of one client mic packet settles it, and tells an alternative
  client what the host tolerates.
- Whether the host accepts stereo or other rates on the uplink.
