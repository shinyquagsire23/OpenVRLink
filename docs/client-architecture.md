# Client architecture

## Rendering

Each frame from the host consists of one or more images rendered from known eye
positions through known frusta. `VRLinkCore` converts each eye's tiles into
world-space quads (in meters) constructed from the rendered eye's position and
its right, up, and forward axes.

Because world-space rendering is standard across XR runtimes, keeping quad
composition in `VRLinkCore` keeps platform backends thin:

- Late-stage reprojection requires no special handling. If the user's head has
  rotated since the host rendered the frame, the runtime simply views the
  world-space quad from the updated eye pose.
- The foveal inset is rendered as another quad with a feathered border.
- All projection and quad-placement math lives in shared platform-independent
  code.

Transforms inside each graphics backend should stay minimal (for example,
coordinate-space conversions).

With each decoded frame, a streaming session produces a `FrameLayout` containing
the host's rendered eye pose and a list of tiles per eye, where each tile maps a
sub-rect of a decoded texture onto a sub-frustum of that eye's view. Steam VR
Link produces two tiles per eye from a single atlas texture (base and fovea).
WiVRn decodes a separate video stream per eye compressed into rectilinear
foveation bands, forming a grid of tiles (`docs/wivrn/protocol.md`), plus an
optional third alpha stream when an OpenXR app submits transparent regions. When
a frame includes alpha, the compositor clears to transparent rather than opaque
black so passthrough remains visible behind the stream. `Composition` converts
`FrameLayout` tiles into world-space `Quad` values independently of the
streaming protocol:

```swift
struct Quad {                    // produced by VRLinkCore, per frame, per eye
    var corners: [Vec3]          // world space, meters: top-left, top-right, bottom-left, bottom-right
    var atlasRect: Rect          // normalized UV sub-rect within the decoded texture
    var picture: Int             // index into the frame's decoded textures
    var feather: Float           // soft border, as a fraction of quad width
}
struct EyeView {                 // produced by the XR runtime (or a window), per displayed frame
    var eye: Pose                // world space
    var frustum: Frustum         // tangents
}
```

## Protocols

Both Valve's Steam VR Link (`StreamSession`) and WiVRn (`WiVRnSession`) are
supported. Displays, decoders, and app shells interact with both through the
common `StreamingSession` interface. Both Steam and WiVRn hosts appear side by
side in the host browser (WiVRn uses mDNS for discovery, so Apple platforms use
a separate mDNS/Bonjour discovery path alongside UDP subnet probing).

## Targets

| library | handles | imports | current target |
|---|---|---|---|
| core | protocol, pairing, session, FEC, timing, geometry, frame composition (`[Quad]`), settings, calibration math | Foundation, POSIX sockets, system crypto frameworks on Apple platforms or swift-crypto elsewhere | `VRLinkCore` |
| XR runtime | eye poses, predicted display time, and drawable render surfaces | CompositorServices *or* OpenXR | `VRLinkVisionCompositor` |
| tracking and input | head pose, controller and hand poses, buttons and axes, haptics out | ARKit + GameController *or* OpenXR | `VRLinkVisionTracking` |
| graphics | drawing quads through eye views from a decoded frame | Metal *or* Vulkan | `VRLinkMetal` |
| decoder | access units in, decoded frames out | VideoToolbox *or* a platform decoder | `VRLinkVideoToolbox` |
| audio | PCM out, microphone in | CoreAudio *or* a platform API | `VRLinkAppleAudio` |
| session glue | host discovery, pairing, starting and stopping a session with its decoder and audio, live settings updates | platform-specific backends | `VRLinkAppleSession` |
| experiments | experimental features isolated so core targets do not depend on them | platform frameworks as needed | `VRLinkVisionExperiments`, `VRLinkAppleFace` |
| app shells | wiring, window or immersive space, settings UI | the platform's app framework | `OpenVRLink` (macOS viewer), `client/visionOS` |

