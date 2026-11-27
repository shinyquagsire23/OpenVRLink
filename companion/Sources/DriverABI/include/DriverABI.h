// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// C declarations used by `driver_openvrlink` to interoperate with OpenVR's
// C++ vtables (`openvr_driver.h`), Direct3D's `ID3DBlob`, and OS module/memory APIs.

#ifndef OVRL_DRIVER_ABI_H
#define OVRL_DRIVER_ABI_H

// The C runtime's plain file functions are used; Microsoft's headers mark them deprecated.
#define _CRT_SECURE_NO_WARNINGS 1

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: OpenVR (C++ interfaces, as tables of functions taking the object first)

typedef struct ovr_context ovr_context;
typedef struct ovr_log ovr_log;
typedef struct ovr_settings ovr_settings;

// IVRDriverContext
struct ovr_context_vtable {
    void *(*get_generic_interface)(ovr_context *self, const char *version, int32_t *error);
    uint64_t (*get_driver_handle)(ovr_context *self);
};
struct ovr_context { const struct ovr_context_vtable *vtable; };

// IVRDriverLog_001
struct ovr_log_vtable {
    void (*log)(ovr_log *self, const char *message);
};
struct ovr_log { const struct ovr_log_vtable *vtable; };

// IVRSettings_003
struct ovr_settings_vtable {
    const char *(*error_name)(ovr_settings *self, int32_t error);
    void (*set_bool)(ovr_settings *self, const char *section, const char *key, bool value, int32_t *error);
    void (*set_int32)(ovr_settings *self, const char *section, const char *key, int32_t value, int32_t *error);
    void (*set_float)(ovr_settings *self, const char *section, const char *key, float value, int32_t *error);
    void (*set_string)(ovr_settings *self, const char *section, const char *key, const char *value, int32_t *error);
    bool (*get_bool)(ovr_settings *self, const char *section, const char *key, int32_t *error);
    int32_t (*get_int32)(ovr_settings *self, const char *section, const char *key, int32_t *error);
    float (*get_float)(ovr_settings *self, const char *section, const char *key, int32_t *error);
    void (*get_string)(ovr_settings *self, const char *section, const char *key, char *value, uint32_t size, int32_t *error);
};
struct ovr_settings { const struct ovr_settings_vtable *vtable; };

// IServerTrackedDeviceProvider_004, which the driver implements
typedef struct ovr_provider ovr_provider;
struct ovr_provider_vtable {
    int32_t (*init)(ovr_provider *self, ovr_context *context);
    void (*cleanup)(ovr_provider *self);
    const char *const *(*interface_versions)(ovr_provider *self);
    void (*run_frame)(ovr_provider *self);
    bool (*should_block_standby)(ovr_provider *self);
    void (*enter_standby)(ovr_provider *self);
    void (*leave_standby)(ovr_provider *self);
};
struct ovr_provider { const struct ovr_provider_vtable *vtable; };

// MARK: Direct3D

// Minimal `ID3DBlob` vtable layout used to inspect stock shader blobs and return patched blobs.
typedef struct d3d_blob d3d_blob;
struct d3d_blob_vtable {
    int32_t (*query_interface)(d3d_blob *self, const void *interface_id, void **out);
    uint32_t (*add_ref)(d3d_blob *self);
    uint32_t (*release)(d3d_blob *self);
    void *(*pointer)(d3d_blob *self);
    size_t (*size)(d3d_blob *self);
};
// Custom `ID3DBlob` allocation holding a patched DXBC shader.
struct d3d_blob {
    const struct d3d_blob_vtable *vtable;
    uint32_t references;
    uint8_t *bytes;
    size_t size;
};

// MARK: Data link (link.c)

// Helpers for non-blocking TCP sockets, directory creation, and spawning subprocesses from vrserver's
// frame callback.

// Initiates a non-blocking TCP connection to a host-order IPv4 address and port. Returns a socket
// handle, or -1 on error.
intptr_t ovrl_link_connect(uint32_t address, uint16_t port);
// Checks whether a non-blocking connect has finished, returning 1 when connected, 0 while still in
// progress, or -1 on failure.
int ovrl_link_ready(intptr_t link);
// Sends up to `count` bytes without blocking. Returns bytes sent (0 if the socket would block), or -1 on error.
ptrdiff_t ovrl_link_send(intptr_t link, const void *bytes, size_t count);
// Receives up to `capacity` bytes without blocking. Returns bytes read (0 if none available), or -1 on EOF/error.
ptrdiff_t ovrl_link_receive(intptr_t link, void *bytes, size_t capacity);
void ovrl_link_close(intptr_t link);
// Creates `path` if it does not exist. Returns 0 if the directory exists afterward, or -1 on error.
int ovrl_make_folder(const char *path);
// Spawns `program` asynchronously with two arguments and no console window. Returns 0 on success, or -1 on error.
int ovrl_start_program(const char *program, const char *first, const char *second);

// MARK: Operating system

#if defined(_WIN32)

struct win_memory_information {
    void *base;
    void *allocation_base;
    uint32_t allocation_protect;
    uint16_t partition;
    size_t region_size;
    uint32_t state;
    uint32_t protect;
    uint32_t kind;
};

void *GetModuleHandleA(const char *name);
int GetModuleHandleExA(uint32_t flags, const char *name_or_address, void **module);
int VirtualProtect(void *address, size_t size, uint32_t protect, uint32_t *old);
void *VirtualAlloc(void *address, size_t size, uint32_t kind, uint32_t protect);
size_t VirtualQuery(const void *address, struct win_memory_information *information, size_t length);
int FlushInstructionCache(void *process, const void *address, size_t size);
void *GetCurrentProcess(void);
uint64_t GetTickCount64(void);
void AcquireSRWLockExclusive(void **lock);
void ReleaseSRWLockExclusive(void **lock);

#else

#include <pthread.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
// dl_iterate_phdr and the structures it reports. glibc only declares it with _GNU_SOURCE.
#include <elf.h>
struct ovrl_loaded_object {
    uintptr_t slide;
    const char *name;
    const Elf64_Phdr *headers;
    uint16_t count;
};
int dl_iterate_phdr(int (*visit)(struct ovrl_loaded_object *object, size_t size, void *context), void *context);
#endif

#endif

#endif
