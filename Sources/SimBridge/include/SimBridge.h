#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

/// The values CoreSimulator uses for `-[SimDevice state]`.
typedef NS_ENUM(NSInteger, OSDeviceState) {
    OSDeviceStateCreating = 0,
    OSDeviceStateShutdown = 1,
    OSDeviceStateBooting = 2,
    OSDeviceStateBooted = 3,
    OSDeviceStateShuttingDown = 4,
} NS_SWIFT_NAME(DeviceState);

typedef NS_ENUM(NSInteger, OSTouchPhase) {
    OSTouchPhaseDown = 0,
    OSTouchPhaseMove = 1,
    OSTouchPhaseUp = 2,
} NS_SWIFT_NAME(TouchPhase);

/// Which screen edge a contact started on. Only `bottom` changes behaviour in the guest: it is what
/// turns a drag into the system home / app switcher gesture.
typedef NS_ENUM(uint32_t, OSTouchEdge) {
    OSTouchEdgeNone = 0,
    OSTouchEdgeTop = 1,
    OSTouchEdgeLeft = 2,
    OSTouchEdgeBottom = 3,
    OSTouchEdgeRight = 4,
} NS_SWIFT_NAME(TouchEdge);

typedef NS_ENUM(NSInteger, OSHardwareButton) {
    OSHardwareButtonHome = 0,
    OSHardwareButtonLock,
    OSHardwareButtonSiri,
    OSHardwareButtonVolumeUp,
    OSHardwareButtonVolumeDown,
} NS_SWIFT_NAME(HardwareButton);

/// A snapshot of one simulator, copied out of CoreSimulator so nothing on the Swift side holds a
/// remote proxy.
NS_SWIFT_NAME(DeviceSnapshot)
@interface OSDeviceSnapshot : NSObject
@property (nonatomic, readonly, copy) NSString *udid;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) OSDeviceState state;
@property (nonatomic, readonly, copy) NSString *deviceTypeIdentifier;
@property (nonatomic, readonly, copy) NSString *deviceTypeName;
@property (nonatomic, readonly, copy) NSString *runtimeIdentifier;
@property (nonatomic, readonly, copy) NSString *runtimeName;
@property (nonatomic, readonly, getter=isAvailable) BOOL available;
/// Points to pixels, 3 on most modern iPhones.
@property (nonatomic, readonly) CGFloat pointScale;
/// The main screen in pixels, portrait.
@property (nonatomic, readonly) CGSize mainScreenPixelSize;
@end

/// The live framebuffer of one booted device. Frames are delivered only when the guest redraws, so
/// a still screen costs nothing. `stop` unregisters from CoreSimulator entirely, which is what a
/// hidden or minimized window does.
NS_SWIFT_NAME(DisplayStream)
@interface OSDisplayStream : NSObject
@property (nonatomic, readonly) CGSize pixelSize;
/// Pixels per inch as CoreSimulator reports it, 0 when unknown. Used for "Physical Size".
@property (nonatomic, readonly) NSUInteger pixelsPerInch;
/// The frame with the device's rounded corners and cutout already applied, when the device has one.
@property (nonatomic) BOOL prefersMaskedSurface;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, nullable) IOSurfaceRef currentSurface CF_RETURNS_NOT_RETAINED;

/// `handler` runs on a private serial queue, once per redraw.
- (void)startWithHandler:(void (^)(IOSurfaceRef surface))handler;
- (void)stop;

- (instancetype)init NS_UNAVAILABLE;
@end

/// Touch, keyboard and hardware buttons for one booted device, over SimulatorKit's Indigo HID path.
/// Points are normalized to the portrait framebuffer: (0, 0) top left, (1, 1) bottom right.
NS_SWIFT_NAME(HIDClient)
@interface OSHIDClient : NSObject
- (void)sendTouchAt:(CGPoint)point phase:(OSTouchPhase)phase edge:(OSTouchEdge)edge;
- (void)sendTouchesAt:(CGPoint)first and:(CGPoint)second phase:(OSTouchPhase)phase;
/// `usage` is a USB HID keyboard usage (page 0x07), e.g. 0x04 for A.
- (void)sendKeyUsage:(uint32_t)usage down:(BOOL)down;
- (void)sendButton:(OSHardwareButton)button down:(BOOL)down;

- (instancetype)init NS_UNAVAILABLE;
@end

/// The connection to CoreSimulator, loaded from the given Xcode at runtime.
NS_SWIFT_NAME(CoreSimulator)
@interface OSCoreSimulator : NSObject

/// Loads CoreSimulator and SimulatorKit for `developerDir` (e.g. /Applications/Xcode.app/Contents/Developer).
+ (nullable instancetype)connectWithDeveloperDirectory:(NSString *)developerDir
                                                 error:(NSError *_Nullable *_Nullable)error;

@property (nonatomic, readonly, copy) NSString *developerDirectory;
/// Paths of the frameworks that were loaded, for diagnostics.
@property (nonatomic, readonly, copy) NSArray<NSString *> *loadedFrameworks;

- (NSArray<OSDeviceSnapshot *> *)devices;

/// Calls `handler` on the main queue whenever any device in the default set changes. Returns a
/// token for `removeDeviceObserver:`, or 0 when this Xcode does not offer notifications.
- (NSUInteger)addDeviceObserver:(void (^)(void))handler;
- (void)removeDeviceObserver:(NSUInteger)token;

- (nullable OSDisplayStream *)openDisplayForDevice:(NSString *)udid
                                             error:(NSError *_Nullable *_Nullable)error;
- (nullable OSHIDClient *)openHIDForDevice:(NSString *)udid
                                     error:(NSError *_Nullable *_Nullable)error;

/// `orientation` is the GSEvent value: 1 portrait, 2 upside down, 3 landscape right, 4 landscape left.
- (BOOL)setOrientation:(uint32_t)orientation
             forDevice:(NSString *)udid
                 error:(NSError *_Nullable *_Nullable)error;
- (BOOL)simulateMemoryWarningForDevice:(NSString *)udid
                                 error:(NSError *_Nullable *_Nullable)error;
/// Connects the Mac keyboard as the device's hardware keyboard, which hides the on-screen one.
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled
                         forDevice:(NSString *)udid
                             error:(NSError *_Nullable *_Nullable)error;

- (instancetype)init NS_UNAVAILABLE;
@end

FOUNDATION_EXPORT NSErrorDomain const OSSimBridgeErrorDomain;

NS_ASSUME_NONNULL_END