Apple-specific frameworks are avoided outside Apple-specific targets, and
platform differences are isolated via `#if` conditionals or separate target
libraries (for example, macOS versus visionOS).

## Libraries

### XR runtime core

The XR runtime layer provides per-eye views, the predicted display timestamp,
and the render surfaces for each frame.

Display refresh rate can change mid-stream: visionOS switches between 45, 60,
90, 96, and 120 Hz based on thermal/performance state and environment, giving
applications minimal control. The XR runtime reports the current refresh period
every frame to `VRLinkCore`. When the period changes, the session publishes the
updated refresh-rate value and the host adjusts the stream without restarting
(`docs/svl-timing/refresh-rate.md`, **captured**).

Eye positions are **not** fixed on every headset, particularly headsets with
dynamic pupil-swim correction. visionOS shifts each eye view by a few
millimeters as the user's eye rotates (since the pupil pivots around the center
of the eyeball), while an SVL host cannot be given updated eye geometry
mid-session. The runtime must avoid reporting eye saccades as spikes in head
velocity; part of the pupil-swim offset can be folded into the reported head
pose, and world-space rendering still uses the exact per-eye view at display
time.

The predicted display time also drives pose prediction and timing reports: both
the pose packet's target-time field and the per-frame timing telemetry sent to
the host are derived from it (`docs/svl-tracking-input/poses.md`,
`docs/svl-video/retransmit.md`).

### XR runtime inputs/outputs

OpenXR exposes head pose, controller poses, buttons, and haptics through a
single API. visionOS splits them across three frameworks: world and hand
tracking come from ARKit, controller buttons and haptics come from
GameController, and frame timing comes from CompositorServices. Accordingly,
`VRLinkCore` defines three separate protocols rather than a monolithic XR input
interface:

```swift
protocol HeadTracking   { func head(at time: DisplayTime) -> TrackedPose }      // pose + velocities
protocol HandTracking   { func hand(_ side: Side, at time: DisplayTime) -> TrackedPose?   // controller grip or tracked hand
                          func skeleton(_ side: Side, at time: DisplayTime) -> HandSkeleton? }
protocol ControllerInput { func state(_ side: Side) -> ControllerState          // buttons, triggers, sticks, touches
                           func vibrate(_ side: Side, _ pulse: HapticPulse) }
```

Each hand reports a `ControllerState` (`VRLinkCore/Input.swift`) containing a
world-space grip pose and button/axis states mapped to the Oculus Touch layout
exposed to the host. The platform backend maps the physical controller inputs
onto those fields, while `VRLinkCore` handles wire encoding and publishes the
controller's device properties to the host the first time a controller appears.

An OpenXR backend implements `HeadTracking`, `HandTracking`, and
`ControllerInput` from a single OpenXR session. On visionOS, `HeadTracking` and
`HandTracking` are backed by ARKit providers while `ControllerInput` uses
GameController, and the backend aligns controller poses and button states to the
same timestamp.

All poses cross this API boundary in the same world coordinate space used by the
render quads.

### Decoder -> graphics

Zero-copy video rendering requires pairing a compatible decoder and graphics
backend (VideoToolbox with Metal, MediaCodec with Vulkan via
`AHardwareBuffer`, or a Windows decoder with Vulkan via shared textures). The
decoder outputs an opaque `DecodedFrame`, and the graphics backend declares
which frame representations it can sample; the app shell wires up a matching
pair. By design, not every decoder works with every graphics backend.

Cross-platform wrapper layers for graphics or video decoding are avoided in
favor of native platform APIs, which provide direct control over memory layout,
color spaces, and synchronization.

Additional decoder and rendering rules:

- Do not perform color conversion on the CPU.
- Prefer a hardware texture format whose sampler converts YCbCr to RGB directly
  (on Metal, private pixel formats 500/505/508 with VideoToolbox `'&xf0'`
  output). Fall back to YCbCr-to-RGB conversion in the fragment shader when
  hardware sampler conversion is unavailable.
