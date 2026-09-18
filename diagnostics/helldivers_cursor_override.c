#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Wine 10 winemac.drv documents this game-scoped alternative capture path.
 * Refuse to overwrite an existing preference or remove an unexpected value. */
static const WCHAR key_path[] = L"Software\\Wine\\AppDefaults\\helldivers2.exe\\Mac Driver";
static const WCHAR value_name[] = L"UseConfinementCursorClipping";

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "query") && strcmp(argv[1], "event-tap") && strcmp(argv[1], "restore-default")))
        return 2;
    WCHAR value[128] = {0};
    DWORD type = 0, size = sizeof(value);
    LONG status = RegGetValueW(HKEY_CURRENT_USER, key_path, value_name, RRF_RT_ANY | RRF_NOEXPAND, &type, value, &size);
    BOOL absent = status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND;
    if (status != ERROR_SUCCESS && !absent) {
        printf("Registry query failed: %ld\n", status);
        return 1;
    }
    BOOL event_tap = !absent && type == REG_SZ && size == 2 * sizeof(WCHAR) && value[0] == L'n' && value[1] == 0;
    if (!strcmp(argv[1], "query")) {
        printf("cursor_override=%s\n", absent ? "absent" : event_tap ? "event-tap" : "existing-other");
        return 0;
    }
    BOOL restore = !strcmp(argv[1], "restore-default");
    if ((restore && !absent && !event_tap) || (!restore && !absent)) {
        puts("Refused: existing preference would be overwritten or unexpectedly removed");
        return 1;
    }
    if (restore && absent) {
        puts("cursor_override=absent");
        return 0;
    }
    HKEY key = NULL;
    status = restore ? RegOpenKeyExW(HKEY_CURRENT_USER, key_path, 0, KEY_SET_VALUE, &key)
                     : RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL);
    if (status != ERROR_SUCCESS) {
        printf("Registry open failed: %ld\n", status);
        return 1;
    }
    const WCHAR disabled[] = L"n";
    status = restore ? RegDeleteValueW(key, value_name)
                     : RegSetValueExW(key, value_name, 0, REG_SZ, (const BYTE *)disabled, sizeof(disabled));
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
        printf("Registry update failed: %ld\n", status);
        return 1;
    }
    printf("cursor_override=%s\n", restore ? "absent" : "event-tap");
    return 0;
}
