# Client architecture

## Rendering

A frame from the host is a set of pictures, each rendered from a known eye position through a known frustum. 
The core turns each eye frame into a quad standing in the world, in meters, built from the rendering eye's 
position and its right/up/forward axes.

Since a world-space renderer is practically the default setup for XR runtimes, this allows VRLinkCore to be portable across platforms with minimal fuss:

- Late-stage reprojection needs no special case. If the head has turned since the host rendered, the rectangle is just seen from a different pose.
- The fovea is one more rectangle with a feathered edge.
- The math one has to check by eye is the same code for all platforms.

Transforms done by the different graphics backends should be kept minimal (space conversions, etc)

What a session hands on with each frame is a `FrameLayout`: for each eye, where the
host's eye was and a list of tiles, each a part of one decoded picture and the part of
that eye's view it fills. Steam's VR Link gives two tiles an eye from one atlas (base and
fovea); WiVRn gives each eye a picture of its own, squeezed in bands, which comes to a
grid of tiles (`docs/wivrn/protocol.md`). `Composition` turns tiles into quads and knows
nothing of either protocol.

```swift
struct Quad {                    // produced by the core, per frame, per eye
    var corners: [Vec3]          // world space, meters: top-left, top-right, bottom-left, bottom-right
    var atlasRect: Rect          // which part of the decoded picture it shows
    var picture: Int             // which of the frame's decoded pictures
    var feather: Float           // soft border, as a fraction of its width
}
struct EyeView {                 // produced by the XR runtime (or a window), per displayed frame
    var eye: Pose                // world space
    var frustum: Frustum         // tangents
}
```

## Protocols

Both Valve's Steam VR Link (`StreamSession`) and WiVRn (`WiVRnSession`) are supported. 
Displays, decoders and app shells see either as a `StreamingSession`, which provides a 
common interface between both. Both Steam and WiVRn hosts are listed side-by-side in the
host browser (WiVRn does its discovery via mDNS though, which means Apple devices will
have to split functionality for discovery there).

## Targets

| library | handles | imports | current target |
|---|---|---|---|
| core | protocol, pairing, session, FEC, timing, geometry, frame composition (`[Quad]`), settings, calibration math | Foundation, POSIX sockets, the system's cryptography on Apple platforms and swift-crypto elsewhere | `VRLinkCore` |
| XR runtime | where the eyes are and when the next frame will be displayed; the surfaces to draw into | CompositorServices *or* OpenXR | `VRLinkVisionCompositor` |
| tracking and input | head pose, controller and hand poses, buttons and axes, haptics out | ARKit + GameController *or* OpenXR | `VRLinkVisionTracking` |
| graphics | draw quads through eye views, from a decoded frame | Metal *or* Vulkan | `VRLinkMetal` |
| decoder | access units in, decoded frames out | VideoToolbox *or* a platform decoder | `VRLinkVideoToolbox` |
| audio | PCM out, microphone in | CoreAudio *or* a platform API | `VRLinkAppleAudio` |
| session glue | find a host, pair, start and stop a session with its decoder and audio; settings while the app runs | the backends of its platform | `VRLinkAppleSession` |
| experiments | things that may not last, kept where nothing depends on them | whatever they need | `VRLinkVisionExperiments`, `VRLinkAppleFace` |
| app shells | wiring, window or immersive space, settings UI | the platform's app framework | `OpenVRLink` (macOS viewer), `client/visionOS` |

Apple-specific frameworks are avoided outside of Apple-specific code, and further delineation happens either with ifdefs or separate libraries (ex, macOS vs visionOS).

## Libraries

### XR runtime core

Provides the eye views, the predicted display time, and where to draw.

The display's refresh rate can change while streaming--visionOS moves between 45, 60, 90, 96 and 120 Hz 
depending on the performance state and environment, and gives applications very little control, so the 
XR runtime has to report the current refresh period every frame and send it to the Core. 
When the period changes, the session re-publishes its refresh-rate value with the new rate and the host 
switches the stream without a restart (`docs/svl-timing/refresh-rate.md`, captured).

Eye positions are **not** constant on every headset, especially not those with pupil swim correction. 
visionOS moves each view by a few millimeters as the eye behind it turns (a pupil swings around the 
middle of its eyeball), and the host cannot be given new eye geometry mid-session. 
The runtime needs to be careful not to accidentally return eye saccades as a rapid head velocity, and 
some amount of the pupil swim correction can be merged into the sent head pose (and is still corrected
from the worldspace-based rendering). 

