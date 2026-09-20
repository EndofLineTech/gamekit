#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Wine 10 win32u/winstation.c reads this per-executable Explorer setting.
 * Only the named desktop's size is shared; the default Steam desktop is untouched. */
static const WCHAR app_key[] = L"Software\\Wine\\AppDefaults\\WondersII_1_13.exe\\Explorer";
static const WCHAR sizes_key[] = L"Software\\Wine\\Explorer\\Desktops";
static const WCHAR desktop[] = L"Gamekit15900";

static int inspect(const WCHAR *key, const WCHAR *name, const WCHAR *expected) {
    WCHAR value[256]; DWORD type = 0, size = sizeof(value);
    LONG result = RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_ANY, &type, value, &size);
    if (result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND) return 0;
    if (result == ERROR_SUCCESS && type == REG_SZ && size == (wcslen(expected) + 1) * sizeof(WCHAR)
        && !memcmp(value, expected, size)) return 1;
    return -1;
}
static LONG write_value(const WCHAR *key, const WCHAR *name, const WCHAR *value) {
    HKEY handle;
    LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_SET_VALUE, NULL, &handle, NULL);
    if (result != ERROR_SUCCESS) return result;
    result = RegSetValueExW(handle, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
    RegCloseKey(handle);
    return result;
}
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "query") && strcmp(argv[1], "apply") && strcmp(argv[1], "restore"))) return 2;
    int app = inspect(app_key, L"Desktop", desktop);
    int size = inspect(sizes_key, desktop, L"800x600");
    printf("app_desktop=%s named_size=%s\n", app == 0 ? "absent" : app == 1 ? "Gamekit15900" : "other",
        size == 0 ? "absent" : size == 1 ? "800x600" : "other");
    if (!strcmp(argv[1], "query")) return 0;
    if (app < 0 || size < 0) return 3; /* Never overwrite unknown preferences. */
    if (!strcmp(argv[1], "restore")) {
        if (app == 1 && RegDeleteKeyValueW(HKEY_CURRENT_USER, app_key, L"Desktop") != ERROR_SUCCESS) return 4;
        if (size == 1 && RegDeleteKeyValueW(HKEY_CURRENT_USER, sizes_key, desktop) != ERROR_SUCCESS) return 4;
    } else {
        if (app || size) return 3; /* Require an untouched baseline. */
        if (write_value(sizes_key, desktop, L"800x600") != ERROR_SUCCESS) return 4;
        if (write_value(app_key, L"Desktop", desktop) != ERROR_SUCCESS) {
            RegDeleteKeyValueW(HKEY_CURRENT_USER, sizes_key, desktop);
            return 4;
        }
    }
    app = inspect(app_key, L"Desktop", desktop); size = inspect(sizes_key, desktop, L"800x600");
    int expected = !strcmp(argv[1], "apply") ? 1 : 0;
    printf("readback app=%d size=%d\n", app, size);
    return app == expected && size == expected ? 0 : 4;
}
