// Device/queue creation and lifetime check; no rendering or Steam execution.
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>

int main()
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("process_id=%lu\n", static_cast<unsigned long>(GetCurrentProcessId()));
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
            hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device),
                                  reinterpret_cast<void **>(&device));
            if (SUCCEEDED(hr)) {
                std::printf("hardware_vendor=0x%04x device=0x%04x\n", desc.VendorId, desc.DeviceId);
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
