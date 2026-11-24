// VCamBootGuard.m — Crash watchdog + kill-switch for boot-loop prevention
#import "VCamBootGuard.h"
#import "VCamTypes.h"
#import <Foundation/Foundation.h>

static NSString *const kLoadingStampPath =
    @kVCamLibraryDir "/loading.stamp";
static NSString *const kCrashCounterPath =
    @kVCamLibraryDir "/crash_counter";
static NSString *const kKillSwitchPath   =
    @kVCamLibraryDir "/killswitch";

static const NSTimeInterval kCrashWindowSec     = 30.0;
static const NSInteger      kMaxCrashesBeforeKS = 3;

// ── vcam_bootguard_is_killed ──────────────────────────────────────────────
BOOL vcam_bootguard_is_killed(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:kKillSwitchPath];
}

// ── vcam_bootguard_set_killed ─────────────────────────────────────────────
void vcam_bootguard_set_killed(void) {
    [[NSFileManager defaultManager]
        createFileAtPath:kKillSwitchPath
                contents:[NSData data]
              attributes:nil];
    VCamLogE("BootGuard: kill-switch SET — injection disabled until cleared from companion app");
}

// ── vcam_bootguard_clear_killed ───────────────────────────────────────────
void vcam_bootguard_clear_killed(void) {
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtPath:kKillSwitchPath error:&err];
    if (!err) {
        VCamLogI("BootGuard: kill-switch CLEARED");
    }
    // Also reset crash counter
    [[NSFileManager defaultManager] removeItemAtPath:kCrashCounterPath error:nil];
}

// ── vcam_bootguard_check ──────────────────────────────────────────────────
BOOL vcam_bootguard_check(void) {
    // Ensure library directory exists
    [[NSFileManager defaultManager]
        createDirectoryAtPath:@kVCamLibraryDir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    // 1. Hard kill-switch check
    if (vcam_bootguard_is_killed()) {
        VCamLogE("BootGuard: kill-switch active — aborting injection");
        return NO;
    }

    // 2. Check if previous run left a loading.stamp (= it crashed)
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kLoadingStampPath]) {
        // Read timestamp
        NSDictionary *attrs = [fm attributesOfItemAtPath:kLoadingStampPath error:nil];
        NSDate *stampDate = attrs[NSFileModificationDate];
        NSTimeInterval age = -[stampDate timeIntervalSinceNow];

        if (age < kCrashWindowSec) {
            // Crashed quickly — increment counter
            NSInteger count = 0;
            NSString *counterStr = [NSString stringWithContentsOfFile:kCrashCounterPath
                                                             encoding:NSUTF8StringEncoding
                                                                error:nil];
            if (counterStr) count = [counterStr integerValue];
            count++;
            VCamLogE("BootGuard: crash within window detected (count=%ld / max=%ld)",
                     (long)count, (long)kMaxCrashesBeforeKS);

            if (count >= kMaxCrashesBeforeKS) {
                vcam_bootguard_set_killed();
                [fm removeItemAtPath:kLoadingStampPath error:nil];
                [fm removeItemAtPath:kCrashCounterPath error:nil];
                return NO;
            }

            [@(count).stringValue writeToFile:kCrashCounterPath
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
        } else {
            // Old stamp — not a crash loop, reset counter
            [fm removeItemAtPath:kCrashCounterPath error:nil];
        }

        [fm removeItemAtPath:kLoadingStampPath error:nil];
    }

    // 3. Write loading stamp — will be removed by vcam_bootguard_reset()
    //    If the process crashes before reset() is called, the stamp remains.
    [@"1" writeToFile:kLoadingStampPath
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];

    // 4. Schedule a watchdog: if we haven't called reset() within 60s, something
    //    went wrong but didn't crash (hung). Clean up the stamp regardless.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [[NSFileManager defaultManager] removeItemAtPath:kLoadingStampPath error:nil];
    });

    return YES;
}

// ── vcam_bootguard_reset ──────────────────────────────────────────────────
void vcam_bootguard_reset(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:kLoadingStampPath error:nil];
    [fm removeItemAtPath:kCrashCounterPath error:nil];
    VCamLogI("BootGuard: injection successful — crash counter reset");
}
