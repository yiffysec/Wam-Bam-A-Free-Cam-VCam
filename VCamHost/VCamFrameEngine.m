// VCamFrameEngine.m -- 30Hz frame pump
#import "VCamFrameEngine.h"
#import "VCamMediaSource.h"
#import "VCamPixelConverter.h"
#import "VCamSharedState.h"
#import "VCamTypes.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

#include <mach/mach_time.h>

// Implemented in VCamHooks.x -- pushes straight to the original sink IMP.
extern void     vcam_push_to_remote_sink(id node, CMSampleBufferRef sb, id input);
extern uint64_t vcam_last_natural_render(void);

/// Converts mach ticks to seconds using the host's timebase.
static double vcam_ticks_to_seconds(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    if (tb.denom == 0) return 0;
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e9;
}

/// If the real graph drove a sink more recently than this, the engine stays out
/// of the way. Two frame intervals of slack absorbs normal jitter.
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

    AVAssetReader            *_reader;
    AVAssetReaderTrackOutput *_trackOutput;
    BOOL                      _readerExhausted;
    CMTime                    _loopOffset;
    CMTime                    _lastPTS;

    // Pre-rendered still, reused every tick for photo sources.
    CVPixelBufferRef _still420v;
    CVPixelBufferRef _stillBGRA;

    // Published frames, guarded by _frameLock.
    CVPixelBufferRef _current420v;
    CVPixelBufferRef _currentBGRA;
    os_unfair_lock   _frameLock;

    // Framing, refreshed from shared state every tick.
    CGSize       _cameraSize;
    VCamRotation _rotation;
    float        _zoom;
    float        _panX, _panY;
    BOOL         _mirrorH, _mirrorV;
    VCamFitMode  _fitMode;

    NSMutableArray<VCamSinkRef *> *_remoteSinks;
    os_unfair_lock                 _sinkLock;

    BOOL     _running;
    uint64_t _tickCount;
}

+ (VCamFrameEngine *)sharedEngine {
    static VCamFrameEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _frameLock   = OS_UNFAIR_LOCK_INIT;
    _sinkLock    = OS_UNFAIR_LOCK_INIT;
    _queue       = dispatch_queue_create("com.yiffysec.vcam.frameengine",
                                          DISPATCH_QUEUE_SERIAL);
    _remoteSinks = [NSMutableArray array];
    _cameraSize  = CGSizeMake(1920, 1080);
    _zoom        = kVCamDefaultZoom;
    _loopOffset  = kCMTimeZero;
    _lastPTS     = kCMTimeZero;
    return self;
}

// -- Lifecycle -----------------------------------------------------------
- (void)start {
    dispatch_async(_queue, ^{ [self startOnQueue]; });
}

- (void)startOnQueue {
    if (_running) return;

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

    [self releaseStills];

    os_unfair_lock_lock(&_frameLock);
    if (_current420v) { CVPixelBufferRelease(_current420v); _current420v = NULL; }
    if (_currentBGRA) { CVPixelBufferRelease(_currentBGRA); _currentBGRA = NULL; }
    os_unfair_lock_unlock(&_frameLock);

    os_unfair_lock_lock(&_sinkLock);
    [_remoteSinks removeAllObjects];
    os_unfair_lock_unlock(&_sinkLock);

    _running = NO;
    VCamLogI("engine: stopped");
}

- (void)releaseStills {
    if (_still420v) { CVPixelBufferRelease(_still420v); _still420v = NULL; }
    if (_stillBGRA) { CVPixelBufferRelease(_stillBGRA); _stillBGRA = NULL; }
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

        BOOL geometryChanged = (st.rotation != _rotation) ||
                               (st.fitMode  != _fitMode);
        [self adoptState:&st];

        if (st.enabled && !_running)      [self startOnQueue];
        else if (!st.enabled && _running) [self stopOnQueue];
        else if (geometryChanged && [VCamMediaSource sharedSource].sourceType
                                     == VCamSourcePhoto) {
            // Stills are pre-rendered, so a framing change needs a re-render.
            [self releaseStills];
            [self openMedia];
        }
    });
}

