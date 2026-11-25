// VCamAudioEngine.m -- Produces the audio that replaces the live microphone
#import "VCamAudioEngine.h"
#import "VCamMediaSource.h"
#import "VCamTypes.h"
#import <AVFoundation/AVFoundation.h>

@implementation VCamAudioEngine {
    dispatch_queue_t _q;

    // The file the current mode decodes from (nil for None/Microphone).
    NSURL *_url;

    // AVAssetReader streaming LPCM in the target format. Rebuilt when either the
    // URL or the target format changes. Guarded by _q.
    AVAssetReader            *_reader;
    AVAssetReaderTrackOutput *_output;
    AudioStreamBasicDescription _targetASBD;   // what the reader is emitting
    BOOL                      _haveTarget;

    // Leftover decoded bytes not yet consumed by a request, so frame counts that
    // do not divide evenly across reader buffers still produce a seamless stream.
    NSMutableData *_carry;
}

+ (VCamAudioEngine *)sharedEngine {
    static VCamAudioEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q     = dispatch_queue_create("com.yiffysec.vcam.audioengine",
                                    DISPATCH_QUEUE_SERIAL);
    _carry = [NSMutableData data];
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
        [self teardownReaderLocked];
        VCamLogI("audio: source set to %{public}@", url.lastPathComponent ?: @"(none)");
    });
}

// -- Replacement ----------------------------------------------------------
- (CMSampleBufferRef)replacementForBuffer:(CMSampleBufferRef)original
                                      mode:(VCamAudioMode)mode
                                     muted:(BOOL)muted {
    if (!original) return NULL;

    // Microphone, unmuted: the one mode that passes the real audio through.
    if (mode == VCamAudioMicrophone && !muted) return NULL;

    // Everything else replaces. None and muted-mic are silence; Video/Custom try
    // the file and fall back to silence. Describe the target format from the
    // buffer we are replacing so whatever we build slots in exactly.
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
        pcm = [self pcmOfLength:bytesNeeded forASBD:asbd];   // nil on any failure
    }
    if (!pcm) {
        // Silence: a correctly sized, zero-filled buffer. Always works.
        pcm = [NSMutableData dataWithLength:bytesNeeded];
    }

    return [self bufferWithPCM:pcm
                        frames:frames
                        format:fmt
                        timing:original];
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

// -- File decode ----------------------------------------------------------
// Returns exactly `length` bytes of LPCM in the target format, looping the file,
// or nil if the file cannot be read in that format (caller then uses silence).
- (NSMutableData *)pcmOfLength:(size_t)length
                       forASBD:(const AudioStreamBasicDescription *)asbd {
    if (!_url) return nil;

    __block NSMutableData *result = nil;
    dispatch_sync(_q, ^{
        // (Re)build the reader if the target format changed or it is not running.
        if (!_haveTarget ||
            memcmp(&_targetASBD, asbd, sizeof(*asbd)) != 0 ||
            !_reader) {
            [self teardownReaderLocked];
            if (![self buildReaderForASBD:asbd]) return;
        }

        NSMutableData *out = [NSMutableData dataWithCapacity:length];

        // Spend carry-over first.
        if (_carry.length) {
            NSUInteger take = MIN(_carry.length, length);
            [out appendBytes:_carry.bytes length:take];
            [_carry replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
        }

        int loops = 0;
        while (out.length < length) {
            NSData *chunk = [self nextChunkLocked];
            if (!chunk) {
                // Exhausted: restart for a seamless loop. Guard against a file
                // that yields nothing, so we never spin forever.
                if (++loops > 2) break;
                [self restartReaderLocked];
                continue;
            }
            loops = 0;
            NSUInteger need = length - out.length;
            if (chunk.length <= need) {
                [out appendData:chunk];
            } else {
                [out appendBytes:chunk.bytes length:need];
                [_carry appendBytes:(const char *)chunk.bytes + need
                             length:chunk.length - need];
            }
        }

        // Only accept a full buffer; a short read becomes silence upstream so we
        // never emit a half-filled audio buffer.
        if (out.length >= length) {
            out.length = length;
            result = out;
        }
    });
    return result;
}

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
    // conversion step is needed and the bytes drop straight into the buffer.
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

- (NSData *)nextChunkLocked {
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

- (void)restartReaderLocked {
    AudioStreamBasicDescription asbd = _targetASBD;
    BOOL had = _haveTarget;
    [self teardownReaderLocked];
    if (had) [self buildReaderForASBD:&asbd];
}

- (void)teardownReaderLocked {
    [_reader cancelReading];
    _reader     = nil;
    _output     = nil;
    _haveTarget = NO;
    [_carry setLength:0];
}

@end
