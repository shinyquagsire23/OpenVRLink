# Audio FEC (2 data + 1 XOR parity)

Sources: `SVLAudio::TransmitAndUpdateFEC()` +0x157854,
`SVLAudio::TransmitAudioPacket` +0x1575a8,
`SVLAudio::TransportRXAudioFrames` +0x1571b8, `SVLAudio::UpdateStats` +0x158f78.
All claims **static** unless marked.

## Scheme

Audio packets (types 0x0b / 0x0c, see [packet-format.md](packet-format.md))
share one 16-bit sequence counter. The position in a group is `seq % 3`:

| `seq % 3` | content |
|---|---|
| 0 | data packet A |
| 1 | data packet B |
| 2 | parity: byte-wise XOR of A's and B's payloads over 1024 bytes (shorter one zero-padded) |

The parity packet's `len` is `max(len_A, len_B)`. In the type-0x0c variant its
`aux` field is `min(len_A, len_B)`, so two packets of different length can be
recovered; in the type-0x0b variant `aux` is the ordinary format word and both
data packets are assumed equal length.

When the sequence counter reaches 0xffff after a completed group it is reset to
0 (0xffff is a multiple of 3, so group alignment survives the wrap).

Which variant a sender uses is decided by the peer's capability word
(see [negotiation-and-settings.md](negotiation-and-settings.md)):

```python
if peer_caps & 2:   type_word = 0x100c     # variable-length FEC
elif peer_caps & 1: type_word = 0x100b     # equal-length FEC
else:               type_word = 0x0006 | (0x0800 if i_am_client else 0)   # no FEC, no parity packets
```

## Sender

```python
def transmit_and_update_fec(self):
    if self.agg_len == 0: return
    self.send(self.pkt, len=self.agg_len)          # seq = self.seq; then self.seq += 1
    if self.fec_enabled:
        pos = self.seq % 3                          # seq AFTER the increment
        if pos == 1:                                # just sent A
            self.parity = copy(self.pkt)            # header + 1024 payload bytes
        elif pos == 2:                              # just sent B
            self.parity.payload ^= self.pkt.payload # all 1024 bytes
            self.send(self.parity, len=max(len_A, len_B))   # aux=min(len_A,len_B) if type 0x0c
            self.parity = zeros
        if self.seq == 0xffff: self.seq = 0
    self.pkt = zeros; self.agg_len = 0
```

## Receiver

State: `last_seq` (`SVLAudio+0xc5c`), one held packet `held` (`+0x824`, header
+ 1024 payload bytes; `held.seq == 2` is the "nothing held" sentinel).

```python
def rx_fec_packet(self, p):            # p.type in (0x0b, 0x0c) and p.flags == 0x10
    if p.seq == self.last_seq: return                  # duplicate
    if p.seq - self.last_seq > 2:                      # a whole group boundary was jumped
        if self.held.seq % 3 == 1:                     # a B we were holding back for its A
            self.play(self.held)
        self.drop_count += ((p.seq - self.last_seq - 1) * 2) // 3    # -> cAudDrop
        self.held.seq = 2
        self.on_peer_audio_discontinuity()             # tells the jitter buffer to crossfade
    self.last_seq = p.seq

    pos = p.seq % 3
    if pos == 0:                       # A: play now, keep for parity
        self.play(p); self.held = copy(p)
    elif pos == 1:                     # B
        if self.held.seq == p.seq - 1: # A was received and already played
            self.play(p); self.held.seq = 2
        else:                          # A missing: hold B unplayed until the parity arrives
            self.held = copy(p)
    else:                              # parity
        if self.held.seq == 2 or p.seq - self.held.seq > 2: return
        n = self.held.len
        if p.type == 0x0c:
            if self.held.len < p.len:  # held is the shorter one -> the lost one is the longer
                zero-pad held.payload to p.len;  n = p.len
            else:                      # the lost one is the shorter
                n = p.aux
        rec = xor(p.payload, self.held.payload)        # 1024 bytes
        if self.held.seq == p.seq - 2:     # held A (played), lost B
            self.play(rec[:n])
        elif self.held.seq == p.seq - 1:   # held B (unplayed), lost A
            self.play(rec[:n]); self.play(self.held)
        self.held.seq = 2
        self.fec_recovered += 1            # -> cAudFEC
```

