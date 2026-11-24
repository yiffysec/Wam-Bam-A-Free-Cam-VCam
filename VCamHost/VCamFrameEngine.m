// VCamFrameEngine.m -- Source decode plus per-shape delivery
#import "VCamFrameEngine.h"
#import "VCamFrameVariant.h"
#import "VCamMediaSource.h"
#import "VCamPixelConverter.h"
#import "VCamDiagnostics.h"
#import "VCamSharedState.h"
#import "VCamTypes.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>

// Implemented in VCamHooks.x
extern void     vcam_push_to_remote_sink(id node, CMSampleBufferRef sb, id input);
extern uint64_t vcam_last_natural_render(void);

static double vcam_ticks_to_seconds(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    if (tb.denom == 0) return 0;
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e9;
}

/// If the real graph drove a sink more recently than this, stay out of the way.
/// Two frame intervals absorbs normal jitter.
static const double kVCamStallThresholdSec = 2.0 / kVCamTargetFPS;

// A weak node reference paired with the input it was last rendered for.
@interface VCamSinkRef : NSObject
@property (nonatomic, weak) id node;
@property (nonatomic, weak) id input;
@end
@implementation VCamSinkRef
@end

@implementation VCamFrameEngine {
    dispatch_source_t _timer;
    dispatch_queue_t  _queue;

    // -- Producer state (engine queue only) ------------------------------
    AVAssetReader            *_reader;
    AVAssetReaderTrackOutput *_trackOutput;
    BOOL                      _readerExhausted;
    CMTime                    _loopOffset;
    CMTime                    _lastPTS;
    CGSize                    _sensorSize;
    BOOL                      _running;

    // -- Source frame, shared with consumers -----------------------------
    // The raw decoded frame before framing is applied. Consumers render it into
    // their own shape, so framing happens per shape rather than once globally.
    CVPixelBufferRef _sourceFrame;
    uint64_t         _generation;
    os_unfair_lock   _sourceLock;

    // -- Variant cache, shared with consumers ----------------------------
    NSMutableArray<VCamFrameVariant *> *_variants;
    os_unfair_lock                      _variantLock;

    // -- Framing, refreshed from shared state each tick ------------------
    // Read under _sourceLock so a consumer never renders with half-updated
    // geometry.
    VCamRotation _rotation;
    float        _zoom;
    float        _panX, _panY;
    BOOL         _mirrorH, _mirrorV;
    VCamFitMode  _fitMode;

    NSMutableArray<VCamSinkRef *> *_remoteSinks;
    os_unfair_lock                 _sinkLock;
}

+ (VCamFrameEngine *)sharedEngine {
    static VCamFrameEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _sourceLock  = OS_UNFAIR_LOCK_INIT;
    _variantLock = OS_UNFAIR_LOCK_INIT;
    _sinkLock    = OS_UNFAIR_LOCK_INIT;
    _queue       = dispatch_queue_create("com.yiffysec.vcam.frameengine",
                                          DISPATCH_QUEUE_SERIAL);
    _variants    = [NSMutableArray arrayWithCapacity:kVCamMaxVariants];
    _remoteSinks = [NSMutableArray array];
    _sensorSize  = CGSizeMake(1920, 1080);
    _zoom        = kVCamDefaultZoom;
    _loopOffset  = kCMTimeZero;
    _lastPTS     = kCMTimeZero;
    return self;
}

// =========================================================================
//  Lifecycle
// =========================================================================

- (void)start {
    dispatch_async(_queue, ^{ [self startOnQueue]; });
}

- (void)startOnQueue {
    if (_running) return;

    // Block here, not in the constructor: this is our own background queue, so
    // waiting for Metal costs a few early frames, whereas waiting in the dylib
    // constructor would stall cameracaptured's startup.
    [VCamPixelConverter.sharedConverter ensureReady];

    VCamSharedState st;
    vcam_shm_read(&st);
    [self adoptState:&st];

    if (!st.enabled) {
        VCamLogI("engine: start requested while disabled -- staying idle");
        return;
    }

    [self openMedia];
    [self installTimer];

    _running = YES;
    VCamLogI("engine: running at %dHz", kVCamTargetFPS);
}

