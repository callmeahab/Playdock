#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <libproc.h>
#import <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>

// Apply presentation hooks only to Steam/helpers; games may inherit the injection variable.
static NSString *backendDirectory;
static NSDictionary *presentation;
static IMP backendPolicy, backendOrder, backendAlpha, backendActivate, backendForeground;
static BOOL applyingBackendWindow;

static BOOL isSteamBackendProcess(void) {
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    for (NSString *argument in arguments) {
        NSString *name=[[[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent] lowercaseString];
        if ([name hasSuffix:@".exe"])
            return [@[@"steam.exe",@"steamwebhelper.exe",@"steamerrorreporter.exe"] containsObject:name];
    }
    NSString *name=arguments.firstObject.lastPathComponent.lowercaseString;
    return [@[@"steam_osx",@"steam helper"] containsObject:name];
}

static void backendHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return;
    *original=method_getImplementation(method);
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
}

static NSDictionary *backendHost(void) {
    if (!presentation) return nil;
    pid_t pid=[presentation[@"pid"] intValue];
    struct proc_bsdinfo info={0};
    if (proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info)) != sizeof(info) ||
        info.pbi_start_tvsec != [presentation[@"seconds"] unsignedLongLongValue] ||
        info.pbi_start_tvusec != [presentation[@"microseconds"] unsignedLongLongValue]) return nil;
    CGWindowID number=[presentation[@"window"] unsignedIntValue];
    NSArray *items=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,number));
    NSDictionary *host=items.firstObject;
    return [host[(id)kCGWindowOwnerPID] intValue]==pid && [host[(id)kCGWindowIsOnscreen] boolValue] ? host : nil;
}

static void applyBackendWindow(NSWindow *window) {
    if (applyingBackendWindow || !backendAlpha) return;
    applyingBackendWindow=YES;
    NSDictionary *host=backendHost();
    ((void(*)(id,SEL,CGFloat))backendAlpha)(window,@selector(setAlphaValue:),host ? 1 : 0);
    window.ignoresMouseEvents=host == nil;
    if (host && backendOrder) {
        CGRect bounds;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)host[(id)kCGWindowBounds],&bounds)) {
            CGFloat top=NSScreen.screens.firstObject.frame.size.height;
            NSRect frame=NSMakeRect(bounds.origin.x+24,top-bounds.origin.y-bounds.size.height+52,
                                   MAX(300,bounds.size.width-48),MAX(240,bounds.size.height-132));
            if (!NSEqualRects(window.frame,frame)) [window setFrame:frame display:NO];
        }
        window.level=NSNormalWindowLevel;
        if (window.isVisible) ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))backendOrder)(window,@selector(orderWindow:relativeTo:),NSWindowBelow,[presentation[@"window"] integerValue]);
    }
    applyingBackendWindow=NO;
}

static BOOL backendSetPolicy(id self,SEL cmd,NSApplicationActivationPolicy policy) {
    return ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))backendPolicy)(self,cmd,NSApplicationActivationPolicyAccessory);
}
static void backendSetAlpha(NSWindow *self,SEL cmd,CGFloat alpha) {
    if (applyingBackendWindow) { ((void(*)(id,SEL,CGFloat))backendAlpha)(self,cmd,alpha); return; }
    applyBackendWindow(self);
}
static void backendOrderWindow(NSWindow *self,SEL cmd,NSWindowOrderingMode mode,NSInteger relative) {
    if (NSApp && backendPolicy) ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))backendPolicy)(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory);
    applyBackendWindow(self); // Suppress a window before its first orderFront.
    if (mode != NSWindowOut && backendHost()) { mode=NSWindowBelow; relative=[presentation[@"window"] integerValue]; }
    ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))backendOrder)(self,cmd,mode,relative);
}
static void backendActivateApplication(id self,SEL cmd,BOOL flag) { /* The host owns foreground activation. */ }
static void backendTransformForeground(id self,SEL cmd) {
    if (NSApp && backendPolicy) ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))backendPolicy)(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory);
}

static OSStatus backendTransformProcess(const ProcessSerialNumber *psn,ProcessApplicationTransformState state) {
    // Use dyld's original reference; dlsym can recurse into the interposer under AppKit's lock.
    return TransformProcessType(psn,backendDirectory ? kProcessTransformToUIElementApplication : state);
}
__attribute__((used)) static struct { const void *replacement; const void *original; } backendTransformInterpose
    __attribute__((section("__DATA,__interpose")))={ (const void *)backendTransformProcess,(const void *)TransformProcessType };

static void backendTick(void) {
    NSData *data=[NSData dataWithContentsOfFile:[backendDirectory stringByAppendingPathComponent:@"presentation.json"]];
    presentation=data.length<4096 ? [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil] : nil;
    if (![presentation isKindOfClass:NSDictionary.class]) presentation=nil;
    if (!NSApp) return;
    if (backendPolicy) ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))backendPolicy)(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory);
    if (!backendForeground && [NSApp respondsToSelector:NSSelectorFromString(@"transformProcessToForeground")])
        backendHook(NSApp.class,NSSelectorFromString(@"transformProcessToForeground"),(IMP)backendTransformForeground,&backendForeground);
    for (NSWindow *window in NSApp.windows) applyBackendWindow(window);
}

__attribute__((constructor)) static void initializeSteamBackend(void) {
    const char *directory=getenv("WAYFARER_STEAM_BACKEND");
    if (!directory || !isSteamBackendProcess()) return;
    struct stat info;
    if (stat(directory,&info) || !S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 077) != 0) return;
    backendDirectory=@(directory);
    backendHook(NSApplication.class,@selector(setActivationPolicy:),(IMP)backendSetPolicy,&backendPolicy);
    backendHook(NSApplication.class,@selector(activateIgnoringOtherApps:),(IMP)backendActivateApplication,&backendActivate);
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
