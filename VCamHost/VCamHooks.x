// VCamHooks.x -- Frame substitution in the capture graph, with fallbacks
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
//  -renderSampleBuffer:forInput: is hooked, whose signature is object-typed and
//  stable from iOS 15 through 26.
// ===========================================================================
//
// Tiers. Each is a different route for our pixels, and the arbiter escalates
// when it observes real frames flowing with none of them being replaced:
//
//   0  sink hooks        -- substitute at the six sink selectors. Preferred:
//                           each sink knows the exact shape its client asked
//                           for, so substitution is format-honest.
//   1  emit replacement  -- substitute at BWNodeOutput emitSampleBuffer:, the
//                           one point every frame passes through. Coarser (one
//                           shape for all consumers downstream) but it works
//                           when no sink selector could be hooked.
//   2  discovered hooks  -- enumerate the runtime for any *SinkNode class
//                           responding to renderSampleBuffer:forInput: and hook
//                           whatever turns up. This is the insurance policy
//                           against Apple renaming these classes.
//   3  client side       -- give up in-daemon and let the app-side library own
//                           it. Published for the app to act on.
//
// Format contract: every substitution derives its shape from the sample buffer
// being replaced, so a connection that asked for 640x480 BGRA gets exactly
// that. `fallbackFormat` below applies only when a buffer declares no format at
// all -- a compressed still, usually.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdatomic.h>
#include <mach/mach_time.h>

#import "VCamTypes.h"
#import "VCamSharedState.h"
#import "VCamDiagnostics.h"
#import "VCamFrameEngine.h"
#import "VCamAudioEngine.h"
#import "VCamPaths.h"
#import "VCamFrameVariant.h"
#import "VCamPixelConverter.h"

extern int vcam_ios_major(void);

// -- Natural-render tracking ----------------------------------------------
// Mach time of the last time the real graph drove a remote sink. The frame
// engine only pushes its own frames once this has gone stale, so a healthy
// graph is never doubled up.
static _Atomic uint64_t g_lastNaturalRender = 0;

void vcam_note_natural_render(void) {
    atomic_store_explicit(&g_lastNaturalRender, mach_absolute_time(),
                          memory_order_relaxed);
}

uint64_t vcam_last_natural_render(void) {
    return atomic_load_explicit(&g_lastNaturalRender, memory_order_relaxed);
}

// -- Tier state -----------------------------------------------------------
static _Atomic uint32_t g_activeTier = VCamTierSinkHooks;

static inline BOOL vcam_tier_is(VCamTier t) {
    return atomic_load_explicit(&g_activeTier, memory_order_relaxed) == (uint32_t)t;
}

static void vcam_set_tier(VCamTier t) {
    uint32_t prev = atomic_exchange_explicit(&g_activeTier, (uint32_t)t,
                                             memory_order_relaxed);
    if (prev != (uint32_t)t) {
        VCamLogI("tier: %{public}s -> %{public}s",
                 vcam_diag_tier_name(prev), vcam_diag_tier_name(t));
        vcam_diag_set_active_tier((uint32_t)t);
    }
}

// -- Hook bookkeeping -----------------------------------------------------
typedef void (*VCamEmitFn)(id, SEL, CMSampleBufferRef);
typedef void (*VCamRenderFn)(id, SEL, CMSampleBufferRef, id);

static VCamEmitFn   orig_emitSampleBuffer    = NULL;
static VCamRenderFn orig_imageQueue_render   = NULL;
static VCamRenderFn orig_remoteQueue_render  = NULL;
static VCamRenderFn orig_photoEncoder_render = NULL;
static VCamRenderFn orig_stillImage_render   = NULL;
static VCamRenderFn orig_stillScaler_render  = NULL;
static VCamRenderFn orig_videoComp_render    = NULL;
static VCamRenderFn orig_audioConv_render    = NULL;

static uint32_t g_hooksAttempted = 0;
static uint32_t g_hooksInstalled = 0;

