// VCamAudioEngine.h -- Produces the audio that replaces the live microphone
//
// Four modes, mapped from VCamAudioMode:
//   None        -> silence
//   Video       -> the imported video's own audio track
//   Microphone  -> pass the real mic through (muted -> silence)
//   Custom      -> a custom imported audio file
//
// The design principle mirrors the video side: never leak what the user asked to
// hide, and never crash the host. Concretely, the engine only ever builds a
// REPLACEMENT buffer that matches the original's format, timing and frame count
// exactly -- it never mutates the system's buffer in place (that memory may be
// read-only) and never changes the stream's shape. Silence is built directly and
// always succeeds; the file-backed modes decode through AVAssetReader in the
// target PCM format, and if decoding or format matching fails for any reason the
// engine returns silence rather than nothing. So the worst case for Video/Custom
// is "quiet", never "crash" and never "the real microphone leaks through".

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "VCamSharedState.h"   // VCamAudioMode

@class VCamMediaSource;

NS_ASSUME_NONNULL_BEGIN

@interface VCamAudioEngine : NSObject

@property (class, nonatomic, readonly) VCamAudioEngine *sharedEngine;

/// Point the engine at the file the current audio mode needs (the video for
/// VCamAudioVideo, the custom file for VCamAudioCustom, nil otherwise). Cheap to
/// call on every config change; it only rebuilds the decoder when the URL
/// actually changes.
- (void)configureWithSource:(VCamMediaSource *)source;

/// Given the microphone buffer the graph is delivering, return the buffer that
/// should replace it, or NULL to let the original pass through untouched.
///
///   Microphone, not muted -> NULL (pass through)
///   None, or muted        -> silence shaped like `original`
///   Video / Custom        -> file audio in `original`'s format, or silence if
///                            the file cannot be produced
///
/// Caller owns a non-NULL result and must CFRelease it.
- (nullable CMSampleBufferRef)replacementForBuffer:(CMSampleBufferRef)original
                                               mode:(VCamAudioMode)mode
                                              muted:(BOOL)muted
                                                     CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
