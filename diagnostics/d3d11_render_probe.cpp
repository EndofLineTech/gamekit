// Bounded D3D11 device, shader draw, readback and presentation qualification.
// Build: x86_64-w64-mingw32-g++ -O2 -static diagnostics/d3d11_render_probe.cpp -ld3d11 -ldxgi -ld3dcompiler -o probe.exe
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void check(HRESULT result, const char *step) {
    if (FAILED(result)) { std::printf("FAIL %s hr=%08lx\n", step, (unsigned long)result); std::exit(2); }
}
static void calibration(ID3D11Device *device, ID3D11DeviceContext *context) {
    ID3D11Query *disjoint{}, *timestamp{}, *event{};
    D3D11_QUERY_DESC desc{D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
    check(device->CreateQuery(&desc, &disjoint), "disjoint query");
    desc.Query = D3D11_QUERY_TIMESTAMP; check(device->CreateQuery(&desc, &timestamp), "timestamp query");
    desc.Query = D3D11_QUERY_EVENT; check(device->CreateQuery(&desc, &event), "event query");
    for (int attempt = 0; attempt < 3; ++attempt) {
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
        std::printf("calibration attempt=%d event=%d disjoint_hr=%08lx timestamp_hr=%08lx frequency=%llu disjoint=%d timestamp=%llu\n",
            attempt, complete, (unsigned long)disjointHR, (unsigned long)timestampHR,
            (unsigned long long)timing.Frequency, timing.Disjoint, (unsigned long long)ticks);
    }
    disjoint->Release(); timestamp->Release(); event->Release();
}
int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
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
    calibration(device, context);
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
}
