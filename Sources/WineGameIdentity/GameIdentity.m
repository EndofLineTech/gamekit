#import <AppKit/AppKit.h>
#include <dlfcn.h>
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

/* Wine rewrites argv to the Windows image. Read only this process's first two
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
    if (!ReadArgument(bytes, length, &offset)) return nil; // Unix image path
    while (offset < length && bytes[offset] == 0) ++offset;
    NSString *first = ReadArgument(bytes, length, &offset);
    NSString *leaf = [[first stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
    if (argc > 1 && [@[@"wine", @"wine64", @"wine-preloader", @"wine64-preloader", @"windows steam"] containsObject:leaf]) {
        return ReadArgument(bytes, length, &offset);
    }
    return first;
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

static NSString *ReadGameName(void) {
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
    return name;
}

#ifdef GAMEKIT_IDENTITY_READER_TEST
int main(void) {
    @autoreleasepool {
        NSString *name = ReadGameName();
        if (name) puts(name.UTF8String);
    }
    return 0;
}
#else
/* Launch Services permits the process itself to update its display name. This
 * macOS-specific SPI is optional: an unavailable symbol leaves Wine's name intact.
 * The helper never changes another process, hides windows or modifies game files. */
static BOOL SetOwnGameName(NSString *name) {
    static void *library;
    static CFTypeRef (*currentASN)(void);
    static OSStatus (*setItem)(int, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        library = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY);
        if (!library) return;
        currentASN = dlsym(library, "_LSGetCurrentApplicationASN");
        if (!currentASN) currentASN = dlsym(library, "_LSASNGetCurrentApplicationASN");
        setItem = dlsym(library, "_LSSetApplicationInformationItem");
    });
    if (!currentASN || !setItem) return NO;
    CFTypeRef asn = currentASN();
    return asn && setItem(-2, asn, CFSTR("LSDisplayName"), (__bridge CFStringRef)name, NULL) == noErr;
}

static void TryGameIdentity(CFAbsoluteTime deadline) {
    @autoreleasepool {
        if (NSApp && NSApp.activationPolicy == NSApplicationActivationPolicyRegular) {
            NSString *name = ReadGameName();
            if (name && SetOwnGameName(name)) return;
        }
        if (CFAbsoluteTimeGetCurrent() >= deadline) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            TryGameIdentity(deadline);
        });
    }
}

__attribute__((constructor)) static void GameIdentityStart(void) {
    @autoreleasepool {
        // SteamAppId can be absent in the native Wine environment; a Windows
        // image under an installed game directory is the fallback identity.
        if (!getenv("GAMEKIT_GAME_NAMES_FILE") || !getenv("GAMEKIT_SESSION_ID")) return;
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 120;
        dispatch_async(dispatch_get_main_queue(), ^{ TryGameIdentity(deadline); });
    }
}
#endif