- (void)adoptState:(const VCamSharedState *)st {
    _rotation = st->rotation;
    _zoom     = (st->zoom > 0.0f) ? st->zoom : kVCamDefaultZoom;
    _panX     = st->panX;
    _panY     = st->panY;
    _mirrorH  = st->mirrorH != 0;
    _mirrorV  = st->mirrorV != 0;
    _fitMode  = st->fitMode;
}

- (void)notifyRealCameraSize:(CGSize)size {
    if (size.width < 16 || size.height < 16) return;

    dispatch_async(_queue, ^{
        if (CGSizeEqualToSize(size, _cameraSize)) return;
        _cameraSize = size;
        VCamLogI("engine: sensor geometry now %.0fx%.0f", size.width, size.height);

        // Stills are rendered to the sensor's dimensions, so re-render them.
        if ([VCamMediaSource sharedSource].sourceType == VCamSourcePhoto) {
            [self releaseStills];
            [self openMedia];
        }
    });
}

// -- Sink registry -------------------------------------------------------
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

// -- Published frames ----------------------------------------------------
- (CVPixelBufferRef)currentFrame420v {
    os_unfair_lock_lock(&_frameLock);
    CVPixelBufferRef r = _current420v;
    if (r) CVPixelBufferRetain(r);
    os_unfair_lock_unlock(&_frameLock);
    return r;
}

- (CVPixelBufferRef)currentFrameBGRA {
    os_unfair_lock_lock(&_frameLock);
    CVPixelBufferRef r = _currentBGRA;
    if (r) CVPixelBufferRetain(r);
    os_unfair_lock_unlock(&_frameLock);
    return r;
}

- (void)publish420v:(CVPixelBufferRef)v bgra:(CVPixelBufferRef)b {
    os_unfair_lock_lock(&_frameLock);
    CVPixelBufferRef old420 = _current420v;
    CVPixelBufferRef oldBGRA = _currentBGRA;
    _current420v = v ? (CVPixelBufferRetain(v), v) : NULL;
    _currentBGRA = b ? (CVPixelBufferRetain(b), b) : NULL;
    os_unfair_lock_unlock(&_frameLock);

    // Release outside the lock: a sink may still be draining the old buffer.
    if (old420)  CVPixelBufferRelease(old420);
    if (oldBGRA) CVPixelBufferRelease(oldBGRA);
}

// -- Media opening -------------------------------------------------------
- (void)openMedia {
    VCamMediaSource *src = [VCamMediaSource sharedSource];

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

    CGSize target = [self outputSize];
    CVPixelBufferRef v = [self render:img toFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                 size:target];
    CVPixelBufferRef b = [self render:img toFormat:kCVPixelFormatType_32BGRA
                                 size:target];
    if (!v && !b) return;

    [self releaseStills];
    _still420v = v;   // owned
    _stillBGRA = b;   // owned

    [self publish420v:v bgra:b];
    VCamLogI("engine: still ready at %.0fx%.0f", target.width, target.height);
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

    // Ask the decoder for 420v directly. Decoding straight into the format the
    // sinks require avoids a per-frame conversion for the common case.
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:tracks.firstObject
                         outputSettings:@{
            (NSString *)kCVPixelBufferPixelFormatTypeKey:
                @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        }];
    out.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:out]) {
        VCamLogE("engine: reader rejected 420v output");
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

// -- Timer ---------------------------------------------------------------
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

    _tickCount++;
}

