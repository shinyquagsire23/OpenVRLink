# OpenVRLink companion

`openvrlink-companion` configures a Windows or Linux SteamVR PC for OpenVRLink
clients. It is structured as a Swift package with no dependencies outside
FoundationEssentials:

| target | description |
|---|---|
| `PatchCore` | Locates functions in `driver_vrlink`, patches DXBC and SPIR-V shaders, and implements the host side of the extension handshake. Uses only raw memory and Swift value types (no Foundation) so `driver_openvrlink` can link it directly |
| `CompanionKit` | Locates Steam and SteamVR, adapts Sense controller render models, and installs `driver_openvrlink` and its settings schema entries |
| `openvrlink-companion` | GUI and command-line installer and diagnostic tool |
| `WinAPI` | C header declarations for Win32 GUI, WinHTTP, and resource APIs on Windows (empty on other platforms) |
| `driver_openvrlink` | Device-less SteamVR driver loaded into `vrserver` alongside `driver_vrlink` to apply in-memory hooks |
| `DriverABI` | C header declarations for OpenVR vtables, Direct3D's `ID3DBlob`, and OS memory/module APIs |

## Usage

`openvrlink-companion` manages two independent components that can be installed,
updated, and uninstalled separately:

- **Sense controller models** (`models`). Searches for an existing copy of the
  PlayStation VR2 Sense render models (checking Sony's PlayStation VR2 App
  first, then registered external drivers, and finally the sparse models ALVR
  places in SteamVR's `playstation_vr2` driver folder), copies them into a
  resource-only driver named `openvrlink_sense`, and remaps their input paths to
  match the Touch controller inputs sent by OpenVRLink. `openvrlink-companion`
  flags an available update if a better model source is installed later (such as
  installing Sony's app after using ALVR's models) or if the input remapping
  changes.
- **VR Link extensions driver** (`driver`). Installs `driver_openvrlink` and
  adds its settings controls to SteamVR's VR Link settings tab.
  `openvrlink-companion` flags an update when its bundled driver differs from
  the installed binary, or when a SteamVR update overwrites `driver_vrlink`'s
  settings schema and removes the OpenVRLink controls.

### Windows

`openvrlink-companion.exe` is a single executable with `driver_openvrlink.dll`
embedded as a resource. Running it without arguments opens a GUI window showing
each component's status, an **Install** or **Update** button when an action is
available, and an **✕** button to uninstall it. The bottom of the window shows
the current `openvrlink-companion` version and a button to check GitHub for a
newer release, download it, and relaunch.

Passing command-line arguments runs the same CLI interface as on Linux. Because
`openvrlink-companion.exe` uses the Windows GUI subsystem, `cmd.exe` returns to
the prompt immediately rather than waiting for it to exit; run
`start /wait openvrlink-companion status` or redirect stdout if you want to wait
for output synchronously.

### Command line

```
openvrlink-companion status                  # show detected paths and component status
openvrlink-companion install [models] [driver] [encoding-size]
openvrlink-companion uninstall [models] [driver] [encoding-size]
openvrlink-companion update [--check]        # update openvrlink-companion to the latest release
```

`install` accepts `--steamvr DIR` if SteamVR is not detected automatically,
`--models DIR` to copy Sense models from a specific directory, `--driver FILE`
to install an external `driver_openvrlink` binary instead of the bundled one,
and `--vrlink-tab` to place the settings controls in SteamVR's VR Link tab
(by editing `driver_vrlink`'s schema file) instead of a dedicated OpenVRLink
tab. `--vrlink-tab` only works on older SteamVR builds that render the VR Link
tab from its schema. Starting around SteamVR 2.19.4, SteamVR uses a built-in
UI page for VR Link that ignores custom schema entries.

On Linux, `openvrlink-companion` looks for `driver_openvrlink.so` next to the
executable (matching the release archive layout, e.g. in `~/.local/bin`) or at
`../lib/openvrlink/driver_openvrlink.so` and
`../share/openvrlink/driver_openvrlink.so` for system packages.

### Headset profile settings

Along with its runtime patches, `driver_openvrlink` includes `default.vrsettings`
sections for OpenVRLink's native headset names (`vrlink_Apple Vision Pro (OpenVRLink)` and
`vrlink_OpenVRLink Headset`). When `driver_vrlink` sees an unrecognized HMD
model name, it reads the matching `vrlink_<model>` section from SteamVR's
settings; these defaults enable eye tracking, 10-bit video, and the headset's
requested render resolution all at once. Once an OpenVRLink client sees that the
host has these settings installed, it reports its native model name on
subsequent connections instead of spoofing a Vive Focus Vision
(see [docs/openvrlink-extensions.md](../docs/openvrlink-extensions.md), section 3).
Eye tracking data is still only forwarded to SteamVR apps when
`shareEyeTrackingData` is enabled in SteamVR's Steam Link settings;
`openvrlink-companion` does not modify that setting.

### High-PPD encoding size

Running `openvrlink-companion install encoding-size` (or clicking **Apply** in
the GUI) sets `driver_vrlink/streamFormatWidth` to `3200` and
`automaticStreamFormatWidth` to `false` in `steamvr.vrsettings`, exceeding the
maximum value exposed by SteamVR's UI slider. Running
`openvrlink-companion uninstall encoding-size` (or clicking **✕**) removes both
keys so SteamVR manages the encoding width again. Because this edits user
settings rather than installing a driver, `install` and `uninstall` only touch
it when `encoding-size` is specified explicitly. SteamVR must be closed first
so it does not overwrite `steamvr.vrsettings` on exit.

### Installation paths and Steam discovery

Both drivers are installed under `%LOCALAPPDATA%\OpenVRLink` on Windows or
`~/.local/share/openvrlink` on Linux, and registered in `openvrpaths.vrpath`
(the same file `vrpathreg adddriver` edits). Nothing inside the SteamVR
directory is modified unless you pass `--vrlink-tab`, which edits
`driver_vrlink`'s `settingsschema.vrsettings`. Running `install` without
`--vrlink-tab` removes any entries added to that file by an earlier install.

`openvrlink-companion` checks known Steam installation locations directly:

- **Windows**: `HKCU\Software\Valve\Steam\SteamPath` and
  `HKLM\SOFTWARE\Valve\Steam\InstallPath` (in both 64-bit and 32-bit registry
  views), followed by `Steam` under `%ProgramFiles(x86)%` and `%ProgramFiles%`.
- **Linux**: `$XDG_DATA_HOME/Steam`, `~/.local/share/Steam`, `~/.steam/steam`,
  `~/.steam/root`, `~/.steam/debian-installation`, the Steam snap
  (`~/snap/steam/common/.local/share/Steam`), and the Steam Flatpak
  (`~/.var/app/com.valvesoftware.Steam/.local/share/Steam` and `data/Steam`).
- **Steam libraries**: every library folder listed in each installation's
  `libraryfolders.vdf`.

Sandboxed Linux builds of Steam (Snap and Flatpak) run with private home
directories and cannot read hidden directories in `$HOME`. When SteamVR is
installed inside a Snap or Flatpak, `openvrlink-companion` places its drivers
and edits `openvrpaths.vrpath` inside that sandbox's config and data directories
(`~/snap/steam/common/.config` and `.local/share` for Snap, or
`~/.var/app/com.valvesoftware.Steam/.config` / `config` and `.local/share` for
Flatpak). If multiple Steam installations exist on the system, it selects the
one that has SteamVR installed.

### Self-updates

`openvrlink-companion update` and the GUI **Check for updates** button query the
OpenVRLink GitHub releases API and look for the latest non-prerelease tag with a
higher numeric version (`v0.1.0-10` > `v0.1.0-9`) that includes an asset for the
current platform:

| platform | release asset | contents |
|---|---|---|
| Windows | `openvrlink-companion-windows-x86_64.exe` | single-file executable with embedded `driver_openvrlink.dll` |
| Linux | `openvrlink-companion-linux-<arch>.tar.gz` | `openvrlink-companion` and `driver_openvrlink.so` |

Repository-wide versioning is configured in `version.json` at the repository
root (`version` and `build`, formatted as `0.1.0-8`). The visionOS Xcode project
reads `version.json` directly when generated, and `openvrlink-companion` compiles
it in (`Sources/RepoVersion`, C23 `#embed`), so a version bump is one edit. The
package therefore has to be built inside the repository, with `version.json` one
folder above it. On Windows, `package-windows.cmd` stamps
the version from `version.json` into the executable as a `VERSION` resource, or
uses an explicit override when passed as `package-windows.cmd VERSION`.

During an update, the new binary is staged next to `openvrlink-companion` and
invoked with `version` to verify that it runs and reports the expected version.
Because Windows locks running executables against overwrites but allows renaming
them, the updater renames the running executable to `<name>.old-<id>` and moves
the new binary into place; the next launch deletes any leftover `.old-*` files.
On Linux, the updater swaps both `openvrlink-companion` and
`driver_openvrlink.so` in the same directory, or exits with an error if the
directory is not writable (for example, when installed via a system package
manager). Updating `openvrlink-companion` does not automatically modify the
installed SteamVR drivers; afterward, any component whose bundled driver changed
will show an available update.

Downloads use WinHTTP on Windows and `curl` on Linux over HTTPS. To test the
updater locally without publishing a GitHub release, set `OVRL_RELEASE_LIST` to
a local JSON file in GitHub's releases API format (local file paths are accepted
as download URLs when `OVRL_RELEASE_LIST` is set).

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
- **Floor perimeter patch.** On Windows, `driver_openvrlink` replaces the call
  at the end of `SVLHMDDriver::Activate` that forces SteamVR to ignore
  `collisionBounds/CollisionBoundsGroundPerimeterOn` with a 6-byte NOP
  (`Scan.keepFloorPerimeter`). Because `Activate` runs as soon as a headset
  connects—before the extension handshake—this patch applies to all VR Link
  headsets. The ground perimeter setting defaults to off, so behavior only
  changes when you enable it in SteamVR, and the original bytes are restored in
  `Cleanup`. SteamVR still hides vertical chaperone walls for VR Link headsets
  inside `vrcompositor` (see [docs/svl-values/vte-id-table.md](../docs/svl-values/vte-id-table.md)).
  The equivalent patch has not been located in the Linux driver yet.
