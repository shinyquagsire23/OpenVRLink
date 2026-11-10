# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Steam's Remote Client broadcast protocol on UDP 27036.

Discovery, pairing and the request that starts a VR Link session all ride on
this one datagram format (docs/remoteplay/broadcast-packet.md):

    ff ff ff ff 21 4c 5f a0     magic
    u32le header_len            CMsgRemoteClientBroadcastHeader
    header
    u32le body_len              the message named by header.msg_type
    body
"""
import random
import socket
import struct
import time
from dataclasses import dataclass

from . import proto

PORT = 27036
MAGIC = bytes.fromhex("ffffffff214c5fa0")

Header = proto.message("CMsgRemoteClientBroadcastHeader")
_msg_enum = proto.enum("ERemoteClientBroadcastMsg")

# msg_type -> body message. Types with an empty or unknown body are absent.
BODY_TYPES = {
    "k_ERemoteClientBroadcastMsgDiscovery": "CMsgRemoteClientBroadcastDiscovery",
    "k_ERemoteClientBroadcastMsgStatus": "CMsgRemoteClientBroadcastStatus",
    "k_ERemoteDeviceAuthorizationRequest": "CMsgRemoteDeviceAuthorizationRequest",
    "k_ERemoteDeviceAuthorizationResponse": "CMsgRemoteDeviceAuthorizationResponse",
    "k_ERemoteDeviceStreamingRequest": "CMsgRemoteDeviceStreamingRequest",
    "k_ERemoteDeviceStreamingResponse": "CMsgRemoteDeviceStreamingResponse",
    "k_ERemoteDeviceProofRequest": "CMsgRemoteDeviceProofRequest",
    "k_ERemoteDeviceProofResponse": "CMsgRemoteDeviceProofResponse",
    "k_ERemoteDeviceAuthorizationCancelRequest": "CMsgRemoteDeviceAuthorizationCancelRequest",
    "k_ERemoteDeviceStreamingCancelRequest": "CMsgRemoteDeviceStreamingCancelRequest",
    "k_ERemoteClientBroadcastMsgClientIDDeconflict": "CMsgRemoteClientBroadcastClientIDDeconflict",
    "k_ERemoteDeviceStreamTransportSignal": "CMsgRemoteDeviceStreamTransportSignal",
    "k_ERemoteDeviceStreamingProgress": "CMsgRemoteDeviceStreamingProgress",
    "k_ERemoteDeviceAuthorizationConfirmed": "CMsgRemoteDeviceAuthorizationConfirmed",
}


def msg_type(name):
    return _msg_enum.values_by_name[name].number


def msg_name(number):
    return _msg_enum.values_by_number[number].name


@dataclass
class Datagram:
    header: object      # CMsgRemoteClientBroadcastHeader
    body: object        # decoded message, or raw bytes when the type has no known body
    trailing: bytes     # anything after the body; never seen non-empty

    @property
    def kind(self):
        return msg_name(self.header.msg_type)


def encode(header, body):
    header_bytes = header.SerializeToString()
    body_bytes = body.SerializeToString()
    return (MAGIC + struct.pack("<I", len(header_bytes)) + header_bytes
            + struct.pack("<I", len(body_bytes)) + body_bytes)


def decode(data):
    """Parse one datagram, or return None if it is not this protocol."""
    if len(data) < 16 or data[:8] != MAGIC:
        return None
    (header_len,) = struct.unpack_from("<I", data, 8)
    header_end = 12 + header_len
    if header_end + 4 > len(data):
        return None
    header = Header.FromString(data[12:header_end])
    (body_len,) = struct.unpack_from("<I", data, header_end)
    body_end = header_end + 4 + body_len
    raw = data[header_end + 4:body_end]
    body_type = BODY_TYPES.get(msg_name(header.msg_type))
    body = proto.message(body_type).FromString(raw) if body_type else raw
    return Datagram(header, body, data[body_end:])


def open_socket(bind_port=0):
    """A UDP socket for talking to hosts. Port 27036 is only needed to hear
    other machines' unsolicited broadcasts; replies come back to any port."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("", bind_port))
    return sock


def send(sock, address, client_id, kind, body, instance_id=None, device_token=None):
    header = Header(client_id=client_id, msg_type=msg_type(kind))
    if instance_id is not None:
        header.instance_id = instance_id
    if device_token is not None:
        header.device_token = device_token
    sock.sendto(encode(header, body), address)


def discover(sock, client_id, targets=("255.255.255.255",), wait=1.5, seq_num=1):
    """Send a discovery probe and collect Status replies.

    Returns {(ip, port): Datagram}. A host answers a probe addressed to it
    directly just as it answers a broadcast.
    """
    probe = proto.message("CMsgRemoteClientBroadcastDiscovery")(seq_num=seq_num)
    for target in targets:
        send(sock, (target, PORT), client_id, "k_ERemoteClientBroadcastMsgDiscovery", probe)
    hosts = {}
    deadline = time.monotonic() + wait
    while (remaining := deadline - time.monotonic()) > 0:
        sock.settimeout(remaining)
        try:
            data, address = sock.recvfrom(2048)
        except socket.timeout:
            break
        datagram = decode(data)
        if datagram and datagram.kind == "k_ERemoteClientBroadcastMsgStatus":
            hosts[address] = datagram
    return hosts


def random_client_id():
    return random.getrandbits(64)
