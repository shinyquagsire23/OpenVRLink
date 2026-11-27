// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// SwiftPM requires at least one C source file in each C target.
#include "COpenXR.h"

#if defined(__ANDROID__)
#include <android/native_window_jni.h>
#include <string.h>

void *ovrl_xr_window(void *java_vm, jobject surface) {
    JavaVM *vm = java_vm;
    JNIEnv *env = NULL;
    int attached = 0;
    if (!vm || !surface) return NULL;
    jint found = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (found == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
        attached = 1;
    } else if (found != JNI_OK || !env) {
        return NULL;
    }
    ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
    // Galaxy XR returns a JNI local reference that the caller must delete, while Play For Dream returns
    // a global reference owned by the runtime and aborts if DeleteLocalRef is called on it.
    if ((*env)->GetObjectRefType(env, surface) == JNILocalRefType) (*env)->DeleteLocalRef(env, surface);
    if (attached) (*vm)->DetachCurrentThread(vm);
    return window;
}

int ovrl_xr_fill_window(void *window, int32_t width, int32_t height) {
    int result = ANativeWindow_setBuffersGeometry(window, width, height, WINDOW_FORMAT_RGBA_8888);
    if (result != 0) return result;
    ANativeWindow_Buffer buffer;
    memset(&buffer, 0, sizeof buffer);
    result = ANativeWindow_lock(window, &buffer, NULL);
    if (result != 0) return result;
    int usable = buffer.bits && buffer.stride >= width && buffer.height >= height;
    // buffer.stride is measured in 4-byte RGBA pixels.
    for (int32_t y = 0; usable && y < height; y++) memset((uint8_t *)buffer.bits + (size_t)y * (size_t)buffer.stride * 4, 0, (size_t)width * 4);
    result = ANativeWindow_unlockAndPost(window);
    return usable ? result : -1;
}

void ovrl_xr_release_window(void *window) { ANativeWindow_release(window); }
#endif
