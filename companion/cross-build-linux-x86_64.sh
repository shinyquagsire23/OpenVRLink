#!/bin/sh
# Cross-compiles `driver_openvrlink` for x86-64 Linux from a non-x86 host (Linux
# SteamVR is an x86-64 binary even when running under FEX on arm64).
#   TOOLCHAIN  root directory of the host Swift toolchain (parent of `usr`)
#   X86_SWIFT  `usr/lib` directory from the matching x86-64 Swift toolchain (`swift`, `swift_static`)
#   SYSROOT    x86-64 Linux sysroot containing glibc and GCC development files
set -e
here=$(cd "$(dirname "$0")" && pwd)
: "${TOOLCHAIN:?}" "${X86_SWIFT:?}" "${SYSROOT:?}"
# Statically link `libstdc++` alongside the Swift runtime and disallow undefined
# symbols so `driver_openvrlink.so` only depends on glibc inside `vrserver`.
gcc=$(ls -d "$SYSROOT"/usr/lib/gcc/x86_64-linux-gnu/* | tail -1)
clang=$(ls -d "$TOOLCHAIN"/usr/lib/clang/* | tail -1)     # the compiler's own headers (stdbool.h, ...)
cd "$here"
PATH="$TOOLCHAIN/usr/bin:$PATH" swift build --build-system native -c release --product driver_openvrlink \
  --scratch-path .build-x86_64 --triple x86_64-unknown-linux-gnu --sdk "$SYSROOT" --static-swift-stdlib \
  -Xswiftc -resource-dir -Xswiftc "$X86_SWIFT/swift_static" -Xswiftc -use-ld=lld \
  -Xswiftc -Xclang-linker -Xswiftc --sysroot="$SYSROOT" \
  -Xswiftc -Xclang-linker -Xswiftc --gcc-install-dir="$gcc" \
  -Xcc --sysroot="$SYSROOT" -Xcc --gcc-install-dir="$gcc" -Xcc -resource-dir -Xcc "$clang" \
  -Xlinker "$gcc/libstdc++.a" -Xlinker -lm -Xlinker -ldl -Xlinker -lpthread -Xlinker --no-undefined
ls -la .build-x86_64/release/libdriver_openvrlink.so
