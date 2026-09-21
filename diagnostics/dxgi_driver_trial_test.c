/* Windows-side contract tests for the experimental substitution boundary. */
#include "../Sources/HelldiversDriverVersion/dxgi.c"
static HRESULT answer;
static LONGLONG bits;
static unsigned calls;
static HRESULT WINAPI fakeCheck(IDXGIAdapter *adapter, REFIID iid, LARGE_INTEGER *version)
{
    (void)adapter; (void)iid;
    ++calls;
    if (version) version->QuadPart = bits;
    SetLastError(ERROR_BUSY);
    return answer;
}
int main(void)
{
    LARGE_INTEGER version;
    originalCheck = fakeCheck;
    answer = S_OK; bits = GAMEKIT_DRIVER_MATCH;
    if (substituteVersion(NULL, &IID_IDXGIDevice, &version) != S_OK ||
        version.QuadPart != GAMEKIT_DRIVER_REPLACEMENT || GetLastError() != ERROR_BUSY) return 1;
    bits = GAMEKIT_DRIVER_MATCH ^ 1;
    if (substituteVersion(NULL, &IID_IDXGIDevice, &version) != S_OK || version.QuadPart != bits) return 2;
    answer = E_NOINTERFACE; bits = GAMEKIT_DRIVER_MATCH;
    if (substituteVersion(NULL, &IID_IDXGIDevice, &version) != E_NOINTERFACE || version.QuadPart != bits) return 3;
    answer = S_OK;
    if (substituteVersion(NULL, &IID_IDXGIDevice, NULL) != S_OK || GetLastError() != ERROR_BUSY) return 4;
    if (calls != 4) return 5;
    puts("Driver shim contract passed");
    return 0;
}
