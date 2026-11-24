// VCamHUDBridge.h -- HUD liveness detection and fallback arbitration
//
// The SpringBoard HUD is a convenience, never a dependency. It is unavailable
// whenever any of these are true:
//   * the jailbreak does not inject into SpringBoard (some roothide setups)
//   * the user removed / disabled the SpringBoard component
//   * SpringBoard was resprung without the tweak
//   * the HUD crashed or its window failed to attach to a scene
//
// Detection is an explicit ping/pong over Darwin notifications:
//
//   app                                   SpringBoard
//    |-- clear hudAlive in shm                 |
//    |-- notify_post(hud-ping)  -------------->|
//    |                                         |-- stamp hudHeartbeat
//    |                                         |-- set hudAlive = 1
//    |<------------------ notify_post(hud-pong)|
//    |-- resolve: AVAILABLE                    |
//
// No pong inside kVCamHUDProbeTimeout => UNAVAILABLE. The app then owns every
// control itself, shows an explanatory banner, and still exposes the manual
// "Show HUD" override in case detection is wrong on an exotic setup.

#pragma once
#import <Foundation/Foundation.h>
#import "VCamSharedState.h"

NS_ASSUME_NONNULL_BEGIN

/// How long to wait for a pong before declaring the HUD unavailable.
static const NSTimeInterval kVCamHUDProbeTimeout = 1.25;

/// A heartbeat older than this is treated as stale.
static const NSTimeInterval kVCamHUDHeartbeatTTL = 10.0;

typedef NS_ENUM(NSInteger, VCamHUDAvailability) {
    VCamHUDAvailabilityUnknown     = 0,  // not probed yet
    VCamHUDAvailabilityAvailable   = 1,  // SpringBoard answered
    VCamHUDAvailabilityUnavailable = 2,  // no answer -- app drives everything
};

@interface VCamHUDBridge : NSObject

+ (instancetype)shared;

/// Last resolved availability.
@property (nonatomic, readonly) VCamHUDAvailability availability;

/// YES when the app must present the full in-app control surface because the
/// HUD cannot be relied on. Equivalent to availability != Available.
@property (nonatomic, readonly) BOOL appMustDriveEverything;

/// Human-readable explanation for the UI banner, or nil when all is well.
@property (nonatomic, readonly, nullable) NSString *statusDescription;

/// Probe the HUD. The completion runs on the main queue. Safe to call often;
/// concurrent probes coalesce into the single in-flight probe.
- (void)probeWithCompletion:(nullable void (^)(VCamHUDAvailability availability))completion;

/// Ask SpringBoard to show/hide its HUD window. Returns NO immediately if the
/// HUD is known-unavailable (nothing is listening).
- (BOOL)requestHUDVisible:(BOOL)visible;

/// Called from the SpringBoard side: answer a ping and stamp the heartbeat.
/// Installs its own observer; call once when the HUD window is live.
- (void)beginRespondingToProbes;

/// Stamp the heartbeat without waiting for a ping (SpringBoard side).
- (void)stampHeartbeat;

@end

NS_ASSUME_NONNULL_END
