#import "OSInternal.h"
#import <IOSurface/IOSurfaceRef.h>

static IOSurfaceRef _Nullable OSSurfaceFromObject(id _Nullable object) {
    if (!object) { return NULL; }
    CFTypeRef value = (__bridge CFTypeRef)object;
    return CFGetTypeID(value) == IOSurfaceGetTypeID() ? (IOSurfaceRef)value : NULL;
}

@implementation OSDisplayStream {
    id _descriptor;
    BOOL _usesScreenCallbacks;
    NSUUID *_token;
    dispatch_queue_t _queue;
    // Guarded by _queue. Retained CF references.
    IOSurfaceRef _surface;
    IOSurfaceRef _maskedSurface;
    void (^_handler)(IOSurfaceRef);
    BOOL _running;
    BOOL _prefersMasked;
}

- (instancetype)initWithDescriptor:(id)descriptor error:(NSError **)error {
    if (!(self = [super init])) { return nil; }

    id<OSPSimDisplayRenderable> renderable = descriptor;
    BOOL hasLegacy = [descriptor respondsToSelector:@selector(registerCallbackWithUUID:damageRectanglesCallback:)] &&
                     [descriptor respondsToSelector:@selector(registerCallbackWithUUID:ioSurfacesChangeCallback:)];
    Protocol *screen = NSProtocolFromString(@"SimScreen");
    BOOL hasScreen = screen && [descriptor conformsToProtocol:screen] &&
        [descriptor respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)];
    if (!hasScreen && !hasLegacy) {
        if (error) { *error = OSMakeError(20, @"This Xcode's display port offers no frame callbacks."); }
        return nil;
    }

    _descriptor = descriptor;
    _usesScreenCallbacks = hasScreen;
    _pixelSize = renderable.displaySize;
    _pixelsPerInch = [descriptor respondsToSelector:@selector(displayPitch)] ? renderable.displayPitch : 0;
    _queue = dispatch_queue_create("OpenSimulator.display", DISPATCH_QUEUE_SERIAL);
    _prefersMasked = YES;
    [self refreshSurfacesFromDescriptor];
    return self;
}

- (void)dealloc {
    // No dispatch_sync here: the last reference can be dropped on _queue itself.
    if (_token) { [self unregisterToken:_token]; }
    if (_surface) { CFRelease(_surface); }
    if (_maskedSurface) { CFRelease(_maskedSurface); }
}

- (void)replaceSurface:(IOSurfaceRef _Nullable)surface masked:(IOSurfaceRef _Nullable)masked {
    if (surface) { CFRetain(surface); }
    if (masked) { CFRetain(masked); }
    if (_surface) { CFRelease(_surface); }
    if (_maskedSurface) { CFRelease(_maskedSurface); }
    _surface = surface;
    _maskedSurface = masked;
}

- (void)refreshSurfacesFromDescriptor {
    id<OSPSimDisplayIOSurfaceRenderable> renderable = _descriptor;
    [self replaceSurface:OSSurfaceFromObject(renderable.framebufferSurface)
                  masked:OSSurfaceFromObject(renderable.maskedFramebufferSurface)];
}

- (IOSurfaceRef)pickSurface {
    return (_prefersMasked && _maskedSurface) ? _maskedSurface : _surface;
}

- (BOOL)prefersMaskedSurface {
    __block BOOL value;
    dispatch_sync(_queue, ^{ value = self->_prefersMasked; });
    return value;
}

- (void)setPrefersMaskedSurface:(BOOL)prefersMaskedSurface {
    dispatch_async(_queue, ^{
        self->_prefersMasked = prefersMaskedSurface;
        [self emit];
    });
}

- (BOOL)isRunning {
    __block BOOL value;
    dispatch_sync(_queue, ^{ value = self->_running; });
    return value;
}

- (IOSurfaceRef)currentSurface {
    __block IOSurfaceRef surface;
    dispatch_sync(_queue, ^{ surface = [self pickSurface]; });
    return surface;
}

/// Runs on _queue.
- (void)emit {
    IOSurfaceRef surface = [self pickSurface];
    if (_running && _handler && surface) {
        _handler(surface);
    }
}

- (void)startWithHandler:(void (^)(IOSurfaceRef))handler {
    __block NSUUID *token = nil;
    dispatch_sync(_queue, ^{
        self->_handler = [handler copy];
        if (self->_running) { return; }
        self->_running = YES;
        self->_token = [NSUUID UUID];
        token = self->_token;
    });
    if (!token) { return; }

    __weak OSDisplayStream *weakSelf = self;
    if (_usesScreenCallbacks) {
        [(id<OSPSimScreen>)_descriptor registerScreenCallbacksWithUUID:token
            callbackQueue:_queue
            frameCallback:^{ [weakSelf emit]; }
            surfacesChangedCallback:^(id primary, id masked) {
                OSDisplayStream *strongSelf = weakSelf;
                if (!strongSelf) { return; }
                [strongSelf replaceSurface:OSSurfaceFromObject(primary) masked:OSSurfaceFromObject(masked)];
                [strongSelf emit];
            }
            propertiesChangedCallback:^(id properties) {}];
    } else {
        dispatch_queue_t queue = _queue;
        [(id<OSPSimDisplayIOSurfaceRenderable>)_descriptor registerCallbackWithUUID:token
            ioSurfacesChangeCallback:^(id ignored) {
                dispatch_async(queue, ^{
                    OSDisplayStream *strongSelf = weakSelf;
                    [strongSelf refreshSurfacesFromDescriptor];
                    [strongSelf emit];
                });
            }];
        [(id<OSPSimDisplayRenderable>)_descriptor registerCallbackWithUUID:token
            damageRectanglesCallback:^(id ignored) {
                dispatch_async(queue, ^{ [weakSelf emit]; });
            }];
    }

    // The guest only redraws on change, so show what is there now rather than waiting for the next.
    dispatch_async(_queue, ^{
        [self refreshSurfacesFromDescriptor];
        [self emit];
    });
}

- (void)stop {
    __block NSUUID *token = nil;
    dispatch_sync(_queue, ^{
        if (!self->_running) { return; }
        self->_running = NO;
        self->_handler = nil;
        token = self->_token;
        self->_token = nil;
    });
    if (token) { [self unregisterToken:token]; }
}

- (void)unregisterToken:(NSUUID *)token {
    if (_usesScreenCallbacks) {
        [(id<OSPSimScreen>)_descriptor unregisterScreenCallbacksWithUUID:token];
    } else {
        [(id<OSPSimDisplayRenderable>)_descriptor unregisterDamageRectanglesCallbackWithUUID:token];
        [(id<OSPSimDisplayIOSurfaceRenderable>)_descriptor unregisterIOSurfacesChangeCallbackWithUUID:token];
    }
}

@end
