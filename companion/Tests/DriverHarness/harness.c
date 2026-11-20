// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// End-to-end test runner for `driver_openvrlink.dll`. First simulates Steam's
// watchdog loading and immediately unloading the driver, then loads the mock
// `driver_vrlink.dll` alongside `driver_openvrlink.dll`, drives the OpenVRLink
// handshake through the hooked functions, and verifies hook behavior and cleanup.

#include <stdio.h>
#include <string.h>
#include <windows.h>

#pragma pack(push, 1)
typedef struct { char key[20]; double value; int time; } Record;
#pragma pack(pop)

static char status_text[256];
static int gamma_available = -1, logged = 0;

typedef struct { void **vtable; } Object;

static const char *error_name(Object *self, int error) { return ""; }
static void set_bool(Object *self, const char *section, const char *key, char value, int *error) {
    if (!strcmp(key, "gammaAvailable")) gamma_available = value;
    *error = 0;
}
static void set_int32(Object *self, const char *section, const char *key, int value, int *error) { *error = 0; }
static void set_float(Object *self, const char *section, const char *key, float value, int *error) { *error = 0; }
static void set_string(Object *self, const char *section, const char *key, const char *value, int *error) {
    if (!strcmp(key, "status")) strncpy(status_text, value, sizeof status_text - 1);
    *error = 0;
}
static char get_bool(Object *self, const char *section, const char *key, int *error) { *error = 0; return 1; }
static int get_int32(Object *self, const char *section, const char *key, int *error) { *error = 0; return 0; }
static float get_float(Object *self, const char *section, const char *key, int *error) { *error = 0; return 1.8f; }
static void *settings_vtable[] = { error_name, set_bool, set_int32, set_float, set_string, get_bool, get_int32, get_float };
static Object settings = { settings_vtable };

static int shader_reads_logged = 0;
static void log_line(Object *self, const char *text) {
    logged++;
    if (strstr(text, "read shader")) shader_reads_logged++;
    printf("  log: %s", text);
}
static void *log_vtable[] = { log_line };
static Object driver_log = { log_vtable };

static void *generic_interface(Object *self, const char *name, int *error) {
    *error = 0;
    if (!strcmp(name, "IVRSettings_003")) return &settings;
    if (!strcmp(name, "IVRDriverLog_001")) return &driver_log;
    *error = 105;
    return 0;
}
static unsigned long long driver_handle(Object *self) { return 1; }
static void *context_vtable[] = { generic_interface, driver_handle };
static Object context = { context_vtable };

static int failures = 0;
static void expect(int condition, const char *what) {
    printf("%s %s\n", condition ? "ok  " : "FAIL", what);
    fflush(stdout);
    if (!condition) failures++;
}

// vrserver calls RunFrame on every driver each server frame; the driver does its periodic work there.
static void (*run_frame)(Object *);
static void frames(Object *provider, int milliseconds) {
    for (int elapsed = 0; elapsed < milliseconds; elapsed += 25) {
        run_frame(provider);
        Sleep(25);
    }
}


static void fill(Record *records, int count) {
    for (int i = 0; i < count; i++) {
        memset(&records[i], 0, sizeof(Record));
        strcpy(records[i].key, "dCurBW");
        records[i].value = 100;
        records[i].time = 7;
    }
}

