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
| XR runtime | eye poses, predicted display time, and drawable render surfaces | CompositorServices *or* OpenXR | `VRLinkVisionCompositor`, `VRLinkOpenXR` |
| tracking and input | head pose, controller and hand poses, buttons and axes, haptics out | ARKit + GameController *or* OpenXR | `VRLinkVisionTracking`, `VRLinkOpenXR` |
| graphics | drawing quads through eye views from a decoded frame | Metal *or* Vulkan | `VRLinkMetal`, `VRLinkOpenXRMetal`, `VRLinkVulkan` |
| decoder | access units in, decoded frames out | VideoToolbox *or* a platform decoder | `VRLinkVideoToolbox`, `VRLinkMediaCodec` |
| audio | PCM out, microphone in | CoreAudio *or* a platform API | `VRLinkAppleAudio`, `VRLinkAndroidAudio` |
| session glue | host discovery, pairing, starting and stopping a session with its decoder and audio, live settings updates | `VRLinkCore` (`HostFinder`, `StreamLink`, `ClientModel`) plus injected platform backends | `VRLinkCore`, `VRLinkAppleSession` (SwiftUI), `VRLinkXRClient` (OpenXR) |
| UI | presenting `ClientModel` and forwarding user actions | SwiftUI *or* Dear ImGui *or* a platform toolkit | `client/visionOS`, `VRLinkPanel` (+ `CImGui`) |
| rooms | room selection for streaming sessions and the Room Setup immersive space | ARKit + RealityKit | `VRLinkVisionRooms` |
| experiments | experimental features isolated so core targets do not depend on them | platform frameworks as needed | `VRLinkVisionExperiments`, `VRLinkAppleFace` |
| app shells | wiring, window or immersive space, settings UI | the platform's app framework | `OpenVRLink` (macOS viewer), `client/visionOS`, `OpenVRLinkXR` (macOS OpenXR), `OpenVRLinkAndroid` + `client/android` (Android) |

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

## OpenXR

`VRLinkOpenXR` implements the XR runtime, tracking, and input backends for
OpenXR headsets. Unlike visionOS, where `VRLinkVisionCompositor` and
`VRLinkVisionTracking` wrap separate system frameworks, OpenXR exposes display
timing, swapchains, and input through a single API, so `VRLinkOpenXR` handles
all of them in one target. Rendering is delegated to an `XRGraphics` backend
(`VRLinkOpenXRMetal` or `VRLinkVulkan`) that the app shell pairs with a matching
video decoder.

| component | location |
|---|---|
| Unmodified Khronos OpenXR headers (no loader linked at build time) | `COpenXR` |
| Runtime discovery and function pointer resolution | `VRLinkOpenXR/Loader.swift`, `XRInstance.swift` |
| Session management, frame loop, swapchains, display metrics, and timing reports | `XRDisplay.swift` |
| Action bindings, `ControllerState` mapping, hand tracking, and haptics | `XRInput.swift` |
| Graphics backend protocol for OpenXR swapchains | `XRGraphics.swift` |
| Quad layer for a 2D panel, with controller and hand pointer rays | `XRPanelLayer.swift` |
| Platform-independent OpenXR client (display, link, panel, and model wired together) | `VRLinkXRClient` |
| Metal graphics backend (`XR_KHR_metal_enable`) using `QuadRenderer` | `VRLinkOpenXRMetal` |
| Vulkan graphics backend (`XR_KHR_vulkan_enable2`) sampling `AHardwareBuffer` | `VRLinkVulkan` |

### Runtime loading

`VRLinkOpenXR` does not link an OpenXR loader at build time. Instead, it
resolves every OpenXR function pointer through `xrGetInstanceProcAddr` at
runtime. On macOS and Linux, `Loader` reads the active runtime manifest directly
(`XR_RUNTIME_JSON`, followed by `~/.config/openxr/1/active_runtime.json` and
standard XDG/system directories), loads the runtime shared library, and calls
`xrNegotiateLoaderRuntimeInterface` directly. Setting `OPENXR_LOADER` loads an
external Khronos loader library instead when API layers are needed. On Android,
`libopenxr_loader.so` is bundled in the APK because connecting to the device's
runtime goes through Android's OpenXR runtime broker. Windows registry lookup
for active runtimes is not implemented yet.

### Frame loop and session lifecycle

Each frame, `XRDisplay` waits for the runtime's predicted display time, samples
head, controller, and hand poses for that timestamp, locates both eye views, and
draws the latest decoded frame's quads into per-eye swapchains. It submits a
single `XrCompositionLayerProjection` in the same reference space as the quads
so the runtime performs late-stage reprojection, matching visionOS. When
`XR_KHR_convert_timespec_time` is available, display timestamps are converted to
the monotonic clock used by `Uptime` for `frameShown` and `displayRefreshes`
telemetry; otherwise, the display time is estimated as one refresh period ahead.