- (void)stop {
    dispatch_async(_queue, ^{ [self stopOnQueue]; });
}

- (void)stopOnQueue {
    if (!_running) return;

    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }

    [_reader cancelReading];
    _reader          = nil;
    _trackOutput     = nil;
    _readerExhausted = NO;
    _loopOffset      = kCMTimeZero;
    _lastPTS         = kCMTimeZero;

    os_unfair_lock_lock(&_sourceLock);
    CVPixelBufferRef old = _sourceFrame;
    _sourceFrame = NULL;
    _generation  = 0;
    os_unfair_lock_unlock(&_sourceLock);
    if (old) CVPixelBufferRelease(old);

    os_unfair_lock_lock(&_variantLock);
    [_variants removeAllObjects];
    os_unfair_lock_unlock(&_variantLock);

    os_unfair_lock_lock(&_sinkLock);
    [_remoteSinks removeAllObjects];
    os_unfair_lock_unlock(&_sinkLock);

    vcam_diag_set_variant_count(0);

    _running = NO;
    VCamLogI("engine: stopped");
}

- (void)restartWithSource:(VCamMediaSource *)source {
    VCAM_UNUSED(source);
    dispatch_async(_queue, ^{
        [self stopOnQueue];
        [self startOnQueue];
    });
}

- (void)applyConfig {
    dispatch_async(_queue, ^{
        VCamSharedState st;
        vcam_shm_read(&st);

        BOOL framingChanged = (st.rotation != _rotation) ||
                              (st.fitMode  != _fitMode)  ||
                              (st.zoom     != _zoom)     ||
                              (st.panX     != _panX)     ||
                              (st.panY     != _panY)     ||
                              ((st.mirrorH != 0) != _mirrorH) ||
                              ((st.mirrorV != 0) != _mirrorV);

        [self adoptState:&st];

        if (st.enabled && !_running)      { [self startOnQueue]; return; }
        if (!st.enabled && _running)      { [self stopOnQueue];  return; }

        // Framing is baked into each cached render, so a framing change has to
        // invalidate them. Bumping the generation is enough -- the next request
        // for any shape misses its cache and re-renders.
        if (framingChanged) {
            os_unfair_lock_lock(&_sourceLock);
            if (_sourceFrame) _generation++;
            os_unfair_lock_unlock(&_sourceLock);
            VCamLogD("engine: framing changed, caches invalidated");
        }
    });
}

- (void)adoptState:(const VCamSharedState *)st {
    os_unfair_lock_lock(&_sourceLock);
    _rotation = st->rotation;
    _zoom     = (st->zoom > 0.0f) ? st->zoom : kVCamDefaultZoom;
    _panX     = st->panX;
    _panY     = st->panY;
    _mirrorH  = st->mirrorH != 0;
    _mirrorV  = st->mirrorV != 0;
    _fitMode  = st->fitMode;
    os_unfair_lock_unlock(&_sourceLock);
}

- (void)notifyRealCameraSize:(CGSize)size {
    if (size.width < 16 || size.height < 16) return;
    dispatch_async(_queue, ^{
        if (CGSizeEqualToSize(size, _sensorSize)) return;
        _sensorSize = size;
        VCamLogI("engine: sensor geometry now %.0fx%.0f", size.width, size.height);
    });
}

// =========================================================================
//  Delivery
// =========================================================================

- (BOOL)hasSourceFrame {
    os_unfair_lock_lock(&_sourceLock);
    BOOL has = (_sourceFrame != NULL);
    os_unfair_lock_unlock(&_sourceLock);
    return has;
}

- (NSUInteger)variantCount {
    os_unfair_lock_lock(&_variantLock);
    NSUInteger n = _variants.count;
    os_unfair_lock_unlock(&_variantLock);
    return n;
}

