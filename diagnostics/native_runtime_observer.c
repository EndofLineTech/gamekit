/* Read-only ARM64 host receipt. No function interposition or ABI changes. */
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int output = -1;
static void image_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (output < 0) return;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        if (_dyld_get_image_header(i) != header) continue;
        const char *name = _dyld_get_image_name(i);
        dprintf(output, "image\tpid=%d\tcpu=%08x\t%s\n", getpid(), header->cputype, name ? name : "unknown");
        return;
    }
}
__attribute__((constructor)) static void observe_host(void) {
    const char *path = getenv("GAMEKIT_NATIVE_RECEIPT");
    if (!path || !getenv("GAMEKIT_CANDIDATE_SESSION") || !getenv("WINEPREFIX")) return;
    output = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0) return;
    int translated = -1;
    size_t length = sizeof(translated);
    int result = sysctlbyname("sysctl.proc_translated", &translated, &length, NULL, 0);
    dprintf(output, "host\tpid=%d\ttranslated=%d\tquery=%d\tpages=%ld\n", getpid(), translated, result, sysconf(_SC_PAGESIZE));
    _dyld_register_func_for_add_image(image_added);
}
