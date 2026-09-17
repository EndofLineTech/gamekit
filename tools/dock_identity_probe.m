#import <AppKit/AppKit.h>
#include <stdio.h>

/* Standalone application used to verify helper loading and process-self naming.
 * It has no game/Wine dependency, touches no user prefix, and exits after 3s. */
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        if (getenv("GAMEKIT_IDENTITY_ROUTED")) return 3;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
        NSString *name = NSRunningApplication.currentApplication.localizedName;
        printf("%s\n", name.UTF8String);
        return [name isEqualToString:[NSString stringWithUTF8String:argv[1]]] ? 0 : 1;
    }
}