- Leave the decoder's output pixel format unspecified where the platform allows;
  requesting a specific format triggers an extra conversion pass that wastes
  bandwidth and power.

Frame buffer lifecycle (partially implemented):

- Access units are decoded immediately upon arrival and placed into a short
  decoded-frame queue. The compositor pulls frames from the queue for rendering,
  bounding queue depth so latency cannot accumulate.
- Each `DecodedFrame` must stay alive until the GPU finishes sampling it—the
  graphics backend retains the frame until its command buffer completes.
- The decoder's buffer pool must hold at least the queue depth plus the
  currently displayed frame plus the codec's reference frames (at least 3).
- The host updates SPS/PPS/VPS bytes dynamically during rate control. The
  decoder must ingest updated parameter sets in place without tearing down the
  session, or it will lose its reference frames.

### Audio

Audio streams raw 48 kHz stereo PCM in both directions with XOR parity
(`docs/svl-audio/`), backed by a jitter buffer, a microphone source, and a
playback sink.

On visionOS, the playback sink also has to keep the OS audio session alive:
CoreAudio can drop or suspend the audio unit inconsistently across app
backgrounding, system notifications, and other interruptions, so the sink
monitors and restarts the session when interrupted.

## Session lifecycle

A headset app can be interrupted at any time—the user removes the headset,
presses the Digital Crown, or switches to another app. Rather than exiting on
backgrounding, this client handles suspension and resumption directly in
`VRLinkCore`:

```
idle -> connecting -> streaming -> suspended -> connecting -> streaming ...
                          \________________________/
                           background / headset doffed     foreground / donned
```

- **Suspend** (app backgrounded, immersive space dismissed, or headset removed):
  send a disconnect notice to the host, stop the session thread, flush the
  decoder and decoded-frame queue, and stop audio so all state from the previous
  stream is cleared.
- **Resume** (app foregrounded with the immersive space active): send a fresh
  `StreamingRequest` on UDP 27036 and start a new streaming session. Because
  each session string is single-use, resuming always requests a new session
  string using the existing pairing secret without repeating PIN pairing.
- SteamVR keeps running for roughly 30 s after a client disconnects
  (`docs/svl-values/startup-exchange.md`). Reconnecting within that window
  restores video within ~250 ms with the running VR application intact; after
  SteamVR exits, resuming takes a few seconds for a cold start.
- `VRLinkCore` exposes a single connection controller with `suspend()` and
  `resume()` methods, which the app shell drives from platform scene-phase and
  headset-worn events. Decoder, graphics, and audio backends must all support
  stopping and restarting cleanly within a single process.

Host selection follows three rules across this lifecycle:

- The initial connection is always chosen explicitly by the user in the entry
  window, which lists discovered hosts and accepts a manually typed IP address.
- Once selected, that host remains the active target for the lifetime of the app
  process; resuming reconnects to it automatically without reopening the window.
- Launching the app fresh always opens the entry window rather than
  auto-connecting to a previously used host.

On visionOS, display geometry APIs are unavailable outside an immersive space.
Because the host needs display parameters before starting the stream, the app
briefly opens a compositor layer once per launch to measure eye positions,
frusta, and refresh rate.

On visionOS, removing and putting the headset back on pauses and resumes the
immersive space, automatically suspending and resuming the stream; backgrounding
the 2D window does not disturb an active immersive session. If the system closes
the immersive space entirely, the stream ends and the host-picker window
reappears. Frames from an ended stream are discarded immediately so resuming
shows the waiting backdrop rather than a stale frame from the prior session.

Two lifecycle cases remain unimplemented: keeping a stream alive across brief
interruptions within the host's 30 s grace window, and displaying connection
status inside the immersive space while resuming.

## Networking quirks and minutiae

