// Diagnostic-only pass-through timing of read/pread in managed Helldivers.
// Records sizes/durations/categories, never read contents or file paths.
#import <Foundation/Foundation.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef GAMEKIT_READ_TIMING_DIRECTORY
#error Supply a fresh private output directory.
#endif

static _Atomic bool target;
static _Thread_local bool recording;
static _Atomic uint64_t calls, returnedBytes, elapsedNS, slowCalls;
static _Atomic uint64_t preadCalls, preadBytes, preadElapsedNS, preadIntervalMaxNS, fileRecords, otherRecords;
static pthread_mutex_t outputLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t ticker;

static void Record(NSDictionary *record) {
    bool previous = recording;
    recording = true;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if (data && data.length < 8192) {
        pthread_mutex_lock(&outputLock);
        int directory = open(GAMEKIT_READ_TIMING_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directory >= 0) {
            int fd = openat(directory, "reads.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
            struct stat info;
            if (fd >= 0) {
                if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1) {
                    NSMutableData *line = [data mutableCopy]; [line appendBytes:"\n" length:1];
                    const uint8_t *bytes = line.bytes; size_t remaining = line.length;
                    while (remaining) {
                        ssize_t count = write(fd, bytes, remaining);
                        if (count < 0 && errno == EINTR) continue;
                        if (count <= 0) break;
                        bytes += count; remaining -= (size_t)count;
                    }
                }
                close(fd);
            }
            close(directory);
        }
        pthread_mutex_unlock(&outputLock);
    }
    recording = previous;
}

#include "DiagnosticProfile.h"
static void Observe(int fd, size_t requested, ssize_t result, uint64_t duration, const char *operation) {
    atomic_fetch_add(&calls, 1);
    if (result > 0) atomic_fetch_add(&returnedBytes, (uint64_t)result);
    atomic_fetch_add(&elapsedNS, duration);
    if (operation[0] == 'p') {
        atomic_fetch_add(&preadCalls, 1);
        if (result > 0) atomic_fetch_add(&preadBytes, (uint64_t)result);
        atomic_fetch_add(&preadElapsedNS, duration);
        uint64_t maximum = atomic_load(&preadIntervalMaxNS);
        while (maximum < duration && !atomic_compare_exchange_weak(&preadIntervalMaxNS, &maximum, duration)) {}
    }
    if (duration < 20000000) return;
    atomic_fetch_add(&slowCalls, 1);
    @autoreleasepool {
        char path[PATH_MAX] = {0};
        NSString *category = @"non-file-or-unavailable";
        if (fcntl(fd, F_GETPATH, path) == 0) {
            if (atomic_fetch_add(&fileRecords, 1) >= 128) return;
            NSString *name = [NSString stringWithUTF8String:path];
            id installation = GamekitDiagnosticParameters(@"primary")[@"installationSuffix"];
            if ([installation isKindOfClass:NSString.class] && [installation length] && [name containsString:installation]) category = @"game-installation";
            else if ([name containsString:@"/d3dm/"] || [name containsString:@"/Caches/"]) category = @"cache";
            else category = @"other-file";
        } else if (duration < 500000000 || atomic_fetch_add(&otherRecords, 1) >= 16) return;
        uint64_t thread = 0; pthread_threadid_np(NULL, &thread);
        Record(@{@"event": @"slow-read", @"pid": @(getpid()), @"thread": @(thread), @"operation": @(operation),
                 @"unixTime": @(NSDate.date.timeIntervalSince1970), @"durationMS": @(duration / 1000000.0),
                 @"requestedBytes": @(requested), @"returnedBytes": @(result), @"category": category});
    }
}

static ssize_t TraceRead(int fd, void *buffer, size_t count) {
    if (!target || recording) return read(fd, buffer, count);
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    ssize_t result = read(fd, buffer, count); int error = errno;
    recording = true;
    Observe(fd, count, result, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start, "read");
    recording = false;
    errno = error; return result;
}
static ssize_t TracePread(int fd, void *buffer, size_t count, off_t offset) {
    if (!target || recording) return pread(fd, buffer, count, offset);
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    ssize_t result = pread(fd, buffer, count, offset); int error = errno;
    recording = true;
    Observe(fd, count, result, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start, "pread");
    recording = false;
    errno = error; return result;
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } readInterpose[] = {
    {(const void *)&TraceRead, (const void *)&read}, {(const void *)&TracePread, (const void *)&pread}
};

__attribute__((constructor)) static void StartReadTiming(void) {
    @autoreleasepool {
        if (!getenv("GAMEKIT_SESSION_ID") || !getenv("WINEPREFIX")) return;
        char **arguments = *_NSGetArgv();
        for (int i = 0; i < *_NSGetArgc() && i < 3; ++i) {
            NSString *argument = [NSString stringWithUTF8String:arguments[i]];
            if ([argument hasPrefix:@"-"]) continue;
            NSString *name = [[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
            if ([name hasSuffix:@".exe"]) { target = GamekitDiagnosticMatches(@"primary", nil, name); break; }
        }
        if (!target) return;
        __block unsigned samples = 0;
        ticker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(ticker, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 10000000);
        dispatch_source_set_event_handler(ticker, ^{
            @autoreleasepool {
                Record(@{@"event": @"totals", @"pid": @(getpid()), @"unixTime": @(NSDate.date.timeIntervalSince1970),
                    @"calls": @(atomic_load(&calls)), @"returnedBytes": @(atomic_load(&returnedBytes)),
                    @"sumElapsedNS": @(atomic_load(&elapsedNS)), @"slowCalls": @(atomic_load(&slowCalls)),
                    @"preadCalls": @(atomic_load(&preadCalls)), @"preadBytes": @(atomic_load(&preadBytes)),
                    @"preadElapsedNS": @(atomic_load(&preadElapsedNS)), @"preadIntervalMaxNS": @(atomic_exchange(&preadIntervalMaxNS, 0))});
                if (++samples >= 120) dispatch_source_cancel(ticker);
            }
        });
        dispatch_resume(ticker);
    }
}
