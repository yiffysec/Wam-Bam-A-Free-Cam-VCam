// AppDelegate.m — Minimal app delegate for WamBamVCam companion app
#import "AppDelegate.h"
#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamTypes.h"
#import "VCamMainViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    // Open shared memory — if this fails, everything falls back to plist-only mode
    if (vcam_shm_open() != 0) {
        VCamLogE("AppDelegate: shared memory unavailable — using plist fallback");
    }

    // Ensure the library directory exists
    [[NSFileManager defaultManager]
        createDirectoryAtPath:@kVCamLibraryDir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController =
        [[UINavigationController alloc]
            initWithRootViewController:[[VCamMainViewController alloc] init]];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    [self.window makeKeyAndVisible];

    return YES;
}

@end
