// VCamAudioEngine.m -- Produces the audio that replaces the live microphone
//
// Threading contract -- read before editing:
//   The replacement is requested from BWAudioConverterNode's own render thread,
//   which is part of the live capture graph. That thread must NEVER block on
//   I/O: stalling it stalls the graph, and a long enough stall trips the media
//   watchdog, which takes cameracaptured (and the host app) down. So the render
//   thread here only ever does lock-free-ish work -- copy already-decoded PCM out
//   of a ring buffer and build a CMSampleBuffer. All AVAssetReader decoding
//   happens ahead of time on a private queue (`_q`) that keeps the ring topped
//   up. If the ring is short (startup, or the file briefly can't keep pace) the
//   shortfall is filled with silence for that one buffer -- quiet, never a block
//   and never the real mic leaking through.
//
//   Ownership of state:
//     * `_ring`, `_pendingASBD`, `_havePending`  -- guarded by `_ringLock`;
//       touched by BOTH the render thread and `_q`.
//     * everything else (`_reader`, `_output`, `_carry`, `_targetASBD`,
//       `_haveTarget`, `_url`, `_ringCap`)       -- touched ONLY on `_q`.

#import "VCamAudioEngine.h"
#import "VCamMediaSource.h"
#import "VCamTypes.h"
#import <AVFoundation/AVFoundation.h>
#include <os/lock.h>
#include <stdatomic.h>

// Target fill expressed in seconds of audio; the byte cap is derived per format.
static const double kVCamAudioRingSeconds = 0.5;
static const size_t kVCamAudioRingMinBytes = 64 * 1024;
static const size_t kVCamAudioRingMaxBytes = 2 * 1024 * 1024;

@implementation VCamAudioEngine {
    dispatch_queue_t _q;

    // -- `_q`-only reader state ------------------------------------------
    NSURL                      *_url;          // file for Video/Custom (nil otherwise)
    AVAssetReader              *_reader;
    AVAssetReaderTrackOutput   *_output;
    AudioStreamBasicDescription _targetASBD;   // format the reader is emitting
    BOOL                        _haveTarget;
    NSMutableData              *_carry;         // decoded bytes not yet ringed
    size_t                      _ringCap;

    // -- shared, under _ringLock -----------------------------------------
    os_unfair_lock              _ringLock;
    NSMutableData              *_ring;          // decoded PCM in _targetASBD
    AudioStreamBasicDescription _pendingASBD;   // format the render thread needs
    BOOL                        _havePending;

    _Atomic bool                _refillScheduled;
}

+ (VCamAudioEngine *)sharedEngine {
    static VCamAudioEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q        = dispatch_queue_create("com.yiffysec.vcam.audioengine",
                                       DISPATCH_QUEUE_SERIAL);
    _carry    = [NSMutableData data];
    _ring     = [NSMutableData data];
    _ringLock = OS_UNFAIR_LOCK_INIT;
    _ringCap  = kVCamAudioRingMinBytes;
    atomic_store(&_refillScheduled, false);
    return self;
}

// -- Configuration --------------------------------------------------------
- (void)configureWithSource:(VCamMediaSource *)source {
    NSURL *url = source.audioURL;   // nil for None/Microphone
    dispatch_async(_q, ^{
        if ((url == nil && self->_url == nil) ||
            [url.path isEqualToString:self->_url.path]) {
            return;   // unchanged
        }
        self->_url = url;
        [self teardownReader];
        os_unfair_lock_lock(&self->_ringLock);
        [self->_ring setLength:0];
        self->_havePending = NO;
        os_unfair_lock_unlock(&self->_ringLock);
        VCamLogI("audio: source set to %{public}@", url.lastPathComponent ?: @"(none)");
    });
}

