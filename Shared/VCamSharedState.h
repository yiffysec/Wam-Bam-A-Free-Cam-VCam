// VCamSharedState.h — Zero-copy seqlock-protected shared state
// Shared between: VCamHost (cameracaptured/mediaserverd)
//                 VCamSpringBoard (SpringBoard HUD)
//                 VCamApp (companion app)
//                 VCamPrefs (PreferenceLoader bundle)
//
// IPC model:
//   hot path  -> mmap'd VCamSharedState (seqlock, ~0ms latency)
//   durable   -> Config.plist at kVCamConfigPath
//   wakeup    -> Darwin notify "com.yiffysec.wambamvcam/config-changed"
//   fallback  -> 0.5s poll of plist (if daemon missed the notification)
//
// HUD liveness:
//   The companion app posts kVCamNotifyHUDPing. If the SpringBoard tweak is
//   loaded it stamps hudHeartbeat + hudAlive and posts kVCamNotifyHUDPong.
//   No pong within the probe window => HUD unavailable => the app drives
//   everything itself and surfaces a manual override toggle.

#pragma once
#include <stdint.h>
#include <stdatomic.h>
#include <dispatch/dispatch.h>

// -- Paths (resolve through jbroot() on roothide) --------------------------
#define kVCamLibraryDir     "/var/mobile/Library/WamBamVCam"
#define kVCamConfigPath     kVCamLibraryDir "/Config.plist"
#define kVCamMediaPath      kVCamLibraryDir "/source"      // + ext (.mov/.jpg/.png)
#define kVCamShmPath        kVCamLibraryDir "/vcam.shm"
#define kVCamKillSwitchPath kVCamLibraryDir "/killswitch"  // exists = disable injection

// -- Darwin notification names --------------------------------------------
#define kVCamNotifyConfigChanged  "com.yiffysec.wambamvcam/config-changed"
#define kVCamNotifyMediaChanged   "com.yiffysec.wambamvcam/media-changed"
#define kVCamNotifyToggleHUD      "com.yiffysec.wambamvcam/toggle-hud"
#define kVCamNotifyHUDPing        "com.yiffysec.wambamvcam/hud-ping"
#define kVCamNotifyHUDPong        "com.yiffysec.wambamvcam/hud-pong"
#define kVCamNotifyClientChanged  "com.yiffysec.wambamvcam/client-changed"

// -- Rotation constants ----------------------------------------------------
typedef enum : int32_t {
    VCamRotation0   = 0,
    VCamRotation90  = 90,
    VCamRotation180 = 180,
    VCamRotation270 = 270,
} VCamRotation;

// -- Media source type ----------------------------------------------------
typedef enum : uint8_t {
    VCamSourceNone      = 0,
    VCamSourceVideo     = 1,
    VCamSourcePhoto     = 2,
} VCamSourceType;

// -- Fit mode -------------------------------------------------------------
typedef enum : uint8_t {
    VCamFitFill     = 0,   // aspect-fill (no real pixels exposed)
    VCamFitFit      = 1,   // aspect-fit  (letterbox/pillarbox in black)
    VCamFitStretch  = 2,   // stretch to fill (ignores aspect ratio)
} VCamFitMode;

// -- Shared hot-path state (one cache line, seqlock-protected) ------------
// Writer bumps seq to odd before writing and to even after. Readers loop
// until they observe a stable, even sequence number.
typedef struct __attribute__((aligned(64))) {
    _Atomic uint32_t  seq;              // 0  : seqlock counter (even = stable)
    uint8_t           enabled;          // 4  : 1 = vcam active
    uint8_t           paused;           // 5  : 1 = show real camera (pass-through)
    VCamSourceType    sourceType;       // 6
    VCamFitMode       fitMode;          // 7
    VCamRotation      rotation;         // 8  : degrees
    float             zoom;             // 12 : 1.0 = no zoom
    float             panX;             // 16 : -1.0 ... 1.0
    float             panY;             // 20
    uint8_t           mirrorH;          // 24 : horizontal mirror
    uint8_t           mirrorV;          // 25
    uint8_t           hudEnabled;       // 26 : user wants the SpringBoard HUD
    uint8_t           useRealAudio;     // 27 : 1 = pass-through mic
    uint8_t           perAppEnabled;    // 28 : 1 = allow-list mode
    uint8_t           _pad0[3];         // 29 : align the double
    double            hudHeartbeat;     // 32 : CFAbsoluteTime of last HUD pong
    uint8_t           hudAlive;         // 40 : 1 = SpringBoard tweak answered
    uint8_t           clientAllowed;    // 41 : per-app verdict from VCamClient
    uint8_t           _pad1[22];        // 42 : pad to 64
} VCamSharedState;

_Static_assert(sizeof(VCamSharedState) == 64,
               "VCamSharedState must be exactly one cache line");

// -- C API ----------------------------------------------------------------
#ifdef __cplusplus
extern "C" {
#endif

/// Open/create the shared memory region. Returns 0 on success, -1 on error.
int  vcam_shm_open(void);

/// Close and unmap. Safe to call even if vcam_shm_open() was never called.
void vcam_shm_close(void);

/// Get the pointer to the mapped state. Returns NULL if not mapped.
VCamSharedState *vcam_shm_ptr(void);

/// Seqlock read -- copies stable state into *out. Never blocks.
void vcam_shm_read(VCamSharedState *out);

/// Seqlock write -- publishes *in and posts the config-changed notification.
void vcam_shm_write(const VCamSharedState *in);

/// Seqlock write without posting any notification (used for HUD heartbeats).
void vcam_shm_write_quiet(const VCamSharedState *in);

/// Post a Darwin notification by name.
void vcam_notify_post(const char *name);

/// Register a dispatch-based observer. Returns the notify token (or -1).
int  vcam_notify_observe(const char *name, dispatch_queue_t queue,
                         void (^block)(void));

/// Cancel an observer previously returned by vcam_notify_observe().
void vcam_notify_cancel(int token);

#ifdef __cplusplus
}
#endif
