// Indigo HID messages for touch, keyboard and hardware buttons.
//
// The single touch envelope, its offsets, and the button / consumer constants are adapted from idb
// (Meta Platforms, MIT) and Siniulator (Krzysztof Magiera, MIT), as verified and documented by
// OpenDeviceHub (Samuel Abada, MIT) on Xcode 26.5 and Xcode 27. See THIRD_PARTY_NOTICES.md.

#import "OSInternal.h"
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef void *_Nullable (*OSMouseBuilder)(CGPoint *_Nullable, CGPoint *_Nullable, uint32_t, NSUInteger, CGSize, uint32_t);
typedef void *_Nullable (*OSKeyboardBuilder)(int32_t usage, int32_t down);
typedef void *_Nullable (*OSButtonBuilder)(int32_t source, int32_t direction, int32_t target);
typedef void *_Nullable (*OSArbitraryBuilder)(int32_t target, uint32_t page, uint32_t usage, int32_t direction);

// Targets and directions.
static const uint32_t kTouchTarget = 0x32;
static const int32_t kButtonTarget = 0x33;
static const int32_t kButtonDown = 1;
static const int32_t kButtonUp = 2;
static const uint32_t kConsumerPage = 0x0c;
// The builder only knows contact down (1) and up (2); a move is a down at the new position.
static const NSUInteger kContactDown = 1;
static const NSUInteger kContactUp = 2;

// The builder's message, as patched for a single contact.
static const size_t kRatioX = 0x3c;
static const size_t kRatioY = 0x44;
// The hand-built single touch envelope.
static const size_t kMessageSize = 320;
static const size_t kInnerSizeOffset = 0x18;
static const uint32_t kInnerSize = 144;
static const size_t kEventTypeOffset = 0x1c;
static const uint8_t kEventTypeSingleTouch = 2;
static const size_t kPayloadOffset = 0x20;
static const uint32_t kEventKindTouch = 11;
static const size_t kTimestampOffset = 0x24;
static const size_t kContactOffset = 0x30;
static const size_t kContactBytes = 112;
static const size_t kSecondPayloadOffset = 0xb0;
static const size_t kSecondMarkerA = 0xc0;
static const size_t kSecondMarkerB = 0xc4;
// The builder's own two-contact message: first finger, a duplicate of it, then the second.
static const size_t kTwoFirstX = 0x3c, kTwoFirstY = 0x44;
static const size_t kTwoDupX = 0xdc, kTwoDupY = 0xe4;
static const size_t kTwoSecondX = 0x17c, kTwoSecondY = 0x184;

static inline void OSWriteDouble(void *base, size_t offset, double value) {
    memcpy((uint8_t *)base + offset, &value, sizeof(value));
}

static inline void OSWriteU32(void *base, size_t offset, uint32_t value) {
    memcpy((uint8_t *)base + offset, &value, sizeof(value));
}

@implementation OSHIDClient {
    id<OSPSimDeviceLegacyHIDClient> _client;
    dispatch_queue_t _queue;
    OSMouseBuilder _mouse;
    OSKeyboardBuilder _keyboard;
    OSButtonBuilder _button;
    OSArbitraryBuilder _arbitrary;
}

- (instancetype)initWithDevice:(id)device simulatorKitPath:(NSString *)path error:(NSError **)error {
    if (!(self = [super init])) { return nil; }

    void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    _mouse = handle ? (OSMouseBuilder)dlsym(handle, "IndigoHIDMessageForMouseNSEvent") : NULL;
    _keyboard = handle ? (OSKeyboardBuilder)dlsym(handle, "IndigoHIDMessageForKeyboardArbitrary") : NULL;
    _button = handle ? (OSButtonBuilder)dlsym(handle, "IndigoHIDMessageForButton") : NULL;
    _arbitrary = handle ? (OSArbitraryBuilder)dlsym(handle, "IndigoHIDMessageForHIDArbitrary") : NULL;
    if (!_mouse || !_keyboard || !_button || !_arbitrary) {
        if (error) { *error = OSMakeError(30, @"SimulatorKit is missing the Indigo HID message builders."); }
        return nil;
    }

    // A Swift class in SimulatorKit, so it must be created with +alloc rather than the runtime.
    Class clientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    if (!clientClass || ![clientClass instancesRespondToSelector:@selector(initWithDevice:error:)]) {
        if (error) { *error = OSMakeError(31, @"SimulatorKit has no SimDeviceLegacyHIDClient."); }
        return nil;
    }
    NSError *initError = nil;
    id<OSPSimDeviceLegacyHIDClient> client = [(id<OSPSimDeviceLegacyHIDClient>)[clientClass alloc] initWithDevice:device
                                                                                                          error:&initError];
    if (!client || ![(id)client respondsToSelector:@selector(sendWithMessage:freeWhenDone:completionQueue:completion:)]) {
        if (error) {
            *error = OSMakeError(32, @"Could not connect input to the device: %@",
                                 initError.localizedDescription ?: @"no HID client");
        }
        return nil;
    }
    _client = client;
    _queue = dispatch_queue_create("OpenSimulator.hid", DISPATCH_QUEUE_SERIAL);
    return self;
}

