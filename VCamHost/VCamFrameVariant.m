// VCamFrameVariant.m -- One output shape, pooled
#import "VCamFrameVariant.h"
#import "VCamTypes.h"
#import <mach/mach_time.h>
#include <stdatomic.h>

// Formats we can actually produce. Anything else makes -initWith... fail, and
// the caller passes the real camera frame through untouched rather than
// delivering a buffer the client cannot interpret.
static BOOL vcam_format_supported(OSType f) {
    switch (f) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:   // '420v'
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:    // '420f'
        case kCVPixelFormatType_32BGRA:                         // 'BGRA'
        case kCVPixelFormatType_32ARGB:
            return YES;
        default:
            return NO;
    }
}

static BOOL vcam_format_is_planar_ycbcr(OSType f) {
    return f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

/// Declares the colour of the pixels we are about to write. Set BEFORE
/// rendering: CoreImage reads these attachments when converting into a YCbCr
/// buffer, so attaching them up front makes the pixels match the description
/// rather than merely claiming to.
static void vcam_attach_color_metadata(CVPixelBufferRef buf, OSType format) {
    if (!buf) return;

    CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);

    // Only meaningful for YCbCr. On an RGB buffer a matrix attachment is noise
    // and some consumers object to it.
    if (vcam_format_is_planar_ycbcr(format)) {
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
    }
}

@implementation VCamFrameVariant {
    CVPixelBufferPoolRef _pool;
    CFDictionaryRef      _auxAttributes;
    CVPixelBufferRef     _cached;
    uint64_t             _generation;
    uint64_t             _lastUsed;
}

@synthesize width       = _width;
@synthesize height      = _height;
@synthesize pixelFormat = _pixelFormat;

+ (BOOL)supportsPixelFormat:(OSType)pixelFormat {
    return vcam_format_supported(pixelFormat);
}

+ (const char *)describeFormat:(OSType)f {
    // Four static slots so a log line can name a couple of formats at once
    // without the caller managing storage.
    static char bufs[4][8];
    static _Atomic unsigned next = 0;
    unsigned slot = atomic_fetch_add_explicit(&next, 1, memory_order_relaxed) % 4;
    char *b = bufs[slot];
    b[0] = (char)((f >> 24) & 0xFF);
    b[1] = (char)((f >> 16) & 0xFF);
    b[2] = (char)((f >>  8) & 0xFF);
    b[3] = (char)( f        & 0xFF);
    b[4] = '\0';
    for (int i = 0; i < 4; i++) {
        if (b[i] < 32 || b[i] > 126) b[i] = '?';
    }
    return b;
}

- (instancetype)initWithWidth:(size_t)width
                       height:(size_t)height
                  pixelFormat:(OSType)pixelFormat {
    if (!(self = [super init])) return nil;

    if (!vcam_format_supported(pixelFormat)) {
        VCamLogI("variant: unsupported format %{public}s -- declining",
                 [VCamFrameVariant describeFormat:pixelFormat]);
        return nil;
    }

    // Planar 4:2:0 needs even dimensions for its half-resolution chroma plane.
    if (vcam_format_is_planar_ycbcr(pixelFormat)) {
        width  &= ~(size_t)1;
        height &= ~(size_t)1;
    }

    // Sanity bounds. A corrupt format description must not turn into a
    // multi-gigabyte allocation inside the camera daemon.
    if (width < 16 || height < 16 || width > 8192 || height > 8192) {
        VCamLogE("variant: refusing implausible geometry %zux%zu", width, height);
        return nil;
    }

    _width       = width;
    _height      = height;
    _pixelFormat = pixelFormat;

    NSDictionary *pixelAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:     @(pixelFormat),
        (NSString *)kCVPixelBufferWidthKey:                @(width),
        (NSString *)kCVPixelBufferHeightKey:               @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:  @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey:   @YES,
    };

    NSDictionary *poolAttrs = @{
        (NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @(2),
    };

    CVReturn err = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                            (__bridge CFDictionaryRef)poolAttrs,
                                            (__bridge CFDictionaryRef)pixelAttrs,
                                            &_pool);
    if (err != kCVReturnSuccess || !_pool) {
        VCamLogE("variant: pool create failed for %zux%zu %{public}s cv=%d",
                 width, height, [VCamFrameVariant describeFormat:pixelFormat],
                 (int)err);
        return nil;
    }

    // The allocation threshold is the jetsam guard: past the ceiling the pool
    // returns kCVReturnWouldExceedAllocationThreshold instead of allocating,
    // and we pass the real frame through for that tick.
    NSDictionary *aux = @{
        (NSString *)kCVPixelBufferPoolAllocationThresholdKey:
            @(kVCamVariantPoolCeiling),
    };
    _auxAttributes = CFBridgingRetain(aux);

    _lastUsed = mach_absolute_time();

    VCamLogI("variant: created %zux%zu %{public}s",
             width, height, [VCamFrameVariant describeFormat:pixelFormat]);
    return self;
}

- (void)dealloc {
    if (_cached)        CVPixelBufferRelease(_cached);
    if (_pool)          CVPixelBufferPoolRelease(_pool);
    if (_auxAttributes) CFRelease(_auxAttributes);
}

- (uint64_t)generation { return _generation; }
- (uint64_t)lastUsed   { return _lastUsed;   }

- (void)touch {
    _lastUsed = mach_absolute_time();
}

- (CVPixelBufferRef)cachedBufferForGeneration:(uint64_t)generation {
    if (!_cached || _generation == 0 || _generation != generation) return NULL;
    CVPixelBufferRetain(_cached);
    return _cached;
}

- (CVPixelBufferRef)lastRenderedBuffer {
    if (!_cached) return NULL;
    CVPixelBufferRetain(_cached);
    return _cached;
}

- (CVPixelBufferRef)newPooledBuffer {
    if (!_pool) return NULL;

    CVPixelBufferRef buf = NULL;
    CVReturn err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                       kCFAllocatorDefault, _pool, _auxAttributes, &buf);

    if (err == kCVReturnWouldExceedAllocationThreshold) {
        // Every buffer we handed out is still in flight downstream. Skipping
        // this frame is strictly better than being jetsammed.
        VCamLogD("variant: %zux%zu at pool ceiling, skipping frame",
                 _width, _height);
        return NULL;
    }
    if (err != kCVReturnSuccess || !buf) {
        VCamLogE("variant: pool vend failed cv=%d", (int)err);
        return NULL;
    }

    vcam_attach_color_metadata(buf, _pixelFormat);
    return buf;
}

- (void)cacheBuffer:(CVPixelBufferRef)buffer generation:(uint64_t)generation {
    if (!buffer) return;
    CVPixelBufferRetain(buffer);
    if (_cached) CVPixelBufferRelease(_cached);
    _cached     = buffer;
    _generation = generation;
}

- (void)invalidate {
    if (_cached) { CVPixelBufferRelease(_cached); _cached = NULL; }
    _generation = 0;
}

@end
