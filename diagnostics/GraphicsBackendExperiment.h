// Compile-time-only qualification knobs, never included in the packaged helper.
// -include this file and define GAMEKIT_RENDERER_EXPERIMENT and the quoted
// GAMEKIT_RENDERER_LOG_PATH (a pre-created Windows Z:/ path).
#import <Foundation/Foundation.h>
#include <stdlib.h>
static void GamekitRendererExperiment(NSString *backend, NSString *appID) {
    // Windows children inherit Steam's Windows environment, not the later
    // native constructor's getenv state. Publish the private log directory
    // at owned Steam startup too; MVK options below remain native/game-scoped.
    setenv("DXVK_LOG_PATH", GAMEKIT_RENDERER_LOG_PATH, 1);
    setenv("DXVK_LOG_LEVEL", "info", 1);
    setenv("DXVK_STATE_CACHE_PATH", GAMEKIT_RENDERER_LOG_PATH, 1);
    setenv("DXMT_LOG_PATH", GAMEKIT_RENDERER_LOG_PATH, 1);
    setenv("DXMT_LOG_LEVEL", "info", 1);
    if ([backend isEqual:@"dxvk"] && [appID isEqual:@"526870"]) {
#ifdef GAMEKIT_MVK_PRECISE
        // Config-only subset of the researched Unreal/MoltenVK workaround.
        // Do not advertise unimplemented features or rewrite shaders.
        setenv("MVK_CONFIG_FAST_MATH_ENABLED", "0", 1);
        setenv("MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE", "1", 1);
#endif
    } else {
        unsetenv("MVK_CONFIG_FAST_MATH_ENABLED"); unsetenv("MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE");
    }
}
