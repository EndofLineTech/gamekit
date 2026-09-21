// Compile-time-only qualification knobs, never included in the packaged helper.
// -include this file and define GAMEKIT_RENDERER_EXPERIMENT and the quoted
// GAMEKIT_RENDERER_LOG_PATH (a pre-created Windows Z:/ path).
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include "DiagnosticProfile.h"
static inline void GamekitRendererExperiment(NSString *backend, NSString *appID) {
    // Windows children inherit Steam's Windows environment, not the later
    // native constructor's getenv state. Publish the private log directory
    // at owned Steam startup too; MVK options below remain native/game-scoped.
    setenv("DXVK_LOG_PATH", GAMEKIT_RENDERER_LOG_PATH, 1);
    setenv("DXVK_LOG_LEVEL", "info", 1);
#ifdef GAMEKIT_DXVK_HUD
    setenv("DXVK_HUD", GAMEKIT_DXVK_HUD, 1);
#endif
    setenv("DXVK_STATE_CACHE_PATH", GAMEKIT_RENDERER_LOG_PATH, 1);
    setenv("DXMT_LOG_PATH", GAMEKIT_RENDERER_LOG_PATH, 1);
    setenv("DXMT_LOG_LEVEL", "info", 1);
    NSDictionary *profile = GamekitDiagnosticParameters(@"renderer");
    if ([backend isEqual:profile[@"backend"]] && [[profile[@"appId"] description] isEqual:appID]) {
#ifdef GAMEKIT_MVK_PRECISE
        // Config-only subset of the researched Unreal/MoltenVK workaround.
        // Do not advertise unimplemented features or rewrite shaders.
        NSDictionary *environment = profile[@"environment"];
        for (NSString *key in @[@"MVK_CONFIG_FAST_MATH_ENABLED", @"MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE"]) {
            id value = [environment isKindOfClass:NSDictionary.class] ? environment[key] : nil;
            if ([value isKindOfClass:NSString.class] && ([value isEqual:@"0"] || [value isEqual:@"1"])) setenv(key.UTF8String, [value UTF8String], 1);
            else unsetenv(key.UTF8String);
        }
#endif
    } else {
        unsetenv("MVK_CONFIG_FAST_MATH_ENABLED"); unsetenv("MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE");
    }
}