The predicted display time is also tied to poses: the pose message's target-time field and the frame 
reports the host receives both are derived from it (`docs/svl-tracking-input/poses.md`, `docs/svl-video/retransmit.md`).

### XR runtime inputs/outputs

OpenXR puts head pose, controller poses, buttons and haptics behind one API.
visionOS does not: world and hand tracking come from ARKit, controller buttons
and haptics from GameController, and the frame timing from CompositorServices.
So the core asks for three things independently instead of modeling a single
"XR input API":

```swift
protocol HeadTracking   { func head(at time: DisplayTime) -> TrackedPose }      // pose + velocities
protocol HandTracking   { func hand(_ side: Side, at time: DisplayTime) -> TrackedPose?   // controller grip or tracked hand
                          func skeleton(_ side: Side, at time: DisplayTime) -> HandSkeleton? }
protocol ControllerInput { func state(_ side: Side) -> ControllerState          // buttons, triggers, sticks, touches
                           func vibrate(_ side: Side, _ pulse: HapticPulse) }
```

What crosses the seam for a controller is one `ControllerState` per hand (`VRLinkCore/Input.swift`),
which contains the grip pose in world space plus buttons named for the Touch controller the host is 
shown. 
The platform maps whatever is really held onto those names, and the core owns the wire encoding and 
publishes the controller's identity to the host the first time a hand holds one.

An OpenXR backend implements all three from one session. A visionOS backend implements the first two 
from ARKit providers and the third from GameController, and is responsible for making the pose of a 
controller and its buttons describe the same instant.

All poses cross this API seam in the same world space the quads use.

### Decoder -> graphics

Zero-copy is a property of a decoder *and* a graphics backend together (VideoToolbox with Metal; 
MediaCodec with Vulkan through AHardwareBuffer; a Windows decoder with Vulkan through a shared texture). 
The decoder produces an opaque `DecodedFrame`, and the graphics backend declares which kinds it can 
sample--the app shell pairs ones that match. Not every decoder works with every graphics backend, by design.

In general, all-in-one graphics backends/decoder backends are to be avoided, in favor of platform-specific
APIs which give much finer control over the final output.

Other guidelines:

