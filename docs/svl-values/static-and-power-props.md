# Device properties: static props, power props, host defaults

Device properties travel over the wire as fixed-size packed C structs rather
than JSON. JSON is only `vrlink`'s *local* configuration format
(`assets/config/hmd_config.json` and `assets/config/controller_config.json` in
the APK); on the wire, each device's properties are sent as one VTS value (see
[value-transport-wire-format.md](value-transport-wire-format.md)).

All offsets below are file offsets in `libvrlink_scene.so`. Fields are
little-endian with no padding (all three structs are byte-packed; 0x489 is odd).

## 1. `VTE_StaticProps_t` — 1161 bytes (0x489)

Sent as `VTE_PROPS_STATIC_HMD` (id 0x0d), `VTE_PROPS_STATIC_L` (0x0e),
`VTE_PROPS_STATIC_R` (0x0f).

| off | size | field | valid bit | JSON key in the APK config |
|---|---|---|---|---|
| 0x000 | u32 | `valid_mask` | — | always `0x7ff` as sent by `vrlink` |
| 0x004 | char[128] | tracking system | 0x001 | `sTrackingSystem` |
| 0x084 | char[128] | serial number | 0x002 | `sSerialNumber` |
| 0x104 | char[128] | manufacturer | 0x004 | `sManufacturerName` |
| 0x184 | char[128] | model number | 0x008 | `sModelNumber` |
| 0x204 | char[128] | render model name | 0x010 | `sRenderModelName` |
| 0x284 | char[128] | resource root | 0x020 | `sResourceRoot` |
| 0x304 | char[128] | input profile path | 0x040 (see note) | `sInputProfilePath` |
| 0x384 | float32 | laser-mouse HMD angle, degrees | 0x080 (see note) | `flLaserMouseHmdAngleDegrees` |
| 0x388 | char[128] | controller type | 0x100 | `sControllerType` |
| 0x408 | char[128] | device type | 0x200 (see note) | `sDeviceType` |
| 0x488 | u8 | driver type | 0x400 (see note) | `ubDriverType` |

