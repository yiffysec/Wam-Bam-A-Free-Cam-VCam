// VCamPixelConverter.h -- The shared Metal-backed CIContext
//
// Deliberately small. An earlier version carried a hand-written BGRA->NV12
// Metal compute kernel, compiled from source at runtime. Both the kernel and
// the compile are gone, for two reasons:
//
//   1. It was dead code. The frame engine renders CIImages straight into
//      destination buffers whose pixel format is whatever the client asked for,
//      and CoreImage performs the RGB-to-YCbCr conversion itself, honouring the
//      colour attachments set on the destination. Nothing ever called the
//      kernel.
//
//   2. Compiling Metal from source text costs hundreds of milliseconds, and the
//      earlier code spent them inside cameracaptured's startup path -- while
//      SpringBoard waits synchronously on that daemon's torch service during
//      boot, and concurrently with Apple's own GPU prewarm, which is known to
//      crash-loop in some iOS 26 configurations.
//
// What remains is one CIContext with a defined working colour space. Setup is
// still deferred off the constructor: creating a Metal device is much cheaper
// than compiling a shader, but it is not free, and the camera daemon's startup
// is not the place to find out.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamPixelConverter : NSObject

@property (class, nonatomic, readonly) VCamPixelConverter *sharedConverter;

/// Arms the converter. Safe to call from a dylib constructor: the Metal work
/// happens on a background queue.
- (void)setup;

/// Blocks until setup has completed. Call from a worker thread only -- never
/// from a constructor, and never from a hook on the capture thread.
- (void)ensureReady;

/// YES once -ciContext is usable.
@property (nonatomic, readonly) BOOL isReady;

/// The shared CIContext. nil until setup completes.
@property (nonatomic, readonly, nullable) CIContext *ciContext;

@end

NS_ASSUME_NONNULL_END