- No color conversion must happen on the CPU.
- Prefer a texture format whose sampler converts YCbCr to RGB (on Metal, the private formats 500/505/508, which the draft takes this path with VideoToolbox's `'&xf0'` output). A conversion in the fragment shader is the fallback.
- Request no output pixel format from the decoder where the platform allows--asking for one costs a conversion which wastes bandwidth and power.

Lifecycle (not fully implemented yet):

- Frames are decoded immediately after receiving and wait in a short queue. 
  The client compositor takes frames from the queue and renders them, with some
  bookkeeping to keep the queue from piling up too much.
- The decoded frame must stay alive until the GPU has finished with it--the graphics 
  backend holds it until its command buffer completes.
- The decoder's buffer pool has to be at least the queue depth plus the frame on 
  screen plus the decoder's own references (a minimum of 3).
- The host sends parameter sets whose bytes change with rate control. The decoder must 
  take them without being rebuilt, or it loses its reference frames

### Audio

Raw 48 kHz stereo PCM both ways with XOR parity (`docs/svl-audio/`), with a jitter buffer,
source and sink.

The sink has one other function beyond playing: **keeping itself alive.** On visionOS, this
means babysitting CoreAudio to make sure the OS doesn't randomly drop audio when the app is
backgrounded, a notification happens, etc etc. Somehow it's wildly inconsistent about what
kills the audio session versus what doesn't.

## Session lifecycle

A headset app can be backgrounded at any time: the headset comes off, the crown is
pressed, another app takes over, etc. Instead of exiting on background, this client 
is designed around the ability to be backgrounded at any time whatsoever, which means
handling it in Core rather than just the app shell.

```
idle -> connecting -> streaming -> suspended -> connecting -> streaming ...
                          \________________________/
                           background / headset doffed     foreground / donned
```

- **Suspend** (app backgrounded, immersive space dismissed, headset doffed):
  say goodbye to the host, stop the session thread, flush the decoder and the
  decoded-frame queue, stop audio. Nothing is kept that depends on the old
  stream.
- **Resume** (foregrounded and the immersive space is back): ask the host for
  a session again and start a new one. A session string is only good for one
  connection, so resuming is always a fresh streaming request on UDP 27036. 
  Pairing is not repeated.
- SteamVR stays up for about 30 s after a client drops
  (`docs/svl-values/startup-exchange.md`), and while it is up a returning
  client gets video within a quarter of a second and the running game is still
  there. After that the host is cold and the resume takes a few seconds while
  SteamVR starts.
- The core exposes one object that owns "the connection to this host" and
  can be told `suspend()` and `resume()`. The app shell maps its platform's
  scene-phase and headset-worn signals onto those two calls. Decoder, graphics
  and audio backends must all tolerate being stopped and started again in one
  process.

Choosing a host is also part of this lifecycle:

- The first connection is always a choice made by the user: the entry
  window lists the hosts that answered discovery and takes a typed address.
- The chosen host stays chosen for as long as the app lives. A resume goes
  back to that host without asking, and without the window having to be open.
- Launching the app from its icon always shows the window, and does not
  connect by itself, even if a host was chosen last time.

On visionOS, there are no APIs to fetch display measurements outside of an immersive space.
The host has to be told about the displays before starting the stream, so once per run of the 
app a compositor layer is opened for a moment only to measure eye positions, frusta and refresh rate.

On visionOS, taking the headset off and putting it back on pauses and resumes 
the immersive space, and the stream comes back by itself; backgrounding the app 
does not disturb it.
When the system closes the immersive space, the stream ends and the window offers 
the list again.
Frames of the ended stream are dropped at once, so a resume shows the waiting backdrop
rather than the last picture of the old session.

Not handled yet: keeping the stream alive through a short interruption instead of dropping 
it (the host's 30 s window might allow it), and what the user sees while a resume is in progress.

## Networking quirks and minutiae

Apple's platforms are strict about broadcast and multicast: on visionOS, iOS, iPadOS, etc
a datagram to 255.255.255.255 or `ff02::1` fails with "No route to host" unless the app 
holds the multicast entitlement, which is granted by request.
The workaround is to send the same discovery probe as unicast to every address of the local 
subnet by hand, taken from the interface's address and netmask, and the host answers as usual. 
It refuses subnets wider than a /22 (1022 addresses) rather than sweep half of one silently, 
and takes an explicit address list instead.

The client does discovery the same way on every platform, instead of branching the code on Apple/not-Apple:

- sweep the local subnet with unicast probes (hosts answer a unicast probe from any source port)
- always probe hosts paired before, by their last known address
- let the user type an address, for subnets too wide to sweep and for hosts on another network
  (or for routers and firewalls that drop discovery protocols)

Networking also prefers wired ethernet over wireless interfaces where possible. For visionOS, this
is connected using a USB-C ethernet dongle via the developer strap. TBD how this will work on other
platforms (it might be interesting to drive a Wi-Fi dongle from userspace). Figuring out which interfaces
are wired is handled per-platform.

The app also needs the local-network permission prompt to be granted on Apple platforms, and early
networking packets can be dropped until the user accepts the prompt. (TODO: maybe remind the user if
things seem too silent).

## Configuration storage

Settings and pairing secrets go in one folder named `OpenVRLink` in the platform's per-user data location 
(See also `VRLinkCore/DataDirectory.swift`). These paths are roughly `XDG_DATA_HOME`-shaped, but I don't
like `XDG_CONFIG_HOME` so we'll pretend it doesn't exist.

| platform | folder |
|---|---|
| Linux, Android | `$XDG_DATA_HOME/OpenVRLink`, defaulting to `~/.local/share/OpenVRLink` |
| Windows | `%LOCALAPPDATA%\OpenVRLink` (`AppData\Local`) |
| macOS | `~/Library/Application Support/OpenVRLink` |
| iOS, visionOS | `OpenVRLink` inside the app's Documents folder |

These folders hold the client configuration as well as all the pairing keys gathered.

(TODO: garbage collection on the pairing keys?)

Settings are stored to `settings.json` in the data folder, written by `Sources/VRLinkCore/Settings.swift`.
The settings file is both backward and forward compatible, and **not** platform-unique, so not all settings
will apply to all platforms.

## Experiments

Off unless asked for, on their own tab, and expected to break.

### Face and eyes from a camera picture of the face

For platforms that give an app no face or eye tracking but do give it a picture of the user's face.
On visionOS that picture is the Spatial Persona: the "front camera" delivers the Persona as the system 
draws it, and its face and eyes move as the user's do.

| step | where |
|---|---|
| camera pictures, Apple's face-landmark detector | `VRLinkAppleFace/FaceCamera.swift` (also runs on a Mac's camera) |
| landmarks to the 70 FB expression weights and to pupil positions | core, `FaceFromLandmarks.swift` |
| pupil positions to a gaze direction | core, `GazeCalibration.swift` |
| joining camera, settings and calibration on visionOS | `Sources/VRLinkVisionExperiments/PersonaTracking.swift` |
| the calibration space (RealityKit) | `Sources/VRLinkVisionExperiments/GazeCalibrationSpace.swift` |
| the RealityKit renderer that lets the Persona's camera follow the head | `Sources/VRLinkVisionExperiments/RealityKitDisplay.swift` |

**Where the Persona's camera is:** The system pictures the Persona as seen from the SwiftUI view marked 
`cameraAnchor`. With the ordinary renderer that can only be the app's window: a compositor layer cannot 
hold a view. The exact rules for the Persona camera are a bit fiddly, but the gist is that a RealityKit 
space with no windows can override where the Persona camera is placed, and the Persona camera will chase
any new updates rapidly if the entity is enabled/disabled.

### Drawing the stream with RealityKit

`Sources/VRLinkVisionExperiments/RealityKitDisplay.swift`, modeled after ALVR's renderer:

- Each decoded frame is flattened by the ordinary quad renderer into one texture, the left eye 
  in the lower half and the right in the upper: per eye the base tile with the foveal tile over 
  it, seen from exactly where the host's eye was, so the pass only resamples. 1.6 texture pixels 
  per tile pixel each way (at most 3072), to keep most of the fovea's detail.
- Each eye has a plane in the world filling the host's frustum for that eye, 80 m out (70 m for 
  the right, so the two do not fight). Its material (ALVR's `SBSMaterial.usda`, the `_L` and `_R`
  variants) shows its half of the texture to its own eye and nothing to the other.
  RealityKit then does what the compositor path does itself: it draws that world-space rectangle
  from wherever the eyes are when the frame is shown.