/// Originals for classes found by discovery. Each discovered class gets its own
/// slot so its %orig can be called without a lookup on the hot path.
#define kVCamMaxDiscovered 12
static struct {
    Class        cls;
    VCamRenderFn orig;
} g_discovered[kVCamMaxDiscovered];
static int g_discoveredCount = 0;

// =========================================================================
//  Gating
// =========================================================================
static inline BOOL vcam_should_replace(void) {
    VCamSharedState st;
    vcam_shm_read(&st);

    if (!st.enabled || st.paused) return NO;

    // Per-app mode honours the verdict published by VCamClient from inside the
    // app. In system-wide mode the flag is ignored entirely, so a VCamClient
    // that failed to load cannot break the common case.
    if (st.perAppEnabled && !st.clientAllowed) return NO;

    return YES;
}

// =========================================================================
//  Replacement sample buffer
// =========================================================================
// CFDictionaryApplyFunction takes a C function pointer, not a block.
static void vcam_copy_attachment(const void *key, const void *value, void *ctx) {
    if (key && value && ctx) {
        CFDictionarySetValue((CFMutableDictionaryRef)ctx, key, value);
    }
}

/// Wraps our pixel buffer in a sample buffer that inherits the original's
/// timing and attachments, so CMTime monotonicity -- which AVFoundation asserts
/// on -- and camera metadata both survive substitution.
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

    // Carry over orientation, exposure and the rest so the buffer looks native.
    if (original) {
        CFArrayRef srcAtt = CMSampleBufferGetSampleAttachmentsArray(original, false);
        CFArrayRef dstAtt = CMSampleBufferGetSampleAttachmentsArray(out, true);
        if (srcAtt && dstAtt &&
            CFArrayGetCount(srcAtt) > 0 && CFArrayGetCount(dstAtt) > 0) {
            CFDictionaryRef s = CFArrayGetValueAtIndex(srcAtt, 0);
            CFMutableDictionaryRef d =
                (CFMutableDictionaryRef)CFArrayGetValueAtIndex(dstAtt, 0);
            if (s && d) CFDictionaryApplyFunction(s, vcam_copy_attachment, d);
        }
    }

    return out;
}

/// The body every sink hook shares. Derives the shape from `sb`, substitutes if
/// possible, and otherwise passes the real frame through untouched -- a
/// substitution we cannot do correctly is always worse than not doing it.
static inline void vcam_substitute(id self, SEL _cmd, CMSampleBufferRef sb,
                                    id input, VCamRenderFn orig,
                                    OSType fallbackFormat) {
    if (!orig) return;

    if (!vcam_should_replace()) { orig(self, _cmd, sb, input); return; }

    CVPixelBufferRef frame =
        [VCamFrameEngine.sharedEngine frameForSampleBuffer:sb
                                           fallbackFormat:fallbackFormat];
    if (!frame) { orig(self, _cmd, sb, input); return; }

    CMSampleBufferRef replacement = vcam_wrap(sb, frame);
    CVPixelBufferRelease(frame);

    if (replacement) {
        orig(self, _cmd, replacement, input);
        CFRelease(replacement);
        vcam_diag_note_replacement();
    } else {
        orig(self, _cmd, sb, input);
    }
}

// =========================================================================
//  Tier 0 -- the six sink selectors
// =========================================================================

// BWNodeOutput -emitSampleBuffer: is the universal point. At tier 0 it only
// measures: geometry for the engine's default, and the frame counter the
// arbiter compares against. At tier 1 it also substitutes.
static void hook_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (sb) {
        vcam_diag_note_frame_seen();

        CVPixelBufferRef real = CMSampleBufferGetImageBuffer(sb);
        if (real) {
            [VCamFrameEngine.sharedEngine
                notifyRealCameraSize:CGSizeMake(CVPixelBufferGetWidth(real),
                                                CVPixelBufferGetHeight(real))];
        }
    }

    if (!orig_emitSampleBuffer) return;

    // Tier 1: substitute here instead. Only when the sink hooks are not the
    // active route, so a healthy tier 0 is never double-substituted.
    if (vcam_tier_is(VCamTierEmitReplacement) && vcam_should_replace() && sb) {
        CVPixelBufferRef frame =
            [VCamFrameEngine.sharedEngine
                frameForSampleBuffer:sb
                      fallbackFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
        if (frame) {
            CMSampleBufferRef replacement = vcam_wrap(sb, frame);
            CVPixelBufferRelease(frame);
            if (replacement) {
                orig_emitSampleBuffer(self, _cmd, replacement);
                CFRelease(replacement);
                vcam_diag_note_replacement();
                return;
            }
        }
    }

    orig_emitSampleBuffer(self, _cmd, sb);
}

