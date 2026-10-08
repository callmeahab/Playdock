#import "RemoteLayer.h"
@interface CALayer (WFContext)
- (void)setContextId:(uint32_t)value;
@end
CALayer *WFMakeRemoteLayer(uint32_t context) {
    Class cls = NSClassFromString(@"CALayerHost");
    if (!cls || ![cls instancesRespondToSelector:@selector(setContextId:)]) return nil;
    CALayer *layer = [cls layer];
    [layer setContextId:context];
    return layer;
}
