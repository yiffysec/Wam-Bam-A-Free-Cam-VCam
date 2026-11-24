// VCamRootListController.m -- Settings pane (PreferenceLoader)
//
// A convenience surface only. The companion app is the authoritative UI and can
// do everything this pane can plus media import and per-app selection. This
// pane exists so the common toggles are reachable from Settings without
// leaving whatever the user was doing.

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#import "../Shared/VCamConfig.h"
#import "../Shared/VCamHUDBridge.h"
#import "../Shared/VCamBootGuard.h"
#import "../Shared/VCamTypes.h"

@interface VCamRootListController : PSListController
@end

@implementation VCamRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[VCamConfig shared] load];
}

// -- Preference bridging -------------------------------------------------
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"] ?: specifier.identifier;
    if (!key) return specifier.properties[@"default"];

    id value = [[VCamConfig shared] objectForKey:key];
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"] ?: specifier.identifier;
    if (!key) return;

    VCamConfig *cfg = [VCamConfig shared];
    [cfg setObject:value forKey:key];
    [cfg commit];   // writes the plist, republishes shared state, notifies

    // Media and audio paths need the daemon to reopen its reader.
    if ([key isEqualToString:@kVCamPrefSourcePath] ||
        [key isEqualToString:@kVCamPrefAudioPath]) {
        vcam_notify_post(kVCamNotifyMediaChanged);
    }

    // HUD visibility is a live request, not just a stored flag.
    if ([key isEqualToString:@kVCamPrefHUDEnabled]) {
        [[VCamHUDBridge shared] requestHUDVisible:[value boolValue]];
    }
}

// -- Actions -------------------------------------------------------------
- (void)checkHUD {
    __weak typeof(self) weakSelf = self;
    [[VCamHUDBridge shared] probeWithCompletion:^(VCamHUDAvailability a) {
        NSString *message;
        switch (a) {
            case VCamHUDAvailabilityAvailable:
                message = @"The SpringBoard HUD is installed and responding.";
                break;
            case VCamHUDAvailabilityUnavailable:
                message = @"The HUD is not responding. Everything still works "
                           "from the Wam Bam VCam app, which has the full set of "
                           "controls. Open the app to drive the virtual camera "
                           "from there.";
                break;
            default:
                message = @"Could not determine HUD status.";
                break;
        }
        [weakSelf alert:@"HUD Status" message:message];
    }];
}

- (void)clearKillSwitch {
    if (!vcam_bootguard_is_killed()) {
        [self alert:@"Kill Switch"
            message:@"The kill switch is not currently engaged. Nothing to clear."];
        return;
    }

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Clear Kill Switch"
                         message:@"This re-enables injection into the camera "
                                  "daemon on the next launch. Clear it only once "
                                  "you have changed whatever caused the crashes."
                  preferredStyle:UIAlertControllerStyleAlert];

    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];

    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Clear"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        vcam_bootguard_clear_killed();
        [weakSelf alert:@"Done"
                message:@"Kill switch cleared. Respring or reboot to apply."];
    }]];

    [self presentViewController:a animated:YES completion:nil];
}

- (void)openApp {
    // PreferenceLoader bundles live inside Preferences, which cannot use
    // UIApplication openURL directly, so go through the shared-application
    // workspace the same way other Settings panes do.
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws) {
        id workspace = [ws performSelector:@selector(defaultWorkspace)];
        SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([workspace respondsToSelector:open]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [workspace performSelector:open
                            withObject:@"com.yiffysec.wambamvcam.app"];
            #pragma clang diagnostic pop
            return;
        }
    }
    [self alert:@"Open the App"
        message:@"Launch \"Wam Bam VCam\" from your home screen for media import, "
                 "per-app selection and the full control set."];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:title message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

@end
