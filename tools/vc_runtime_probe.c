#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

/* Read-only reproduction of the Unreal bootstrapper's VC runtime checks.
 * Prints only dependency names, numeric versions and Win32 status codes. */
int main(void) {
    int failed = 0;
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    printf("System image ntdll=%p RtlUserThreadStart=%p\n", (void *)ntdll, (void *)GetProcAddress(ntdll, "RtlUserThreadStart"));
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX | SEM_NOGPFAULTERRORBOX);
    HKEY key;
    LONG status = RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64", 0, KEY_READ, &key);
    printf("VC runtime registry open: %ld\n", status);
    if (status != ERROR_SUCCESS) { failed = 1; }
    if (status == ERROR_SUCCESS) {
        const WCHAR *fields[] = { L"Installed", L"Major", L"Minor", L"Bld", L"Rbld" };
        const char *labels[] = { "Installed", "Major", "Minor", "Bld", "Rbld" };
        for (int i = 0; i < 5; ++i) {
            DWORD value = 0, size = sizeof(value), type = 0;
            status = RegQueryValueExW(key, fields[i], NULL, &type, (BYTE *)&value, &size);
            printf("%s: status=%ld type=%lu value=%lu\n", labels[i], status, type, value);
        }
        RegCloseKey(key);
    }
    const WCHAR *dlls[] = { L"msvcp140_2.dll", L"vcruntime140_1.dll", L"msvcp140.dll", L"vcruntime140.dll", L"ucrtbase.dll" };
    const char *labels[] = { "msvcp140_2.dll", "vcruntime140_1.dll", "msvcp140.dll", "vcruntime140.dll", "ucrtbase.dll" };
    for (int i = 0; i < 5; ++i) {
        WCHAR path[MAX_PATH];
        DWORD rootSize = GetEnvironmentVariableW(L"SystemRoot", path, MAX_PATH);
        printf("SystemRoot available: %s\n", rootSize > 0 && rootSize < MAX_PATH ? "yes" : "no");
        GetSystemDirectoryW(path, MAX_PATH);
        wcscat_s(path, MAX_PATH, L"\\");
        wcscat_s(path, MAX_PATH, dlls[i]);
        DWORD ignored = 0;
        DWORD bytes = GetFileVersionInfoSizeW(path, &ignored);
        void *version = bytes ? HeapAlloc(GetProcessHeap(), 0, bytes) : NULL;
        VS_FIXEDFILEINFO *fixed = NULL;
        UINT fixedSize = 0;
        if (version && GetFileVersionInfoW(path, 0, bytes, version) && VerQueryValueW(version, L"\\", (void **)&fixed, &fixedSize)
            && fixedSize >= sizeof(VS_FIXEDFILEINFO)) {
            printf("File version %s: %u.%u.%u.%u\n", labels[i],
                HIWORD(fixed->dwFileVersionMS), LOWORD(fixed->dwFileVersionMS),
                HIWORD(fixed->dwFileVersionLS), LOWORD(fixed->dwFileVersionLS));
            /* The observed bootstrapper requires at least 14.42.34438 for
             * msvcp140_2 and vcruntime140_1, not just successful LoadLibrary. */
            WORD major = HIWORD(fixed->dwFileVersionMS), minor = LOWORD(fixed->dwFileVersionMS);
            WORD build = HIWORD(fixed->dwFileVersionLS);
            if (i < 2 && !(major > 14 || (major == 14 && (minor > 42 || (minor == 42 && build >= 34438))))) { failed = 1; }
        } else {
            printf("File version %s: FAIL error=%lu\n", labels[i], GetLastError());
            if (i < 2) { failed = 1; }
        }
        if (version) { HeapFree(GetProcessHeap(), 0, version); }
        SetLastError(0);
        HMODULE module = LoadLibraryW(dlls[i]);
        DWORD error = module ? 0 : GetLastError();
        printf("Load %s: %s error=%lu\n", labels[i], module ? "PASS" : "FAIL", error);
        if (!module) { failed = 1; continue; }
        FreeLibrary(module);
    }
    return failed;
}
