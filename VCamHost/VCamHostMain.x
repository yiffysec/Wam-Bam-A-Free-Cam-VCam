// VCamHostMain.x -- Dylib entry point for the camera daemon
//
// Injected into:
//   iOS 18 .. 26+  cameracaptured   (Apple moved the capture graph out of
//                                    mediaserverd into this dedicated daemon)
//   iOS 15 .. 17   mediaserverd
//
// Everything here is ordered so that a failure at any step leaves the device
// bootable and the camera working:
//
//   1. bail out unless we are actually in a camera daemon
//   2. consult the boot guard (kill switch + crash counter) BEFORE anything else
//   3. detect the OS version
//   4. open shared memory; give up quietly if unavailable
//   5. bring up Metal and the media source
//   6. install hooks, each independently verified and individually skippable
//   7. subscribe to configuration changes
//   8. start the frame pump
//   9. tell the boot guard we made it, which clears the crash counter
//
// If cameracaptured crashes three times inside the guard's window, step 2 sets
// the kill switch and injection stops happening at all. The user clears it from
// the companion app or from Settings -- no SSH, no restore.

#import <Foundation/Foundation.h>
#import <substrate.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>

#import "VCamTypes.h"
#import "VCamSharedState.h"
#import "VCamDiagnostics.h"
#import "VCamBootGuard.h"
#import "VCamFrameEngine.h"
#import "VCamMediaSource.h"
#import "VCamPixelConverter.h"

// Implemented in VCamHooks.x
void vcam_install_hooks_ios18(void);
void vcam_install_hooks_ios17(void);

// -- libSandy -------------------------------------------------------------
// cameracaptured and mediaserverd run in their own sandboxes, which deny reads
// of /var/mobile/Library by default. libSandy consumes the profile we ship at
// /Library/libSandy/WamBamVCam.plist and hands the daemon a sandbox extension
// for exactly that directory.
//
// Resolved with dlopen/dlsym rather than linked. Linking it -- even weakly --
// makes libsandy.dylib a load-time dependency of this dylib, and a load failure
// inside the camera daemon means a broken camera. dlopen cannot fail that way:
// the worst case is a log line and an unextended sandbox.
//
// Several paths are tried because the library lives in a different place under
// each jailbreak scheme. The usual presentation of a missing extension is "the
// tweak does nothing", with config and media reads failing silently, so this is
// worth being loud about.
#define kVCamSandyProfile "WamBamVCam"
#define kVCamSandySuccess 0

typedef int (*VCamSandyFn)(const char *);

static void vcam_apply_sandbox_extensions(void) {
    static const char *candidates[] = {
        "libsandy.dylib",                            // already loaded, or on the path
        "/usr/lib/libsandy.dylib",                   // rootful, and roothide via jbroot
        "/var/jb/usr/lib/libsandy.dylib",            // rootless
        "/usr/lib/libSandy.dylib",
        "/var/jb/usr/lib/libSandy.dylib",
    };

    void *handle = NULL;
    for (size_t i = 0; i < VCAM_ARRAY_SIZE(candidates); i++) {
        handle = dlopen(candidates[i], RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) handle = dlopen(candidates[i], RTLD_LAZY);
        if (handle) break;
    }

    if (!handle) {
        VCamLogE("sandbox: libSandy not found. If the daemon cannot read "
                 "%{public}s, install com.opa334.libsandy.", kVCamConfigPath);
        return;
    }

    VCamSandyFn apply =
        (VCamSandyFn)dlsym(handle, "libSandy_applySandboxExtensions");
    if (!apply) {
        VCamLogE("sandbox: libSandy loaded but the entry point is missing");
        return;
    }

    int rc = apply(kVCamSandyProfile);
    if (rc == kVCamSandySuccess) {
        VCamLogI("sandbox: libSandy profile '%{public}s' applied",
                 kVCamSandyProfile);
    } else {
        VCamLogE("sandbox: libSandy profile '%{public}s' failed rc=%d -- config "
                 "and media reads may be denied", kVCamSandyProfile, rc);
    }
}

/// Confirms the daemon can actually read the config. Cheap, and turns an
/// invisible sandbox denial into one explicit log line.
static void vcam_verify_config_readable(void) {
    if (access(kVCamConfigPath, R_OK) == 0) {
        VCamLogI("sandbox: %{public}s is readable", kVCamConfigPath);
        return;
    }
    VCamLogE("sandbox: cannot read %{public}s (errno=%d). The virtual camera "
             "will stay idle until this is resolved.", kVCamConfigPath, errno);
    vcam_diag_set_last_error(VCamDiagErrorSandboxDenied);
}

// -- Version state --------------------------------------------------------
static int g_iosMajor = 0;
static int g_iosMinor = 0;

// Lives for the life of the process; see the comment at its assignment.
static dispatch_source_t g_configPoll = nil;

int vcam_ios_major(void) { return g_iosMajor; }
int vcam_ios_minor(void) { return g_iosMinor; }

// -- Process identity -----------------------------------------------------
static BOOL vcam_process_named(const char *name) {
    const char *p = getprogname();
    return p && name && strcmp(p, name) == 0;
}

