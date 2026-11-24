// VCamConfig.h -- Durable configuration layer
//
// Two tiers, deliberately:
//   VCamSharedState (mmap)  -- hot path, read every frame by cameracaptured
//   Config.plist            -- durable, survives reboot, readable by Settings
//
// VCamConfig keeps them in sync. Every setter writes the plist AND republishes
// the shared state, then posts the Darwin notification. Any process may call
// these; the daemon only ever reads.

#pragma once
#import <Foundation/Foundation.h>
#import "VCamSharedState.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCamConfig : NSObject

+ (instancetype)shared;

/// Load the plist from disk into memory and publish it to shared state.
/// Call once at process start.
- (void)load;

/// Force a re-read of the plist (e.g. after Settings changed it).
- (void)reload;

/// Flush the in-memory dictionary to disk atomically and publish + notify.
- (void)commit;

// -- Raw access ----------------------------------------------------------
- (nullable id)objectForKey:(NSString *)key;
- (void)setObject:(nullable id)value forKey:(NSString *)key;

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;
- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def;
- (float)floatForKey:(NSString *)key defaultValue:(float)def;
- (nullable NSString *)stringForKey:(NSString *)key;

// -- Typed, published properties -----------------------------------------
// Setting any of these commits the plist and republishes shared state.
@property (nonatomic, assign) BOOL           enabled;
@property (nonatomic, assign) BOOL           paused;
@property (nonatomic, assign) VCamSourceType sourceType;
@property (nonatomic, assign) VCamFitMode    fitMode;
@property (nonatomic, assign) VCamRotation   rotation;
@property (nonatomic, assign) float          zoom;
@property (nonatomic, assign) float          panX;
@property (nonatomic, assign) float          panY;
@property (nonatomic, assign) BOOL           mirrorH;
@property (nonatomic, assign) BOOL           mirrorV;
@property (nonatomic, assign) BOOL           hudEnabled;
@property (nonatomic, assign) BOOL           useRealAudio;
@property (nonatomic, assign) BOOL           perAppEnabled;

@property (nonatomic, copy, nullable)   NSString *sourcePath;
@property (nonatomic, copy, nullable)   NSString *audioPath;

/// Bundle identifiers the vcam applies to when perAppEnabled is YES.
@property (nonatomic, copy) NSArray<NSString *> *perAppList;

- (BOOL)isAppEnabled:(NSString *)bundleID;
- (void)setApp:(NSString *)bundleID enabled:(BOOL)on;

/// Build a VCamSharedState snapshot from the current configuration.
- (VCamSharedState)snapshot;

/// Publish the current configuration into shared memory + notify listeners.
- (void)publish;

/// Publish without posting a notification. Used by -reload, because reload is
/// itself what listeners do in response to the notification.
- (void)publishQuiet:(BOOL)quiet;

@end

NS_ASSUME_NONNULL_END
