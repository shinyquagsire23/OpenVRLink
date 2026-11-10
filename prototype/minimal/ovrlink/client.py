# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A minimal SVL client: enough to make a host send video, and to save it.

It presents a motionless head with no controllers, publishes the startup
values the reference client publishes, acks what the host sends, and writes
completed frames out as an HEVC elementary stream. Every behavior here is a
candidate for "change it and see what the host does"; docs/ records the
answers.
"""
import random
import socket
import struct
import time
from dataclasses import dataclass, field

from . import profile, svl
from .video import CLASS_VIDEO, TYPE_DESCRIPTOR, Descriptor, FrameAssembler
from .vts import ValueTransport

CLASS_STREAM = 3            # unreliable stream
TYPE_POSE = 0x01
TYPE_VALUES = 0x07
TYPE_VALUE_TRANSPORT = 0x0D
CLASS_VIDEO_REPLY = 4
TYPE_FRAME_REPORT = 0x0F

POSE_BLOCK = 0x168          # fixed part of the pose message; value transport follows
VTS_BUDGET = 0x174
POSES_PER_FRAME = 4         # the reference client sends sub-indices 0..3 each frame
HEAD_HEIGHT_METERS = 1.6


def _i32(value):
    return (value + 0x80000000) % 0x100000000 - 0x80000000


class ClockOffset:
    """SVLRoot::SymmetricTimingUpdate (docs/svl-timing/clock-sync.md): tracks
    the smallest believable (local - peer) difference, in microseconds."""

    def __init__(self):
        self.offset = 0
        self.confidence = 0

    def update(self, peer_time, local_time):
        difference = _i32(local_time - peer_time)
        if self.confidence == 0:
            self.offset, self.confidence = difference, 1
            return
        k = 1_000_000 // (self.confidence + 5)
        error = difference - self.offset
        if error <= 0:
            if error >= -(k // 2):
                self.offset -= min(100, (-error * k) // 200_000)
                self.confidence = min(400, self.confidence + 1)
            elif self.confidence < 20:
                self.confidence = 0
            else:
                self.confidence -= 4
        elif error > k:
            self.confidence = max(0, self.confidence - 1)
        else:
            self.offset += min(5, (error * k) // 2_000_000)
            self.confidence = min(400, self.confidence + 1)


def packed_pose(position, tracked=True):
    """PackedPose_t, 88 bytes: position in meters in the play space, identity
    orientation (w first), zero velocities, identity offset pose."""
    if not tracked:
        return bytes(88)
    return (struct.pack("<3f", *position) + struct.pack("<4f", 1, 0, 0, 0)
            + bytes(24)                          # linear and angular velocity
            + struct.pack("<HBx", 200, 2)        # tracking result Running_OK, state valid
            + struct.pack("<3f4f", 0, 0, 0, 1, 0, 0, 0) + bytes(4))


@dataclass
class Stats:
    datagrams_in: int = 0
    bad_checksum: int = 0
    frames: int = 0
    frame_bytes: int = 0
    descriptors: int = 0
    audio_messages: int = 0
    kinds: dict = field(default_factory=dict)
    first_frame_at: float = 0.0                           # seconds after start
    frame_times: dict = field(default_factory=dict)       # frame id -> host tx_time (us)
    audio_seconds: dict = field(default_factory=dict)     # whole second -> audio messages
    host_values: dict = field(default_factory=dict)       # the host's string->double keys, latest


class Client:
    def __init__(self, session, log=print, omit=()):
        """`omit`: value ids to leave unpublished, for finding out which ones
        the host needs."""
        self.link = svl.link_from_token(session.token)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
        self.sock.connect((session.host, session.port))
        self.sock.setblocking(False)
        self.log = log
        self.start = time.monotonic()
        self.seq = 0
        self.values = ValueTransport()
        self.clock = ClockOffset()
        self.assembler = FrameAssembler()
        self.stats = Stats()
        self.frame_period = 1.0 / profile.REFRESH_HZ
        self.frame_id = 0
        self.frame_start = 0        # SVL time this frame id began: the "vsync" the host paces against
        self.host_version = 0
        self.host_instance = None
        self.last_frame = (0, 0)   # (frame id, local time) of the newest completed frame
        for value_id, data in profile.startup_values(random.getrandbits(63)).items():
            if value_id not in omit:
                self.values.publish(value_id, data)
        if profile.FOCUS_EVENT not in omit:
            self.values.publish(profile.FOCUS_EVENT, bytes([5]) + bytes(51), force=True)

    def now(self):
        """The SVL clock: microseconds since this client started, as i32."""
        return _i32(int((time.monotonic() - self.start) * 1e6))

    # -- sending ----------------------------------------------------------

    def _pose_message(self, sub_index):
        now = self.now()
        header = struct.pack("<BBBBiiiiiH", 0x0A, sub_index, 0x20, 0,
                             _i32(self.clock.offset) if self.clock.confidence else 0,
                             now, now, self.frame_start, self.frame_id,
                             0)                  # reset counter: bump to ask for an IDR
        hmd_input = struct.pack("<IQBB", 9, 0, 0x08, 0xFF)       # bit 3: no controllers
        fixed = (header + hmd_input + bytes(28) * 2
                 + packed_pose((0.0, HEAD_HEIGHT_METERS, 0.0))
                 + packed_pose(None, tracked=False) * 2)
        assert len(fixed) == POSE_BLOCK
        return svl.Element(CLASS_STREAM, TYPE_POSE, 0, 0, fixed + self.values.tick(VTS_BUDGET))

    def _frame_report(self):
        frame_id, when = self.last_frame
        # decoded / accepted / display-predicted / display-flip, all the same
        # frame: this client "displays" a frame the moment it is complete.
        value = struct.pack("<IIHHIHHI", when, when, frame_id, 0, when, frame_id, 0, when)
        return svl.Element(CLASS_VIDEO_REPLY, TYPE_FRAME_REPORT, frame_id, frame_id, value)

    def _stat_values(self):
        now = self.now()
        records = b"".join(
            key.ljust(20, b"\0") + struct.pack("<di", value, now)
            for key, value in ((b"cRXpass", 100.0), (b"cRXerr", 0.0), (b"cFramePhase", 0.3)))
        return svl.Element(CLASS_STREAM, TYPE_VALUES, 0, 0, records)

    def send_tick(self, sub_index):
        elements = [self._stat_values(), self._frame_report(), self._pose_message(sub_index)]
        self.sock.send(self.link.pack(self.seq, elements))
        self.seq += 1

    # -- receiving --------------------------------------------------------

    def _values_completed(self, ids):
        for value_id in ids:
            _version, data = self.values.remote[value_id]
            if value_id == profile.HOST_INSTANCE:
                if self.host_instance not in (None, data):
                    self.log("host instance changed; republishing every value")
                if self.host_instance != data:
                    self.host_instance = data
                    self.values.republish_all()
            elif value_id == profile.DISPLAY_RATE_REQUEST:
                (hz,) = struct.unpack("<f", data[:4])
                self.frame_period = 1.0 / hz
                self.log(f"host requests {hz:.1f} Hz")
                self.values.publish(profile.REQUESTED_FRAMETIME_US,
                                    struct.pack("<I", int(1000000.5 / hz)), force=True)
            elif value_id == profile.PROP_REFRESH:
                self.log("host requests a property refresh")
                self.values.republish_all()
            else:
                self.log(f"host value {value_id:#04x}: {len(data)} bytes {data[:16].hex()}")

    def _descriptor(self, element):
        descriptor = Descriptor.parse(element)
        self.stats.descriptors += 1
        self.host_version = descriptor.version
        self.clock.update(descriptor.tx_time, self.now())
        self.stats.frame_times.setdefault(descriptor.frame_id, descriptor.tx_time)
        trailer = descriptor.trailer
        if len(trailer) >= 16 and trailer[0x0C] == 3:
            n_values, n_timing, n_vts = trailer[0x0D], trailer[0x0E], trailer[0x0F]
            for record in range(n_values):
                key, value, _when = struct.unpack_from("<20sdi", trailer, 0x10 + 32 * record)
                if key[0]:
                    self.stats.host_values[key.rstrip(b"\0").decode(errors="replace")] = value
            start = 0x10 + 32 * n_values + 8 * n_timing
            self._values_completed(self.values.receive(trailer[start:start + n_vts]))

    def receive(self, on_frame):
        while True:
            try:
                data = self.sock.recv(2084)
            except (BlockingIOError, ConnectionRefusedError):
                return
            datagram = self.link.unpack(data)
            if datagram is None:
                continue
            self.stats.datagrams_in += 1
            if not datagram.checksum_ok:
                self.stats.bad_checksum += 1
                continue
            for element in datagram.elements:
                self.stats.kinds[element.kind] = self.stats.kinds.get(element.kind, 0) + 1
                if element.cls == CLASS_VIDEO:
                    if element.type == TYPE_DESCRIPTOR:
                        self._descriptor(element)
                    if done := self.assembler.accept(element):
                        frame_id, frame = done
                        self.last_frame = (frame_id, self.now())
                        self.stats.frames += 1
                        self.stats.first_frame_at = self.stats.first_frame_at or time.monotonic() - self.start
                        self.stats.frame_bytes += len(frame)
                        on_frame(frame_id, frame)
                elif element.cls == CLASS_STREAM and element.type == TYPE_VALUE_TRANSPORT:
                    self._values_completed(self.values.receive(element.value))
                elif element.cls in (6, 0x0B, 0x0C):
                    self.stats.audio_messages += 1
                    second = int(time.monotonic() - self.start)
                    self.stats.audio_seconds[second] = self.stats.audio_seconds.get(second, 0) + 1
                elif element.cls == 8:
                    self.log(f"host message: {element.value[4:].decode(errors='replace')}")

    def close(self):
        """Tell the host the session is over, the way the reference client's
        scene destructor does: sequence 0xffff, one empty class-3 type-0x13
        message, five times 100 ms apart (docs/svl-transport/connection-lifecycle.md)."""
        goodbye = self.link.pack(0xFFFF, [svl.Element(CLASS_STREAM, 0x13, 0, 0, b"")])
        for _ in range(5):
            self.sock.send(goodbye)
            time.sleep(0.1)
        self.sock.close()

    # -- main loop --------------------------------------------------------

    def run(self, seconds, on_frame):
        deadline = time.monotonic() + seconds
        next_tick = time.monotonic()
        next_report = time.monotonic() + 1
        sub_index = 0
        while time.monotonic() < deadline:
            self.receive(on_frame)
            now = time.monotonic()
            if now >= next_tick:
                self.send_tick(sub_index)
                sub_index = (sub_index + 1) % POSES_PER_FRAME
                if sub_index == 0:
                    self.frame_id += 1
                    self.frame_start = self.now()
                next_tick += self.frame_period / POSES_PER_FRAME
            if now >= next_report:
                stats = self.stats
                self.log(f"t={now - self.start:5.1f}s in={stats.datagrams_in} frames={stats.frames} "
                         f"({stats.frame_bytes} B, {self.assembler.dropped} incomplete) "
                         f"audio={stats.audio_messages} unacked={[hex(i) for i in self.values.pending]}")
                next_report += 1
            time.sleep(0.0005)
        return self.stats
