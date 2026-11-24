// VCamFrameEngine.h -- 30Hz frame pump
//
// Responsibilities:
//   * decode the user's video (AVAssetReader, seamless loop) or hold the still
//   * keep two ready-to-serve frames: 420v for video sinks, BGRA for still sinks
//   * drive BWRemoteQueueSinkNode independently at 30Hz so third-party apps get
//     a moving image even when the real graph is not pulling
//   * apply framing: fit mode, rotation, mirroring, zoom and pan
//   * stay inside a bounded buffer budget so jetsam never kills the daemon

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@class VCamMediaSource;

NS_ASSUME_NONNULL_BEGIN

@interface VCamFrameEngine : NSObject

@property (class, nonatomic, readonly) VCamFrameEngine *sharedEngine;

/// Start the pump. Idempotent.
- (void)start;

/// Stop the pump and release every buffer it holds.
- (void)stop;

/// Reload media and restart.
- (void)restartWithSource:(nullable VCamMediaSource *)source;

/// Re-read shared state and start/stop as the new configuration requires.
- (void)applyConfig;

/// Report the real sensor geometry so output dimensions match it exactly.
- (void)notifyRealCameraSize:(CGSize)size;

/// Remember a remote sink node so the 30Hz timer can push frames into it.
- (void)registerRemoteQueueSinkNode:(id)node input:(nullable id)input;

/// Latest 420v frame, retained. Caller must CVPixelBufferRelease.
- (nullable CVPixelBufferRef)currentFrame420v CF_RETURNS_RETAINED;

/// Latest BGRA frame, retained. Caller must CVPixelBufferRelease.
- (nullable CVPixelBufferRef)currentFrameBGRA CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
