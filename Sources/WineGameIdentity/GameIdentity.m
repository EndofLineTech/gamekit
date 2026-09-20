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

static NSDictionary *ReadSessionDocument(void) {
    NSString *prefix = EnvironmentString("WINEPREFIX");
    NSString *session = EnvironmentString("GAMEKIT_SESSION_ID");
    if (!prefix.length || !session.length || ![[NSUUID alloc] initWithUUIDString:session]) return nil;
    NSData *data = ReadMapping(EnvironmentString("GAMEKIT_GAME_NAMES_FILE"));
    if (!data) return nil;
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![document isKindOfClass:NSDictionary.class]) return nil;
    id schema = document[@"schemaVersion"];
    if (![schema isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)schema) == CFBooleanGetTypeID() || ![schema isEqual:@1] ||
        ![document[@"prefix"] isEqual:prefix] || ![document[@"sessionID"] isEqual:session]) return nil;
    id games = document[@"games"];
    if (![games isKindOfClass:NSDictionary.class] || [games count] > 512) return nil;
    return document;
}

/* Resolve the actual image, not an inherited AppID that may belong to a parent
 * game. This also handles Wine launches whose native environment has no AppID. */
static NSString *ImageAppID(NSDictionary *document) {
    id directories = document[@"directories"];
    if (![directories isKindOfClass:NSDictionary.class] || [directories count] > 512) return nil;
    NSString *image = [WindowsImage() stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
    NSString *unixBase = [EnvironmentString("WINEPREFIX") stringByAppendingString:@"/drive_c/"];
    if ([image hasPrefix:unixBase]) image = [@"c:\\" stringByAppendingString:[image substringFromIndex:unixBase.length]];
    image = [image stringByReplacingOccurrencesOfString:@"/" withString:@"\\"].lowercaseString;
    NSArray *parts = [image componentsSeparatedByString:@"\\"];
    if (!([image hasPrefix:@"c:\\"] || [image hasPrefix:@"z:\\"]) || ![image hasSuffix:@".exe"] || [parts containsObject:@".."] || [parts containsObject:@"."] ||
        [image rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSString *found = nil;
    for (id key in directories) {
        id directory = directories[key];
        if (![CanonicalAppID(key) isEqual:key] || ![directory isKindOfClass:NSString.class]) continue;
        NSString *path = [directory lowercaseString];
        NSArray *components = [path componentsSeparatedByString:@"\\"];
        if (!([path hasPrefix:@"c:\\"] || [path hasPrefix:@"z:\\"]) || ![path hasSuffix:@"\\"] || [components count] < 3 ||
            [components containsObject:@".."] || [components containsObject:@"."] ||
            [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) continue;
        if ([image hasPrefix:path]) {
            if (found) return nil;
            found = key;
        }
    }
    return found;
}

static BOOL ValidGraphicsBackend(id value) {
    return [value isKindOfClass:NSString.class] &&
        ( [value isEqual:@"automatic"] || [value isEqual:@"metal3"] || [value isEqual:@"dxmt"] || [value isEqual:@"dxvk"] );
}

static BOOL ValidLibraryPath(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 16384 ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    for (NSString *part in [value componentsSeparatedByString:@":"]) {
        if (![part hasPrefix:@"/"] || [part.pathComponents containsObject:@".."] || [part.pathComponents containsObject:@"."]) return NO;
    }
    return YES;
}

static BOOL ApplyGraphicsBackend(void) {
    NSDictionary *document = ReadSessionDocument();
    id shared = document[@"sharedGraphicsBackend"];
    if (!ValidGraphicsBackend(shared)) return NO;
    NSString *backend = [shared isEqual:@"automatic"] ? @"automatic" : @"metal3";
    NSString *imageID = ImageAppID(document), *advertised = EnvironmentString("SteamAppId");
    id overrides = document[@"graphicsBackends"];
    if (imageID && [document[@"games"][imageID] isKindOfClass:NSString.class] &&
        (!advertised.length || [GameAppID() isEqual:imageID]) &&
        (!overrides || ([overrides isKindOfClass:NSDictionary.class] && [overrides count] <= 512))) {
        backend = shared;
        id chosen = overrides[imageID];
        if (ValidGraphicsBackend(chosen)) backend = chosen;
    }
    // Reset inherited game overrides for Steam/services/unrelated children.
    // Automatic means UNSET, not a guessed Metal 4 flag value.
    if ([backend isEqual:@"metal3"]) setenv("D3DM_MTL4", "0", 1);
    else unsetenv("D3DM_MTL4");
    // Leave the VC++ family and feature-detection DLL loads intact. These
    // backends qualify D3D10/11 only; D3D12 rendering requires an Apple backend.
#ifdef GAMEKIT_RENDERER_EXPERIMENT
    GamekitRendererExperiment(backend, imageID);
#endif
    NSString *base = document[@"defaultLibraryPath"], *cx = document[@"dxvkLibraryPath"];
    if (!ValidLibraryPath(base) || !ValidLibraryPath(cx)) return NO;
    NSString *desired = [backend isEqual:@"dxvk"] ? cx : base;
#ifdef GAMEKIT_MVK_LIBRARY_DIRECTORY
    if ([backend isEqual:@"dxvk"] && [imageID isEqual:@"526870"])
        desired = [[NSString stringWithUTF8String:GAMEKIT_MVK_LIBRARY_DIRECTORY] stringByAppendingFormat:@":%@", base];
#endif
    if ([EnvironmentString("DYLD_FALLBACK_LIBRARY_PATH") isEqual:desired]) return NO;
    // dyld captures its search paths at process startup. The constructor must
    // re-exec even when the correct game's loader is already selected.
    return setenv("DYLD_FALLBACK_LIBRARY_PATH", desired.UTF8String, 1) == 0;
}

static NSString *ReadGameNameWithLoader(NSString **loader, BOOL *fullscreenSpace) {
    if (loader) *loader = nil;
    if (fullscreenSpace) *fullscreenSpace = NO;
    NSString *appID = GameAppID();
    if (!appID && EnvironmentString("SteamAppId").length) return nil;
    NSDictionary *document = ReadSessionDocument();
    if (!document) return nil;
    id games = document[@"games"];
    if (loader && [document[@"defaultLoader"] isKindOfClass:NSString.class]) *loader = document[@"defaultLoader"];
    NSString *imageID = ImageAppID(document);
    if (appID && WindowsImage().length && ![appID isEqual:imageID]) return nil;
    if (!appID) appID = imageID;
    if (!appID) return nil;
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
        if (getenv("GAMEKIT_TEST_BACKEND_SETTING")) {
            ApplyGraphicsBackend();
            if (getenv("GAMEKIT_TEST_DLL_SETTING")) { puts(getenv("WINEDLLOVERRIDES") ?: "unset"); return 0; }
            puts(getenv("D3DM_MTL4") ?: "unset"); return 0;
        }
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
#ifdef GAMEKIT_SAVE_WRITE_GUARD
        void (^guardSaves)(void) = ^{
            extern void GamekitProtectSatisfactorySaves(void);
            NSString *appID = ImageAppID(ReadSessionDocument());
            NSString *image = [[WindowsImage() stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
            if (([appID isEqual:@"526870"] && [image isEqual:@"factorygamesteam-win64-shipping.exe"]) ||
                ([appID isEqual:@"900001"] && [image hasPrefix:@"probe"]))
                GamekitProtectSatisfactorySaves();
        };
#endif
#ifdef GAMEKIT_DEVICE_API_CAPTURE
        extern void GamekitArmDeviceAPICapture(int enabled);
        NSDictionary *captureDocument = ReadSessionDocument();
        NSString *captureID = ImageAppID(captureDocument);
        NSString *captureImage = [[WindowsImage() stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
        GamekitArmDeviceAPICapture(([captureID isEqual:@"553850"] && [captureImage isEqual:@"helldivers2.exe"]) ||
                                  ([captureID isEqual:@"900001"] && [captureImage hasPrefix:@"probe"]));
#endif
        BOOL libraryPathChanged = ApplyGraphicsBackend();
        if (!getenv("GAMEKIT_GAME_NAMES_FILE") || !getenv("GAMEKIT_SESSION_ID")) return;
        NSString *current = CurrentLoaderPath();
        NSString *routed = EnvironmentString("GAMEKIT_IDENTITY_ROUTED");
        if (routed) {
            unsetenv("GAMEKIT_IDENTITY_ROUTED");
            if ([routed isEqual:current]) {
#ifdef GAMEKIT_SAVE_WRITE_GUARD
                guardSaves();
#endif
                return;
            }
        }
        NSString *target = nil;
        (void)ReadGameNameWithLoader(&target, NULL);
        if (!current || !target.length || ([current isEqual:target] && !libraryPathChanged)) {
#ifdef GAMEKIT_SAVE_WRITE_GUARD
            guardSaves();
#endif
            return;
        }
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