/// Takes ownership of `message`, which must come from malloc.
- (void)send:(void *_Nullable)message {
    if (!message) { return; }
    [_client sendWithMessage:message freeWhenDone:YES completionQueue:_queue completion:^(NSError *error) {
        if (error) { NSLog(@"OpenSimulator: HID send failed: %@", error.localizedDescription); }
    }];
}

static inline NSUInteger OSContactType(OSTouchPhase phase) {
    return phase == OSTouchPhaseUp ? kContactUp : kContactDown;
}

- (void)sendTouchAt:(CGPoint)point phase:(OSTouchPhase)phase edge:(OSTouchEdge)edge {
    // The builder always produces a multi-touch message with an implied second contact, which the
    // guest reads as a two finger gesture. So the contact is copied into a single-touch envelope.
    CGPoint contact = point;
    void *source = _mouse(&contact, NULL, kTouchTarget, OSContactType(phase), CGSizeMake(1, 1), edge);
    if (!source) { return; }
    OSWriteDouble(source, kRatioX, point.x);
    OSWriteDouble(source, kRatioY, point.y);

    uint8_t *message = calloc(1, kMessageSize);
    if (!message) { free(source); return; }
    uint64_t timestamp = mach_absolute_time();
    OSWriteU32(message, kInnerSizeOffset, kInnerSize);
    message[kEventTypeOffset] = kEventTypeSingleTouch;
    OSWriteU32(message, kPayloadOffset, kEventKindTouch);
    memcpy(message + kTimestampOffset, &timestamp, sizeof(timestamp));
    memcpy(message + kContactOffset, (uint8_t *)source + kContactOffset, kContactBytes);
    free(source);

    memcpy(message + kSecondPayloadOffset, message + kPayloadOffset, kInnerSize);
    OSWriteU32(message, kSecondMarkerA, 1);
    OSWriteU32(message, kSecondMarkerB, 2);
    [self send:message];
}

- (void)sendTouchesAt:(CGPoint)first and:(CGPoint)second phase:(OSTouchPhase)phase {
    CGPoint a = first, b = second;
    void *message = _mouse(&a, &b, kTouchTarget, OSContactType(phase), CGSizeMake(1, 1), OSTouchEdgeNone);
    if (!message) { return; }
    // The guest reads the duplicate payload for the leading finger, so both copies are written.
    OSWriteDouble(message, kTwoFirstX, first.x);
    OSWriteDouble(message, kTwoFirstY, first.y);
    OSWriteDouble(message, kTwoDupX, first.x);
    OSWriteDouble(message, kTwoDupY, first.y);
    OSWriteDouble(message, kTwoSecondX, second.x);
    OSWriteDouble(message, kTwoSecondY, second.y);
    [self send:message];
}

- (void)sendKeyUsage:(uint32_t)usage down:(BOOL)down {
    [self send:_keyboard((int32_t)usage, down ? 1 : 0)];
}

- (void)sendButton:(OSHardwareButton)button down:(BOOL)down {
    int32_t direction = down ? kButtonDown : kButtonUp;
    switch (button) {
        case OSHardwareButtonHome:
            [self send:_button(0, direction, kButtonTarget)];
            break;
        case OSHardwareButtonLock:
            [self send:_button(1, direction, kButtonTarget)];
            break;
        case OSHardwareButtonSiri:
            [self send:_button(0x400002, direction, kButtonTarget)];
            break;
        case OSHardwareButtonVolumeUp:
            [self send:_arbitrary((int32_t)kTouchTarget, kConsumerPage, 0xe9, direction)];
            break;
        case OSHardwareButtonVolumeDown:
            [self send:_arbitrary((int32_t)kTouchTarget, kConsumerPage, 0xea, direction)];
            break;
    }
}

@end
