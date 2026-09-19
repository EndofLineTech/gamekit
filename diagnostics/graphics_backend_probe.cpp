#include <windows.h>
#include <d3d12.h>
#include <cstdio>
#include <cstring>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char value[128] = {0};
    DWORD size = GetEnvironmentVariableA("D3DM_MTL4", value, sizeof(value));
    if (size >= sizeof(value)) return 3;
    const char *actual = size ? value : "unset";
    std::printf("windows_backend=%s expected=%s\n", actual, argv[1]);
    if (std::strcmp(actual, argv[1])) return 4;
    HMODULE module = LoadLibraryW(L"d3d12.dll");
    auto create = module ? reinterpret_cast<PFN_D3D12_CREATE_DEVICE>(GetProcAddress(module, "D3D12CreateDevice")) : nullptr;
    if (!create) return 5;
    ID3D12Device *device = nullptr;
    HRESULT result = create(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device));
    std::printf("D3D12CreateDevice=%08lx\n", (unsigned long)result);
    if (FAILED(result) || !device) return 6;
    device->Release();
    return 0;
}