- (CVPixelBufferRef)frameForSampleBuffer:(CMSampleBufferRef)sb
                          fallbackFormat:(OSType)fallbackFormat {
    size_t width  = 0, height = 0;
    OSType format = 0;

    // Preference order matters. The image buffer is ground truth: it is the
    // exact shape this connection is receiving right now. The format
    // description is next best. The sensor default is a last resort and is
    // usually wrong for anything but the viewfinder.
    BOOL hadImageBuffer = NO;

    if (sb) {
        CVPixelBufferRef original = CMSampleBufferGetImageBuffer(sb);
        if (original) {
            hadImageBuffer = YES;
            width  = CVPixelBufferGetWidth(original);
            height = CVPixelBufferGetHeight(original);
            format = CVPixelBufferGetPixelFormatType(original);
        } else {
            CMFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sb);
            if (desc && CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
                width  = (size_t)dims.width;
                height = (size_t)dims.height;
                format = CMFormatDescriptionGetMediaSubType(desc);
            }
        }
    }

    // When the original carries a real pixel buffer, its format is ground truth:
    // it is exactly what the connection, the encoder and the consumer expect. If
    // we cannot produce THAT format, we must pass the real frame through rather
    // than hand back a different layout -- a 10-bit HDR ('x420'), depth, or other
    // biplanar variant reinterpreted as our 8-bit 420v is misread downstream and
    // crashes the host app. This is the "some apps crash on camera open" bug:
    // those apps simply request a format we do not synthesise. Silently passing
    // through is correct; forcing a format is not.
    if (hadImageBuffer) {
        if (![VCamFrameVariant supportsPixelFormat:format]) {
            vcam_diag_note_declined_format(format);
            return NULL;
        }
    } else {
        // No pixel buffer, only a format description (e.g. a compressed still).
        // There is nothing to mismatch, so a supported subtype is used as-is and
        // anything else -- including a compressed subtype -- falls back to what
        // this sink class delivers.
        if (format == 0 || ![VCamFrameVariant supportsPixelFormat:format]) {
            format = fallbackFormat;
        }
    }

    if (width == 0 || height == 0) {
        width  = (size_t)_sensorSize.width;
        height = (size_t)_sensorSize.height;
    }

    return [self frameForWidth:width height:height pixelFormat:format];
}

- (CVPixelBufferRef)frameForWidth:(size_t)width
                           height:(size_t)height
                      pixelFormat:(OSType)pixelFormat {
    if (![VCamFrameVariant supportsPixelFormat:pixelFormat]) {
        vcam_diag_note_declined_format(pixelFormat);
        return NULL;
    }

    // Snapshot the source and the framing together, so a configuration change
    // mid-render cannot produce a half-transformed frame.
    os_unfair_lock_lock(&_sourceLock);
    CVPixelBufferRef source = _sourceFrame;
    if (source) CVPixelBufferRetain(source);
    uint64_t generation = _generation;
    VCamRotation rotation = _rotation;
    float zoom = _zoom, panX = _panX, panY = _panY;
    BOOL mirrorH = _mirrorH, mirrorV = _mirrorV;
    VCamFitMode fitMode = _fitMode;
    os_unfair_lock_unlock(&_sourceLock);

    if (!source || generation == 0) return NULL;

    VCamFrameVariant *variant = [self variantForWidth:width
                                                height:height
                                           pixelFormat:pixelFormat];
    if (!variant) { CVPixelBufferRelease(source); return NULL; }

    // Fast path: this shape was already rendered from this source frame.
    CVPixelBufferRef cached = [variant cachedBufferForGeneration:generation];
    if (cached) {
        CVPixelBufferRelease(source);
        vcam_diag_note_cache_hit();
        return cached;
    }

    CVPixelBufferRef out = [variant newPooledBuffer];
    if (!out) {
        // Pool exhausted: every buffer we vended for this shape is still held
        // downstream. Serve the LAST frame we rendered rather than NULL. NULL
        // makes the hook fall back to the real camera buffer -- a visible flash
        // of the true feed, which for a virtual camera is the one outcome worse
        // than a repeated frame. (Stills never reach here: their generation is
        // fixed, so the cache hit above always serves.) Re-serving the cached
        // buffer does not allocate, so it cannot deepen the exhaustion.
        CVPixelBufferRef last = [variant lastRenderedBuffer];
        CVPixelBufferRelease(source);
        if (last) vcam_diag_note_cache_hit();
        else      vcam_diag_set_last_error(VCamDiagErrorPoolExhausted);
        return last;   // NULL only if this shape has never been rendered
    }

    BOOL ok = [self renderSource:source
                            into:out
                        rotation:rotation
                            zoom:zoom
                            panX:panX
                            panY:panY
                         mirrorH:mirrorH
                         mirrorV:mirrorV
                         fitMode:fitMode];

    CVPixelBufferRelease(source);

    if (!ok) { CVPixelBufferRelease(out); return NULL; }

    [variant cacheBuffer:out generation:generation];
    vcam_diag_note_render();
    return out;   // caller releases
}

