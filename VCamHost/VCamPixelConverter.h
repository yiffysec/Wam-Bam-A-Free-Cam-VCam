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

/// Must be called once before use (sets up Metal device and CIContext).
- (void)setup;

/// The shared Metal-backed CIContext. nil if Metal is unavailable.
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
