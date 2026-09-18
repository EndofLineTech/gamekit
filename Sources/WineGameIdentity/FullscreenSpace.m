#import <AppKit/AppKit.h>
#import <objc/runtime.h>

extern BOOL GamekitShouldUseFullscreenSpace(void);

// Wine assumes a native parent is another WineWindow. Never parent its window
// to this AppKit host: use auxiliary/active-Space placement instead.
@interface GamekitFullscreenSpace : NSObject <NSWindowDelegate>
@property(strong) NSWindow *host;
@property(weak) NSWindow *game;
@property NSWindowCollectionBehavior originalBehavior;
@property(strong) NSTimer *watch;
@property BOOL entering;
@property BOOL closing;
@property NSUInteger hiddenSamples;
@end

@implementation GamekitFullscreenSpace
- (void)finish {
    [self.watch invalidate]; self.watch = nil;
    NSWindow *game = self.game;
    game.collectionBehavior = self.originalBehavior;
    self.host.delegate = nil;
    [self.host orderOut:nil]; [self.host close]; self.host = nil;
    if (game.visible && NSApp.active) [game makeKeyAndOrderFront:nil];
}
- (void)requestClose {
    if (self.closing) return;
    self.closing = YES;
    if (self.entering) return; // Complete AppKit's transition before reversing it.
    if (self.host.styleMask & NSWindowStyleMaskFullScreen) [self.host toggleFullScreen:nil];
    else [self finish];
}
- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
    return (options & ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideToolbar)) |
        NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
}
- (void)windowDidEnterFullScreen:(NSNotification *)note {
    self.entering = NO;
    NSWindow *game = self.game;
    if (self.closing || !game || !game.visible) {
        self.closing = YES;
        [self.host toggleFullScreen:nil];
        return;
    }
    game.collectionBehavior = (game.collectionBehavior | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace) &
        ~(NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorCanJoinAllSpaces);
    [game makeKeyAndOrderFront:nil];
    __weak GamekitFullscreenSpace *weakSelf = self;
    self.watch = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        GamekitFullscreenSpace *owner = weakSelf;
        if (!owner) { [timer invalidate]; return; }
        // Wine may hide/minimize its exclusive window while Command-Tab moves
        // away. That is suspension, not a request to destroy the native Space.
        if (!owner.game) { [owner requestClose]; return; }
        if (owner.game.visible || !NSApp.active || NSApp.hidden || owner.game.miniaturized) owner.hiddenSamples = 0;
        else if (++owner.hiddenSamples >= 5) [owner requestClose];
    }];
}
- (void)windowDidExitFullScreen:(NSNotification *)note { [self finish]; }
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window { self.entering = NO; [self finish]; }
- (void)windowDidFailToExitFullScreen:(NSWindow *)window { [self finish]; }
- (void)startWithGame:(NSWindow *)game {
    self.game = game; self.originalBehavior = game.collectionBehavior;
    self.host = [[NSWindow alloc] initWithContentRect:NSMakeRect(NSMinX(game.screen.frame), NSMinY(game.screen.frame), 800, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.host.releasedWhenClosed = NO;
    self.host.title = @"Gamekit fullscreen Space";
    self.host.backgroundColor = NSColor.blackColor;
    self.host.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.host.delegate = self;
    self.entering = YES;
    [self.host orderFront:nil]; [self.host toggleFullScreen:nil];
}
- (void)dealloc {
    [_watch invalidate];
    // Wine also emits "close" while temporarily ordering a minimized window
    // out. Object lifetime, rather than that notification, ends ownership.
    NSWindow *orphan = _host;
    orphan.delegate = nil;
    if (orphan) dispatch_async(dispatch_get_main_queue(), ^{ [orphan orderOut:nil]; [orphan close]; });
}
@end

static const char associationKey;
__attribute__((constructor)) static void StartGamekitFullscreenSpace(void) {
    @autoreleasepool {
        if (!GamekitShouldUseFullscreenSpace()) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __block NSUInteger attempts = 0;
            [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
                if (++attempts > 90) { [timer invalidate]; return; }
                for (NSWindow *game in NSApp.windows) {
                    if (![NSStringFromClass(game.class) isEqualToString:@"WineWindow"] || !game.visible || game.parentWindow || !game.screen) continue;
                    if (game.styleMask & NSWindowStyleMaskFullScreen) continue;
                    NSRect content = [game contentRectForFrameRect:game.frame];
                    if (!NSContainsRect(content, game.screen.frame)) continue;
                    GamekitFullscreenSpace *manager = [GamekitFullscreenSpace new];
                    objc_setAssociatedObject(game, &associationKey, manager, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [manager startWithGame:game];
                    [timer invalidate];
                    return;
                }
            }];
        });
    }
}
