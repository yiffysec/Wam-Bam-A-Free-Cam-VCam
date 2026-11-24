// VCamHUDBridge.m -- HUD liveness detection and fallback arbitration
#import "VCamHUDBridge.h"
#import "VCamTypes.h"

@implementation VCamHUDBridge {
    VCamHUDAvailability _availability;
    int                 _pongToken;
    int                 _pingToken;
    BOOL                _probeInFlight;
    BOOL                _gotPong;
    NSMutableArray     *_pendingCompletions;
    dispatch_queue_t    _q;
}

+ (instancetype)shared {
    static VCamHUDBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _availability       = VCamHUDAvailabilityUnknown;
    _pongToken          = -1;
    _pingToken          = -1;
    _pendingCompletions = [NSMutableArray array];
    _q = dispatch_queue_create("com.yiffysec.vcam.hudbridge", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    vcam_notify_cancel(_pongToken);
    vcam_notify_cancel(_pingToken);
}

- (VCamHUDAvailability)availability { return _availability; }

- (BOOL)appMustDriveEverything {
    return _availability != VCamHUDAvailabilityAvailable;
}

- (NSString *)statusDescription {
    switch (_availability) {
        case VCamHUDAvailabilityAvailable:
            return nil;
        case VCamHUDAvailabilityUnavailable:
            return @"The SpringBoard HUD isn't responding, so every control is "
                    "being driven from this app instead. Nothing is lost — the "
                    "camera override works exactly the same. Use the override "
                    "below if you believe the HUD is actually installed.";
        case VCamHUDAvailabilityUnknown:
        default:
            return @"Checking whether the SpringBoard HUD is available…";
    }
}

// -- probe ---------------------------------------------------------------
- (void)probeWithCompletion:(void (^)(VCamHUDAvailability))completion {
    dispatch_async(_q, ^{
        if (completion) [_pendingCompletions addObject:[completion copy]];

        if (_probeInFlight) return;      // coalesce
        _probeInFlight = YES;
        _gotPong       = NO;

        if (vcam_shm_open() != 0) {
            // No shared memory at all: the app still works via the plist, but
            // the HUD definitively cannot be talking to us.
            [self _resolve:VCamHUDAvailabilityUnavailable];
            return;
        }

        // Register the pong listener before pinging so we cannot miss it.
        if (_pongToken < 0) {
            __weak typeof(self) weakSelf = self;
            _pongToken = vcam_notify_observe(kVCamNotifyHUDPong, _q, ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf->_gotPong = YES;
                [strongSelf _resolve:VCamHUDAvailabilityAvailable];
            });
        }

        // Clear the liveness flag so a stale value cannot be mistaken for a reply.
        VCamSharedState st;
        vcam_shm_read(&st);
        st.hudAlive = 0;
        vcam_shm_write_quiet(&st);

        vcam_notify_post(kVCamNotifyHUDPing);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kVCamHUDProbeTimeout * NSEC_PER_SEC)),
                       _q, ^{
            if (!_probeInFlight) return;   // already resolved by the pong

            // Second chance: the SpringBoard side may have stamped the shared
            // state even if the notification was dropped under memory pressure.
            VCamSharedState now;
            vcam_shm_read(&now);
            NSTimeInterval age = CFAbsoluteTimeGetCurrent() - now.hudHeartbeat;
            BOOL fresh = (now.hudAlive != 0) && (age >= 0) && (age < kVCamHUDHeartbeatTTL);

            [self _resolve:fresh ? VCamHUDAvailabilityAvailable
                                 : VCamHUDAvailabilityUnavailable];
        });
    });
}

// Must be called on _q.
- (void)_resolve:(VCamHUDAvailability)result {
    if (!_probeInFlight) return;
    _probeInFlight = NO;
    _availability  = result;

    VCamLogI("HUDBridge: availability resolved = %ld", (long)result);

    NSArray *completions = [_pendingCompletions copy];
    [_pendingCompletions removeAllObjects];

    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^c)(VCamHUDAvailability) in completions) c(result);
    });
}

// -- request visibility --------------------------------------------------
- (BOOL)requestHUDVisible:(BOOL)visible {
    // Record the intent durably regardless; SpringBoard reads it on next launch.
    if (vcam_shm_open() == 0) {
        VCamSharedState st;
        vcam_shm_read(&st);
        st.hudEnabled = visible ? 1 : 0;
        vcam_shm_write(&st);
    }

    if (_availability == VCamHUDAvailabilityUnavailable) {
        VCamLogI("HUDBridge: requestHUDVisible:%d while HUD unavailable", (int)visible);
        return NO;
    }

    vcam_notify_post(kVCamNotifyToggleHUD);
    return YES;
}

// -- SpringBoard side ----------------------------------------------------
- (void)beginRespondingToProbes {
    if (_pingToken >= 0) return;
    vcam_shm_open();

    __weak typeof(self) weakSelf = self;
    _pingToken = vcam_notify_observe(kVCamNotifyHUDPing, _q, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf stampHeartbeat];
        vcam_notify_post(kVCamNotifyHUDPong);
    });

    [self stampHeartbeat];
    VCamLogI("HUDBridge: now responding to probes");
}

- (void)stampHeartbeat {
    if (vcam_shm_open() != 0) return;
    VCamSharedState st;
    vcam_shm_read(&st);
    st.hudAlive     = 1;
    st.hudHeartbeat = CFAbsoluteTimeGetCurrent();
    vcam_shm_write_quiet(&st);
}

@end
