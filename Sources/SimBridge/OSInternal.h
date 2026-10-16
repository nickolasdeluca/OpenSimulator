#import "SimBridge.h"
#import "OSPrivate.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSError *OSMakeError(NSInteger code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

@interface OSDeviceSnapshot ()
- (instancetype)initWithDevice:(id<OSPSimDevice>)device;
@end

@interface OSDisplayStream ()
- (nullable instancetype)initWithDescriptor:(id)descriptor error:(NSError *_Nullable *_Nullable)error;
@end

@interface OSHIDClient ()
- (nullable instancetype)initWithDevice:(id)device
                       simulatorKitPath:(NSString *)path
                                  error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