static BOOL vcam_in_camera_daemon(void) {
    return vcam_process_named(kVCamProcessCameraCaptured) ||
           vcam_process_named(kVCamProcessMediaServerd);
}

// -- Constructor ----------------------------------------------------------
__attribute__((constructor))
static void VCamHostInit(void) {
    @autoreleasepool {
        // 1 -- Wrong process? Do nothing at all. The injection filter should
        //      already guarantee this, but a stale filter plist must not turn
        //      into an unexpected dylib in some other daemon.
        if (!vcam_in_camera_daemon()) return;

        const char *pname = getprogname() ?: "?";

        // 2 -- Boot guard first. Nothing above this line may allocate or hook.
        if (!vcam_bootguard_check()) {
            VCamLogE("init: boot guard refused injection in %{public}s", pname);
            return;
        }

        // 3 -- OS version.
        NSOperatingSystemVersion v =
            NSProcessInfo.processInfo.operatingSystemVersion;
        g_iosMajor = (int)v.majorVersion;
        g_iosMinor = (int)v.minorVersion;

        VCamLogI("init: %{public}s on iOS %d.%d", pname, g_iosMajor, g_iosMinor);

        // On iOS 18+ the capture graph lives only in cameracaptured. If the
        // filter also pulled us into mediaserverd there, stand down -- hooking
        // a graph that is not there wastes memory and risks surprises.
        if (g_iosMajor >= 18 && !vcam_process_named(kVCamProcessCameraCaptured)) {
            VCamLogI("init: iOS 18+, so %{public}s is not the capture host -- "
                     "standing down", pname);
            vcam_bootguard_reset();
            return;
        }
        if (g_iosMajor < 18 && !vcam_process_named(kVCamProcessMediaServerd)) {
            VCamLogI("init: iOS %d, so %{public}s is not the capture host -- "
                     "standing down", g_iosMajor, pname);
            vcam_bootguard_reset();
            return;
        }

        // 4a -- Sandbox extensions, before any read of our own directory.
        vcam_apply_sandbox_extensions();

        // 4b -- Shared memory. Without it there is no way to read the user's
        //       intent on the hot path, so stop rather than hook blindly.
        //       Opened before the readability check so the check can publish
        //       its result into diagnostics.
        if (vcam_shm_open() != 0) {
            VCamLogE("init: shared memory unavailable -- not hooking");
            vcam_bootguard_reset();
            return;
        }

        vcam_diag_set_daemon_pid((uint32_t)getpid());
        vcam_diag_set_ios_version((uint32_t)g_iosMajor, (uint32_t)g_iosMinor);
        vcam_diag_reset_counters();

        vcam_verify_config_readable();

        // 5 -- Subsystems.
        @try {
            [VCamPixelConverter.sharedConverter setup];
            [VCamMediaSource.sharedSource setup];
        } @catch (NSException *ex) {
            VCamLogE("init: subsystem setup threw %{public}@ -- not hooking",
                     ex.reason);
            vcam_diag_set_last_error(VCamDiagErrorMetalUnavailable);
            vcam_bootguard_reset();
            return;
        }

        // 6 -- Hooks.
        @try {
            if (g_iosMajor >= 18) vcam_install_hooks_ios18();
            else                  vcam_install_hooks_ios17();
        } @catch (NSException *ex) {
            VCamLogE("init: hook installation threw %{public}@", ex.reason);
            // Deliberately not setting the kill switch here: one exception is
            // not a boot loop, and the crash counter already covers the case
            // where this process really does keep dying.
            vcam_bootguard_reset();
            return;
        }

        // 7 -- Configuration plumbing.
        dispatch_queue_t cfgQueue =
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

        vcam_notify_observe(kVCamNotifyConfigChanged, cfgQueue, ^{
            [VCamMediaSource.sharedSource reloadConfig];
            [VCamFrameEngine.sharedEngine applyConfig];
        });

        vcam_notify_observe(kVCamNotifyMediaChanged, cfgQueue, ^{
            [VCamMediaSource.sharedSource reloadMedia];
            [VCamFrameEngine.sharedEngine
                restartWithSource:VCamMediaSource.sharedSource];
        });

        // Safety net for a dropped notification: a slow poll of the plist.
        // Held in a static because under ARC a dispatch source stored only in a
        // local would be released the moment this scope ends, cancelling the
        // timer before it ever fires.
        g_configPoll =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cfgQueue);
        dispatch_source_set_timer(g_configPoll, dispatch_time(DISPATCH_TIME_NOW, 0),
                                   (uint64_t)(kVCamPollIntervalSec * NSEC_PER_SEC),
                                   (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(g_configPoll, ^{
            [VCamFrameEngine.sharedEngine applyConfig];
        });
        dispatch_resume(g_configPoll);

        // 8 -- Start pumping.
        [VCamFrameEngine.sharedEngine start];

        // 9 -- Survived startup; clear the crash counter.
        vcam_bootguard_reset();

        VCamLogI("init: injection live in %{public}s", pname);
    }
}
