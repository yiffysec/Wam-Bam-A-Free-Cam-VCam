# Architecture audit — 2026-11-24

A review of everything built so far against the research, against what
comparable implementations actually ship, and against the goal of working
across the board rather than on a happy path.

Verdict: the foundation is sound and the dangerous parts are handled, but there
are **three confirmed functional gaps that will make real apps fail**, **one
latent boot-hang risk introduced by our own code**, and **no redundancy at all**
— every capability currently has exactly one implementation, and if it misses,
the feature is simply absent.

---

## 1. What is already right

Worth stating, because the rest of this document is about what is wrong.

| Area | State |
|---|---|
| Injection target selection | Correct. `cameracaptured` on iOS 18+, `mediaserverd` on ≤17, chosen at runtime. Matches every working implementation surveyed. |
| The five sink selectors | Correct and verified dynamically (class, selector, argc, return type) before hooking. |
| The `OSType` boot-loop trap | Avoided. We never hook `initWithInputMediaType:sinkID:`. This is the documented cause of `cameracaptured` crash loops and Apple-logo hangs. |
| Boot guard | Crash counter plus kill switch, consulted before any allocation. Recoverable from the app or Settings without SSH. |
| Format contract per sink class | `420v` for video sinks, BGRA for still sinks. |
| Truncated planar refusal | Implemented — frames missing a chroma plane are dropped, not forwarded. |
| Independent 30 Hz sink drive | Implemented, and gated on stall detection so a healthy graph is not double-fed. |
| Seqlock shared memory + atomic plist | Sound two-tier design. |
| HUD optionality | Genuinely optional, probed, with in-app fallback and manual override. |

---

## 2. Confirmed functional gaps

These are not theoretical. Each is corroborated by a specific upstream fix in a
working implementation.

### 2.1 Per-connection geometry and pixel format — HIGH

**What we do:** one global `_cameraSize`, learned from `emitSampleBuffer:`, and a
fixed format assumption per sink *class*.

**Why that breaks:** a single session can have several connections at different
presets. A client that asked for 640×480, or for BGRA on a video path, receives
our 1920×1080 `420v` regardless. The upstream fix for exactly this failure
describes frames arriving as "1280×720 landscape BGRA whatever its preset /
connection asked for."

**Fix:** derive the target from the *original sample buffer being replaced*, on
every hook invocation — width, height, pixel format, and bytes-per-row — rather
than from a global. Cache rendered output per (width, height, format) so the
common case is still one render per frame.

This single change also subsumes black-screen causes 1, 4, 6 and 10 from the
research, and is the main reason to do it first.

### 2.2 No synthetic source or stream publication — HIGH

**What we do:** replace frames in sinks. Nothing else.

**Why that breaks:** if no source is published, some clients never build a
capture graph at all. The documented symptom: a front-camera client "gets no
device (the synthetic source is published as a back camera), so its session has
no input and the sample buffer delegate never fires." The preview can still look
right, which makes this easy to miss during testing.

**Fix:** publish one unsynchronized video stream on the synthetic source so
client devices get ports, and publish a format surface that matches what we
deliver — field of view, SDR only, intrinsic matrix. Position-aware, so a front
camera request resolves to a front-facing synthetic source.

Research needed: `FigCaptureSourceBackingsProvider` specifics on iOS 26, and the
`_sSourceList` removal on 27.

### 2.3 Format-description extensions are not set — MEDIUM

**What we do:** `CMVideoFormatDescriptionCreateForImageBuffer` and nothing more.