- (void)decodeNextFrame {
    VCamMediaSource *src = [VCamMediaSource sharedSource];

    if (src.sourceType == VCamSourceNone) return;

    if (src.sourceType == VCamSourcePhoto) {
        // Already published; nothing to decode. Re-publish if a consumer
        // somehow drained the slot.
        os_unfair_lock_lock(&_frameLock);
        BOOL empty = (_current420v == NULL);
        os_unfair_lock_unlock(&_frameLock);
        if (empty && _still420v) [self publish420v:_still420v bgra:_stillBGRA];
        return;
    }

    if (!_reader || _readerExhausted) {
        // Seamless loop: tear the reader down and reopen from the top.
        [_reader cancelReading];
        _reader      = nil;
        _trackOutput = nil;
        _loopOffset  = _lastPTS;
        [self openReader:src.mediaURL];
        if (!_reader) return;
    }

    CMSampleBufferRef sb = [_trackOutput copyNextSampleBuffer];
    if (!sb) {
        _readerExhausted = YES;
        return;
    }

    CVPixelBufferRef decoded = CMSampleBufferGetImageBuffer(sb);
    if (!decoded) { CFRelease(sb); return; }

    // Reject a planar buffer missing its chroma plane. Handing one of these to
    // a 420v sink is a classic cause of a green or black preview.
    if (CVPixelBufferGetPixelFormatType(decoded) ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        CVPixelBufferGetPlaneCount(decoded) < 2) {
        VCamLogE("engine: dropping truncated planar frame (planes=%zu)",
                 CVPixelBufferGetPlaneCount(decoded));
        CFRelease(sb);
        return;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (CMTIME_IS_VALID(pts)) _lastPTS = CMTimeAdd(pts, _loopOffset);

    CVPixelBufferRef framed = [self applyFraming:decoded];
    CFRelease(sb);

    if (!framed) return;

    CVPixelBufferRef bgra = [VCamPixelConverter.sharedConverter convertToBGRA:framed];

    [self publish420v:framed bgra:bgra];

    CVPixelBufferRelease(framed);
    if (bgra) CVPixelBufferRelease(bgra);
}

// -- Independent 30Hz drive of remote sinks ------------------------------
- (void)driveRemoteSinks {
    os_unfair_lock_lock(&_sinkLock);
    NSArray<VCamSinkRef *> *sinks = [_remoteSinks copy];
    os_unfair_lock_unlock(&_sinkLock);

    if (!sinks.count) return;

    // Only step in when the real graph has gone quiet. While it is pulling
    // normally the hook is already substituting every frame, and pushing here
    // too would deliver each frame twice.
    uint64_t last = vcam_last_natural_render();
    if (last != 0) {
        uint64_t now = mach_absolute_time();
        if (now > last &&
            vcam_ticks_to_seconds(now - last) < kVCamStallThresholdSec) {
            return;
        }
    }

    CVPixelBufferRef frame = [self currentFrame420v];
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
        id node = ref.node;
        if (node) vcam_push_to_remote_sink(node, sb, ref.input);
    }

    CFRelease(sb);
}

// -- Framing -------------------------------------------------------------
- (CGSize)outputSize {
    // Output must match the sensor exactly. Rotation by a quarter turn swaps
    // the axes of the source, not of the destination -- the destination is
    // always the sensor's own geometry.
    return _cameraSize;
}