Apple platforms restrict UDP broadcast and multicast: on visionOS, iOS, and
iPadOS, sending to `255.255.255.255` or `ff02::1` fails with "No route to host"
unless the app holds Apple's multicast entitlement. As a workaround, the client
derives the local subnet from the network interface's IP address and netmask and
sends unicast discovery probes to each host address, which Steam hosts answer
normally. The client refuses to sweep subnets wider than `/22` (1022 usable
addresses) rather than silently scanning a partial range, requiring explicit IP
addresses instead.

Rather than branching discovery logic per platform, the client uses the same
approach everywhere:

- sweep the local subnet with unicast probes (hosts answer unicast probes from
  any source port)
- directly probe previously paired hosts at their last known IP addresses
- accept manually entered IP addresses for subnets wider than `/22`, routed
  networks, or firewalls that drop discovery traffic

Networking prefers wired Ethernet over Wi-Fi when available. On visionOS, wired
Ethernet is available via a USB-C dongle attached to the Developer Strap;
interface detection on other platforms is handled per platform (driving a USB
Wi-Fi adapter from userspace may also be worth exploring).

On Apple platforms, the OS displays a local-network permission prompt on first
network use, and early UDP packets are dropped until the user grants access.
(TODO: surface a hint in the UI if discovery receives no responses.)

## Configuration storage

Settings and pairing secrets are stored in an `OpenVRLink` directory inside the
platform's per-user application data location (see
`VRLinkCore/DataDirectory.swift`). On Linux and Android this follows
`XDG_DATA_HOME` rather than splitting files across `XDG_CONFIG_HOME`:

| platform | folder |
|---|---|
| Linux, Android | `$XDG_DATA_HOME/OpenVRLink`, defaulting to `~/.local/share/OpenVRLink` |
| Windows | `%LOCALAPPDATA%\OpenVRLink` (`AppData\Local`) |
| macOS | `~/Library/Application Support/OpenVRLink` |
| iOS, visionOS | `OpenVRLink` inside the app's Documents folder |

This directory holds `settings.json` along with all saved host pairing secrets.
(TODO: consider pruning stale pairing keys.)

`Sources/VRLinkCore/Settings.swift` reads and writes `settings.json`. The schema
is backward- and forward-compatible and shared across platforms, so individual
fields may only apply to specific platforms.

## Experiments

Experimental features live in their own settings tab, default to off, and may
change or break between builds.

### Camera-based face and eye tracking

Platforms without dedicated eye- or face-tracking APIs can estimate both from a
camera feed of the user's face. On visionOS, the "front camera" feed delivers
the system-rendered Spatial Persona, whose facial expressions and eye movements
track the user.

| step | location |
|---|---|
| camera capture and Apple Vision face-landmark detection | `VRLinkAppleFace/FaceCamera.swift` (also runs against a Mac webcam) |
| mapping landmarks to 70 `XR_FB_face_tracking2` weights and pupil positions | core, `FaceFromLandmarks.swift` |
| mapping pupil positions to a gaze ray | core, `GazeCalibration.swift` |
| combining camera capture, settings, and calibration on visionOS | `Sources/VRLinkVisionExperiments/PersonaTracking.swift` |
| RealityKit gaze calibration space | `Sources/VRLinkVisionExperiments/GazeCalibrationSpace.swift` |
| RealityKit stream renderer that anchors the Persona camera to the head | `Sources/VRLinkVisionExperiments/RealityKitDisplay.swift` |

visionOS renders the Spatial Persona from the viewpoint of a SwiftUI view tagged
with `cameraAnchor`. Because a Metal `CompositorLayer` cannot host SwiftUI
views, the standard compositor renderer leaves the Persona camera fixed at the
2D app window. However, a RealityKit immersive space with no open 2D windows can
attach the `cameraAnchor` to a head-tracked entity, and toggling that entity's
enabled state prompts visionOS to update the Persona camera pose rapidly.

### RealityKit stream renderer

`Sources/VRLinkVisionExperiments/RealityKitDisplay.swift`, modeled after ALVR's
RealityKit renderer:

