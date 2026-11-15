# Microphone uplink (client → host)

Sources: `QSVLClientAudioNdk::Init(bool, int)` +0xf4184,
`QSVLClientAudioNdk::OnInputAudioReady` +0xf46d4,
`SVLAudio::AcceptFramesFromDeviceForSendingOverNetwork(short*, int)` +0x15773c,
`SVLAudio::FlushAudioPacket` +0x157960, `SVLAudio::TransmitAndUpdateFEC`
+0x157854, `SVLAudio::TransmitAudioPacket` +0x1575a8. All details below are
**static** unless marked otherwise.

## Device formats vrlink opens

| stream | direction | channels | sample format | rate | other |
|---|---|---|---|---|---|
| output | playback | 2 | PCM 16-bit (`AAUDIO_FORMAT_PCM_I16` = 1) | the rate passed to `Init` | performance mode 12 (low latency), sharing mode 1 (shared), buffer capacity = one burst |
| input | capture | 1 | PCM 16-bit | same rate as output | performance mode 12, sharing mode 1, input preset 7 (voice communication) |

`Init`'s rate argument is the downlink rate from the packet format word when
the stream is reopened for a rate change, and 48000 when reopened after an
`AAUDIO_ERROR_DISCONNECTED` (`QSVLClientAudioNdk::Tick` +0xf4758). The initial
startup call site was not traced, so the 48000 Hz initial rate is **inferred**.

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
- With type-0x0c enabled (the normal case, since the host advertises capability
  3), a packet is flushed at the end of every capture callback, so packets are
  variable length (≤ 1024 bytes) and the parity packet uses the min/max length
  convention described in [fec.md](fec.md).
- Nothing is sent while `SVLRoot::BIsConnectionActive()` is false.
- The packet header uses type `0x0c`/`0x0b` with flags `0x10`, or type `0x06`
  with flags `0x08` (client marker) when the host advertised no FEC capability.
  `aux` is the format word `(channels-1) | (rate/10) << 2` with channels = 1.
- `TransmitAudioPacket` enforces a minimum 250 µs gap between audio packets via
  spin-wait.

There is no gain control, VAD, echo cancellation, or resampling in this path;
muting happens at the Android level (`AndroidAudioManagerService::
SetMicrophoneMute`) rather than in the stream (**inferred** from the absence of
any branch on a mute flag in the functions above; `SVLAudio::SyncAudioControls`
+0xf4ae8 only stores a bool at `+0x1d62`, whose reader was not traced).

## Capture verification (`vr3`)

Capture `vr3` records 40.26 s of `vrlink` streaming under Klepton (80,011
intact SVL datagrams, each with a `CLOCK_MONOTONIC` receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. Unlike the
earlier `vr1` capture, which had a third of its datagrams torn and no
timestamps (giving only lower-bound counts), every count here is complete.

- **captured, negative**: `vr3` contains no client-to-host audio elements,
  leaving the uplink wire format unconfirmed in that capture. Of 69,287
  client-to-host elements, none has byte 0 (transport class) equal to 0x06,
  0x0b, or 0x0c; the client sends only classes 3 and 4. All 2,913 audio
  elements in the capture travel host to client, matching `vr1`.
- **captured** (client log): Before the first SVL datagram, `vrlink` logs
  `[Audio] Creating input stream...` followed by `[Audio] AAudio Error:
  AAudioStreamBuilder_openStream( inputBuilder, &m_pAAudioInputStream ) =
  AAUDIO_ERROR_UNAVAILABLE` because Klepton provides no audio capture device.
- **captured**: The host streamed video for the full 40 s and audio for its
  9.7 s burst without receiving any microphone packets, confirming that the
  uplink is optional.
- **captured**: The host advertises capabilities 3 in VTE 0x19
  ([negotiation-and-settings.md](negotiation-and-settings.md)), so a client
  with a working microphone takes the type-0x0c, flush-every-callback path
  described above (**static**).

## Client uplink test (2026-11-10)

Tested with `client` on macOS sending a generated 440 Hz sine wave (amplitude
12000) as microphone audio while recording three seconds from the host's
default recording device, which SteamVR sets to "Steam Streaming Microphone"
for the session (**captured** / **measured**):

- `client` sent packets as class `0x0c`, type `0x10`, format word `0x4b00`
  (48 kHz mono), with up to 1024 bytes of mono 16-bit samples per packet, two
  data packets followed by their XOR parity with the shorter length in the
  index field, one packet per datagram, starting after the first video packet
  arrived.
- The host's virtual microphone recorded the tone at RMS 8467 of 32768
  (12000 / √2 is 8485, matching unity gain), with a zero-crossing pitch of
  459 Hz, 37% of spectral power at 440 Hz, and none at 220 or 880 Hz. This
  confirms that the host honors format word `0x4b00` as mono 48 kHz and does
  not play parity packets as audio.
- A few discontinuities over the three-second recording came from sending in
  10 ms bursts from a sleeping thread. An earlier sender that fell behind real
  time produced a measured pitch of 1539 Hz from the same tone, showing that
  the host does not smooth over an uplink that under-delivers.

Live microphone hardware (the Apple capture path compiles cleanly but has only
been tested with the generated tone) and host handling of stereo or non-48 kHz
rates were not tested.

## Open questions

- Capture `vrlink`'s own uplink packets on the wire in an environment where its
  AAudio input stream opens (for example, by supplying a capture device in
  Klepton).
- Check the sample-rate field in `vrlink`'s uplink format word: no writer of
  `SVLAudio+0x0c` was found statically, so `vrlink` may send `aux = 0x0000` on
  mic data packets. Capturing a single `vrlink` mic packet will settle what it
  sends.
- Test whether the host accepts stereo or other sample rates on the uplink.
