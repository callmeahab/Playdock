#import <Cocoa/Cocoa.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        int listener = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        strlcpy(address.sun_path, argv[1], sizeof(address.sun_path));
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 16)) return 3;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (;;) {
                int client = accept(listener, NULL, NULL);
                if (client < 0) break;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    FILE *file = fdopen(client, "r"); char *line = NULL; size_t capacity = 0;
                    BOOL requestedActivation = NO;
                    while (getline(&line, &capacity, file) > 0) {
                        @autoreleasepool {
                            NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line length:strlen(line)] options:0 error:nil];
                            if ([value[@"type"] isEqual:@"hello"]) {
                                const char *ack = "{\"type\":\"ready\",\"version\":1}\n";
                                send(client, ack, strlen(ack), 0);
                            }
                            if (![value[@"type"] isEqual:@"window"] || ![value[@"visible"] boolValue] || [value[@"width"] doubleValue] < 50) continue;
                            if (value[@"context"] || value[@"presentation"]) { fprintf(stdout, "NATIVE_POLICY_FAILED\n"); fflush(stdout); exit(4); }
                            if (!requestedActivation) {
                                requestedActivation = YES;
                                NSData *message = [NSJSONSerialization dataWithJSONObject:@{@"kind": @"activate", @"id": value[@"id"]} options:0 error:nil];
                                send(client, message.bytes, message.length, 0); send(client, "\n", 1, 0);
                                fprintf(stdout, "ACTIVATION_REQUESTED\n"); fflush(stdout);
                            }
                            if ([value[@"focused"] boolValue]) {
                                fprintf(stdout, "NATIVE_POLICY_PASSED\n"); fflush(stdout);
                                dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
                                break;
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