// -- Replacement (render thread) ------------------------------------------
- (CMSampleBufferRef)replacementForBuffer:(CMSampleBufferRef)original
                                      mode:(VCamAudioMode)mode
                                     muted:(BOOL)muted {
    if (!original) return NULL;

    // Microphone, unmuted: the one mode that passes the real audio through.
    if (mode == VCamAudioMicrophone && !muted) return NULL;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(original);
    if (!fmt || CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Audio) {
        return NULL;   // not audio we understand -- leave it alone
    }
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbd || asbd->mBytesPerFrame == 0) return NULL;

    CMItemCount frames = CMSampleBufferGetNumSamples(original);
    if (frames <= 0) return NULL;

    size_t bytesNeeded = (size_t)frames * asbd->mBytesPerFrame;

    NSMutableData *pcm;
    BOOL wantFile = (mode == VCamAudioVideo || mode == VCamAudioCustom);

    if (wantFile) {
        pcm = [self takeFromRing:bytesNeeded wantASBD:asbd];   // never blocks
    }
    if (!pcm) {
        // Silence: a correctly sized, zero-filled buffer. Always works, and is
        // what None / muted / a not-yet-primed file all resolve to.
        pcm = [NSMutableData dataWithLength:bytesNeeded];
    }

    return [self bufferWithPCM:pcm frames:frames format:fmt timing:original];
}

/// Copies up to `bytesNeeded` bytes of decoded PCM out of the ring, consuming
/// them, and zero-pads any shortfall so the result is always exactly the size
/// asked for. Publishes the format the render thread needs and schedules a
/// background refill. Returns nil only when there is nothing decoded yet AND the
/// caller should treat the whole buffer as silence (same effect as a zero-pad,
/// but lets None/muted skip the ring entirely upstream).
- (NSMutableData *)takeFromRing:(size_t)bytesNeeded
                       wantASBD:(const AudioStreamBasicDescription *)asbd {
    NSMutableData *out = [NSMutableData dataWithCapacity:bytesNeeded];

    os_unfair_lock_lock(&_ringLock);

    // Tell the prefetcher which format to decode into. A change clears the ring
    // so the render thread never reads bytes in a stale format.
    if (!_havePending || memcmp(&_pendingASBD, asbd, sizeof(*asbd)) != 0) {
        _pendingASBD = *asbd;
        _havePending = YES;
        [_ring setLength:0];
    }

    NSUInteger take = MIN((NSUInteger)bytesNeeded, _ring.length);
    if (take > 0) {
        [out appendBytes:_ring.bytes length:take];
        [_ring replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
    }

    os_unfair_lock_unlock(&_ringLock);

    if (out.length < bytesNeeded) {
        out.length = bytesNeeded;   // zero-pads the shortfall with silence
    }

    [self scheduleRefill];
    return out;
}

// -- Background prefetch (`_q`) --------------------------------------------
- (void)scheduleRefill {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_refillScheduled, &expected, true)) {
        return;   // a refill is already queued
    }
    dispatch_async(_q, ^{
        atomic_store(&self->_refillScheduled, false);
        @try {
            [self refill];
        } @catch (NSException *ex) {
            VCamLogE("audio: refill threw %{public}@", ex.reason);
        }
    });
}

- (void)refill {
    if (!_url) return;

    // Adopt the render thread's requested format if it changed.
    AudioStreamBasicDescription want;
    BOOL have;
    os_unfair_lock_lock(&_ringLock);
    want = _pendingASBD;
    have = _havePending;
    os_unfair_lock_unlock(&_ringLock);
    if (!have) return;

    if (!_haveTarget || memcmp(&_targetASBD, &want, sizeof(want)) != 0 || !_reader) {
        [self teardownReader];
        if (![self buildReaderForASBD:&want]) return;
        _ringCap = [self ringCapForASBD:&want];
    }

    int loops = 0;
    for (;;) {
        os_unfair_lock_lock(&_ringLock);
        BOOL full    = (_ring.length >= _ringCap);
        BOOL stale   = (memcmp(&_pendingASBD, &_targetASBD, sizeof(_targetASBD)) != 0);
        os_unfair_lock_unlock(&_ringLock);

        if (stale) return;   // format changed under us; next refill rebuilds
        if (full)  return;

        NSData *chunk = [self nextChunk];
        if (!chunk) {
            if (++loops > 2) return;       // file yields nothing -- avoid a spin
            [self restartReader];          // seamless loop
            continue;
        }
        loops = 0;

        os_unfair_lock_lock(&_ringLock);
        if (memcmp(&_pendingASBD, &_targetASBD, sizeof(_targetASBD)) == 0) {
            [_ring appendData:chunk];
        } else {
            [_ring setLength:0];
            os_unfair_lock_unlock(&_ringLock);
            return;
        }
        os_unfair_lock_unlock(&_ringLock);
    }
}