- The standard quad renderer flattens each decoded frame into a single
  top-bottom stereo texture (left eye in the lower half, right eye in the upper
  half), compositing the foveal tile over the base tile from the host's exact
  rendered eye pose so this pass only resamples. Each axis uses 1.6 texture
  pixels per source tile pixel (clamped to 3072) to retain foveal detail.
- Each eye views a world-space plane spanning the host's frustum at 80 m out for
  the left eye and 70 m out for the right eye (offset to prevent depth
  fighting). Using ALVR's `SBSMaterial.usda` (`_L` and `_R` variants), each
  plane displays its half of the texture to its matching eye and stays
  invisible to the other eye. RealityKit then reprojects those world-space
  planes from the live eye poses at display time, matching the Metal compositor
  path.
- Three texture-and-plane pairs are cycled in a ring with only the newest pair
  enabled so texture contents and plane transforms update together in the same
  RealityKit frame.
- Because RealityKit does not report display geometry, this renderer reuses the
  `MeasuredDisplay` measurements captured before the first connection (see
  [Session lifecycle](#session-lifecycle)).
- Because RealityKit does not expose exact presentation timestamps, a display
  link tracks refresh times and `VsyncPrediction` (ALVR's method) advances by a
  whole number of refresh intervals sufficient to cover RealityKit's ~14 ms
  running-average render duration. That predicted display time is reported to
  the session and used as the target timestamp for head and hand poses.

This path adds a second full-screen render pass and does not yet support display
foveation or rate-map gaze. Gaze calibration also runs in a RealityKit space so
the Persona camera views the pupils from the same head-relative position during
calibration and streaming; it closes the app's 2D window while running (since
any open window claims the Persona camera anchor), renders instructions beneath
the target dots, and reopens the window afterward.

**Gaze estimation.** After leveling face roll, the landmark estimator computes
four features per eye:

- horizontal pupil position between the eye corners (`across`, `-0.5 ... 0.5`)
- vertical pupil offset relative to the center of the eye outline (`down`, in
  eye widths)
- vertical pupil offset relative to the line through the two eye corners
  (`belowCorners`)
- eyelid aperture (`open`)

`belowCorners` and `open` compensate for eyelid coupling: because the upper and
lower eyelids move vertically with the pupil, `down` alone changes very little
during upward or downward gaze (which previously caused vertical gaze to stick
on the headset), whereas the eye corners stay fixed and the eyelids lower on
downward gaze. Features are averaged across both eyes, and calibration fits a
quadratic model mapping them to horizontal and vertical gaze tangents in head
space:

```
    across = k . [1, a, d, a*a, a*d, d*d, c, o]        up = likewise, own k
```

Calibration fits `k` via least squares from `(features, targetDirection)` sample
pairs.

Ground-truth gaze direction comes from the single visionOS interaction that
reveals where the user is looking: a distant pinch delivers a ray from the eyes
to the gazed target. The calibration space displays 19 head-locked dots 1.5 m
ahead (forcing eye rotation rather than head rotation); as the user looks at
each dot and pinches, the pinch ray—transformed into head space—is paired with
the eye features averaged over the preceding 0.4 s. Quadratic terms receive
mild ridge regularization and are omitted entirely when fewer than 10 samples
are available. Both the fitted coefficients and residual sample error are stored
in `settings.json`. At runtime, the estimated gaze vector is scaled to a fixed
1.5 m distance and smoothed. Gaze freezes only when both eyes are completely
closed, since treating partially lowered eyelids during downward gaze as blinks
previously froze vertical tracking. Without a saved calibration, the RealityKit
renderer sends no gaze data.

**Continuous calibration** (setting `continuousGazeCalibration`, off by default;
implemented in `GazeCalibration.tuned` and wired in `PersonaTracking.learn`).
Because headset fit shifts during and between sessions, enabling this mode
records each distant pinch made while streaming as an additional calibration
sample—pairing the head-space pinch ray with eye features averaged over the
preceding 0.4 s. Up to 60 samples are retained, and the fit is recomputed on
each new sample:

- Any sample more than 0.35 in tangent space (~19 degrees) from the current
  model's prediction is discarded as an outlier, since users do not hold their
  eyes stationary during normal pinches; headset shifts larger than that require
  re-running manual calibration.
- Once 60 samples are stored, a new sample replaces the existing sample with the
  nearest gaze direction rather than evicting the oldest sample, preserving edge
  samples when pinches cluster near the center of the view.
- Samples decay exponentially by a weight factor of 0.97 per step so recent
  observations carry greater weight.

Updated coefficients take effect immediately and are persisted to
`settings.json` only when the stream ends rather than on every pinch (writing
settings mid-stream triggers a SwiftUI view update that can displace the Persona
camera anchor). Calibrations saved before sample history was added cannot be
tuned incrementally and must be re-run once.

For vergence and focal distance, only the ray direction is used and features are
averaged across both eyes, so inward vergence on near targets should cancel out
(**inferred**; untested on the headset).

**Face calibration.** Face calibration (`FaceCalibration.swift`,
`Sources/VRLinkVisionExperiments/FaceCalibrationSpace.swift`) replaces default
author-tuned thresholds with per-user measurements. A panel displays the user's
Persona and prompts for nine expressions in sequence (rest, jaw open, smile,
frown, pucker, brows up, brows down, eyes closed, and eyes wide), counting down
before sampling each expression for slightly over a second. Ten normalized
landmark distances relative to face size are recorded (`FaceMeasures`: mouth gap
and width, left/right mouth corner drop, left/right brow lift, and left/right
eye openness). Each outgoing blendshape weight (`0` to `1`) interpolates from
the resting baseline to that expression's peak calibration measurement;
expressions without a dedicated calibration pose remain `0`. When calibrated
gaze is available, it drives the eight `eyesLook` weights. Weights are smoothed
with a 50 ms time constant.

## Dependencies

- **Crypto**: Uses operating-system frameworks on Apple platforms (CryptoKit,
  CommonCrypto, Security) so Apple builds carry no bundled cryptography library,
  and **swift-crypto** on Linux, Windows, and Android (excluded from Apple
  builds). Platform selection uses `#if` in a single core file (`Primitives`),
  the sole exception to injected backends, with shared known-answer tests
  verifying both paths. Pairing uses X25519, SHA-256, AES-CBC, single-block
  AES-ECB (for the encrypted IV), and RSA-OAEP with SHA-1
  (`_RSA.Encryption.Padding.PKCS1_OAEP`), all included in swift-crypto 3.x.
- **Protobuf**: Serialized by hand (`VRLinkCore/Protobuf.swift`) rather than
  adding a protobuf dependency, since only four broadcast message flows are
  needed.

## Remaining work

1. **visionOS**: finish remaining missing features.
2. **Windows helper**: install PSVR2 assets and optionally patch
   `driver_vrlink` for additional features (such as improved transport
   encoding).
3. **Windows**: Vulkan, OpenXR, platform video decoder, and audio backends
   (primarily a desktop debugging target rather than an end-user build).
4. **Android**: reuse the Vulkan and OpenXR backends and iron out remaining
   visionOS-specific assumptions.

## Open questions

- Which decoder API to target on Windows (vendor SDKs, Media Foundation, or
  Vulkan Video), and how to import its output surfaces into Vulkan without extra
  copies.
- Whether the host requires exact client display timestamps or only consistent
  frame intervals (see the delivered-versus-agreed frame rate discussion in
  `docs/svl-values/startup-exchange.md`).
- Color pipeline handling: the stream signals BT.2020 primaries and gamma 2.2,
  while `vrlink` configures its decoder output as linear.
- How to report controller identity on platforms whose controllers differ from
  the Quest Touch profile described by `vrlink`.