- Three textures and plane pairs are used in turn and only the newest is enabled, so that a texture 
  and the place of its planes always change in the same RealityKit frame.
- RealityKit says nothing about the displays: it relies on the measurement taken before the
  first connection (`MeasuredDisplay`, see the lifecycle above).
- RealityKit does not say when a change will be seen. A display link gives the time of each refresh, 
  and what RealityKit is handed is shown a whole number of refreshes later, enough to cover its drawing 
  time (a running average, about 14 ms): that is the display time the session is told, and so the 
  time head and hand poses aim at (`VsyncPrediction`, ALVR's method).

It costs a second pass over every pixel, has no display foveation (yet) and no rate-map gaze (yet). 
The calibration space is RealityKit too, so that the pupils are seen from the same camera position 
when calibrating as when streaming; it puts the app's window away while it runs (the Persona's camera 
stays at an open window whatever else is offered), shows its instructions under the dots, and brings 
the window back when it ends.

**Gaze.** For each eye the estimator gives, after turning the face level:

- the pupil's place between the eye's corners (`across`, -0.5 ... 0.5)
- its height against the middle of the eye's outline (`down`, in eye widths)
- its height against the line through the two corners (`belowCorners`), and 
- how open the lids are (`open`). 

The last two are there because the lids follow the eye: the outline moves with 
the pupil, so `down` alone hardly changes when looking up or down (seen on the 
headset as a gaze that stuck vertically), while the corners stay put and the lids
lower as the eye does. The two eyes are averaged. A calibration maps these to the 
gaze's two tangents in the head's frame:

```
    across = k . [1, a, d, a*a, a*d, d*d, c, o]        up = likewise, own k
```

fitted by least squares to pairs of (features, true direction). 

