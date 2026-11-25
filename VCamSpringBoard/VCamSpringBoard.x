// VCamSpringBoard.x -- Floating HUD overlay in SpringBoard
//
// The HUD is strictly optional. Its only jobs are:
//   * give a one-tap on/off/pause control that floats over every app
//   * answer liveness probes from the companion app
//
// Everything it can do, the app can do too. If this dylib never loads -- some
// roothide setups do not inject into SpringBoard, the user may have removed the
// component, or the window may fail to attach to a scene -- the app detects the
// silence and takes over, so no capability is lost.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamConfig.h"
#import "../Shared/VCamHUDBridge.h"
#import "../Shared/VCamTypes.h"

@interface VCamHUDWindow : UIWindow
@end

@interface VCamHUDViewController : UIViewController
- (void)refresh;
@end

static VCamHUDWindow    *gHUDWindow      = nil;
static BOOL              gSuppressedByUI = NO;   // app switcher / lock screen
static dispatch_source_t gHeartbeatTimer = nil;  // lives as long as SpringBoard

static void vcam_show_hud(void);
static void vcam_update_hud_visibility(void);

// -- VCamHUDViewController ------------------------------------------------
@implementation VCamHUDViewController {
    UIButton *_toggleBtn;
    UIButton *_pauseBtn;
    UIButton *_mirrorBtn;
    UIButton *_muteBtn;
    UIView   *_indicator;
    UILabel  *_statusLabel;
    CGPoint   _panStartOrigin;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    self.view.layer.cornerRadius   = 14;
    self.view.layer.masksToBounds  = YES;
    self.view.layer.borderColor    = [[UIColor whiteColor] colorWithAlphaComponent:0.22].CGColor;
    self.view.layer.borderWidth    = 0.5;

    _indicator = [[UIView alloc] initWithFrame:CGRectMake(9, 9, 9, 9)];
    _indicator.layer.cornerRadius  = 4.5;
    _indicator.layer.masksToBounds = YES;
    _indicator.backgroundColor     = [UIColor systemGrayColor];
    [self.view addSubview:_indicator];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(23, 3, 58, 20)];
    _statusLabel.font      = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.text      = @"VCam";
    [self.view addSubview:_statusLabel];

    _toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _toggleBtn.frame             = CGRectMake(6, 25, 76, 28);
    _toggleBtn.layer.cornerRadius = 7;
    _toggleBtn.titleLabel.font   = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [_toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_toggleBtn addTarget:self action:@selector(toggleTapped)
         forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_toggleBtn];

    _pauseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _pauseBtn.frame              = CGRectMake(6, 57, 36, 24);
    _pauseBtn.layer.cornerRadius = 6;
    _pauseBtn.backgroundColor    = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.85];
    _pauseBtn.titleLabel.font    = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [_pauseBtn setTitle:@"II" forState:UIControlStateNormal];
    [_pauseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_pauseBtn addTarget:self action:@selector(pauseTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_pauseBtn];

    _mirrorBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _mirrorBtn.frame              = CGRectMake(46, 57, 36, 24);
    _mirrorBtn.layer.cornerRadius = 6;
    _mirrorBtn.backgroundColor    = [[UIColor systemPurpleColor] colorWithAlphaComponent:0.85];
    _mirrorBtn.titleLabel.font    = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [_mirrorBtn setTitle:@"⇄" forState:UIControlStateNormal];
    [_mirrorBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_mirrorBtn addTarget:self action:@selector(mirrorTapped)
         forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_mirrorBtn];

    // Mute, full width below the others. Shown only in Microphone audio mode;
    // the window grows to make room (see -refresh). Starts hidden.
    _muteBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _muteBtn.frame              = CGRectMake(6, 85, 76, 24);
    _muteBtn.layer.cornerRadius = 6;
    _muteBtn.titleLabel.font    = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    [_muteBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_muteBtn addTarget:self action:@selector(muteTapped)
       forControlEvents:UIControlEventTouchUpInside];
    _muteBtn.hidden = YES;
    [self.view addSubview:_muteBtn];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:pan];

    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(handleHold:)];
    hold.minimumPressDuration = 0.8;
    [self.view addGestureRecognizer:hold];

    [self refresh];
}

