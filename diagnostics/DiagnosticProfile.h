#pragma once
// Diagnostic-only JSON configuration. Overrides select a file, never game rules.
#import <Foundation/Foundation.h>
#include <stdlib.h>
static inline NSDictionary *GamekitDiagnosticParameters(NSString *key) {
    const char *override = getenv("GAMEKIT_DIAGNOSTIC_PROFILE");
    NSString *path = override ? [NSString stringWithUTF8String:override] : nil;
#ifdef GAMEKIT_DIAGNOSTIC_PROFILE_PATH
    if (!path) path = @GAMEKIT_DIAGNOSTIC_PROFILE_PATH;
#else
    if (!path) path = [[[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"profiles"] stringByAppendingPathComponent:@"games.json"];
#endif
    if (![path isAbsolutePath]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:NULL];
    if (!data || data.length > 32768) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    id schema = root[@"schemaVersion"];
    if (![schema isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)schema) == CFBooleanGetTypeID() || ![schema isEqual:@1]) return nil;
    id value = root[key];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static inline BOOL GamekitDiagnosticMatches(NSString *key, NSString *appID, NSString *image) {
    NSDictionary *parameters = GamekitDiagnosticParameters(key);
    if (!parameters || (appID && ![[parameters[@"appId"] description] isEqual:appID])) return NO;
    NSString *name = [[image stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
    id exact = parameters[@"executable"], prefix = parameters[@"executablePrefix"];
    return ([exact isKindOfClass:NSString.class] && [name isEqual:[exact lowercaseString]]) ||
        ([prefix isKindOfClass:NSString.class] && [prefix length] && [name hasPrefix:[prefix lowercaseString]]);
}
