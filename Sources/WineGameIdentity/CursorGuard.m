#import <AppKit/AppKit.h>
#import <objc/runtime.h>

/* Opt-in cursor selection in the matched managed game process only. Wine sets
 * NSCursor itself, so an unrelated host process cannot suppress its cursor.
 * AppKit in other apps remains unaffected; the real cursor returns on focus loss. */
static NSCursor *guardCursor;
static IMP originalSetCursor;

static void GuardedSetCursor(NSCursor *cursor, SEL selector) {
    NSCursor *replacement = guardCursor && NSApp.isActive && NSApp.keyWindow ? guardCursor : cursor;
    ((void (*)(id, SEL))originalSetCursor)(replacement, selector);
}

void GamekitStartCursorGuard(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (originalSetCursor) return;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:4 bitsPerPixel:32];
        if (!bitmap || !bitmap.bitmapData) return;
        memset(bitmap.bitmapData, 0, 4);
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        [image addRepresentation:bitmap];
        guardCursor = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
        Method method = class_getInstanceMethod(NSCursor.class, @selector(set));
        if (!guardCursor || !method) return;
        // Publish the fallback before installing the hook: another thread may
        // set a cursor as soon as the implementation is exchanged.
        originalSetCursor = method_getImplementation(method);
        method_setImplementation(method, (IMP)GuardedSetCursor);
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [guardCursor set]; }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [guardCursor set]; }];
        [guardCursor set];
    });
}