Once the OpenXR runtime begins the session and reports valid eye views,
`XRDisplay.onReady` builds a `DeviceProfile` from `xrLocateViews` in view space,
the recommended swapchain dimensions, and the refresh rate from
`XR_FB_display_refresh_rate` (or the predicted frame period), so the app does
not need a separate measurement pass. `XRClient` starts connecting as soon as
both the session is running and the user has picked a host
(`ClientModel.state.target`). If the runtime stops the session (for example,
when you take off the headset or switch to another app), `XRClient` disconnects
the stream, keeps the selected host, and reconnects when the session resumes.
Pressing Stop in the panel clears the selected host and sends a disconnect
notice so the host closes the session.

### Reference spaces and input

Tracking and rendering prefer the `STAGE` reference space when supported (using
`xrGetReferenceSpaceBoundsRect` as the room chaperone boundary sent to the
host), falling back to `LOCAL_FLOOR` and then `LOCAL`. OpenXR relies directly on
the runtime's boundary system rather than maintaining saved rooms or spatial
anchors. When the user recenters or edits their boundary in the system UI, the
runtime posts a reference-space change event; once its change timestamp arrives,
`XRDisplay.onSpaceChanged` fires so `XRClient` can re-read the bounds and send
them to the host. When the host requests a recenter, `XRClient` moves the
play-space origin beneath the user's head for the rest of the session (matching
visionOS) and transforms the boundary corners so the chaperone stays in the same
physical spot.

Eye gaze uses `XR_EXT_eye_gaze_interaction`. Because that extension provides a
gaze ray in view space without a convergence distance, `XRInput` projects a
fixation point 10 m along the ray. Face tracking uses
`XR_ANDROID_face_tracking` (`XRFace.swift`), whose first 63 blendshape weights
match the `XR_FB_face_tracking2` layout expected by the host (`TONGUE_OUT` maps
to index 68). On Galaxy XR, the runtime reports no face weights until the user
completes system face calibration; `XRFace` queries
`xrGetFaceCalibrationStateANDROID` so the in-headset panel can prompt the user
to calibrate.

On Android, the system back button is delivered to the `NativeActivity` input
queue rather than OpenXR. During an immersive session, `Activity.swift` consumes
`AKEYCODE_BACK` so it does not close the activity, and `XRInput.systemButton`
forwards it as the left controller menu button (or the left-hand menu gesture
when using hand tracking) to open the SteamVR dashboard. On runtimes that
support `XR_FB_hand_tracking_aim` (such as Quest), `XRInput` also reads the
left-hand menu pinch gesture alongside the hand joints and maps it to the same
menu bit.

`XRInput` defines a single action set covering `ControllerState` inputs, with
suggested bindings for Oculus Touch, Meta Touch Plus, Pico 4, Valve Index, and
Khronos simple controller profiles. When a hand is not holding an active
controller, `XRInput` queries the 26 joints from `XR_EXT_hand_tracking`, which
already match the joint ordering and axis convention of `TrackedHand`.
Transparent or chroma-keyed streams request `XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND`
when the headset supports passthrough blending. Both `MetalXRGraphics` and
`VulkanXRGraphics` support chroma keying; the Vulkan backend compiles a second
`quad.frag` variant that uses dual-source blending to match `Quad.metal`.

### Depth correction

`StereoDepthEstimator` (in `VRLinkCore`, generic over the decoded frame type and
typealiased as `DepthEstimator` in `VRLinkVideoToolbox`) estimates scene depth
from stereo disparity between the left and right eye views, allowing `XRDisplay`
to warp the stream quads for translational reprojection just like
`CompositorDisplay` on visionOS. Each `XRGraphics` backend supplies its own
frame readback path:

- `MetalXRGraphics` runs stereo downsampling and matching on the GPU with
  `StereoShrink`, sharing the implementation used on visionOS.
- `VulkanXRGraphics` renders both eyes side by side into a small offscreen image
  using the existing quad pipeline and render pass, copies the result into a
  host-visible buffer, and reads the pixels back once that frame's fence
  signals. `StereoDepthEstimator` then runs `StereoMatcher` on the CPU on a
  utility-priority queue. This path is enabled when using an 8-bit swapchain
  format.

### In-headset panel

