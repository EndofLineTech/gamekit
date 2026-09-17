#include <windows.h>
#include <msctf.h>
#include <cstdio>

// MinGW's headers do not yet provide ctffunc.h. This is the published
// ITfFnReconversion IID, also present in Wine's include/ctffunc.idl.
static const IID reconversionIID =
    {0x4cea93c0, 0x0a58, 0x11d3, {0x8d, 0xf0, 0x00, 0x10, 0x5a, 0x27, 0x99, 0xb5}};
static const GUID systemFunctionProvider =
    {0x9a698bb0, 0x0f21, 0x11d3, {0x8d, 0xf1, 0x00, 0x10, 0x5a, 0x27, 0x99, 0xb5}};

// Observe the text-input interfaces needed by newer Helldivers builds without
// launching a game, replacing DLLs, or dereferencing failed COM results.
int main()
{
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return 1;
    ITfThreadMgr *manager = nullptr;
    hr = CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER,
                          IID_ITfThreadMgr, reinterpret_cast<void **>(&manager));
    std::printf("Create thread manager: 0x%08lx\n", static_cast<unsigned long>(hr));
    bool supported = false;
    if (SUCCEEDED(hr) && manager) {
        TfClientId client = 0;
        hr = manager->Activate(&client);
        std::printf("Activate: 0x%08lx\n", static_cast<unsigned long>(hr));
        if (SUCCEEDED(hr)) {
            ITfFunctionProvider *provider = nullptr;
            hr = manager->GetFunctionProvider(systemFunctionProvider, &provider);
            std::printf("GetFunctionProvider: 0x%08lx; nonnull=%d\n",
                        static_cast<unsigned long>(hr), provider != nullptr);
            if (SUCCEEDED(hr) && provider) {
                IUnknown *function = nullptr;
                hr = provider->GetFunction(GUID_NULL, reconversionIID, &function);
                std::printf("GetFunction(ITfFnReconversion): 0x%08lx; nonnull=%d\n",
                            static_cast<unsigned long>(hr), function != nullptr);
                supported = SUCCEEDED(hr) && function;
                if (function) function->Release();
            }
            if (provider) provider->Release();
            manager->Deactivate();
        }
        manager->Release();
    }
    CoUninitialize();
    std::printf("Text-input reconversion available=%d\n", supported);
    std::puts("Text-input observation complete");
    return 0;
}