- (CVPixelBufferRef)applyFraming:(CVPixelBufferRef)src CF_RETURNS_RETAINED {
    if (!src) return NULL;

    CGSize target = [self outputSize];
    CIImage *img  = [CIImage imageWithCVPixelBuffer:src];
    if (!img) return NULL;

    // 1. Rotation (about the image's own centre).
    if (_rotation != VCamRotation0) {
        CGFloat radians = 0;
        switch (_rotation) {
            case VCamRotation90:  radians = -M_PI_2; break;
            case VCamRotation180: radians =  M_PI;   break;
            case VCamRotation270: radians =  M_PI_2; break;
            default: break;
        }
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(radians)];
        img = [self normalizeOrigin:img];
    }

    // 2. Mirroring.
    if (_mirrorH || _mirrorV) {
        CGAffineTransform m = CGAffineTransformMakeScale(_mirrorH ? -1 : 1,
                                                          _mirrorV ? -1 : 1);
        img = [img imageByApplyingTransform:m];
        img = [self normalizeOrigin:img];
    }

    // 3. Zoom and pan: crop a window out of the source, then fit that window.
    if (_zoom > 1.001f || _panX != 0.0f || _panY != 0.0f) {
        CGRect e = img.extent;
        CGFloat cw = e.size.width  / _zoom;
        CGFloat ch = e.size.height / _zoom;
        CGFloat maxDX = (e.size.width  - cw) / 2.0;
        CGFloat maxDY = (e.size.height - ch) / 2.0;
        CGFloat cx = e.origin.x + maxDX + _panX * maxDX;
        CGFloat cy = e.origin.y + maxDY + _panY * maxDY;
        img = [img imageByCroppingToRect:CGRectMake(cx, cy, cw, ch)];
        img = [self normalizeOrigin:img];
    }

    // 4. Fit the result into the sensor's frame.
    img = [self fit:img into:target];

    return [self render:img
               toFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                   size:target];
}

/// Moves an image's extent back to the origin after a transform.
- (CIImage *)normalizeOrigin:(CIImage *)img {
    CGRect e = img.extent;
    if (e.origin.x == 0 && e.origin.y == 0) return img;
    return [img imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
}

- (CIImage *)fit:(CIImage *)img into:(CGSize)target {
    CGRect e = img.extent;
    if (CGRectIsEmpty(e) || CGRectIsInfinite(e)) return img;

    CGFloat sx = target.width  / e.size.width;
    CGFloat sy = target.height / e.size.height;

    if (_fitMode == VCamFitStretch) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
        img = [self normalizeOrigin:img];
    } else {
        CGFloat s = (_fitMode == VCamFitFill) ? MAX(sx, sy) : MIN(sx, sy);
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
        img = [self normalizeOrigin:img];

        // Centre within the target.
        CGRect scaled = img.extent;
        CGFloat dx = (target.width  - scaled.size.width)  / 2.0;
        CGFloat dy = (target.height - scaled.size.height) / 2.0;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];

        // Fit mode leaves bars; composite over black so the sink never receives
        // undefined pixels outside the image's extent.
        if (_fitMode == VCamFitFit) {
            CIImage *black = [[CIImage imageWithColor:
                               [CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                              imageByCroppingToRect:
                                  CGRectMake(0, 0, target.width, target.height)];
            img = [img imageByCompositingOverImage:black];
        }
    }

    return [img imageByCroppingToRect:CGRectMake(0, 0, target.width, target.height)];
}

- (CVPixelBufferRef)render:(CIImage *)img
                  toFormat:(OSType)format
                      size:(CGSize)size CF_RETURNS_RETAINED {
    if (!img || size.width < 1 || size.height < 1) return NULL;

    // 420v requires even dimensions for the half-resolution chroma plane.
    size_t w = (size_t)size.width  & ~1UL;
    size_t h = (size_t)size.height & ~1UL;
    if (w < 2 || h < 2) return NULL;

    CVPixelBufferRef out = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:       @(format),
        (NSString *)kCVPixelBufferWidthKey:                 @(w),
        (NSString *)kCVPixelBufferHeightKey:                @(h),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:   @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey:    @YES,
    };

    CVReturn cvErr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, format,
                                          (__bridge CFDictionaryRef)attrs, &out);
    if (cvErr != kCVReturnSuccess || !out) {
        VCamLogE("engine: CVPixelBufferCreate failed cv=%d", (int)cvErr);
        return NULL;
    }

    CIContext *ctx = VCamPixelConverter.sharedConverter.ciContext;
    if (!ctx) { CVPixelBufferRelease(out); return NULL; }

    @try {
        [ctx render:img toCVPixelBuffer:out];
    } @catch (NSException *ex) {
        VCamLogE("engine: CIContext render threw %{public}@", ex.reason);
        CVPixelBufferRelease(out);
        return NULL;
    }

    return out;
}

@end
