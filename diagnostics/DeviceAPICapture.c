// Diagnostic-only pass-through of D3DMetal 4.0b2 device entry points.
// Native exports were inspected: these use the Windows x64 (ms_abi) ABI.
// Never linked into the normal app; scope is armed by the owned-image helper.
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef GAMEKIT_DEVICE_API_LOG_DIRECTORY
#error Supply a private diagnostic directory
#endif
#define MSABI __attribute__((ms_abi))
typedef int32_t (MSABI *Create12)(void *, uint32_t, const void *, void **);
typedef int32_t (MSABI *Create11)(void *, uint32_t, void *, uint32_t, const uint32_t *, uint32_t, uint32_t, void **, uint32_t *, void **);
typedef int32_t (MSABI *Create11Swap)(void *, uint32_t, void *, uint32_t, const uint32_t *, uint32_t, uint32_t, const void *, void **, void **, uint32_t *, void **);
static _Atomic(Create12) original12;
static _Atomic(Create11) original11;
static _Atomic(Create11Swap) original11Swap;
static atomic_bool target;
static atomic_uint records;

void GamekitArmDeviceAPICapture(int enabled) { atomic_store(&target, enabled != 0); }

static void record(const char *api, const char *phase, int32_t result, int device) {
    int saved = errno;
    if (!atomic_load(&target) || atomic_fetch_add(&records, 1) >= 32) return;
    int directory = open(GAMEKIT_DEVICE_API_LOG_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory >= 0) {
        char filename[64], line[256];
        snprintf(filename, sizeof(filename), "device-api-%d.jsonl", getpid());
        int file = openat(directory, filename, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        struct stat info;
        if (file >= 0) {
            if (!fstat(file, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
                info.st_nlink == 1 && (info.st_mode & 0777) == 0600 && info.st_size < 16384) {
                int size = snprintf(line, sizeof(line), "{\"api\":\"%s\",\"phase\":\"%s\",\"hresult\":\"%08x\",\"device\":%d}\n", api, phase, (uint32_t)result, device);
                if (size > 0 && (size_t)size < sizeof(line)) (void)write(file, line, (size_t)size);
            }
            close(file);
        }
        close(directory);
    }
    errno = saved;
}
static int32_t MSABI capture12(void *adapter, uint32_t level, const void *iid, void **device) {
    record("D3D12CreateDevice", "enter", 0, 0);
    int32_t result = atomic_load(&original12)(adapter, level, iid, device);
    record("D3D12CreateDevice", "return", result, result >= 0 && device && *device);
    return result;
}
static int32_t MSABI capture11(void *adapter, uint32_t type, void *software, uint32_t flags,
    const uint32_t *levels, uint32_t count, uint32_t sdk, void **device, uint32_t *level, void **context) {
    record("D3D11CreateDevice", "enter", 0, 0);
    int32_t result = atomic_load(&original11)(adapter, type, software, flags, levels, count, sdk, device, level, context);
    record("D3D11CreateDevice", "return", result, result >= 0 && device && *device);
    return result;
}
static int32_t MSABI capture11Swap(void *adapter, uint32_t type, void *software, uint32_t flags,
    const uint32_t *levels, uint32_t count, uint32_t sdk, const void *desc, void **swap,
    void **device, uint32_t *level, void **context) {
    record("D3D11CreateDeviceAndSwapChain", "enter", 0, 0);
    int32_t result = atomic_load(&original11Swap)(adapter, type, software, flags, levels, count, sdk, desc, swap, device, level, context);
    record("D3D11CreateDeviceAndSwapChain", "return", result, result >= 0 && device && *device);
    return result;
}
static void *captureDlsym(void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (!symbol || !atomic_load(&target)) return symbol;
    int saved = errno;
    Dl_info info;
    int matches = dladdr(symbol, &info) && info.dli_fname && strstr(info.dli_fname, "/D3DMetal.framework/Versions/A/D3DMetal");
    errno = saved;
    if (!matches) return symbol;
    if (!strcmp(name, "D3D12CreateDevice")) { atomic_store(&original12, (Create12)symbol); return (void *)capture12; }
    if (!strcmp(name, "D3D11CreateDevice")) { atomic_store(&original11, (Create11)symbol); return (void *)capture11; }
    if (!strcmp(name, "D3D11CreateDeviceAndSwapChain")) { atomic_store(&original11Swap, (Create11Swap)symbol); return (void *)capture11Swap; }
    return symbol;
}
__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; }
    interpose = { (const void *)captureDlsym, (const void *)dlsym };
