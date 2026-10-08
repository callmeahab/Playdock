#import <Cocoa/Cocoa.h>

@interface WineWindow : NSWindow
@end
@implementation WineWindow
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        WineWindow *game = [[WineWindow alloc] initWithContentRect:NSMakeRect(100,100,800,600)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        NSView *content = game.contentView;
        game.title = @"Native tracking fixture";
        [game orderFront:nil];
        NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(950,100,200,100)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        [other makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSString *done = @(getenv("PLAYDOCK_PROBE_DONE"));
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (![NSFileManager.defaultManager fileExistsAtPath:done]) return;
            [game orderOut:nil];
            [game makeKeyAndOrderFront:nil];
            BOOL intact = game.isVisible && game.alphaValue == 1 && !game.ignoresMouseEvents &&
                game.contentView == content && !content.wantsLayer && NSApp.activationPolicy == NSApplicationActivationPolicyRegular;
            fprintf(stdout,"%s\n",intact ? "NATIVE_WINDOW_INTACT" : "NATIVE_WINDOW_CHANGED"); fflush(stdout);
            exit(intact ? 0 : 4);
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        [NSApp run];
    }
}
