// VCamHooks.x -- BW* node-graph hooks for virtual camera frame injection
//
// Hook points:
//   1. BWNodeOutput -emitSampleBuffer:                              (geometry probe)
//   2. BWImageQueueSinkNode -renderSampleBuffer:forInput:           (in-process delivery)
//   3. BWRemoteQueueSinkNode -renderSampleBuffer:forInput:          (third-party apps)
//   4. BWPhotoEncoderNode -renderSampleBuffer:forInput:             (photo capture)
//   5. BWStillImageSampleBufferSinkNode -renderSampleBuffer:forInput: (still delivery)
//
// ===========================================================================
//  THE BOOT-LOOP TRAP -- read before touching this file
// ===========================================================================
//  -[BWStillImageSampleBufferSinkNode initWithInputMediaType:sinkID:] takes an
//  OSType (a uint32 FourCC, 'vide' == 0x76696465) as its FIRST argument, not an
//  Objective-C object. Hooking it with an `id` parameter makes ARC -- or any
//  %orig bridging -- retain the integer 0x76696465 as if it were a pointer.
//  That dereferences unmapped memory inside cameracaptured, which crashes.
//  SpringBoard waits synchronously on cameracaptured's torch XPC service during
//  startup, so a crash loop there hangs the device at the Apple logo.
//
//  This file therefore NEVER hooks that initialiser. Only
//  -renderSampleBuffer:forInput: is hooked, whose signature is stable and
//  object-typed on every release from iOS 15 through iOS 26.
//
//  Every hook is additionally guarded by:
//    * class existence verification before any hook is installed
//    * method existence + type-encoding verification per selector
//    * an @try/@catch around installation so a surprise never reaches launchd
// ===========================================================================
//
// Format contract (violating this is the usual cause of a black preview):
//   video sinks -> kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ('420v')
//   still sinks -> kCVPixelFormatType_32BGRA
//   colour      -> BT.709, video range (enforced in VCamPixelConverter's shader)

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdatomic.h>
#include <mach/mach_time.h>

#import "VCamTypes.h"
#import "VCamSharedState.h"
#import "VCamFrameEngine.h"
#import "VCamPixelConverter.h"

extern int vcam_ios_major(void);

// -- Class caches ---------------------------------------------------------
static Class cls_BWNodeOutput                     = nil;
static Class cls_BWImageQueueSinkNode             = nil;
static Class cls_BWRemoteQueueSinkNode            = nil;
static Class cls_BWPhotoEncoderNode               = nil;
static Class cls_BWStillImageSampleBufferSinkNode = nil;

// -- Original implementations --------------------------------------------
typedef void (*VCamEmitFn)(id, SEL, CMSampleBufferRef);
typedef void (*VCamRenderFn)(id, SEL, CMSampleBufferRef, id);

static VCamEmitFn   orig_emitSampleBuffer       = NULL;
static VCamRenderFn orig_imageQueue_render      = NULL;
static VCamRenderFn orig_remoteQueue_render     = NULL;
static VCamRenderFn orig_photoEncoder_render    = NULL;
static VCamRenderFn orig_stillImage_render      = NULL;

// -- Gating ---------------------------------------------------------------
static inline BOOL vcam_should_replace(void) {
    VCamSharedState st;
    vcam_shm_read(&st);

    if (!st.enabled || st.paused) return NO;

    // Per-app mode: honour the verdict published by VCamClient. In system-wide
    // mode the flag is ignored entirely, so a missing VCamClient cannot break
    // the common case.
    if (st.perAppEnabled && !st.clientAllowed) return NO;

    return YES;
}

