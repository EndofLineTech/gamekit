/* Read-only host inventory for the macOS 28 runtime investigation.
 * Queries feature availability; never changes page size, thread ABI, TSO,
 * signing, entitlements, Rosetta installation, or any Wine prefix.
 * Build with the Xcode 27 SDK for arm64.
 */
#include <dlfcn.h>
#include <errno.h>
#include <os/arch/arm64.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/sysctl.h>
#include <unistd.h>

int main(void)
{
#if !defined(__arm64__)
    fputs("This inventory must run as a native arm64 process.\n", stderr);
    return 2;
#else
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) != 0 && errno != ENOENT) {
        perror("sysctl.proc_translated");
        return 1;
    }
    printf("process_architecture=arm64\nprocess_translated=%d\nhost_page_size=%ld\n", translated, sysconf(_SC_PAGESIZE));
    if (__builtin_available(macOS 26.6, *)) {
        printf("kernel_cross_arch_x86_64=%s\n", os_cross_arch_is_supported(OS_CROSS_ARCH_X86_64) ? "true" : "false");
    } else {
        puts("kernel_cross_arch_x86_64=query_unavailable");
    }
    const char *symbols[] = {
        "posix_spawnattr_set_4k_page_size_np",
        "os_set_custom_x18_abi_enabled",
        "os_custom_x18_abi_enabled",
        "thread_set_x86_64_compat"
    };
    for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); ++i)
        printf("symbol_%s=%s\n", symbols[i], dlsym(RTLD_DEFAULT, symbols[i]) ? "present" : "absent");
    puts("cross_arch_authorization=not_tested\nreplacement_runtime=not_tested\nmacos28_compatibility=not_tested");
    return 0;
#endif
}
