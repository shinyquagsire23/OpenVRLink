# Device properties: static props, power props, host defaults

The brief for this work assumed the device properties travel as JSON, but they
do not. JSON is only the client's *local* configuration format
(`assets/config/hmd_config.json`, `assets/config/controller_config.json` in the
APK); on the wire each device's properties are a fixed-size packed C struct sent
as one VTS value (see [value-transport-wire-format.md](value-transport-wire-format.md)).

Binary: `libvrlink_scene.so`; offsets are file offsets. Little-endian, no
padding (all three structs are byte-packed: 0x489 is odd).

## 1. `VTE_StaticProps_t` — 1161 bytes (0x489)

Sent as `VTE_PROPS_STATIC_HMD` (id 0x0d), `VTE_PROPS_STATIC_L` (0x0e),
`VTE_PROPS_STATIC_R` (0x0f).

| off | size | field | valid bit | JSON key in the APK config |
|---|---|---|---|---|
| 0x000 | u32 | `valid_mask` | — | always `0x7ff` as sent by this client |
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

- **static**: struct size, offsets, the order the mask bits are OR'd in, and
  the source offsets in `SVLStaticProps` — `PackVTEProps(SVLStaticProps const&,
  VTE_StaticProps_t&)` +0x10d388. Size 0x489 at the `UpdateValue` call sites in
  `QSVLClient::UpdateFrameVariables` +0xf5248.
- **static**: the JSON keys and the order they are read into `SVLStaticProps` —
  `QSVLDeviceHmd::GetStaticProps` +0x1000b4. `sDeviceType` is *not* read from
  the HMD JSON; it is rebuilt as `"<sTrackingSystem>/<sSerialNumber>"`
  (`tssprintf("%s/%s", …)` stored at `SVLStaticProps+0xc8`).
- **captured**: which string slot is which. Reassembling ids 0x0d, 0x0e and
  0x0f from capture `vr3` (both versions of each; every chunk present, where
  `vr1` had to be pieced together from untorn datagrams) gives `valid_mask = 0x7ff` and, at the offsets in the
  table, exactly the strings of the APK's `hollywood` HMD entry and the
  `/interaction_profiles/oculus/touch_controller` left/right entries
  (`oculus`, `VRLINKHMDQUEST2`, `Oculus`, `Oculus Quest2`, `generic_hmd`,
  `vrlink`, `{oculus}/input/rift_profile.json`, 0.0, `rift`,
  `oculus/VRLINKHMDQUEST2`, driver type 0; and the corresponding controller
  strings).
- **inferred**: the mask-bit ↔ field pairing for bits 0x040/0x080 and
  0x200/0x400. The code ORs `0xc0` after writing both the input-profile string
  and the float, and `0x600` after writing the device-type string and the
  driver-type byte; the table assumes ascending order.

### Where the values come from

| VTE id | source | notes |
|---|---|---|
| 0x0d HMD | `hmd_config.json` → `staticProps[<product name>]` | key is `GetDeviceProductName()` (Android `ro.product.name`-style, e.g. `hollywood` = Quest 2, `eureka` = Quest 3). If the key is missing the client logs `[DeviceHMD] Unable to find device static props for "%s"` and sends a generic set: serial `GENERICHMD1`, manufacturer from the OS, model = product name lower-cased with spaces → `_`, device type `generic`, everything else empty. **static** +0x1000b4 |
| 0x0e / 0x0f controllers | `controller_config.json` → `staticProps[<active interaction profile>]["left"\|"right"]` | chosen by the OpenXR interaction profile currently bound for that hand; re-sent when the profile changes (`XrSceneStream::HandleUpdateInteractionProfile` +0x118d.. calls `RequestVariableUpdate` four times). If no profile is known for the hand, nothing is sent for that hand (the dirty flag stays set and it is retried every frame). **static** `QSVLClientXR::GetStaticProp` +0xfb2d4, `QSVLXRInput::GetStaticProps` +0x1069ec |
| 0x0e / 0x0f hand tracking | hard-coded, used when the hand has no interaction profile, the host version is ≥ 7 and `XRQContext+0x118e+hand` is set | in slot order: tracking system `vrlink`; serial `VRLINKQ_Hand_Left` / `VRLINKQ_Hand_Right`; manufacturer `VRLink`; model `VRLink Hand Tracker (Left Hand)` / `(Right Hand)`; render model `shuttlecock`; resource root `vrlink`; input profile `{vrlink}/input/svl_hand_interaction_augmented_input_profile.json`; laser-mouse angle 0; controller type `svl_hand_interaction_augmented`; device type `vrlink/VRLINKQ_HandTracker_Left` / `_Right`; **driver type 1** (controllers and the HMD send 0). **static** `QSVLXRInput::GetStaticProps` +0x1069ec. The `valid_mask` is added by the common packer, so 0x7ff (**inferred**, not seen on the wire for a hand) |