- (void)refresh {
    VCamSharedState st;
    vcam_shm_read(&st);

    if (st.enabled && !st.paused) {
        _indicator.backgroundColor   = [UIColor systemGreenColor];
        _toggleBtn.backgroundColor   = [UIColor systemGreenColor];
        [_toggleBtn setTitle:@"ON" forState:UIControlStateNormal];
        _statusLabel.text            = @"Active";
    } else if (st.enabled && st.paused) {
        _indicator.backgroundColor   = [UIColor systemOrangeColor];
        _toggleBtn.backgroundColor   = [UIColor systemOrangeColor];
        [_toggleBtn setTitle:@"PAUSED" forState:UIControlStateNormal];
        _statusLabel.text            = @"Real cam";
    } else {
        _indicator.backgroundColor   = [UIColor systemGrayColor];
        _toggleBtn.backgroundColor   = [UIColor systemBlueColor];
        [_toggleBtn setTitle:@"OFF" forState:UIControlStateNormal];
        _statusLabel.text            = @"VCam";
    }

    _pauseBtn.alpha  = st.enabled ? 1.0 : 0.35;
    _mirrorBtn.alpha = st.enabled ? 1.0 : 0.35;
    _mirrorBtn.layer.borderWidth = st.mirrorH ? 1.5 : 0.0;
    _mirrorBtn.layer.borderColor = [UIColor whiteColor].CGColor;

    // Mute belongs to live-microphone mode only. Show it there and grow the
    // window to fit; hide it and shrink back otherwise.
    BOOL micMode = (st.audioMode == VCamAudioMicrophone);
    _muteBtn.hidden = !micMode;
    if (micMode) {
        BOOL muted = (st.audioMuted != 0);
        [_muteBtn setTitle:(muted ? @"MIC MUTED" : @"MIC LIVE")
                  forState:UIControlStateNormal];
        _muteBtn.backgroundColor = muted
            ? [UIColor systemRedColor]
            : [[UIColor systemGreenColor] colorWithAlphaComponent:0.85];
        _muteBtn.alpha = st.enabled ? 1.0 : 0.35;
    }

    // Resize the floating window to match whether the mute row is present.
    UIWindow *win = self.view.window;
    if (win) {
        CGFloat wantH = micMode ? 118 : 88;
        if (fabs(win.frame.size.height - wantH) > 0.5) {
            CGRect f = win.frame;
            f.size.height = wantH;
            win.frame = f;
        }
    }
}

- (void)toggleTapped {
    VCamConfig *cfg = [VCamConfig shared];
    [cfg reload];
    BOOL next = !cfg.enabled;
    cfg.paused  = NO;
    cfg.enabled = next;        // commits the plist and republishes shared state
    [self refresh];
    [self haptic:UIImpactFeedbackStyleMedium];
}

- (void)pauseTapped {
    VCamConfig *cfg = [VCamConfig shared];
    [cfg reload];
    if (!cfg.enabled) return;
    cfg.paused = !cfg.paused;
    [self refresh];
    [self haptic:UIImpactFeedbackStyleLight];
}

- (void)mirrorTapped {
    VCamConfig *cfg = [VCamConfig shared];
    [cfg reload];
    cfg.mirrorH = !cfg.mirrorH;
    [self refresh];
    [self haptic:UIImpactFeedbackStyleLight];
}

- (void)muteTapped {
    VCamConfig *cfg = [VCamConfig shared];
    [cfg reload];
    if (cfg.audioMode != VCamAudioMicrophone) return;   // mute is mic-only
    cfg.audioMuted = !cfg.audioMuted;
    [self refresh];
    [self haptic:UIImpactFeedbackStyleMedium];
}

- (void)haptic:(UIImpactFeedbackStyle)style {
    UIImpactFeedbackGenerator *g =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g impactOccurred];
}

