// Read-only Win32 / DirectDraw / D3D8 display-mode probe for legacy games.
#include <windows.h>
#include <ddraw.h>
#include <d3d8.h>
#include <cstdio>

static unsigned ddModes, dd800;
static HRESULT WINAPI modeCallback(DDSURFACEDESC *mode, void *) {
    ++ddModes;
    if (mode->dwWidth == 800 && mode->dwHeight == 600) {
        ++dd800;
        std::printf("DirectDraw 800x600 bpp=%lu\n", (unsigned long)mode->ddpfPixelFormat.dwRGBBitCount);
    }
    return DDENUMRET_OK;
}

int main(int argc, char **argv) {
    if (argc == 2 && !std::freopen(argv[1], "w", stdout)) return 2;
    setvbuf(stdout, nullptr, _IONBF, 0);
    HDC dc = GetDC(nullptr);
    if (!dc) return 2;
    std::printf("GDI size=%dx%d bpp=%d planes=%d metrics=%dx%d\n",
        GetDeviceCaps(dc, HORZRES), GetDeviceCaps(dc, VERTRES), GetDeviceCaps(dc, BITSPIXEL),
        GetDeviceCaps(dc, PLANES), GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    ReleaseDC(nullptr, dc);
    DEVMODEA mode{}; mode.dmSize = sizeof(mode);
    if (EnumDisplaySettingsA(nullptr, ENUM_CURRENT_SETTINGS, &mode))
        std::printf("Current display=%lux%lu bpp=%lu\n", (unsigned long)mode.dmPelsWidth,
            (unsigned long)mode.dmPelsHeight, (unsigned long)mode.dmBitsPerPel);
    unsigned modes = 0, modes800 = 0;
    for (DWORD i = 0; i < 4096 && EnumDisplaySettingsA(nullptr, i, &mode); ++i) {
        ++modes;
        if (mode.dmPelsWidth == 800 && mode.dmPelsHeight == 600) {
            ++modes800;
            std::printf("Win32 800x600 bpp=%lu\n", (unsigned long)mode.dmBitsPerPel);
        }
    }
    std::printf("Win32 modes=%u modes800=%u\n", modes, modes800);
    IDirectDraw *dd{};
    HRESULT hr = DirectDrawCreate(nullptr, &dd, nullptr);
    std::printf("DirectDrawCreate=%08lx\n", (unsigned long)hr);
    if (SUCCEEDED(hr)) {
        DDSURFACEDESC current{}; current.dwSize = sizeof(current);
        hr = dd->GetDisplayMode(&current);
        std::printf("DirectDraw mode hr=%08lx size=%lux%lu bpp=%lu\n", (unsigned long)hr,
            (unsigned long)current.dwWidth, (unsigned long)current.dwHeight, (unsigned long)current.ddpfPixelFormat.dwRGBBitCount);
        hr = dd->EnumDisplayModes(0, nullptr, nullptr, modeCallback);
        std::printf("DirectDraw enum hr=%08lx modes=%u modes800=%u\n", (unsigned long)hr, ddModes, dd800);
        dd->Release();
    }
    IDirect3D8 *d3d = Direct3DCreate8(D3D_SDK_VERSION);
    std::printf("Direct3DCreate8=%s\n", d3d ? "ok" : "null");
    if (d3d) {
        std::printf("D3D8 adapters=%u\n", d3d->GetAdapterCount());
        for (UINT adapter = 0; adapter < d3d->GetAdapterCount(); ++adapter) {
            D3DDISPLAYMODE current{};
            hr = d3d->GetAdapterDisplayMode(adapter, &current);
            std::printf("D3D8 adapter=%u current_hr=%08lx size=%ux%u format=%u modes=%u\n",
                adapter, (unsigned long)hr, current.Width, current.Height, current.Format, d3d->GetAdapterModeCount(adapter));
            unsigned found = 0;
            for (UINT i = 0; i < d3d->GetAdapterModeCount(adapter) && i < 4096; ++i) {
                D3DDISPLAYMODE available{};
                if (SUCCEEDED(d3d->EnumAdapterModes(adapter, i, &available)) && available.Width == 800 && available.Height == 600) {
                    ++found;
                    std::printf("D3D8 800x600 format=%u\n", available.Format);
                }
            }
            std::printf("D3D8 adapter=%u modes800=%u\n", adapter, found);
        }
        d3d->Release();
    }
    std::puts("END legacy display probe");
    return 0; // Observations, not a claim that the game passes its check.
}
