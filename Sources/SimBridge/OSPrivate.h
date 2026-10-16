// Declarations for the CoreSimulator / SimulatorKit symbols this bridge messages. They are
// protocols only: nothing is linked, every receiver is cast from `id`, and every selector is checked
// with -respondsToSelector: or -conformsToProtocol: before it is relied on, because these are
// private and change between Xcode releases.
//
// Selector names were cross-checked against OpenDeviceHub (MIT), which verified them on Xcode 26.5
// and Xcode 27. See THIRD_PARTY_NOTICES.md.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@protocol OSPSimDeviceType <NSObject>
@property (nonatomic, readonly, nullable) NSString *identifier;
@property (nonatomic, readonly, nullable) NSString *name;
@property (nonatomic, readonly) float mainScreenScale;
@property (nonatomic, readonly) CGSize mainScreenSize;
@end

@protocol OSPSimRuntime <NSObject>
@property (nonatomic, readonly, nullable) NSString *identifier;
@property (nonatomic, readonly, nullable) NSString *name;
@end

@protocol OSPSimDevice <NSObject>
@property (nonatomic, readonly, nullable) NSUUID *UDID;
@property (nonatomic, readonly, nullable) NSString *name;
@property (nonatomic, readonly) NSUInteger state;
@property (nonatomic, readonly, nullable) id<OSPSimDeviceType> deviceType;
@property (nonatomic, readonly, nullable) id<OSPSimRuntime> runtime;
@property (nonatomic, readonly, nullable) NSString *runtimeIdentifier;
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, nullable) id io;
- (void)simulateMemoryWarning;
- (unsigned int)lookup:(NSString *)service error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled
                      keyboardType:(unsigned char)keyboardType
                             error:(NSError *_Nullable *_Nullable)error;
@end

@protocol OSPSimDeviceSet <NSObject>
@property (nonatomic, readonly, nullable) NSArray *devices;
- (NSUInteger)registerNotificationHandlerOnQueue:(dispatch_queue_t)queue
                                         handler:(void (^)(id _Nullable))handler;
- (BOOL)unregisterNotificationHandler:(NSUInteger)handle error:(NSError *_Nullable *_Nullable)error;
@end

@protocol OSPSimServiceContext <NSObject>
- (nullable id<OSPSimDeviceSet>)defaultDeviceSetWithError:(NSError *_Nullable *_Nullable)error;
@end

@protocol OSPSimServiceContextClass <NSObject>
- (nullable id<OSPSimServiceContext>)sharedServiceContextForDeveloperDir:(NSString *)developerDir
                                                                   error:(NSError *_Nullable *_Nullable)error;
@end

@protocol OSPSimDeviceIO <NSObject>
@property (nonatomic, readonly, nullable) NSArray *ioPorts;
@end

@protocol OSPSimDeviceIOPort <NSObject>
@property (nonatomic, readonly, nullable) id descriptor;
@end

@protocol OSPSimDeviceIOPortDescriptor <NSObject>
@property (nonatomic, readonly, nullable) id state;
@end

@protocol OSPSimDisplayDescriptorState <NSObject>
/// 0 is a panel the device has, 1 an external display port.
@property (nonatomic, readonly) unsigned short displayClass;
@end

@protocol OSPSimDisplayRenderable <NSObject>
@property (nonatomic, readonly) CGSize displaySize;
/// Named pitch, but it is pixels per inch.
@property (nonatomic, readonly) NSUInteger displayPitch;
- (void)registerCallbackWithUUID:(NSUUID *)uuid damageRectanglesCallback:(void (^)(id _Nullable))block;
- (void)unregisterDamageRectanglesCallbackWithUUID:(NSUUID *)uuid;
@end

@protocol OSPSimDisplayIOSurfaceRenderable <NSObject>
@property (nonatomic, readonly, nullable) id framebufferSurface;
@property (nonatomic, readonly, nullable) id maskedFramebufferSurface;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(id _Nullable))block;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
@end

/// The grouped screen callbacks Xcode 27 display ports offer alongside the older ones.
@protocol OSPSimScreen <NSObject>
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(void (^)(void))frameCallback
                surfacesChangedCallback:(void (^)(id _Nullable, id _Nullable))surfacesChangedCallback
              propertiesChangedCallback:(void (^)(id _Nullable))propertiesChangedCallback;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end

@protocol OSPSimDeviceLegacyHIDClient <NSObject>
- (instancetype _Nullable)initWithDevice:(id)device error:(NSError *_Nullable *_Nullable)error;
- (void)sendWithMessage:(void *)message
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t _Nullable)queue
             completion:(void (^)(NSError *_Nullable))completion;
@end

NS_ASSUME_NONNULL_END
