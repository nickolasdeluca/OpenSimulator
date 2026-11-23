// Sets a foldable simulator's hinge angle, which is how iOS decides whether the iPhone Duo is
// closed (cover panel) or open (inner panel).
//
// Device Hub does this through CoreDevice, whose dtuhidd daemon dispatches a vendor-defined HID
// event that locationd reads as a Virtualization control: usage page 0xFF61, usage 0x5B, carrying
// an IOKit binary-serialized dictionary that names the control and its value. This dispatches the
// same event from inside the device, which the simulator allows without an entitlement.
//
// The app ships this source and builds it for the simulator on first use, with the selected Xcode
// (see Sources/SimulatorCore/GuestHelper.swift), then runs it with
// `simctl spawn <udid> set-hinge-angle <degrees>`.

#import <Foundation/Foundation.h>
#import <IOKit/IOCFSerialize.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef IOHIDEventRef (*VendorEventCreate)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                           const uint8_t *, CFIndex, uint32_t);
typedef IOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
typedef void (*Dispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

static const uint32_t kVirtualizationControlPage = 0xFF61;
static const uint32_t kVirtualizationControlUsage = 0x5B;

static BOOL dispatchControl(IOHIDEventSystemClientRef client, VendorEventCreate create, Dispatch dispatch,
                            NSDictionary *control) {
    NSMutableDictionary *payload = [control mutableCopy];
    payload[@"provider"] = @"com.apple.Virtualization.VirtualMachines";
    CFDataRef data = IOCFSerialize((__bridge CFTypeRef)payload, kIOCFSerializeToBinary);
    if (!data) { return NO; }
    IOHIDEventRef event = create(kCFAllocatorDefault, mach_absolute_time(), kVirtualizationControlPage,
                                 kVirtualizationControlUsage, 0, CFDataGetBytePtr(data), CFDataGetLength(data), 0);
    CFRelease(data);
    if (!event) { return NO; }
    dispatch(client, event);
    CFRelease(event);
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: set-hinge-angle <degrees>\n");
            return 64;
        }
        double degrees = atof(argv[1]);
        if (degrees < 0 || degrees > 180) {
            fprintf(stderr, "The angle must be between 0 and 180 degrees.\n");
            return 64;
        }

        // Private API: looked up first, so a renamed function fails with a message instead of a crash.
        VendorEventCreate create = (VendorEventCreate)dlsym(RTLD_DEFAULT, "IOHIDEventCreateVendorDefinedEvent");
        ClientCreate createClient = (ClientCreate)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
        Dispatch dispatch = (Dispatch)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        IOHIDEventSystemClientRef client = createClient ? createClient(kCFAllocatorDefault) : NULL;
        if (!create || !dispatch || !client) {
            fprintf(stderr, "This iOS version can't simulate the hinge.\n");
            return 69;
        }

        // locationd only works out the posture once it also knows the orientation, as Device Hub sends it.
        BOOL sent = dispatchControl(client, create, dispatch,
                                    @{@"source": @"orientation-picker-control", @"type": @"enum", @"value": @"portrait"}) &&
                    dispatchControl(client, create, dispatch,
                                    @{@"source": @"hinge-slider-control", @"type": @"range", @"value": @(degrees)});
        CFRelease(client);
        if (!sent) {
            fprintf(stderr, "The hinge event couldn't be created.\n");
            return 1;
        }
        // Dispatching is asynchronous, so the process waits a moment before it exits.
        [NSThread sleepForTimeInterval:0.3];
    }
    return 0;
}
