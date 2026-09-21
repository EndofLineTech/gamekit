// Read-only Win32 / DirectDraw / D3D8 display-mode probe for legacy games.
#include <windows.h>
#include <ddraw.h>
#include <d3d8.h>
#include <cstdio>

static unsigned ddModes, matchedModes, targetWidth, targetHeight;
static HRESULT WINAPI modeCallback(DDSURFACEDESC *mode, void *) {
    ++ddModes;
    if (mode->dwWidth == targetWidth && mode->dwHeight == targetHeight) {
        ++matchedModes;
        std::printf("DirectDraw %ux%u bpp=%lu\n", targetWidth, targetHeight, (unsigned long)mode->ddpfPixelFormat.dwRGBBitCount);
    }
    return DDENUMRET_OK;
}

int main(int argc, char **argv) {
    char extra;
    if (argc < 2 || argc > 3 || std::sscanf(argv[1], "%ux%u%c", &targetWidth, &targetHeight, &extra) != 2 ||
        !targetWidth || !targetHeight || targetWidth > 32768 || targetHeight > 32768) return 2;
    if (argc == 3 && !std::freopen(argv[2], "w", stdout)) return 2;
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
    unsigned modes = 0, matched = 0;
    for (DWORD i = 0; i < 4096 && EnumDisplaySettingsA(nullptr, i, &mode); ++i) {
        ++modes;
        if (mode.dmPelsWidth == targetWidth && mode.dmPelsHeight == targetHeight) {
            ++matched;
            std::printf("Win32 %ux%u bpp=%lu\n", targetWidth, targetHeight, (unsigned long)mode.dmBitsPerPel);
        }
    }
    std::printf("Win32 modes=%u matched=%u\n", modes, matched);
    IDirectDraw *dd{};
    HRESULT hr = DirectDrawCreate(nullptr, &dd, nullptr);
    std::printf("DirectDrawCreate=%08lx\n", (unsigned long)hr);
    if (SUCCEEDED(hr)) {
        DDSURFACEDESC current{}; current.dwSize = sizeof(current);
        hr = dd->GetDisplayMode(&current);
        std::printf("DirectDraw mode hr=%08lx size=%lux%lu bpp=%lu\n", (unsigned long)hr,
            (unsigned long)current.dwWidth, (unsigned long)current.dwHeight, (unsigned long)current.ddpfPixelFormat.dwRGBBitCount);
        hr = dd->EnumDisplayModes(0, nullptr, nullptr, modeCallback);
        std::printf("DirectDraw enum hr=%08lx modes=%u matched=%u\n", (unsigned long)hr, ddModes, matchedModes);
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
                if (SUCCEEDED(d3d->EnumAdapterModes(adapter, i, &available)) && available.Width == targetWidth && available.Height == targetHeight) {
                    ++found;
                    std::printf("D3D8 %ux%u format=%u\n", targetWidth, targetHeight, available.Format);
                }
            }
            std::printf("D3D8 adapter=%u matched=%u\n", adapter, found);
        }
        d3d->Release();
    }
    std::puts("END legacy display probe");
    return 0; // Observations, not a claim that the game passes its check.
}