`play(x)` is `AcceptAudioFramesFromPeer(x.payload, x.len // (2*out_channels))`
(vtable +0x30), i.e. a push into the jitter buffer.

Note the comparison `p.seq - self.last_seq > 2` is done on zero-extended
16-bit values as a signed int, so it does not handle the 0xffff→0 wrap as a
continuation — but the sender's reset happens on a group boundary, and a
backwards jump simply fails the `> 2` test and proceeds.

Plain type-6 packets bypass all of this and are played immediately.

## Loss accounting published to the host

`SVLAudio::UpdateStats` (client only, called once per rendered frame from
`SVLRoot::HandleEvent` event type 2) publishes through the SVLRoot value
channel:

| key | source | meaning |
|---|---|---|
| `cAudDrop` | `SVLAudio+0xc58` | estimated lost data packets (2/3 of each sequence gap) |
| `cAudFEC` | `SVLAudio+0xc54` | packets reconstructed from parity |

## Confirmed against a wire capture

Capture: `vr3` (real client under Klepton, 40.26 s of streaming, 80,011 SVL
datagrams, none torn, each with a CLOCK_MONOTONIC receive/send timestamp).
Times below are seconds from the first SVL datagram of the capture. The earlier
capture `vr1` had a third of its datagrams torn and no timestamps, so its
counts were lower bounds; every figure here is a complete count.

Field names as in [packet-format.md](packet-format.md): "type 0x0c, flags
0x10" is what the transport prints as "class 0x0c, type 0x10".

- **captured**: 2,913 messages, `seq` 0 to 2912, every step +1. That is 971
  complete A / B / parity triples and no partial one: the burst starts on
  `seq % 3 == 0` and ends on `seq % 3 == 2`.
- **captured**: `seq % 3 == 2` messages carry a length in the last header
  field (896 x851, 1024 x60, 768 x60); the other two positions carry `0x4b01`
  (1,942 of 1,942).
- **captured**: for all 971 triples, `parity == A ^ B` over 1024 zero-padded
  bytes, parity `len == max(len_A, len_B)` and parity last field
  `== min(len_A, len_B)`. 971 of 971, 0 failures. Caveat, same as `vr1`
  (which had 11 of 11): every data payload is zeros, so the XOR itself is of
  zeros and the parity payloads are all zero - the length rules are the
  informative part, and the XOR of non-zero audio is still **static** only.
- **captured**: position 0 is always 1024 bytes; position 1 is 896 (851),
  1024 (60) or 768 (60); parity is always 1024 long, because A always is.
  The unequal-length convention is therefore exercised in 911 of 971 triples
  (min 896 or 768 against max 1024).
- **captured**: the host uses type 0x0c (flags 0x10) for every message after
  the client advertises capabilities 3 in VTE 0x18. No type 0x0b or 0x06
  message appears.
- **captured**: `cAudFEC` and `cAudDrop` stay 0 for the whole session, as they
  should with no sequence gap. (`vr1` showed `cAudFEC` 0 -> 1 in a session
  the tracer was disturbing; `vr3` has no recovery to show.)
- **captured**: the parity packet is sent late. B follows A within 0.2 ms
  (median), but the parity arrives a median 4.4 ms after B, spread evenly over
  0 to 10 ms, and 907 of 971 arrive within 0.3 ms of the next video frame's
  first descriptor. Details and the inference in
  [packet-format.md](packet-format.md) ("Timing of the downlink"). For the
  receiver above this means a lost A is replayed (with its held B) up to
  about 10 ms late.
- **Not visible**: sequence wrap. The burst is 2,913 messages, so `seq` never
  gets near 0xffff. The counter started at 0 at the first audio message of the
  session; whether it restarts at 0 for a later burst in the same session is
  unknown (there was only one burst).

## Open questions / to confirm on the wire

- XOR parity over non-silent audio (both captures carried only zeros), and an
  actual recovery: no packet was lost in `vr3`, so the receive state machine
  is still **static** only.
- Whether the host's sequence counter also resets at 0xffff (needs more than
  3.6 minutes of continuous audio at 300 messages/s), and whether it continues
  or restarts when audio resumes after a pause.
- Which type the host sends when the client advertises capabilities 1 or 0
  (probe).
- Whether the host changes anything when `cAudDrop` / `cAudFEC` grow.