static void hook_imageQueue_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_substitute(self, _cmd, sb, in, orig_imageQueue_render,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}

static void hook_remoteQueue_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    // Registering the node lets the engine push frames at a steady 30Hz when
    // the graph stalls -- without that drive, third-party apps show a frozen
    // first frame or nothing at all.
    [VCamFrameEngine.sharedEngine registerRemoteQueueSinkNode:self input:in];

    // Record that the real graph is pulling, so the engine's timer stays out of
    // the way instead of doubling every frame.
    vcam_note_natural_render();

    vcam_substitute(self, _cmd, sb, in, orig_remoteQueue_render,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}

static void hook_photoEncoder_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_substitute(self, _cmd, sb, in, orig_photoEncoder_render,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}

// Still paths default to BGRA when a buffer declares no format -- but the shape
// still comes from the buffer when it has one, so a still sink handing us 420v
// gets 420v back.
static void hook_stillImage_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_substitute(self, _cmd, sb, in, orig_stillImage_render,
                    kCVPixelFormatType_32BGRA);
}

static void hook_stillScaler_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_substitute(self, _cmd, sb, in, orig_stillScaler_render,
                    kCVPixelFormatType_32BGRA);
}

// BWVideoCompressorNode receives the UNCOMPRESSED frame on its way into the
// H.264/HEVC encoder that feeds movie recording (BWQuickTimeMovieFileSinkNode).
// The preview sinks are a parallel branch, so without this hook a recording
// captured the real sensor even while the preview showed our media. Substituting
// the compressor's input -- an uncompressed 420v frame, same as the video sinks
// -- puts our content into the recorded file. We hook the input, never the
// movie-file sink, which only sees already-compressed data.
static void hook_videoComp_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    vcam_substitute(self, _cmd, sb, in, orig_videoComp_render,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}

// BWAudioConverterNode receives the microphone audio before it splits to the
// recording file and to apps. Replacing it here covers every audio consumer at
// once. The audio engine decides per mode: pass the real mic through (NULL),
// silence it (None or muted), or fill it with the video's / a custom file's
// audio -- always in the original buffer's exact format, so the stream's shape
// is untouched.
static void hook_audioConv_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    if (!orig_audioConv_render) return;

    if (!vcam_should_replace()) { orig_audioConv_render(self, _cmd, sb, in); return; }

    VCamSharedState st;
    vcam_shm_read(&st);

    CMSampleBufferRef replacement =
        [VCamAudioEngine.sharedEngine replacementForBuffer:sb
                                                      mode:st.audioMode
                                                     muted:(st.audioMuted != 0)];
    if (replacement) {
        orig_audioConv_render(self, _cmd, replacement, in);
        CFRelease(replacement);
    } else {
        orig_audioConv_render(self, _cmd, sb, in);   // pass the real mic through
    }
}

