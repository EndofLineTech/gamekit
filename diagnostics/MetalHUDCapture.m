// Diagnostic-only game-scoped HUD logging. No compiler interposition or
// reflection serialization; link alongside the normal identity/Space helper.
#import <Foundation/Foundation.h>
#include "DiagnosticProfile.h"
#include <crt_externs.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef GAMEKIT_METAL_HUD_LOG_DIRECTORY
#error Supply a fresh private output directory at build time.
#endif

__attribute__((constructor)) static void StartMetalHUDCapture(void) {
    @autoreleasepool {
        if (!getenv("GAMEKIT_SESSION_ID") || !getenv("WINEPREFIX")) return;
        BOOL target = NO;
        char **arguments = *_NSGetArgv();
        for (int i = 0; i < *_NSGetArgc() && i < 3; ++i) {
            NSString *argument = [NSString stringWithUTF8String:arguments[i]];
            if ([argument hasPrefix:@"-"]) continue;
            NSString *name = [[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
            if ([name hasSuffix:@".exe"]) { target = GamekitDiagnosticMatches(@"primary", nil, name); break; }
        }
        if (!target) return;
        int dir = open(GAMEKIT_METAL_HUD_LOG_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (dir < 0) return;
        int fd = openat(dir, "stderr.log", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        close(dir);
        if (fd < 0) return;
        struct stat info;
        if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1 && dup2(fd, STDERR_FILENO) >= 0) {
            setenv("MTL_HUD_ENABLED", "1", 1);
            setenv("MTL_HUD_LOG_ENABLED", "1", 1);
            setenv("MTL_HUD_LOG_SHADER_ENABLED", "1", 1);
            fprintf(stderr, "Gamekit HUD-only capture pid=%d\n", getpid());
        }
        close(fd);
    }
}
