// VCamTypes.h — Compile-time constants, version detection, common macros
// No ObjC/C++ dependencies — safe to include from C, ObjC, and Metal shaders.

#pragma once
#include <stdint.h>
#include <os/log.h>
#include <os/lock.h>
#include <dispatch/dispatch.h>

// -- Paths ----------------------------------------------------------------
// These live here, in the lowest-level shared header, rather than alongside the
// shared-memory layout. They are referenced as `@kVCamConfigPath` in several
// files, and a translation unit that has the ObjC `@` but not the macro fails
// with "unexpected '@' in program" -- which points at the wrong thing entirely.
// Keeping them in the header everything already includes avoids that trap.
//
// Deliberately outside any jailbreak prefix: /var/mobile/Library is a real path
// under rootful, rootless and roothide alike, so the daemon, the app and the
// HUD all agree on it without any jbroot() translation.
#define kVCamLibraryDir     "/var/mobile/Library/WamBamVCam"
#define kVCamConfigPath     kVCamLibraryDir "/Config.plist"
#define kVCamMediaPath      kVCamLibraryDir "/source"      // + ext (.mov/.jpg/...)
#define kVCamShmPath        kVCamLibraryDir "/vcam.shm"
#define kVCamKillSwitchPath kVCamLibraryDir "/killswitch"

// -- Darwin notification names --------------------------------------------
#define kVCamNotifyConfigChanged  "com.yiffysec.wambamvcam/config-changed"
#define kVCamNotifyMediaChanged   "com.yiffysec.wambamvcam/media-changed"
#define kVCamNotifyToggleHUD      "com.yiffysec.wambamvcam/toggle-hud"
#define kVCamNotifyHUDPing        "com.yiffysec.wambamvcam/hud-ping"
#define kVCamNotifyHUDPong        "com.yiffysec.wambamvcam/hud-pong"
#define kVCamNotifyClientChanged  "com.yiffysec.wambamvcam/client-changed"

// ── OS version helpers ─────────────────────────────────────────────────────
// Use at runtime; these are not compile-time constants.
#ifndef VCAM_IOS_AT_LEAST
#  define VCAM_IOS_AT_LEAST(maj, min) \
     (__builtin_available(iOS maj.min, *))
#endif

// ── Logging ───────────────────────────────────────────────────────────────
#define kVCamSubsystem  "com.yiffysec.wambamvcam"
#define kVCamCategory   "VCam"

static inline os_log_t vcam_log(void) {
    static os_log_t _log;
    static dispatch_once_t _once;
    dispatch_once(&_once, ^{ _log = os_log_create(kVCamSubsystem, kVCamCategory); });
    return _log;
}

#define VCamLog(fmt, ...)   os_log(vcam_log(), "[VCam] " fmt, ##__VA_ARGS__)
#define VCamLogE(fmt, ...)  os_log_error(vcam_log(), "[VCam][ERR] " fmt, ##__VA_ARGS__)
#define VCamLogI(fmt, ...)  os_log_info(vcam_log(), "[VCam][INFO] " fmt, ##__VA_ARGS__)
#ifdef DEBUG
# define VCamLogD(fmt, ...) os_log_debug(vcam_log(), "[VCam][DBG] " fmt, ##__VA_ARGS__)
#else
# define VCamLogD(fmt, ...) do {} while(0)
#endif

// ── Process names ─────────────────────────────────────────────────────────
#define kVCamProcessCameraCaptured  "cameracaptured"   // iOS 18+
#define kVCamProcessMediaServerd    "mediaserverd"     // iOS ≤ 17
#define kVCamProcessSpringBoard     "SpringBoard"
#define kVCamProcessCompanionApp    "WamBamVCam"

// ── Pixel format FourCC values ────────────────────────────────────────────
// 420v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (video sinks)
#define kVCamFmt420v   ((uint32_t)0x34323076u)  // '420v'
// BGRA = kCVPixelFormatType_32BGRA (still / photo sinks)
#define kVCamFmtBGRA   ((uint32_t)0x42475241u)  // 'BGRA'

// ── BWNode FourCC media type ───────────────────────────────────────────────
// CRITICAL: passed as OSType (uint32) NOT as an Objective-C object.
// Hooking initWithInputMediaType: with an id parameter causes retain of an
// integer → crash → boot-loop. Must cast to (uint32_t) or (OSType).
#define kVCamMediaTypeVideo ((uint32_t)0x76696465u)  // 'vide'
#define kVCamMediaTypeAudio ((uint32_t)0x736F756Eu)  // 'soun'

// ── Frame engine constants ────────────────────────────────────────────────
#define kVCamTargetFPS          30
#define kVCamFrameInterval      (1.0 / kVCamTargetFPS)
#define kVCamFramePoolMaxSize   3     // max outstanding CVPixelBuffers; jetsam guard
#define kVCamPollIntervalSec    0.5   // config-plist poll fallback

// ── IOSurface rotation pool ───────────────────────────────────────────────
#define kVCamSurfacePoolSlots   3     // triple-buffering for zero-copy XPC

// ── Preference / config keys ──────────────────────────────────────────────
#define kVCamPrefEnabled        "enabled"
#define kVCamPrefSourcePath     "sourcePath"
#define kVCamPrefSourceType     "sourceType"
#define kVCamPrefFitMode        "fitMode"
#define kVCamPrefRotation       "rotation"
#define kVCamPrefMirrorH        "mirrorH"
#define kVCamPrefMirrorV        "mirrorV"
#define kVCamPrefUseRealAudio   "useRealAudio"
#define kVCamPrefHUDEnabled     "hudEnabled"
#define kVCamPrefPerAppEnabled  "perAppEnabled"
#define kVCamPrefPerAppList     "perAppList"
#define kVCamPrefZoom           "zoom"
#define kVCamPrefPanX           "panX"
#define kVCamPrefPanY           "panY"
#define kVCamPrefPaused         "paused"
#define kVCamPrefAudioPath      "audioPath"
#define kVCamPrefHUDPosition    "hudPosition"    // "topLeft"|"topRight"|"bottomLeft"|"bottomRight"
#define kVCamPrefHUDOpacity     "hudOpacity"     // 0.0…1.0

// ── Default values ────────────────────────────────────────────────────────
#define kVCamDefaultEnabled     0
#define kVCamDefaultFitMode     0    // VCamFitFill
#define kVCamDefaultRotation    0
#define kVCamDefaultMirrorH     0
#define kVCamDefaultZoom        1.0f
#define kVCamDefaultHUDOpacity  0.85f

// ── Misc helpers ──────────────────────────────────────────────────────────
#define VCAM_UNUSED(x) ((void)(x))
#define VCAM_ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
