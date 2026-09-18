#import <Foundation/Foundation.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSString *EnvironmentString(const char *key) {
    const char *value = getenv(key);
    return value ? [NSString stringWithUTF8String:value] : nil;
}

static NSString *CanonicalAppID(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    if (!value.length || value.length > 10 ||
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) return nil;
    unsigned long long number = strtoull(value.UTF8String, NULL, 10);
    if (!number || number > UINT32_MAX) return nil;
    return [NSString stringWithFormat:@"%llu", number];
}

static NSString *GameAppID(void) { return CanonicalAppID(EnvironmentString("SteamAppId")); }

#ifndef GAMEKIT_IDENTITY_READER_TEST
static NSString *ReadArgument(const unsigned char *bytes, NSUInteger length, NSUInteger *offset) {
    if (*offset >= length) return nil;
    const unsigned char *end = memchr(bytes + *offset, 0, length - *offset);
    if (!end) return nil;
    NSUInteger count = (NSUInteger)(end - bytes) - *offset;
    NSString *value = [[NSString alloc] initWithBytes:bytes + *offset length:count encoding:NSUTF8StringEncoding];
    *offset += count + 1;
    return value;
}
#endif

/* Wine rewrites argv to the Windows image. Read only this process's first three
 * arguments, not its environment or another process's private command line. */
static NSString *WindowsImage(void) {
#ifdef GAMEKIT_IDENTITY_READER_TEST
    return EnvironmentString("GAMEKIT_TEST_WINDOWS_IMAGE");
#else
    int mib[] = { CTL_KERN, KERN_PROCARGS2, getpid() };
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) || length < sizeof(int) || length > 1048576) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (sysctl(mib, 3, data.mutableBytes, &length, NULL, 0)) return nil;
    const unsigned char *bytes = data.bytes;
    int argc = 0; memcpy(&argc, bytes, sizeof(argc));
    if (argc < 1 || argc > 4096) return nil;
    NSUInteger offset = sizeof(argc);
    NSString *unixImage = ReadArgument(bytes, length, &offset);
    if (!unixImage) return nil;
    while (offset < length && bytes[offset] == 0) ++offset;
    for (int i = 0; i < argc && i < 3; ++i) {
        NSString *argument = ReadArgument(bytes, length, &offset);
        if (!argument) return nil;
        if ([argument isEqual:unixImage]) continue;
        if ([argument.lowercaseString hasSuffix:@".exe"]) return argument;
    }
    return nil;
#endif
}

/* Follow only pinned, non-symlink components and read a bounded regular file.
 * The mapping lives outside the Wine prefix and is written atomically by Gamekit. */
static NSData *ReadMapping(NSString *path) {
    if (![path hasPrefix:@"/"]) return nil;
    NSArray<NSString *> *parts = path.pathComponents;
    if (parts.count < 2) return nil;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return nil;
    for (NSUInteger i = 1; i < parts.count; ++i) {
        NSString *part = parts[i];
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) { close(fd); return nil; }
        int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
        if (i + 1 < parts.count) flags |= O_DIRECTORY;
        int next = openat(fd, part.fileSystemRepresentation, flags);
        close(fd);
        if (next < 0) return nil;
        fd = next;
    }
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_size > 1048576) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[8192];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) != 0) {
        if (count < 0) {
            if (errno == EINTR) continue;
            close(fd); return nil;
        }
        if (data.length + (NSUInteger)count > 1048576) { close(fd); return nil; }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(fd);
    return data;
}

