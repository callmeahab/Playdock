#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static NSImage *gameDockIcon;
static NSImage *lastDockSource;
static NSMutableDictionary<NSString *, NSValue *> *dockIconMethods;
static IMP dockPolicyMethod;
static BOOL dockHelper;
static BOOL preparedDockIcon;
static _Thread_local BOOL applyingDockIcon;

static NSString *dockProgram(void) {
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        NSString *program = [[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
        if ([program hasSuffix:@".exe"]) return program;
    }
    return @"";
}

static NSImage *roundedDockIcon(NSImage *source) {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    const CGFloat side = 512;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
    [image lockFocus];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, side, side) xRadius:side * 0.2237 yRadius:side * 0.2237] addClip];
    CGFloat scale = MAX(side / source.size.width, side / source.size.height);
    NSSize size = NSMakeSize(source.size.width * scale, source.size.height * scale);
    [source drawInRect:NSMakeRect((side-size.width)/2, (side-size.height)/2, size.width, size.height)
             fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [image unlockFocus];
    return image;
}

static IMP dockOriginalIcon(id app) {
    for (Class cls = object_getClass(app); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = dockIconMethods[NSStringFromClass(cls)];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void setGameDockIcon(id app, SEL selector, NSImage *image) {
    IMP original = applyingDockIcon ? (IMP)dockIconMethods[NSStringFromClass(NSApplication.class)].pointerValue : dockOriginalIcon(app);
    if (!original) return;
    if (!preparedDockIcon && image && image != lastDockSource && image != gameDockIcon) {
        lastDockSource = image;
        gameDockIcon = roundedDockIcon(image);
    }
    BOOL wasApplying = applyingDockIcon;
    applyingDockIcon = YES;
    @try { ((void (*)(id, SEL, NSImage *))original)(app, selector, gameDockIcon ?: image); }
    @finally { applyingDockIcon = wasApplying; }
}

static void hookDockIcon(Class cls) {
    Method method = class_getInstanceMethod(cls, @selector(setApplicationIconImage:));
    if (!method || method_getImplementation(method) == (IMP)setGameDockIcon) return;
    dockIconMethods[NSStringFromClass(cls)] = [NSValue valueWithPointer:method_getImplementation(method)];
    class_replaceMethod(cls, @selector(setApplicationIconImage:), (IMP)setGameDockIcon, method_getTypeEncoding(method));
}

static BOOL setDockHelperPolicy(id app, SEL selector, NSApplicationActivationPolicy policy) {
    if (policy == NSApplicationActivationPolicyRegular) policy = NSApplicationActivationPolicyAccessory;
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))dockPolicyMethod)(app, selector, policy);
}

static void dockHelperForeground(id controller, SEL selector, BOOL foreground) {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

static void applyGameDock(void) {
    if (!NSApp) return;
    if (dockHelper) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Class controller = NSClassFromString(@"WineApplicationController");
        SEL selector = NSSelectorFromString(@"transformProcessToForeground:");
        Method method = class_getInstanceMethod(controller, selector);
        if (method) class_replaceMethod(controller, selector, (IMP)dockHelperForeground, method_getTypeEncoding(method));
        return;
    }
    hookDockIcon(NSApp.class);
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp setApplicationIconImage:gameDockIcon ?: NSApp.applicationIconImage];
}

__attribute__((constructor)) static void initializeGameDock(void) {
    const char *path = getenv("PLAYDOCK_STEAM_DOCK_ICON");
    const char *presentation = getenv("PLAYDOCK_GAME_PRESENTATION");
    if (!path && (!presentation || strcmp(presentation, "native"))) return;
    NSString *program = dockProgram();
    if (![program hasSuffix:@".exe"]) return;
    dockHelper = [@[@"steam.exe", @"steamwebhelper.exe", @"steamservice.exe", @"steamerrorreporter.exe", @"explorer.exe",
        @"services.exe", @"winedevice.exe", @"wineboot.exe", @"rpcss.exe", @"plugplay.exe", @"svchost.exe",
        @"winemenubuilder.exe", @"conhost.exe"] containsObject:program];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (dockHelper) {
            Method policy = class_getInstanceMethod(NSApplication.class, @selector(setActivationPolicy:));
            dockPolicyMethod = method_getImplementation(policy);
            class_replaceMethod(NSApplication.class, @selector(setActivationPolicy:), (IMP)setDockHelperPolicy, method_getTypeEncoding(policy));
        } else {
            if (path) {
                NSString *file = @(path);
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
                if (file.isAbsolutePath && [file.pathExtension isEqualToString:@"icns"] && [attributes[NSFileSize] unsignedLongLongValue] <= 4 * 1024 * 1024)
                    gameDockIcon = [[NSImage alloc] initWithContentsOfFile:file];
                preparedDockIcon = gameDockIcon != nil;
            }
            dockIconMethods = [NSMutableDictionary new];
            hookDockIcon(NSApplication.class);
        }
        applyGameDock();
        for (NSNotificationName name in @[NSApplicationDidFinishLaunchingNotification, NSApplicationDidBecomeActiveNotification, NSWindowDidBecomeMainNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { applyGameDock(); }];
    });
}
