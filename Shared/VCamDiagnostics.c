// VCamDiagnostics.c -- What the daemon publishes about itself
#include "VCamDiagnostics.h"
#include "VCamTypes.h"
#include <string.h>

// Every accessor tolerates an unmapped region. Diagnostics must never be the
// reason something fails -- if the shared region is unavailable the tweak still
// works, it just cannot explain itself.
#define VCAM_DIAG_OR_RETURN(d)                       \
    VCamDiagnostics *d = vcam_shm_diag_ptr();        \
    if (!d) return

#define VCAM_BUMP(field, amount)                                     \
    do {                                                             \
        VCAM_DIAG_OR_RETURN(_d);                                     \
        atomic_fetch_add_explicit(&_d->field, (amount),              \
                                  memory_order_relaxed);             \
    } while (0)

#define VCAM_SET(field, value)                                       \
    do {                                                             \
        VCAM_DIAG_OR_RETURN(_d);                                     \
        atomic_store_explicit(&_d->field, (value),                   \
                              memory_order_relaxed);                 \
    } while (0)

// -- Hot-path counters ----------------------------------------------------
void vcam_diag_note_frame_seen(void)    { VCAM_BUMP(framesSeen, 1);     }
void vcam_diag_note_replacement(void)   { VCAM_BUMP(framesReplaced, 1); }
void vcam_diag_note_driven_frame(void)  { VCAM_BUMP(framesDriven, 1);   }
void vcam_diag_note_render(void)        { VCAM_BUMP(renders, 1);        }
void vcam_diag_note_cache_hit(void)     { VCAM_BUMP(cacheHits, 1);      }

void vcam_diag_note_declined_format(uint32_t fourCC) {
    VCAM_SET(declinedFormat, fourCC);
}

// -- State ----------------------------------------------------------------
void vcam_diag_set_hooks(uint32_t attempted, uint32_t installed) {
    VCamDiagnostics *d = vcam_shm_diag_ptr();
    if (!d) return;
    atomic_store_explicit(&d->hooksAttempted, attempted, memory_order_relaxed);
    atomic_store_explicit(&d->hooksInstalled, installed, memory_order_relaxed);
}

void vcam_diag_add_installed_hook(uint32_t bit) {
    VCamDiagnostics *d = vcam_shm_diag_ptr();
    if (!d) return;
    atomic_fetch_or_explicit(&d->hooksInstalled, bit, memory_order_relaxed);
}

void vcam_diag_set_active_tier(uint32_t tier)    { VCAM_SET(activeTier, tier);    }
void vcam_diag_set_variant_count(uint32_t count) { VCAM_SET(variantCount, count); }
void vcam_diag_set_last_error(uint32_t code)     { VCAM_SET(lastError, code);     }
void vcam_diag_set_daemon_pid(uint32_t pid)      { VCAM_SET(daemonPid, pid);      }

void vcam_diag_set_ios_version(uint32_t major, uint32_t minor) {
    VCAM_SET(iosVersion, (major << 16) | (minor & 0xFFFFu));
}

// -- Reading --------------------------------------------------------------
void vcam_diag_read(VCamDiagnostics *out) {
    if (!out) return;

    VCamDiagnostics *d = vcam_shm_diag_ptr();
    if (!d) { memset(out, 0, sizeof(*out)); return; }

#define VCAM_LOAD(field) \
    atomic_store_explicit(&out->field, \
        atomic_load_explicit(&d->field, memory_order_relaxed), \
        memory_order_relaxed)

    VCAM_LOAD(hooksAttempted);
    VCAM_LOAD(hooksInstalled);
    VCAM_LOAD(framesSeen);
    VCAM_LOAD(framesReplaced);
    VCAM_LOAD(framesDriven);
    VCAM_LOAD(activeTier);
    VCAM_LOAD(variantCount);
    VCAM_LOAD(renders);
    VCAM_LOAD(cacheHits);
    VCAM_LOAD(declinedFormat);
    VCAM_LOAD(iosVersion);
    VCAM_LOAD(lastError);
    VCAM_LOAD(daemonPid);

#undef VCAM_LOAD
}

void vcam_diag_reset_counters(void) {
    VCamDiagnostics *d = vcam_shm_diag_ptr();
    if (!d) return;
    atomic_store_explicit(&d->framesSeen,     0, memory_order_relaxed);
    atomic_store_explicit(&d->framesReplaced, 0, memory_order_relaxed);
    atomic_store_explicit(&d->framesDriven,   0, memory_order_relaxed);
    atomic_store_explicit(&d->renders,        0, memory_order_relaxed);
    atomic_store_explicit(&d->cacheHits,      0, memory_order_relaxed);
}

// -- Names ----------------------------------------------------------------
const char *vcam_diag_tier_name(uint32_t tier) {
    switch ((VCamTier)tier) {
        case VCamTierSinkHooks:       return "sink hooks";
        case VCamTierEmitReplacement: return "emit replacement";
        case VCamTierDiscoveredHooks: return "discovered hooks";
        case VCamTierClientSide:      return "client side";
        default:                      return "unknown";
    }
}

const char *vcam_diag_error_name(uint32_t code) {
    switch ((VCamDiagError)code) {
        case VCamDiagErrorNone:             return "none";
        case VCamDiagErrorNoClasses:        return "capture classes not found";
        case VCamDiagErrorNoHooks:          return "no hooks installable";
        case VCamDiagErrorMetalUnavailable: return "Metal unavailable";
        case VCamDiagErrorSandboxDenied:    return "sandbox denied config read";
        case VCamDiagErrorNoMedia:          return "no media selected";
        case VCamDiagErrorDecodeFailed:     return "media decode failed";
        case VCamDiagErrorPoolExhausted:    return "buffer pool exhausted";
        default:                            return "unknown";
    }
}
