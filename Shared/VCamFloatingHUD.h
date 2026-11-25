// VCamFloatingHUD.h -- The floating control pill, shared by two hosts
//
// The exact same window and controls are shown from two places:
//   * SpringBoard  -- floats over the home screen and lock screen.
//   * every app (via VCamClient) -- floats over THAT app while it is using the
//     camera. This is the only way to sit above a foreground app on modern iOS:
//     a window created in SpringBoard is composited beneath the app's own scene
//     layer, so it is invisible while an app is up. A window created inside the
//     app, in the app's own active window scene at UIWindowLevelAlert, is not.
//
// One implementation, two callers, so the controls never drift apart. The
// manager is defensive by construction: every entry point is safe to call from
// the main thread at any time, tolerates having no scene, and never throws.

#pragma once
#import <UIKit/UIKit.h>
#import "VCamSharedState.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCamFloatingHUD : NSObject

+ (instancetype)shared;

/// Create (if needed) and show the pill in `scene`, or in the process's active
/// foreground window scene when `scene` is nil. Honours hudEnabled and the
/// suppressed flag. Must be called on the main thread.
- (void)presentInScene:(nullable UIWindowScene *)scene;

/// Tear the window down entirely.
- (void)dismiss;

/// Re-read shared state and update the controls and visibility in place.
- (void)refresh;

/// App switcher / lock screen want the pill hidden without destroying it.
- (void)setSuppressed:(BOOL)suppressed;

/// YES once a window exists (whether or not it is currently visible).
@property (nonatomic, readonly) BOOL isPresented;

@end

NS_ASSUME_NONNULL_END