- (size_t)ringCapForASBD:(const AudioStreamBasicDescription *)asbd {
    double bytesPerSec = asbd->mSampleRate * (double)asbd->mBytesPerFrame;
    size_t cap = (size_t)(bytesPerSec * kVCamAudioRingSeconds);
    if (cap < kVCamAudioRingMinBytes) cap = kVCamAudioRingMinBytes;
    if (cap > kVCamAudioRingMaxBytes) cap = kVCamAudioRingMaxBytes;
    return cap;
}

// -- AVAssetReader plumbing (all `_q`) ------------------------------------
- (BOOL)buildReaderForASBD:(const AudioStreamBasicDescription *)asbd {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_url options:nil];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!tracks.count) {
        VCamLogI("audio: %{public}@ has no audio track", _url.lastPathComponent);
        return NO;
    }

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader) { VCamLogE("audio: reader init failed %{public}@", err); return NO; }

    // Ask the reader for LPCM in exactly the target format, so no separate
    // conversion step is needed and the bytes drop straight into the ring.
    NSDictionary *settings = @{
        AVFormatIDKey:            @(kAudioFormatLinearPCM),
        AVSampleRateKey:          @(asbd->mSampleRate),
        AVNumberOfChannelsKey:    @(asbd->mChannelsPerFrame),
        AVLinearPCMBitDepthKey:   @((asbd->mBitsPerChannel) ?: 16),
        AVLinearPCMIsFloatKey:    @((asbd->mFormatFlags & kAudioFormatFlagIsFloat) ? YES : NO),
        AVLinearPCMIsBigEndianKey:@((asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) ? YES : NO),
        AVLinearPCMIsNonInterleaved:@((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? YES : NO),
    };
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) {
        VCamLogE("audio: reader rejected target LPCM format");
        return NO;
    }
    [reader addOutput:out];
    if (![reader startReading]) {
        VCamLogE("audio: startReading failed %{public}@", reader.error);
        return NO;
    }

    _reader     = reader;
    _output     = out;
    _targetASBD = *asbd;
    _haveTarget = YES;
    [_carry setLength:0];
    return YES;
}

- (NSData *)nextChunk {
    if (!_output) return nil;
    CMSampleBufferRef sb = [_output copyNextSampleBuffer];
    if (!sb) return nil;

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sb);
    if (!block) { CFRelease(sb); return nil; }

    size_t total = 0;
    char *ptr = NULL;
    OSStatus err = CMBlockBufferGetDataPointer(block, 0, NULL, &total, &ptr);
    if (err != noErr || !ptr || total == 0) { CFRelease(sb); return nil; }

    NSData *data = [NSData dataWithBytes:ptr length:total];
    CFRelease(sb);
    return data;
}

- (void)restartReader {
    AudioStreamBasicDescription asbd = _targetASBD;
    BOOL had = _haveTarget;
    [self teardownReader];
    if (had) [self buildReaderForASBD:&asbd];
}

- (void)teardownReader {
    [_reader cancelReading];
    _reader     = nil;
    _output     = nil;
    _haveTarget = NO;
    [_carry setLength:0];
}

// -- Build a CMSampleBuffer from PCM --------------------------------------
- (CMSampleBufferRef)bufferWithPCM:(NSData *)pcm
                            frames:(CMItemCount)frames
                            format:(CMFormatDescriptionRef)fmt
                            timing:(CMSampleBufferRef)original
                                    CF_RETURNS_RETAINED {
    // kCMBlockBufferAssureMemoryNowFlag forces the backing memory to be
    // allocated here, so the ReplaceDataBytes copy below has somewhere to land --
    // without it the allocation can be deferred and the copy fails.
    CMBlockBufferRef block = NULL;
    OSStatus err = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, pcm.length, kCFAllocatorDefault, NULL,
        0, pcm.length, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (err != noErr || !block) return NULL;

    err = CMBlockBufferReplaceDataBytes(pcm.bytes, block, 0, pcm.length);
    if (err != noErr) { CFRelease(block); return NULL; }

    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    if (!CMTIME_IS_VALID(timing.presentationTimeStamp)) {
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    }

    CMSampleBufferRef out = NULL;
    err = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        kCFAllocatorDefault, block, fmt, frames,
        timing.presentationTimeStamp, NULL, &out);
    CFRelease(block);

    if (err != noErr || !out) {
        if (out) CFRelease(out);
        return NULL;
    }
    return out;
}

@end
