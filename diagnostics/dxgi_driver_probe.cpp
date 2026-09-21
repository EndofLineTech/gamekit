#include <windows.h>
#include <dxgi1_6.h>
#include <d3d12.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cctype>
#include <cwchar>

int main(int argc, char **argv) {
    if (argc >= 3 && !std::strcmp(argv[1], "configure")) {
        for (int i = 1; i < argc; ++i) {
            wchar_t path[512] = L"Software\\Wine\\DllOverrides";
            if (i > 1) {
                if (!std::strlen(argv[i]) || std::strlen(argv[i]) > 200 || std::strpbrk(argv[i], "\\/[]\r\n\t\"")) return 12;
                wchar_t executable[256];
                if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i], -1, executable, 256)) return 12;
                swprintf(path, 512, L"Software\\Wine\\AppDefaults\\%ls\\DllOverrides", executable);
            }
            HKEY key;
            if (RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr)) return 10;
            const wchar_t *value = i > 1 ? L"native,builtin" : L"builtin";
            LONG result = RegSetValueExW(key, L"dxgi", 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(wchar_t)));
            RegCloseKey(key);
            if (result) return 11;
        }
        std::puts("Isolated per-app DXGI overrides configured");
        return 0;
    }
    if (argc < 2 || std::strlen(argv[1]) != 16) return 12;
    ULONGLONG expected;
    {
        for (const char *c = argv[1]; *c; ++c) if (!std::isxdigit((unsigned char)*c)) return 12;
        expected = std::strtoull(argv[1], nullptr, 16);
    }
    HMODULE dxgi = argc >= 3 ? LoadLibraryA(argv[2]) : LoadLibraryW(L"dxgi.dll");
    if (!dxgi) return 1;
    auto create = reinterpret_cast<HRESULT (WINAPI *)(REFIID, void **)>(GetProcAddress(dxgi, "CreateDXGIFactory1"));
    IDXGIFactory1 *factory = nullptr;
    if (!create || FAILED(create(IID_PPV_ARGS(&factory)))) return 2;
    IDXGIAdapter1 *adapter = nullptr;
    if (FAILED(factory->EnumAdapters1(0, &adapter))) return 3;
    LARGE_INTEGER version{};
    HRESULT result = adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice), &version);
    std::printf("DXGI hr=%08lx version=%016llx expected=%016llx\n", (unsigned long)result,
        (unsigned long long)version.QuadPart, (unsigned long long)expected);
    if (FAILED(result) || (ULONGLONG)version.QuadPart != expected) return 4;
    ID3D12Device *device = nullptr;
    HMODULE d3d12 = LoadLibraryW(L"d3d12.dll");
    auto createDevice = d3d12 ? reinterpret_cast<PFN_D3D12_CREATE_DEVICE>(GetProcAddress(d3d12, "D3D12CreateDevice")) : nullptr;
    if (!createDevice) return 6;
    result = createDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device));
    std::printf("D3D12CreateDevice hr=%08lx\n", (unsigned long)result);
    if (FAILED(result) || !device) return 5;
    device->Release(); adapter->Release(); factory->Release();
    return 0;
}
