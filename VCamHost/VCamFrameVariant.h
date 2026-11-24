// VCamFrameVariant.h -- One output shape, pooled
//
// A "variant" is a single (width, height, pixel format) triple that some client
// connection has asked for. Each variant owns:
//
//   * a CVPixelBufferPool, so steady-state delivery allocates nothing
//   * the most recently rendered buffer for that shape
//   * the source generation that buffer was rendered from
//
// Why this exists: a capture session can have several connections at different
// presets, and the still path wants BGRA while the video path wants 420v. The
// first version of this engine rendered one global size and handed the same
// buffer to everyone, which delivers the wrong shape to any connection that
// asked for something else -- a documented failure mode, where a client that
// requested one preset receives "1280x720 landscape BGRA whatever its preset or
// connection asked for".
//
// Deriving the shape from the sample buffer being replaced, and caching one
// render per shape per source frame, fixes that without re-rendering per call.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Allocation ceiling per variant. Must cover every buffer that can be in flight
/// at once for one shape: the current cached frame, the frame just handed to the
/// sink, and the one or two prior frames a third-party consumer may still hold
/// in its own XPC queue. Three was too few -- the pool ran dry mid-stream and the
/// hook fell back to the real camera, which is the "video flashes the real feed"
/// symptom. Six gives comfortable headroom at ~3 MB per 1080p NV12 buffer, well
/// inside the daemon's budget for the one or two shapes typically active. The
/// exhaustion fallback (serve the last rendered frame) still guarantees we never
/// leak the real camera even if this is somehow exceeded.
static const int kVCamVariantPoolCeiling = 6;

@interface VCamFrameVariant : NSObject

/// Returns nil if a pool cannot be created for this shape (unsupported format,
/// absurd dimensions, or allocation failure).
- (nullable instancetype)initWithWidth:(size_t)width
                                height:(size_t)height
                           pixelFormat:(OSType)pixelFormat;

@property (nonatomic, readonly) size_t width;
@property (nonatomic, readonly) size_t height;
@property (nonatomic, readonly) OSType pixelFormat;

/// Monotonic counter of the source frame the cached buffer was rendered from.
/// 0 means nothing cached yet.
@property (nonatomic, readonly) uint64_t generation;

/// Mach time of the last request, for LRU eviction.
@property (nonatomic, readonly) uint64_t lastUsed;

/// Marks this variant as used now.
- (void)touch;

/// Returns the cached buffer retained if it was rendered from `generation`,
/// otherwise NULL. Caller must CVPixelBufferRelease a non-NULL result.
- (nullable CVPixelBufferRef)cachedBufferForGeneration:(uint64_t)generation
                                                        CF_RETURNS_RETAINED;

/// Returns the most recently rendered buffer for this shape, retained,
/// regardless of which generation it came from, or NULL if nothing has been
/// rendered yet. Used as the exhaustion fallback: a stale-but-ours frame always
/// beats letting the real camera through. Caller must CVPixelBufferRelease.
- (nullable CVPixelBufferRef)lastRenderedBuffer CF_RETURNS_RETAINED;

/// Takes a buffer from the pool, ready to be rendered into. Colour attachments
/// are applied before return, so CoreImage honours them during the render.
/// Returns NULL when the pool is at its ceiling. Caller must release.
- (nullable CVPixelBufferRef)newPooledBuffer CF_RETURNS_RETAINED;

/// Stores `buffer` as the cached render for `generation`.
- (void)cacheBuffer:(CVPixelBufferRef)buffer generation:(uint64_t)generation;

/// Drops the cached buffer. The pool is kept.
- (void)invalidate;

/// YES if this engine can render the given format at all.
+ (BOOL)supportsPixelFormat:(OSType)pixelFormat;

/// Human-readable FourCC, for logs. Returns a static-lifetime string.
+ (const char *)describeFormat:(OSType)pixelFormat;

@end

NS_ASSUME_NONNULL_END
