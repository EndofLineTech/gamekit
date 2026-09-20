// Explicit diagnostic build only: capture one title's Wine D3D/display errors.
#import <Foundation/Foundation.h>
#include <crt_externs.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef GAMEKIT_LEGACY_D3D_LOG
#error Supply a private log path
#endif
__attribute__((constructor)) static void StartLegacyD3DTrace(void) {
    @autoreleasepool {
        if (!getenv("GAMEKIT_SESSION_ID") || !getenv("WINEPREFIX")) return;
        char **args = *_NSGetArgv();
        BOOL target = NO;
        for (int i = 1; i < *_NSGetArgc() && i < 4; ++i) {
            NSString *name = [[[NSString stringWithUTF8String:args[i]] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
            if ([name caseInsensitiveCompare:@"7 Wonders - Treasures of Seven.exe"] == NSOrderedSame) target = YES;
        }
        if (!target) return;
        int fd = open(GAMEKIT_LEGACY_D3D_LOG, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return;
        struct stat info;
        if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1 &&
            (info.st_mode & 0777) == 0600 && info.st_size < 1048576 && dup2(fd, STDERR_FILENO) >= 0) {
            setenv("WINEDEBUG", "-all,err+d3d,err+d3d8,err+system", 1);
            fprintf(stderr, "Gamekit legacy D3D error capture pid=%d\n", getpid());
        }
        close(fd);
    }
}
