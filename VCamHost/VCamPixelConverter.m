// VCamPixelConverter.m -- The shared Metal-backed CIContext
#import "VCamPixelConverter.h"
#import "VCamDiagnostics.h"
#import "VCamTypes.h"
#import <Metal/Metal.h>

@implementation VCamPixelConverter {
    id<MTLDevice> _device;
    CIContext    *_ciContext;
    BOOL          _ready;
}

+ (VCamPixelConverter *)sharedConverter {
    static VCamPixelConverter *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

// -- Setup ----------------------------------------------------------------
// NEVER do this work synchronously from a dylib constructor. cameracaptured's
// startup is on SpringBoard's critical path during boot -- it waits
// synchronously on the torch XPC service -- and the daemon runs its own GPU
// prewarm at the same time. Deferring costs a handful of early frames, which
// nobody can see, and removes an entire class of boot hang.
- (void)setup {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self ensureReady];
    });
}

- (void)ensureReady {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ [self reallySetup]; });
}

- (void)reallySetup {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        VCamLogE("converter: no Metal device -- cannot render");
        vcam_diag_set_last_error(VCamDiagErrorMetalUnavailable);
        return;
    }

    // A defined working colour space matters. Rendering into a YCbCr buffer
    // with colour management switched off is ambiguous and shifts colour:
    // sRGB in, and each destination buffer's own attachments declare BT.709
    // on the way out, which is what CoreImage converts to.
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (srgb) opts[kCIContextWorkingColorSpace] = (__bridge id)srgb;
    opts[kCIContextHighQualityDownsample] = @NO;
    opts[kCIContextCacheIntermediates]    = @NO;   // one frame in flight; no reuse

    _ciContext = [CIContext contextWithMTLDevice:_device options:opts];
    if (srgb) CGColorSpaceRelease(srgb);

    if (!_ciContext) {
        VCamLogE("converter: CIContext creation failed");
        vcam_diag_set_last_error(VCamDiagErrorMetalUnavailable);
        return;
    }

    _ready = YES;
    VCamLogI("converter: ready on '%{public}@'", _device.name);
}

- (CIContext *)ciContext { return _ciContext; }   // nil until setup completes
- (BOOL)isReady          { return _ready;     }

@end
