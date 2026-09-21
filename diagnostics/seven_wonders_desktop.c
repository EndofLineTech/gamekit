#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* Wine 10 win32u/winstation.c reads this per-executable Explorer setting.
 * Only the named desktop's size is shared; the default Steam desktop is untouched. */
static WCHAR app_key[512];
static const WCHAR sizes_key[] = L"Software\\Wine\\Explorer\\Desktops";
static WCHAR desktop[128], dimensions[128];

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
    if (argc != 5 || (strcmp(argv[1], "query") && strcmp(argv[1], "apply") && strcmp(argv[1], "restore"))) return 2;
    for (int i = 2; i < 5; ++i) if (!strlen(argv[i]) || strlen(argv[i]) > 100 || strpbrk(argv[i], "\\/[]\r\n\t\"")) return 2;
    WCHAR executable[128];
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[2], -1, executable, 128) ||
        !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[3], -1, desktop, 128) ||
        !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[4], -1, dimensions, 128)) return 2;
    swprintf(app_key, 512, L"Software\\Wine\\AppDefaults\\%ls\\Explorer", executable);
    int app = inspect(app_key, L"Desktop", desktop);
    int size = inspect(sizes_key, desktop, dimensions);
    printf("app_desktop=%s named_size=%s\n", app == 0 ? "absent" : app == 1 ? argv[3] : "other",
        size == 0 ? "absent" : size == 1 ? argv[4] : "other");
    if (!strcmp(argv[1], "query")) return 0;
    if (app < 0 || size < 0) return 3; /* Never overwrite unknown preferences. */
    if (!strcmp(argv[1], "restore")) {
        if (app == 1 && RegDeleteKeyValueW(HKEY_CURRENT_USER, app_key, L"Desktop") != ERROR_SUCCESS) return 4;
        if (size == 1 && RegDeleteKeyValueW(HKEY_CURRENT_USER, sizes_key, desktop) != ERROR_SUCCESS) return 4;
    } else {
        if (app || size) return 3; /* Require an untouched baseline. */
        if (write_value(sizes_key, desktop, dimensions) != ERROR_SUCCESS) return 4;
        if (write_value(app_key, L"Desktop", desktop) != ERROR_SUCCESS) {
            RegDeleteKeyValueW(HKEY_CURRENT_USER, sizes_key, desktop);
            return 4;
        }
    }
    app = inspect(app_key, L"Desktop", desktop); size = inspect(sizes_key, desktop, dimensions);
    int expected = !strcmp(argv[1], "apply") ? 1 : 0;
    printf("readback app=%d size=%d\n", app, size);
    return app == expected && size == expected ? 0 : 4;
}
