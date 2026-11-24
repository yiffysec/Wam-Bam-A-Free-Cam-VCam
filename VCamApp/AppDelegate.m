// AppDelegate.m — Minimal app delegate for WamBamVCam companion app
#import "AppDelegate.h"
#import "../Shared/VCamSharedState.h"
#import "../Shared/VCamTypes.h"
#import "../Shared/VCamPaths.h"
#import "VCamMainViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    // Open shared memory — if this fails, everything falls back to plist-only mode
    if (vcam_shm_open() != 0) {
        VCamLogE("AppDelegate: shared memory unavailable — using plist fallback");
    }

    // Ensure the library directory exists, under the jailbreak root and
    // world-accessible so the camera daemon (a different user) can reach it too.
    NSString *dir = VCamLibraryDir();
    [[NSFileManager defaultManager]
        createDirectoryAtPath:dir
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions: @(0777) }
                        error:nil];
    [[NSFileManager defaultManager]
        setAttributes:@{ NSFilePosixPermissions: @(0777) }
         ofItemAtPath:dir error:nil];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController =
        [[UINavigationController alloc]
            initWithRootViewController:[[VCamMainViewController alloc] init]];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    [self.window makeKeyAndVisible];

    return YES;
}

@end
