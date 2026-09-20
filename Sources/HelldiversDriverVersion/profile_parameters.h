/* Runtime parameters projected from validated game JSON by GameDockNames.
 * No game identities or version values are compiled into the generic adapter. */
static ULONGLONG profileMatch, profileReplacement;

static BOOL parseVersion(const WCHAR *text, ULONGLONG *value)
{
    ULONGLONG parsed = 0;
    if (wcslen(text) != 16) return FALSE;
    for (unsigned i = 0; i < 16; ++i) {
        unsigned digit;
        if (text[i] >= L'0' && text[i] <= L'9') digit = text[i] - L'0';
        else if (text[i] >= L'a' && text[i] <= L'f') digit = text[i] - L'a' + 10;
        else return FALSE;
        parsed = (parsed << 4) | digit;
    }
    *value = parsed;
    return TRUE;
}

static BOOL readProfileParameters(const WCHAR *image)
{
    WCHAR file[32768], sections[8192], executable[256], directory[32768], match[32], replacement[32];
    DWORD size = GetEnvironmentVariableW(L"GAMEKIT_DXGI_PARAMETERS_FILE", file, 32768);
    if (!size || size >= 32768 || file[0] != L'Z' || file[1] != L':') return FALSE;
    size = GetPrivateProfileSectionNamesW(sections, 8192, file);
    if (!size || size >= 8190) return FALSE;
    const WCHAR *name = wcsrchr(image, L'\\');
    name = name ? name + 1 : image;
    BOOL found = FALSE;
    unsigned count = 0;
    for (const WCHAR *section = sections; *section; section += wcslen(section) + 1) {
        if (++count > 512) return FALSE;
        DWORD length = GetPrivateProfileStringW(section, L"Executable", L"", executable, 256, file);
        if (!length || length >= 255 || lstrcmpiW(executable, name)) continue;
        length = GetPrivateProfileStringW(section, L"Directory", L"", directory, 32768, file);
        if (!length || length >= 32767 || directory[length - 1] != L'\\' ||
            _wcsnicmp(image, directory, length)) continue;
        if (found) return FALSE; /* Ambiguous image ownership never chooses a rule. */
        GetPrivateProfileStringW(section, L"Match", L"", match, 32, file);
        GetPrivateProfileStringW(section, L"Replacement", L"", replacement, 32, file);
        if (!parseVersion(match, &profileMatch) || !parseVersion(replacement, &profileReplacement)) return FALSE;
        found = TRUE;
    }
    return found;
}