`QSVLXRInput::GetStaticProps` receives a third argument, the host protocol
version taken from the last bookend (`SVLRoot+0xba8`, copied from
`SVLVideoFrameDescriptor_t+0x20` in `QSVLClient::ReceivedBookend` +0xf6cf8).
What it changes was not traced (**open**).

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
bytes the real client sent):

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

An interoperable client is free to send any strings; what the host does with
them (which SteamVR driver properties they become) is host-side and unknown.
The safest choice is to reuse one of the shipped sets verbatim.

## 2. `VTE_PowerProps_t` — 12 bytes

Sent as ids 0x10 (HMD), 0x11 (left), 0x12 (right). No `VTE_*` name string for
these exists in the client; `VTE_PROPS_POWER_HMD/L/R` is our label
(**inferred** naming).

| off | size | field |
|---|---|---|
| 0 | u32 | `valid_mask` = `0x3f` |
| 4 | u32 | flags: bit n = `SVLPowerProps` bool n, n = 0..4 |
| 8 | float32 | battery level |

**static**: `PackVTEProps(SVLPowerProps const&, VTE_PowerProps_t&)` +0x10d52c.

For the HMD (`QSVLDeviceHmd::GetPowerProps` +0x100d60, **static**) the client
sets bools 0, 1, 3, 4 to `1` and bool 2 to `IsHmdBatteryCharging()`, and the
float to `GetHmdBatteryLevel()`. So the HMD sends flags `0x1b` (not charging) or
`0x1f` (charging). **captured**: HMD `3f 00 00 00 | 1b 00 00 00 | 33 33 73 3f`
(battery 0.95, so the float is a 0..1 fraction); both controllers
`3f 00 00 00 | 1a 00 00 00 | 00 00 00 00` (flags 0x1a = bools 1, 3, 4; battery
0.0 — a run without real controllers' battery data). The names of bools 0, 1, 3, 4 are **unknown**; by analogy
with OpenVR's `Prop_DeviceProvidesBatteryStatus_Bool`,
`Prop_DeviceIsWireless_Bool`, `Prop_DeviceIsCharging_Bool`,
`Prop_DeviceCanPowerOff_Bool` they are probably "provides battery status / is
wireless / is charging / …" (**inferred**).

The controller variant (`QSVLXRInput::GetPowerProps` +0x106ff4, **static**)
is a constant for either hand, controller or tracked hand: bools
{0, 1, 0, 1, 1} and battery 0.0, i.e. `3f 00 00 00 | 1a 00 00 00 |
00 00 00 00`, which is exactly what `vr3` captured for both controllers.

Power props are re-published on a timer: posted event type 4 re-arms the three
dirty flags (`QSVLClient::HandleEvent` +0xf4bec, **static**), and `UpdateValue`
then only transmits if the 12 bytes changed.

## 3. `VTE_HostDefaults_t` — 8 bytes (`VTE_HOST_DEFAULTS`, id 0x15)

`PackVTEProps(SVLHostDefaults const&, VTE_HostDefaults_t&)` +0x10d370 ignores
its input and writes constants (**static**):

| off | size | value |
|---|---|---|
| 0 | u32 | `3` (valid mask, two fields) |
| 4 | u16 | `1` |
| 6 | u16 | `0` |

Wire bytes: `03 00 00 00 01 00 00 00` (**captured** identical). Meaning of the two fields: **unknown**
(`QSVLClientXR::GetHostDefaults` +0xfb2c8 sets a `u16 = 1`, i.e. two `bool`s
`true, false`, which the packer then discards).

## Open questions / to confirm on the wire

Resolved by capture (`vr1`, re-checked on the complete `vr3` with identical
bytes): string offsets, `valid_mask == 0x7ff`, battery float is a 0..1
fraction, host-defaults bytes. In `vr3` each of the three static-prop values
took five pose packets (about 10 ms) to send and all three were acked within
35 ms of the session's first datagram; the power props and host defaults
followed in a single pose packet at 30 ms. Whether the host needs all three
static-prop values is answered by the probe results in
[startup-exchange.md](startup-exchange.md): a cold host needs the HMD's (0x0d,
and its power props 0x10), not the controllers'.

