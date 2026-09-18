// Diagnostic-only: a native fullscreen host carries the original full-display
// Wine game window as an auxiliary window, preserving the game's own dimensions.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <crt_externs.h>

@interface GamekitSpaceHost : NSObject <NSWindowDelegate>
@property(strong) NSWindow *host;
@property(weak) NSWindow *game;
@property NSWindowCollectionBehavior originalBehavior;
@end

@implementation GamekitSpaceHost
- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
    return (options & ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideToolbar)) |
        NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
}
- (void)windowDidEnterFullScreen:(NSNotification *)note {
    NSWindow *game = self.game;
    if (!game || !game.visible) { [self.host toggleFullScreen:nil]; return; }
    game.collectionBehavior = (game.collectionBehavior | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace) &
        ~(NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorCanJoinAllSpaces);
    [game makeKeyAndOrderFront:nil];
    os_log(OS_LOG_DEFAULT, "GamekitSpaceHost entered host=%{public}@ game=%{public}@", NSStringFromRect(self.host.frame), NSStringFromRect(game.frame));
    __block NSUInteger samples = 0;
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        if (++samples > 45) { [timer invalidate]; return; }
        for (NSWindow *window in NSApp.windows) {
            if (window == self.host || [NSStringFromClass(window.class) isEqualToString:@"WineWindow"])
                os_log(OS_LOG_DEFAULT, "GamekitSpaceHost state host=%{public}d number=%{public}ld visible=%{public}d activeSpace=%{public}d key=%{public}d frame=%{public}@ behavior=%{public}lu", window == self.host, (long)window.windowNumber, window.visible, window.onActiveSpace, window.keyWindow, NSStringFromRect(window.frame), (unsigned long)window.collectionBehavior);
        }
    }];
}
- (void)windowDidExitFullScreen:(NSNotification *)note {
    NSWindow *game = self.game;
    game.collectionBehavior = self.originalBehavior;
    [self.host orderOut:nil];
    if (game.visible) [game makeKeyAndOrderFront:nil];
    os_log(OS_LOG_DEFAULT, "GamekitSpaceHost exited game=%{public}@", NSStringFromRect(game.frame));
}
@end

static const char associationKey;
__attribute__((constructor)) static void StartFullscreenHostTrial(void) {
    @autoreleasepool {
        if (!getenv("GAMEKIT_SESSION_ID") || !getenv("WINEPREFIX")) return;
        BOOL helldivers = NO;
        char **arguments = *_NSGetArgv();
        for (int i = 0; i < *_NSGetArgc() && i < 3; ++i) {
            NSString *argument = [NSString stringWithUTF8String:arguments[i]];
            if ([argument hasPrefix:@"-"]) continue;
            NSString *name = [[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
            if ([name.lowercaseString hasSuffix:@".exe"]) {
                helldivers = [name.lowercaseString isEqualToString:@"helldivers2.exe"];
                break;
            }
        }
        if (!helldivers) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __block NSUInteger attempts = 0;
            [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
                if (++attempts > 90) { [timer invalidate]; return; }
                for (NSWindow *game in NSApp.windows) {
                    if (![NSStringFromClass(game.class) isEqualToString:@"WineWindow"] || !game.visible || game.parentWindow || !game.screen) continue;
                    NSRect content = [game contentRectForFrameRect:game.frame];
                    if (!NSContainsRect(content, game.screen.frame)) continue;
                    GamekitSpaceHost *manager = [GamekitSpaceHost new];
                    manager.game = game; manager.originalBehavior = game.collectionBehavior;
                    manager.host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
                    manager.host.title = @"Gamekit fullscreen Space";
                    manager.host.backgroundColor = NSColor.blackColor;
                    manager.host.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
                    manager.host.delegate = manager;
                    objc_setAssociatedObject(game, &associationKey, manager, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [manager.host orderFront:nil];
                    [manager.host toggleFullScreen:nil];
                    os_log(OS_LOG_DEFAULT, "GamekitSpaceHost requested for game=%{public}@", NSStringFromRect(game.frame));
                    [timer invalidate];
                    return;
                }
            }];
        });
    }
}