// -- Replacement sample buffer -------------------------------------------
// Builds a fresh CMSampleBuffer around our pixel buffer while inheriting the
// original's timing, so CMTime monotonicity -- which AVFoundation asserts on --
// is preserved end to end.
static CMSampleBufferRef vcam_wrap(CMSampleBufferRef original,
                                    CVPixelBufferRef replacement)
                                    CF_RETURNS_RETAINED {
    if (!replacement) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus err = CMVideoFormatDescriptionCreateForImageBuffer(
                       kCFAllocatorDefault, replacement, &fmt);
    if (err != noErr || !fmt) {
        VCamLogE("wrap: format description failed err=%d", (int)err);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, kVCamTargetFPS),
        .presentationTimeStamp = kCMTimeInvalid,
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    if (original) {
        CMSampleTimingInfo inherited = {0};
        if (CMSampleBufferGetSampleTimingInfo(original, 0, &inherited) == noErr) {
            if (CMTIME_IS_VALID(inherited.presentationTimeStamp)) {
                timing.presentationTimeStamp = inherited.presentationTimeStamp;
            }
            if (CMTIME_IS_VALID(inherited.duration) &&
                CMTimeCompare(inherited.duration, kCMTimeZero) > 0) {
                timing.duration = inherited.duration;
            }
        }
    }

    if (!CMTIME_IS_VALID(timing.presentationTimeStamp)) {
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    }

    CMSampleBufferRef out = NULL;
    err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                    replacement, fmt,
                                                    &timing, &out);
    CFRelease(fmt);

    if (err != noErr || !out) {
        VCamLogE("wrap: CMSampleBufferCreateReadyWithImageBuffer err=%d", (int)err);
        return NULL;
    }

    // Carry over attachments (orientation, exposure metadata and so on) so the
    // consuming app sees a buffer that looks native.
    if (original) {
        CFArrayRef srcAtt = CMSampleBufferGetSampleAttachmentsArray(original, false);
        CFArrayRef dstAtt = CMSampleBufferGetSampleAttachmentsArray(out, true);
        if (srcAtt && dstAtt &&
            CFArrayGetCount(srcAtt) > 0 && CFArrayGetCount(dstAtt) > 0) {
            CFDictionaryRef s = CFArrayGetValueAtIndex(srcAtt, 0);
            CFMutableDictionaryRef d =
                (CFMutableDictionaryRef)CFArrayGetValueAtIndex(dstAtt, 0);
            if (s && d) {
                CFDictionaryApplyFunction(s, vcam_copy_attachment, d);
            }
        }
    }

    return out;
}

// -- Natural-render tracking ----------------------------------------------
// Mach absolute time of the last time the real graph drove a remote sink. The
// frame engine only pushes its own frames once this has gone stale, so a
// healthy graph is never doubled up.
static _Atomic uint64_t g_lastNaturalRender = 0;

void vcam_note_natural_render(void) {
    atomic_store_explicit(&g_lastNaturalRender, mach_absolute_time(),
                          memory_order_relaxed);
}

uint64_t vcam_last_natural_render(void) {
    return atomic_load_explicit(&g_lastNaturalRender, memory_order_relaxed);
}

// CFDictionaryApplyFunction takes a C function pointer, not a block.
static void vcam_copy_attachment(const void *key, const void *value, void *ctx) {
    if (key && value && ctx) {
        CFDictionarySetValue((CFMutableDictionaryRef)ctx, key, value);
    }
}

// Shared body for all the 420v video sinks.
static inline void vcam_render_video(id self, SEL _cmd, CMSampleBufferRef sb,
                                      id input, VCamRenderFn orig) {
    if (!orig) return;

    if (!vcam_should_replace()) { orig(self, _cmd, sb, input); return; }

    CVPixelBufferRef frame = [VCamFrameEngine.sharedEngine currentFrame420v];
    if (!frame) { orig(self, _cmd, sb, input); return; }

    CMSampleBufferRef replacement = vcam_wrap(sb, frame);
    CVPixelBufferRelease(frame);

    if (replacement) {
        orig(self, _cmd, replacement, input);
        CFRelease(replacement);
    } else {
        orig(self, _cmd, sb, input);
    }
}

