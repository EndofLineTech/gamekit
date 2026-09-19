// Diagnostic-only, linked into a separate helper package. Observes converter
// calls without changing their arguments, output, or return value.
// The D3DMetal 4.0b2 private C++ entry is ABI-specific: its mangled arguments
// and bool return were inspected locally. Its opaque layout is NEVER decoded.
// Public opaque reflection API reference:
// https://github.com/wmarti/metal-shader-converter/blob/main/include/metal_irconverter.h
#import <Foundation/Foundation.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef GAMEKIT_COMPILE_TIMING
#include <string>
#include <vector>
struct IRObject;
struct IRError;
struct IRCompiler;
extern IRObject *IRCompilerAllocCompileAndLink(IRCompiler *, const std::vector<std::string> &, const IRObject *, IRError **);
static unsigned compileCalls;
#endif

#ifndef GAMEKIT_STAGEIN_LOG_DIRECTORY
#error Supply an explicit private diagnostic output directory at build time.
#endif

typedef struct IRCompiler IRCompiler;
typedef struct IRShaderReflection IRShaderReflection;
typedef struct IRMetalLibBinary IRMetalLibBinary;
extern "C" {
extern const char *IRShaderReflectionCopyJSONString(const IRShaderReflection *);
extern void IRShaderReflectionFreeString(const char *);
}
struct D3DMInputLayoutDesc;
extern bool IRCreateStageInFunction(const IRCompiler *, IRMetalLibBinary *, const IRShaderReflection *, const D3DMInputLayoutDesc &);

static bool targetGame;
static unsigned failedCalls, successfulCalls;
static pthread_mutex_t outputLock = PTHREAD_MUTEX_INITIALIZER;

static void AppendRecord(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if (!data || data.length > 262144) return;
    pthread_mutex_lock(&outputLock);
    int dir = open(GAMEKIT_STAGEIN_LOG_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir >= 0) {
        int fd = openat(dir, "stage-in.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        struct stat info;
        if (fd >= 0) {
            if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1) {
                NSMutableData *line = [data mutableCopy]; [line appendBytes:"\n" length:1];
                const uint8_t *bytes = static_cast<const uint8_t *>(line.bytes);
                size_t remaining = line.length;
                while (remaining) {
                    ssize_t count = write(fd, bytes, remaining);
                    if (count < 0 && errno == EINTR) continue;
                    if (count <= 0) break;
                    bytes += count; remaining -= (size_t)count;
                }
            }
            close(fd);
        }
        close(dir);
    }
    pthread_mutex_unlock(&outputLock);
}

static id JSONValue(const char *text) {
    if (!text) return NSNull.null;
    size_t length = strnlen(text, 131073);
    if (length > 131072) return @{@"truncated": @YES};
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:text length:length] options:NSJSONReadingFragmentsAllowed error:NULL] ?: NSNull.null;
}

static void RecordStageIn(bool result, const IRShaderReflection *reflection, double durationMS) {
    int savedErrno = errno;
    if (targetGame) {
        unsigned sequence = result ? __atomic_fetch_add(&successfulCalls, 1, __ATOMIC_RELAXED) : __atomic_fetch_add(&failedCalls, 1, __ATOMIC_RELAXED);
        if (sequence < (result ? 4u : 64u)) {
            @autoreleasepool {
                const char *reflectionJSON = reflection ? IRShaderReflectionCopyJSONString(reflection) : NULL;
                uint64_t thread = 0; pthread_threadid_np(NULL, &thread);
                AppendRecord(@{@"event": @"d3dmetal-stage-in", @"pid": @(getpid()), @"thread": @(thread),
                    @"unixTime": @(NSDate.date.timeIntervalSince1970), @"success": @(result), @"sequence": @(sequence), @"durationMS": @(durationMS),
                    @"layout": NSNull.null, @"reflection": JSONValue(reflectionJSON)});
                if (reflectionJSON) IRShaderReflectionFreeString(reflectionJSON);
            }
        }
    }
    errno = savedErrno;
}

static bool TracePrivateStageIn(const IRCompiler *compiler, IRMetalLibBinary *binary,
                                const IRShaderReflection *reflection, const D3DMInputLayoutDesc &layout) {
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    bool result = IRCreateStageInFunction(compiler, binary, reflection, layout);
    int savedErrno = errno;
    double duration = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1000000.0;
    RecordStageIn(result, reflection, duration);
    errno = savedErrno;
    return result;
}

#ifdef GAMEKIT_COMPILE_TIMING
// D3DMetal 4.0b2 imports this vector-reference overload, not the public C entry.
// Its register-return ABI was inspected locally. Forward opaque objects and
// the original vector reference untouched; never export shader data or names.
static IRObject *TraceCompile(IRCompiler *compiler, const std::vector<std::string> &entries,
                              const IRObject *input, IRError **error) {
    if (!targetGame) return IRCompilerAllocCompileAndLink(compiler, entries, input, error);
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    IRObject *result = IRCompilerAllocCompileAndLink(compiler, entries, input, error);
    int savedErrno = errno;
    double duration = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1000000.0;
    unsigned sequence = __atomic_fetch_add(&compileCalls, 1, __ATOMIC_RELAXED);
    if (sequence < 8192) {
        @autoreleasepool {
            uint64_t thread = 0; pthread_threadid_np(NULL, &thread);
            AppendRecord(@{@"event": @"compile-link", @"pid": @(getpid()), @"thread": @(thread),
                @"unixTime": @(NSDate.date.timeIntervalSince1970), @"durationMS": @(duration),
                @"sequence": @(sequence), @"success": @(result != nullptr)});
        }
    }
    errno = savedErrno;
    return result;
}
#endif

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } stageInInterpose[] = {
    {(const void *)&TracePrivateStageIn, (const void *)&IRCreateStageInFunction}
#ifdef GAMEKIT_COMPILE_TIMING
    , {(const void *)&TraceCompile, (const void *)&IRCompilerAllocCompileAndLink}
#endif
};

__attribute__((constructor)) static void InitializeStageInTrace(void) {
    @autoreleasepool {
        if (!getenv("GAMEKIT_SESSION_ID") || !getenv("WINEPREFIX")) return;
        char **arguments = *_NSGetArgv();
        for (int i = 0; i < *_NSGetArgc() && i < 3; ++i) {
            NSString *argument = [NSString stringWithUTF8String:arguments[i]];
            if ([argument hasPrefix:@"-"]) continue;
            NSString *name = [[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
            if ([name hasSuffix:@".exe"]) { targetGame = [name isEqualToString:@"helldivers2.exe"]; break; }
        }
        if (targetGame) {
#ifdef GAMEKIT_STAGEIN_HUD
            // Apple-documented, process-local HUD diagnostics; no user defaults.
            setenv("MTL_HUD_ENABLED", "1", 1);
            setenv("MTL_HUD_LOG_ENABLED", "1", 1);
            setenv("MTL_HUD_LOG_SHADER_ENABLED", "1", 1);
            int dir = open(GAMEKIT_STAGEIN_LOG_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (dir >= 0) {
                int fd = openat(dir, "stderr.log", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
                struct stat info;
                if (fd >= 0) {
                    if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1) dup2(fd, STDERR_FILENO);
                    close(fd);
                }
                close(dir);
            }
#endif
            AppendRecord(@{@"event": @"trace-loaded", @"pid": @(getpid())});
        }
    }
}