static NSString *ReadGameNameWithLoader(NSString **loader, BOOL *fullscreenSpace) {
    if (loader) *loader = nil;
    if (fullscreenSpace) *fullscreenSpace = NO;
    NSString *appID = GameAppID();
    NSString *prefix = EnvironmentString("WINEPREFIX");
    NSString *session = EnvironmentString("GAMEKIT_SESSION_ID");
    if ((!appID && EnvironmentString("SteamAppId").length) || !prefix.length || !session.length || ![[NSUUID alloc] initWithUUIDString:session]) return nil;
    NSData *data = ReadMapping(EnvironmentString("GAMEKIT_GAME_NAMES_FILE"));
    if (!data) return nil;
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![document isKindOfClass:NSDictionary.class]) return nil;
    id schema = document[@"schemaVersion"];
    if (![schema isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)schema) == CFBooleanGetTypeID() || ![schema isEqual:@1] ||
        ![document[@"prefix"] isEqual:prefix] || ![document[@"sessionID"] isEqual:session]) return nil;
    id games = document[@"games"];
    if (![games isKindOfClass:NSDictionary.class] || [games count] > 512) return nil;
    if (loader && [document[@"defaultLoader"] isKindOfClass:NSString.class]) *loader = document[@"defaultLoader"];
    if (!appID) {
        id directories = document[@"directories"];
        if (![directories isKindOfClass:NSDictionary.class] || [directories count] > 512) return nil;
        NSString *image = [WindowsImage() stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        NSString *unixBase = [prefix stringByAppendingString:@"/drive_c/"];
        if ([image hasPrefix:unixBase]) image = [@"c:\\" stringByAppendingString:[image substringFromIndex:unixBase.length]];
        image = [image stringByReplacingOccurrencesOfString:@"/" withString:@"\\"].lowercaseString;
        NSArray *parts = [image componentsSeparatedByString:@"\\"];
        if (![image hasSuffix:@".exe"] || [parts containsObject:@".."] || [parts containsObject:@"."] ||
            [image rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
        for (id key in directories) {
            id directory = directories[key];
            if (![CanonicalAppID(key) isEqual:key] || ![directory isKindOfClass:NSString.class] ||
                ![directory hasSuffix:@"\\"] || ![directory length]) continue;
            if ([image hasPrefix:[directory lowercaseString]]) {
                if (appID) return nil; // Ambiguous directories cannot name the process.
                appID = key;
            }
        }
        if (!appID) return nil;
    }
    id name = games[appID];
    if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 1024 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    id loaders = document[@"loaders"];
    if (loader && [loaders isKindOfClass:NSDictionary.class] && [loaders count] <= 512 &&
        [loaders[appID] isKindOfClass:NSString.class]) *loader = loaders[appID];
    if (fullscreenSpace && [appID isEqualToString:@"553850"]) {
        id spaces = document[@"fullscreenSpaces"];
        id enabled = [spaces isKindOfClass:NSDictionary.class] ? spaces[appID] : nil;
        NSString *image = [[WindowsImage() stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
        if ([enabled isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID() &&
            [enabled boolValue] && [image isEqualToString:@"helldivers2.exe"]) *fullscreenSpace = YES;
    }
    return name;
}

BOOL GamekitShouldUseFullscreenSpace(void) {
    BOOL enabled = NO;
    (void)ReadGameNameWithLoader(NULL, &enabled);
    return enabled;
}

#ifdef GAMEKIT_IDENTITY_READER_TEST
int main(void) {
    @autoreleasepool {
        if (getenv("GAMEKIT_TEST_SPACE_SETTING")) { puts(GamekitShouldUseFullscreenSpace() ? "enabled" : "disabled"); return 0; }
        NSString *name = ReadGameNameWithLoader(NULL, NULL);
        if (name) puts(name.UTF8String);
    }
    return 0;
}
#else
static NSString *CurrentLoaderPath(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) || !realpath(path, resolved)) return nil;
    return [NSString stringWithUTF8String:resolved];
}

/* Dock takes its label from the executable/bundle on disk, not LSDisplayName.
 * Before Wine starts, re-exec the byte-identical loader in the prepared game
 * bundle. Preserve Wine's arguments, environment and inherited server socket.
 * The one-shot marker is removed before Wine creates any Windows children. */
__attribute__((constructor)) static void GameIdentityStart(void) {
    @autoreleasepool {
        if (!getenv("GAMEKIT_GAME_NAMES_FILE") || !getenv("GAMEKIT_SESSION_ID")) return;
        NSString *current = CurrentLoaderPath();
        NSString *routed = EnvironmentString("GAMEKIT_IDENTITY_ROUTED");
        if (routed) {
            unsetenv("GAMEKIT_IDENTITY_ROUTED");
            if ([routed isEqual:current]) return;
        }
        NSString *target = nil;
        (void)ReadGameNameWithLoader(&target, NULL);
        if (!current || !target.length || [current isEqual:target]) return;
        NSString *root = [[[[EnvironmentString("WINEPREFIX") stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Launchers"] stringByAppendingString:@"/"];
        if (![current hasPrefix:root] || ![target hasPrefix:root]) return;
        NSData *sourceBytes = ReadMapping(current);
        NSData *targetBytes = ReadMapping(target);
        if (!sourceBytes.length || ![sourceBytes isEqual:targetBytes]) return;
        int argc = *_NSGetArgc();
        if (argc < 1 || argc > 4096) return;
        char **original = *_NSGetArgv();
        char **arguments = calloc((size_t)argc + 1, sizeof(char *));
        if (!arguments) return;
        arguments[0] = (char *)target.fileSystemRepresentation;
        for (int i = 1; i < argc; ++i) arguments[i] = original[i];
        if (setenv("GAMEKIT_IDENTITY_ROUTED", target.fileSystemRepresentation, 1) == 0) {
            execve(target.fileSystemRepresentation, arguments, *_NSGetEnviron());
            unsetenv("GAMEKIT_IDENTITY_ROUTED");
        }
        free(arguments); // Failed routing leaves the original Wine launch intact.
    }
}
#endif
