/* Game-scoped DXGI compatibility version, not a physical driver version.
 * Independently implemented after studying dappermint/winecx-gptk df88b180.
 * Targets and versions come from JSON: runtime parameters for current builds,
 * a generated parameter header for historical pinned-artifact reproduction.
 */
#define COBJMACROS
#include <windows.h>
#include <dxgi1_6.h>
#include <d3dcommon.h>
#include <stdio.h>
#include <wchar.h>
#ifdef GAMEKIT_PROFILE_DRIVER
#include "profile_parameters.h"
#elif !defined(GAMEKIT_LEGACY_PARAMETERS)
#error "Supply runtime profile mode or a JSON-generated legacy parameter header"
#endif

typedef HRESULT (WINAPI *CheckVersion)(IDXGIAdapter *, REFIID, LARGE_INTEGER *);
static INIT_ONCE moduleOnce = INIT_ONCE_STATIC_INIT;
static HMODULE originalModule;
static BOOL target;
static SRWLOCK adapterLock = SRWLOCK_INIT;
static CheckVersion originalCheck;
static void **patchedTable;
#ifdef GAMEKIT_DRIVER_DIAGNOSTICS
static LONG records;
#endif

static BOOL CALLBACK loadOriginal(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
    WCHAR path[MAX_PATH];
    DWORD length;
    (void)once; (void)parameter; (void)context;
    WCHAR original[32768];
    DWORD originalLength = GetEnvironmentVariableW(L"GAMEKIT_DXGI_ORIGINAL", original, 32768);
    /* The managed revision supplies the pinned runtime module's absolute DOS
     * path. No prefix placeholder, registry override or search-path fallback. */
    if (originalLength && originalLength < 32768 && original[0] == L'Z' && original[1] == L':')
        originalModule = LoadLibraryW(original);
    length = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (length && length < MAX_PATH) {
#ifdef GAMEKIT_PROFILE_DRIVER
        target = readProfileParameters(path);
#else
        const WCHAR *name = wcsrchr(path, L'\\');
        name = name ? name + 1 : path;
        target = !lstrcmpiW(name, GAMEKIT_DRIVER_TARGET);
#ifdef GAMEKIT_DRIVER_DIAGNOSTICS
        target = target || !lstrcmpiW(name, GAMEKIT_DRIVER_PROBE);
#endif
#endif
    }
    return TRUE;
}

static FARPROC entry(const char *name)
{
    InitOnceExecuteOnce(&moduleOnce, loadOriginal, NULL, NULL);
    return originalModule ? GetProcAddress(originalModule, name) : NULL;
}

