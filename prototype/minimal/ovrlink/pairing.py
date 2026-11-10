# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pairing with a Steam host and asking it to start a VR Link session.

Both conversations run over the broadcast protocol on UDP 27036
(docs/remoteplay/pairing.md, docs/remoteplay/session-request.md).
"""
import hashlib
import random
import socket
import struct
import time
from dataclasses import dataclass

from . import broadcast, proto, steamcrypto

AuthorizationRequest = proto.message("CMsgRemoteDeviceAuthorizationRequest")
AuthorizationConfirmed = proto.message("CMsgRemoteDeviceAuthorizationConfirmed")
StreamingRequest = proto.message("CMsgRemoteDeviceStreamingRequest")
ProofResponse = proto.message("CMsgRemoteDeviceProofResponse")

_auth_result = proto.enum("ERemoteDeviceAuthorizationResult").values_by_number
_stream_result = proto.enum("ERemoteDeviceStreamingResult").values_by_number

AUTH_SUCCESS, AUTH_IN_PROGRESS = 0, 5
STREAM_SUCCESS, STREAM_UNAUTHORIZED, STREAM_IN_PROGRESS = 0, 1, 5

# How often the reference client repeats a request until it is answered.
AUTHORIZATION_RESEND_SECONDS = 3
STREAMING_RESEND_SECONDS = 1


class Unauthorized(Exception):
    """The host does not know this device (or its secret); pair first."""


class Refused(Exception):
    """The host answered with a failure result."""


@dataclass
class Host:
    address: tuple          # (ip, port) the Status came from
    client_id: int          # the host's id, from its broadcast header
    status: object          # CMsgRemoteClientBroadcastStatus


@dataclass
class SessionArgs:
    """The string the shell hands the VR client as `sArgs`
    (docs/remoteplay/session-request.md)."""
    raw: str

    @property
    def fields(self):
        return self.raw.split("~")

    @property
    def host(self):
        return self.fields[0]

    @property
    def port(self):
        return int(self.fields[1])

    @property
    def token(self):
        return self.fields[7]


def find_host(sock, identity, address):
    hosts = broadcast.discover(sock, identity.device_id, [address])
    if not hosts:
        raise TimeoutError(f"{address} did not answer discovery")
    host_address, datagram = next(iter(hosts.items()))
    return Host(host_address, datagram.header.client_id, datagram.body)


def _device_token(identity, host):
    """The device id, encrypted under the secret shared with this host."""
    return steamcrypto.symmetric_encrypt(struct.pack("<Q", identity.device_id),
                                         identity.secret(host.client_id))


def _replies(sock, host, deadline):
    """Yield datagrams from this host until the deadline."""
    while (remaining := deadline - time.monotonic()) > 0:
        sock.settimeout(remaining)
        try:
            data, address = sock.recvfrom(4096)
        except socket.timeout:
            return
        datagram = broadcast.decode(data)
        if datagram and address[0] == host.address[0] and datagram.header.client_id == host.client_id:
            yield datagram


def pair(sock, identity, host, device_name, show_pin, timeout=120):
    """Run the PIN pairing. `show_pin(pin)` is called once; a person then
    types that PIN into Steam on the host. Stores the new shared secret."""
    pin = "%04u" % random.randint(1, 9999)
    exchange = steamcrypto.KeyExchange()
    request_id = random.getrandbits(32) or 1

    # Only Steam's servers can open the ticket. A host that completes the key
    # exchange itself never needs it, but the field is required.
    ticket = AuthorizationRequest.CKeyEscrow_Ticket(
        password=pin.encode(), identifier=identity.device_id,
        payload=identity.secret(host.client_id), usage=0,
        device_name=device_name, device_model="", device_serial="",
        device_provisioning_id=0)
    request = AuthorizationRequest(
        device_token=_device_token(identity, host), device_name=device_name,
        encrypted_request=steamcrypto.rsa_encrypt(ticket.SerializeToString()),
        auth_key=exchange.masked_public(pin), request_id=request_id)

    show_pin(pin)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        broadcast.send(sock, host.address, identity.device_id,
                       "k_ERemoteDeviceAuthorizationRequest", request)
        resend_at = min(deadline, time.monotonic() + AUTHORIZATION_RESEND_SECONDS)
        for datagram in _replies(sock, host, resend_at):
            if datagram.kind != "k_ERemoteDeviceAuthorizationResponse":
                continue
            response = datagram.body
            if response.result == AUTH_IN_PROGRESS:
                continue
            if response.result != AUTH_SUCCESS:
                raise Refused(_auth_result[response.result].name)
            if response.auth_key:
                secret = exchange.shared_secret(response.auth_key, pin)
                echoed = steamcrypto.symmetric_decrypt(response.device_token, secret)
                if echoed != struct.pack("<Q", identity.device_id):
                    raise Refused("host proved a different device id (wrong PIN?)")
                identity.set_secret(host.client_id, secret)
                broadcast.send(sock, host.address, identity.device_id,
                               "k_ERemoteDeviceAuthorizationConfirmed",
                               AuthorizationConfirmed(result=AUTH_SUCCESS))
            else:
                # Legacy path: Steam's servers opened the ticket and the secret
                # we put in it is now the shared one.
                identity.save()
            return response
    raise TimeoutError("nobody entered the PIN on the host")


def request_session(sock, identity, host, timeout=60, log=lambda message: None):
    """Ask the host to start SteamVR streaming. Returns SessionArgs."""
    response, session_key = request_stream(sock, identity, host, timeout=timeout, log=log)
    args = steamcrypto.symmetric_decrypt(bytes.fromhex(response.cert), session_key).decode()
    # The host omits its own address; the shell prepends it.
    return SessionArgs(host.address[0] + args if args.startswith("~") else args)


def cancel_stream(sock, identity, host, request_id):
    broadcast.send(sock, host.address, identity.device_id, "k_ERemoteDeviceStreamingCancelRequest",
                   proto.message("CMsgRemoteDeviceStreamingCancelRequest")(request_id=request_id))


def request_stream(sock, identity, host, stream_interface=4, form_factor=5, timeout=60,
                   log=lambda message: None):
    """Send a streaming request and see it through the proof. Returns the
    final CMsgRemoteDeviceStreamingResponse and the decrypted session key.

    stream_interface 4 (SteamVR) with form_factor 5 (VR headset) is a VR Link
    request; the other interfaces ask for flat Remote Play
    (docs/remoteplay/vr-vs-flat.md)."""
    request_id = random.getrandbits(32) or 1
    secret = identity.secret(host.client_id)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        request = StreamingRequest(
            request_id=request_id, maximum_resolution_x=1280, maximum_resolution_y=800,
            audio_channel_count=2, device_version="Android 10",
            device_token=_device_token(identity, host), pin=b"",
            enable_video_streaming=True, enable_audio_streaming=True,
            enable_input_streaming=True, network_test=False, client_id=host.client_id,
            supported_transport=[1, 2, 4], restricted=False,
            form_factor=form_factor, gamepad_count=0, gameid=0,
            stream_interface=stream_interface)
        broadcast.send(sock, host.address, identity.device_id,
                       "k_ERemoteDeviceStreamingRequest", request)
        resend_at = min(deadline, time.monotonic() + STREAMING_RESEND_SECONDS)
        for datagram in _replies(sock, host, resend_at):
            body = datagram.body
            if datagram.kind == "k_ERemoteDeviceProofRequest":
                if body.request_id != request_id:
                    continue
                if body.update_secret:
                    # The host rotates the secret: new = SHA-256(old || challenge).
                    secret = hashlib.sha256(secret + body.challenge).digest()
                    identity.set_secret(host.client_id, secret)
                log("proof requested")
                broadcast.send(sock, host.address, identity.device_id,
                               "k_ERemoteDeviceProofResponse",
                               ProofResponse(response=steamcrypto.symmetric_encrypt(body.challenge, secret),
                                             request_id=request_id,
                                             updated_secret=body.update_secret))
            elif datagram.kind == "k_ERemoteDeviceStreamingProgress":
                log(f"progress {body.progress:.2f}")
            elif datagram.kind == "k_ERemoteDeviceStreamingResponse":
                if body.request_id != request_id:
                    continue
                log(_stream_result[body.result].name)
                if body.result == STREAM_IN_PROGRESS:
                    continue
                if body.result == STREAM_UNAUTHORIZED:
                    raise Unauthorized()
                if body.result != STREAM_SUCCESS:
                    raise Refused(_stream_result[body.result].name)
                return body, steamcrypto.symmetric_decrypt(body.encrypted_session_key, secret)
    raise TimeoutError("host never finished starting the stream")
