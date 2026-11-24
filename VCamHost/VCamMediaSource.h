// VCamMediaSource.h — Manages the user's source media file
//
// Reads configuration from kVCamConfigPath (via libSandy in daemon context)
// and exposes the resolved source URL and type.

#pragma once
#import <Foundation/Foundation.h>
#import "VCamSharedState.h"  // for VCamSourceType

NS_ASSUME_NONNULL_BEGIN

@interface VCamMediaSource : NSObject

@property (class, nonatomic, readonly) VCamMediaSource *sharedSource;

/// Setup — load initial config
- (void)setup;

/// Reload config from plist (called on Darwin notify)
- (void)reloadConfig;

/// Reload media file (called when file changes)
- (void)reloadMedia;

@property (nonatomic, readonly) VCamSourceType sourceType;
@property (nonatomic, readonly, copy, nullable) NSURL *mediaURL;
@property (nonatomic, readonly, copy, nullable) NSURL *audioURL;  // nil = real mic
@property (nonatomic, readonly) BOOL useRealAudio;

@end

NS_ASSUME_NONNULL_END
