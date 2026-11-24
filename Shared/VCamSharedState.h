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
#include <stddef.h>
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

// -- Shared-memory header identity ----------------------------------------
// vcam.shm is a file, so it survives process restarts AND package upgrades. If
// the layout below ever changes without this magic/version changing with it, a
// stale file from the previous version is reinterpreted field by field --
// including `enabled`, which is how you get a virtual camera that switches
// itself on after an update. vcam_shm_open() validates these and reinitialises
// the region from scratch on any mismatch.
//
// BUMP kVCamShmVersion ON EVERY CHANGE TO VCamSharedState OR VCamDiagnostics.
#define kVCamShmMagic   ((uint32_t)0x57424643u)   // 'WBFC'
#define kVCamShmVersion ((uint16_t)3u)

// -- Shared hot-path state (one cache line, seqlock-protected) ------------
// Writer bumps seq to odd before writing and to even after. Readers loop
// until they observe a stable, even sequence number.
//
// The header triple (magic, version, size) sits outside the seqlock-protected
// body on purpose: it is written once at initialisation and never again, so a
// reader can validate it without taking the seqlock.
typedef struct __attribute__((aligned(64))) {
    uint32_t          magic;            // -   : kVCamShmMagic
    uint16_t          version;          // -   : kVCamShmVersion
    uint16_t          structSize;       // -   : sizeof(VCamSharedState)
    _Atomic uint32_t  seq;              // 0  : seqlock counter (even = stable)
    uint8_t           enabled;          // 12 : 1 = vcam active
    uint8_t           paused;           // 13 : 1 = show real camera (pass-through)
    VCamSourceType    sourceType;       // 14
    VCamFitMode       fitMode;          // 15
    VCamRotation      rotation;         // 16 : degrees
    float             zoom;             // 20 : 1.0 = no zoom
    float             panX;             // 24 : -1.0 ... 1.0
    float             panY;             // 28
    uint8_t           mirrorH;          // 32 : horizontal mirror
    uint8_t           mirrorV;          // 33
    uint8_t           hudEnabled;       // 34 : user wants the SpringBoard HUD
    uint8_t           useRealAudio;     // 35 : 1 = pass-through mic
    uint8_t           perAppEnabled;    // 36 : 1 = allow-list mode
    uint8_t           _pad0[3];         // 37 : align the double
    double            hudHeartbeat;     // 40 : CFAbsoluteTime of last HUD pong
    uint8_t           hudAlive;         // 48 : 1 = SpringBoard tweak answered
    uint8_t           clientAllowed;    // 49 : per-app verdict from VCamClient
    uint8_t           _pad1[14];        // 50 : pad to 64
} VCamSharedState;

_Static_assert(sizeof(VCamSharedState) == 64,
               "VCamSharedState must be exactly one cache line");
_Static_assert(offsetof(VCamSharedState, enabled) == 12,
               "the seqlock body must start immediately after seq");

// -- Hook identity bits ---------------------------------------------------
// Which hooks were attempted, and which actually installed. Published so the
// companion app can say "4 of 6 installed" instead of the user guessing.
#define kVCamHookEmit         (1u << 0)   // BWNodeOutput emitSampleBuffer:
#define kVCamHookImageQueue   (1u << 1)   // BWImageQueueSinkNode
#define kVCamHookRemoteQueue  (1u << 2)   // BWRemoteQueueSinkNode
#define kVCamHookPhotoEncoder (1u << 3)   // BWPhotoEncoderNode
#define kVCamHookStillImage   (1u << 4)   // BWStillImageSampleBufferSinkNode
#define kVCamHookStillScaler  (1u << 5)   // BWStillImageScalerNode
#define kVCamHookDiscovered   (1u << 6)   // anything found by class discovery

// -- Delivery tiers -------------------------------------------------------
// Each tier is a different way of getting our pixels to the client. The daemon
// starts at tier 0 and escalates when the arbiter observes frames flowing
// without any being replaced. Published so a failure is diagnosable.
typedef enum : uint32_t {
    VCamTierSinkHooks        = 0,  // substitute at the sink nodes (preferred)
    VCamTierEmitReplacement  = 1,  // substitute at BWNodeOutput emitSampleBuffer:
    VCamTierDiscoveredHooks  = 2,  // hook every *SinkNode found by discovery
    VCamTierClientSide       = 3,  // give up in-daemon; the app-side library owns it
} VCamTier;

// -- Daemon diagnostics (second cache line) -------------------------------
// Written only by the camera daemon, read by everyone. All fields are atomics
// updated independently -- no seqlock, because counters need no mutual
// consistency and the hot path must not contend on a lock.
typedef struct __attribute__((aligned(64))) {
    _Atomic uint32_t hooksAttempted;   // 0  : bitmask of kVCamHook*
    _Atomic uint32_t hooksInstalled;   // 4  : bitmask of kVCamHook*
    _Atomic uint64_t framesSeen;       // 8  : real frames through emitSampleBuffer:
    _Atomic uint64_t framesReplaced;   // 16 : substitutions actually delivered
    _Atomic uint64_t framesDriven;     // 24 : frames pushed by our own 30Hz timer
    _Atomic uint32_t activeTier;       // 32 : VCamTier
    _Atomic uint32_t variantCount;     // 36 : output shapes currently pooled
    _Atomic uint32_t renders;          // 40 : framing renders performed
    _Atomic uint32_t cacheHits;        // 44 : shape served from cache
    _Atomic uint32_t declinedFormat;   // 48 : last FourCC we could not produce
    _Atomic uint32_t iosVersion;       // 52 : major << 16 | minor
    _Atomic uint32_t lastError;        // 56 : VCamDiagError
    _Atomic uint32_t daemonPid;        // 60 : 0 until the daemon reports in
} VCamDiagnostics;

_Static_assert(sizeof(VCamDiagnostics) == 64,
               "VCamDiagnostics must be exactly one cache line");

/// Error codes published in `lastError`. Deliberately coarse -- enough to point
/// at a subsystem, with the unified log carrying the detail.
typedef enum : uint32_t {
    VCamDiagErrorNone            = 0,
    VCamDiagErrorNoClasses       = 1,  // BW* classes absent entirely
    VCamDiagErrorNoHooks         = 2,  // classes found, nothing installable
    VCamDiagErrorMetalUnavailable = 3,
    VCamDiagErrorSandboxDenied   = 4,  // cannot read our own config
    VCamDiagErrorNoMedia         = 5,
    VCamDiagErrorDecodeFailed    = 6,
    VCamDiagErrorPoolExhausted   = 7,
} VCamDiagError;

// -- The mapped region ----------------------------------------------------
// Two cache lines: mutable configuration, then daemon diagnostics. Separate
// lines so the daemon writing counters never invalidates the line the hot path
// reads configuration from.
typedef struct {
    VCamSharedState state;
    VCamDiagnostics diag;
} VCamSharedRegion;

_Static_assert(sizeof(VCamSharedRegion) == 128, "region must be two cache lines");

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

/// Get the pointer to the mapped diagnostics block. NULL if not mapped.
VCamDiagnostics *vcam_shm_diag_ptr(void);

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
