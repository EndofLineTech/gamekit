// Diagnostic-only helper, linked into a separate local test package.
// Helldivers must be windowed; no aspect-ratio or game-rendering hooks are used.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <crt_externs.h>

@interface GamekitSpaceTrialDelegate : NSObject <NSWindowDelegate>
@property(weak) id<NSWindowDelegate> original;
@end

@implementation GamekitSpaceTrialDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.original respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector { return self.original; }
- (NSSize)window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposed {
    NSSize original = proposed;
    if ([self.original respondsToSelector:_cmd]) original = [self.original window:window willUseFullScreenContentSize:proposed];
    NSSize requested = window.screen ? window.screen.frame.size : original;
    os_log(OS_LOG_DEFAULT, "GamekitSpaceTrial size proposed=%{public}@ original=%{public}@ requested=%{public}@", NSStringFromSize(proposed), NSStringFromSize(original), NSStringFromSize(requested));
    return requested;
}
- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
    if ([self.original respondsToSelector:_cmd])
        options = [self.original window:window willUseFullScreenPresentationOptions:options];
    options &= ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideToolbar);
    return options | NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    if ([self.original respondsToSelector:_cmd]) [self.original windowDidEnterFullScreen:notification];
    NSWindow *window = notification.object;
    os_log(OS_LOG_DEFAULT, "GamekitSpaceTrial entered native fullscreen frame=%{public}@ presentation=%{public}lu", NSStringFromRect(window.frame), (unsigned long)NSApp.presentationOptions);
}
- (void)windowDidExitFullScreen:(NSNotification *)notification {
    if ([self.original respondsToSelector:_cmd]) [self.original windowDidExitFullScreen:notification];
    NSWindow *window = notification.object;
    os_log(OS_LOG_DEFAULT, "GamekitSpaceTrial exited native fullscreen frame=%{public}@", NSStringFromRect(window.frame));
}
@end

static const char associationKey;

__attribute__((constructor)) static void StartNativeSpaceTrial(void) {
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
                for (NSWindow *window in NSApp.windows) {
                    if (![NSStringFromClass(window.class) isEqualToString:@"WineWindow"] || !window.visible || window.parentWindow) continue;
                    NSRect content = [window contentRectForFrameRect:window.frame];
                    if (content.size.width < 800 || content.size.height < 450 || !(window.styleMask & NSWindowStyleMaskResizable)) continue;
                    if (!(window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) || (window.styleMask & NSWindowStyleMaskFullScreen)) continue;
                    GamekitSpaceTrialDelegate *proxy = [GamekitSpaceTrialDelegate new];
                    proxy.original = window.delegate;
                    objc_setAssociatedObject(window, &associationKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    window.delegate = proxy;
                    os_log(OS_LOG_DEFAULT, "GamekitSpaceTrial requesting native fullscreen frame=%{public}@", NSStringFromRect(window.frame));
                    [window toggleFullScreen:nil];
                    [timer invalidate];
                    return;
                }
            }];
        });
    }
}