// =========================================================================
//  Tier 2 -- discovered classes
// =========================================================================
// One shared hook for everything discovery turns up. The original is found by
// class identity, walking the superclass chain because the receiver may be a
// subclass of the class we hooked.
static void hook_discovered_render(id self, SEL _cmd, CMSampleBufferRef sb, id in) {
    VCamRenderFn orig = NULL;
    for (Class c = object_getClass(self); c && !orig; c = class_getSuperclass(c)) {
        for (int i = 0; i < g_discoveredCount; i++) {
            if (g_discovered[i].cls == c) { orig = g_discovered[i].orig; break; }
        }
    }
    if (!orig) return;   // cannot call through; dropping is safer than guessing

    vcam_substitute(self, _cmd, sb, in, orig,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}

// =========================================================================
//  Exported: push straight to a remote sink
// =========================================================================
// Called by the engine's 30Hz timer. Goes to the ORIGINAL implementation on
// purpose: the buffer is already ours, so routing back through the hook would
// re-fetch the current frame and do the work twice.
void vcam_push_to_remote_sink(id node, CMSampleBufferRef sb, id input) {
    if (!node || !sb || !orig_remoteQueue_render) return;
    @try {
        orig_remoteQueue_render(node, @selector(renderSampleBuffer:forInput:),
                                sb, input);
    } @catch (NSException *ex) {
        VCamLogE("push_to_remote_sink: %{public}@", ex.reason);
    }
}

// =========================================================================
//  Installation
// =========================================================================

/// Verifies a selector exists AND that its shape matches what we expect before
/// swapping the implementation. A signature change in a future iOS release then
/// degrades into "this hook is skipped and logged", never into a crash.
static BOOL vcam_signature_ok(Class cls, const char *clsName, SEL sel,
                               unsigned expectedArgc) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        VCamLogE("hook: %{public}s has no %{public}s",
                 clsName, sel_getName(sel));
        return NO;
    }

    unsigned argc = method_getNumberOfArguments(m);
    if (argc != expectedArgc) {
        VCamLogE("hook: %{public}s %{public}s argc=%u expected %u -- skipping",
                 clsName, sel_getName(sel), argc, expectedArgc);
        return NO;
    }

    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != 'v') {
        VCamLogE("hook: %{public}s %{public}s returns '%{public}s' not void -- "
                 "skipping", clsName, sel_getName(sel), ret);
        return NO;
    }

    return YES;
}

static BOOL vcam_hook_render(const char *clsName, VCamRenderFn replacement,
                              VCamRenderFn *origSlot, uint32_t bit) {
    g_hooksAttempted |= bit;

    Class cls = objc_getClass(clsName);
    if (!cls) {
        VCamLogI("hook: class %{public}s absent on this release", clsName);
        return NO;
    }

    SEL sel = @selector(renderSampleBuffer:forInput:);
    if (!vcam_signature_ok(cls, clsName, sel, 4)) return NO;

    MSHookMessageEx(cls, sel, (IMP)replacement, (IMP *)origSlot);
    if (!*origSlot) {
        VCamLogE("hook: %{public}s produced no original", clsName);
        return NO;
    }

    g_hooksInstalled |= bit;
    VCamLogI("hook: %{public}s installed", clsName);
    return YES;
}

static BOOL vcam_hook_emit(void) {
    g_hooksAttempted |= kVCamHookEmit;

    Class cls = objc_getClass("BWNodeOutput");
    if (!cls) {
        VCamLogE("hook: BWNodeOutput absent");
        return NO;
    }

    SEL sel = @selector(emitSampleBuffer:);
    if (!vcam_signature_ok(cls, "BWNodeOutput", sel, 3)) return NO;

    MSHookMessageEx(cls, sel, (IMP)hook_emitSampleBuffer,
                    (IMP *)&orig_emitSampleBuffer);
    if (!orig_emitSampleBuffer) return NO;

    g_hooksInstalled |= kVCamHookEmit;
    VCamLogI("hook: BWNodeOutput emitSampleBuffer: installed");
    return YES;
}

