// VCamFloatingHUD.m -- see header. One pill, shared by SpringBoard and apps.
#import "VCamFloatingHUD.h"
#import "VCamConfig.h"
#import "VCamTypes.h"
#import <objc/runtime.h>

// =========================================================================
//  Window -- passes touches through everywhere except the control cluster
// =========================================================================
@interface VCamHUDWindow : UIWindow
@end

@implementation VCamHUDWindow

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [self configure];
    return self;
}

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    if (!(self = [super initWithWindowScene:scene])) return nil;
    [self configure];
    return self;
}

- (void)configure {
    self.windowLevel     = UIWindowLevelAlert + 1000;
    self.backgroundColor = UIColor.clearColor;
    self.opaque          = NO;
    self.clipsToBounds    = YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;   // outside the pill -> fall through
}

@end

// =========================================================================
//  View controller -- the controls
// =========================================================================
@interface VCamHUDViewController : UIViewController
- (void)refresh;
@end

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
    _toggleBtn.frame              = CGRectMake(6, 25, 76, 28);
    _toggleBtn.layer.cornerRadius = 7;
    _toggleBtn.titleLabel.font    = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
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

// Long-press hides the pill until it is explicitly turned back on.
- (void)handleHold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    VCamConfig *cfg = [VCamConfig shared];
    cfg.hudEnabled = NO;
    [[VCamFloatingHUD shared] refresh];
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

// =========================================================================
//  Manager
// =========================================================================
@implementation VCamFloatingHUD {
    VCamHUDWindow *_window;
    BOOL           _suppressed;
}

+ (instancetype)shared {
    static VCamFloatingHUD *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (BOOL)isPresented { return _window != nil; }

- (UIWindowScene *)resolveScene:(UIWindowScene *)scene {
    if (scene) return scene;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)s;
            }
        }
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
        }
    }
    return nil;
}

- (void)presentInScene:(UIWindowScene *)scene {
    @try {
        if (_window) { [self refresh]; return; }

        CGRect screen = UIScreen.mainScreen.bounds;
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        CGFloat x = [ud objectForKey:@"VCamHUDX"] ? [ud doubleForKey:@"VCamHUDX"]
                                                   : screen.size.width - 100;
        CGFloat y = [ud objectForKey:@"VCamHUDY"] ? [ud doubleForKey:@"VCamHUDY"] : 64;
        CGRect frame = CGRectMake(x, y, 88, 88);

        UIWindowScene *s = [self resolveScene:scene];
        if (s) {
            _window = [[VCamHUDWindow alloc] initWithWindowScene:s];
            _window.frame = frame;
        } else {
            _window = [[VCamHUDWindow alloc] initWithFrame:frame];
        }
        _window.rootViewController = [[VCamHUDViewController alloc] init];
        _window.hidden = NO;

        VCamLogI("VCamHUD: window created at (%.0f, %.0f)", x, y);
        [self applyVisibility];
    } @catch (NSException *ex) {
        VCamLogE("VCamHUD: present threw %{public}@", ex.reason);
        _window = nil;
    }
}

- (void)dismiss {
    @try {
        _window.hidden = YES;
        _window.rootViewController = nil;
        _window = nil;
    } @catch (NSException *ex) {
        VCAM_UNUSED(ex);
        _window = nil;
    }
}

- (void)refresh {
    if (!_window) return;
    [self applyVisibility];
}

- (void)applyVisibility {
    if (!_window) return;
    VCamSharedState st;
    vcam_shm_read(&st);
    BOOL shouldShow = st.hudEnabled && !_suppressed;
    _window.hidden = !shouldShow;
    if (shouldShow) {
        [(VCamHUDViewController *)_window.rootViewController refresh];
    }
}

- (void)setSuppressed:(BOOL)suppressed {
    _suppressed = suppressed;
    [self applyVisibility];
}

@end