// -- Hook 1: BWNodeOutput -emitSampleBuffer: ------------------------------
// The one place every camera frame in the system passes through. Used only to
// learn the real sensor geometry so our output matches it exactly; replacement
// happens at the sinks, where the pixel-format contract is unambiguous.
static void hook_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (sb) {
        CVPixelBufferRef real = CMSampleBufferGetImageBuffer(sb);
        if (real) {
            [VCamFrameEngine.sharedEngine
                notifyRealCameraSize:CGSizeMake(CVPixelBufferGetWidth(real),
                                                CVPixelBufferGetHeight(real))];
        }
    }
    if (orig_emitSampleBuffer) orig_emitSampleBuffer(self, _cmd, sb);
}

// -- Hooks 2-4: 420v video sinks -----------------------------------------
static void hook_imageQueue_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_render_video(self, _cmd, sb, in, orig_imageQueue_render);
}

static void hook_remoteQueue_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    // Registering the node lets the frame engine push frames at a steady 30Hz
    // even when the real graph stalls -- without that independent drive,
    // third-party apps show a frozen first frame or nothing at all.
    [VCamFrameEngine.sharedEngine registerRemoteQueueSinkNode:self input:in];

    // Record that the real graph is pulling. The engine checks this so it only
    // takes over when the graph goes quiet, instead of doubling every frame.
    vcam_note_natural_render();

    vcam_render_video(self, _cmd, sb, in, orig_remoteQueue_render);
}

static void hook_photoEncoder_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_render_video(self, _cmd, sb, in, orig_photoEncoder_render);
}

// -- Hook 5: BGRA still sink ---------------------------------------------
static void hook_stillImage_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    if (!orig_stillImage_render) return;

    if (!vcam_should_replace()) {
        orig_stillImage_render(self, _cmd, sb, in);
        return;
    }

    CVPixelBufferRef frame = [VCamFrameEngine.sharedEngine currentFrameBGRA];
    if (!frame) { orig_stillImage_render(self, _cmd, sb, in); return; }

    CMSampleBufferRef replacement = vcam_wrap(sb, frame);
    CVPixelBufferRelease(frame);

    if (replacement) {
        orig_stillImage_render(self, _cmd, replacement, in);
        CFRelease(replacement);
    } else {
        orig_stillImage_render(self, _cmd, sb, in);
    }
}

// -- Exported: push a frame straight to a remote sink --------------------
// Called by the frame engine's 30Hz timer. Goes to the ORIGINAL implementation
// on purpose: the buffer is already ours, so routing back through the hook
// would re-fetch the current frame and do the work twice.
void vcam_push_to_remote_sink(id node, CMSampleBufferRef sb, id input) {
    if (!node || !sb || !orig_remoteQueue_render) return;
    @try {
        orig_remoteQueue_render(node, @selector(renderSampleBuffer:forInput:),
                                sb, input);
    } @catch (NSException *ex) {
        VCamLogE("push_to_remote_sink: %{public}@", ex.reason);
    }
}

// -- Installation helpers -------------------------------------------------
static BOOL vcam_resolve_classes(void) {
    struct { Class *slot; const char *name; BOOL required; } table[] = {
        { &cls_BWNodeOutput,                     "BWNodeOutput",                     YES },
        { &cls_BWImageQueueSinkNode,             "BWImageQueueSinkNode",             YES },
        { &cls_BWRemoteQueueSinkNode,            "BWRemoteQueueSinkNode",            YES },
        { &cls_BWPhotoEncoderNode,               "BWPhotoEncoderNode",               NO  },
        { &cls_BWStillImageSampleBufferSinkNode, "BWStillImageSampleBufferSinkNode", NO  },
    };

    BOOL allRequiredPresent = YES;

    for (size_t i = 0; i < VCAM_ARRAY_SIZE(table); i++) {
        *table[i].slot = objc_getClass(table[i].name);
        if (*table[i].slot) continue;

        if (table[i].required) {
            VCamLogE("resolve: REQUIRED class %{public}s missing", table[i].name);
            allRequiredPresent = NO;
        } else {
            VCamLogI("resolve: optional class %{public}s missing, skipping",
                     table[i].name);
        }
    }

    return allRequiredPresent;
}

