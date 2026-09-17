/* Build both as a native x86_64 Mach-O and as a Windows x64 executable.
 * Capability advertisement and actual instruction execution are separate tests. */
#include <cpuid.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static LONG WINAPI probe_fault(EXCEPTION_POINTERS *exception) {
    fprintf(stderr, "Instruction fault: 0x%08lx\n", exception->ExceptionRecord->ExceptionCode);
    fflush(stderr);
    ExitProcess(2);
    return EXCEPTION_EXECUTE_HANDLER;
}
#endif

__attribute__((noinline)) static int execute_avx(void) {
    const float a[8] = {1,2,3,4,5,6,7,8};
    const float b[8] = {8,7,6,5,4,3,2,1};
    float result[8] = {0};
    __asm__ volatile("vmovups (%1), %%ymm0\n\t"
                     "vaddps (%2), %%ymm0, %%ymm1\n\t"
                     "vmovups %%ymm1, (%0)\n\t"
                     "vzeroupper"
                     : : "r"(result), "r"(a), "r"(b) : "ymm0", "ymm1", "memory");
    for (int i = 0; i < 8; ++i) if (result[i] != 9.0f) return 1;
    puts("AVX execution: PASS (all eight lanes)");
    return 0;
}

__attribute__((noinline)) static int execute_avx2(void) {
    const int a[8] = {1,2,3,4,5,6,7,8};
    const int b[8] = {8,7,6,5,4,3,2,1};
    int result[8] = {0};
    __asm__ volatile("vmovdqu (%1), %%ymm0\n\t"
                     "vpaddd (%2), %%ymm0, %%ymm1\n\t"
                     "vmovdqu %%ymm1, (%0)\n\t"
                     "vzeroupper"
                     : : "r"(result), "r"(a), "r"(b) : "ymm0", "ymm1", "memory");
    for (int i = 0; i < 8; ++i) if (result[i] != 9) return 1;
    puts("AVX2 execution: PASS (all eight lanes)");
    return 0;
}

int main(int argc, char **argv) {
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    SetUnhandledExceptionFilter(probe_fault);
#endif
    unsigned int a = 0, b = 0, c = 0, d = 0;
    __cpuid_count(1, 0, a, b, c, d);
    unsigned int leaf1 = c;
    printf("CPUID.1: XSAVE=%u OSXSAVE=%u AVX=%u FMA=%u F16C=%u\n",
        (c >> 26) & 1, (c >> 27) & 1, (c >> 28) & 1, (c >> 12) & 1, (c >> 29) & 1);
    if (__get_cpuid_max(0, NULL) >= 7) {
        __cpuid_count(7, 0, a, b, c, d);
        printf("CPUID.7: AVX2=%u AVX512F=%u\n", (b >> 5) & 1, (b >> 16) & 1);
    }
    if (leaf1 & (1u << 27)) {
        __asm__ volatile("xgetbv" : "=a"(a), "=d"(d) : "c"(0));
        printf("XCR0: 0x%llx; XMM/YMM enabled=%u\n", (unsigned long long)(((uint64_t)d << 32) | a), (a & 6) == 6);
    } else { puts("XCR0: not queried (OSXSAVE not advertised)"); }
#ifdef _WIN32
    printf("Windows PF: XSAVE=%d AVX=%d AVX2=%d AVX512F=%d\n",
        IsProcessorFeaturePresent(PF_XSAVE_ENABLED), IsProcessorFeaturePresent(PF_AVX_INSTRUCTIONS_AVAILABLE),
        IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE), IsProcessorFeaturePresent(PF_AVX512F_INSTRUCTIONS_AVAILABLE));
#endif
    fflush(stdout);
    if (argc == 2 && strcmp(argv[1], "--execute") == 0) {
        if (execute_avx() || execute_avx2()) { puts("Instruction arithmetic: FAIL"); return 1; }
    }
    return 0;
}
