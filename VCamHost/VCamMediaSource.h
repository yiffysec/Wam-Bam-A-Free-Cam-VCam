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

/// The audio file to use for the active audio mode, or nil when the mode needs
/// no file (None/Microphone): the imported video's URL for VCamAudioVideo, the
/// custom audio file for VCamAudioCustom.
@property (nonatomic, readonly, copy, nullable) NSURL *audioURL;
@property (nonatomic, readonly) VCamAudioMode audioMode;

@end

NS_ASSUME_NONNULL_END
