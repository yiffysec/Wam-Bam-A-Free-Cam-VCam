// VCamFrameEngine.h -- Source decode plus per-shape delivery
//
// Two halves:
//
//   Producer -- a 30Hz timer decodes the user's video (AVAssetReader, looped)
//               or holds their still, and publishes it as "the source frame"
//               with a monotonically increasing generation number.
//
//   Consumer -- hooks ask for a frame matching the exact shape the client
//               connection asked for. The engine renders the source through the
//               framing pipeline into a pooled buffer of that shape, caches it
//               against the current generation, and hands it back. Several
//               connections at different presets each get a correct frame, and
//               each shape is rendered at most once per source frame.
//
// It also drives BWRemoteQueueSinkNode independently at 30Hz, gated on stall
// detection, because a client graph that is not pulling otherwise shows a
// frozen first frame or nothing at all.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@class VCamMediaSource;

NS_ASSUME_NONNULL_BEGIN

/// How many distinct output shapes to keep pooled at once. Past this the least
/// recently used variant is evicted, so an app cycling presets cannot grow our
/// memory without bound.
static const NSUInteger kVCamMaxVariants = 4;

@interface VCamFrameEngine : NSObject

@property (class, nonatomic, readonly) VCamFrameEngine *sharedEngine;

// -- Lifecycle -----------------------------------------------------------
- (void)start;
- (void)stop;
- (void)restartWithSource:(nullable VCamMediaSource *)source;
- (void)applyConfig;

/// Report the real sensor geometry, used only as a last-resort default when a
/// sample buffer carries no usable shape of its own.
- (void)notifyRealCameraSize:(CGSize)size;

// -- Delivery ------------------------------------------------------------

/// The main entry point for hooks. Derives width, height and pixel format from
/// `sampleBuffer` -- its image buffer first, then its format description --
/// and returns a frame of exactly that shape.
///
/// `fallbackFormat` is used only when the sample buffer declares no format at
/// all. Pass the format that sink class is documented to want.
///
/// Returns NULL when there is no media, the engine is not ready, the requested
/// format is one we cannot produce, or the pool is at its ceiling. A NULL
/// result means "pass the real frame through" -- never "deliver nothing".
///
/// Caller must CVPixelBufferRelease a non-NULL result.
- (nullable CVPixelBufferRef)frameForSampleBuffer:(nullable CMSampleBufferRef)sampleBuffer
                                   fallbackFormat:(OSType)fallbackFormat
                                                   CF_RETURNS_RETAINED;

/// Explicit-shape variant, for callers that know what they want.
- (nullable CVPixelBufferRef)frameForWidth:(size_t)width
                                    height:(size_t)height
                               pixelFormat:(OSType)pixelFormat
                                             CF_RETURNS_RETAINED;

/// Remember a remote sink node so the 30Hz timer can push into it when the real
/// graph goes quiet.
- (void)registerRemoteQueueSinkNode:(id)node input:(nullable id)input;

// -- Diagnostics ---------------------------------------------------------

/// YES once a source frame is available to serve.
@property (nonatomic, readonly) BOOL hasSourceFrame;

/// Number of output shapes currently pooled.
@property (nonatomic, readonly) NSUInteger variantCount;

@end

NS_ASSUME_NONNULL_END