int main(void) {
    // Steam's watchdog, inside steam.exe: load, ask for an interface the driver lacks, unload.
    HMODULE watched = LoadLibraryA("driver_openvrlink.dll");
    if (watched) {
        int refused = 0;
        void *(*watchdog)(const char *, int *) = (void *)GetProcAddress(watched, "HmdDriverFactory");
        expect(watchdog("IVRWatchdogProvider_001", &refused) == 0 && refused == 105, "the watchdog is refused");
        FreeLibrary(watched);
        Sleep(300);
        expect(1, "the process survives the watchdog unloading the driver");
    }
    HMODULE vrlink = LoadLibraryA("driver_vrlink.dll");
    HMODULE ours = LoadLibraryA("driver_openvrlink.dll");
    if (!vrlink || !ours) { printf("FAIL could not load the libraries\n"); return 1; }
    int (*call_parse)(void *, const void *, int) = (void *)GetProcAddress(vrlink, "call_parse");
    int (*call_populate)(void *, void *, int) = (void *)GetProcAddress(vrlink, "call_populate");
    void *(*factory)(const char *, int *) = (void *)GetProcAddress(ours, "HmdDriverFactory");
    long (*call_read_shader)(const unsigned short *, unsigned char *) = (void *)GetProcAddress(vrlink, "call_read_shader");
    float (*call_constants)(float *) = (void *)GetProcAddress(vrlink, "call_constants");
    float constants[28] = {0};
    unsigned char magic[4] = {0};
    // Load real `.fxo` shaders when `VRLINK_FXO` is provided to `run.cmd` (one patched copy-view shader and one unpatched YUV shader).
    long copy_size = call_read_shader(L"shaders\\genforencode_ps_copy_view.fxo", magic);
    long other_size = call_read_shader(L"shaders\\encode_rgb_to_yuv_ps_y.fxo", magic);
    int have_shaders = copy_size > 0 && other_size > 0;
    if (!have_shaders) printf("  (no real shaders beside the test; shader patching is not exercised)\n");
    int code = 0;
    expect(factory("IVRWatchdogProvider_001", &code) == 0 && code == 105, "an interface the driver does not have is refused");
    Object *provider = factory("IServerTrackedDeviceProvider_004", &code);
    expect(provider != 0, "the provider interface is returned");
    int (*init)(Object *, Object *) = provider->vtable[0];
    void (*cleanup)(Object *) = provider->vtable[1];
    const char *const *(*versions)(Object *) = provider->vtable[2];
    expect(!strcmp(versions(provider)[1], "IServerTrackedDeviceProvider_004") && versions(provider)[2] == 0, "interface versions are listed");
    run_frame = provider->vtable[3];
    expect(init(provider, &context) == 0, "the driver starts");
    frames(provider, 1500);
    expect(logged > 0, "the driver logs through vrserver");
    expect(strstr(status_text, "handshake active; gamma starts when a headset connects") != 0, "status says gamma waits for the encode shaders");
    printf("  status: %s\n", status_text);
    expect(gamma_available == 0, "gamma is unavailable before any encode shader is read");
    expect(call_read_shader(L"shaders\\missing.fxo", magic) < 0 && shader_reads_logged == 1, "a failed shader read is passed back as it is");
    expect(call_constants(constants) == 1536.0f && constants[10] == 1.0f, "the Direct3D constants are filled by the original, then given gamma 1");
    if (have_shaders) {
        expect(call_read_shader(L"shaders\\encode_rgb_to_yuv_ps_y.fxo", magic) == other_size, "a shader with no sRGB conversion is read unchanged");
        expect(call_read_shader(L"shaders\\genforencode_ps_copy_view.fxo", magic) == copy_size + 196 && !memcmp(magic, "DXBC", 4), "the copy-view shader is handed over with gamma added");
        frames(provider, 700);
        expect(gamma_available == 1 && strstr(status_text, "encoding gamma active") != 0, "gamma is then reported available");
    }

    // A client that never speaks the extension gets untouched records.
    Record records[4], stock[1];
    memset(stock, 0, sizeof stock);
    strcpy(stock[0].key, "cPingMS");
    int touched = 0;
    for (int i = 0; i < 20; i++) {
        call_parse(0, stock, 1);
        fill(records, 4);
        call_populate(0, records, 4);
        touched += strcmp(records[0].key, "dCurBW") != 0;
    }
    expect(touched == 0, "nothing is sent to a client that is not OpenVRLink");
    expect(call_parse(0, stock, 0) > 0, "the original record functions still run");

    // An OpenVRLink client: its heartbeat keeps changing.
    Record client[2];
    int seen_host = 0, seen_available = 0, seen_active = 0, seen_gamma = 0, others_kept = 1;
    double available = -1, active = -1, gamma = -1;
    for (int i = 0; i < 30; i++) {
        memset(client, 0, sizeof client);
        strcpy(client[0].key, "oxClient");
        client[0].value = 65536.0 + (double)(i & 0xFFFF);
        strcpy(client[1].key, "oxWant");
        client[1].value = 1;
        call_parse(0, client, 2);
        fill(records, 4);
        call_populate(0, records, 4);
        if (!strcmp(records[0].key, "oxHost")) seen_host = records[0].value >= 65536.0;
        if (!strcmp(records[0].key, "oxAvail")) { seen_available = 1; available = records[0].value; }
        if (!strcmp(records[0].key, "oxOn")) { seen_active = 1; active = records[0].value; }
        if (!strcmp(records[0].key, "oxGamma")) { seen_gamma = 1; gamma = records[0].value; }
        for (int j = 1; j < 4; j++) others_kept &= !strcmp(records[j].key, "dCurBW") && records[j].time == 7;
        frames(provider, 50);
    }
    expect(seen_host && seen_available && seen_active && seen_gamma, "an OpenVRLink client receives all four host keys");
    if (have_shaders) {
        expect(available == 1 && active == 1 && gamma > 1.79 && gamma < 1.81, "the keys say gamma 1.8 is active");
        expect(call_constants(constants) == 1536.0f && constants[10] > 1.79f && constants[10] < 1.81f, "the constants carry gamma 1.8 while the client is live");
    } else {
        expect(available == 0 && active == 0 && gamma == 1, "the keys say no feature is available or active");
    }
    expect(others_kept, "the driver's other records are left alone");

    cleanup(provider);
    touched = 0;
    for (int i = 0; i < 10; i++) {
        client[0].value += 1;
        call_parse(0, client, 2);
        fill(records, 4);
        call_populate(0, records, 4);
        touched += strcmp(records[0].key, "dCurBW") != 0;
    }
    expect(touched == 0, "after cleanup the call sites are back as they were");
    int logged_before = shader_reads_logged;
    expect((!have_shaders || call_read_shader(L"shaders\\genforencode_ps_copy_view.fxo", magic) == copy_size) && shader_reads_logged == logged_before, "after cleanup shader reads go straight to the original");
    memset(constants, 0, sizeof constants);
    expect(call_constants(constants) == 1536.0f && constants[10] == 0.0f, "after cleanup the constants are the original's alone");
    expect(strstr(status_text, "not loaded") != 0 && gamma_available == 0, "cleanup resets the published status");
    printf(failures ? "FAILED (%d)\n" : "PASSED\n", failures);
    return failures != 0;
}
