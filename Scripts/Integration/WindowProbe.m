#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        int pid = atoi(argv[1]); if (pid <= 0) return 2;
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        fprintf(stdout,"POLICY=%ld\n",(long)(app ? app.activationPolicy : NSApplicationActivationPolicyProhibited));
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        for (NSDictionary *w in windows) {
            if ([w[(id)kCGWindowOwnerPID] intValue] != pid || [w[(id)kCGWindowLayer] intValue] != 0) continue;
            CGRect frame; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&frame);
            if (frame.size.width < 50 || frame.size.height < 50) continue;
            fprintf(stdout,"WINDOW=%u ALPHA=%.2f ONSCREEN=%d SIZE=%.0fx%.0f\n",[w[(id)kCGWindowNumber] unsignedIntValue],[w[(id)kCGWindowAlpha] doubleValue],[w[(id)kCGWindowIsOnscreen] boolValue],frame.size.width,frame.size.height);
        }
    }
}
