// Read-only controller visibility and bounded XInput event observation.
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <xinput.h>
#include <cstdio>

static unsigned devices;
static BOOL CALLBACK device(const DIDEVICEINSTANCEW *info, void *) {
    ++devices;
    char name[512]{};
    WideCharToMultiByte(CP_UTF8, 0, info->tszProductName, -1, name, sizeof(name), nullptr, nullptr);
    std::printf("DirectInput controller: %s\n", name);
    return DIENUM_CONTINUE;
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    IDirectInput8W *input{};
    HRESULT hr = DirectInput8Create(GetModuleHandleW(nullptr), DIRECTINPUT_VERSION, IID_IDirectInput8W, (void **)&input, nullptr);
    if (SUCCEEDED(hr)) {
        input->EnumDevices(DI8DEVCLASS_GAMECTRL, device, nullptr, DIEDFL_ATTACHEDONLY);
        input->Release();
    }
    std::printf("DirectInput result=%08lx attached=%u\n", (unsigned long)hr, devices);
    HMODULE module = LoadLibraryW(L"xinput1_3.dll");
    if (!module) { std::puts("XInput DLL unavailable"); return 2; }
    using GetState = DWORD (WINAPI *)(DWORD, XINPUT_STATE *);
    auto getState = (GetState)GetProcAddress(module, "XInputGetState");
    if (!getState) return 2;
    DWORD previous[4]{};
    bool connected[4]{};
    unsigned changes[4]{};
    for (int sample = 0; sample < 25; ++sample) {
        for (DWORD slot = 0; slot < 4; ++slot) {
            XINPUT_STATE state{};
            DWORD result = getState(slot, &state);
            if (result == ERROR_SUCCESS) {
                if (!connected[slot] || state.dwPacketNumber != previous[slot]) {
                    ++changes[slot];
                    std::printf("XInput slot=%lu buttons=%04x left=%d,%d right=%d,%d triggers=%u,%u\n",
                        (unsigned long)slot, state.Gamepad.wButtons, state.Gamepad.sThumbLX, state.Gamepad.sThumbLY,
                        state.Gamepad.sThumbRX, state.Gamepad.sThumbRY, state.Gamepad.bLeftTrigger, state.Gamepad.bRightTrigger);
                }
                connected[slot] = true; previous[slot] = state.dwPacketNumber;
            } else if (sample == 0 || connected[slot]) {
                std::printf("XInput slot=%lu status=%lu\n", (unsigned long)slot, (unsigned long)result);
                connected[slot] = false;
            }
        }
        Sleep(200);
    }
    for (unsigned slot = 0; slot < 4; ++slot)
        std::printf("XInput summary slot=%u connected=%d state_samples=%u\n", slot, connected[slot], changes[slot]);
    FreeLibrary(module);
    return 0; // Missing hardware is an observation, not a successful input test.
}
