# OpenVRLink client

For architecture details, see [docs/client-architecture.md](../docs/client-architecture.md).

## Build and run

macOS viewer (Swift 5.9 or later, macOS 14 or later):

```
swift run -c release OpenVRLink [host address]
```

With no address it looks for Steam hosts on the local network. Drag to look around, W A S D to move, X to swap eyes, 
space for the pretend controller's trigger.

visionOS app (Xcode with the visionOS 26 SDK or later). The headset needs to be already paired with the Mac for development:

```
cd visionOS && ./run.sh          # generate the project, build, install, launch
cd visionOS && ./run.sh --build  # build only
```

The signing team is read from this Mac's Apple Development certificate, and the bundle id is made from that team (`dev.openvrlink.<team>.OpenVRLink`), so your build has its own non-conflicting bundle ID. `OPENVRLINK_TEAM` and 
`OPENVRLINK_BUNDLE_ID` can override the team and bundle ID if needed.

To run tests: `swift test`.

The first time either client meets a host it shows a PIN to type into Steam on that host. The pairing secret 
and the settings are kept in the OpenVRLink data folder (`~/Library/Application Support/OpenVRLink` on macOS, 
the app's Documents folder on visionOS).

## Layout

Everything compiles into one Swift package.

| target | what's there | platform-specific frameworks |
|---|---|---|
| `VRLinkCore` | The Big One: the protocol, pairing, the session, FEC and retransmission, timing, geometry, where the picture stands in the world, hands, gestures, settings, the gaze and face calibration maths | none (Foundation, sockets, swift-crypto) |
| `VRLinkVideoToolbox` | decoder: HEVC, H.264, AV1 | VideoToolbox |
| `VRLinkMetal` | graphics: draws the core's quads from a decoded frame | Metal |
| `VRLinkAppleAudio` | audio out, microphone in | AVFAudio |
| `VRLinkAppleNetwork` | which network interfaces are wired | Network |
| `VRLinkAppleFace` | face landmarks from a camera picture | AVFoundation, Vision |
| `VRLinkAppleSession` | finding a host, pairing, a session that can stop and start again; the settings store | (the Apple backends above) |
| `VRLinkVisionTracking` | visionOS: head, hands, controllers, haptics, pinches | ARKit, GameController |
| `VRLinkVisionCompositor` | visionOS: the stream in a compositor layer | CompositorServices |
| `VRLinkVisionExperiments` | visionOS: the RealityKit renderer, Persona face and eye tracking, their calibrations | RealityKit |
| `OpenVRLink` | the macOS viewer | AppKit, MetalKit |
| `visionOS/` | the visionOS app: scenes, wiring, settings views | SwiftUI |

## On the PC

- **Controllers.** A PlayStation VR2 Sense controller is presented to SteamVR as a Touch controller drawn with the Sense model. 
  The model has to be put on the PC once: run `tools/install-sense-model.ps1` there (it copies and adapts the models from SteamVR's own `playstation_vr2` driver folder), then restart SteamVR.
- **Face and eye tracking for other programs** (VRChat through VRCFaceTracking, for instance): in SteamVR's Steam Link settings turn on
  OSC, face tracking over OSC, and sharing eye tracking. Install the Steam Link module in VRCFaceTracking and give both the same port. SteamVR only offers these when the client says it has eye or face tracking, which it does when the Persona experiment is on.

## Settings and experiments

Kept in `settings.json` in the data folder and shared by both clients; the
table and the reasoning are in the architecture document under "Settings"
and "Experiments". The experiments (off by default, on their own tab in the
visionOS app) are a RealityKit renderer, face and eye tracking read off the
wearer's Spatial Persona, and the two calibrations those need.

## Licence

[Mozilla Public License 2.0](../LICENSE) except where headers say specifically otherwise.
