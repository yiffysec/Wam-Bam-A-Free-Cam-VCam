// VCamPixelConverter.h — Metal-backed pixel format conversion + CIContext
//
// Provides:
//   - A shared Metal-backed CIContext for CIImage rendering
//   - BGRA → 420v conversion (Metal compute shader)
//   - 420v → BGRA conversion (for still-sink delivery)

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamPixelConverter : NSObject

@property (class, nonatomic, readonly) VCamPixelConverter *sharedConverter;

/// Arms the converter. Safe to call from a dylib constructor: the expensive
/// Metal work is deferred to a background queue, because compiling a shader
/// inside cameracaptured's startup path risks delaying the torch XPC service
/// SpringBoard waits on during boot. See the comment on -setup.
- (void)setup;

/// Blocks until setup has completed. Call from a worker thread only, never from
/// a constructor and never from a hook on the capture thread.
- (void)ensureReady;

/// YES once -ciContext is usable.
@property (nonatomic, readonly) BOOL isReady;

/// The shared Metal-backed CIContext. nil until setup completes.
@property (nonatomic, readonly, nullable) CIContext *ciContext;

/// Convert a 420v CVPixelBuffer to BGRA. Returns a new, retained buffer, or
/// NULL on failure. Caller must CVPixelBufferRelease.
- (nullable CVPixelBufferRef)convertToBGRA:(CVPixelBufferRef)src420v
                                            CF_RETURNS_RETAINED;

/// Convert a BGRA CVPixelBuffer to 420v. Returns a new, retained buffer, or
/// NULL on failure. Caller must CVPixelBufferRelease.
- (nullable CVPixelBufferRef)convertTo420v:(CVPixelBufferRef)srcBGRA
                                            CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
