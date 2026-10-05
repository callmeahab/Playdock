#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
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
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(180,180,600,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title=@"Wayfarer background presentation test";
        [window makeKeyAndOrderFront:nil];
        struct proc_bsdinfo process={0}; proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process));
        printf("{\"pid\":%d,\"seconds\":%llu,\"microseconds\":%llu,\"window\":%ld}\n",getpid(),process.pbi_start_tvsec,process.pbi_start_tvusec,(long)window.windowNumber); fflush(stdout);
        __block int ticks=0;
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
            printf("{\"policy\":%ld,\"alpha\":%.2f,\"width\":%.0f,\"height\":%.0f}\n",(long)[NSRunningApplication currentApplication].activationPolicy,window.alphaValue,window.frame.size.width,window.frame.size.height); fflush(stdout);
            if (++ticks>=80) [app terminate:nil];
        }];
        [app run];
    }
    return 0;
}
