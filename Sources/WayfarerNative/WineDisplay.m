#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <dlfcn.h>
#import <stdatomic.h>
#define GL_SILENCE_DEPRECATION
#import <OpenGL/gl3.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurface.h>

// Resolve private CAContext interfaces at runtime, as Wine's Cocoa driver does.
@interface NSObject (WFRemoteContext)
+ (id)contextWithCGSConnection:(uint32_t)connection options:(NSDictionary *)options;
- (uint32_t)contextId;
- (void)setLayer:(CALayer *)layer;
@end

@interface WFWindow : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic) NSUInteger identifier;
@property(nonatomic, strong) id context;
@property(nonatomic, strong) CALayer *root;
@property(nonatomic, strong) CALayer *glLayer;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL focused;
@property(nonatomic) double order;
@property(nonatomic, copy) NSDictionary *last;
@property(nonatomic) BOOL dirty;
@end
@implementation WFWindow
@end

static NSMutableDictionary<NSNumber *, WFWindow *> *windows;
static int transport = -1;
static _Atomic(bool) connected;
static BOOL restoring;
static BOOL nativeGamePresentation;

// Embed Steam's software view; games need their engine's native GPU drawable and input.
static BOOL shouldPresentNatively(void) {
    const char *mode = getenv("WAYFARER_GAME_PRESENTATION");
    if (!mode || strcmp(mode,"native")) return NO;
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if (![argument.lowercaseString hasSuffix:@".exe"]) continue;
        NSString *program = [[argument stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
        return ![@[@"steam.exe", @"steamwebhelper.exe", @"explorer.exe", @"steamservice.exe", @"steamerrorreporter.exe"] containsObject:program];
    }
    // Keep unknown children on their native display path.
    return YES;
}
static __thread NSWindow *__unsafe_unretained inputWindow;
static NSPoint virtualMouse;
static BOOL hasVirtualMouse;
static dispatch_queue_t writer;
static NSUInteger nextIdentifier;
static IMP originalColorImage;
static IMP originalUpdateLayer;
static IMP originalPolicy, originalForeground;
static NSApplicationActivationPolicy savedPolicy;
static BOOL savedPolicyValid;
static BOOL accessoryApplied;
static id renderActivity;
static BOOL frameChanged;
static void hook(Class cls, SEL sel, IMP replacement, IMP *original);
static void setColorImage(NSView *self, SEL cmd, CGImageRef image);
static void updateLayer(NSView *self, SEL cmd);

static void accessoryApplication(void) {
    // Wine must create its NSApplication subclass first.
    if (!connected || !NSApp || !originalPolicy || accessoryApplied) return;
    if (!savedPolicyValid) { savedPolicy = NSApp.activationPolicy; savedPolicyValid = YES; }
    // Cache activation policy; querying LaunchServices each frame stalls rendering.
    accessoryApplied = ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))originalPolicy)(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory);
}
static BOOL setPolicy(id self, SEL cmd, NSApplicationActivationPolicy policy) {
    if (connected) {
        savedPolicy = policy; savedPolicyValid = YES;
        if (policy == NSApplicationActivationPolicyRegular) policy = NSApplicationActivationPolicyAccessory;
    }
    BOOL applied = ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))originalPolicy)(self,cmd,policy);
    if (connected && applied) accessoryApplied = policy == NSApplicationActivationPolicyAccessory;
    return applied;
}
static void foreground(id self, SEL cmd, BOOL activate) {
    if (connected) {
        savedPolicy = NSApplicationActivationPolicyRegular; savedPolicyValid = YES;
        accessoryApplication(); return;
    }
    ((void(*)(id,SEL,BOOL))originalForeground)(self,cmd,activate);
}
static void installForegroundHook(void) {
    if (!originalForeground)
        hook(NSClassFromString(@"WineApplicationController"),NSSelectorFromString(@"transformProcessToForeground:"),(IMP)foreground,&originalForeground);
}

