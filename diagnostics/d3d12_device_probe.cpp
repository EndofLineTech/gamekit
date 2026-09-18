// Device/queue creation and lifetime check; no rendering or Steam execution.
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <set>
#include <utility>
#include <vector>

int main()
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("process_id=%lu\n", static_cast<unsigned long>(GetCurrentProcessId()));
    DEVMODEW mode = {};
    mode.dmSize = sizeof(mode);
    if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &mode))
        std::printf("Windows current mode: %lux%lu @ %lu Hz\n", mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency);
    std::set<std::pair<DWORD, DWORD>> windowModes;
    for (DWORD index = 0; index < 1024; ++index) {
        mode = {}; mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsW(nullptr, index, &mode)) break;
        windowModes.emplace(mode.dmPelsWidth, mode.dmPelsHeight);
    }
    for (const auto &size : windowModes)
        std::printf("Windows mode: %lux%lu\n", size.first, size.second);
    IDXGIFactory4 *factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory4), reinterpret_cast<void **>(&factory));
    if (FAILED(hr)) {
        std::fprintf(stderr, "FAIL CreateDXGIFactory1=0x%08lx\n", static_cast<unsigned long>(hr));
        return 1;
    }
    IDXGIAdapter1 *adapter = nullptr;
    ID3D12Device *device = nullptr;
    for (UINT index = 0;; ++index) {
        hr = factory->EnumAdapters1(index, &adapter);
        if (FAILED(hr)) break;
        DXGI_ADAPTER_DESC1 desc = {};
        if (SUCCEEDED(adapter->GetDesc1(&desc)) && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
            LARGE_INTEGER driver = {};
            HRESULT versionResult = adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice), &driver);
            unsigned long long version = static_cast<unsigned long long>(driver.QuadPart);
            std::printf("DXGI driver query: hr=0x%08lx raw=0x%016llx version=%u.%u.%u.%u\n",
                static_cast<unsigned long>(versionResult), version,
                static_cast<unsigned>((version >> 48) & 0xffff), static_cast<unsigned>((version >> 32) & 0xffff),
                static_cast<unsigned>((version >> 16) & 0xffff), static_cast<unsigned>(version & 0xffff));
            hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device),
                                  reinterpret_cast<void **>(&device));
            if (SUCCEEDED(hr)) {
                std::printf("hardware_vendor=0x%04x device=0x%04x\n", desc.VendorId, desc.DeviceId);
                IDXGIOutput *output = nullptr;
                if (SUCCEEDED(adapter->EnumOutputs(0, &output))) {
                    UINT count = 0;
                    if (SUCCEEDED(output->GetDisplayModeList(DXGI_FORMAT_R8G8B8A8_UNORM, 0, &count, nullptr)) && count > 0 && count <= 1024) {
                        std::vector<DXGI_MODE_DESC> modes(count);
                        if (SUCCEEDED(output->GetDisplayModeList(DXGI_FORMAT_R8G8B8A8_UNORM, 0, &count, modes.data()))) {
                            std::set<std::pair<UINT, UINT>> sizes;
                            for (UINT i = 0; i < count; ++i) sizes.emplace(modes[i].Width, modes[i].Height);
                            for (const auto &size : sizes) std::printf("DXGI mode: %ux%u\n", size.first, size.second);
                        }
                    }
                    output->Release();
                }
                adapter->Release();
                adapter = nullptr;
                break;
            }
        }
        adapter->Release();
        adapter = nullptr;
    }
    factory->Release();
    if (!device) {
        std::fprintf(stderr, "FAIL no hardware D3D12 device; last HRESULT=0x%08lx\n",
                     static_cast<unsigned long>(hr));
        return 2;
    }
    D3D12_COMMAND_QUEUE_DESC desc = {};
    desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue *queue = nullptr;
    hr = device->CreateCommandQueue(&desc, __uuidof(ID3D12CommandQueue), reinterpret_cast<void **>(&queue));
    if (FAILED(hr)) {
        std::fprintf(stderr, "FAIL CreateCommandQueue=0x%08lx\n", static_cast<unsigned long>(hr));
        device->Release();
        return 3;
    }
    std::puts("hardware device and queue created; waiting 15 seconds for image/lifetime diagnostics");
    Sleep(15000);
    queue->Release();
    device->Release();
    std::puts("PASS device/queue probe (rendering not tested)");
    return 0;
}
