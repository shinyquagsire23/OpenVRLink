# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The value-transport system (docs/svl-values/value-transport-wire-format.md).

A "latest value wins" replication layer: each side publishes values by id,
chopped into 128-byte chunks, and repeats every chunk until the peer acks it.
Its bytes ride inside other messages (the pose packet going up; type-0x0d
messages and frame descriptors coming down).
"""
import struct
from dataclasses import dataclass, field

CHUNK = 128
MAX_VALUE = 0x800000


@dataclass
class _Outgoing:
    data: bytes
    version: int
    unacked: set = field(default_factory=set)


@dataclass
class _Incoming:
    version: int
    data: bytearray
    missing: set


def _chunk_count(size):
    return -(-size // CHUNK)


class ValueTransport:
    def __init__(self):
        self._local = {}        # id -> _Outgoing currently being delivered
        self._staged = {}       # id -> bytes waiting for the previous value to be acked
        self._acks_owed = []    # (version, id, chunk)
        self._inprogress = {}   # id -> _Incoming
        self.remote = {}        # id -> (version, bytes), complete values from the peer
        self._cursor = 0

    # -- sending ----------------------------------------------------------

    def publish(self, value_id, data, force=False):
        """Set a local value. Unchanged values are not re-sent unless forced
        (the reference client calls a forced update an event)."""
        current = self._local.get(value_id)
        if not force and value_id not in self._staged and current and current.data == data:
            return
        self._staged[value_id] = bytes(data)

    def republish_all(self):
        """What the reference client does when the host's instance id (value 2)
        changes: send every value again under a new version."""
        for value_id, outgoing in self._local.items():
            self._staged.setdefault(value_id, outgoing.data)

    def _promote(self):
        for value_id in list(self._staged):
            current = self._local.get(value_id)
            if current and current.unacked:
                continue  # the previous value is still in flight
            version = (current.version + 1) & 0x7F if current else 1
            data = self._staged.pop(value_id)
            self._local[value_id] = _Outgoing(data, version, set(range(_chunk_count(len(data)))))

    def tick(self, budget):
        """Bytes to attach to the next carrier message: acks first, then every
        unacked chunk that fits, round-robin by id."""
        self._promote()
        out = bytearray()
        while self._acks_owed and len(out) + 4 <= budget:
            version, value_id, chunk = self._acks_owed.pop(0)
            out += struct.pack("<BBH", version, value_id, chunk)
        ids = sorted(self._local)
        ordered = [i for i in ids if i >= self._cursor] + [i for i in ids if i < self._cursor]
        for value_id in ordered:
            outgoing = self._local[value_id]
            for chunk in sorted(outgoing.unacked):
                piece = outgoing.data[chunk * CHUNK:(chunk + 1) * CHUNK]
                if len(out) + 8 + len(piece) > budget:
                    self._cursor = value_id
                    return bytes(out)
                out += struct.pack("<BBHI", 0x80 | outgoing.version, value_id, chunk,
                                   len(outgoing.data)) + piece
        self._cursor = 0
        return bytes(out)

    @property
    def pending(self):
        """Ids whose current value the peer has not fully acked."""
        return sorted(i for i, o in self._local.items() if o.unacked) + sorted(self._staged)

    # -- receiving --------------------------------------------------------

    def receive(self, buffer):
        """Parse value-transport bytes from the peer. Returns the ids whose
        value completed with this call."""
        completed = []
        offset = 0
        while offset + 4 <= len(buffer):
            first, value_id, chunk = struct.unpack_from("<BBH", buffer, offset)
            version = first & 0x7F
            if not first & 0x80:                                  # an ack for one of our chunks
                outgoing = self._local.get(value_id)
                if outgoing and outgoing.version == version:
                    outgoing.unacked.discard(chunk)
                offset += 4
                continue
            if offset + 8 > len(buffer):
                break
            (total,) = struct.unpack_from("<I", buffer, offset + 4)
            if total > MAX_VALUE or total <= chunk * CHUNK:
                break
            size = min(CHUNK, total - chunk * CHUNK)
            piece = buffer[offset + 8:offset + 8 + size]
            offset += 8 + size
            # Every data chunk is acked, duplicates and unknown ids included,
            # or the host repeats it forever.
            self._acks_owed.append((version, value_id, chunk))
            done = self.remote.get(value_id)
            incoming = self._inprogress.get(value_id)
            if incoming is None or incoming.version != version:
                if incoming is None and done and done[0] == version:
                    continue                                      # duplicate of a finished value
                incoming = self._inprogress[value_id] = _Incoming(
                    version, bytearray(total), set(range(_chunk_count(total))))
            if chunk in incoming.missing:
                incoming.data[chunk * CHUNK:chunk * CHUNK + size] = piece
                incoming.missing.discard(chunk)
                if not incoming.missing:
                    self.remote[value_id] = (version, bytes(incoming.data))
                    del self._inprogress[value_id]
                    completed.append(value_id)
        return completed
