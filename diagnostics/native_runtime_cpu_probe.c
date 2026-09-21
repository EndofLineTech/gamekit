/* Generic Windows CPU/ABI probe, compiled separately for each guest machine. */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#if defined(__i386__) || defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>

__attribute__((target("avx"), noinline)) static int avx_test(unsigned seed) {
    float input[8], output[8];
    for (unsigned i = 0; i < 8; ++i) input[i] = (float)(seed + i);
    __m256 value = _mm256_loadu_ps(input);
    __asm__ volatile("vaddps %0, %0, %0" : "+x"(value));
    _mm256_storeu_ps(output, value);
    for (unsigned i = 0; i < 8; ++i) if (output[i] != 2.0f * input[i]) return 0;
    return 1;
}
__attribute__((target("avx2"), noinline)) static int avx2_test(unsigned seed) {
    int input[8], output[8];
    for (unsigned i = 0; i < 8; ++i) input[i] = (int)(seed + i);
    __m256i value = _mm256_loadu_si256((const __m256i *)input);
    __m256i addend = _mm256_set1_epi32(17);
    // Volatile assembly makes execution observable to the optimizer: comparing
    // two equivalent C expressions alone can collapse this probe to return 1.
    __asm__ volatile("vpaddd %1, %0, %0" : "+x"(value) : "x"(addend));
    _mm256_storeu_si256((__m256i *)output, value);
    for (unsigned i = 0; i < 8; ++i) if (output[i] != input[i] + 17) return 0;
    return 1;
}
#endif

static DWORD tls;
static volatile LONG counter, callback_count;
static DWORD WINAPI worker(void *argument) {
    if (!TlsSetValue(tls, argument)) return 1;
    for (unsigned i = 0; i < 10000; ++i) {
        InterlockedIncrement(&counter);
        if ((i % 128) == 0) SwitchToThread();
        if (TlsGetValue(tls) != argument) return 2;
    }
    return 0;
}
static LONG CALLBACK exception_callback(EXCEPTION_POINTERS *exception) {
    if (exception->ExceptionRecord->ExceptionCode != 0xe0424242) return EXCEPTION_CONTINUE_SEARCH;
    InterlockedIncrement(&callback_count);
    return EXCEPTION_CONTINUE_EXECUTION;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
#if defined(__i386__)
    const char *machine = "i386";
#elif defined(__x86_64__)
    const char *machine = "x86_64";
#elif defined(__aarch64__)
    const char *machine = "arm64";
#else
    const char *machine = "unknown";
#endif
    SYSTEM_INFO system; GetSystemInfo(&system);
    printf("guest=%s pointer_bits=%u page_size=%lu pid=%lu\n", machine, (unsigned)(sizeof(void *) * 8),
           (unsigned long)system.dwPageSize, (unsigned long)GetCurrentProcessId());
    tls = TlsAlloc();
    if (tls == TLS_OUT_OF_INDEXES) return 1;
    HANDLE threads[4];
    for (uintptr_t i = 0; i < 4; ++i) {
        threads[i] = CreateThread(NULL, 0, worker, (void *)(i + 1), 0, NULL);
        if (!threads[i]) return 2;
    }
    if (WaitForMultipleObjects(4, threads, TRUE, 10000) != WAIT_OBJECT_0) return 3;
    for (unsigned i = 0; i < 4; ++i) {
        DWORD code;
        if (!GetExitCodeThread(threads[i], &code) || code) return 4;
        printf("thread=%u exit=%lu\n", i, (unsigned long)code);
        CloseHandle(threads[i]);
    }
    TlsFree(tls);
    printf("atomic_counter=%ld expected=40000\n", (long)counter);
    if (counter != 40000) return 5;
    puts("PASS threads/TLS/atomic operations");
    void *handler = AddVectoredExceptionHandler(1, exception_callback);
    if (!handler) return 6;
    RaiseException(0xe0424242, 0, 0, NULL);
    if (callback_count != 1 || !RemoveVectoredExceptionHandler(handler)) return 7;
    puts("PASS exception callback and return");
#if defined(__i386__) || defined(__x86_64__)
    unsigned eax, ebx, ecx, edx;
    __cpuid_count(1, 0, eax, ebx, ecx, edx);
    printf("CPUID XSAVE=%u OSXSAVE=%u AVX=%u\n", (ecx >> 26) & 1, (ecx >> 27) & 1, (ecx >> 28) & 1);
    if (!(ecx & (1u << 27)) || !(ecx & (1u << 28))) return 8;
    unsigned low, high;
    __asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
    printf("XCR0=%08x%08x\n", high, low);
    if ((low & 6) != 6) return 9;
    __cpuid_count(7, 0, eax, ebx, ecx, edx);
    printf("CPUID AVX2=%u\n", (ebx >> 5) & 1);
    if (!(ebx & (1u << 5))) return 10;
    unsigned seed = GetTickCount() & 1023;
    if (!avx_test(seed)) return 11;
    puts("PASS AVX execution");
    if (!avx2_test(seed)) return 12;
    puts("PASS AVX2 execution");
#endif
    puts("PASS CPU/ABI probe");
    return 0;
}
