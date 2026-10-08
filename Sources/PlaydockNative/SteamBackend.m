#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <libproc.h>
#import <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>

// Apply presentation hooks only to Steam/helpers; games may inherit the injection variable.
static NSString *backendDirectory;
static IMP backendPolicy, backendOrder, backendAlpha;
static BOOL applyingBackendWindow;

static BOOL isSteamBackendProcess(void) {
    NSString *name=NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent.lowercaseString;
    return [@[@"steam_osx",@"steam helper"] containsObject:name];
}

static void backendHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method || method_getImplementation(method)==replacement) return;
    if (original) *original=method_getImplementation(method);
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
}
static BOOL backendCannotFocus(id self,SEL cmd) { return NO; }
static void backendIgnoreActivation(id self,SEL cmd,BOOL flag) {}
static void backendIgnoreForeground(id self,SEL cmd) {}
static void backendIgnoreKeyWindow(id self,SEL cmd) {}
static void backendIgnoreKeyAndFront(id self,SEL cmd,id sender) {}

static void applyBackendWindow(NSWindow *window) {
    if (applyingBackendWindow || !backendAlpha) return;
    applyingBackendWindow=YES;
    // Steam's CEF subclasses can override the base window's focus methods.
    backendHook(window.class,@selector(canBecomeKeyWindow),(IMP)backendCannotFocus,NULL);
    backendHook(window.class,@selector(canBecomeMainWindow),(IMP)backendCannotFocus,NULL);
    backendHook(window.class,@selector(makeKeyWindow),(IMP)backendIgnoreKeyWindow,NULL);
    backendHook(window.class,@selector(makeMainWindow),(IMP)backendIgnoreKeyWindow,NULL);
    backendHook(window.class,@selector(makeKeyAndOrderFront:),(IMP)backendIgnoreKeyAndFront,NULL);
    if (window.alphaValue!=0) ((void(*)(id,SEL,CGFloat))backendAlpha)(window,@selector(setAlphaValue:),0);
    window.ignoresMouseEvents=YES;
    if (window.isVisible && backendOrder) ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))backendOrder)(window,@selector(orderWindow:relativeTo:),NSWindowOut,0);
    applyingBackendWindow=NO;
}
static BOOL backendSetPolicy(id self,SEL cmd,NSApplicationActivationPolicy policy) {
    return ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))backendPolicy)(self,cmd,NSApplicationActivationPolicyProhibited);
}
static void backendSetAlpha(NSWindow *self,SEL cmd,CGFloat alpha) { applyBackendWindow(self); }
static void backendOrderWindow(NSWindow *self,SEL cmd,NSWindowOrderingMode mode,NSInteger relative) {
    applyBackendWindow(self);
    ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))backendOrder)(self,cmd,NSWindowOut,0);
}

static OSStatus backendTransformProcess(const ProcessSerialNumber *psn,ProcessApplicationTransformState state) {
    // Use dyld's original reference; dlsym can recurse into the interposer under AppKit's lock.
    return TransformProcessType(psn,backendDirectory ? kProcessTransformToBackgroundApplication : state);
}
__attribute__((used)) static struct { const void *replacement; const void *original; } backendTransformInterpose
    __attribute__((section("__DATA,__interpose")))={ (const void *)backendTransformProcess,(const void *)TransformProcessType };

static void backendTick(void) {
    if (!NSApp) return;
    if (NSApp.activationPolicy!=NSApplicationActivationPolicyProhibited && backendPolicy)
        ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))backendPolicy)(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyProhibited);
    backendHook(NSApp.class,NSSelectorFromString(@"transformProcessToForeground"),(IMP)backendIgnoreForeground,NULL);
    for (NSWindow *window in NSApp.windows) applyBackendWindow(window);
    if (NSApp.isActive) [NSApp deactivate];
}

__attribute__((constructor)) static void initializeSteamBackend(void) {
    const char *directory=getenv("PLAYDOCK_STEAM_BACKEND");
    if (!directory || !isSteamBackendProcess()) return;
    struct stat info;
    if (stat(directory,&info) || !S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 077) != 0) return;
    backendDirectory=@(directory);
    backendHook(NSApplication.class,@selector(setActivationPolicy:),(IMP)backendSetPolicy,&backendPolicy);
    backendHook(NSApplication.class,@selector(activateIgnoringOtherApps:),(IMP)backendIgnoreActivation,NULL);
    backendHook(NSApplication.class,NSSelectorFromString(@"activate"),(IMP)backendIgnoreForeground,NULL);
    backendHook(NSWindow.class,@selector(canBecomeKeyWindow),(IMP)backendCannotFocus,NULL);
    backendHook(NSWindow.class,@selector(canBecomeMainWindow),(IMP)backendCannotFocus,NULL);
    backendHook(NSWindow.class,@selector(makeKeyWindow),(IMP)backendIgnoreKeyWindow,NULL);
    backendHook(NSWindow.class,@selector(makeMainWindow),(IMP)backendIgnoreKeyWindow,NULL);
    backendHook(NSWindow.class,@selector(makeKeyAndOrderFront:),(IMP)backendIgnoreKeyAndFront,NULL);
    backendHook(NSWindow.class,@selector(orderWindow:relativeTo:),(IMP)backendOrderWindow,&backendOrder);
    backendHook(NSWindow.class,@selector(setAlphaValue:),(IMP)backendSetAlpha,&backendAlpha);
    struct proc_bsdinfo process={0};
    if (proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process)) == sizeof(process)) {
        Dl_info image={0}; dladdr((const void *)&initializeSteamBackend,&image);
        NSString *path=image.dli_fname ? [@(image.dli_fname) stringByResolvingSymlinksInPath] : @"";
        NSData *binary=[NSData dataWithContentsOfFile:path];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(binary.bytes,(CC_LONG)binary.length,digest);
        NSMutableString *hash=[NSMutableString new]; for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hash appendFormat:@"%02x",digest[i]];
        NSString *token=[NSString stringWithFormat:@"%llu:%llu\n%@\n%@",process.pbi_start_tvsec,process.pbi_start_tvusec,path,hash];
        [token writeToFile:[backendDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.ready",getpid()]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    dispatch_async(dispatch_get_main_queue(),^{
        backendTick();
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { backendTick(); }];
    });
}
