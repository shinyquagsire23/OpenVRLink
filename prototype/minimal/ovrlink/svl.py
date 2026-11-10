# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""SVL datagram framing (docs/svl-transport/packet-format.md).

A datagram is a short header followed by elements. Two transport modes are
implemented, chosen by the session token's four-character prefix: mode 1
("XOR0", prefix MID: no cipher, a session-id-seeded XOR checksum), which a
host uses with Steam's streaming encryption off, and mode 2 (prefix AES: the
whole datagram AES-128-CBC encrypted), which it uses with encryption on.
"""
import base64
import struct

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from dataclasses import dataclass

HEADER_LEN = 8          # modes 1 and 2
ELEMENT_HEADER_LEN = 8
MAX_DATAGRAM = 1408
MAX_ELEMENT_VALUE = 0x400


def session_id_from_token(token):
    """Mode 1: the first three decoded bytes of the token, tagged 0x01."""
    if not token.startswith("MID"):
        raise ValueError(f"unsupported key identifier {token[:4]!r}")
    text = token[4:]
    decoded = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    if len(decoded) < 5:
        raise ValueError("token too short for XOR0")
    return int.from_bytes(decoded[:3], "little") | 0x01000000


def xor_fold(data, seed):
    """XOR of the datagram's little-endian u32 words, zero-padded, with a seed."""
    padded = data + bytes(-len(data) % 4)
    for (word,) in struct.iter_unpack("<I", padded):
        seed ^= word
    return seed


@dataclass
class Element:
    """One message: `u8 class | u8 type | u16 id | u16 len | u16 index | value`."""
    cls: int        # channel: 3 unreliable stream, 4 video reply, 5 video, 0xc audio, ...
    type: int       # sub-type within the class
    id: int         # per class: video frame id, reliable sequence id
    index: int      # per class: video packet id, descriptor group
    value: bytes

    @property
    def kind(self):
        """Class and type as the u16 the client's own code writes (0x0305 = video packet)."""
        return self.cls | self.type << 8

    def pack(self):
        return struct.pack("<BBHHH", self.cls, self.type, self.id, len(self.value), self.index) + self.value


@dataclass
class Datagram:
    seq: int
    elements: list
    checksum_ok: bool = True


def pack(seq, elements, session_id):
    body = b"".join(element.pack() for element in elements)
    datagram = struct.pack("<HHI", seq & 0xFFFF, 0, 0) + body
    if len(datagram) > MAX_DATAGRAM:
        raise ValueError(f"datagram of {len(datagram)} bytes exceeds {MAX_DATAGRAM}")
    checksum = xor_fold(datagram, session_id)
    return datagram[:4] + struct.pack("<I", checksum) + datagram[8:]


def unpack(data, session_id=None):
    """Parse a mode-1 datagram. Returns None for anything shorter than a header.
    With no session id the checksum is not judged."""
    if len(data) < HEADER_LEN:
        return None
    seq, _reserved, _checksum = struct.unpack_from("<HHI", data)
    elements = []
    offset = HEADER_LEN
    while len(data) - offset >= ELEMENT_HEADER_LEN:
        cls, type_, id_, length, index = struct.unpack_from("<BBHHH", data, offset)
        end = offset + ELEMENT_HEADER_LEN + length
        if length > MAX_ELEMENT_VALUE or end > len(data):
            break
        if cls == 0:            # padding: the reference client skips it and carries on
            offset = end
            continue
        elements.append(Element(cls, type_, id_, index, data[offset + ELEMENT_HEADER_LEN:end]))
        offset = end
    ok = session_id is None or xor_fold(data, session_id) == 0
    return Datagram(seq, elements, ok)


class XorLink:
    """Mode 1: datagrams in the clear, checked with the session id."""
    mode = 1

    def __init__(self, token):
        self.session_id = session_id_from_token(token)

    def pack(self, seq, elements):
        return pack(seq, elements, self.session_id)

    def unpack(self, data):
        return unpack(data, self.session_id)


class AesLink:
    """Mode 2: the token is 16 bytes of IV then 16 of key. Each datagram is
    zero-padded to a multiple of 16 bytes and encrypted whole, AES-128-CBC,
    starting from the same IV every time. After decryption the header's second
    word is a 24-bit count of sequence wraps tagged 0x02 in its top byte."""
    mode = 2

    def __init__(self, token):
        text = token[4:]
        decoded = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
        if len(decoded) < 32:
            raise ValueError("token too short for AES")
        self.iv, self.key = decoded[:16], decoded[16:32]
        self.wraps = 0
        self.last_seq = 0

    def _cipher(self):
        return Cipher(algorithms.AES(self.key), modes.CBC(self.iv))

    def pack(self, seq, elements):
        seq &= 0xFFFF
        if seq < self.last_seq and seq != 0xFFFF:
            self.wraps += 1
        self.last_seq = seq
        body = b"".join(element.pack() for element in elements)
        # The goodbye datagram (sequence 0xffff) carries a counter of all ones.
        counter = 0xFFFFFF if seq == 0xFFFF else self.wraps & 0xFFFFFF
        clear = struct.pack("<HHI", seq, 0, counter | 0x02000000) + body
        clear += bytes(((len(clear) + 0x13) & ~0xF) - len(clear))     # the reference client's padding rule
        encryptor = self._cipher().encryptor()
        return encryptor.update(clear) + encryptor.finalize()

    def unpack(self, data):
        if len(data) < 16 or len(data) % 16:
            return None
        decryptor = self._cipher().decryptor()
        clear = decryptor.update(data) + decryptor.finalize()
        datagram = unpack(clear)
        if datagram is not None:
            datagram.checksum_ok = clear[7] == 0x02 and clear[2:4] == b"\0\0"
        return datagram


def link_from_token(token):
    kind = token[:3].upper()
    if kind == "MID":
        return XorLink(token)
    if kind == "AES":
        return AesLink(token)
    raise ValueError(f"unsupported key identifier {token[:4]!r}")
