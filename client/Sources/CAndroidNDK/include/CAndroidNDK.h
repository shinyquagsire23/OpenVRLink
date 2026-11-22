// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Exposes the Android NDK headers used by OpenVRLink (NativeActivity, MediaCodec, AAudio, and Vulkan) to Swift.
// Compiles as an empty header on non-Android platforms.

#ifndef CANDROIDNDK_H
#define CANDROIDNDK_H

#if defined(__ANDROID__)
#include <jni.h>
#include <aaudio/AAudio.h>
#include <android/hardware_buffer.h>
#include <android/log.h>
#include <android/looper.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <sys/system_properties.h>

#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>
#endif

#endif