Strings are NUL-terminated C strings in zero-filled 128-byte fields (the struct
is `memset` to 0, then `strcpy`'d).

- Struct size, field offsets, the order the mask bits are OR'd in, and the
  source offsets in `SVLStaticProps` come from `PackVTEProps(SVLStaticProps
  const&, VTE_StaticProps_t&)` (+0x10d388), with size 0x489 passed at the
  `UpdateValue` call sites in `QSVLClient::UpdateFrameVariables` (+0xf5248)
  (**static**).
- The JSON keys and the order they are read into `SVLStaticProps` come from
  `QSVLDeviceHmd::GetStaticProps` (+0x1000b4, **static**). `sDeviceType` is
  *not* read from the HMD JSON; instead, it is formatted as
  `"<sTrackingSystem>/<sSerialNumber>"` (`tssprintf("%s/%s", …)` stored at
  `SVLStaticProps+0xc8`).
- String slot assignments were verified by reassembling ids 0x0d, 0x0e, and
  0x0f from capture `vr3` (both versions of each, with every chunk intact,
  whereas `vr1` had to be pieced together from untorn datagrams) (**captured**).
  The decoded payloads have `valid_mask = 0x7ff` and match the APK's `hollywood`
  HMD entry and `/interaction_profiles/oculus/touch_controller` left/right
  entries at the offsets above (`oculus`, `VRLINKHMDQUEST2`, `Oculus`,
  `Oculus Quest2`, `generic_hmd`, `vrlink`, `{oculus}/input/rift_profile.json`,
  0.0, `rift`, `oculus/VRLINKHMDQUEST2`, driver type 0, plus the corresponding
  controller strings).
- The individual bit pairing for 0x040/0x080 and 0x200/0x400 is **inferred**:
  `PackVTEProps` ORs `0xc0` after writing both the input-profile string and the
  float, and ORs `0x600` after writing the device-type string and the
  driver-type byte, so the table assumes ascending bit order.

### Property sources

| VTE id | source | notes |
|---|---|---|
| 0x0d HMD | `hmd_config.json` → `staticProps[<product name>]` | key is `GetDeviceProductName()` (Android `ro.product.name`-style, e.g. `hollywood` = Quest 2, `eureka` = Quest 3). If the key is missing, `vrlink` logs `[DeviceHMD] Unable to find device static props for "%s"` and sends a generic set: serial `GENERICHMD1`, manufacturer from the OS, model = product name lower-cased with spaces → `_`, device type `generic`, everything else empty. **static** +0x1000b4 |
| 0x0e / 0x0f controllers | `controller_config.json` → `staticProps[<active interaction profile>]["left"\|"right"]` | chosen by the OpenXR interaction profile currently bound for that hand; re-sent when the profile changes (`XrSceneStream::HandleUpdateInteractionProfile` +0x118d.. calls `RequestVariableUpdate` four times). If no profile is known for the hand, nothing is sent for that hand (the dirty flag stays set and it is retried every frame). **static** `QSVLClientXR::GetStaticProp` +0xfb2d4, `QSVLXRInput::GetStaticProps` +0x1069ec |
| 0x0e / 0x0f hand tracking | hard-coded, used when the hand has no interaction profile, the host version is ≥ 7 and `XRQContext+0x118e+hand` is set | in slot order: tracking system `vrlink`; serial `VRLINKQ_Hand_Left` / `VRLINKQ_Hand_Right`; manufacturer `VRLink`; model `VRLink Hand Tracker (Left Hand)` / `(Right Hand)`; render model `shuttlecock`; resource root `vrlink`; input profile `{vrlink}/input/svl_hand_interaction_augmented_input_profile.json`; laser-mouse angle 0; controller type `svl_hand_interaction_augmented`; device type `vrlink/VRLINKQ_HandTracker_Left` / `_Right`; **driver type 1** (controllers and the HMD send 0). **static** `QSVLXRInput::GetStaticProps` +0x1069ec. The `valid_mask` is added by the common packer, so 0x7ff (**inferred**, not seen on the wire for a hand) |

`QSVLXRInput::GetStaticProps` receives a third argument, the host protocol
version taken from the last bookend (`SVLRoot+0xba8`, copied from
`SVLVideoFrameDescriptor_t+0x20` in `QSVLClient::ReceivedBookend` +0xf6cf8).
How the host protocol version affects the output was not traced (**open**).

### Example (built from the APK's config, Quest 2 `hollywood`)

Local JSON:

```json
{ "sTrackingSystem": "oculus", "sSerialNumber": "VRLINKHMDQUEST2",
  "sManufacturerName": "Oculus", "sModelNumber": "Oculus Quest2",
  "sRenderModelName": "generic_hmd", "sResourceRoot": "vrlink",
  "sInputProfilePath": "{oculus}/input/rift_profile.json",
  "flLaserMouseHmdAngleDegrees": 0, "sControllerType": "rift",
  "sDeviceType": "oculus/VRLINKHMDQUEST2" }
```

Wire value for VTE 0x0d (**captured**: this function reproduces the 1161
bytes `vrlink` sent):

```python
import struct
def pack_static(p):
    s = lambda k: p.get(k, "").encode()[:127].ljust(128, b"\0")
    return (struct.pack("<I", 0x7FF)
            + s("sTrackingSystem") + s("sSerialNumber") + s("sManufacturerName")
            + s("sModelNumber") + s("sRenderModelName") + s("sResourceRoot")
            + s("sInputProfilePath")
            + struct.pack("<f", p.get("flLaserMouseHmdAngleDegrees", 0.0))
            + s("sControllerType") + s("sDeviceType")
            + bytes([p.get("ubDriverType", 0)]))          # 1161 bytes
```

Left Touch controller (`/interaction_profiles/oculus/touch_controller`, `left`):
`oculus` / `VRLINKQ2_Controller_Left` / `Oculus` / `Oculus Quest2 (Left
Controller)` / `oculus_quest2_controller_left` / `vrlink` /
`{oculus}/input/touch_profile.json` / 0.0 / `oculus_touch` /
`oculus/VRLINKQ2_Controller_Left` / driver type 0.

HMD entries shipped in the APK (key → serial, model, controller type):
`hollywood` VRLINKHMDQUEST2 "Oculus Quest2" rift; `seacliff` VRLINKHMDQUESTPRO;
`stinson`, `eureka` VRLINKHMDQUEST3; `panther` VRLINKHMDQUEST3S; `PICO 4`
VRLINKHMDPICO4 (pico); `PICO 4 Enterprise`, `PICO 4 Pro`
VRLINKHMDPICO4PROORENTERPRISE; `PICO 4 Ultra` VRLINKHMDPICO4ULTRA; `kona`
VRLINKHMDVIVEFOCUSVISION (vive_focus, `{htc}/input/vive_controller_profile.json`);
`A7P10` VRLINKHMDPICONEO3; `unknown` VRLINKHMDUNKNOWN. The `unknown` entry
exists in the file but the code path that would select it was not found — the
missing-key path builds the hard-coded generic set instead (**static**).

How the host maps these strings onto SteamVR driver properties is mostly
host-side (see [Host handling of controller strings (2026-11-10)](#host-handling-of-controller-strings-2026-11-10)
below for what `vrserver.txt` revealed); the safest default for an
interoperable client is to reuse one of the shipped sets verbatim.

## 2. `VTE_PowerProps_t` — 12 bytes

Sent as ids 0x10 (HMD), 0x11 (left), 0x12 (right). No `VTE_*` name string for
these exists in `libvrlink_scene.so`; `VTE_PROPS_POWER_HMD/L/R` is our own
label (**inferred** naming).

| off | size | field |
|---|---|---|
| 0 | u32 | `valid_mask` = `0x3f` |
| 4 | u32 | flags: bit n = `SVLPowerProps` bool n, n = 0..4 |
| 8 | float32 | battery level |

Layout and packing come from `PackVTEProps(SVLPowerProps const&,
VTE_PowerProps_t&)` (+0x10d52c, **static**).

For the HMD (`QSVLDeviceHmd::GetPowerProps` +0x100d60, **static**), `vrlink`
sets bools 0, 1, 3, and 4 to `1`, bool 2 to `IsHmdBatteryCharging()`, and the
float to `GetHmdBatteryLevel()`. Thus the HMD sends flags `0x1b` (not charging)
or `0x1f` (charging). In `vr3` (**captured**), the HMD sent
`3f 00 00 00 | 1b 00 00 00 | 33 33 73 3f` (battery 0.95, confirming a 0..1
fraction), and both controllers sent `3f 00 00 00 | 1a 00 00 00 | 00 00 00 00`
(flags 0x1a = bools 1, 3, 4; battery 0.0). The exact names of bools 0, 1, 3,
and 4 are **unknown**; by analogy with OpenVR's
`Prop_DeviceProvidesBatteryStatus_Bool`, `Prop_DeviceIsWireless_Bool`,
`Prop_DeviceIsCharging_Bool`, and `Prop_DeviceCanPowerOff_Bool`, they likely
correspond to "provides battery status / is wireless / is charging / …"
(**inferred**).

The controller variant (`QSVLXRInput::GetPowerProps` +0x106ff4, **static**)
returns constants for either hand, whether controller or tracked hand: bools
{0, 1, 0, 1, 1} and battery 0.0 (`3f 00 00 00 | 1a 00 00 00 | 00 00 00 00`),
matching what `vr3` captured for both controllers.

Power props are re-published on a timer: posted event type 4 re-arms the three
dirty flags (`QSVLClient::HandleEvent` +0xf4bec, **static**), and `UpdateValue`
transmits only if the 12 bytes changed.

## 3. `VTE_HostDefaults_t` — 8 bytes (`VTE_HOST_DEFAULTS`, id 0x15)

`PackVTEProps(SVLHostDefaults const&, VTE_HostDefaults_t&)` +0x10d370 ignores
its input and writes constants (**static**):

| off | size | value |
|---|---|---|
| 0 | u32 | `3` (valid mask, two fields) |
| 4 | u16 | `1` |
| 6 | u16 | `0` |

On the wire this is always `03 00 00 00 01 00 00 00` (**captured**). The
meaning of the two fields is **unknown** (`QSVLClientXR::GetHostDefaults`
+0xfb2c8 sets a `u16 = 1`, i.e. two `bool`s `true, false`, which `PackVTEProps`
then ignores).

## Open questions

Capture `vr1` (re-verified on the complete `vr3` capture with identical bytes)
confirmed the string offsets, `valid_mask == 0x7ff`, the 0..1 fractional range
for battery level, and the host-defaults payload. In `vr3`, each of the three
static-prop values took five pose packets (~10 ms) to transmit and all three
were acked within 35 ms of the session's first datagram; the power props and
host defaults followed in a single pose packet at 30 ms. As shown by the
cold-host probes in [startup-exchange.md](startup-exchange.md), a cold host
requires the HMD's static and power props (0x0d and 0x10), not the
controllers'.

1. What are the OpenVR property names for power-prop bools 0, 1, 3, and 4, and
   does any `vrlink` build ever send real controller battery data instead of
   `0x1a` / `0.0`?
2. Does the host honor `valid_mask` when sent a partial struct with fewer bits
   set?
3. What does `ubDriverType != 0` select on the host?

## Reporting battery levels from our client (2026-11-11)

`client/` sends the headset's power flags the same way `vrlink` does (`0x1b`,
or `0x1f` when charging) along with the reported battery level, updating
whenever the level changes by at least 1%. For controllers whose battery status
the platform reports, `client/` sends those same flag sets (`0x1b` / `0x1f`)
and the reported level, whereas `vrlink` always sends `0x1a` and `0.0`.
Treating flag bit 0 as "provides a battery level" is **inferred** from `vrlink`
setting it on the headset and clearing it on controllers. Whether SteamVR
displays either battery reading in its UI has not yet been verified on the
host.

## Host handling of controller strings (2026-11-10)

The results below were **captured** from the host's `vrserver.txt` (which logs
each string as `driver_vrlink` creates the device) across three cold starts
with different right-controller strings:

