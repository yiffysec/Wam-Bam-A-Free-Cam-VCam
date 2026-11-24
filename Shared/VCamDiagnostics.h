// VCamDiagnostics.h -- What the daemon publishes about itself
//
// The point of this layer is to make failure diagnosable. Without it the only
// available answer to "it doesn't work" is a shrug: hooks install silently,
// frames are replaced silently, and a sandbox denial or an unsupported pixel
// format looks exactly like a disabled tweak.
//
// With it, the companion app can say something specific -- "tier 0 installed 4
// of 6 hooks and has replaced 0 frames out of 1,847 seen, so we escalated to
// tier 1" -- and the fallback arbiter has the signal it needs to escalate on
// its own.
//
// Every counter is a plain atomic in the second cache line of the shared
// region. No seqlock: counters need no mutual consistency, and the capture
// thread must never block on diagnostics. All of these are safe to call from a
// hook on the hot path.

#pragma once
#include <stdint.h>
#include "VCamSharedState.h"

#ifdef __cplusplus
extern "C" {
#endif

// -- Hot-path counters ----------------------------------------------------

/// A real camera frame passed through emitSampleBuffer:.
void vcam_diag_note_frame_seen(void);

/// A substitution was actually handed to a sink.
void vcam_diag_note_replacement(void);

/// Our own 30Hz timer pushed a frame into a stalled sink.
void vcam_diag_note_driven_frame(void);

/// A shape was rendered through the framing pipeline.
void vcam_diag_note_render(void);

/// A shape was served from its cache without re-rendering.
void vcam_diag_note_cache_hit(void);

/// A client asked for a pixel format we cannot produce. Records the FourCC so
/// the next unsupported format shows up in diagnostics rather than only in the
/// log, which is where new iOS releases tend to surprise us.
void vcam_diag_note_declined_format(uint32_t fourCC);

// -- State ----------------------------------------------------------------

void vcam_diag_set_hooks(uint32_t attempted, uint32_t installed);
void vcam_diag_add_installed_hook(uint32_t bit);
void vcam_diag_set_active_tier(uint32_t tier);
void vcam_diag_set_variant_count(uint32_t count);
void vcam_diag_set_ios_version(uint32_t major, uint32_t minor);
void vcam_diag_set_last_error(uint32_t code);
void vcam_diag_set_daemon_pid(uint32_t pid);

// -- Reading --------------------------------------------------------------

/// Snapshot every field. Fields are read independently, so the snapshot is not
/// a consistent instant -- which is fine for counters and is the reason this
/// needs no lock.
void vcam_diag_read(VCamDiagnostics *out);

/// Reset the counters, keeping hook and version state. Used when the engine
/// restarts so the app's numbers describe the current run.
void vcam_diag_reset_counters(void);

/// Short human-readable name for a tier, for UI and logs.
const char *vcam_diag_tier_name(uint32_t tier);

/// Short human-readable name for an error code.
const char *vcam_diag_error_name(uint32_t code);

#ifdef __cplusplus
}
#endif
