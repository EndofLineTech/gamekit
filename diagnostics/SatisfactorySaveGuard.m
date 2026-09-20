// Diagnostic-only process sandbox: the game may read saves but cannot write them.
// Link into an experimental identity helper; never included in the normal app.
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sandbox.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef GAMEKIT_SAVE_GUARD_DIRECTORY
#error Supply the exact original SaveGames directory
#endif

static void recordGuard(int applied, int verified) {
#ifdef GAMEKIT_SAVE_GUARD_LOG
    const char *session = getenv("GAMEKIT_SESSION_ID") ?: "";
    if (strlen(session) > 36 || strspn(session, "0123456789abcdefABCDEF-") != strlen(session)) return;
    int log = open(GAMEKIT_SAVE_GUARD_LOG, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (log < 0) return;
    if (!fstat(log, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1 &&
        (info.st_mode & 0777) == 0600 && info.st_size < 65536) {
        char line[192];
        int length = snprintf(line, sizeof(line), "pid=%d session=%s verified=%d sandbox_result=%d\n", getpid(), session, verified, applied);
        if (length > 0 && length < (int)sizeof(line)) (void)write(log, line, (size_t)length);
    }
    close(log);
#else
    (void)applied; (void)verified;
#endif
}

void GamekitProtectSatisfactorySaves(void) {
    NSString *directory = @GAMEKIT_SAVE_GUARD_DIRECTORY;
    if ([directory containsString:@"\""] || [directory containsString:@"\\"] || ![directory hasPrefix:@"/"]) _exit(78);
    NSString *profile = [NSString stringWithFormat:@"(version 1) (allow default) (deny file-write* (subpath \"%@\"))", directory];
    char *error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int applied = sandbox_init(profile.UTF8String, 0, &error);
    if (error) sandbox_free_error(error);
#pragma clang diagnostic pop
    // A child can inherit the guard and cannot install a second sandbox. In
    // either case verify an actual exclusive creation is denied before Wine
    // starts the game. Never open an existing save for this check.
    int root = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) _exit(78);
    NSString *marker = [@".gamekit-write-denial-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(root, marker.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int code = errno;
    if (fd >= 0) { close(fd); unlinkat(root, marker.UTF8String, 0); }
    close(root);
    if (fd >= 0 || (code != EPERM && code != EACCES)) { recordGuard(applied, 0); _exit(78); }
    recordGuard(applied, 1);
    fprintf(stderr, "Gamekit diagnostic save-write guard verified (sandbox_result=%d)\n", applied);
}