/// Verifies a selector exists AND that its type encoding matches what we expect
/// before swapping the implementation. A signature change between iOS releases
/// then degrades into "this hook is skipped", never into a crash.
static BOOL vcam_hook_render(Class cls, const char *clsName,
                              VCamRenderFn replacement, VCamRenderFn *origSlot) {
    if (!cls) return NO;

    SEL sel = @selector(renderSampleBuffer:forInput:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        VCamLogE("hook: %{public}s has no renderSampleBuffer:forInput:", clsName);
        return NO;
    }

    // Expect: void return, (self, _cmd, CMSampleBufferRef, id) = 4 arguments.
    unsigned argc = method_getNumberOfArguments(m);
    if (argc != 4) {
        VCamLogE("hook: %{public}s renderSampleBuffer: argc=%u, expected 4 -- skipping",
                 clsName, argc);
        return NO;
    }

    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'v') {
        VCamLogE("hook: %{public}s renderSampleBuffer: returns '%{public}s', "
                 "expected void -- skipping", clsName, ret);
        return NO;
    }

    MSHookMessageEx(cls, sel, (IMP)replacement, (IMP *)origSlot);
    if (!*origSlot) {
        VCamLogE("hook: %{public}s MSHookMessageEx produced no original", clsName);
        return NO;
    }

    VCamLogI("hook: %{public}s renderSampleBuffer:forInput: installed", clsName);
    return YES;
}

static BOOL vcam_hook_emit(void) {
    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls_BWNodeOutput, sel);
    if (!m) {
        VCamLogE("hook: BWNodeOutput has no emitSampleBuffer:");
        return NO;
    }
    if (method_getNumberOfArguments(m) != 3) {
        VCamLogE("hook: BWNodeOutput emitSampleBuffer: unexpected argc -- skipping");
        return NO;
    }

    MSHookMessageEx(cls_BWNodeOutput, sel,
                    (IMP)hook_emitSampleBuffer, (IMP *)&orig_emitSampleBuffer);
    VCamLogI("hook: BWNodeOutput emitSampleBuffer: installed");
    return orig_emitSampleBuffer != NULL;
}

// -- Public installation --------------------------------------------------
void vcam_install_hooks(void) {
    VCamLogI("install: resolving BW* classes (iOS %d)", vcam_ios_major());

    if (!vcam_resolve_classes()) {
        VCamLogE("install: required classes missing -- aborting cleanly. The "
                 "camera is untouched and the device will boot normally.");
        return;
    }

    @try {
        vcam_hook_emit();

        vcam_hook_render(cls_BWImageQueueSinkNode, "BWImageQueueSinkNode",
                         hook_imageQueue_render, &orig_imageQueue_render);

        vcam_hook_render(cls_BWRemoteQueueSinkNode, "BWRemoteQueueSinkNode",
                         hook_remoteQueue_render, &orig_remoteQueue_render);

        vcam_hook_render(cls_BWPhotoEncoderNode, "BWPhotoEncoderNode",
                         hook_photoEncoder_render, &orig_photoEncoder_render);

        // NOTE: renderSampleBuffer:forInput: only. See the boot-loop trap note
        // at the top of this file -- initWithInputMediaType:sinkID: is off limits.
        vcam_hook_render(cls_BWStillImageSampleBufferSinkNode,
                         "BWStillImageSampleBufferSinkNode",
                         hook_stillImage_render, &orig_stillImage_render);
    } @catch (NSException *ex) {
        VCamLogE("install: exception %{public}@ -- partial hook set left in place",
                 ex.reason);
    }

    VCamLogI("install: complete");
}

// Version-specific entry points. The BW* graph classes live in
// CMCapture.framework on iOS 14+ and in Celestial.framework before that, but
// the selectors we rely on are identical, so one implementation serves both.
void vcam_install_hooks_ios18(void) { vcam_install_hooks(); }
void vcam_install_hooks_ios17(void) { vcam_install_hooks(); }
