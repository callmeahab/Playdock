#import <Cocoa/Cocoa.h>

@interface DockFixtureApplication : NSApplication
@end
@implementation DockFixtureApplication
- (void)setApplicationIconImage:(NSImage *)image { [super setApplicationIconImage:image]; }
@end

@interface WineApplicationController : NSObject
- (void)transformProcessToForeground:(BOOL)foreground;
@end
@implementation WineApplicationController
- (void)transformProcessToForeground:(BOOL)foreground { [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; }
@end

static NSImage *icon(NSColor *color) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(64,64)];
    [image lockFocus]; [color setFill]; NSRectFill(NSMakeRect(0,0,64,64)); [image unlockFocus];
    return image;
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [DockFixtureApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        app.applicationIconImage = icon(NSColor.redColor);
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) {
            [[[WineApplicationController alloc] init] transformProcessToForeground:YES];
            app.applicationIconImage = getenv("PLAYDOCK_TEST_PREPARED_BASELINE")
                ? [[NSImage alloc] initWithContentsOfFile:@(getenv("PLAYDOCK_STEAM_DOCK_ICON"))] : icon(NSColor.blueColor);
            NSBitmapImageRep *pixels = [[NSBitmapImageRep alloc] initWithData:app.applicationIconImage.TIFFRepresentation];
            NSColor *center = [[pixels colorAtX:pixels.pixelsWide/2 y:pixels.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            NSColor *corner = [pixels colorAtX:0 y:0];
            printf("{\"policy\":%ld,\"red\":%.3f,\"green\":%.3f,\"blue\":%.3f,\"cornerAlpha\":%.3f}\n",(long)app.activationPolicy,center.redComponent,center.greenComponent,center.blueComponent,corner.alphaComponent);
            fflush(stdout); [app terminate:nil];
        }];
        [app run];
    }
}
