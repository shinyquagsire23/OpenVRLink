#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Cross-compiles libOpenVRLinkAndroid.so using the Swift SDK for Android and packages it into a signed APK
# using the Android SDK command-line tools (aapt2, zipalign, and apksigner).
#
# Usage:
#   ./build.sh              Build build/OpenVRLink.apk
#   ./build.sh --install    Build and install onto a connected headset via adb
#   ./build.sh --flat       Start in a 2D launcher window and enter XR after selecting a host. By default
#                           the launcher goes straight into XR with the panel floating there, which is
#                           what Android XR needs (it gives this app's 2D window no pointer).
#
# Prerequisites:
#   - An open-source swift.org toolchain (Xcode's bundled toolchain does not support Swift SDKs) paired
#     with the matching Swift SDK for Android:
#     https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html
#     Set SWIFT_TOOLCHAIN to override automatic detection in ~/Library/Developer/Toolchains.
#   - Android SDK (ANDROID_HOME, defaulting to ~/Library/Android/sdk) with build-tools, a platform SDK,
#     and NDK r27 or later configured via the Swift SDK's setup-android-sdk.sh script.
#   - An Android debug keystore (~/.android/debug.keystore), or OPENVRLINK_KEYSTORE and
#     OPENVRLINK_KEYSTORE_PASS.
#
# The Khronos OpenXR loader AAR is downloaded from Maven Central on first build and cached in build/.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
client=$(dirname "$here")
out="$here/build"

install=""
flat=""
for argument in "$@"; do
    case "$argument" in
        --install) install=1 ;;
        --flat) flat=1 ;;
        *) echo "usage: build.sh [--install] [--flat]" >&2; exit 2 ;;
    esac
done

# Target Android 10 (API 29) by default to support Quest, Pico, Lynx, and Android XR.
api=${OPENVRLINK_ANDROID_API:-29}
triple="aarch64-unknown-linux-android$api"
abi=arm64-v8a
package=${OPENVRLINK_PACKAGE:-org.openvrlink.client}
loader_version=1.1.65

sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
tools=$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)
platform=$(ls -d "$sdk"/platforms/android-* | sort -V | tail -1)
toolchain=${SWIFT_TOOLCHAIN:-$(ls -d "$HOME"/Library/Developer/Toolchains/swift-*-RELEASE.xctoolchain 2>/dev/null | sort -V | tail -1)}
[ -x "$toolchain/usr/bin/swift" ] || { echo "no swift.org toolchain found; set SWIFT_TOOLCHAIN" >&2; exit 1; }
swift="$toolchain/usr/bin/swift"
# The Swift SDK locates the NDK via ANDROID_NDK_HOME and requires r27 or later. If ANDROID_NDK_HOME is
# unset or points to an older NDK, fall back to the newest NDK installed under $sdk/ndk.
ndk_major() { sed -n 's/^Pkg.Revision = \([0-9]*\).*/\1/p' "$1/source.properties" 2>/dev/null; }
if [ -z "${ANDROID_NDK_HOME:-}" ] || [ "$(ndk_major "$ANDROID_NDK_HOME")" -lt 27 ] 2>/dev/null; then
    ANDROID_NDK_HOME=$(ls -d "$sdk"/ndk/* | sort -V | tail -1)
fi
[ "$(ndk_major "$ANDROID_NDK_HOME")" -ge 27 ] || { echo "Android NDK 27 or later is needed; found $ANDROID_NDK_HOME" >&2; exit 1; }
export ANDROID_NDK_HOME

version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$client/../version.json")
build=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['build'])" "$client/../version.json")

echo "== building for $triple with $("$swift" --version 2>&1 | head -1)"
scratch="$client/.build-android"
"$swift" build --package-path "$client" --scratch-path "$scratch" --swift-sdk "$triple" -c release --product OpenVRLinkAndroid
built=$("$swift" build --package-path "$client" --scratch-path "$scratch" --swift-sdk "$triple" -c release --show-bin-path)

rm -rf "$out/apk"
libs="$out/apk/lib/$abi"
mkdir -p "$libs"
cp "$built/libOpenVRLinkAndroid.so" "$libs/"

# Locate the Swift runtime libraries in the Swift SDK and libc++_shared.so in the NDK sysroot.
resources=$("$swift" sdk configure --show-configuration "$("$swift" sdk list | grep -i android | head -1)" "$triple" 2>/dev/null \
    | sed -n 's/^swiftResourcesPath: //p')
[ -d "$resources/android" ] || { echo "could not find the Swift SDK's runtime libraries" >&2; exit 1; }
sysroot=$("$swift" sdk configure --show-configuration "$("$swift" sdk list | grep -i android | head -1)" "$triple" 2>/dev/null \
    | sed -n 's/^sdkRootPath: //p')
readelf=$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-readelf | head -1)

# Recursively copy transitive shared-library dependencies required by libOpenVRLinkAndroid.so.
needed() { "$readelf" -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
queue="libOpenVRLinkAndroid.so"
while [ -n "$queue" ]; do
    next=""
    for name in $queue; do
        for wanted in $(needed "$libs/$name"); do
            [ -e "$libs/$wanted" ] && continue
            if [ -e "$resources/android/$wanted" ]; then
                cp "$resources/android/$wanted" "$libs/"
            elif [ "$wanted" = "libc++_shared.so" ]; then
                cp "$sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$libs/"
            else
                continue                       # provided by the Android system image (libc, libandroid, libvulkan, etc.)
            fi
            next="$next $wanted"
        done
    done
    queue=$next
done

# Strip debug symbols from the packaged copies while leaving unstripped binaries in .build-android/.
strip=$(dirname "$readelf")/llvm-strip
for library in "$libs"/*.so; do "$strip" --strip-unneeded "$library"; done

loader="$out/openxr_loader_for_android-$loader_version.aar"
if [ ! -e "$loader" ]; then
    mkdir -p "$out"
    curl -sfL -o "$loader.part" \
        "https://repo1.maven.org/maven2/org/khronos/openxr/openxr_loader_for_android/$loader_version/openxr_loader_for_android-$loader_version.aar"
    mv "$loader.part" "$loader"
fi
unzip -q -o -j "$loader" "jni/$abi/libopenxr_loader.so" -d "$libs"

min_sdk=$api
launcher='<category android:name="android.intent.category.LAUNCHER" \/>'
if [ -n "$flat" ]; then immersive_launcher=""; drop_flat=""; else immersive_launcher=$launcher; drop_flat='/@FLAT_ONLY_BEGIN@/,/@FLAT_ONLY_END@/d'; fi
sed -e "s/@PACKAGE@/$package/g" -e "s/@VERSION@/$version/g" -e "s/@BUILD@/$build/g" -e "s/@MIN_SDK@/$min_sdk/g" \
    -e "s/@IMMERSIVE_LAUNCHER@/$immersive_launcher/" -e "$drop_flat" \
    "$here/AndroidManifest.xml" > "$out/AndroidManifest.xml"

echo "== packaging"
unsigned="$out/unsigned.apk"
aligned="$out/aligned.apk"
rm -f "$unsigned" "$aligned" "$out/OpenVRLink.apk"
rm -f "$out/resources.zip"
"$tools/aapt2" compile --dir "$here/res" -o "$out/resources.zip"
"$tools/aapt2" link -o "$unsigned" --manifest "$out/AndroidManifest.xml" -I "$platform/android.jar" "$out/resources.zip"
# Store native libraries uncompressed (-0) so Android can mmap them directly from page-aligned offsets.
(cd "$out/apk" && zip -q -r -0 "$unsigned" lib)
"$tools/zipalign" -p 4 "$unsigned" "$aligned"

keystore=${OPENVRLINK_KEYSTORE:-$HOME/.android/debug.keystore}
pass=${OPENVRLINK_KEYSTORE_PASS:-android}
"$tools/apksigner" sign --ks "$keystore" --ks-pass "pass:$pass" --out "$out/OpenVRLink.apk" "$aligned"
rm -f "$unsigned" "$aligned" "$out/OpenVRLink.apk.idsig"
echo "== $out/OpenVRLink.apk ($(du -h "$out/OpenVRLink.apk" | cut -f1)): $package $version-$build"
for library in "$libs"/*.so; do printf '   %9d %s\n' "$(wc -c < "$library")" "$(basename "$library")"; done

if [ -n "$install" ]; then
    "$sdk/platform-tools/adb" install -r "$out/OpenVRLink.apk"
    echo "launch from the headset, or:"
    echo "  adb shell am start -n $package/android.app.NativeActivity     (immersive)"
    echo "  adb shell am start -n $package/.Panel                         (flat panel)"
    echo "log: adb logcat -s OpenVRLink"
fi