/// Finds or creates the variant for a shape, evicting the least recently used
/// one when the cache is full.
- (VCamFrameVariant *)variantForWidth:(size_t)width
                                height:(size_t)height
                           pixelFormat:(OSType)pixelFormat {
    // Planar formats were rounded down to even in the variant, so match on the
    // same rounding or every request would miss.
    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        width  &= ~(size_t)1;
        height &= ~(size_t)1;
    }

    os_unfair_lock_lock(&_variantLock);

    VCamFrameVariant *found = nil;
    for (VCamFrameVariant *v in _variants) {
        if (v.width == width && v.height == height &&
            v.pixelFormat == pixelFormat) {
            found = v;
            break;
        }
    }

    if (found) {
        [found touch];
        os_unfair_lock_unlock(&_variantLock);
        return found;
    }

    if (_variants.count >= kVCamMaxVariants) {
        NSUInteger lruIndex = 0;
        uint64_t   oldest   = UINT64_MAX;
        for (NSUInteger i = 0; i < _variants.count; i++) {
            uint64_t t = _variants[i].lastUsed;
            if (t < oldest) { oldest = t; lruIndex = i; }
        }
        VCamFrameVariant *evicted = _variants[lruIndex];
        VCamLogI("engine: evicting variant %zux%zu %{public}s",
                 evicted.width, evicted.height,
                 [VCamFrameVariant describeFormat:evicted.pixelFormat]);
        [_variants removeObjectAtIndex:lruIndex];
    }

    VCamFrameVariant *fresh = [[VCamFrameVariant alloc] initWithWidth:width
                                                                height:height
                                                           pixelFormat:pixelFormat];
    if (fresh) [_variants addObject:fresh];

    NSUInteger count = _variants.count;
    os_unfair_lock_unlock(&_variantLock);

    vcam_diag_set_variant_count((uint32_t)count);
    return fresh;
}

// =========================================================================
//  Producer
// =========================================================================

- (void)openMedia {
    VCamMediaSource *src = VCamMediaSource.sharedSource;

    switch (src.sourceType) {
        case VCamSourceNone:
            VCamLogI("engine: no media selected");
            return;
        case VCamSourcePhoto:
            [self loadStill:src.mediaURL];
            return;
        case VCamSourceVideo:
            [self openReader:src.mediaURL];
            return;
    }
}

