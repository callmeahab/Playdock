#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
@interface FixtureWindow : NSWindow
@end
@implementation FixtureWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        fprintf(stderr,"fixture: main\n");
        NSApplication *app=[NSApplication sharedApplication];
        fprintf(stderr,"fixture: application\n");
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        fprintf(stderr,"fixture: policy\n");
        ProcessSerialNumber psn={0,kCurrentProcess};
        TransformProcessType(&psn,kProcessTransformToForegroundApplication);
        fprintf(stderr,"fixture: transform\n");
        NSWindow *window=[[FixtureWindow alloc] initWithContentRect:NSMakeRect(180,180,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title=@"Playdock background presentation test";
        [window makeKeyAndOrderFront:nil];
        struct proc_bsdinfo process={0}; proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process));
        printf("{\"pid\":%d,\"seconds\":%llu,\"microseconds\":%llu,\"window\":%ld}\n",getpid(),process.pbi_start_tvsec,process.pbi_start_tvusec,(long)window.windowNumber); fflush(stdout);
        __block int ticks=0;
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            [app activateIgnoringOtherApps:YES];
            [window setAlphaValue:1];
            [window makeMainWindow];
            [window makeKeyAndOrderFront:nil];
            printf("{\"policy\":%ld,\"alpha\":%.2f,\"visible\":%d,\"key\":%d,\"main\":%d,\"ignoresMouse\":%d,\"canKey\":%d,\"canMain\":%d}\n",(long)[NSRunningApplication currentApplication].activationPolicy,window.alphaValue,window.isVisible,window.isKeyWindow,window.isMainWindow,window.ignoresMouseEvents,window.canBecomeKeyWindow,window.canBecomeMainWindow); fflush(stdout);
            if (++ticks>=80) [app terminate:nil];
        }];
        [app run];
    }
    return 0;
}
