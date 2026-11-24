// VCamPaths.h -- The one place shared paths are resolved
//
// WHY THIS EXISTS (the iOS 26 / Dopamine 3 field bug):
//
// The daemon, SpringBoard and the app must all agree on one real filesystem
// path for the shared-memory file, the config and the media -- and that path
// has to be reachable from inside cameracaptured's sandbox.
//
// The first version hardcoded "/var/mobile/Library/WamBamVCam". That is the
// REAL path, outside the jailbreak tree. SpringBoard (broad sandbox) and the
// companion app (no-sandbox entitlement) can reach it, which is why the HUD and
// the app's own settings worked -- but cameracaptured has a tight media sandbox
// that denies it, so the daemon could never open the shared memory. And because
// the diagnostics live inside that shared memory, the daemon could not even
// report the failure: every field read back as "nothing", indistinguishable
// from "not injected".
//
// The fix is what the proven tweaks do: put the shared files UNDER the
// jailbreak root (rootless /var/jb/..., roothide's randomized jbroot), which the
// jailbreak's sandbox patches grant injected processes access to. libroot's
// JBROOT conversion resolves that real location at runtime, identically in every
// component and on every scheme (rootful returns the path unchanged), so all
// three converge on the same file.
//
// This header is included from C (VCamSharedState.c) as well as Objective-C, so
// the C accessors are always visible and the Objective-C surface is guarded.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// -- C accessors (cached UTF-8, process lifetime) -------------------------
// Safe to call from C and from the hot path. Resolved once through libroot.
// Marked _Nonnull: each falls back to a literal rather than ever returning NULL,
// so callers never have to null-check. (_Nonnull is a clang keyword; this code
// is only ever built with clang.)
const char *_Nonnull vcam_library_dir(void);
const char *_Nonnull vcam_config_path(void);
const char *_Nonnull vcam_shm_path(void);
const char *_Nonnull vcam_breadcrumb_path(void);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The tweak's directory, resolved under the jailbreak root. Created on demand
/// by the callers that write into it.
NSString *VCamLibraryDir(void);

/// Durable configuration plist.
NSString *VCamConfigPath(void);

/// Seqlock shared-memory file (also carries the daemon diagnostics block).
NSString *VCamShmPath(void);

/// Boot-loop kill switch flag file.
NSString *VCamKillSwitchPath(void);

/// Crash counter and loading stamp used by the boot guard.
NSString *VCamCrashCounterPath(void);
NSString *VCamLoadingStampPath(void);

/// Daemon breadcrumb: written early in the daemon's startup, before shared
/// memory, so the app can tell "daemon ran but could not open shm" apart from
/// "daemon never loaded". A plain plist the no-sandbox app can always read.
NSString *VCamBreadcrumbPath(void);

/// Media and audio bases. Append the real extension before use.
NSString *VCamMediaBasePath(void);   // .../source
NSString *VCamAudioBasePath(void);   // .../audio

NS_ASSUME_NONNULL_END
#endif /* __OBJC__ */
