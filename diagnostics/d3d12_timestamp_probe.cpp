// Independent bounded timestamp-query/readback check. No game or Steam launch.
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstdint>
#include <cstring>

template<class T> struct Com {
    T *value = nullptr;
    ~Com() { if (value) value->Release(); }
    T **out() { return &value; }
    T *operator->() { return value; }
};
struct Failure { const char *operation; HRESULT result; };
#define CHECK(expr) do { HRESULT result = (expr); if (FAILED(result)) throw Failure{#expr, result}; } while (0)

int main()
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    try {
        Com<IDXGIFactory4> factory;
        CHECK(CreateDXGIFactory1(IID_PPV_ARGS(factory.out())));
        Com<ID3D12Device> device;
        for (UINT index = 0; !device.value; ++index) {
            Com<IDXGIAdapter1> adapter;
            CHECK(factory->EnumAdapters1(index, adapter.out()));
            DXGI_ADAPTER_DESC1 desc = {};
            CHECK(adapter->GetDesc1(&desc));
            if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            CHECK(D3D12CreateDevice(adapter.value, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(device.out())));
        }
        Com<ID3D12CommandQueue> queue;
        D3D12_COMMAND_QUEUE_DESC queueDesc = {};
        queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        CHECK(device->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(queue.out())));
        UINT64 frequency = 0;
        HRESULT frequencyResult = queue->GetTimestampFrequency(&frequency);
        std::printf("frequency_hr=0x%08lx frequency=%llu\n", static_cast<unsigned long>(frequencyResult), static_cast<unsigned long long>(frequency));
        bool allValid = true;
        for (unsigned round = 0; round < 3; ++round) {
            Com<ID3D12CommandAllocator> allocator;
            Com<ID3D12GraphicsCommandList> list;
            Com<ID3D12QueryHeap> queries;
            Com<ID3D12Resource> upload, readback;
            Com<ID3D12Fence> fence;
            CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(allocator.out())));
            CHECK(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.value, nullptr, IID_PPV_ARGS(list.out())));
            D3D12_QUERY_HEAP_DESC queryDesc = {};
            queryDesc.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP; queryDesc.Count = 2;
            CHECK(device->CreateQueryHeap(&queryDesc, IID_PPV_ARGS(queries.out())));
            D3D12_RESOURCE_DESC buffer = {};
            buffer.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; buffer.Width = 32;
            buffer.Height = 1; buffer.DepthOrArraySize = 1; buffer.MipLevels = 1;
            buffer.SampleDesc.Count = 1; buffer.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
            D3D12_HEAP_PROPERTIES heap = {};
            heap.Type = D3D12_HEAP_TYPE_UPLOAD;
            CHECK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(upload.out())));
            heap.Type = D3D12_HEAP_TYPE_READBACK;
            CHECK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(readback.out())));
            constexpr UINT64 sentinel = 0xfedcba9876543210ULL;
            UINT64 initial[4] = {sentinel, sentinel, sentinel, sentinel};
            void *mapped = nullptr;
            D3D12_RANGE none = {0, 0};
            CHECK(upload->Map(0, &none, &mapped));
            std::memcpy(mapped, initial, sizeof(initial)); upload->Unmap(0, nullptr);
            list->CopyBufferRegion(readback.value, 0, upload.value, 0, 32);
            list->EndQuery(queries.value, D3D12_QUERY_TYPE_TIMESTAMP, 0);
            list->CopyBufferRegion(readback.value, 16, upload.value, 16, 16);
            list->EndQuery(queries.value, D3D12_QUERY_TYPE_TIMESTAMP, 1);
            list->ResolveQueryData(queries.value, D3D12_QUERY_TYPE_TIMESTAMP, 0, 2, readback.value, 0);
            CHECK(list->Close());
            CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(fence.out())));
            LARGE_INTEGER start, finish, qpcFrequency;
            QueryPerformanceFrequency(&qpcFrequency); QueryPerformanceCounter(&start);
            ID3D12CommandList *submitted[] = {list.value}; queue->ExecuteCommandLists(1, submitted);
            CHECK(queue->Signal(fence.value, 1));
            const ULONGLONG deadline = GetTickCount64() + 5000;
            while (fence->GetCompletedValue() < 1 && GetTickCount64() < deadline) Sleep(1);
            QueryPerformanceCounter(&finish);
            if (fence->GetCompletedValue() < 1) { std::puts("FAIL fence_timeout_5s"); return 1; }
            D3D12_RANGE range = {0, sizeof(initial)};
            CHECK(readback->Map(0, &range, &mapped));
            UINT64 values[4]; std::memcpy(values, mapped, sizeof(values)); readback->Unmap(0, &none);
            const bool copied = values[2] == sentinel && values[3] == sentinel;
            const bool valid = copied && SUCCEEDED(frequencyResult) && frequency > 0 &&
                values[0] != 0 && values[1] >= values[0] && values[0] != sentinel && values[1] != sentinel;
            allValid &= valid;
            std::printf("round=%u copy_valid=%u timestamps_valid=%u begin=0x%016llx end=0x%016llx fence_ms=%.3f\n",
                round, copied, valid, static_cast<unsigned long long>(values[0]), static_cast<unsigned long long>(values[1]),
                1000.0 * static_cast<double>(finish.QuadPart - start.QuadPart) / qpcFrequency.QuadPart);
            if (!copied) { std::puts("FAIL copy_readback"); return 1; }
        }
        std::puts(allValid ? "PASS timestamps written and ordered" : "OBSERVED timestamps unavailable despite completed copy/fence");
        return allValid ? 0 : 2;
    } catch (const Failure &failure) {
        std::printf("FAIL %s hr=0x%08lx\n", failure.operation, static_cast<unsigned long>(failure.result));
        return 1;
    }
}