The true direction comes from the one place visionOS reveals it: a pinch at a distance 
arrives with a ray from the eyes to what they looked at. The calibration space shows 
nineteen dots 1.5 m ahead that turn with the head (so that the eyes turn, not the head); 
for each, the user looks and pinches, and the pinch's ray, moved into the head's frame, 
is paired with the features averaged over the 0.4 s before. Everything past the plane is
held back slightly (ridge) and left out altogether under ten samples. The fit and its error 
on its own samples go into `settings.json`. The gaze sent is given a fixed 1.5 m length and smoothed. 
It is held only while both eyes are fully shut: lids merely lowered, as when looking down, 
used to count as a blink and froze it. With no calibration no gaze is sent from the RealityKit 
renderer.

**Continuous calibration** (setting `continuousGazeCalibration`, off by default; core
`GazeCalibration.tuned`, joined up in `PersonaTracking.learn`). The fit of the headset shifts
while it is worn and between wearings. With this on, every pinch made at a distance while
streaming is one more pair, taken exactly as in the calibration space: the pinch's ray in the
head's frame, with the features averaged over the 0.4 s before. The calibration keeps its
samples (up to 60) and is fitted again with each new one:

- A pair more than 0.35 (tangent, about 19 degrees) from what the calibration expects is left
  out: nobody was asked to hold their eyes still, so some readings are of eyes in motion.
  A shift larger than that needs the calibration run again.
- Once there are 60, the new pair replaces the old one that looked nearest to the same spot.
  Pinches cluster in the middle; dropping the oldest instead would leave nothing at the edges.
- Each sample counts 0.97 of the one after it, so the newest say most.

The tuned calibration is used at once, and written to `settings.json` when the stream ends,
not at each pinch (a settings change makes SwiftUI look at the stream's view again, which can
cost the Persona's camera its place). A calibration saved before samples were kept cannot be
tuned; it has to be run once more.

Focal distance: only the ray's direction is used, and the features are the average of the two
eyes, so the eyes turning in for something near should cancel. This is **inferred**; the whole
mode is untried on the headset.

**Face calibration.**  A face calibration (core `FaceCalibration.swift`,
`Sources/VRLinkVisionExperiments/FaceCalibrationSpace.swift`) replaces parameters tuned for just 
me with the user's own: a panel shows their Persona and asks for nine expressions in turn 
(rest, jaw open, smile, frown, pucker, brows up, brows down, eyes closed, eyes wide), and each is
counted in and then measured for a little over a second. What is measured are ten lengths in the 
picture over the face's size (`FaceMeasures`: mouth gap and width, each mouth corner's drop, each
brow's lift, each eye's openness). Each weight sent is then how far the face has gone from its 
resting measurement towards the one at that expression's fullest, 0 to 1. Expressions with no pose 
of their own stay at zero. Where the eyes look (the eight `eyesLook` weights) is taken from the 
calibrated gaze when there is one. Weights are smoothed with a 50 ms time constant.

## Dependencies

- **Crypto: the operating system's on Apple platforms** (CryptoKit, CommonCrypto, Security), so
  the app carries no cryptography of its own; **swift-crypto elsewhere**, and none of it is built
  into an Apple build. The choice is made by `#if` in one file of the core (`Primitives`), the one
  exception to backends being handed in; known-answer tests hold both halves to the same results.
  swift-crypto builds for Windows and Android. Pairing uses its X25519, SHA-256, 
  AES-CBC, single-block AES (for the wrapped IV) and RSA-OAEP with SHA-1 (`_RSA.Encryption.Padding.PKCS1_OAEP`);
  all are present in 3.x
- **Protobuf: No thanks.** It's only four messages, so we serialize by hand (`VRLinkCore/Protobuf.swift`)

## Remaining work

1. **visionOS**: any remaining missing features
2. **Windows helper**: Installs PSVR2 assets, maybe also patches driver_vrlink for features (better transport encoding)
3. **Windows**: Vulkan, OpenXR, a platform decoder and audio (aka, Dis-integration Hell). Not a real user-facing target, but easier to debug.
4. **Android**: reuses Vulkan and OpenXR, irons out all the visionOS-specifics.

## Open questions

- Which decoder on Windows (vendor SDKs, Media Foundation, or Vulkan Video), and how its output reaches Vulkan without extra copies.
- Whether the host needs the client's display time to be exact, or only consistent (the delivered-versus-agreed frame rate question in
  `docs/svl-values/startup-exchange.md`).
- The color pipeline: the stream signals BT.2020 primaries and gamma 2.2, and vrlink tells its decoder it's "linear".
- How controller identity should be presented on platforms whose controllers are not the Quest Touch set vrlink describes.
