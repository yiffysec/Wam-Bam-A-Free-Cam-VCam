// VCamPaths.m -- Resolve every shared path through libroot, once
#import "VCamPaths.h"
#import "VCamTypes.h"
#import <rootless.h>   // Theos libroot: JBROOT path conversion for every scheme

// The relative path, as it would read on a rootful device. libroot rewrites it
// to the real jailbreak-root location at runtime (rootless /var/jb/..., roothide
// randomized), and returns it unchanged on rootful.
#define kVCamRelDir "/var/mobile/Library/WamBamVCam"

NSString *VCamLibraryDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *resolved = ROOT_PATH_NS(@kVCamRelDir);
        // libroot returns nil only if conversion fails outright; fall back to
        // the literal so the app still functions rather than crashing on nil.
        dir = resolved.length ? resolved : @kVCamRelDir;
        VCamLogI("paths: library dir resolved to %{public}@", dir);
    });
    return dir;
}

NSString *VCamConfigPath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"Config.plist"];
}
NSString *VCamShmPath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"vcam.shm"];
}
NSString *VCamKillSwitchPath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"killswitch"];
}
NSString *VCamCrashCounterPath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"crash_counter"];
}
NSString *VCamLoadingStampPath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"loading.stamp"];
}
NSString *VCamBreadcrumbPath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"daemon.breadcrumb"];
}
NSString *VCamMediaBasePath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"source"];
}
NSString *VCamAudioBasePath(void) {
    return [VCamLibraryDir() stringByAppendingPathComponent:@"audio"];
}

// -- C accessors ----------------------------------------------------------
// Never returns NULL (the accessors are _Nonnull): on the vanishingly unlikely
// strdup failure, hand back the relative literal so callers still get a usable,
// if unresolved, path rather than a crash.
static const char *vcam_cache(NSString *s) {
    const char *dup = strdup(s.fileSystemRepresentation);
    return dup ? dup : kVCamRelDir;
}

const char *vcam_library_dir(void) {
    static const char *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = vcam_cache(VCamLibraryDir()); });
    return c;
}
const char *vcam_config_path(void) {
    static const char *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = vcam_cache(VCamConfigPath()); });
    return c;
}
const char *vcam_shm_path(void) {
    static const char *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = vcam_cache(VCamShmPath()); });
    return c;
}
const char *vcam_breadcrumb_path(void) {
    static const char *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = vcam_cache(VCamBreadcrumbPath()); });
    return c;
}