// Long-press hides the HUD until the app turns it back on.
- (void)handleHold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    VCamConfig *cfg = [VCamConfig shared];
    cfg.hudEnabled = NO;
    vcam_update_hud_visibility();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.view.window;
    if (!win) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        _panStartOrigin = win.frame.origin;
        return;
    }

    CGPoint t = [g translationInView:win];
    CGRect f  = win.frame;
    f.origin.x = _panStartOrigin.x + t.x;
    f.origin.y = _panStartOrigin.y + t.y;

    CGRect screen = UIScreen.mainScreen.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, screen.size.width  - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y, screen.size.height - f.size.height));
    win.frame  = f;

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        [ud setDouble:f.origin.x forKey:@"VCamHUDX"];
        [ud setDouble:f.origin.y forKey:@"VCamHUDY"];
    }
}

@end

// -- VCamHUDWindow --------------------------------------------------------
@implementation VCamHUDWindow

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.windowLevel     = UIWindowLevelAlert + 1000;
    self.backgroundColor = UIColor.clearColor;
    self.opaque          = NO;
    self.clipsToBounds   = YES;
    return self;
}

// Touches outside the control cluster fall through to whatever is underneath.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

// -- Window lifecycle -----------------------------------------------------
static UIWindowScene *vcam_active_scene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:UIWindowScene.class]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)s;
            }
        }
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
        }
    }
    return nil;
}

static void vcam_show_hud(void) {
    if (gHUDWindow) {
        vcam_update_hud_visibility();
        return;
    }

    CGRect screen = UIScreen.mainScreen.bounds;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    CGFloat x = [ud objectForKey:@"VCamHUDX"] ? [ud doubleForKey:@"VCamHUDX"]
                                               : screen.size.width - 100;
    CGFloat y = [ud objectForKey:@"VCamHUDY"] ? [ud doubleForKey:@"VCamHUDY"] : 64;

    CGRect frame = CGRectMake(x, y, 88, 88);

    UIWindowScene *scene = vcam_active_scene();
    if (scene) {
        gHUDWindow = [[VCamHUDWindow alloc] initWithWindowScene:scene];
        gHUDWindow.frame = frame;
    } else {
        gHUDWindow = [[VCamHUDWindow alloc] initWithFrame:frame];
    }

    gHUDWindow.rootViewController = [[VCamHUDViewController alloc] init];
    gHUDWindow.hidden = NO;

    VCamLogI("VCamHUD: window created at (%.0f, %.0f)", x, y);
    vcam_update_hud_visibility();
}

static void vcam_update_hud_visibility(void) {
    if (!gHUDWindow) return;
    VCamSharedState st;
    vcam_shm_read(&st);
    BOOL shouldShow = st.hudEnabled && !gSuppressedByUI;
    gHUDWindow.hidden = !shouldShow;
    if (shouldShow) {
        [(VCamHUDViewController *)gHUDWindow.rootViewController refresh];
    }
}

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
        vcam_update_hud_visibility();
    });

    vcam_notify_observe(kVCamNotifyToggleHUD, dispatch_get_main_queue(), ^{
        [[VCamConfig shared] reload];
        if (!gHUDWindow) vcam_show_hud();
        else             vcam_update_hud_visibility();
    });

    // Re-stamp the heartbeat periodically so a probe that loses its
    // notification can still fall back on a fresh timestamp. Stored in a static
    // because under ARC a dispatch source held only in a local is released when
    // the scope ends, which would cancel the timer before it ever fires.
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
    if (st.hudEnabled) vcam_show_hud();

    VCamLogI("VCamHUD: bootstrap complete (hudEnabled=%d)", (int)st.hudEnabled);
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
    gSuppressedByUI = YES;
    vcam_update_hud_visibility();
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    gSuppressedByUI = NO;
    vcam_update_hud_visibility();
}

%end

// ...and off the lock screen.
%hook SBLockScreenManager

- (void)_setUILocked:(BOOL)locked {
    %orig;
    gSuppressedByUI = locked;
    dispatch_async(dispatch_get_main_queue(), ^{ vcam_update_hud_visibility(); });
}

%end
