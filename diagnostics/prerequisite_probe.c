/* Prerequisite smoke test, not a graphics-rendering/Steam compatibility test. */
#include <stdio.h>
#include <windows.h>

int main(void)
{
    printf("pointer_bits=%u\n", (unsigned)(sizeof(void *) * 8));
    printf("process_id=%lu\n", (unsigned long)GetCurrentProcessId());
#ifdef _WIN64
    int failures = 0;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    printf("wine_unix_call_dispatcher=%s\n",
           ntdll && GetProcAddress(ntdll, "__wine_unix_call_dispatcher") ? "present" : "absent");
    const char *libraries[] = {"d3d11.dll", "d3d12.dll", "dxgi.dll", "winegstreamer.dll"};
    const char *symbols[] = {"D3D11CreateDevice", "D3D12CreateDevice", "CreateDXGIFactory1", "DllGetClassObject"};
    for (unsigned i = 0; i < sizeof(libraries) / sizeof(libraries[0]); ++i) {
        HMODULE module = LoadLibraryA(libraries[i]);
        if (!module) {
            fprintf(stderr, "FAIL LoadLibrary %s error=%lu\n", libraries[i],
                    (unsigned long)GetLastError());
            ++failures;
            continue;
        }
        char path[MAX_PATH];
        DWORD length = GetModuleFileNameA(module, path, MAX_PATH);
        if (!length || length >= MAX_PATH || !GetProcAddress(module, symbols[i])) {
            fprintf(stderr, "FAIL inspect %s error=%lu\n", libraries[i],
                    (unsigned long)GetLastError());
            FreeLibrary(module);
            ++failures;
            continue;
        }
        printf("loaded=%s export=%s\n", path, symbols[i]);
        /* Match statically imported graphics DLL lifetime. Keep successful
         * modules loaded until process exit; this is not a plugin-unload test. */
    }
    if (failures) {
        fprintf(stderr, "FAIL prerequisite probe: %d DLL check(s) failed\n", failures);
        return 1;
    }
#endif
    puts("PASS prerequisite probe (rendering not tested)");
    return 0;
}