**Why that matters:** downstream colour handling reads the colour attachments.
Without `kCVImageBufferYCbCrMatrix`, `ColorPrimaries` and `TransferFunction` set
to the BT.709 values our shader actually produces, the advertised format does not
match the delivered bits. Upstream verifies precisely this ("advertised format ==
delivered format", "format-description extensions match the bits") as a test.

**Fix:** attach colour metadata to every buffer we create, and assert the
advertised description matches.

### 2.4 Missing sixth hook: `BWStillImageScalerNode` — MEDIUM

Another implementation hooks `BWStillImageScalerNode -renderSampleBuffer:forInput:`
for photo-capture scaling. We do not. Photo capture may therefore scale the real
frame on some paths.

### 2.5 Movie recording is unhandled — MEDIUM

Recording video in Camera.app will not produce our media. Upstream handles this
client-side: for a vcam-bound movie output, record it yourself with a 30 Hz
`AVAssetWriter` writing H.264, and fire
`didStartRecordingToOutputFileAtURL:` / `didFinishRecordingToOutputFileAtURL:error:`
on the delegate. Even there, rotation metadata, pause/resume, slo-mo, time-lapse
and cinematic remain uncovered.

### 2.6 Virtual microphone is plumbed but not implemented — MEDIUM

Config and UI exist; no hook does the work. Daemon-side audio graph injection is
poorly documented. The tractable path is client-side: proxy the
`AVCaptureAudioDataOutput` sample-buffer delegate. Real-mic pass-through, the
default, works today.

### 2.7 Client-side preview path is absent — HIGH

**The big one.** `BWRemoteQueueSinkNode` exists on *both* sides of the XPC
boundary. Upstream's client-side library taps it inside the app so the preview is
fed from the exact sample the graph delivered, and falls back to a bootstrap path
for "the pre-graph window (preview-only sessions)."

Our `VCamClient` only publishes a per-app verdict. Consequence: an app that uses
only `AVCaptureVideoPreviewLayer` with no data output can still show the real
camera, and there is a window at session start before the graph exists where we
deliver nothing.

**Fix:** give `VCamClient` real work — see §4, tiers 3 to 5.

---

## 3. Defects in our own code

### 3.1 Metal setup in the dylib constructor — CRITICAL, latent brick risk

`VCamHostInit` calls `[VCamPixelConverter setup]` synchronously, which calls
`MTLCreateSystemDefaultDevice()` and then `newLibraryWithSource:` — compiling
Metal from source text — inside `cameracaptured`'s startup path.

Two independent problems:

1. Runtime shader compilation costs on the order of hundreds of milliseconds. We
   are spending that before `cameracaptured` finishes starting, and SpringBoard
   waits synchronously on that daemon's torch service during boot. This is the
   same shape as the hang the `OSType` trap causes, reached a different way.
2. `cameracaptured` performs its own GPU prewarm (`FigCapturePreloadShaders` →
   `PrewarmThreadSafeSBPs` → `NRFProcessorV3 prewarm`), which is known to
   crash-loop in at least some iOS 26 configurations. Adding our own Metal device
   creation concurrently with Apple's prewarm is asking for trouble.

**Fix:** make converter setup lazy and off the constructor — first use, on a
background queue, behind `dispatch_once`, with the frame engine tolerating a
not-yet-ready converter. Prefer the `CIContext` path (which needs no custom
shader) and treat the Metal kernel as an optimisation, not a dependency.

**Status: fixed in this commit.**

### 3.2 libSandy profile is shipped but never consumed — HIGH

`layout/Library/libSandy/WamBamVCam.plist` exists. Nothing ever calls
`libSandy_applySandboxExtensions`. The dependency is declared in `control` and the
library is not even linked any more — the earlier `-lsandy` was dropped during a
Makefile rewrite.

Consequence: the daemon's sandbox may deny reads of `Config.plist` and the media
file, which presents as "the tweak does nothing" with no error anywhere obvious.

**Status: fixed in this commit.**

### 3.3 No magic or version in the shared-memory header — MEDIUM

`vcam.shm` is a persistent file. If the struct layout changes between releases
and a stale file survives the upgrade, every field is misread — including
`enabled`. There is no magic number, no version, no size check.

**Status: fixed in this commit.**

### 3.4 Dead Metal path, and `CIContext` colour management disabled — MEDIUM

`convertTo420v:` — the Metal BT.709 kernel — is never called. Everything goes
through `CIContext`, which we construct with `kCIContextWorkingColorSpace` and
`kCIContextOutputColorSpace` set to null. "No colour management" when rendering
into a YCbCr buffer is ambiguous and a plausible source of a colour shift. Either
wire the kernel up or give `CIContext` a defined working space and set the output
buffer's colour attachments.

### 3.5 Per-frame `CVPixelBufferCreate` — MEDIUM

Thirty 1080p `420v` IOSurface allocations per second inside a jetsam-constrained
daemon. Should be a `CVPixelBufferPool` sized to the research's three-buffer
budget, keyed by (width, height, format) once §2.1 lands.

### 3.6 Per-app verdict is a single global byte — MEDIUM

`clientAllowed` is one byte in shared memory. Two apps using the camera
concurrently means last writer wins. The correct fix is daemon-side client
identity — resolving the sink's client PID to a bundle ID — which needs research;
the surveyed implementations do not appear to solve this either.

### 3.7 `driveRemoteSinks` may push a nil input — LOW

We pass `ref.input`, which can be nil if the weak reference died. The original
implementation may not tolerate that.

### 3.8 No stale-frame watchdog — LOW

If `AVAssetReader` wedges, we serve the last decoded frame forever with no
detection and no restart.

---

## 4. The redundancy architecture

Today every capability has exactly one implementation. Hook installation failure
is logged and skipped, and then nothing happens — `emitSampleBuffer:` is hooked
but used *only* to learn geometry, which is a wasted fallback sitting right there.

Proposed: tiers, with a health arbiter that measures whether the active tier is
actually producing replacements and escalates when it is not.

| Tier | Mechanism | Covers | Trigger |
|---|---|---|---|
| 0 | Daemon sink hooks (current) | everything, cleanly | default |
| 1 | Replacement at `BWNodeOutput -emitSampleBuffer:` | all consumers, coarser | no sink hook installed, or zero replacements observed while frames flow |
| 2 | Dynamic class discovery — hook every class whose name matches `*SinkNode` and which responds to `renderSampleBuffer:forInput:` | future iOS renames | tier 0 found no known classes |
| 3 | Client-side `AVCaptureVideoDataOutput` delegate proxy | most third-party SDKs | daemon tiers all silent |
| 4 | Client-side `AVCaptureVideoPreviewLayer` feed / preview pump | preview-only sessions, pre-graph window | preview session with no data output |
| 5 | Client-side `AVCapturePhotoOutput` / movie-output proxy | photo and video capture | capture requested on a vcam-bound output |

Tiers 1 and 2 are cheap — tier 1 is a few lines, since the hook already exists.
Tier 3 onward is the client-side library we have not written yet.

**Crucially, the arbiter needs observability to work.** Which leads to:

### 4.1 Runtime verification and diagnostics — HIGH

We currently cannot answer "is it working, and if not, which part failed?" The
daemon should publish into shared memory:

- a bitmask of which hooks installed,
- a monotonic count of frames actually replaced, per sink class,
- the active tier,
- the last error code and its source.

The app then shows a real diagnostics screen instead of the user guessing. This is
what turns "it doesn't work" into "tier 0 installed 4 of 5 hooks and has replaced
0 frames, so we escalated to tier 1."

### 4.2 End-to-end self-test — MEDIUM

A **Test VCam** button in the app: run an `AVCaptureSession` against ourselves,
capture one frame, compare it to the source media, report pass/fail per path
(preview, data output, photo). Upstream ships a self-verifying harness that
checks advertised-vs-delivered format, BT.709 correctness at patch centres,
format-description extensions, and timing monotonicity. The same checks belong
here, runnable on-device by the user.

---

## 5. Things we researched and correctly did not need

Worth recording so they are not re-litigated.

- **Thread quiescing** (`task_threads` + `thread_suspend` during code patching).
  Necessary for inline function hooking that rewrites instructions. We use
  Objective-C method swizzling, which swaps an IMP pointer atomically. Not needed
  — *unless* we later add `MSHookFunction` on a C function such as a
  `FigCapture*` entry point, at which point it becomes mandatory.
- **IOSurface three-slot XPC rotation.** Relevant to moving frames *between*
  processes. We replace in-place inside the daemon, so the sink's own transport
  handles it. Becomes relevant if the client-side tiers need their own transport.

---

## 6. New risk to avoid in client-side work

`VCamClient` loads into every process linking AVFoundation — which on a modern
system includes SpringBoard, PosterBoard, AccessibilityUIServer, InputUI and most
widget extensions. Upstream shipped a 1 Hz preview-layer scan armed on load in all
of them and measured substantial idle wakeups in `AccessibilityUIServer` and
`InputUI` over fifteen idle minutes.

Any periodic client-side work must be armed only while a session using the
virtual camera is actually running, never on load.

---

## 7. Priority order

**P0 — safety and silent failure (this commit)**
1. Metal setup out of the constructor (§3.1)
2. libSandy actually applied (§3.2)
3. shared-memory magic and version (§3.3)

**P1 — make real apps work**
4. Per-connection geometry and format (§2.1)
5. Diagnostics in shared memory + app screen (§4.1)
6. Tier 1 and tier 2 daemon fallbacks (§4)
7. Colour attachments and format extensions (§2.3)
8. `CVPixelBufferPool` (§3.5)

**P2 — coverage**
9. Client-side library: tiers 3 to 5 (§2.7, §4)
10. Synthetic source and stream publication (§2.2)
11. `BWStillImageScalerNode` (§2.4)
12. End-to-end self-test (§4.2)

**P3 — features**
13. Virtual microphone, client-side (§2.6)
14. Movie recording (§2.5)
15. Stale-frame watchdog (§3.8)

**Research before building**
- `FigCaptureSourceBackingsProvider` on iOS 26, `_sSourceList` on 27 → §2.2
- Resolving a sink's client PID to a bundle ID → §3.6
- Audio graph injection daemon-side, if client-side proves insufficient → §2.6
- Confirming the `BW*` class set is unchanged on iOS 26.x on a real device