static void sendMessage(NSDictionary *message) {
    if (!connected) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || data.length > 65536) return;
    NSMutableData *frame = [data mutableCopy];
    [frame appendBytes:"\n" length:1];
    dispatch_async(writer, ^{
        const char *bytes = frame.bytes; size_t left = frame.length;
        while (left && transport >= 0) {
            ssize_t written = send(transport, bytes, left, 0);
            if (written <= 0) break;
            bytes += written; left -= written;
        }
    });
}
static BOOL isWine(NSWindow *window) {
    Class wineClass = NSClassFromString(@"WineWindow");
    return connected && wineClass && [window isKindOfClass:wineClass];
}
static WFWindow *record(NSWindow *window) {
    return windows[@((uintptr_t)(__bridge void *)window)];
}
static void publish(WFWindow *item) {
    NSWindow *w = item.window;
    if (!w || (!nativeGamePresentation && !item.context)) return;
    NSSize size = w.contentView.bounds.size;
    NSRect contentRect = [w contentRectForFrameRect:w.frame];
    CGFloat screenTop = NSScreen.screens.firstObject.frame.size.height;
    NSDictionary *message = @{@"type": @"window", @"id": @(item.identifier),
        @"context": @(nativeGamePresentation ? 0 : [item.context contextId]),
        @"presentation": nativeGamePresentation ? @"native" : @"embedded", @"title": w.title ?: @"",
        @"x": @(contentRect.origin.x), @"y": @(screenTop-NSMaxY(contentRect)),
        @"width": @(size.width), @"height": @(size.height), @"visible": @(item.visible),
        @"focused": @(item.focused), @"order": @(item.order)};
    if (![message isEqual:item.last]) {
        if (item.visible && ![item.last[@"visible"] boolValue])
            fprintf(stderr,"Wayfarer: %s window %s %.0fx%.0f, content %s.\n",nativeGamePresentation ? "native" : "embedded",w.title.UTF8String,size.width,size.height,NSStringFromClass(w.contentView.class).UTF8String);
        item.last = message; sendMessage(message);
    }
}
static WFWindow *attach(NSWindow *w) {
    if (!isWine(w) || !w.contentView) return nil;
    WFWindow *item = record(w);
    if (item) return item;
    if (nativeGamePresentation) {
        item = [WFWindow new]; item.window = w; item.identifier = ++nextIdentifier;
        item.visible = w.isVisible; item.focused = w.isKeyWindow;
        windows[@((uintptr_t)(__bridge void *)w)] = item;
        return item;
    }
    Class contextClass = NSClassFromString(@"CAContext");
    uint32_t (*connection)(void) = dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    if (!contextClass || !connection) {
        sendMessage(@{@"type": @"error", @"message": @"This macOS version cannot share Wine's render layers."});
        return nil;
    }
    NSView *view = w.contentView;
    installForegroundHook(); accessoryApplication();
    if (!renderActivity)
        renderActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Rendering an embedded Windows session"];
    if (!originalColorImage) hook(NSClassFromString(@"WineContentView"),NSSelectorFromString(@"setColorImage:"),(IMP)setColorImage,&originalColorImage);
    if (!originalUpdateLayer) hook(NSClassFromString(@"WineContentView"),@selector(updateLayer),(IMP)updateLayer,&originalUpdateLayer);
    view.wantsLayer = YES;
    item = [WFWindow new]; item.window = w; item.identifier = ++nextIdentifier; item.dirty = YES;
    item.root = [CALayer layer]; item.root.geometryFlipped = view.isFlipped;
    item.root.actions = @{@"contents": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
    item.root.frame = view.bounds;
    item.root.anchorPoint = CGPointZero; item.root.position = CGPointZero;
    item.context = [contextClass contextWithCGSConnection:connection() options:@{}];
    [item.context setLayer:item.root];
    // Export a separate root so AppKit cannot reclaim its CAContext.
    item.root.contents = view.layer.contents;
    item.root.contentsScale = view.layer.contentsScale;
    windows[@((uintptr_t)(__bridge void *)w)] = item;
    return item;
}

static IMP originalOrder, originalOut, originalVisible, originalOcclusion, originalKey;
static IMP originalMakeKey, originalSetContent, originalWindowAtPoint, originalMouseLocation;
static IMP originalActivation;
static IMP originalActive, originalAppKey;
static BOOL active(id self, SEL cmd) {
    return connected ? YES : ((BOOL(*)(id,SEL))originalActive)(self,cmd);
}
static NSWindow *appKey(id self, SEL cmd) {
    if (connected) for (WFWindow *item in windows.allValues) if (item.focused && item.visible) return item.window;
    return ((id(*)(id,SEL))originalAppKey)(self,cmd);
}
static IMP originalGLFlush;
@interface WFGLDrawable : NSObject {
@public IOSurfaceRef surfaces[3]; GLuint textures[3], framebuffers[3];
@public _Atomic(bool) pending;
}
@property(nonatomic) int width, height, index;
@property(nonatomic) double lastPresent;
@end
@implementation WFGLDrawable
- (void)dealloc { for (int i=0;i<3;i++) if (surfaces[i]) CFRelease(surfaces[i]); }
@end
static const void *drawableKey = &drawableKey;
static const void *glDiagnosticKey = &glDiagnosticKey;
static const void *glWindowDiagnosticKey = &glWindowDiagnosticKey;
// The legacy OpenGL drawable belongs to NSWindow; copy it on the GPU into a shared IOSurface.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void glPresent(NSOpenGLContext *self, SEL cmd) {
    if (connected && [NSStringFromClass(self.class) hasPrefix:@"Wine"] && !objc_getAssociatedObject(self,glDiagnosticKey)) {
        fprintf(stderr,"Wayfarer: OpenGL present (current context matches: %d).\n",CGLGetCurrentContext() == self.CGLContextObj);
        objc_setAssociatedObject(self,glDiagnosticKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!connected || ![NSStringFromClass(self.class) hasPrefix:@"Wine"] || CGLGetCurrentContext() != self.CGLContextObj) {
        ((void(*)(id,SEL))originalGLFlush)(self,cmd); return;
    }
    __block WFWindow *item;
    void (^findWindow)(void) = ^{
        NSView *view = self.view;
        item = record(view.window);
        if (!item && [self respondsToSelector:NSSelectorFromString(@"latentView")])
            view = ((id(*)(id,SEL))objc_msgSend)(self,NSSelectorFromString(@"latentView"));
        item = record(view.window);
        if (!objc_getAssociatedObject(self,glWindowDiagnosticKey)) {
            fprintf(stderr,"Wayfarer: OpenGL effective view %s, window %s, attached %d, visible %d; tracked %lu.\n",NSStringFromClass(view.class).UTF8String,NSStringFromClass(view.window.class).UTF8String,item!=nil,item.visible,(unsigned long)windows.count);
            objc_setAssociatedObject(self,glWindowDiagnosticKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    };
    if (NSThread.isMainThread) findWindow(); else dispatch_sync(dispatch_get_main_queue(),findWindow);
    if (!item || !item.visible) { ((void(*)(id,SEL))originalGLFlush)(self,cmd); return; }
    GLint size[2] = {0}; CGLGetParameter(self.CGLContextObj,kCGLCPSurfaceBackingSize,size);
    if (size[0]<=0 || size[1]<=0) { GLint viewport[4]; glGetIntegerv(GL_VIEWPORT,viewport); size[0] = viewport[2]; size[1] = viewport[3]; }
    static BOOL reportedSize;
    if (!reportedSize) { reportedSize = YES; fprintf(stderr,"Wayfarer: OpenGL surface size %dx%d.\n",size[0],size[1]); }
    if (size[0]<=0 || size[1]<=0 || size[0]>8192 || size[1]>8192) { ((void(*)(id,SEL))originalGLFlush)(self,cmd); return; }
    WFGLDrawable *draw = objc_getAssociatedObject(self,drawableKey);
    double now = CACurrentMediaTime();
    if (draw && (draw->pending || now-draw.lastPresent < 1.0/60)) { ((void(*)(id,SEL))originalGLFlush)(self,cmd); return; }
    GLint readFBO, writeFBO, readBuffer, texture;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&readFBO); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&writeFBO);
    glGetIntegerv(GL_READ_BUFFER,&readBuffer); glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE,&texture);
    if (!draw || draw.width != size[0] || draw.height != size[1]) {
        if (draw) { glDeleteTextures(3,draw->textures); glDeleteFramebuffers(3,draw->framebuffers); }
        draw = [WFGLDrawable new]; draw.width = size[0]; draw.height = size[1];
        fprintf(stderr,"Wayfarer: shared OpenGL drawable %dx%d.\n",size[0],size[1]);
        glGenTextures(3,draw->textures); glGenFramebuffers(3,draw->framebuffers);
        for (int i=0;i<3;i++) {
            NSDictionary *props = @{(id)kIOSurfaceWidth: @(size[0]), (id)kIOSurfaceHeight: @(size[1]),
                (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')};
            draw->surfaces[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            glBindTexture(GL_TEXTURE_RECTANGLE,draw->textures[i]);
            if (!draw->surfaces[i] || CGLTexImageIOSurface2D(self.CGLContextObj,GL_TEXTURE_RECTANGLE,GL_RGBA8,size[0],size[1],GL_BGRA,GL_UNSIGNED_INT_8_8_8_8_REV,draw->surfaces[i],0) != kCGLNoError) continue;
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw->framebuffers[i]);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_RECTANGLE,draw->textures[i],0);
        }
        objc_setAssociatedObject(self,drawableKey,draw,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    draw.lastPresent = now;
    int slot = draw.index++ % 3;
    BOOL scissor = glIsEnabled(GL_SCISSOR_TEST); glDisable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,0); glReadBuffer(GL_BACK);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw->framebuffers[slot]); glDrawBuffer(GL_COLOR_ATTACHMENT0);
    if (draw->surfaces[slot] && glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        glBlitFramebuffer(0,0,size[0],size[1],0,size[1],size[0],0,GL_COLOR_BUFFER_BIT,GL_NEAREST);
        glFinish();
        draw->pending = true;
        IOSurfaceRef surface = draw->surfaces[slot]; CFRetain(surface);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (connected && item.window) {
                if (!item.glLayer) { item.glLayer = [CALayer layer]; [item.root addSublayer:item.glLayer]; }
                item.glLayer.frame = item.window.contentView.bounds;
                item.glLayer.contents = (__bridge id)surface;
                [CATransaction flush];
            }
            draw->pending = false;
            CFRelease(surface);
        });
    }
    glBindTexture(GL_TEXTURE_RECTANGLE,texture);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,readFBO); glReadBuffer(readBuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,writeFBO);
    if (scissor) glEnable(GL_SCISSOR_TEST);
    ((void(*)(id,SEL))originalGLFlush)(self,cmd);
}
#pragma clang diagnostic pop
static void activate(id self, SEL cmd, BOOL flag) {
    if (connected) return;
    ((void(*)(id,SEL,BOOL))originalActivation)(self,cmd,flag);
}
static void orderWindow(NSWindow *self, SEL cmd, NSWindowOrderingMode mode, NSInteger relative) {
    if (isWine(self) && !restoring) {
        if (nativeGamePresentation) {
            ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))originalOrder)(self,cmd,mode,relative);
            WFWindow *item = attach(self); item.visible = self.isVisible; item.focused = self.isKeyWindow;
            if (item.visible) item.order = NSProcessInfo.processInfo.systemUptime;
            publish(item); return;
        }
        self.alphaValue = 0; self.ignoresMouseEvents = YES;
        if (mode != NSWindowOut && !NSIsEmptyRect(self.frame)) {
            BOOL onScreen = NO; for (NSScreen *screen in NSScreen.screens) onScreen |= NSIntersectsRect(self.frame,screen.frame);
            if (!onScreen) [self center];
        }
        ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))originalOrder)(self,cmd,mode,relative);
        WFWindow *item = attach(self); item.visible = mode != NSWindowOut;
        if (item.visible) item.order = NSProcessInfo.processInfo.systemUptime;
        publish(item); return;
    }
    ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))originalOrder)(self,cmd,mode,relative);
}
static void orderOut(NSWindow *self, SEL cmd, id sender) {
    if (isWine(self) && !restoring) {
        ((void(*)(id,SEL,id))originalOut)(self,cmd,sender);
        WFWindow *item = record(self); item.visible = NO; publish(item); return;
    }
    ((void(*)(id,SEL,id))originalOut)(self,cmd,sender);
}
static BOOL visible(NSWindow *self, SEL cmd) {
    WFWindow *item = record(self);
    return isWine(self) && item ? item.visible : ((BOOL(*)(id,SEL))originalVisible)(self,cmd);
}
static NSWindowOcclusionState occlusion(NSWindow *self, SEL cmd) {
    WFWindow *item = record(self);
    return isWine(self) && item && item.visible ? NSWindowOcclusionStateVisible : ((NSWindowOcclusionState(*)(id,SEL))originalOcclusion)(self,cmd);
}
static BOOL isKey(NSWindow *self, SEL cmd) {
    WFWindow *item = record(self);
    return isWine(self) && item ? item.focused : ((BOOL(*)(id,SEL))originalKey)(self,cmd);
}
static void makeKey(NSWindow *self, SEL cmd) {
    if (nativeGamePresentation) { ((void(*)(id,SEL))originalMakeKey)(self,cmd); return; }
    if (isWine(self) && !restoring) {
        for (WFWindow *other in windows.allValues) if (other.window != self && other.focused) {
            other.focused = NO;
            if ([other.window respondsToSelector:@selector(windowDidResignKey:)])
                ((void(*)(id,SEL,id))objc_msgSend)(other.window,@selector(windowDidResignKey:),[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:other.window]);
            publish(other);
        }
        WFWindow *item = attach(self); item.focused = YES;
        if ([self respondsToSelector:@selector(windowDidBecomeKey:)])
            ((void(*)(id,SEL,id))objc_msgSend)(self,@selector(windowDidBecomeKey:),[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:self]);
        publish(item); return;
    }
    ((void(*)(id,SEL))originalMakeKey)(self,cmd);
}
static void setContent(NSWindow *self, SEL cmd, NSView *view) {
    ((void(*)(id,SEL,id))originalSetContent)(self,cmd,view);
    if (isWine(self)) attach(self);
}
static NSInteger windowAtPoint(id self, SEL cmd, NSPoint point, NSInteger below) {
    if (inputWindow) return inputWindow.windowNumber;
    return ((NSInteger(*)(id,SEL,NSPoint,NSInteger))originalWindowAtPoint)(self,cmd,point,below);
}
static NSPoint mouseLocation(id self, SEL cmd) {
    if (connected && hasVirtualMouse) return virtualMouse;
    return ((NSPoint(*)(id,SEL))originalMouseLocation)(self,cmd);
}
static void hook(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls,sel);
    if (!method) return;
    *original = method_getImplementation(method);
    class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(method));
}
static void setColorImage(NSView *self, SEL cmd, CGImageRef image) {
    ((void(*)(id,SEL,CGImageRef))originalColorImage)(self,cmd,image);
    WFWindow *item = record(self.window);
    if (connected && item) item.dirty = YES;
}
static void updateLayer(NSView *self, SEL cmd) {
    ((void(*)(id,SEL))originalUpdateLayer)(self,cmd);
    WFWindow *item = record(self.window);
    if (connected && item && item.visible) {
        // Reuse unchanged cropped bitmaps to avoid Core Animation copies.
        item.root.contents = self.layer.contents;
        item.root.contentsScale = self.layer.contentsScale;
        item.root.contentsRect = self.layer.contentsRect;
        item.dirty = NO; frameChanged = YES;
    }
}