/// Tier 2. Walks the entire class list for anything that looks like a capture
/// sink and responds to the selector we know how to drive. Deliberately
/// conservative about what it will touch: a false positive here runs our
/// substitution inside an unrelated subsystem.
static int vcam_install_discovered_hooks(void) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return 0;

    SEL sel = @selector(renderSampleBuffer:forInput:);
    int installed = 0;

    for (unsigned i = 0; i < count && g_discoveredCount < kVCamMaxDiscovered; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;

        // Must look like a capture-graph sink.
        if (strncmp(name, "BW", 2) != 0 && strstr(name, "CaptureSink") == NULL) {
            continue;
        }
        if (strstr(name, "Sink") == NULL && strstr(name, "Encoder") == NULL) {
            continue;
        }

        // Already covered by tier 0.
        if (strcmp(name, "BWImageQueueSinkNode") == 0            ||
            strcmp(name, "BWRemoteQueueSinkNode") == 0           ||
            strcmp(name, "BWPhotoEncoderNode") == 0              ||
            strcmp(name, "BWStillImageSampleBufferSinkNode") == 0 ||
            strcmp(name, "BWStillImageScalerNode") == 0) {
            continue;
        }

        // The selector must be implemented by this class itself, not inherited
        // -- hooking an inherited method would hook the superclass for every
        // subclass at once, which is both redundant and hard to reason about.
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL declaresItself = NO;
        if (methods) {
            for (unsigned int m = 0; m < methodCount; m++) {
                if (method_getName(methods[m]) == sel) { declaresItself = YES; break; }
            }
            free(methods);
        }
        if (!declaresItself) continue;

        if (!vcam_signature_ok(cls, name, sel, 4)) continue;

        VCamRenderFn orig = NULL;
        MSHookMessageEx(cls, sel, (IMP)hook_discovered_render, (IMP *)&orig);
        if (!orig) {
            VCamLogE("discovery: %{public}s produced no original", name);
            continue;
        }

        g_discovered[g_discoveredCount].cls  = cls;
        g_discovered[g_discoveredCount].orig = orig;
        g_discoveredCount++;
        installed++;

        VCamLogI("discovery: hooked %{public}s", name);
    }

    free(classes);

    if (installed > 0) {
        g_hooksInstalled |= kVCamHookDiscovered;
        vcam_diag_add_installed_hook(kVCamHookDiscovered);
    }
    return installed;
}

// =========================================================================
//  Capture-graph dump (diagnostics, not a hook)
// =========================================================================
// Writes every BW* node class present on this device, flagging which respond to
// the render selector we drive and which look recording-related, to a
// world-readable text file the app can show. The point is to identify the nodes
// we do NOT yet hook -- above all the movie-recording encoder, which is why a
// recorded clip still captures the real camera -- without guessing a class name
// and risking a daemon crash by hooking the wrong one.
static void vcam_dump_graph_classes(void) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    SEL render = @selector(renderSampleBuffer:forInput:);
    SEL emit   = @selector(emitSampleBuffer:);

    NSMutableString *dump = [NSMutableString string];
    [dump appendString:@"# Wam Bam VCam -- capture graph node classes\n"];
    [dump appendString:@"# flags: [R]=renderSampleBuffer:forInput:  "
                        "[E]=emitSampleBuffer:  [*]=looks recording-related\n\n"];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        const char *n = class_getName(classes[i]);
        if (!n || strncmp(n, "BW", 2) != 0) continue;
        [names addObject:@(n)];
    }
    free(classes);
    [names sortUsingSelector:@selector(caseInsensitiveCompare:)];

    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        BOOL r = [cls instancesRespondToSelector:render];
        BOOL e = [cls instancesRespondToSelector:emit];

        // Only list nodes that actually move sample buffers, or whose name
        // points at the recording/encode/write path -- the full BW* list is
        // long and mostly irrelevant.
        BOOL recordish =
            [name containsString:@"Encoder"] || [name containsString:@"Record"] ||
            [name containsString:@"Movie"]   || [name containsString:@"Writer"]  ||
            [name containsString:@"File"]     || [name containsString:@"Video"];
        if (!r && !e && !recordish) continue;

        [dump appendFormat:@"%@%@%@ %@\n",
            r ? @"[R]" : @"[ ]",
            e ? @"[E]" : @"[ ]",
            recordish ? @"[*]" : @"[ ]",
            name];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:VCamLibraryDir()
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions: @(0777) }
                        error:nil];
    NSString *path = VCamGraphDumpPath();
    [dump writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm setAttributes:@{ NSFilePosixPermissions: @(0644) }
         ofItemAtPath:path error:nil];

    VCamLogI("graph: dumped %lu node classes to %{public}@",
             (unsigned long)names.count, path);
}