static HRESULT WINAPI substituteVersion(IDXGIAdapter *adapter, REFIID iid, LARGE_INTEGER *version)
{
    HRESULT result = originalCheck(adapter, iid, version);
    DWORD error = GetLastError();
#ifdef GAMEKIT_PROFILE_DRIVER
    if (SUCCEEDED(result) && version && (ULONGLONG)version->QuadPart == profileMatch) {
        version->QuadPart = (LONGLONG)profileReplacement;
#else
    if (SUCCEEDED(result) && version && version->QuadPart == GAMEKIT_DRIVER_MATCH) {
        version->QuadPart = GAMEKIT_DRIVER_REPLACEMENT;
#endif
#ifdef GAMEKIT_DRIVER_DIAGNOSTICS
        if (InterlockedIncrement(&records) <= 16) {
            FILE *log = fopen("C:\\gamekit-driver-trial.log", "a");
            if (log) {
                fprintf(log, "pid=%lu substituted=%016llx\n", GetCurrentProcessId(), (unsigned long long)version->QuadPart);
                fclose(log);
            }
        }
#endif
    }
    SetLastError(error);
    return result;
}

static void instrumentFactory(IUnknown *object)
{
    IDXGIFactory1 *factory = NULL;
    IDXGIAdapter *adapter = NULL;
    if (!target || !object) return;
    if (FAILED(IUnknown_QueryInterface(object, &IID_IDXGIFactory1, (void **)&factory))) return;
    if (IDXGIFactory1_EnumAdapters(factory, 0, &adapter) == S_OK && adapter) {
        void **table = *(void ***)adapter;
        DWORD protection;
        AcquireSRWLockExclusive(&adapterLock);
        /* This bounded single-adapter trial deliberately refuses a second,
         * different table rather than calling the wrong original function. */
        if (!patchedTable && VirtualProtect(&table[9], sizeof(void *), PAGE_READWRITE, &protection)) {
            originalCheck = (CheckVersion)table[9];
            InterlockedExchangePointer(&table[9], (void *)substituteVersion);
            patchedTable = table;
            VirtualProtect(&table[9], sizeof(void *), protection, &protection);
        }
        ReleaseSRWLockExclusive(&adapterLock);
        IDXGIAdapter_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
}

HRESULT WINAPI TrialCreateDXGIFactory(REFIID iid, void **output)
{
    typedef HRESULT (WINAPI *Create)(REFIID, void **);
    Create create = (Create)entry("CreateDXGIFactory");
    HRESULT result = create ? create(iid, output) : E_NOINTERFACE;
    if (SUCCEEDED(result) && output) instrumentFactory((IUnknown *)*output);
    return result;
}
HRESULT WINAPI TrialCreateDXGIFactory1(REFIID iid, void **output)
{
    typedef HRESULT (WINAPI *Create)(REFIID, void **);
    Create create = (Create)entry("CreateDXGIFactory1");
    HRESULT result = create ? create(iid, output) : E_NOINTERFACE;
    if (SUCCEEDED(result) && output) instrumentFactory((IUnknown *)*output);
    return result;
}
HRESULT WINAPI TrialCreateDXGIFactory2(UINT flags, REFIID iid, void **output)
{
    typedef HRESULT (WINAPI *Create)(UINT, REFIID, void **);
    Create create = (Create)entry("CreateDXGIFactory2");
    HRESULT result = create ? create(flags, iid, output) : E_NOINTERFACE;
    if (SUCCEEDED(result) && output) instrumentFactory((IUnknown *)*output);
    return result;
}

/* Typed forwarding avoids a loader-time dependency on a prefix placeholder
 * for dxgm.dll. The pinned original is loaded by absolute path on first call. */
HRESULT WINAPI TrialDXGID3D10CreateDevice(HMODULE core, IDXGIFactory *factory, IDXGIAdapter *adapter,
    UINT flags, const D3D_FEATURE_LEVEL *levels, UINT count, void **device)
{
    typedef HRESULT (WINAPI *Function)(HMODULE, IDXGIFactory *, IDXGIAdapter *, UINT, const D3D_FEATURE_LEVEL *, UINT, void **);
    Function function = (Function)entry("DXGID3D10CreateDevice");
    return function ? function(core, factory, adapter, flags, levels, count, device) : E_NOINTERFACE;
}
HRESULT WINAPI TrialDXGID3D10RegisterLayers(const void *layers, UINT count)
{
    typedef HRESULT (WINAPI *Function)(const void *, UINT);
    Function function = (Function)entry("DXGID3D10RegisterLayers");
    return function ? function(layers, count) : E_NOINTERFACE;
}
HRESULT WINAPI TrialDXGIGetDebugInterface1(UINT flags, REFIID iid, void **output)
{
    typedef HRESULT (WINAPI *Function)(UINT, REFIID, void **);
    Function function = (Function)entry("DXGIGetDebugInterface1");
    return function ? function(flags, iid, output) : E_NOINTERFACE;
}
HRESULT WINAPI TrialDXGIDeclareAdapterRemovalSupport(void)
{
    typedef HRESULT (WINAPI *Function)(void);
    Function function = (Function)entry("DXGIDeclareAdapterRemovalSupport");
    return function ? function() : E_NOINTERFACE;
}
