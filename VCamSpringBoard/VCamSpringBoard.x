// VCamSpringBoard.x -- Floating HUD overlay on the home and lock screens
//
// The HUD here floats over SpringBoard itself. Floating over a foreground APP is
// the in-app overlay's job (VCamClient), because a SpringBoard window is
// composited beneath an app's own scene on modern iOS. The pill, its controls
// and all of its behaviour live in the shared VCamFloatingHUD; this file is just
// the SpringBoard-side lifecycle around it.
//
// The HUD is strictly optional. If this dylib never loads -- some roothide setups
// do not inject into SpringBoard, the user removed the component, or the window
// fails to attach -- the app detects the silence (VCamHUDBridge) and takes over,
// so no capability is lost.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamConfig.h"
#import "../Shared/VCamHUDBridge.h"
#import "../Shared/VCamFloatingHUD.h"
#import "../Shared/VCamTypes.h"

static dispatch_source_t gHeartbeatTimer = nil;   // lives as long as SpringBoard

// -- Bootstrap ------------------------------------------------------------
static void vcam_springboard_bootstrap(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    vcam_shm_open();
    [[VCamConfig shared] load];

    // Start answering liveness probes immediately -- before the window even
    // exists -- so the app learns the HUD component is installed even if the
    // window is currently hidden or suppressed.
    [[VCamHUDBridge shared] beginRespondingToProbes];

    vcam_notify_observe(kVCamNotifyConfigChanged, dispatch_get_main_queue(), ^{
        [[VCamConfig shared] reload];
        [[VCamFloatingHUD shared] refresh];
    });

    vcam_notify_observe(kVCamNotifyToggleHUD, dispatch_get_main_queue(), ^{
        [[VCamConfig shared] reload];
        [[VCamFloatingHUD shared] presentInScene:nil];   // creates or refreshes
    });

    // Re-stamp the heartbeat periodically so a probe that loses its notification
    // can still fall back on a fresh timestamp. Stored in a static because under
    // ARC a dispatch source held only in a local is released when the scope ends,
    // which would cancel the timer before it ever fires.
    gHeartbeatTimer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gHeartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                               3ull * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gHeartbeatTimer, ^{
        [[VCamHUDBridge shared] stampHeartbeat];
    });
    dispatch_resume(gHeartbeatTimer);

    VCamSharedState st;
    vcam_shm_read(&st);
    if (st.hudEnabled) [[VCamFloatingHUD shared] presentInScene:nil];

    VCamLogI("VCamHUD: SpringBoard bootstrap complete (hudEnabled=%d)",
             (int)st.hudEnabled);
}

// -- SpringBoard hooks ----------------------------------------------------
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            vcam_springboard_bootstrap();
        } @catch (NSException *ex) {
            VCamLogE("VCamHUD: bootstrap threw %{public}@ -- app-side controls "
                     "remain fully functional", ex.reason);
        }
    });
}

%end

// Keep the HUD out of the way of the app switcher.
%hook SBAppSwitcherViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[VCamFloatingHUD shared] setSuppressed:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [[VCamFloatingHUD shared] setSuppressed:NO];
}

%end

// ...and off the lock screen.
%hook SBLockScreenManager

- (void)_setUILocked:(BOOL)locked {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VCamFloatingHUD shared] setSuppressed:locked];
    });
}

%end