| controller type | model number | render model sent | result |
|---|---|---|---|
| `playstation_vr2_sense` | PlayStation VR2 Sense (Right) | `{playstation_vr2}playstation_vr2_sense_right` | `[SVLController] Activate Error: Unsupported controller type "playstation_vr2_sense"`; the device is not activated |
| `oculus_touch` | Oculus Quest2 (Right Controller) | `{playstation_vr2}playstation_vr2_sense_right` | `[SVLController] Overriding Quest specific properties for Oculus Quest2 (Right Controller)`; SteamVR loads its own `oculus_quest2_controller_right` model |
| `oculus_touch` | PlayStation VR2 Sense (Right) | `{playstation_vr2}playstation_vr2_sense_right` | `[SVLController] Finished activation`; SteamVR loads the model from `drivers\playstation_vr2\resources\rendermodels` and draws it, with the Touch input profile in force |

`sControllerType` must match a profile known to `driver_vrlink` (Touch, Pico,
Vive Focus 3, or its hand tracker), while `sRenderModelName` and the display
names are otherwise unrestricted, except that a Quest model number causes
`driver_vrlink` to substitute its own Quest properties and render model. A
serial number that a running SteamVR instance has already registered keeps its
existing properties, so string changes take effect only from a cold start.

In the headset using the third row's strings, SteamVR draws the PS VR2 model
aligned to the hand once the grip offset pose is set to
`(0.002, 0.0097, -0.1196)` m with 5.037 degrees of pitch around X. However,
the rendered trigger, buttons, and thumbstick do not animate when the physical
controls move. Inspecting the render model's JSON on the host (**captured**)
explains why: each moving part is bound to a PS VR2 input path (`/input/r2`,
`/input/cross/click`, `/input/right_stick`, `/input/r1`), whereas a device
registered with `sControllerType = "oculus_touch"` exposes Touch input paths
(`/input/trigger`, `/input/a/click`, `/input/joystick`, `/input/grip`), leaving
the model's component bindings unmatched. Input delivery itself works normally
through the Touch profile.
