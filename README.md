# OpenVRLink

An open-source client compatible with Valve's Steam VR Link pairing and streaming protocol, written in Swift for visionOS (and eventually other platforms).

## Added features

 - (visionOS) Persona-based dynamic foveation (30Hz, slow), with eye gaze calibration
 - (visionOS) Persona-based face tracking, with calibration
 - Chroma keying, with the option to disable it in games only
 - Gaze-pinch interactions
 - Double-clack controllers to swap between controllers and hand tracking
 - Horizontal and vertical FoV adjustment
 - Improved backgrounding/foregrounding behavior

## Building

```
cd client/visionOS
./run.sh
```

## Components

| where | wat |
|---|---|
| [`docs/`](docs/README.md) | protocol docs |
| [`client/`](client/README.md) | Swift client, not a ton of platform delineation yet |
| `prototype/minimal/` | Python probe for trying things against a real host |

The client runs immersed on visionOS and as a windowed viewer on macOS. Windows and Android are planned and the code is arranged for them (see also: [docs/client-architecture.md](docs/client-architecture.md)).

## Licence

[Mozilla Public License 2.0](LICENSE) except where headers say specifically otherwise.

OpenVRLink is not affiliated with or endorsed by Valve. Steam, SteamVR and Steam Link are trademarks of Valve Corporation.
