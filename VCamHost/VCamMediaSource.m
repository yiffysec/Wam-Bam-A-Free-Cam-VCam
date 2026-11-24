// VCamMediaSource.m -- Resolves the user's chosen media inside the daemon
//
// The daemon deliberately does NOT use VCamConfig: that class publishes to
// shared memory on every read, and the daemon must never write state the app
// and HUD own. Here we only ever read -- the plist for paths, shared memory for
// the hot flags.

#import "VCamMediaSource.h"
#import "VCamTypes.h"
#import "VCamPaths.h"
#import <Foundation/Foundation.h>

static NSArray<NSString *> *vcam_video_extensions(void) {
    return @[@"mov", @"mp4", @"m4v"];
}

static NSArray<NSString *> *vcam_photo_extensions(void) {
    return @[@"jpg", @"jpeg", @"png", @"heic"];
}

/// Finds the first existing kVCamMediaPath.<ext> for a source type.
static NSString *vcam_conventional_path(VCamSourceType type) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *exts = (type == VCamSourceVideo) ? vcam_video_extensions()
                                              : vcam_photo_extensions();
    for (NSString *ext in exts) {
        NSString *p = [VCamMediaBasePath() stringByAppendingPathExtension:ext];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

/// Infers the source type from a file extension.
static VCamSourceType vcam_type_for_path(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([vcam_video_extensions() containsObject:ext]) return VCamSourceVideo;
    if ([vcam_photo_extensions() containsObject:ext]) return VCamSourcePhoto;
    return VCamSourceNone;
}

@implementation VCamMediaSource {
    dispatch_queue_t _q;
    NSDate          *_mediaMTime;
}

@synthesize sourceType   = _sourceType;
@synthesize mediaURL     = _mediaURL;
@synthesize audioURL     = _audioURL;
@synthesize useRealAudio = _useRealAudio;

+ (VCamMediaSource *)sharedSource {
    static VCamMediaSource *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q            = dispatch_queue_create("com.yiffysec.vcam.mediasource",
                                           DISPATCH_QUEUE_SERIAL);
    _useRealAudio = YES;
    _sourceType   = VCamSourceNone;
    return self;
}

- (void)setup      { dispatch_sync(_q,  ^{ [self resolve]; }); }
- (void)reloadConfig { dispatch_async(_q, ^{ [self resolve]; }); }
- (void)reloadMedia  { dispatch_async(_q, ^{ [self resolve]; }); }

- (void)resolve {
    NSDictionary *cfg =
        [NSDictionary dictionaryWithContentsOfFile:VCamConfigPath()] ?: @{};
    NSFileManager *fm = NSFileManager.defaultManager;

    // ---- Video / photo ------------------------------------------------
    NSString  *resolved = nil;
    VCamSourceType type = (VCamSourceType)[cfg[@kVCamPrefSourceType] integerValue];

    // 1. Explicit path from the app.
    NSString *explicit = cfg[@kVCamPrefSourcePath];
    if ([explicit isKindOfClass:NSString.class] && explicit.length &&
        [fm fileExistsAtPath:explicit]) {
        resolved = explicit;
        VCamSourceType inferred = vcam_type_for_path(explicit);
        if (inferred != VCamSourceNone) type = inferred;
    }

    // 2. Conventional path for the configured type.
    if (!resolved && type != VCamSourceNone) {
        resolved = vcam_conventional_path(type);
    }

    // 3. Last resort: whatever is actually on disk.
    if (!resolved) {
        for (VCamSourceType t = VCamSourceVideo; t <= VCamSourcePhoto; t++) {
            NSString *p = vcam_conventional_path(t);
            if (p) { resolved = p; type = t; break; }
        }
    }

    if (!resolved) type = VCamSourceNone;

    // ---- Audio ---------------------------------------------------------
    NSString *audio = cfg[@kVCamPrefAudioPath];
    NSURL *audioURL = nil;
    if ([audio isKindOfClass:NSString.class] && audio.length &&
        [fm fileExistsAtPath:audio]) {
        audioURL = [NSURL fileURLWithPath:audio];
    }

    BOOL realAudio = cfg[@kVCamPrefUseRealAudio]
                   ? [cfg[@kVCamPrefUseRealAudio] boolValue]
                   : (audioURL == nil);

    // ---- Commit --------------------------------------------------------
    _sourceType   = type;
    _mediaURL     = resolved ? [NSURL fileURLWithPath:resolved] : nil;
    _audioURL     = audioURL;
    _useRealAudio = realAudio;

    if (resolved) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:resolved error:nil];
        _mediaMTime = attrs[NSFileModificationDate];
    } else {
        _mediaMTime = nil;
    }

    VCamLogI("media: type=%d path=%{public}@ realAudio=%d",
             (int)type, resolved.lastPathComponent ?: @"(none)", (int)realAudio);
}

@end