- (void)loadStill:(NSURL *)url {
    if (!url) return;

    CIImage *img = [CIImage imageWithContentsOfURL:url];
    if (!img) {
        VCamLogE("engine: cannot decode still at %{public}@", url);
        return;
    }

    CGRect e = img.extent;
    if (CGRectIsEmpty(e) || CGRectIsInfinite(e)) {
        VCamLogE("engine: still has no usable extent");
        return;
    }

    // The still becomes the source frame at its own native size. Framing to
    // each client's shape happens on delivery, as for video.
    CVPixelBufferRef src =
        [self newSourceBufferWidth:(size_t)e.size.width
                            height:(size_t)e.size.height];
    if (!src) return;

    CIContext *ctx = VCamPixelConverter.sharedConverter.ciContext;
    if (!ctx) { CVPixelBufferRelease(src); return; }

    // Normalise the extent to the origin before rendering.
    if (e.origin.x != 0 || e.origin.y != 0) {
        img = [img imageByApplyingTransform:
               CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
    }

    @try {
        [ctx render:img toCVPixelBuffer:src];
    } @catch (NSException *ex) {
        VCamLogE("engine: still render threw %{public}@", ex.reason);
        CVPixelBufferRelease(src);
        return;
    }

    [self publishSource:src];
    CVPixelBufferRelease(src);

    VCamLogI("engine: still ready at %.0fx%.0f", e.size.width, e.size.height);
}

- (void)openReader:(NSURL *)url {
    if (!url) return;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) {
        VCamLogE("engine: no video track in %{public}@", url);
        return;
    }

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader) {
        VCamLogE("engine: AVAssetReader init failed: %{public}@", err);
        return;
    }

    // Decode straight to BGRA. The source frame is an intermediate that gets
    // re-rendered per shape anyway, and BGRA keeps the CoreImage path simple
    // and lossless through rotation and scaling. The YCbCr conversion happens
    // once, on the way into each client's buffer.
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:tracks.firstObject
                         outputSettings:@{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (NSString *)kCVPixelBufferMetalCompatibilityKey:  @YES,
        }];
    out.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:out]) {
        VCamLogE("engine: reader rejected BGRA output");
        return;
    }
    [reader addOutput:out];

    if (![reader startReading]) {
        VCamLogE("engine: startReading failed: %{public}@", reader.error);
        return;
    }

    _reader          = reader;
    _trackOutput     = out;
    _readerExhausted = NO;

    VCamLogI("engine: reader open for %{public}@", url.lastPathComponent);
}

- (CVPixelBufferRef)newSourceBufferWidth:(size_t)w height:(size_t)h
                                          CF_RETURNS_RETAINED {
    if (w < 16 || h < 16 || w > 8192 || h > 8192) return NULL;

    CVPixelBufferRef buf = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:      @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey:                 @(w),
        (NSString *)kCVPixelBufferHeightKey:                @(h),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:   @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey:    @YES,
    };
    CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attrs, &buf);
    if (err != kCVReturnSuccess) {
        VCamLogE("engine: source buffer create failed cv=%d", (int)err);
        return NULL;
    }
    return buf;
}

- (void)publishSource:(CVPixelBufferRef)frame {
    if (!frame) return;
    CVPixelBufferRetain(frame);

    os_unfair_lock_lock(&_sourceLock);
    CVPixelBufferRef old = _sourceFrame;
    _sourceFrame = frame;
    _generation++;
    if (_generation == 0) _generation = 1;   // 0 means "nothing cached"
    os_unfair_lock_unlock(&_sourceLock);

    if (old) CVPixelBufferRelease(old);
}

- (void)installTimer {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / kVCamTargetFPS);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                               interval, interval / 8);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}

- (void)tick {
    VCamSharedState st;
    vcam_shm_read(&st);

    if (!st.enabled) { [self stopOnQueue]; return; }
    if (st.paused)   return;

    [self adoptState:&st];

    @try {
        [self decodeNextFrame];
        [self driveRemoteSinks];
    } @catch (NSException *ex) {
        VCamLogE("engine: tick threw %{public}@", ex.reason);
    }
}