- **No background threads.** Periodic checks run inside `vrserver`'s `RunFrame`
  callback.
- **Module pinning.** Steam's watchdog loads every registered driver into
  `steam.exe` and immediately unloads it, which can crash libraries that bundle
  a language runtime. `driver_openvrlink` pins its module handle on the first
  call to `HmdDriverFactory`. Because `steam.exe` keeps the DLL mapped while
  Steam is open, `install` renames any locked binary before writing a new build
  in its place, and `uninstall` moves locked files to
  `%LOCALAPPDATA%\OpenVRLink\in-use` to be deleted on a later run after Steam
  exits.
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
  `openvrlink-companion` is also statically linked and imports
  `FoundationEssentials` instead of full `Foundation`, avoiding the 34 MB ICU
  Unicode data table that `Foundation` pulls into static builds. Process
  spawning, threading, locks, and string helpers are implemented directly on
  Win32 and POSIX in `CompanionKit/OS.swift` and `Window.swift`, keeping the
  binary at 18 MB on Windows (including the embedded driver DLL) and 22 MB on
  Linux. On Windows, its only non-OS DLL dependencies are `MSVCP140.dll` and
  `VCRUNTIME140.dll`, which Steam already installs alongside SteamVR.
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

Windows and Linux builds have both been verified end-to-end with the macOS
viewer: Windows 11 running SteamVR 2.19.4, and arm64 Ubuntu 24.04 running the
October 2026 x86-64 Linux SteamVR build under FEX inside the Steam snap. In both
cases, `driver_openvrlink` loaded into `vrserver`, patched the encode shaders on
connection, and negotiated encoding gamma with the client. Visual quality on an
OLED headset still needs evaluation.

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
package-windows.cmd [VERSION]                    # build single-file Windows release
./package-linux.sh                               # build Linux release archive
```

`package-windows.cmd` compiles a release build and runs
`openvrlink-companion pack`, which copies `openvrlink-companion.exe`, embeds
`driver_openvrlink.dll` into its Win32 resources via `UpdateResource` (without
requiring a separate resource compiler), and verifies that the packed binary
starts. `pack` also embeds a `VS_VERSIONINFO` resource for Windows File Explorer
and, when given `--icon FILE.ico`, embeds the application icon used by both File
Explorer and the GUI window (`WindowsResources`). The checked-in icon at
`Resources/openvrlink-companion.ico` is generated from the visionOS app icon
layers by `python3 make-icon.py`. Unpacked development builds load
`driver_openvrlink.dll` from the same directory instead and use the default
system window icon. `package-linux.sh` builds `driver_openvrlink.so` natively on
x86-64 hosts or via `cross-build-linux-x86_64.sh` on arm64 hosts (the arm64
cross-build path has been tested; native x86-64 packaging has not).

To inspect the Windows GUI layout headlessly, run
`openvrlink-companion window --snapshot FILE.bmp` to render the window to a BMP
file. Rendering requires an interactive desktop session (capturing directly over
SSH produces a black image, so run it via a scheduled task with `/it`).

`Tests/DriverHarness` compiles a mock `driver_vrlink.dll` (with matching
function prologues) and a C host executable that loads `driver_openvrlink.dll`
the way `steam.exe` and `vrserver` do, runs the OpenVRLink handshake, and
verifies that all hooks and shader patches apply and clean up cleanly.
