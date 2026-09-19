// Read-only, PID-start-identity-pinned CPU/IO samples. No paths or arguments logged.
#include "CProcessSupport.h"
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static int number(const char *text, uint64_t *value)
{
    if (!text || !*text) return 0;
    for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return 0;
    char *end = NULL; errno = 0;
    *value = strtoull(text, &end, 10);
    return errno == 0 && end && !*end;
}

int main(int argc, char **argv)
{
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return 5;
    if (argc == 2 && !strcmp(argv[1], "--self-test")) {
        struct rusage_info_v4 before = {0}, after = {0};
        if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&before)) return 4;
        uint64_t cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID);
        uint64_t until = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 250000000;
        volatile uint64_t work = 1;
        while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < until) work = work * 1664525 + 1013904223;
        uint64_t cpuElapsed = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart;
        if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&after)) return 4;
        double converted = ((after.ri_user_time - before.ri_user_time) + (after.ri_system_time - before.ri_system_time)) *
            (double)timebase.numer / timebase.denom;
        double ratio = cpuElapsed ? converted / cpuElapsed : 0;
        printf("timebase=%u/%u rusage_cpu_ns=%.0f clock_cpu_ns=%" PRIu64 " ratio=%.4f\n", timebase.numer, timebase.denom, converted, cpuElapsed, ratio);
        return ratio > 0.8 && ratio < 1.2 ? 0 : 5;
    }
    uint64_t rawPID, seconds, micros, duration;
    if (argc != 5 || !number(argv[1], &rawPID) || !number(argv[2], &seconds) ||
        !number(argv[3], &micros) || !number(argv[4], &duration) || !rawPID || rawPID > INT_MAX ||
        !seconds || micros >= 1000000 || duration < 1 || duration > 90) return 2;
    const pid_t pid = (pid_t)rawPID;
    const uint64_t end = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + duration * 1000000000ULL;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("{\"event\":\"start\",\"schemaVersion\":1,\"pid\":%d,\"timebase_numer\":%u,\"timebase_denom\":%u}\n", pid, timebase.numer, timebase.denom);
    do {
        GKProcessIdentity before, after;
        int status = gk_identity(pid, &before);
        if (status == ESRCH || status == ENOENT || (!status && before.zombie)) {
            puts("{\"event\":\"exited\"}"); return 0;
        }
        if (status || before.uid != getuid() || before.start_seconds != seconds || before.start_microseconds != micros) return 3;
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage)) { perror("proc_pid_rusage"); return 4; }
        if (gk_identity(pid, &after) || after.start_seconds != seconds || after.start_microseconds != micros || after.uid != getuid()) return 3;
        double now = clock_gettime_nsec_np(CLOCK_REALTIME) / 1000000000.0;
        printf("{\"event\":\"sample\",\"unixTime\":%.6f,\"pid\":%d,\"user_ticks\":%" PRIu64 ",\"system_ticks\":%" PRIu64
               ",\"disk_read_bytes\":%" PRIu64 ",\"disk_write_bytes\":%" PRIu64 ",\"pageins\":%" PRIu64 ",\"footprint_bytes\":%" PRIu64 "}\n",
               now, pid, usage.ri_user_time, usage.ri_system_time, usage.ri_diskio_bytesread,
               usage.ri_diskio_byteswritten, usage.ri_pageins, usage.ri_phys_footprint);
        usleep(100000);
    } while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < end);
    return 0;
}
