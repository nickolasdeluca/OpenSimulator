#import "OSInternal.h"
#import <dlfcn.h>
#import <mach/mach.h>

NSErrorDomain const OSSimBridgeErrorDomain = @"OpenSimulator.SimBridge";

NSError *OSMakeError(NSInteger code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:OSSimBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static inline BOOL OSSetError(NSError **out, NSError *error) {
    if (out) { *out = error; }
    return NO;
}

#pragma mark - Device snapshot

@implementation OSDeviceSnapshot

- (instancetype)initWithDevice:(id<OSPSimDevice>)device {
    if ((self = [super init])) {
        _udid = device.UDID.UUIDString ?: @"";
        _name = device.name ?: _udid;
        _state = (OSDeviceState)device.state;
        id<OSPSimDeviceType> type = device.deviceType;
        _deviceTypeIdentifier = type.identifier ?: @"";
        _deviceTypeName = type.name ?: @"";
        _pointScale = type ? type.mainScreenScale : 1;
        _mainScreenPixelSize = type ? type.mainScreenSize : CGSizeZero;
        _runtimeIdentifier = device.runtimeIdentifier ?: @"";
        // A device whose runtime has been uninstalled has no runtime object but keeps the identifier.
        _runtimeName = device.runtime.name ?: _runtimeIdentifier;
        _available = device.available;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ %@ state=%ld>", self.name, self.udid, self.runtimeName, (long)self.state];
}

@end

#pragma mark - Core simulator

@implementation OSCoreSimulator {
    id<OSPSimServiceContext> _context;
    NSString *_simulatorKitPath;
    NSMutableDictionary<NSNumber *, id> *_observerSets;
}

+ (NSArray<NSString *> *)candidatesForFramework:(NSString *)relative
                                   developerDir:(NSString *)developerDir
                                      sharedDir:(nullable NSString *)sharedDir {
    NSMutableArray *paths = [NSMutableArray array];
    if (sharedDir) {
        [paths addObject:[sharedDir stringByAppendingPathComponent:relative]];
    }
    [paths addObject:[@"/Library/Developer/PrivateFrameworks" stringByAppendingPathComponent:relative]];
    [paths addObject:[[developerDir stringByAppendingPathComponent:@"Library/PrivateFrameworks"]
                         stringByAppendingPathComponent:relative]];
    return paths;
}

+ (nullable NSString *)loadFirstOf:(NSArray<NSString *> *)paths attempts:(NSMutableArray<NSString *> *)attempts {
    for (NSString *path in paths) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [attempts addObject:[NSString stringWithFormat:@"%@ (missing)", path]];
            continue;
        }
        if (dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL)) {
            return path;
        }
        const char *reason = dlerror();
        [attempts addObject:[NSString stringWithFormat:@"%@ (%s)", path, reason ?: "dlopen failed"]];
    }
    return nil;
}

