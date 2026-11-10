# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The protobuf messages of Steam's broadcast protocol on UDP 27036, as far
as the VR path uses them (docs/remoteplay/messages.md).

This is this project's own description of the wire format: only the messages
and fields the probe sends or reads, written out below as a table. Fields a
host sends that are not listed are skipped when parsing, as protobuf allows.
The descriptor is built from the table when the module is loaded, so there
is no protoc step and no generated code.

The names are the ones the protocol's own messages carry, which is also what
the documentation calls them.
"""
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

# Enumerations: name -> {value name: number}.
ENUMS = {
    # What a datagram's body is (the header's msg_type).
    "ERemoteClientBroadcastMsg": {
        "k_ERemoteClientBroadcastMsgDiscovery": 0,
        "k_ERemoteClientBroadcastMsgStatus": 1,
        "k_ERemoteClientBroadcastMsgOffline": 2,
        "k_ERemoteDeviceAuthorizationRequest": 3,
        "k_ERemoteDeviceAuthorizationResponse": 4,
        "k_ERemoteDeviceStreamingRequest": 5,
        "k_ERemoteDeviceStreamingResponse": 6,
        "k_ERemoteDeviceProofRequest": 7,
        "k_ERemoteDeviceProofResponse": 8,
        "k_ERemoteDeviceAuthorizationCancelRequest": 9,
        "k_ERemoteDeviceStreamingCancelRequest": 10,
        "k_ERemoteClientBroadcastMsgClientIDDeconflict": 11,
        "k_ERemoteDeviceStreamTransportSignal": 12,
        "k_ERemoteDeviceStreamingProgress": 13,
        "k_ERemoteDeviceAuthorizationConfirmed": 14,
    },
    # Whether a host can serve VR Link (in its status).
    "EVRLinkCaps": {
        "k_EVRLinkCapsUnknown": 0,
        "k_EVRLinkCapsAvailable": 1,
        "k_EVRLinkCapsUnimplemented": 2,
        "k_EVRLinkCapsMissingHardwareEncoding": 3,
    },
    # How a pairing request came out.
    "ERemoteDeviceAuthorizationResult": {
        "k_ERemoteDeviceAuthorizationSuccess": 0,
        "k_ERemoteDeviceAuthorizationDenied": 1,
        "k_ERemoteDeviceAuthorizationNotLoggedIn": 2,
        "k_ERemoteDeviceAuthorizationOffline": 3,
        "k_ERemoteDeviceAuthorizationBusy": 4,
        "k_ERemoteDeviceAuthorizationInProgress": 5,
        "k_ERemoteDeviceAuthorizationTimedOut": 6,
        "k_ERemoteDeviceAuthorizationFailed": 7,
        "k_ERemoteDeviceAuthorizationCanceled": 8,
    },
    # How a session request came out.
    "ERemoteDeviceStreamingResult": {
        "k_ERemoteDeviceStreamingSuccess": 0,
        "k_ERemoteDeviceStreamingUnauthorized": 1,
        "k_ERemoteDeviceStreamingScreenLocked": 2,
        "k_ERemoteDeviceStreamingFailed": 3,
        "k_ERemoteDeviceStreamingBusy": 4,
        "k_ERemoteDeviceStreamingInProgress": 5,
        "k_ERemoteDeviceStreamingCanceled": 6,
        "k_ERemoteDeviceStreamingDriversNotInstalled": 7,
        "k_ERemoteDeviceStreamingDisabled": 8,
        "k_ERemoteDeviceStreamingBroadcastingActive": 9,
        "k_ERemoteDeviceStreamingVRActive": 10,
        "k_ERemoteDeviceStreamingPINRequired": 11,
        "k_ERemoteDeviceStreamingTransportUnavailable": 12,
        "k_ERemoteDeviceStreamingInvisible": 13,
        "k_ERemoteDeviceStreamingGameLaunchFailed": 14,
        "k_ERemoteDeviceStreamingSteamVRNotInstalled": 15,
    },
}

# Messages: name -> [(field number, type, field name)]. A type is a protobuf
# scalar type, "enum:<name>" or "message:<name>"; a leading "repeated " makes
# it a list. "Outer.Inner" is a message nested in another.
MESSAGES = {
    "CMsgRemoteClientBroadcastHeader": [
        (1, "uint64", "client_id"),
        (2, "enum:ERemoteClientBroadcastMsg", "msg_type"),
        (3, "uint64", "instance_id"),
        (5, "bytes", "device_token"),
    ],
    "CMsgRemoteClientBroadcastDiscovery": [
        (1, "uint32", "seq_num"),
        (2, "repeated uint64", "client_ids"),
    ],
    "CMsgRemoteClientBroadcastClientIDDeconflict": [
        (2, "repeated uint64", "client_ids"),
    ],
    "CMsgRemoteClientBroadcastStatus": [
        (1, "int32", "version"),
        (2, "int32", "min_version"),
        (3, "uint32", "connect_port"),
        (4, "string", "hostname"),
        (6, "uint32", "enabled_services"),
        (9, "repeated message:CMsgRemoteClientBroadcastStatus.User", "users"),
        (11, "int32", "euniverse"),
        (12, "uint32", "timestamp"),
        (13, "bool", "screen_locked"),
        (14, "bool", "games_running"),
        (18, "bool", "vr_active"),
        (20, "repeated string", "ip_addresses"),
        (22, "bool", "remoteplay_active"),
        (26, "enum:EVRLinkCaps", "vr_link_caps"),
        (28, "fixed64", "connected_paired_network_hash"),
        (29, "bool", "wifi_dongle_present"),
    ],
    "CMsgRemoteClientBroadcastStatus.User": [
        (1, "fixed64", "steamid"),
        (2, "uint32", "auth_key_id"),
    ],
    "CMsgRemoteDeviceAuthorizationRequest": [
        (1, "bytes", "device_token"),
        (2, "string", "device_name"),
        (3, "bytes", "encrypted_request"),
        (4, "bytes", "auth_key"),
        (5, "uint32", "request_id"),
    ],
    # What `encrypted_request` holds before it is encrypted.
    "CMsgRemoteDeviceAuthorizationRequest.CKeyEscrow_Ticket": [
        (1, "bytes", "password"),
        (2, "uint64", "identifier"),
        (3, "bytes", "payload"),
        (4, "uint32", "timestamp"),
        (5, "int32", "usage"),
        (6, "string", "device_name"),
        (7, "string", "device_model"),
        (8, "string", "device_serial"),
        (9, "uint32", "device_provisioning_id"),
    ],
    "CMsgRemoteDeviceAuthorizationCancelRequest": [],
    "CMsgRemoteDeviceAuthorizationResponse": [
        (1, "enum:ERemoteDeviceAuthorizationResult", "result"),
        (2, "fixed64", "steamid"),
        (3, "bytes", "auth_key"),
        (4, "bytes", "device_token"),
    ],
    "CMsgRemoteDeviceAuthorizationConfirmed": [
        (1, "enum:ERemoteDeviceAuthorizationResult", "result"),
    ],
    "CMsgRemoteDeviceStreamingRequest": [
        (1, "uint32", "request_id"),
        (2, "int32", "maximum_resolution_x"),
        (3, "int32", "maximum_resolution_y"),
        (4, "int32", "audio_channel_count"),
        (5, "string", "device_version"),
        (6, "bool", "stream_desktop"),
        (7, "bytes", "device_token"),
        (8, "bytes", "pin"),
        (9, "bool", "enable_video_streaming"),
        (10, "bool", "enable_audio_streaming"),
        (11, "bool", "enable_input_streaming"),
        (12, "bool", "network_test"),
        (13, "uint64", "client_id"),
        (14, "repeated int32", "supported_transport"),
        (15, "bool", "restricted"),
        (16, "int32", "form_factor"),
        (17, "int32", "gamepad_count"),
        (19, "uint64", "gameid"),
        (20, "int32", "stream_interface"),
    ],
    "CMsgRemoteDeviceStreamingCancelRequest": [
        (1, "uint32", "request_id"),
    ],
    "CMsgRemoteDeviceStreamingProgress": [
        (1, "uint32", "request_id"),
        (2, "float", "progress"),
    ],
    "CMsgRemoteDeviceStreamingResponse": [
        (1, "uint32", "request_id"),
        (2, "enum:ERemoteDeviceStreamingResult", "result"),
        (3, "uint32", "port"),
        (4, "bytes", "encrypted_session_key"),
        (6, "int32", "transport"),
        (7, "string", "relay_server"),
        (8, "string", "cert"),
    ],
    "CMsgRemoteDeviceProofRequest": [
        (1, "bytes", "challenge"),
        (2, "uint32", "request_id"),
        (3, "bool", "update_secret"),
    ],
    "CMsgRemoteDeviceProofResponse": [
        (1, "bytes", "response"),
        (2, "uint32", "request_id"),
        (3, "bool", "updated_secret"),
    ],
    "CMsgRemoteDeviceStreamTransportSignal": [
        (1, "bytes", "token"),
        (2, "bytes", "payload"),
    ],
}


def _build():
    F = descriptor_pb2.FieldDescriptorProto
    scalars = {name: getattr(F, "TYPE_" + name.upper())
               for name in ("uint64", "uint32", "int32", "bytes", "string", "bool", "float", "fixed64")}
    file = descriptor_pb2.FileDescriptorProto(name="openvrlink_broadcast.proto", syntax="proto2")
    for name, values in ENUMS.items():
        enum = file.enum_type.add(name=name)
        for value_name, number in values.items():
            enum.value.add(name=value_name, number=number)
    made = {}
    # Outer messages before the ones nested in them.
    for name in sorted(MESSAGES, key=lambda n: n.count(".")):
        outer, _, short = name.rpartition(".")
        message = (made[outer].nested_type if outer else file.message_type).add(name=short)
        made[name] = message
        for number, kind, field_name in MESSAGES[name]:
            repeated = kind.startswith("repeated ")
            kind = kind.removeprefix("repeated ")
            field = message.field.add(name=field_name, number=number,
                                      label=F.LABEL_REPEATED if repeated else F.LABEL_OPTIONAL)
            if kind.startswith("enum:"):
                field.type, field.type_name = F.TYPE_ENUM, "." + kind[5:]
            elif kind.startswith("message:"):
                field.type, field.type_name = F.TYPE_MESSAGE, "." + kind[8:]
            else:
                field.type = scalars[kind]
    pool = descriptor_pool.DescriptorPool()
    pool.Add(file)
    return pool


_pool = _build()


def message(name):
    """The message class for a name, e.g. 'CMsgRemoteClientBroadcastHeader'."""
    return message_factory.GetMessageClass(_pool.FindMessageTypeByName(name))


def enum(name):
    return _pool.FindEnumTypeByName(name)