OpenXR targets do not have a system window manager for a host picker, so the UI
is rendered into an RGBA pixel buffer and shown as a quad layer inside the VR
session. `VRLinkPanel.Panel` draws `ClientModel` (see [UI model](#ui-model))
with Dear ImGui, including discovered hosts, an on-screen keypad for manual IP
entry, connection status, the WiVRn PIN prompt, and settings from
`SettingsForm`.

Rather than maintaining separate ImGui GPU backends for Metal and Vulkan,
`PanelRasterizer` rasterizes ImGui's triangle lists on the CPU into a
premultiplied RGBA buffer. The same pixel buffer can back an OpenXR quad layer
or a 2D launcher window, and unit tests can check the rendered output directly.
`Panel` hashes ImGui's draw lists each frame and only re-rasterizes when they
change. Graphics backends copy that buffer into an 8-bit sRGB swapchain image
through a staging buffer (`choosePanelFormat`, `adoptPanel`, and `drawPanel` on
`XRGraphics`).

`XRPanelLayer` places the panel as an `XrCompositionLayerQuad` 1.6 m in front of
you each time it appears and intersects pointer rays with the quad to get panel
pixel coordinates. Those rays use dedicated `point` and `press` actions bound to
controller aim and trigger, or to hand aim and pinch through
`XR_EXT_hand_interaction`. Keeping them separate from the stream's `aim` and
`trigger` actions prevents a hand-interaction profile from making a tracked hand
look like a controller to the host.

The panel stays up until the first video frame is decoded. Holding the menu
button for 0.8 s shows or hides the panel during an active stream, while short
presses still go to SteamVR. Hand tracking does not have a gesture to reopen the
panel yet, so without controllers it only reappears after the stream ends.

Dear ImGui (`CImGui`, v1.91.9b) is vendored with build flags at the bottom of
`imconfig.h` and wrapped in a plain C header (`CImGui.h`). Swift can import
`imgui.h` directly through C++ interop, but enabling C++ interop on a Swift
target forces every downstream target to enable it too, which would compile the
app targets and their OpenXR, Vulkan, and Android NDK headers as C++.

### macOS OpenXR client

`OpenVRLinkXR` runs OpenVRLink as a macOS OpenXR application, pairing
VideoToolbox decoding, `QuadRenderer`, and CoreAudio with an `XRDisplay` session
instead of an AppKit window. You can test it against
[OXRSys](https://github.com/demonixis/oxrsys), a macOS OpenXR runtime that
forwards frames to a Quest, Pico, or Vision Pro headset:

```
XR_RUNTIME_JSON=<oxrsys>/build/runtime/oxrsys-runtime.json swift run OpenVRLinkXR [host]
```

Running without a host argument opens the in-headset panel with hosts found on
the local network; passing `address`, `steam://address`, or
`wivrn://address[:port]` connects right away. `main.swift` sets up VideoToolbox,
CoreAudio, microphone capture, and Bonjour discovery, and hands session
management off to `XRClient`. Pass `--pictures <folder>` to save periodic
left-eye swapchain captures and redrawn panel images as PNGs for headless
debugging. Controller input, hand tracking, pointer rays, haptics, and physical
headset output via OXRSys still need testing on hardware.

### Android

`client/android/build.sh` cross-compiles `libOpenVRLinkAndroid.so` with the
Swift SDK for Android and packages a signed APK using the Android SDK
command-line tools (`aapt2`, `zipalign`, and `apksigner`), with no Gradle, Java,
or Kotlin code. Android's built-in `NativeActivity` loads the native library and
calls `ANativeActivity_onCreate` in `OpenVRLinkAndroid/Activity.swift`. The
manifest includes metadata for Android XR, Quest, and Pico, targeting Android 10
(API 29) and later.

| component | Android implementation | location |
|---|---|---|
| decoder | `AMediaCodec` decoding into `AImageReader` surfaces (`AHardwareBuffer` frames, one codec per video stream) | `VRLinkMediaCodec/MediaCodecDecoder.swift` |
| graphics | Vulkan renderer importing `AHardwareBuffer` images with `VkSamplerYcbcrConversion` | `VRLinkVulkan/VulkanXRGraphics.swift`, `Shaders/` |
| audio | Low-latency PCM output and microphone capture via AAudio | `VRLinkAndroidAudio` |
| WiVRn discovery | `MulticastDNS` (in `VRLinkCore`), a UDP mDNS/DNS-SD browser | `VRLinkCore/MulticastDNS.swift` |
| platform APIs | JNI calls into Android framework classes for runtime permissions, activity launches, and device name lookup | `OpenVRLinkAndroid/Java.swift` |
| NDK bindings | C module exposing NativeActivity, MediaCodec, AAudio, and Vulkan headers | `CAndroidNDK` |

The Vulkan shaders are written in GLSL under `VRLinkVulkan/Shaders` and
precompiled to SPIR-V into `QuadShaders.swift` by `compile.sh`. The signed APK
is roughly 70 MB, about 40 MB of which is Swift Foundation's ICU data. The
launcher icon is an adaptive icon generated from the visionOS icon layers by
`android/make-icon.py` and compiled from `android/res` with `aapt2`.

Android XR's OpenXR runtime is a system library (`libopenxr.google.so`), so
`AndroidManifest.xml` must declare it with `<uses-native-library>` to expose it
to the app's linker namespace; otherwise the OpenXR loader fails with
`XR_ERROR_RUNTIME_UNAVAILABLE`.

#### Launch modes

Some standalone headsets launch VR apps directly into an immersive OpenXR
session, while others expect a 2D launcher window first. By default, `build.sh`
includes only the immersive entry point in `AndroidManifest.xml`; passing
`--flat` adds the 2D entry point and marks it with the `LAUNCHER` intent
category:

- `android.app.NativeActivity` starts directly in an immersive session
  (`XR_ACTIVITY_START_MODE_FULL_SPACE_UNMANAGED`) and runs `XRClient` with the
  panel shown as a quad layer.
- `.Panel` is an `<activity-alias>` without the immersive XR metadata, so
  Android opens it as a 2D window. `Activity.swift` copies the panel's RGBA
  buffer into the window with `ANativeWindow_lock` and forwards touch events
  from `AInputQueue` to the panel. Selecting a host launches the immersive
  activity to start the stream.

We use an `<activity-alias>` so the APK does not need a custom Java `Activity`
subclass; native code checks the component name on the launch intent to tell
which entry point started it. Both activities run in the same process and share
one `ClientModel` and `Panel` behind a lock, since Dear ImGui uses a single
global context.

The `--flat` 2D entry point is not supported on Android XR. On Galaxy XR, an
`<activity-alias>` inherits the target activity's unmanaged full-space mode
regardless of its own start-mode property, leaving a 2D window stuck on the
splash screen without pointer input. Because the Galaxy XR launcher also opened
the alias even when only the immersive activity carried `LAUNCHER`, default
builds omit the alias from the manifest. Supporting a 2D launcher window on
Android XR would require a separate Java `Activity` subclass and a DEX build
step.

#### Permissions

Runtime permissions are requested over JNI with `Activity.requestPermissions`.
Receiving `onRequestPermissionsResult` would require a custom Java `Activity`
subclass, so native code waits for the activity to pause and resume around the
system permission dialog and then re-checks the permission state.

- `android.permission.HAND_TRACKING`, `EYE_TRACKING_FINE`, and `FACE_TRACKING`
  (Android XR) are requested when the immersive activity starts, before creating
  the OpenXR instance, because the runtime only advertises hand tracking,
  `XR_EXT_eye_gaze_interaction`, and `XR_ANDROID_face_tracking` when the
  corresponding permission is already granted. Devices that do not define those
  permissions skip the prompt (Quest grants `com.oculus.permission.HAND_TRACKING`
  at install time).
- `android.permission.RECORD_AUDIO` is requested when a stream starts with
  "Send my microphone" enabled.

#### Headset quirks

`HeadsetQuirks` (in `VRLinkCore`) identifies the headset from Android's `Build`
properties and stores per-device workarounds for behavior that OpenXR and
MediaCodec do not report. Defaults follow ALVR's OpenXR client:

| quirk | default | description |
|---|---|---|
| `floatTarget` | off | Render to `R16G16B16A16_SFLOAT` swapchains when offered. Off by default because the video stream is 8-bit and 8-bit sRGB swapchains behave consistently across runtimes. |
| `floatTargetIsEncoded` | on for Pico and Galaxy XR | Whether the compositor treats a float swapchain as sRGB-encoded rather than linear, which OpenXR leaves unspecified. |
| `videoRange` | as reported by decoder | Overrides narrow or full YCbCr range conversion for decoders that misreport color range. |
| `decoderWidth`, `decoderHeight` | 2048 x 2048 | Initial decoder dimensions used when parameter sets are not parsed beforehand (currently AV1). `PictureSize` parses H.264 and HEVC dimensions from the SPS. |
| `decoderLowLatency` | on | Enables the Android 11 `low-latency` key and Qualcomm's vendor low-latency extension. |
| `gripOffset` | per-headset (from ALVR) | Local transform `(x, y, z, pitch, yaw, roll)` applied to the left controller grip pose (and mirrored for the right) so non-Quest controllers align with the Quest Touch profile reported to the host. Computed by composing ALVR's per-headset offset with the inverse of ALVR's Quest offset (`get_controller_offset` in `alvr/client_openxr/src/interaction.rs`); on Galaxy XR this shifts the grip 5.5 cm back along +Z with +15 deg of pitch. |
| `waitForGPU` | on | Waits on the frame's GPU fence before releasing swapchain images to the OpenXR runtime. |
| `decoderOperatingRate` | 32767 | `operating-rate` passed to `AMediaCodec` (0 leaves it unset). Qualcomm decoders scale clocks from this hint and default to 30 fps without it; 32767 matches ALVR's maximum-rate setting. If configuring the codec fails with this key set, the decoder retries without it. |

You can override any of these without rebuilding by setting
`debug.openvrlink.*` system properties before launching the app. Active values
are logged at startup along with the chosen swapchain format and the decoder's
reported YCbCr model and range:

```
adb shell setprop debug.openvrlink.float_target 1
adb shell setprop debug.openvrlink.float_encoded 0
adb shell setprop debug.openvrlink.video_range full      # narrow, full, or auto
adb shell setprop debug.openvrlink.decoder_operating_rate 0
adb shell setprop debug.openvrlink.grip_offset 0,0,0.055,15,0,0   # x,y,z meters; pitch,yaw,roll degrees
adb logcat -s OpenVRLink
```

To connect without using the panel during testing, write a target host
(`steam://address`, `wivrn://address[:port]`, or a plain address) to `host.txt`
in the app's internal files directory, and the immersive activity will connect
to it on launch.

#### Wired networks

Android routes sockets over its default network unless bound explicitly, and a
direct USB or Ethernet connection to a PC without internet access never becomes
the default network. `Activity.swift` queries `ConnectivityManager` over JNI for
connected `TRANSPORT_ETHERNET` and `TRANSPORT_USB` networks and passes their
interface names to `HostConnector`. When connecting over one of those
interfaces, `NetworkInterfaces.bind` (in `VRLinkCore`) binds each socket to the
matching network handle via `android_setsocknetwork` and logs
`using wired interface <name>`.

#### Performance logging

During an active stream, `XRDisplay` and `MediaCodecDecoder` log summary metrics
every five seconds:

- `openxr: showed N frames/s of R (M new pictures/s); each frame waited ...,
  prepared ..., drew ..., ended ...` (`FramePace` in `XRDisplay`): reports
  average time spent in `xrWaitFrame`, building quad meshes, `XRGraphics.draw`
  (including waiting on the previous frame's fence), and `xrEndFrame`.
- `decoder: N pictures/s in (B Mbit/s), M out, each taking T ms`
  (`MediaCodecDecoder`): reports input packet rate and bitrate, decoded output
  rate, and queue-to-output decode latency.

If the new-picture rate drops while draw times stay short, the bottleneck is on
the network or in `MediaCodec`; if draw times grow or displayed frames fall
below the refresh rate, rendering is falling behind. Stream resolution is chosen
by the host (`driver_vrlink/streamFormatWidth`, which the companion sets to 2048
for a 2048 x 8192 atlas) and cannot be negotiated by the client
(`docs/svl-values/startup-exchange.md`).

`MediaCodecDecoder` outputs pooled `AHardwareBuffer` instances that
`VulkanXRGraphics` imports once and caches by buffer ID. Because the hardware
decoder writes into those buffers from an external queue, `VulkanXRGraphics`
records a queue-family ownership transfer from `VK_QUEUE_FAMILY_FOREIGN_EXT`
before sampling a buffer in a frame and releases ownership back at the end of
the command buffer so newly decoded contents are visible to Vulkan.

Current limitations on Android:

- Chroma keying requires Vulkan `dualSrcBlend` and
  `XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND` passthrough; the chroma-key settings
  are hidden when either is unsupported.
- Vulkan stereo depth readback requires an 8-bit swapchain format.
- Battery reporting is not implemented.
- AV1 streams configure the decoder with placeholder initial dimensions.
- AAudio streams do not recover after audio output device changes yet.
- Hand tracking has no gesture to reopen the panel during a stream.

### UI model

`ClientModel` (in `VRLinkCore`) holds the client's UI state and user actions
without depending on a UI framework. `ClientModel.State` tracks the connection
phase (`choosing`, `connecting`, or `streaming`), status text, discovered hosts,
whether a WiVRn PIN prompt is up, and the selected target host. Whenever state,
settings, or the last manually entered address change, `ClientModel` fires
`onChange` and saves updated settings or addresses in the background.

UI code calls `connect(to:)`, `connectToTyped()`, `stop()`, and `answerPin(_:)`,
and reads or writes `settings` and `remembered`. On the other side, the app
shell provides `startStream` and `stopStream` closures and reports session
events back through `show`, `streamStarted`, `streamPaused`, and `streamEnded`.
When a WiVRn host asks to pair, `askPin` blocks the connection thread until the
user enters a PIN or cancels.

`SettingsForm` describes the user-facing settings as sections of toggles,
sliders, and color pickers bound to `Settings` key paths. Filtering by a
platform's `Features` gives any UI toolkit the list of controls to draw without
duplicating the form layout.

| UI | how it uses `ClientModel` |
|---|---|
| visionOS (SwiftUI) | `Connection` republishes the model's hosts, status, and PIN prompt as `@Published` properties. The views manage opening immersive spaces directly, and their settings forms are written in SwiftUI because they mix in visionOS-only controls (Room Setup and calibrations). |
| OpenXR shells (Dear ImGui) | `Panel` reads `state` each frame and invokes the action methods; `XRClient` wires up the shell callbacks. |
| Win32, Android views, or other toolkits | Observe `state` via `onChange`, invoke the same action methods, and generate settings controls from `SettingsForm`. |

### Cross-platform refactoring

Several shared types in `VRLinkCore` keep session, UI, discovery, and rendering
logic out of the platform backends:

- `StreamFrame` and `StreamDecoder` (`VRLinkCore/StreamLink.swift`) make
  `DisplayQueue`, `XRDisplay`, and session management generic over platform
  frame and decoder types.
- `StreamLink` manages host connection, pairing, decoder wiring, and `PlaySpace`
  transforms without depending on SwiftUI or platform session frameworks.
  `VRLinkAppleSession.Connection` wraps it as a SwiftUI `ObservableObject`.
- `HostFinder` maintains a combined list of Steam hosts (found via UDP
  broadcast) and WiVRn hosts (found via `ServiceFinder`, backed by Bonjour's
  `ServiceBrowser` on Apple platforms and `MulticastDNS` elsewhere).
- `ClientModel` and `SettingsForm` hold shared UI state and settings definitions
  (see [UI model](#ui-model)).
- `DeviceIdentity` bundles the device name, hardware model, OS version, and
  client version sent to hosts during pairing and session setup.
  `SystemVersion.device(named:)` builds it on Apple platforms, while Android
  reads system properties and JNI.
- `PictureAssembler` groups decoded images from multi-stream frames (such as
  WiVRn stereo and alpha streams) into complete frames for `VideoDecoder` and
  `MediaCodecDecoder`.
- `PictureSize` parses coded display dimensions from H.264 and HEVC sequence
  parameter sets.
- `HeadsetQuirks` stores per-headset workarounds for behavior that runtimes do
  not report.
- `QuadMesh` projects world-space quads into clip-space triangle meshes for
  per-eye rendering.
- `Log.write` redirects log output (for example, to Android `logcat`).
- `SystemCalls.swift` re-exports platform C libraries (`Android` or `Glibc` on
  non-Apple platforms) and wraps POSIX socket calls and flags whose types differ
  on Linux and Android.

`MulticastDNS` sends one-shot mDNS queries from an ephemeral port. Responders
answer unicast to queries from non-5353 ports (RFC 6762 section 6.7), so the
client does not need to bind port 5353 or acquire an Android Wi-Fi multicast
lock. It returns IPv4 addresses directly because Android's system resolver does
not resolve `.local` hostnames.

Remaining platform coupling to clean up:

- `QuadRenderer` packs vertices separately instead of using `QuadMesh`. Its
  vertex layout interleaves both eyes for visionOS single-pass layered rendering
  with reversed-Z depth, while `QuadMesh` builds one mesh per eye; unifying them
  requires updating the Metal shaders' vertex layout.
- The AV1 sequence-header parser lives in `VRLinkVideoToolbox`, so `PictureSize`
  does not support AV1 yet.
- `DeviceProfile.ownModel` checks for `"visionOS"` by string.
- Room selection and spatial anchors (`RoomTracker` and Room Setup) are tied
  to ARKit and RealityKit, though the room data model and polygon math live in
  `VRLinkCore` (OpenXR uses the runtime's stage boundary directly).
- `DeviceProfile.handValues` picks between Oculus Touch and PSVR2 Sense
  controller models rather than reading the active OpenXR interaction profile.
- The visionOS settings views build their forms in SwiftUI instead of using
  `SettingsForm`.

## Rooms

A room defines a saved play area with a center point, forward direction, floor
height, and floor boundary polygon. On visionOS, users create and edit rooms in
the Room Setup immersive space, and room definitions are persisted to
`rooms.json` in the data directory.

| component | file |
|---|---|
| Room model, `PlaySpace` transforms, and SteamVR chaperone JSON | `VRLinkCore/Rooms.swift` |
| Floor polygon math (stroke loops, expansion, self-intersection cleanup, inscribed play-area rectangle) | `VRLinkCore/FloorShape.swift` |
| Applying `PlaySpace` to outgoing poses and incoming frames | `VRLinkAppleSession/Connection.swift` (`playSpace`) |
| ARKit world anchors and floor plane detection | `VRLinkVisionTracking/RoomAnchors.swift` |
| Active room selection and recentering during a session | `VRLinkVisionRooms/RoomTracker.swift` |
| Room Setup immersive space and controls | `VRLinkVisionRooms/RoomSetupSpace.swift` |

### World anchors

Each room is stored relative to a platform world anchor (an ARKit `WorldAnchor`
on visionOS), and the room uses the anchor's UUID as its identifier. Because
world anchors stay fixed in physical space across tracking-origin resets, app
relaunches, and headset reboots, saved rooms stay aligned with the physical
room. Only the anchor's position and horizontal yaw are used so the room's axes
remain level. Because ARKit only runs world tracking inside an immersive space,
anchors can only be added, removed, or located while an immersive space is open.
Whenever ARKit reports an anchor that does not match any saved room in
`rooms.json`, `RoomAnchors` deletes it; this also cleans up anchors left behind
when the user presses "Delete All Rooms" from the 2D settings window.

### Play-space transforms

During streaming, `Connection` transforms every outgoing pose (head,
controllers, hand joints, and pinch rays) into the active room's coordinate
space, where `y = 0` is the room's floor. When decoded frames arrive from the
host, `Connection` transforms their rendered eye poses back into tracking space.
Handling both conversions in `Connection` keeps trackers, renderers, and stereo
depth estimation in raw tracking space, so neither streaming protocol
implementation needs room-specific logic.

### Room selection and boundaries

`RoomTracker` picks a room once per session after the streaming immersive space
opens and ARKit reports a valid head pose (the network connection starts before
the space opens, while tracking is still inactive). A room matches if the user
is standing inside its boundary or within 2.5 m of its center; if multiple rooms
match, the one with the closest center is selected. Rooms whose anchors ARKit
has not located are ignored, though `RoomTracker` waits up to 4 s for ARKit to
report on all saved rooms before deciding. If no room matches, `Connection`
falls back to the raw tracking origin with no boundary. Because poses are sent
in tracking space until room selection finishes, the view can shift once during
the first few moments of a session.

For Steam hosts, the room boundary is sent in the `VTE_CLIENT_CHAPERONE` value
(`docs/svl-values/vte-id-table.md`), with one chaperone wall per polygon edge
and a fresh `universeID` on every update so SteamVR reloads it mid-session.
WiVRn has no boundary message, so WiVRn hosts receive room-relative poses
without a boundary.

### Recentering

Recentering can be triggered either by the Steam host sending VTE event 0x16
(SteamVR's local zero-pose reset, such as `vrcmd --recenter`, is handled
entirely on the host) or by the user holding the Digital Crown on visionOS,
which resets the system tracking origin and fires `onWorldRecenter`. In either
case, `RoomTracker` moves the play space's origin beneath the user's head and
rotates it to match their current heading for the remainder of the session. The
physical boundary does not move: its corners are recomputed in the recentered
play space and re-sent to the host, so the play-space origin may no longer sit
at the center of the boundary. The saved room in `rooms.json` is left untouched
for future sessions.

After a Digital Crown recenter, `RoomTracker` waits until the room's anchor has
been re-measured against the new tracking origin before updating the play space.
When playing without a room, a Digital Crown recenter requires no extra work
because visionOS shifts the tracking origin directly, whereas a host recenter
places a temporary play-space frame beneath the user in tracking space. Inside
Room Setup, holding the Digital Crown has no effect on room positions because
rooms are attached to world anchors rather than the tracking origin.

### Room Setup

Room Setup opens an immersive space paired with a compact floating toolbar
(`Basic/Advanced`, `Add Room`, `Remove Room` when standing in a room, and
`Done`). Each room renders a center post two-thirds of the headset's height, a
forward-pointing flag at the top of the post, a floor grid of three concentric
rings spaced 1 m apart with six radial spokes, and its boundary polygon. Users
interact using either hand pinches (gaze-targeted from a distance or direct
touch) or VR controllers (aimed with the trigger or held directly against an
object):

- Dragging the post or flag moves the room center or rotates its forward
  direction. When grabbed from beyond 35 cm, movement scales proportionally with
  distance up to 8x so you can adjust a room from across the space.
- Holding a hand or controller below the active room's floor for 0.15 s pushes
  the floor down to that height. Pressing "Reset Floor Height" next to the post
  raises the floor halfway to the headset so you can push it back down. New
  rooms initialize their floor height from ARKit horizontal plane detection
  beneath the headset.
- In Basic mode, painting a stroke on the floor creates a boundary once the
  stroke closes a loop (crossing itself or coming within one brush width of
  itself while enclosing at least 0.2 m²). Once a boundary exists, painting a
  stroke that exits and re-enters the boundary expands the polygon to include
  the newly enclosed area; stroke endpoints within 10 cm outside the boundary
  snap across it automatically. Resulting polygons are simplified with a 2 cm
  tolerance and trimmed of self-intersections.
- In Advanced mode, pinching the floor places polygon corners one by one until
  you select the first corner again to close the loop. Existing corners can be
  dragged at any time, and holding a pinch on an edge for 0.3 s inserts a new
  corner. Basic and Advanced modes edit the same underlying polygon.

Controllers aim along their aim pose. For hand pinches, visionOS only provides
an eye-gaze ray at the start of an indirect pinch, so floor strokes begin where
you are looking and then move horizontally at 4x your hand displacement. Hand
rotation is ignored because steering with wrist angle or fingertip direction
proved too jittery.

The active room (the room you are standing in, or otherwise the closest room) is
highlighted with a yellow flag and green boundary, while inactive rooms are
drawn in gray.

### ARKit anchor coordinate drift

On visionOS, ARKit's reported `WorldAnchor` transforms do not stay aligned with
the tracking origin used for `queryDeviceAnchor` head poses: rooms can shift
whenever an immersive space opens or the Digital Crown recenters, and newly
created rooms can appear below the floor behind the user until a crown recenter.
To compensate, `RoomAnchors` places a temporary marker `WorldAnchor` at the
current head position, where its true tracking-space transform is known. When
polling `allAnchors`, `RoomAnchors` computes the correction transform from the
marker's reported pose to its true pose and applies that correction to every
room anchor in the same snapshot.

`RoomAnchors` places a fresh marker whenever the tracking origin may have
changed (when tracking starts in an immersive space, when the head position
jumps by more than 0.5 m between samples, or on a recenter). Until the new
marker is reported back, rooms are hidden briefly in Room Setup and active
streaming sessions hold their previous play space. Because some origin shifts
happen without an obvious jump (for example, an initial floor-height offset on
the first stream after launch), `RoomAnchors` also refreshes the marker every
5 s while keeping the previous correction active until the new marker resolves.
If the origin moves while a marker is still being added, that marker is
discarded. Significant corrections are logged
(`rooms: anchor transforms offset from tracking origin by ...`).

All ARKit calls in `RoomAnchors` (anchor queries, marker placement, and anchor
deletion) run in independent tasks with a 3 s timeout so a hung ARKit call
cannot stall tracking (previously, a mid-stream crown recenter could cause a
room to disappear from both the stream and Room Setup until app restart if a
sequential ARKit call hung). Diagnostic logs report anchor state transitions
(`rooms: room <id> anchor is tracked / reported but not tracked / not reported`),
stalled marker measurements (`rooms: waiting N s for anchor marker ...`), and
timed-out ARKit calls.

Timeout recovery and host-initiated recentering (0x16, not yet seen on the wire)
have not been verified on hardware yet, and SteamVR currently renders the
boundary only while its Chaperone settings page is open.

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
- **Dear ImGui** (MIT, vendored in `client/Sources/CImGui` at v1.91.9b): Draws
  the in-headset panel for OpenXR targets. Only the core library is included,
  with no platform or renderer backends, and the visionOS app does not link it.
- **Khronos OpenXR loader** (Apache 2.0): Downloaded from Maven Central by
  `client/android/build.sh` and bundled into the Android APK. Other platforms do
  not use it.
- **Protobuf**: Serialized by hand (`VRLinkCore/Protobuf.swift`) rather than
  adding a protobuf dependency, since only four broadcast message flows are
  needed.

## Remaining work

1. **visionOS**: finish remaining missing features.
2. **Windows helper**: install PSVR2 assets and optionally patch
   `driver_vrlink` for additional features (such as improved transport
   encoding).
3. **Android**: profile Wi-Fi streaming performance on Galaxy XR, verify Vulkan
   chroma keying, stereo depth estimation, controller grip offsets, and
   wired-network socket binding on hardware, and test Quest, Pico, and Lynx to
   finalize per-headset quirks and launch modes.
4. **Windows**: pair `VRLinkOpenXR` with a Vulkan or Direct3D graphics backend,
   a platform video decoder, and audio output (primarily as a desktop debugging
   target rather than an end-user build).

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
