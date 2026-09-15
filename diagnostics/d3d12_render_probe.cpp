// Hardware clear/present test with fenced GPU readback; no game assets/shaders.
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <stdexcept>

using Microsoft::WRL::ComPtr;

static void check(HRESULT result, const char *operation)
{
    if (FAILED(result)) {
        std::fprintf(stderr, "FAIL %s HRESULT=0x%08lx\n", operation,
                     static_cast<unsigned long>(result));
        throw std::runtime_error(operation);
    }
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

static void transition(ID3D12GraphicsCommandList *list, ID3D12Resource *resource,
                       D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    list->ResourceBarrier(1, &barrier);
}

static void run(HWND window)
{
    ComPtr<IDXGIFactory4> factory;
    check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
    ComPtr<ID3D12Device> device;
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        HRESULT hr = factory->EnumAdapters1(index, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        check(hr, "EnumAdapters1");
        DXGI_ADAPTER_DESC1 info = {};
        check(adapter->GetDesc1(&info), "GetDesc1");
        if (info.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        hr = D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device));
        if (SUCCEEDED(hr)) {
            char name[256] = {};
            WideCharToMultiByte(CP_UTF8, 0, info.Description, -1, name, sizeof(name), nullptr, nullptr);
            std::printf("hardware_adapter=%s vendor=0x%04x device=0x%04x\n",
                        name, info.VendorId, info.DeviceId);
            break;
        }
    }
    if (!device) throw std::runtime_error("No hardware D3D12 device; WARP is not accepted");
    D3D12_COMMAND_QUEUE_DESC queue_desc = {};
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ComPtr<ID3D12CommandQueue> queue;
    check(device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&queue)), "CreateCommandQueue");
    DXGI_SWAP_CHAIN_DESC1 swap_desc = {};
    swap_desc.Width = 640;
    swap_desc.Height = 360;
    swap_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = 2;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> initial_swap;
    check(factory->CreateSwapChainForHwnd(queue.Get(), window, &swap_desc, nullptr, nullptr,
                                        &initial_swap), "CreateSwapChainForHwnd");
    ComPtr<IDXGISwapChain3> swap;
    check(initial_swap.As(&swap), "Query IDXGISwapChain3");
    check(factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER), "MakeWindowAssociation");
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {};
    heap_desc.NumDescriptors = 2;
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    ComPtr<ID3D12DescriptorHeap> heap;
    check(device->CreateDescriptorHeap(&heap_desc, IID_PPV_ARGS(&heap)), "CreateDescriptorHeap");
    const UINT descriptor_size = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    ComPtr<ID3D12Resource> buffers[2];
    D3D12_CPU_DESCRIPTOR_HANDLE views[2];
    for (UINT i = 0; i < 2; ++i) {
        check(swap->GetBuffer(i, IID_PPV_ARGS(&buffers[i])), "GetBuffer");
        views[i] = heap->GetCPUDescriptorHandleForHeapStart();
        views[i].ptr += i * descriptor_size;
        device->CreateRenderTargetView(buffers[i].Get(), nullptr, views[i]);
    }
    ComPtr<ID3D12CommandAllocator> allocator;
    check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)),
          "CreateCommandAllocator");
    ComPtr<ID3D12GraphicsCommandList> list;
    check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr,
                                   IID_PPV_ARGS(&list)), "CreateCommandList");
    check(list->Close(), "Initial Close");
    ComPtr<ID3D12Fence> fence;
    check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "CreateFence");
    const auto close_handle = [](void *handle) { if (handle) CloseHandle(handle); };
    std::unique_ptr<void, decltype(close_handle)> event(CreateEventW(nullptr, FALSE, FALSE, nullptr), close_handle);
    if (!event) throw std::runtime_error("CreateEventW failed");
    D3D12_RESOURCE_DESC texture_desc = buffers[0]->GetDesc();
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = {};
    UINT64 total_bytes = 0;
    device->GetCopyableFootprints(&texture_desc, 0, 1, 0, &footprint, nullptr, nullptr, &total_bytes);
    D3D12_HEAP_PROPERTIES read_heap = {};
    read_heap.Type = D3D12_HEAP_TYPE_READBACK;
    read_heap.CreationNodeMask = read_heap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC read_desc = {};
    read_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    read_desc.Width = total_bytes;
    read_desc.Height = read_desc.DepthOrArraySize = read_desc.MipLevels = 1;
    read_desc.SampleDesc.Count = 1;
    read_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> readback;
    check(device->CreateCommittedResource(&read_heap, D3D12_HEAP_FLAG_NONE, &read_desc,
                                         D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                         IID_PPV_ARGS(&readback)), "Create readback resource");
    const float color[] = {0.125f, 0.25f, 0.75f, 1.0f};
    const ULONGLONG start = GetTickCount64();
    UINT64 frames = 0;
    do {
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) throw std::runtime_error("Probe closed before completion");
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        const UINT index = swap->GetCurrentBackBufferIndex();
        check(allocator->Reset(), "Allocator Reset");
        check(list->Reset(allocator.Get(), nullptr), "Command list Reset");
        transition(list.Get(), buffers[index].Get(), D3D12_RESOURCE_STATE_PRESENT,
                   D3D12_RESOURCE_STATE_RENDER_TARGET);
        list->ClearRenderTargetView(views[index], color, 0, nullptr);
        transition(list.Get(), buffers[index].Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION destination = {};
        destination.pResource = readback.Get();
        destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        destination.PlacedFootprint = footprint;
        D3D12_TEXTURE_COPY_LOCATION source = {};
        source.pResource = buffers[index].Get();
        source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        list->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
        transition(list.Get(), buffers[index].Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                   D3D12_RESOURCE_STATE_PRESENT);
        check(list->Close(), "Close");
        ID3D12CommandList *commands[] = {list.Get()};
        queue->ExecuteCommandLists(1, commands);
        check(queue->Signal(fence.Get(), frames + 1), "Signal");
        if (fence->GetCompletedValue() < frames + 1) {
            check(fence->SetEventOnCompletion(frames + 1, event.get()), "SetEventOnCompletion");
            if (WaitForSingleObject(event.get(), 10000) != WAIT_OBJECT_0)
                throw std::runtime_error("GPU fence did not complete in 10 seconds");
        }
        check(device->GetDeviceRemovedReason(), "Device health");
        HRESULT hr = swap->Present(1, 0);
        check(hr, "Present");
        if (hr != S_OK) throw std::runtime_error("Present was not visible (occluded/status result)");
        ++frames;
    } while (frames < 120 || GetTickCount64() - start < 15000);
    D3D12_RANGE read_range = {0, static_cast<SIZE_T>(total_bytes)};
    void *mapped = nullptr;
    check(readback->Map(0, &read_range, &mapped), "Map readback");
    const unsigned char expected[] = {32, 64, 191, 255};
    bool correct = true;
    for (UINT y : {0u, 180u, 359u}) {
        for (UINT x : {0u, 320u, 639u}) {
            const auto *pixel = static_cast<unsigned char *>(mapped) + footprint.Offset +
                                y * footprint.Footprint.RowPitch + x * 4;
            for (UINT channel = 0; channel < 4; ++channel)
                correct = correct && std::abs(static_cast<int>(pixel[channel]) - expected[channel]) <= 1;
        }
    }
    const D3D12_RANGE written = {0, 0};
    readback->Unmap(0, &written);
    if (!correct) throw std::runtime_error("GPU readback color mismatch");
    std::printf("frames=%llu elapsed_ms=%llu readback_samples=9 expected_rgba=32,64,191,255\n",
                static_cast<unsigned long long>(frames),
                static_cast<unsigned long long>(GetTickCount64() - start));
    std::puts("PASS D3D12 clear/present/readback probe");
}

int main()
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("process_id=%lu\n", static_cast<unsigned long>(GetCurrentProcessId()));
    WNDCLASSW type = {};
    type.lpfnWndProc = window_proc;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"GamekitD3D12Probe";
    type.hCursor = LoadCursorW(nullptr, reinterpret_cast<LPCWSTR>(IDC_ARROW));
    if (!RegisterClassW(&type)) return 1;
    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
    RECT rectangle = {0, 0, 640, 360};
    AdjustWindowRect(&rectangle, style, FALSE);
    HWND window = CreateWindowW(type.lpszClassName, L"Gamekit D3D12 test - blue for 15 seconds",
                                style, CW_USEDEFAULT, CW_USEDEFAULT,
                                rectangle.right - rectangle.left, rectangle.bottom - rectangle.top,
                                nullptr, nullptr, type.hInstance, nullptr);
    if (!window) return 1;
    ShowWindow(window, SW_SHOW);
    int result = 0;
    try { run(window); }
    catch (const std::exception &error) { std::fprintf(stderr, "FAIL %s\n", error.what()); result = 1; }
    DestroyWindow(window);
    return result;
}
