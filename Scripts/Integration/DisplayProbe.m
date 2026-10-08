#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
@interface CALayer (WFHost)
- (void)setContextId:(uint32_t)value;
@end
static int connection = -1;
static NSWindow *window;
static CALayer *remote;
static NSNumber *selectedID;
static BOOL verifyNative, nativeCheckScheduled;
static void sendInput(NSDictionary *message) {
    if (connection < 0) return;
    NSMutableDictionary *value = [message mutableCopy]; value[@"id"] = selectedID;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    send(connection,data.bytes,data.length,0); send(connection,"\n",1,0);
}
@interface WFProbeView : NSView
@end
@implementation WFProbeView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { sendInput(@{@"kind": @"input", @"event": @(event.type), @"code": @(event.keyCode), @"text": event.characters ?: @"", @"plainText": event.charactersIgnoringModifiers ?: @"", @"flags": @(event.modifierFlags)}); }
- (void)keyUp:(NSEvent *)event { [self keyDown:event]; }
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    sendInput(@{@"kind": @"focus"});
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    sendInput(@{@"kind": @"input", @"event": @(event.type), @"x": @(p.x), @"y": @(self.bounds.size.height-p.y)});
}
- (void)mouseUp:(NSEvent *)event { [self mouseDown:event]; }
- (void)mouseMoved:(NSEvent *)event { [self mouseDown:event]; }
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 && argc != 3) return 2;
        verifyNative = argc == 3 && !strcmp(argv[2],"--native");
        int listener = socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un address = {.sun_family=AF_UNIX};
        strlcpy(address.sun_path,argv[1],sizeof(address.sun_path));
        if (bind(listener,(struct sockaddr *)&address,sizeof(address)) || listen(listener,16)) return 3;
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,1000,700) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Playdock direct display probe";
        window.contentView = [[WFProbeView alloc] initWithFrame:window.contentView.bounds];
        window.contentView.wantsLayer = YES;
        [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        fprintf(stdout,"HOST_WINDOW_ID=%ld\n",(long)window.windowNumber); fflush(stdout);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            for (;;) {
                int client = accept(listener,NULL,NULL);
                if (client < 0) break;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
                    FILE *file = fdopen(client,"r"); char *line = NULL; size_t capacity = 0;
                    while (getline(&line,&capacity,file) > 0) {
                        @autoreleasepool {
                            NSData *data = [NSData dataWithBytes:line length:strlen(line)];
                            NSMutableDictionary *value = [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy];
                            [value removeObjectForKey:@"token"];
                            if ([value[@"type"] isEqual:@"hello"]) { const char *ack = "{\"type\":\"ready\",\"version\":1}\n"; send(client,ack,strlen(ack),0); }
                            fprintf(stdout,"%s\n",[[value description] UTF8String]); fflush(stdout);
                            if ([value[@"type"] isEqual:@"window"] && [value[@"visible"] boolValue] && [value[@"width"] doubleValue] > 50) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    connection = client; selectedID = value[@"id"];
                                    if (verifyNative) {
                                        if (![value[@"presentation"] isEqual:@"native"] || [value[@"context"] unsignedIntValue] != 0) {
                                            fprintf(stdout,"NATIVE_POLICY_FAILED\n"); fflush(stdout); exit(4);
                                        }
                                        if (nativeCheckScheduled) return;
                                        nativeCheckScheduled = YES;
                                        sendInput(@{@"kind": @"activate"});
                                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                                            fprintf(stdout,"NATIVE_POLICY_PASSED\n"); fflush(stdout);
                                            [NSApp terminate:nil];
                                        });
                                        return;
                                    }
                                    [remote removeFromSuperlayer];
                                    remote = [NSClassFromString(@"CALayerHost") layer];
                                    [remote setContextId:[value[@"context"] unsignedIntValue]];
                                    remote.frame = NSMakeRect(0,0,[value[@"width"] doubleValue],[value[@"height"] doubleValue]);
                                    [window.contentView.layer addSublayer:remote];
                                    window.title = [@"Playdock direct: " stringByAppendingString:value[@"title"]];
                                    [window setContentSize:remote.frame.size];
                                    [window makeFirstResponder:window.contentView];
                                    sendInput(@{@"kind": @"focus"});
                                    if ([value[@"title"] isEqual:@"Untitled - Notepad"] && ![value[@"focused"] boolValue]) {
                                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                                            sendInput(@{@"kind": @"input", @"event": @(NSEventTypeKeyDown), @"code": @0, @"text": @"a"});
                                            sendInput(@{@"kind": @"input", @"event": @(NSEventTypeKeyUp), @"code": @0, @"text": @"a"});
                                        });
                                    }
                                });
                            }
                        }
                    }
                    free(line); fclose(file);
                });
            }
        });
        [NSApp run];
    }
}
