#!/bin/sh
# Builds the Linux release archive (`openvrlink-companion-linux-<arch>.tar.gz`) containing
# `openvrlink-companion` and `driver_openvrlink.so`. The archive can be extracted directly
# into a single directory (such as `~/.local/bin`) or installed by a system package as
# `bin/openvrlink-companion` and `lib/openvrlink/driver_openvrlink.so`.
#
# SteamVR on Linux is always x86-64, so `driver_openvrlink.so` is built natively on x86-64
# hosts or cross-compiled via `cross-build-linux-x86_64.sh` on other architectures.
#   OUT      output directory for the archive (default: .build/package)
#   DRIVER   path to a prebuilt driver_openvrlink.so to package instead of building one
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
arch=$(uname -m)
out=${OUT:-$here/.build/package}
swift build -c release --static-swift-stdlib --product openvrlink-companion
program=$(swift build -c release --static-swift-stdlib --show-bin-path)/openvrlink-companion
if [ -z "$DRIVER" ]; then
  if [ "$arch" = x86_64 ]; then
    # Match the cross-build flags: statically link libstdc++ and disallow undefined symbols
    # so the driver only depends on glibc libraries already loaded in vrserver.
    swift build -c release --static-swift-stdlib --product driver_openvrlink \
      -Xlinker "$(cc -print-file-name=libstdc++.a)" -Xlinker -lm -Xlinker -ldl -Xlinker -lpthread -Xlinker --no-undefined
    DRIVER=$(swift build -c release --static-swift-stdlib --show-bin-path)/libdriver_openvrlink.so
  else
    ./cross-build-linux-x86_64.sh
    DRIVER=$here/.build-x86_64/release/libdriver_openvrlink.so
  fi
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$program" "$stage/openvrlink-companion"
cp "$DRIVER" "$stage/driver_openvrlink.so"
mkdir -p "$out"
tar -czf "$out/openvrlink-companion-linux-$arch.tar.gz" -C "$stage" openvrlink-companion driver_openvrlink.so
ls -la "$out/openvrlink-companion-linux-$arch.tar.gz"
