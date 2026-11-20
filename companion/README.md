# OpenVRLink companion

`openvrlink-companion` configures a Windows or Linux SteamVR PC for OpenVRLink
clients. It is structured as a Swift package with no dependencies outside
Foundation:

| target | description |
|---|---|
| `PatchCore` | Locates functions in `driver_vrlink`, patches DXBC and SPIR-V shaders, and implements the host side of the extension handshake. Uses only raw memory and Swift value types (no Foundation) so `driver_openvrlink` can link it directly |
| `CompanionKit` | Locates Steam and SteamVR, adapts Sense controller render models, and installs `driver_openvrlink` and its settings schema entries |
| `openvrlink-companion` | Command-line installer and diagnostic tool |
| `driver_openvrlink` | Device-less SteamVR driver loaded into `vrserver` alongside `driver_vrlink` to apply in-memory hooks |
| `DriverABI` | C header declarations for OpenVR vtables, Direct3D's `ID3DBlob`, and OS memory/module APIs |

## Usage

```
openvrlink-companion install      # installs models + extension driver; restart SteamVR afterward
openvrlink-companion status       # shows detected paths, installed drivers, and patch compatibility
openvrlink-companion uninstall
```

`openvrlink-companion install` performs two independent setup steps:

1. **PlayStation VR2 Sense controller models.** It searches for an existing copy
   of the Sense render models (checking Sony's PlayStation VR2 App first, then
   registered external drivers, and finally the sparse models ALVR places in
   SteamVR's `playstation_vr2` driver folder), copies them into a resource-only
   driver named `openvrlink_sense`, and remaps the input paths to match the
   Touch controller inputs sent by OpenVRLink. You can pass `--models DIR` to
   copy from a specific directory containing `playstation_vr2_sense_left` and
   `playstation_vr2_sense_right`.
2. **VR Link extensions** (can be skipped with `--no-patches`). It installs
   `driver_openvrlink` and adds its settings controls to SteamVR's VR Link
   settings tab. Pass `--own-tab` to place those controls in a separate
   OpenVRLink settings tab without modifying `driver_vrlink`'s schema file.

Both drivers are installed under `%LOCALAPPDATA%\OpenVRLink` on Windows or
`~/.local/share/openvrlink` on Linux, and registered in `openvrpaths.vrpath`
(the same file `vrpathreg adddriver` edits). Unless `--own-tab` is used, the
installer also adds entries to `driver_vrlink`'s `settingsschema.vrsettings`.
Running `uninstall` removes those entries, and if a SteamVR update overwrites
`settingsschema.vrsettings`, you can run `install` again to restore the menu
controls.

## Hooking and safety

Protocol details for the extensions are documented in
[docs/openvrlink-extensions.md](../docs/openvrlink-extensions.md).
`driver_openvrlink` uses several safeguards when patching `driver_vrlink`:

- **No on-disk changes to `driver_vrlink`.** All code and shader patches happen
  in memory, so SteamVR updates and Steam file verification never encounter
  modified binaries.
- **Call-site redirection.** Rather than overwriting function prologues,
  `driver_openvrlink` redirects direct `call` and `jmp` displacements to wrapper
  functions that call the unmodified target function. During `Cleanup`, the
  driver restores the original 4-byte displacements at each call site.
- **Conservative lookup.** Targets are resolved from `.symtab` when symbols are
  present (such as the July 2026 Linux build), by unique byte signature, or via
  the PE import table. If a target is missing, matches multiple addresses, or
  has no direct callers, `driver_openvrlink` skips the hook, marks
  `driver_openvrlink/gammaAvailable` as `false`, updates `status`, and leaves
  `driver_vrlink` running unmodified.
- **Handshake gating.** Patches remain inactive until a connected client sends
  an advancing `oxClient` heartbeat, so other headsets using the same PC receive
  an unmodified VR Link stream.
- **No background threads.** Periodic checks run inside `vrserver`'s `RunFrame`
  callback.
- **Module pinning.** Steam's watchdog loads every registered driver into
  `steam.exe` and immediately unloads it, which can crash libraries that bundle
  a language runtime. `driver_openvrlink` pins its module handle on the first
  call to `HmdDriverFactory`. Because `steam.exe` keeps the DLL mapped while
  Steam is open, `install` renames any locked binary before copying a new build
  into place.
- **Non-fatal initialization.** `Init` always returns `0` so hook failures never
  prevent SteamVR from starting, and SteamVR's safe mode can disable
  `driver_openvrlink` like any other third-party driver.

You can run `openvrlink-companion check FILE` against any `driver_vrlink.dll` or
`driver_vrlink.so` to verify whether all hook targets resolve before running a
new SteamVR build.

## Linking the Swift runtime

Because `driver_openvrlink` loads into `steam.exe` and `vrserver`, keeping its
external dependencies minimal avoids library conflicts. With Swift 6.4.2:

- **Static stdlib (default).** Building with `--static-swift-stdlib` produces a
  single 8.5 MB `driver_openvrlink.dll` that depends only on Windows system DLLs
  and the Visual C++ runtime already loaded by `driver_vrlink`.
  `openvrlink-companion` links Foundation statically in the same way (64 MB).
- **Dynamic stdlib.** Produces a 0.6 MB DLL, at the cost of bundling
  `swiftCore.dll` and related Swift runtime libraries alongside the driver.
- **Embedded Swift.** `PatchCore` and `driver_openvrlink` avoid Foundation,
  existentials, untyped `Error`, and `String` so they remain compatible with
  Embedded Swift, though the Swift 6.4 Windows toolchain does not yet ship the
  embedded standard library (`module 'Swift' cannot be imported in embedded
  Swift mode`).

## Platform status

| feature | Windows | Linux |
|---|---|---|
| Controller models | verified on host | implemented (untested with local model files) |
| Extension handshake | verified on host | verified on host |
| Encoding gamma | verified on host | verified on host |

Windows and Linux builds have both been tested end-to-end with the macOS viewer:
Windows 11 running SteamVR 2.19.4 (2026-11-19), and arm64 Ubuntu 24.04 running
the October 2026 x86-64 Linux SteamVR build under FEX inside the Steam snap. In
both cases, `driver_openvrlink` loaded into `vrserver`, patched the encode
shaders on connection, and negotiated encoding gamma with the client. Visual
quality on an OLED headset still needs evaluation.

Because Linux SteamVR is an x86-64 binary even on arm64 hosts,
`driver_openvrlink.so` must always be built for x86-64. On an arm64 Linux host,
`openvrlink-companion` builds natively while `cross-build-linux-x86_64.sh`
cross-compiles `driver_openvrlink.so` using an x86-64 Swift resource directory
and sysroot. The script statically links the Swift runtime and `libstdc++` so
`driver_openvrlink.so` only requires `libc`, `libm`, `libdl`, and `libpthread`
from `vrserver`. Note that building against an Ubuntu 24.04 sysroot requires
glibc 2.38; targeting older Steam Runtime containers requires building against
an older sysroot.

Linux builds of `driver_vrlink.so` have varied more across updates than Windows
builds: the July 2026 build included `.symtab` symbols and named shader
uniforms, whereas the October 2026 build is stripped, moves its SPIR-V shaders
under `resources/shaders/vulkan/`, and widens the constant buffer. To support
both, `Scan` checks `.symtab` first and falls back to byte signatures, and
`SPIRV.patchGamma` identifies an unused constant-buffer float by scanning SPIR-V
instructions rather than matching uniform names.

## Building and testing

```
swift build -c release --static-swift-stdlib     # native build on Windows or Linux
./cross-build-linux-x86_64.sh                    # cross-compile Linux x86-64 driver
swift test                                       # unit tests (Windows, Linux, or macOS)

# Optional tests against local SteamVR binaries and shaders (see Tests/PatchCoreTests/RealFiles.swift):
OVRL_TEST_VRLINK_DLL=…/driver_vrlink.dll OVRL_TEST_VRLINK_SO=…/driver_vrlink.so \
OVRL_TEST_VRLINK_FXO=…/vrlink/resources/shaders/d3d11 swift test

Tests\DriverHarness\run.cmd                      # Windows end-to-end harness
```

`Tests/DriverHarness` compiles a mock `driver_vrlink.dll` (with matching
function prologues) and a C host executable that loads `driver_openvrlink.dll`
the way `steam.exe` and `vrserver` do, runs the OpenVRLink handshake, and
verifies that all hooks and shader patches apply and clean up cleanly.
