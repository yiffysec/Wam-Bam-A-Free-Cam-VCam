// VCamBootGuard.h — Crash watchdog + kill-switch for boot-loop prevention
//
// Strategy:
//   1. At dylib constructor time, check the kill-switch flag file.
//      If present → abort injection and return immediately.
//   2. Write a "loading" timestamp file.
//   3. If cameracaptured crashes within 30s of that file being created
//      and this happens 3 times in a row → write the kill-switch flag
//      and bail. The user can remove it via the companion app.
//
// The companion app writes/removes kVCamKillSwitchPath so the user
// can recover from a boot-loop without SSH.

#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Call at the very start of the dylib constructor.
/// Returns NO if the kill-switch is set (caller should abort injection).
BOOL vcam_bootguard_check(void);

/// Call once injection has been successfully applied and the process
/// has started normally. Resets the crash counter.
void vcam_bootguard_reset(void);

/// Returns YES if the user has manually disabled the tweak via kill-switch.
BOOL vcam_bootguard_is_killed(void);

/// Write the kill-switch flag (call when repeated crashes are detected).
void vcam_bootguard_set_killed(void);

/// Remove the kill-switch flag (call from companion app to re-enable).
void vcam_bootguard_clear_killed(void);

#ifdef __cplusplus
}
#endif