// =========================================================================
//  The arbiter
// =========================================================================
// Escalates when real frames are flowing and none of them are being replaced.
// That is the only symptom common to every way tier 0 can silently fail: a
// renamed class, a changed signature, a sink we do not know about, or a
// substitution that is being built but rejected downstream.
static dispatch_source_t g_arbiterTimer = nil;

static void vcam_arbiter_tick(void) {
    static uint64_t lastSeen    = 0;
    static uint64_t lastHandled = 0;
    static int      quietTicks  = 0;

    VCamSharedState st;
    vcam_shm_read(&st);

    VCamDiagnostics d;
    vcam_diag_read(&d);

    uint64_t seen     = atomic_load_explicit(&d.framesSeen,     memory_order_relaxed);
    uint64_t replaced = atomic_load_explicit(&d.framesReplaced, memory_order_relaxed);
    uint64_t driven   = atomic_load_explicit(&d.framesDriven,   memory_order_relaxed);
    uint64_t declined = atomic_load_explicit(&d.framesDeclined, memory_order_relaxed);

    // "Handled" is substituted OR deliberately passed through. A decline is a
    // correct decision (the app asked for a format we must not fake), not a
    // failure -- counting it as handled is what stops one unusual app from
    // escalating the whole daemon, and from there into the risky discovered
    // hooks, which is a route to crashing other apps.
    uint64_t handled = replaced + driven + declined;

    uint64_t seenDelta    = seen    - lastSeen;
    uint64_t handledDelta = handled - lastHandled;

    lastSeen    = seen;
    lastHandled = handled;

    // Only judge when we are meant to be substituting and the camera is running.
    if (!st.enabled || st.paused || seenDelta == 0) {
        quietTicks = 0;
        return;
    }

    if (handledDelta > 0) {
        quietTicks = 0;
        return;
    }

    // Frames are flowing and we are neither substituting nor deliberately
    // declining them -- a genuine failure to intercept.
    if (++quietTicks < 3) return;   // ~6s of evidence before acting
    quietTicks = 0;

    // Escalation is deliberately limited to the emit-replacement route, which is
    // the same BWNodeOutput we already hook used a different way -- safe, and it
    // also reaches the recording branch. We do NOT auto-install the discovered
    // hooks: hooking arbitrary *SinkNode/*Encoder classes whose buffer contracts
    // we do not know is a real way to crash a host app, and a silent
    // pass-through is strictly better than that. Discovery remains available for
    // a deliberate, opt-in future use, not as an automatic fallback.
    switch ((VCamTier)atomic_load_explicit(&g_activeTier, memory_order_relaxed)) {
        case VCamTierSinkHooks:
            if (orig_emitSampleBuffer) {
                VCamLogE("arbiter: %llu frames seen, none handled -- escalating to "
                         "emit replacement", (unsigned long long)seenDelta);
                vcam_set_tier(VCamTierEmitReplacement);
            } else {
                VCamLogE("arbiter: no emit hook to fall back to -- handing off to "
                         "the client side");
                vcam_set_tier(VCamTierClientSide);
            }
            break;

        case VCamTierEmitReplacement:
            VCamLogE("arbiter: emit replacement is not landing either -- handing "
                     "off to the client side");
            vcam_set_tier(VCamTierClientSide);
            break;

        case VCamTierDiscoveredHooks:
        case VCamTierClientSide:
            break;   // nothing further to try automatically
    }

    vcam_diag_set_hooks(g_hooksAttempted, g_hooksInstalled);
}

static void vcam_start_arbiter(void) {
    if (g_arbiterTimer) return;

    g_arbiterTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));

    dispatch_source_set_timer(g_arbiterTimer,
                               dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                               2ull * NSEC_PER_SEC,
                               (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_arbiterTimer, ^{
        @try {
            vcam_arbiter_tick();
        } @catch (NSException *ex) {
            VCamLogE("arbiter: %{public}@", ex.reason);
        }
    });
    dispatch_resume(g_arbiterTimer);

    VCamLogI("arbiter: watching");
}

