// VCamClient.x -- Per-app gating, injected into every UIKit application
//
// cameracaptured serves every app from one process, so the daemon alone cannot
// tell which app a frame is destined for without reaching into private client
// identity structures that move between iOS releases. Instead this tiny dylib
// rides along in the app, and when the app actually starts a capture session it
// publishes the verdict for its own bundle identifier into shared memory.
//
// The daemon then simply honours clientAllowed. In system-wide mode the verdict
// is always YES, so this component is a no-op and the tweak works even if this
// dylib fails to load.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamConfig.h"
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

%hook AVCaptureSession

- (void)startRunning {
    @try {
        vcam_publish_client_verdict();
    } @catch (NSException *ex) {
        VCamLogE("VCamClient: verdict publish threw %{public}@", ex.reason);
    }
    %orig;
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

        // Keep the verdict current if the user flips per-app settings while the
        // app sits in the foreground.
        vcam_notify_observe(kVCamNotifyConfigChanged,
                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            vcam_publish_client_verdict();
        });

        %init;
    }
}