+ (instancetype)connectWithDeveloperDirectory:(NSString *)developerDir error:(NSError **)error {
    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    NSMutableArray<NSString *> *loaded = [NSMutableArray array];

    NSString *coreSimulator = [self loadFirstOf:[self candidatesForFramework:@"CoreSimulator.framework/CoreSimulator"
                                                                developerDir:developerDir
                                                                   sharedDir:nil]
                                       attempts:attempts];
    if (!coreSimulator) {
        OSSetError(error, OSMakeError(1, @"CoreSimulator could not be loaded. Tried:\n%@",
                                      [attempts componentsJoinedByString:@"\n"]));
        return nil;
    }
    [loaded addObject:coreSimulator];

    // Xcode 27 moved SimulatorKit from the developer directory into the app's SharedFrameworks.
    NSString *sharedDir = nil;
    if ([developerDir hasSuffix:@"/Contents/Developer"]) {
        sharedDir = [[developerDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SharedFrameworks"];
    }
    NSString *simulatorKit = [self loadFirstOf:[self candidatesForFramework:@"SimulatorKit.framework/SimulatorKit"
                                                               developerDir:developerDir
                                                                  sharedDir:sharedDir]
                                      attempts:attempts];
    if (simulatorKit) {
        [loaded addObject:simulatorKit];
    }

    Class contextClass = NSClassFromString(@"SimServiceContext");
    SEL sharedSelector = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
    if (!contextClass || ![contextClass respondsToSelector:sharedSelector]) {
        OSSetError(error, OSMakeError(2, @"This Xcode's CoreSimulator does not offer SimServiceContext."));
        return nil;
    }
    NSError *contextError = nil;
    id<OSPSimServiceContext> context =
        [(id<OSPSimServiceContextClass>)contextClass sharedServiceContextForDeveloperDir:developerDir
                                                                                   error:&contextError];
    if (!context || ![(id)context respondsToSelector:@selector(defaultDeviceSetWithError:)]) {
        OSSetError(error, OSMakeError(3, @"Could not reach CoreSimulatorService: %@",
                                      contextError.localizedDescription ?: @"no service context"));
        return nil;
    }

    OSCoreSimulator *simulator = [[self alloc] initPrivate];
    simulator->_context = context;
    simulator->_developerDirectory = [developerDir copy];
    simulator->_loadedFrameworks = [loaded copy];
    simulator->_simulatorKitPath = simulatorKit;
    simulator->_observerSets = [NSMutableDictionary dictionary];
    return simulator;
}

- (instancetype)initPrivate {
    return [super init];
}

- (nullable id<OSPSimDeviceSet>)deviceSet:(NSError **)error {
    return [_context defaultDeviceSetWithError:error];
}

- (NSArray<OSDeviceSnapshot *> *)devices {
    @synchronized (self) {
        NSMutableArray *result = [NSMutableArray array];
        for (id element in [self deviceSet:nil].devices ?: @[]) {
            id<OSPSimDevice> device = element;
            if (!device.UDID) { continue; }
            [result addObject:[[OSDeviceSnapshot alloc] initWithDevice:device]];
        }
        return result;
    }
}

- (nullable id<OSPSimDevice>)deviceWithUDID:(NSString *)udid error:(NSError **)error {
    for (id element in [self deviceSet:error].devices ?: @[]) {
        id<OSPSimDevice> device = element;
        if ([device.UDID.UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) {
            return device;
        }
    }
    OSSetError(error, OSMakeError(4, @"No simulator with UDID %@.", udid));
    return nil;
}

- (nullable id<OSPSimDevice>)bootedDeviceWithUDID:(NSString *)udid error:(NSError **)error {
    id<OSPSimDevice> device = [self deviceWithUDID:udid error:error];
    if (!device) { return nil; }
    if (device.state != OSDeviceStateBooted) {
        OSSetError(error, OSMakeError(5, @"%@ is not booted.", device.name ?: udid));
        return nil;
    }
    return device;
}

#pragma mark Observers

- (NSUInteger)addDeviceObserver:(void (^)(void))handler {
    @synchronized (self) {
        id<OSPSimDeviceSet> set = [self deviceSet:nil];
        if (![(id)set respondsToSelector:@selector(registerNotificationHandlerOnQueue:handler:)]) {
            return 0;
        }
        NSUInteger token = [set registerNotificationHandlerOnQueue:dispatch_get_main_queue()
                                                           handler:^(id _Nullable notification) {
            handler();
        }];
        if (token != 0) {
            _observerSets[@(token)] = set;
        }
        return token;
    }
}

- (void)removeDeviceObserver:(NSUInteger)token {
    @synchronized (self) {
        id<OSPSimDeviceSet> set = _observerSets[@(token)];
        if (!set) { return; }
        [_observerSets removeObjectForKey:@(token)];
        if ([(id)set respondsToSelector:@selector(unregisterNotificationHandler:error:)]) {
            [set unregisterNotificationHandler:token error:nil];
        }
    }
}

#pragma mark Display and input

- (OSDisplayStream *)openDisplayForDevice:(NSString *)udid error:(NSError **)error {
    @synchronized (self) {
        id<OSPSimDevice> device = [self bootedDeviceWithUDID:udid error:error];
        if (!device) { return nil; }
        id<OSPSimDeviceIO> io = device.io;
        if (![(id)io respondsToSelector:@selector(ioPorts)]) {
            OSSetError(error, OSMakeError(6, @"%@ has no device IO.", device.name));
            return nil;
        }

        Protocol *renderable = NSProtocolFromString(@"SimDisplayRenderable");
        Protocol *surfaceRenderable = NSProtocolFromString(@"SimDisplayIOSurfaceRenderable");
        Protocol *descriptorState = NSProtocolFromString(@"SimDisplayDescriptorState");
        if (!renderable || !surfaceRenderable || !descriptorState) {
            OSSetError(error, OSMakeError(7, @"This Xcode's CoreSimDeviceIO lacks the display protocols."));
            return nil;
        }

        // Pick the built-in panel whose size matches the device type's main screen. A foldable has
        // one built-in port per panel, and its main screen is the cover.
        CGSize mainSize = device.deviceType.mainScreenSize;
        id chosen = nil;
        for (id element in io.ioPorts ?: @[]) {
            id<OSPSimDeviceIOPort> port = element;
            if (![(id)port respondsToSelector:@selector(descriptor)]) { continue; }
            id descriptor = port.descriptor;
            if (![descriptor conformsToProtocol:renderable] || ![descriptor conformsToProtocol:surfaceRenderable]) {
                continue;
            }
            id state = [(id<OSPSimDeviceIOPortDescriptor>)descriptor state];
            if (![state conformsToProtocol:descriptorState]) { continue; }
            if ([(id<OSPSimDisplayDescriptorState>)state displayClass] != 0) { continue; }

            if (!chosen) { chosen = descriptor; }
            if (CGSizeEqualToSize([(id<OSPSimDisplayRenderable>)descriptor displaySize], mainSize)) {
                chosen = descriptor;
                break;
            }
        }
        if (!chosen) {
            OSSetError(error, OSMakeError(8, @"%@ has no display yet. It may still be booting.", device.name));
            return nil;
        }
        return [[OSDisplayStream alloc] initWithDescriptor:chosen error:error];
    }
}

- (OSHIDClient *)openHIDForDevice:(NSString *)udid error:(NSError **)error {
    @synchronized (self) {
        if (!_simulatorKitPath) {
            OSSetError(error, OSMakeError(9, @"SimulatorKit was not found in this Xcode, so input is unavailable."));
            return nil;
        }
        id<OSPSimDevice> device = [self bootedDeviceWithUDID:udid error:error];
        if (!device) { return nil; }
        return [[OSHIDClient alloc] initWithDevice:device simulatorKitPath:_simulatorKitPath error:error];
    }
}

#pragma mark Device actions

// The orientation message is a Purple GSEvent sent to the guest's workspace port, which is how the
// classic Simulator turned the device. Layout adapted from Siniulator (MIT) via OpenDeviceHub (MIT).
- (BOOL)setOrientation:(uint32_t)orientation forDevice:(NSString *)udid error:(NSError **)error {
    mach_port_t port = 0;
    @synchronized (self) {
        id<OSPSimDevice> device = [self bootedDeviceWithUDID:udid error:error];
        if (!device) { return NO; }
        if (![(id)device respondsToSelector:@selector(lookup:error:)]) {
            return OSSetError(error, OSMakeError(10, @"This Xcode cannot look up guest services."));
        }
        port = [device lookup:@"PurpleWorkspacePort" error:nil];
    }
    if (port == 0) {
        return OSSetError(error, OSMakeError(11, @"The device is not ready to rotate yet."));
    }

    uint8_t buffer[112] = {0};
    const mach_msg_size_t size = 108;
    *(uint32_t *)(buffer + 0x00) = 0x13;           // msgh_bits: copy send
    *(uint32_t *)(buffer + 0x04) = size;           // msgh_size
    *(uint32_t *)(buffer + 0x08) = port;           // msgh_remote_port
    *(uint32_t *)(buffer + 0x14) = 0x7b;           // msgh_id
    *(uint32_t *)(buffer + 0x18) = 50 | 0x20000;   // GSEvent type: device orientation changed
    *(uint32_t *)(buffer + 0x48) = 4;              // record subtype
    *(uint32_t *)(buffer + 0x4c) = orientation;

    kern_return_t result = mach_msg((mach_msg_header_t *)buffer, MACH_SEND_MSG | MACH_SEND_TIMEOUT, size, 0,
                                    MACH_PORT_NULL, 2000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), port);
    if (result != KERN_SUCCESS) {
        return OSSetError(error, OSMakeError(12, @"Rotation failed: %s", mach_error_string(result)));
    }
    return YES;
}

- (BOOL)simulateMemoryWarningForDevice:(NSString *)udid error:(NSError **)error {
    @synchronized (self) {
        id<OSPSimDevice> device = [self bootedDeviceWithUDID:udid error:error];
        if (!device) { return NO; }
        if (![(id)device respondsToSelector:@selector(simulateMemoryWarning)]) {
            return OSSetError(error, OSMakeError(13, @"This Xcode cannot simulate memory warnings."));
        }
        [device simulateMemoryWarning];
        return YES;
    }
}

- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled forDevice:(NSString *)udid error:(NSError **)error {
    @synchronized (self) {
        id<OSPSimDevice> device = [self bootedDeviceWithUDID:udid error:error];
        if (!device) { return NO; }
        SEL selector = @selector(setHardwareKeyboardEnabled:keyboardType:error:);
        typedef unsigned char (*KeyboardTypeFunction)(void);
        KeyboardTypeFunction keyboardType = (KeyboardTypeFunction)dlsym(RTLD_DEFAULT, "IndigoHIDGetKeyboardType");
        // Both halves are required: a made-up keyboard type is not safe to hand the device.
        if (![(id)device respondsToSelector:selector] || !keyboardType) {
            return OSSetError(error, OSMakeError(14, @"This Xcode cannot toggle the hardware keyboard."));
        }
        return [device setHardwareKeyboardEnabled:enabled keyboardType:keyboardType() error:error];
    }
}

@end