1. Names of power-prop bools 0, 1, 3, 4, and the controller flag values on a
   real headset (the capture shows 0x1a with battery 0.0).
4. Does the host honor `valid_mask` (send a partial struct with fewer bits)?
5. What `ubDriverType != 0` selects on the host.

## Client behavior (2026-11-11): real battery values

`client/` sends the headset's flags as vrlink does (0x1b, or
0x1f when charging) with the real level, again whenever it changes by a
percent. For a controller whose battery the platform reports it sends the
same two flag sets and the level, where vrlink always sends
0x1a and 0.0; that flag 0 means "has a battery level to show" is
**inferred** from vrlink setting it only for its headset.
Not yet checked on the host: that SteamVR shows either value.

## Client results (2026-11-10): what the host does with controller strings

**Captured** from the host's `vrserver.txt`, which echoes each string as the
vrlink driver creates the device, across three cold starts with different
strings for the right controller:

| controller type | model number | render model sent | result |
|---|---|---|---|
| `playstation_vr2_sense` | PlayStation VR2 Sense (Right) | `{playstation_vr2}playstation_vr2_sense_right` | `[SVLController] Activate Error: Unsupported controller type "playstation_vr2_sense"`; the device is not activated |
| `oculus_touch` | Oculus Quest2 (Right Controller) | `{playstation_vr2}playstation_vr2_sense_right` | `[SVLController] Overriding Quest specific properties for Oculus Quest2 (Right Controller)`; SteamVR loads its own `oculus_quest2_controller_right` model |
| `oculus_touch` | PlayStation VR2 Sense (Right) | `{playstation_vr2}playstation_vr2_sense_right` | `[SVLController] Finished activation`; SteamVR loads the model from `drivers\playstation_vr2\resources\rendermodels` and draws it, with the Touch input profile in force |

So the controller type must be one the driver knows (the profiles it ships
are Touch, Pico, Vive Focus 3 and its hand tracker), the render model and
names are otherwise free, and a Quest model number triggers a substitution
of the driver's own. A serial number that a running SteamVR has already seen
keeps its old properties: changes only show from a cold start.

Reported from the headset with the third row's strings: the PS VR2 model is
drawn in the hand once the offset pose is (0.002, 0.0097, -0.1196) m with
5.037 degrees of pitch about x. Its trigger, buttons and stick do not move
with the real ones. **captured** (the model's JSON on the host): each moving
part is tied to a PS VR2 input path (`/input/r2`, `/input/cross/click`,
`/input/right_stick`, `/input/r1`), while a device of the Touch type has
Touch paths (`/input/trigger`, `/input/a/click`, `/input/joystick`,
`/input/grip`), so the model finds nothing to follow. The inputs themselves
are unaffected; they go through the Touch profile.
