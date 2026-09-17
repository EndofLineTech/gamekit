#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* A short-lived, non-activating window for the opt-in Wine identity test. */
static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_TIMER || message == WM_CLOSE) { DestroyWindow(window); return 0; }
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    (void)previous; (void)command; (void)show;
    WNDCLASSW cls = {0};
    cls.hInstance = instance;
    cls.lpfnWndProc = WindowProc;
    cls.lpszClassName = L"GamekitDockIdentityProbe";
    if (!RegisterClassW(&cls)) return 1;
    HWND window = CreateWindowExW(0, cls.lpszClassName, L"Gamekit identity verification",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 320, 120,
        NULL, NULL, instance, NULL);
    if (!window) return 2;
    SetTimer(window, 1, 7000, NULL);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}