// Deliver input to Wine's Cocoa controller, avoiding global macOS event injection.
@interface WFInputEvent : NSEvent
@property(nonatomic, weak) NSWindow *target;
@property(nonatomic) NSEventType kind;
@property(nonatomic) NSEventModifierFlags flags;
@property(nonatomic) NSPoint local;
@property(nonatomic) unsigned short code;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSString *plainText;
@property(nonatomic) NSInteger button;
@property(nonatomic) CGFloat dx, dy;
@property(nonatomic) CGEventRef cg;
@end
@implementation WFInputEvent
- (NSEventType)type { return _kind; }
- (NSWindow *)window { return _target; }
- (NSInteger)windowNumber { return _target.windowNumber; }
- (NSPoint)locationInWindow { return _local; }
- (NSTimeInterval)timestamp { return NSProcessInfo.processInfo.systemUptime; }
- (NSEventModifierFlags)modifierFlags { return _flags; }
- (unsigned short)keyCode { return _code; }
- (NSString *)characters { return _text ?: @""; }
- (NSString *)charactersIgnoringModifiers { return _plainText ?: @""; }
- (BOOL)isARepeat { return NO; }
- (NSInteger)buttonNumber { return _button; }
- (NSInteger)clickCount { return 1; }
- (float)pressure { return 1; }
- (CGFloat)deltaX { return _dx; }
- (CGFloat)deltaY { return _dy; }
- (CGFloat)scrollingDeltaX { return _dx; }
- (CGFloat)scrollingDeltaY { return _dy; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (NSEventPhase)phase { return NSEventPhaseNone; }
- (NSEventPhase)momentumPhase { return NSEventPhaseNone; }
- (CGEventRef)CGEvent { return _cg; }
- (void)dealloc { if (_cg) CFRelease(_cg); }
@end
static void input(NSDictionary *msg) {
    WFWindow *item;
    for (WFWindow *candidate in windows.allValues) if (candidate.identifier == [msg[@"id"] unsignedIntegerValue]) { item = candidate; break; }
    NSWindow *w = item.window;
    if (!w || !item.visible) return;
    NSString *kind = msg[@"kind"];
    if (nativeGamePresentation) {
        if ([kind isEqual:@"activate"]) {
            if (w.isMiniaturized) [w deminiaturize:nil];
            [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        }
        return;
    }
    if ([kind isEqual:@"focus"]) { makeKey(w,@selector(makeKeyWindow)); return; }
    if ([kind isEqual:@"blur"]) {
        WFInputEvent *release = [WFInputEvent new]; release.target = w;
        release.kind = NSEventTypeFlagsChanged; release.flags = 0;
        [w flagsChanged:release];
        item.focused = NO;
        if ([w respondsToSelector:@selector(windowDidResignKey:)])
            ((void(*)(id,SEL,id))objc_msgSend)(w,@selector(windowDidResignKey:),[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:w]);
        publish(item); return;
    }
    if (![kind isEqual:@"input"]) return;
    WFInputEvent *e = [WFInputEvent new]; e.target = w;
    e.kind = [msg[@"event"] unsignedIntegerValue]; e.flags = [msg[@"flags"] unsignedLongLongValue];
    e.local = NSMakePoint([msg[@"x"] doubleValue],w.contentView.bounds.size.height - [msg[@"y"] doubleValue]);
    e.code = [msg[@"code"] unsignedShortValue]; e.text = msg[@"text"]; e.plainText = msg[@"plainText"];
    e.button = [msg[@"button"] integerValue]; e.dx = [msg[@"dx"] doubleValue]; e.dy = [msg[@"dy"] doubleValue];
    NSPoint point = [w convertPointToScreen:e.local]; virtualMouse = point; hasVirtualMouse = YES;
    CGFloat top = NSScreen.screens.firstObject.frame.size.height;
    CGEventRef cg = CGEventCreate(NULL); e.cg = cg;
    CGEventSetLocation(cg,CGPointMake(point.x,top-point.y)); CGEventSetFlags(cg,(CGEventFlags)e.flags);
    CGEventSetIntegerValueField(cg,kCGMouseEventDeltaX,e.dx);
    CGEventSetIntegerValueField(cg,kCGMouseEventDeltaY,e.dy);
    id controller = NSApp.delegate; inputWindow = w;
    if (e.kind == NSEventTypeKeyDown || e.kind == NSEventTypeKeyUp || e.kind == NSEventTypeFlagsChanged) {
        if (e.kind == NSEventTypeFlagsChanged) [w flagsChanged:e];
        else if ([w respondsToSelector:@selector(postKeyEvent:)])
            ((void(*)(id,SEL,id))objc_msgSend)(w,@selector(postKeyEvent:),e);
    } else {
        SEL selector = e.kind == NSEventTypeScrollWheel ? @selector(handleScrollWheel:) :
            (e.kind == NSEventTypeMouseMoved || e.kind == NSEventTypeLeftMouseDragged || e.kind == NSEventTypeRightMouseDragged || e.kind == NSEventTypeOtherMouseDragged) ? @selector(handleMouseMove:) : @selector(handleMouseButton:);
        if ([controller respondsToSelector:selector]) ((void(*)(id,SEL,id))objc_msgSend)(controller,selector,e);
    }
    inputWindow = nil;
}
static void restore(void) {
    restoring = YES;
    if (renderActivity) { [NSProcessInfo.processInfo endActivity:renderActivity]; renderActivity = nil; }
    if (NSApp && savedPolicyValid && originalPolicy)
        ((BOOL(*)(id,SEL,NSApplicationActivationPolicy))originalPolicy)(NSApp,@selector(setActivationPolicy:),savedPolicy);
    savedPolicyValid = NO; accessoryApplied = NO;
    for (WFWindow *item in windows.allValues) {
        NSWindow *w = item.window; if (!w || nativeGamePresentation) continue;
        w.alphaValue = 1; w.ignoresMouseEvents = NO;
        [item.context setLayer:nil];
        if (item.visible) [w orderFront:nil];
    }
    [windows removeAllObjects]; restoring = NO;
}
static void tick(void) {
    if (!nativeGamePresentation) { installForegroundHook(); accessoryApplication(); }
    for (NSNumber *key in windows.allKeys) {
        WFWindow *item = windows[key];
        NSWindow *w = item.window;
        if (!w) {
            sendMessage(@{@"type": @"closed", @"id": @(item.identifier)});
            [item.context setLayer:nil]; [windows removeObjectForKey:key]; continue;
        }
        if (nativeGamePresentation) {
            item.visible = w.isVisible; item.focused = w.isKeyWindow;
            publish(item); continue;
        }
        if (item.visible) {
            NSView *v = w.contentView;
            if (!CGRectEqualToRect(item.root.bounds,v.bounds)) { item.root.bounds = v.bounds; item.dirty = YES; frameChanged = YES; }
            if (item.dirty || v.needsDisplay) {
                if ([NSStringFromClass(v.class) hasPrefix:@"Wine"] && [v respondsToSelector:@selector(updateLayer)]) [v updateLayer];
                v.needsDisplay = NO;
            }
        }
        publish(item);
    }
    if (frameChanged) { [CATransaction flush]; frameChanged = NO; }
}
__attribute__((constructor)) static void initialize(void) {
    const char *path = getenv("WAYFARER_DISPLAY_SOCKET"), *secret = getenv("WAYFARER_DISPLAY_TOKEN");
    if([NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent isEqualToString:@"wineserver"]) return;
    if (!path || !secret || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return;
    int fd = socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un addr = {.sun_family=AF_UNIX};
    strlcpy(addr.sun_path,path,sizeof(addr.sun_path));
    if (connect(fd,(struct sockaddr *)&addr,sizeof(addr))) { close(fd); return; }
    uid_t uid; gid_t gid;
    if (getpeereid(fd,&uid,&gid) || uid != geteuid()) { close(fd); return; }
    int noSIGPIPE = 1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSIGPIPE,sizeof(noSIGPIPE));
    transport = fd; connected = YES; writer = dispatch_queue_create("app.wayfarer.display.writer",DISPATCH_QUEUE_SERIAL);
    windows = [NSMutableDictionary new];
    sendMessage(@{@"type": @"hello", @"version": @1, @"token": @(secret), @"pid": @(getpid())});
    dispatch_sync(writer, ^{});
    struct timeval timeout = {.tv_sec=1};
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    timeout.tv_sec = 5;
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    // Read a complete bounded frame. A stream may split the ready response.
    char response[128]; size_t received = 0;
    while (received < sizeof(response)-1) {
        ssize_t count = recv(fd,response+received,1,0);
        if (count != 1) break;
        if (response[received++] == '\n') break;
    }
    if (!received || response[received-1] != '\n') { connected = NO; transport = -1; close(fd); return; }
    NSData *ack = [NSData dataWithBytes:response length:received];
    NSDictionary *ready = [NSJSONSerialization JSONObjectWithData:ack options:0 error:nil];
    if (![ready[@"type"] isEqual:@"ready"] || [ready[@"version"] intValue] != 1) { connected = NO; transport = -1; close(fd); return; }
    timeout.tv_sec = 0; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    nativeGamePresentation = shouldPresentNatively();
    fprintf(stderr,"Wayfarer: display policy %s.\n", nativeGamePresentation ? "native game" : "embedded Steam");
    hook(NSWindow.class,@selector(orderWindow:relativeTo:),(IMP)orderWindow,&originalOrder);
    hook(NSWindow.class,@selector(orderOut:),(IMP)orderOut,&originalOut);
    if (!nativeGamePresentation) {
        hook(NSWindow.class,@selector(isVisible),(IMP)visible,&originalVisible);
        hook(NSWindow.class,@selector(occlusionState),(IMP)occlusion,&originalOcclusion);
        hook(NSWindow.class,@selector(isKeyWindow),(IMP)isKey,&originalKey);
        hook(NSWindow.class,@selector(makeKeyWindow),(IMP)makeKey,&originalMakeKey);
        hook(NSApplication.class,@selector(activateIgnoringOtherApps:),(IMP)activate,&originalActivation);
        hook(NSApplication.class,@selector(setActivationPolicy:),(IMP)setPolicy,&originalPolicy);
        hook(NSApplication.class,@selector(isActive),(IMP)active,&originalActive);
        hook(NSApplication.class,@selector(keyWindow),(IMP)appKey,&originalAppKey);
        hook(NSClassFromString(@"NSOpenGLContext"),NSSelectorFromString(@"flushBuffer"),(IMP)glPresent,&originalGLFlush);
        hook(object_getClass(NSWindow.class),@selector(windowNumberAtPoint:belowWindowWithWindowNumber:),(IMP)windowAtPoint,&originalWindowAtPoint);
        hook(object_getClass(NSEvent.class),@selector(mouseLocation),(IMP)mouseLocation,&originalMouseLocation);
    }
    hook(NSWindow.class,@selector(setContentView:),(IMP)setContent,&originalSetContent);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSMutableData *buffer = [NSMutableData new]; char bytes[4096]; ssize_t count;
        while ((count = recv(fd,bytes,sizeof(bytes),0)) > 0) {
            @autoreleasepool {
                [buffer appendBytes:bytes length:count]; if (buffer.length > 65536) break;
                for (;;) {
                    const void *newline = memchr(buffer.bytes,'\n',buffer.length); if (!newline) break;
                    NSUInteger length = (const char *)newline - (const char *)buffer.bytes;
                    NSData *line = [buffer subdataWithRange:NSMakeRange(0,length)];
                    [buffer replaceBytesInRange:NSMakeRange(0,length+1) withBytes:NULL length:0];
                    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                    if ([message isKindOfClass:NSDictionary.class]) dispatch_async(dispatch_get_main_queue(), ^{ input(message); });
                }
            }
        }
        connected = NO;
        // Drain writes before closing, so no queued send can use a reused fd.
        dispatch_sync(writer, ^{ transport = -1; close(fd); });
        dispatch_async(dispatch_get_main_queue(), ^{ restore(); });
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:nativeGamePresentation ? 0.25 : 1.0/60 repeats:YES block:^(NSTimer *timer) { if (connected) tick(); else [timer invalidate]; }];
    });
}
