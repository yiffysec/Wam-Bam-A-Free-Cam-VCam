// VCamClient.x -- Per-app gating + in-app HUD, injected into every UIKit app
//
// Two jobs, both because the daemon serves every app from one process and cannot
// cleanly tell apps apart from inside:
//
//   1. Per-app gating. When the app starts a capture session it publishes the
//      verdict for its own bundle identifier into shared memory; the daemon then
//      honours clientAllowed. In system-wide mode the verdict is always YES, so
//      this is a no-op and the tweak works even if this dylib fails to load.
//
//   2. The floating HUD, OVER THE APP. A window created in SpringBoard is
//      composited beneath a foreground app's own scene on modern iOS, so it is
//      invisible while an app is up -- which is exactly when the user wants the
//      controls. The fix is to put the pill in the app's OWN active scene, from
//      inside the app, at UIWindowLevelAlert. We raise it while a capture session
//      is running (the only time the camera controls are useful) and take it down
//      when the session stops. The shared VCamFloatingHUD is the same pill the
//      SpringBoard HUD shows; this is just the app-side trigger.
//
// Everything here is wrapped so a failure degrades to "no in-app HUD", never a
// crashed host app.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamConfig.h"
#import "../Shared/VCamFloatingHUD.h"
#import "../Shared/VCamTypes.h"

static NSString *vcam_own_bundle_id(void) {
    static NSString *bid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    });
    return bid;
}

/// Publishes whether the vcam should apply to this process.
static void vcam_publish_client_verdict(void) {
    if (vcam_shm_open() != 0) return;

    VCamConfig *cfg = [VCamConfig shared];
    [cfg reload];

    NSString *bid = vcam_own_bundle_id();
    BOOL allowed  = [cfg isAppEnabled:bid];

    VCamSharedState st;
    vcam_shm_read(&st);
    st.clientAllowed = allowed ? 1 : 0;
    vcam_shm_write_quiet(&st);

    vcam_notify_post(kVCamNotifyClientChanged);

    VCamLogI("VCamClient: %{public}@ -> allowed=%d (perApp=%d)",
             bid, (int)allowed, (int)cfg.perAppEnabled);
}

// -- In-app HUD -----------------------------------------------------------
static void vcam_client_show_hud(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[VCamConfig shared] reload];
            [[VCamFloatingHUD shared] presentInScene:nil];
        } @catch (NSException *ex) {
            VCamLogE("VCamClient: HUD present threw %{public}@", ex.reason);
        }
    });
}

static void vcam_client_hide_hud(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[VCamFloatingHUD shared] dismiss];
        } @catch (NSException *ex) {
            VCAM_UNUSED(ex);
        }
    });
}

%hook AVCaptureSession

- (void)startRunning {
    @try {
        vcam_publish_client_verdict();
    } @catch (NSException *ex) {
        VCamLogE("VCamClient: verdict publish threw %{public}@", ex.reason);
    }
    %orig;
    // The camera is live in this app now: raise the controls over it.
    vcam_client_show_hud();
}

- (void)stopRunning {
    %orig;
    vcam_client_hide_hud();
}

- (void)addInput:(AVCaptureInput *)input {
    %orig;
    // Publish early too: some apps configure inputs well before startRunning,
    // and a few third-party SDKs drive the graph without calling startRunning
    // on the public class at all.
    @try {
        vcam_publish_client_verdict();
    } @catch (NSException *ex) {
        VCAM_UNUSED(ex);
    }
}

%end

%ctor {
    // Only meaningful inside real apps. Skip daemons and SpringBoard.
    @autoreleasepool {
        if (!NSBundle.mainBundle.bundleIdentifier) return;
        if ([vcam_own_bundle_id() isEqualToString:@"com.apple.springboard"]) return;

        vcam_shm_open();

        // Keep the verdict current, and the HUD in step, if the user flips
        // settings while the app sits in the foreground.
        vcam_notify_observe(kVCamNotifyConfigChanged,
                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            vcam_publish_client_verdict();
            dispatch_async(dispatch_get_main_queue(), ^{
                @try { [[VCamFloatingHUD shared] refresh]; }
                @catch (NSException *ex) { VCAM_UNUSED(ex); }
            });
        });

        // Let the app raise the pill on demand (e.g. the companion app asks every
        // process to show it) even if no capture session is running.
        vcam_notify_observe(kVCamNotifyToggleHUD, dispatch_get_main_queue(), ^{
            @try {
                [[VCamConfig shared] reload];
                [[VCamFloatingHUD shared] presentInScene:nil];
            } @catch (NSException *ex) { VCAM_UNUSED(ex); }
        });

        %init;
    }
}
