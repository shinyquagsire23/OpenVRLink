# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""What this probe tells the host about itself (docs/svl-values/).

The device strings are the Quest 2 set the Steam Link client ships, reused
verbatim because what the host does with unfamiliar strings is unknown.
"""
import json
import math
import struct

# Value ids (docs/svl-values/vte-id-table.md).
CLIENT_INSTANCE = 0x01
HOST_INSTANCE = 0x02
PROJECTION = 0x04
CHAPERONE = 0x05
EYE_TO_HEAD = 0x08
REQUESTED_FRAMETIME_US = 0x0C
STATIC_HMD, STATIC_LEFT, STATIC_RIGHT = 0x0D, 0x0E, 0x0F
POWER_HMD, POWER_LEFT, POWER_RIGHT = 0x10, 0x11, 0x12
FOCUS_EVENT = 0x13
HOST_DEFAULTS = 0x15
AUDIO_CAPS = 0x18
AVAILABLE_RATES = 0x20
DISPLAY_RATE_REQUEST = 0x21
VERSION_STRING = 0x22
PROP_REFRESH = 0x2B

IPD_METERS = 0.063
REFRESH_HZ = 90.0
HALF_FOV_DEGREES = 45.0

HMD = dict(sTrackingSystem="oculus", sSerialNumber="VRLINKHMDQUEST2", sManufacturerName="Oculus",
           sModelNumber="Oculus Quest2", sRenderModelName="generic_hmd", sResourceRoot="vrlink",
           sInputProfilePath="{oculus}/input/rift_profile.json", sControllerType="rift",
           sDeviceType="oculus/VRLINKHMDQUEST2")


def _controller(side):
    return dict(sTrackingSystem="oculus", sSerialNumber=f"VRLINKQ2_Controller_{side}",
                sManufacturerName="Oculus", sModelNumber=f"Oculus Quest2 ({side} Controller)",
                sRenderModelName=f"oculus_quest2_controller_{side.lower()}", sResourceRoot="vrlink",
                sInputProfilePath="{oculus}/input/touch_profile.json", sControllerType="oculus_touch",
                sDeviceType=f"oculus/VRLINKQ2_Controller_{side}")


def static_props(props):
    """VTE_StaticProps_t, 1161 bytes."""
    def text(key):
        return props.get(key, "").encode()[:127].ljust(128, b"\0")
    return (struct.pack("<I", 0x7FF)
            + text("sTrackingSystem") + text("sSerialNumber") + text("sManufacturerName")
            + text("sModelNumber") + text("sRenderModelName") + text("sResourceRoot")
            + text("sInputProfilePath") + struct.pack("<f", 0.0)
            + text("sControllerType") + text("sDeviceType") + b"\0")


def power_props(flags, battery):
    return struct.pack("<IIf", 0x3F, flags, battery)


def eye_to_head(ipd=IPD_METERS):
    """Two row-major 3x4 matrices, left eye then right: identity rotation, the
    eye sitting half the IPD along the head's right (+x) axis, in meters."""
    def eye(x):
        return struct.pack("<12f", 1, 0, 0, x,
                                   0, 1, 0, 0,
                                   0, 0, 1, 0)
    return eye(-ipd / 2) + eye(+ipd / 2)


def projection(half_fov_degrees=HALF_FOV_DEGREES):
    """Per eye: tangents of the left, right, down, up frustum half-angles."""
    t = math.tan(math.radians(half_fov_degrees))
    return struct.pack("<4f", -t, t, -t, t) * 2


def available_rates(rates=(REFRESH_HZ,)):
    return struct.pack("<II8x", 1, len(rates)) + struct.pack(f"<{len(rates)}f", *rates)


def chaperone(universe_id):
    pose = {"translation": [0, 0, 0], "yaw": 0}
    wall = [[0, 0, 0], [0, 2.43, 0], [0, 2.43, 0], [0, 0, 0]]
    return json.dumps({"jsonid": "chaperone_info", "universes": [{
        "collision_bounds": [wall] * 4, "play_area": [0, 0], "seated": pose,
        "setup_standing2": pose, "standing": pose, "time": "Thu Jan  1 00:00:00 1970",
        "universeID": universe_id}], "version": 5}, separators=(",", ":")).encode()


def startup_values(instance_id):
    """Everything the reference client publishes before video starts."""
    return {
        CLIENT_INSTANCE: struct.pack("<Q", instance_id | 1),
        PROJECTION: projection(),
        EYE_TO_HEAD: eye_to_head(),
        AVAILABLE_RATES: available_rates(),
        VERSION_STRING: b"qvlclient;hollywood;2.0.20.1812",
        CHAPERONE: chaperone(instance_id & 0x7FFFFFFF),
        HOST_DEFAULTS: bytes.fromhex("0300000001000000"),
        STATIC_HMD: static_props(HMD),
        STATIC_LEFT: static_props(_controller("Left")),
        STATIC_RIGHT: static_props(_controller("Right")),
        POWER_HMD: power_props(0x1B, 0.95),
        POWER_LEFT: power_props(0x1A, 0.0),
        POWER_RIGHT: power_props(0x1A, 0.0),
        AUDIO_CAPS: struct.pack("<I", 3),
    }