// =========================================================================
//  Public installation
// =========================================================================
void vcam_install_hooks(void) {
    VCamLogI("install: starting on iOS %d", vcam_ios_major());

    g_hooksAttempted = 0;
    g_hooksInstalled = 0;

    @try {
        // The universal point first: it is both tier 1 and the arbiter's only
        // source of "real frames are flowing" evidence, so losing it costs more
        // than losing any single sink.
        vcam_hook_emit();

        vcam_hook_render("BWImageQueueSinkNode",
                         hook_imageQueue_render, &orig_imageQueue_render,
                         kVCamHookImageQueue);

        vcam_hook_render("BWRemoteQueueSinkNode",
                         hook_remoteQueue_render, &orig_remoteQueue_render,
                         kVCamHookRemoteQueue);

        vcam_hook_render("BWPhotoEncoderNode",
                         hook_photoEncoder_render, &orig_photoEncoder_render,
                         kVCamHookPhotoEncoder);

        // NOTE: renderSampleBuffer:forInput: only. See the boot-loop trap at
        // the top of this file -- initWithInputMediaType:sinkID: is off limits.
        vcam_hook_render("BWStillImageSampleBufferSinkNode",
                         hook_stillImage_render, &orig_stillImage_render,
                         kVCamHookStillImage);

        vcam_hook_render("BWStillImageScalerNode",
                         hook_stillScaler_render, &orig_stillScaler_render,
                         kVCamHookStillScaler);

        // Movie recording: substitute the uncompressed frame entering the video
        // encoder, so a recorded clip contains our media rather than the real
        // sensor feed the parallel preview branch never touched.
        vcam_hook_render("BWVideoCompressorNode",
                         hook_videoComp_render, &orig_videoComp_render,
                         kVCamHookVideoComp);

        // Microphone: substitute the audio entering the converter, before it
        // splits to the recording and to apps.
        vcam_hook_render("BWAudioConverterNode",
                         hook_audioConv_render, &orig_audioConv_render,
                         kVCamHookAudioConv);
    } @catch (NSException *ex) {
        VCamLogE("install: exception %{public}@ -- keeping the partial hook set",
                 ex.reason);
    }

    // Decide where to start. If not one sink selector took, substituting at
    // emitSampleBuffer: is better than doing nothing; if even that is missing,
    // go straight to discovery rather than waiting for the arbiter.
    uint32_t sinkBits = kVCamHookImageQueue | kVCamHookRemoteQueue |
                        kVCamHookPhotoEncoder | kVCamHookStillImage |
                        kVCamHookStillScaler | kVCamHookVideoComp;

    if (g_hooksInstalled & sinkBits) {
        vcam_set_tier(VCamTierSinkHooks);
    } else if (g_hooksInstalled & kVCamHookEmit) {
        VCamLogE("install: no sink hooks took -- starting at emit replacement");
        vcam_set_tier(VCamTierEmitReplacement);
    } else {
        VCamLogE("install: nothing known could be hooked -- trying discovery");
        if (vcam_install_discovered_hooks() > 0) {
            vcam_set_tier(VCamTierDiscoveredHooks);
        } else {
            vcam_set_tier(VCamTierClientSide);
            vcam_diag_set_last_error(VCamDiagErrorNoHooks);
        }
    }

    vcam_diag_set_hooks(g_hooksAttempted, g_hooksInstalled);

    // Record the graph so the recording node can be identified from the app.
    @try { vcam_dump_graph_classes(); }
    @catch (NSException *ex) { VCamLogE("graph dump: %{public}@", ex.reason); }

    vcam_start_arbiter();

    VCamLogI("install: complete -- attempted 0x%02x installed 0x%02x tier %{public}s",
             g_hooksAttempted, g_hooksInstalled,
             vcam_diag_tier_name(atomic_load(&g_activeTier)));
}

// The BW* graph lives in CMCapture.framework on iOS 14+ and Celestial before
// that, but the selectors we rely on are identical, so one implementation
// serves every supported release.
void vcam_install_hooks_ios18(void) { vcam_install_hooks(); }
void vcam_install_hooks_ios17(void) { vcam_install_hooks(); }
