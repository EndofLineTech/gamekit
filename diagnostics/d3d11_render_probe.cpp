// Bounded D3D11 device, shader draw, readback and presentation qualification.
// Build: x86_64-w64-mingw32-g++ -O2 -static diagnostics/d3d11_render_probe.cpp -ld3d11 -ldxgi -ld3dcompiler -o probe.exe
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// A separate workload probe: the startup calibration above does not exercise
// occlusion queries, pooled timestamps, or reuse across rendering submissions.
static int workloadQueries(ID3D11Device *device, ID3D11DeviceContext *context,
                           ID3D11RenderTargetView *view) {
    const D3D11_QUERY kinds[] = {D3D11_QUERY_OCCLUSION, D3D11_QUERY_TIMESTAMP};
    for (auto kind : kinds) {
        std::vector<ID3D11Query *> queries(1100, nullptr);
        D3D11_QUERY_DESC desc{kind, 0};
        for (auto &query : queries) {
            HRESULT hr = device->CreateQuery(&desc, &query);
            if (FAILED(hr)) { std::printf("FAIL workload CreateQuery type=%u hr=%08lx\n", kind, (unsigned long)hr); return 4; }
        }
        for (int round = 0; round < 3; ++round) {
            const ULONGLONG start = GetTickCount64();
            context->OMSetRenderTargets(1, &view, nullptr);
            for (size_t i = 0; i < queries.size(); ++i) {
                if (kind == D3D11_QUERY_OCCLUSION) context->Begin(queries[i]);
                context->Draw(3, 0);
                context->End(queries[i]);
                // Force queries across submission/render-pass boundaries too.
                if (round == 2 && i % 100 == 0) context->Flush();
            }
            if (round != 0) context->Flush();
            const ULONGLONG deadline = GetTickCount64() + 5000;
            size_t ready = 0, invalid = 0;
            UINT64 previous = 0;
            for (auto query : queries) {
                UINT64 value = 0;
                HRESULT hr;
                do {
                    hr = context->GetData(query, &value, sizeof(value), 0);
                } while (hr == S_FALSE && GetTickCount64() < deadline);
                if (hr != S_OK) break;
                ++ready;
                if (kind == D3D11_QUERY_OCCLUSION ? value != 4096 : (!value || value < previous)) ++invalid;
                previous = value;
            }
            std::printf("workload type=%u round=%d ready=%zu/%zu invalid=%zu elapsed_ms=%llu\n",
                kind, round, ready, queries.size(), invalid, (unsigned long long)(GetTickCount64() - start));
            if (ready != queries.size() || invalid) {
                for (auto query : queries) query->Release();
                return 4;
            }
        }
        for (auto query : queries) query->Release();
    }
    std::puts("PASS pooled rendering queries and reuse");
    return 0;
}

