#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdatomic.h>

@interface PDWindow : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic) NSUInteger identifier;
@property(nonatomic) double order;
@property(nonatomic, copy) NSDictionary *last;
@end
@implementation PDWindow
@end

static NSMutableDictionary<NSNumber *, PDWindow *> *windows;
static int transport = -1;
static _Atomic(bool) connected;
static dispatch_queue_t writer;
static NSUInteger nextIdentifier;
static IMP originalOrder, originalOut, originalSetContent;

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
static PDWindow *record(NSWindow *window) {
    return windows[@((uintptr_t)(__bridge void *)window)];
}
static PDWindow *attach(NSWindow *window) {
    Class wine = NSClassFromString(@"WineWindow");
    if (!connected || !wine || ![window isKindOfClass:wine] || !window.contentView) return nil;
    PDWindow *item = record(window);
    if (!item) {
        item = [PDWindow new]; item.window = window; item.identifier = ++nextIdentifier;
        windows[@((uintptr_t)(__bridge void *)window)] = item;
    }
    return item;
}
static void publish(PDWindow *item) {
    NSWindow *window = item.window;
    if (!window) return;
    NSSize size = window.contentView.bounds.size;
    NSRect content = [window contentRectForFrameRect:window.frame];
    CGFloat screenTop = NSScreen.screens.firstObject.frame.size.height;
    NSDictionary *message = @{@"type": @"window", @"id": @(item.identifier), @"title": window.title ?: @"",
        @"x": @(content.origin.x), @"y": @(screenTop-NSMaxY(content)),
        @"width": @(size.width), @"height": @(size.height), @"visible": @(window.isVisible),
        @"focused": @(window.isKeyWindow), @"order": @(item.order)};
    if (![message isEqual:item.last]) { item.last = message; sendMessage(message); }
}
static void orderWindow(NSWindow *window, SEL cmd, NSWindowOrderingMode mode, NSInteger relative) {
    ((void(*)(id,SEL,NSWindowOrderingMode,NSInteger))originalOrder)(window,cmd,mode,relative);
    PDWindow *item = attach(window);
    if (window.isVisible) item.order = NSProcessInfo.processInfo.systemUptime;
    publish(item);
}
static void orderOut(NSWindow *window, SEL cmd, id sender) {
    ((void(*)(id,SEL,id))originalOut)(window,cmd,sender);
    publish(record(window));
}
static void setContent(NSWindow *window, SEL cmd, NSView *view) {
    ((void(*)(id,SEL,id))originalSetContent)(window,cmd,view);
    attach(window);
}
static void input(NSDictionary *message) {
    if (!connected || ![message[@"kind"] isEqual:@"activate"]) return;
    for (PDWindow *item in windows.allValues) {
        if (item.identifier != [message[@"id"] unsignedIntegerValue]) continue;
        NSWindow *window = item.window;
        if (!window || (!window.isVisible && !window.isMiniaturized)) return;
        if (window.isMiniaturized) [window deminiaturize:nil];
        [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        return;
    }
}
static void tick(void) {
    for (NSNumber *key in windows.allKeys) {
        PDWindow *item = windows[key];
        if (!item.window) {
            sendMessage(@{@"type": @"closed", @"id": @(item.identifier)});
            [windows removeObjectForKey:key];
        } else { publish(item); }
    }
}

static void hook(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls,sel);
    if (!method) return;
    *original = method_getImplementation(method);
    class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(method));
}
__attribute__((constructor)) static void initialize(void) {
    const char *path = getenv("PLAYDOCK_DISPLAY_SOCKET"), *secret = getenv("PLAYDOCK_DISPLAY_TOKEN");
    if([NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent isEqualToString:@"wineserver"]) return;
    if (!path || !secret || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return;
    int fd = socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un addr = {.sun_family=AF_UNIX};
    strlcpy(addr.sun_path,path,sizeof(addr.sun_path));
    if (connect(fd,(struct sockaddr *)&addr,sizeof(addr))) { close(fd); return; }
    uid_t uid; gid_t gid;
    if (getpeereid(fd,&uid,&gid) || uid != geteuid()) { close(fd); return; }
    int noSIGPIPE = 1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSIGPIPE,sizeof(noSIGPIPE));
    struct timeval timeout = {.tv_sec=1};
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    transport = fd; connected = YES; writer = dispatch_queue_create("app.playdock.display.writer",DISPATCH_QUEUE_SERIAL);
    windows = [NSMutableDictionary new];
    sendMessage(@{@"type": @"hello", @"version": @1, @"token": @(secret), @"pid": @(getpid())});
    dispatch_sync(writer, ^{});
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
    hook(NSWindow.class,@selector(orderWindow:relativeTo:),(IMP)orderWindow,&originalOrder);
    hook(NSWindow.class,@selector(orderOut:),(IMP)orderOut,&originalOut);
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
        dispatch_async(dispatch_get_main_queue(), ^{ [windows removeAllObjects]; });
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            if (connected) tick(); else [timer invalidate];
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