- (void)decodeNextFrame {
    VCamMediaSource *src = VCamMediaSource.sharedSource;

    if (src.sourceType == VCamSourceNone) return;

    // A still is published once and stays current; nothing to decode per tick.
    if (src.sourceType == VCamSourcePhoto) {
        if (![self hasSourceFrame]) [self loadStill:src.mediaURL];
        return;
    }

    if (!_reader || _readerExhausted) {
        // Seamless loop: tear down and reopen from the top.
        [_reader cancelReading];
        _reader      = nil;
        _trackOutput = nil;
        _loopOffset  = _lastPTS;
        [self openReader:src.mediaURL];
        if (!_reader) return;
    }

    CMSampleBufferRef sb = [_trackOutput copyNextSampleBuffer];
    if (!sb) { _readerExhausted = YES; return; }

    CVPixelBufferRef decoded = CMSampleBufferGetImageBuffer(sb);
    if (!decoded) { CFRelease(sb); return; }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (CMTIME_IS_VALID(pts)) _lastPTS = CMTimeAdd(pts, _loopOffset);

    // The decoded buffer belongs to the reader's pool and is recycled as soon
    // as the sample buffer is released, so it has to be copied rather than
    // retained. The copy is also what lets consumers read it off-queue.
    CVPixelBufferRef source =
        [self newSourceBufferWidth:CVPixelBufferGetWidth(decoded)
                            height:CVPixelBufferGetHeight(decoded)];
    if (!source) { CFRelease(sb); return; }

    CIContext *ctx = VCamPixelConverter.sharedConverter.ciContext;
    if (!ctx) { CVPixelBufferRelease(source); CFRelease(sb); return; }

    CIImage *img = [CIImage imageWithCVPixelBuffer:decoded];
    if (img) {
        @try {
            [ctx render:img toCVPixelBuffer:source];
            [self publishSource:source];
        } @catch (NSException *ex) {
            VCamLogE("engine: source render threw %{public}@", ex.reason);
        }
    }

    CVPixelBufferRelease(source);
    CFRelease(sb);
}

// =========================================================================
//  Independent 30Hz drive
// =========================================================================

- (void)registerRemoteQueueSinkNode:(id)node input:(id)input {
    if (!node) return;

    os_unfair_lock_lock(&_sinkLock);

    BOOL known = NO;
    NSMutableIndexSet *dead = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _remoteSinks.count; i++) {
        VCamSinkRef *ref = _remoteSinks[i];
        if (!ref.node)        { [dead addIndex:i]; continue; }
        if (ref.node == node) { ref.input = input; known = YES; }
    }
    [_remoteSinks removeObjectsAtIndexes:dead];

    if (!known) {
        VCamSinkRef *ref = [VCamSinkRef new];
        ref.node  = node;
        ref.input = input;
        [_remoteSinks addObject:ref];
    }

    os_unfair_lock_unlock(&_sinkLock);
}

- (void)driveRemoteSinks {
    os_unfair_lock_lock(&_sinkLock);
    NSArray<VCamSinkRef *> *sinks = [_remoteSinks copy];
    os_unfair_lock_unlock(&_sinkLock);

    if (!sinks.count) return;

    // Only step in once the real graph has gone quiet. While it is pulling, the
    // hook is already substituting every frame and pushing here too would
    // deliver each frame twice.
    uint64_t last = vcam_last_natural_render();
    if (last != 0) {
        uint64_t now = mach_absolute_time();
        if (now > last &&
            vcam_ticks_to_seconds(now - last) < kVCamStallThresholdSec) {
            return;
        }
    }

    // Without a real sample buffer to copy a shape from, the sensor geometry in
    // 420v is the best available guess -- this path exists precisely because
    // the graph is not delivering anything to measure.
    CVPixelBufferRef frame =
        [self frameForWidth:(size_t)_sensorSize.width
                     height:(size_t)_sensorSize.height
                pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    if (!frame) return;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                      frame, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(frame);
        return;
    }

    // Host-clock timestamps keep the stream strictly monotonic across loops.
    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, kVCamTargetFPS),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sb = NULL;
    OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(
                       kCFAllocatorDefault, frame, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(frame);

    if (err != noErr || !sb) return;

    for (VCamSinkRef *ref in sinks) {
        id node  = ref.node;
        id input = ref.input;
        // A nil input is not something the original implementation is obliged
        // to tolerate, so skip rather than guess.
        if (node && input) {
            vcam_push_to_remote_sink(node, sb, input);
            vcam_diag_note_driven_frame();
        }
    }

    CFRelease(sb);
}

// =========================================================================
//  Framing
// =========================================================================

