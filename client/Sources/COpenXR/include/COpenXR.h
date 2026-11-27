// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Exposes the unmodified Khronos OpenXR headers (under `openxr/`, licensed Apache-2.0 OR MIT) to Swift.
//
// `XR_NO_PROTOTYPES` disables static function prototypes so no OpenXR loader is linked at build time.
// `VRLinkOpenXR` resolves all OpenXR functions dynamically via `xrGetInstanceProcAddr` (see `Loader.swift`).

#ifndef COPENXR_H
#define COPENXR_H

#include <time.h>

#define XR_NO_PROTOTYPES 1
#define XR_USE_TIMESPEC 1

#if defined(__APPLE__)
#define XR_USE_GRAPHICS_API_METAL 1
#endif

#if defined(__ANDROID__)
// Import JNI and Vulkan headers through CAndroidNDK so Swift sees unified C types across modules.
#include <CAndroidNDK.h>
#define XR_USE_PLATFORM_ANDROID 1
#define XR_USE_GRAPHICS_API_VULKAN 1
#endif

#include "openxr/openxr.h"
#include "openxr/openxr_platform.h"
#include "openxr/openxr_loader_negotiation.h"

// Inline wrappers for C function-like macros that Swift cannot import directly.
static inline XrVersion ovrl_xr_version(uint64_t major, uint64_t minor, uint64_t patch) {
    return XR_MAKE_VERSION(major, minor, patch);
}
static inline uint16_t ovrl_xr_version_major(XrVersion version) { return (uint16_t)XR_VERSION_MAJOR(version); }
static inline uint16_t ovrl_xr_version_minor(XrVersion version) { return (uint16_t)XR_VERSION_MINOR(version); }
static inline uint32_t ovrl_xr_version_patch(XrVersion version) { return (uint32_t)XR_VERSION_PATCH(version); }

#if defined(__ANDROID__)
// Acquires and returns a retained `ANativeWindow` for the Java `Surface` from an Android Surface swapchain,
// or NULL on failure. Releases `surface` if it is a JNI local reference.
void *ovrl_xr_window(void *java_vm, jobject surface);
// Posts a single transparent RGBA buffer of the given dimensions to the window. Returns 0 on success.
int ovrl_xr_fill_window(void *window, int32_t width, int32_t height);
void ovrl_xr_release_window(void *window);
#endif

#endif