static void check(HRESULT result, const char *step) {
    if (FAILED(result)) { std::printf("FAIL %s hr=%08lx\n", step, (unsigned long)result); std::exit(2); }
}
static LONG CALLBACK reportProbeFault(EXCEPTION_POINTERS *exception) {
    if (exception->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) return EXCEPTION_CONTINUE_SEARCH;
    HMODULE module{}; char name[4096] = {};
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)exception->ExceptionRecord->ExceptionAddress, &module);
    if (module) GetModuleFileNameA(module, name, sizeof(name));
    std::printf("PROBE_FAULT module=%s rva=%llx address=%p\n", name,
        (unsigned long long)((uintptr_t)exception->ExceptionRecord->ExceptionAddress - (uintptr_t)module),
        exception->ExceptionRecord->ExceptionAddress);
    ExitProcess(6); // Only this standalone probe; avoid an unattended debugger.
    return EXCEPTION_CONTINUE_SEARCH;
}
static int calibration(ID3D11Device *device, ID3D11DeviceContext *context, int attempts) {
    ID3D11Query *disjoint{}, *timestamp{}, *event{};
    D3D11_QUERY_DESC desc{D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
    check(device->CreateQuery(&desc, &disjoint), "disjoint query");
    desc.Query = D3D11_QUERY_TIMESTAMP; check(device->CreateQuery(&desc, &timestamp), "timestamp query");
    desc.Query = D3D11_QUERY_EVENT; check(device->CreateQuery(&desc, &event), "event query");
    // An empty event must still complete; a CPU-readback gate must not wait on
    // an unsubmitted chunk or make the first event deadlock.
    context->End(event); context->Flush();
    BOOL emptyComplete = FALSE;
    const ULONGLONG emptyDeadline = GetTickCount64() + 5000;
    while (!emptyComplete && GetTickCount64() < emptyDeadline)
        check(context->GetData(event, &emptyComplete, sizeof(emptyComplete), D3D11_ASYNC_GETDATA_DONOTFLUSH), "empty event");
    if (!emptyComplete) { std::puts("FAIL empty event timed out"); return attempts; }
    int pending = 0;
    for (int attempt = 0; attempt < attempts; ++attempt) {
        context->Begin(disjoint); context->End(timestamp); context->End(disjoint); context->End(event); context->Flush();
        BOOL complete = FALSE;
        const ULONGLONG deadline = GetTickCount64() + 5000;
        while (!complete && GetTickCount64() < deadline) {
            check(context->GetData(event, &complete, sizeof(complete), 0), "event poll");
        }
        UINT64 ticks = 0;
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT timing{};
        HRESULT disjointHR = context->GetData(disjoint, &timing, sizeof(timing), 0);
        HRESULT timestampHR = context->GetData(timestamp, &ticks, sizeof(ticks), 0);
        if (!complete || disjointHR != S_OK || timestampHR != S_OK || !timing.Frequency || timing.Disjoint || !ticks) ++pending;
        std::printf("calibration attempt=%d event=%d disjoint_hr=%08lx timestamp_hr=%08lx frequency=%llu disjoint=%d timestamp=%llu\n",
            attempt, complete, (unsigned long)disjointHR, (unsigned long)timestampHR,
            (unsigned long long)timing.Frequency, timing.Disjoint, (unsigned long long)ticks);
    }
    disjoint->Release(); timestamp->Release(); event->Release();
    std::printf("calibration attempts=%d pending=%d\n", attempts, pending);
    return pending;
}
static int foreignSharedHandle(const char *text) {
    HANDLE foreign = (HANDLE)(uintptr_t)std::strtoull(text, nullptr, 10);
    ID3D11Device *device{}; ID3D11DeviceContext *context{};
    D3D_FEATURE_LEVEL requested = D3D_FEATURE_LEVEL_11_0;
    check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &requested, 1,
                           D3D11_SDK_VERSION, &device, nullptr, &context), "foreign device");
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = desc.Height = 16; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R16_FLOAT; desc.SampleDesc.Count = 1;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    ID3D11Texture2D *own{}, *invalid{}; IDXGIResource *resource{}; HANDLE handle{};
    check(device->CreateTexture2D(&desc, nullptr, &own), "foreign own texture");
    check(own->QueryInterface(__uuidof(IDXGIResource), (void **)&resource), "foreign own resource");
    check(resource->GetSharedHandle(&handle), "foreign own handle");
    resource->Release();
    HRESULT result = device->OpenSharedResource(foreign, __uuidof(ID3D11Texture2D), (void **)&invalid);
    bool valid = handle != foreign && FAILED(result) && !invalid;
    own->Release(); context->Release(); device->Release();
    return valid ? 0 : 5;
}
int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    AddVectoredExceptionHandler(1, reportProbeFault);
#ifdef GAMEKIT_SAVE_GUARD_PROBE_DIRECTORY
    char guardPath[4096];
    std::snprintf(guardPath, sizeof(guardPath), "%s/.gamekit-win32-guard-%lu-%llu.tmp",
        GAMEKIT_SAVE_GUARD_PROBE_DIRECTORY, (unsigned long)GetCurrentProcessId(), (unsigned long long)GetTickCount64());
    HANDLE guardFile = CreateFileA(guardPath, GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    DWORD guardError = GetLastError();
    if (guardFile != INVALID_HANDLE_VALUE) CloseHandle(guardFile);
    std::printf("Win32 save guard: creation_denied=%d error=%lu\n", guardFile == INVALID_HANDLE_VALUE, (unsigned long)guardError);
    if (guardFile != INVALID_HANDLE_VALUE || guardError != ERROR_ACCESS_DENIED) return 7;
#endif
    if (argc == 3 && std::strcmp(argv[1], "--foreign-shared") == 0) return foreignSharedHandle(argv[2]);
    HWND window = CreateWindowA("STATIC", "Gamekit D3D11 qualification", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                40, 40, 160, 160, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    if (!window) return 2;
    DXGI_SWAP_CHAIN_DESC swap{};
    swap.BufferDesc.Width = swap.BufferDesc.Height = 64;
    swap.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap.SampleDesc.Count = 1; swap.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap.BufferCount = 1; swap.OutputWindow = window; swap.Windowed = TRUE;
    ID3D11Device *device{}; ID3D11DeviceContext *context{}; IDXGISwapChain *chain{};
    D3D_FEATURE_LEVEL level{}, requested = D3D_FEATURE_LEVEL_11_0;
    check(D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &requested, 1,
        D3D11_SDK_VERSION, &swap, &chain, &device, &level, &context), "device/swapchain");
    std::printf("device feature_level=%x\n", level);
    const bool queryCompatibility = argc == 2 && std::strcmp(argv[1], "--query-compat") == 0;
    const bool sharedCompatibility = argc == 2 && std::strcmp(argv[1], "--shared-compat") == 0;
    int pending = calibration(device, context, queryCompatibility ? 100 : 3);
    // Exact descriptor from Satisfactory's next startup failure after query
    // calibration. Report separately from the ordinary render-control result.
    D3D11_TEXTURE2D_DESC sharedDesc{};
    sharedDesc.Width = sharedDesc.Height = 1024; sharedDesc.MipLevels = sharedDesc.ArraySize = 1;
    sharedDesc.Format = DXGI_FORMAT_R16_FLOAT; sharedDesc.SampleDesc.Count = 1;
    sharedDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    sharedDesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    ID3D11Texture2D *sharedTexture{};
    HRESULT sharedResult = device->CreateTexture2D(&sharedDesc, nullptr, &sharedTexture);
    std::printf("shared R16_FLOAT creation_hr=%08lx\n", (unsigned long)sharedResult);
    if (sharedCompatibility) {
        check(sharedResult, "shared texture creation");
        IDXGIResource *resource{}; HANDLE handle{};
        check(sharedTexture->QueryInterface(__uuidof(IDXGIResource), (void **)&resource), "shared resource interface");
        check(resource->GetSharedHandle(&handle), "shared handle"); resource->Release();
        char executable[4096], command[8300];
        DWORD length = GetModuleFileNameA(nullptr, executable, sizeof(executable));
        if (!length || length == sizeof(executable)) return 5;
        std::snprintf(command, sizeof(command), "\"%s\" --foreign-shared %llu", executable, (unsigned long long)(uintptr_t)handle);
        STARTUPINFOA startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION child{};
        if (!CreateProcessA(executable, command, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) return 5;
        DWORD childExit = 5;
        if (WaitForSingleObject(child.hProcess, 10000) == WAIT_OBJECT_0) GetExitCodeProcess(child.hProcess, &childExit);
        CloseHandle(child.hThread); CloseHandle(child.hProcess);
        std::printf("shared foreign_process_exit=%lu\n", (unsigned long)childExit);
        if (childExit) return 5;
        ID3D11Device *second{}; ID3D11DeviceContext *otherContext{};
        check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &requested, 1,
                               D3D11_SDK_VERSION, &second, nullptr, &otherContext), "second device");
        ID3D11Texture2D *alias{}, *staging{}; ID3D11RenderTargetView *sharedView{};
        check(second->OpenSharedResource(handle, __uuidof(ID3D11Texture2D), (void **)&alias), "same-process import");
        check(device->CreateRenderTargetView(sharedTexture, nullptr, &sharedView), "shared RTV");
        const float color[] = {0.5f, 0, 0, 1};
        context->ClearRenderTargetView(sharedView, color);
        D3D11_QUERY_DESC fenceDesc{D3D11_QUERY_EVENT, 0}; ID3D11Query *fence{};
        check(device->CreateQuery(&fenceDesc, &fence), "shared write fence");
        context->End(fence); context->Flush();
        BOOL complete = FALSE; ULONGLONG until = GetTickCount64() + 5000;
        while (!complete && GetTickCount64() < until) check(context->GetData(fence, &complete, sizeof(complete), 0), "shared fence wait");
        if (!complete) return 5;
        fence->Release(); sharedView->Release(); sharedTexture->Release(); sharedTexture = nullptr;
        D3D11_TEXTURE2D_DESC readDesc{}; alias->GetDesc(&readDesc);
        readDesc.Usage = D3D11_USAGE_STAGING; readDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        readDesc.BindFlags = 0; readDesc.MiscFlags = 0;
        check(second->CreateTexture2D(&readDesc, nullptr, &staging), "shared staging");
        otherContext->CopyResource(staging, alias);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        check(otherContext->Map(staging, 0, D3D11_MAP_READ, 0, &mapped), "shared readback");
        unsigned short value = *(unsigned short *)mapped.pData;
        otherContext->Unmap(staging, 0);
        std::printf("shared alias pixel=%04x expected=3800\n", value);
        if (value != 0x3800) return 5;
        otherContext->ClearState(); otherContext->Flush(); staging->Release(); alias->Release();
        ID3D11Texture2D *invalid{};
        HRESULT stale = second->OpenSharedResource(handle, __uuidof(ID3D11Texture2D), (void **)&invalid);
        std::printf("shared stale_hr=%08lx\n", (unsigned long)stale);
        if (SUCCEEDED(stale) || invalid) return 5;
        HRESULT bogus = second->OpenSharedResource((HANDLE)(uintptr_t)0x1233, __uuidof(ID3D11Texture2D), (void **)&invalid);
        std::printf("shared bogus_hr=%08lx\n", (unsigned long)bogus);
        if (SUCCEEDED(bogus) || invalid) return 5;
        sharedDesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
        HRESULT unsupported = device->CreateTexture2D(&sharedDesc, nullptr, &invalid);
        std::printf("shared unsupported_hr=%08lx\n", (unsigned long)unsupported);
        if (SUCCEEDED(unsupported) || invalid) return 5;
        otherContext->Release(); second->Release();
        std::puts("PASS legacy shared alias/lifetime/stale/bogus/unsupported handles");
    }
    if (sharedTexture) sharedTexture->Release();
    const char *shader = "float4 vs(uint id:SV_VertexID):SV_Position { return float4(id==1?3:-1,id==2?3:-1,0,1); }"
                         "float4 ps():SV_Target { return float4(0.25,0.5,0.75,1); }";
    ID3DBlob *vsCode{}, *psCode{}, *error{};
    check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr, "vs", "vs_5_0", 0, 0, &vsCode, &error), "compile VS");
    if (error) { error->Release(); error = nullptr; }
    check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr, "ps", "ps_5_0", 0, 0, &psCode, &error), "compile PS");
    if (error) error->Release();
    ID3D11VertexShader *vs{}; ID3D11PixelShader *ps{};
    check(device->CreateVertexShader(vsCode->GetBufferPointer(), vsCode->GetBufferSize(), nullptr, &vs), "vertex shader");
    check(device->CreatePixelShader(psCode->GetBufferPointer(), psCode->GetBufferSize(), nullptr, &ps), "pixel shader");
    ID3D11Texture2D *target{}, *readback{}; ID3D11RenderTargetView *view{};
    check(chain->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&target), "backbuffer");
    check(device->CreateRenderTargetView(target, nullptr, &view), "render target");
    D3D11_TEXTURE2D_DESC desc{}; target->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ; desc.MiscFlags = 0;
    check(device->CreateTexture2D(&desc, nullptr, &readback), "staging texture");
    D3D11_VIEWPORT viewport{0, 0, 64, 64, 0, 1};
    D3D11_RASTERIZER_DESC rasterDesc{};
    rasterDesc.FillMode = D3D11_FILL_SOLID; rasterDesc.CullMode = D3D11_CULL_NONE; rasterDesc.DepthClipEnable = TRUE;
    ID3D11RasterizerState *raster{};
    check(device->CreateRasterizerState(&rasterDesc, &raster), "rasterizer");
    context->RSSetState(raster);
    context->RSSetViewports(1, &viewport);
    context->VSSetShader(vs, nullptr, 0); context->PSSetShader(ps, nullptr, 0);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    if (argc == 2 && std::strcmp(argv[1], "--query-workload") == 0) {
        int result = workloadQueries(device, context, view);
        if (result) return result;
    }
    for (int frame = 0; frame < 3; ++frame) {
        const float black[] = {0, 0, 0, 1};
        context->OMSetRenderTargets(1, &view, nullptr); context->ClearRenderTargetView(view, black);
        context->Draw(3, 0); context->CopyResource(readback, target);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        check(context->Map(readback, 0, D3D11_MAP_READ, 0, &mapped), "readback");
        auto pixel = (const unsigned char *)mapped.pData + mapped.RowPitch * 32 + 32 * 4;
        bool valid = abs(pixel[0] - 64) <= 1 && abs(pixel[1] - 128) <= 1 && abs(pixel[2] - 191) <= 1 && pixel[3] == 255;
        std::printf("frame=%d pixel=%u,%u,%u,%u valid=%d\n", frame, pixel[0], pixel[1], pixel[2], pixel[3], valid);
        context->Unmap(readback, 0);
        if (!valid) return 3;
        check(chain->Present(1, 0), "present");
    }
    context->ClearState(); context->Flush();
    view->Release(); target->Release(); readback->Release(); vs->Release(); ps->Release();
    raster->Release(); vsCode->Release(); psCode->Release(); chain->Release(); context->Release(); device->Release();
    DestroyWindow(window);
    std::puts("PASS D3D11 shader draw/readback/present");
    return queryCompatibility && pending ? 4 : 0;
}