/// Renders the source frame into `dest`, applying rotation, mirroring, zoom and
/// pan, then fitting to the destination's own dimensions.
- (BOOL)renderSource:(CVPixelBufferRef)source
                into:(CVPixelBufferRef)dest
            rotation:(VCamRotation)rotation
                zoom:(float)zoom
                panX:(float)panX
                panY:(float)panY
             mirrorH:(BOOL)mirrorH
             mirrorV:(BOOL)mirrorV
             fitMode:(VCamFitMode)fitMode {
    CIContext *ctx = VCamPixelConverter.sharedConverter.ciContext;
    if (!ctx || !source || !dest) return NO;

    CIImage *img = [CIImage imageWithCVPixelBuffer:source];
    if (!img) return NO;

    CGSize target = CGSizeMake(CVPixelBufferGetWidth(dest),
                               CVPixelBufferGetHeight(dest));

    // 1 -- Rotation about the image's own centre.
    if (rotation != VCamRotation0) {
        CGFloat radians = 0;
        switch (rotation) {
            case VCamRotation90:  radians = -M_PI_2; break;
            case VCamRotation180: radians =  M_PI;   break;
            case VCamRotation270: radians =  M_PI_2; break;
            default: break;
        }
        img = [self normalizeOrigin:
               [img imageByApplyingTransform:CGAffineTransformMakeRotation(radians)]];
    }

    // 2 -- Mirroring.
    if (mirrorH || mirrorV) {
        img = [self normalizeOrigin:
               [img imageByApplyingTransform:
                CGAffineTransformMakeScale(mirrorH ? -1 : 1, mirrorV ? -1 : 1)]];
    }

    // 3 -- Zoom and pan: crop a window, then let step 4 scale it up.
    if (zoom > 1.001f || panX != 0.0f || panY != 0.0f) {
        CGRect e = img.extent;
        CGFloat cw = e.size.width  / zoom;
        CGFloat ch = e.size.height / zoom;
        CGFloat maxDX = (e.size.width  - cw) / 2.0;
        CGFloat maxDY = (e.size.height - ch) / 2.0;
        CGFloat cx = e.origin.x + maxDX + panX * maxDX;
        CGFloat cy = e.origin.y + maxDY + panY * maxDY;
        img = [self normalizeOrigin:
               [img imageByCroppingToRect:CGRectMake(cx, cy, cw, ch)]];
    }

    // 4 -- Fit to the destination.
    img = [self fit:img into:target mode:fitMode];
    if (!img) return NO;

    @try {
        [ctx render:img toCVPixelBuffer:dest];
    } @catch (NSException *ex) {
        VCamLogE("engine: render threw %{public}@", ex.reason);
        return NO;
    }
    return YES;
}

- (CIImage *)normalizeOrigin:(CIImage *)img {
    CGRect e = img.extent;
    if (e.origin.x == 0 && e.origin.y == 0) return img;
    return [img imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
}

- (CIImage *)fit:(CIImage *)img into:(CGSize)target mode:(VCamFitMode)mode {
    CGRect e = img.extent;
    if (CGRectIsEmpty(e) || CGRectIsInfinite(e)) return nil;

    CGFloat sx = target.width  / e.size.width;
    CGFloat sy = target.height / e.size.height;

    if (mode == VCamFitStretch) {
        img = [self normalizeOrigin:
               [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)]];
    } else {
        CGFloat s = (mode == VCamFitFill) ? MAX(sx, sy) : MIN(sx, sy);
        img = [self normalizeOrigin:
               [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)]];

        CGRect scaled = img.extent;
        CGFloat dx = (target.width  - scaled.size.width)  / 2.0;
        CGFloat dy = (target.height - scaled.size.height) / 2.0;
        img = [img imageByApplyingTransform:
               CGAffineTransformMakeTranslation(dx, dy)];

        // Fit leaves bars. Composite over real black so the destination never
        // receives undefined pixels outside the image's extent -- an infinite
        // or undefined extent is one of the ways a sink ends up showing noise.
        if (mode == VCamFitFit) {
            CIImage *black =
                [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                 imageByCroppingToRect:CGRectMake(0, 0, target.width, target.height)];
            img = [img imageByCompositingOverImage:black];
        }
    }

    return [img imageByCroppingToRect:CGRectMake(0, 0, target.width, target.height)];
}

@end
