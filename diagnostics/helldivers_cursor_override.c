#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Wine 10 winemac.drv documents this game-scoped alternative capture path.
 * Refuse to overwrite an existing preference or remove an unexpected value. */
static const WCHAR key_path[] = L"Software\\Wine\\AppDefaults\\helldivers2.exe\\Mac Driver";

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "query") && strcmp(argv[1], "event-tap") && strcmp(argv[1], "restore-default")
        && strcmp(argv[1], "query-display") && strcmp(argv[1], "capture-display") && strcmp(argv[1], "restore-display")))
        return 2;
    BOOL display = strstr(argv[1], "display") != NULL;
    const WCHAR *value_name = display ? L"CaptureDisplaysForFullscreen" : L"UseConfinementCursorClipping";
    const WCHAR *requested = display ? L"y" : L"n";
    const char *label = display ? "display_capture" : "cursor_override";
    const char *configured_name = display ? "enabled" : "event-tap";
    WCHAR value[128] = {0};
    DWORD type = 0, size = sizeof(value);
    LONG status = RegGetValueW(HKEY_CURRENT_USER, key_path, value_name, RRF_RT_ANY | RRF_NOEXPAND, &type, value, &size);
    BOOL absent = status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND;
    if (status != ERROR_SUCCESS && !absent) {
        printf("Registry query failed: %ld\n", status);
        return 1;
    }
    BOOL configured = !absent && type == REG_SZ && size == 2 * sizeof(WCHAR) && value[0] == requested[0] && value[1] == 0;
    BOOL disabled_display = display && !absent && type == REG_SZ && size == 2 * sizeof(WCHAR) && value[0] == L'n' && value[1] == 0;
    if (!strcmp(argv[1], "query") || !strcmp(argv[1], "query-display")) {
        printf("%s=%s\n", label, absent ? "absent" : configured ? configured_name : disabled_display ? "disabled" : "existing-other");
        return 0;
    }
    BOOL restore = !strcmp(argv[1], "restore-default") || !strcmp(argv[1], "restore-display");
    if ((restore && !absent && !configured) || (!restore && !absent)) {
        puts("Refused: existing preference would be overwritten or unexpectedly removed");
        return 1;
    }
    if (restore && absent) {
        printf("%s=absent\n", label);
        return 0;
    }
    HKEY key = NULL;
    status = restore ? RegOpenKeyExW(HKEY_CURRENT_USER, key_path, 0, KEY_SET_VALUE, &key)
                     : RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL);
    if (status != ERROR_SUCCESS) {
        printf("Registry open failed: %ld\n", status);
        return 1;
    }
    status = restore ? RegDeleteValueW(key, value_name)
                     : RegSetValueExW(key, value_name, 0, REG_SZ, (const BYTE *)requested, 2 * sizeof(WCHAR));
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
        printf("Registry update failed: %ld\n", status);
        return 1;
    }
    printf("%s=%s\n", label, restore ? "absent" : configured_name);
    return 0;
}
