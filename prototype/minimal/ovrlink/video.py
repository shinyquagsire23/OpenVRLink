# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Video reassembly (docs/svl-video/packets.md, frame-descriptor.md).

Class 5 elements: type 3 carries a 1024-byte slice of an encoded frame (or
parity), type 2 is the frame descriptor. A finished frame is one HEVC access
unit in Annex-B form.

FEC is not implemented: a frame with a missing data packet is dropped. The
RAID-6 scheme that would repair it is in docs/svl-video/fec.md.
"""
import struct
from dataclasses import dataclass, field

CLASS_VIDEO = 5
TYPE_DESCRIPTOR = 2
TYPE_PACKET = 3
PACKET_SIZE = 1024
FIRST_PARITY_ID = 0x800
SLOTS = 16  # the reference client keeps frames in slots indexed by frame_id & 0xf


@dataclass
class Descriptor:
    frame_id: int
    group: int          # 0 before the frame's packets, g+1 after group g
    tx_time: int        # host clock, microseconds, 32-bit
    frame_size: int
    fec_mode: int
    bookend_index: int
    metadata_size: int
    version: int
    metadata: bytes     # TransportFrameMetadata_t
    trailer: bytes      # haptics, SVLRoot values, timing events, value-transport bytes

    @classmethod
    def parse(cls, element):
        # Offsets in the docs count from the element header, which is 8 bytes.
        value = element.value
        tx_time, _peer_clock, frame_size, _flag, fec_mode = struct.unpack_from("<IIIBB", value, 0)
        bookend_index, _, metadata_size, version = struct.unpack_from("<BBHI", value, 0x14)
        metadata_size = metadata_size or 0xF0
        return cls(element.id, element.index, tx_time, frame_size, fec_mode, bookend_index,
                   metadata_size, version, value[0x20:0x20 + metadata_size],
                   value[0x20 + metadata_size:])


@dataclass
class _Frame:
    frame_id: int
    size: int = 0                       # 0 until known
    packets: dict = field(default_factory=dict)

    def complete(self):
        if not self.size:
            return False
        count = -(-self.size // PACKET_SIZE)
        return all(index in self.packets for index in range(count))

    def data(self):
        count = -(-self.size // PACKET_SIZE)
        return b"".join(self.packets[index] for index in range(count))[:self.size]


class FrameAssembler:
    """Feed it class-5 elements; it returns (frame_id, bytes) when a frame completes."""

    def __init__(self):
        self._slots = {}
        self._done = set()
        self.dropped = 0

    def _frame(self, frame_id):
        slot = frame_id % SLOTS
        frame = self._slots.get(slot)
        if frame is None or frame.frame_id != frame_id:
            if frame is not None and frame.frame_id not in self._done:
                self.dropped += 1
            frame = self._slots[slot] = _Frame(frame_id)
            self._done.discard(frame_id)
        return frame

    def accept(self, element):
        if element.cls != CLASS_VIDEO:
            return None
        frame_id = element.id
        if frame_id in self._done:
            return None
        frame = self._frame(frame_id)
        if element.type == TYPE_DESCRIPTOR:
            frame.size = Descriptor.parse(element).frame_size
        elif element.type == TYPE_PACKET:
            packet_id = element.index
            if packet_id >= FIRST_PARITY_ID:
                return None
            frame.packets.setdefault(packet_id, element.value)
            if len(element.value) != PACKET_SIZE and not frame.size:
                # The short last packet marks the end of the frame.
                frame.size = packet_id * PACKET_SIZE + len(element.value)
        if frame.complete():
            self._done.add(frame_id)
            return frame_id, frame.data()
        return None
