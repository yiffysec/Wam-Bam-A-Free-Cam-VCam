# Wam Bam A Free Cam

A virtual camera for jailbroken iOS that actually works, and is actually free.

Point it at a video or a photo and every app that opens the camera sees your
media instead — the stock Camera app, Snapchat, Instagram, FaceTime, a KYC flow,
whatever. System-wide or only in the apps you pick.

Built because the paid "virtual camera" tweaks going around are, in the main,
broken: they hook `mediaserverd` on an OS where the capture graph no longer
lives there, deliver BGRA into a sink that wants NV12, and never drive the
third-party delivery path at all. This repository is the working version, with
the reasoning written down so nobody has to pay for a black rectangle again.

**Status:** complete implementation, not yet device-validated. See
[Current state](#current-state).

---

## Supported

| | |
|---|---|
| **iOS** | 15, 16, 17, 18, 26+ |
| **Jailbreaks** | Dopamine 2 / 3, rootless, rootful, roothide |
| **Architectures** | arm64, arm64e |
| **Injection** | ElleKit, Substrate, Substitute |

On iOS 18 and newer the capture graph lives in a dedicated `cameracaptured`
daemon. On iOS 17 and earlier it is inside `mediaserverd`. The host dylib is
injected into both and picks its target at runtime, so one package covers every
supported release.

---

## Features

**Media**
- Video sources, decoded at 30 fps and looped seamlessly
- Photo sources, delivered as a still frame
- Import from Photos (`PHPicker`) or from Files (`UIDocumentPicker`)
- Atomic import — the daemon never opens a half-written file

**Framing**
- Fill (crop to the camera's aspect ratio, so no black bars are ever visible)
- Fit (letterbox, composited over real black rather than undefined pixels)
- Stretch
- Rotation at 0° / 90° / 180° / 270°, for landscape footage on a portrait sensor
- Horizontal and vertical mirroring
- Zoom and pan

**Audio**
- Keep the real microphone (apps hear your surroundings, see your media)
- Or substitute a custom audio file

**Targeting**
- System-wide, or
- Per-app allow-list, with a searchable list of every installed app

**Control surfaces** — three, in descending order of convenience and ascending
order of reliability:
1. Optional floating SpringBoard HUD: draggable, one-tap on/off/pause/mirror,
   hides itself in the app switcher and on the lock screen
2. Settings pane via PreferenceLoader
3. The companion app, which can do everything

**Safety**
- Boot-loop kill switch with a crash counter (details below)
- Every hook independently verified before installation, and individually
  skippable if a signature moved
- Daemon restart button, so a missed change never needs a reboot

---

## The HUD is optional, by design

Some roothide configurations do not inject into SpringBoard. Users remove
components. Windows fail to attach to a scene. So the HUD is never load-bearing.

The app probes it explicitly over Darwin notifications:

```
app                                      SpringBoard
 |  clear hudAlive in shared memory           |
 |  notify_post(hud-ping)  ----------------->  |
 |                                             |  stamp hudHeartbeat
 |                                             |  set hudAlive = 1
 |  <------------------  notify_post(hud-pong) |
 |  resolve: AVAILABLE                         |
```

No pong inside 1.25 s and no fresh heartbeat in shared memory means the HUD is
unavailable. The app then:

- shows a banner explaining that it is driving everything itself,
- keeps every single control reachable in-app — nothing is HUD-only, and
- still offers the **Show HUD** toggle as a manual override, because detection
  can be wrong on an unusual setup and flipping it costs nothing.

SpringBoard starts answering probes as soon as the dylib loads, before the window
exists, so a hidden HUD is never mistaken for a missing one.

---

## How it works

### Where to hook

Every camera frame in iOS passes through the `BW*` node graph in
`CMCapture.framework` (`Celestial.framework` before iOS 14). Five points matter:

| Hook | Purpose | Pixel format |
|---|---|---|
| `BWNodeOutput -emitSampleBuffer:` | universal; used to learn sensor geometry | — |
| `BWImageQueueSinkNode -renderSampleBuffer:forInput:` | in-process delivery | `420v` |
| `BWRemoteQueueSinkNode -renderSampleBuffer:forInput:` | third-party apps over XPC | `420v` |
| `BWPhotoEncoderNode -renderSampleBuffer:forInput:` | photo capture | `420v` |
| `BWStillImageSampleBufferSinkNode -renderSampleBuffer:forInput:` | still delivery | **BGRA** |

Getting that last column wrong is the single most common cause of a black
preview. Video sinks want
`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`; still sinks want BGRA. The
frame engine keeps both ready at all times.

### The boot-loop trap

`-[BWStillImageSampleBufferSinkNode initWithInputMediaType:sinkID:]` takes an
`OSType` — a `uint32` FourCC, `'vide'` is `0x76696465` — as its first argument.
It is **not** an Objective-C object.

Hook it with an `id` parameter and ARC retains the integer `0x76696465` as if it
were a pointer. That dereferences unmapped memory inside `cameracaptured`, which
crashes. SpringBoard waits synchronously on `cameracaptured`'s torch XPC service
during startup, so a crash loop there hangs the device at the Apple logo.

This is where the "virtual camera bricked my phone" reports come from.

**This project never hooks that initialiser.** Only
`renderSampleBuffer:forInput:` is hooked, whose signature is object-typed and
stable from iOS 15 through 26. On top of that, before any hook is installed:

- the class must exist,
- the selector must exist,
- its argument count must be 4, and
- its return type must be `void`.

A signature that moved in a future iOS release degrades into "this one hook is
skipped and logged", never into a crash.

### Why third-party apps go black elsewhere

`BWRemoteQueueSinkNode` feeds apps outside the daemon. Replacing frames only as
they arrive is not enough: when the real graph stalls or throttles, the app
receives one frozen frame or nothing. The frame engine therefore pushes into
every registered remote sink on its own 30 Hz timer, straight to the original
implementation, with host-clock timestamps so the stream stays strictly
monotonic across loop boundaries.

The engine also refuses to forward a planar buffer whose chroma plane is
missing — another classic source of a green or black image.

### Per-app targeting

`cameracaptured` serves every app from one process, so the daemon alone cannot
tell which app a frame is bound for without reaching into private client-identity
structures that move between releases.

Instead a small dylib (`VCamClient`) rides along inside apps, and when an app
actually starts a capture session it publishes the verdict for its own bundle ID
into shared memory. The daemon just honours that flag. In system-wide mode the
flag is ignored entirely, so a failure to load `VCamClient` cannot break the
common case.

### IPC

Two tiers, deliberately:

- **Hot path:** a 64-byte seqlock-protected `mmap` region, one cache line,
  read by the daemon on every frame. A toggle in the HUD or the app takes effect
  on the next frame with no XPC hop.
- **Durable:** `Config.plist`, written atomically, surviving reboots and
  readable from the Settings pane.

Changes are signalled with Darwin notifications and backed by a 0.5 s poll, so a
notification dropped under memory pressure costs half a second, not a restart.

### Colour

BGRA → NV12 conversion runs as a Metal compute kernel using the BT.709
video-range matrix (Y in 16–235, chroma in 16–240), with 2×2 averaging for the
half-resolution chroma plane. Using BT.601, or full range, is what produces the
washed-out or oddly-tinted output seen in other implementations.

### Not getting killed

`cameracaptured` has a tight jetsam budget. The engine holds at most three
`CVPixelBuffer`s, decodes just in time rather than in bulk, never retains a
camera-vended buffer, and releases replaced frames outside its lock so a sink
mid-drain is never left holding freed memory.

---

## Boot-loop protection

Injecting into the process SpringBoard waits on at startup deserves more than
hope. Order of operations in the dylib constructor:

1. Bail out unless we are genuinely in a camera daemon.
2. **Consult the boot guard before anything else** — before any allocation or
   hook.
3. Detect the OS version and confirm this process is the capture host.
4. Open shared memory; give up quietly if unavailable.
5. Bring up Metal and resolve the media source.
6. Install hooks, each verified and individually skippable.
7. Subscribe to configuration changes.
8. Start the frame pump.
9. Tell the boot guard we survived, clearing the crash counter.

The guard writes a stamp file at step 2 and removes it at step 9. A stamp found
on the next launch means the previous run died in between. Three of those inside
the window and the guard writes a kill switch, after which step 2 refuses
injection entirely.

Recovering needs no SSH and no restore: clear the kill switch from the companion
app or from Settings. Uninstalling engages it first, so the window between file
removal and daemon restart cannot inject either.

---

## Building

Requires [Theos](https://theos.dev). For roothide, use the
[roothide fork](https://github.com/roothide/theos) — it rewrites paths through
`jbroot()`.

```bash
git clone https://github.com/yiffysec/Wam-Bam-A-Free-Cam-VCam
cd Wam-Bam-A-Free-Cam-VCam

make package                                  # roothide (default)
make package THEOS_PACKAGE_SCHEME=rootless    # Dopamine, Xina, palera1n rootless
make package THEOS_PACKAGE_SCHEME=            # rootful
```

The `.deb` lands in `packages/`. CI builds all three schemes on every push; see
`.github/workflows/build.yml`.

### Components

| Target | Installs to | Role |
|---|---|---|
| `WBFCVCamHost` | camera daemon | the frame replacement engine |
| `WBFCVCamClient` | every app | publishes the per-app verdict |
| `WBFCVCamSpring` | SpringBoard | the optional HUD |
| `WamBamVCam.app` | `/Applications` | the authoritative control surface |
| `WamBamVCamPrefs` | PreferenceLoader | the Settings pane |

### Layout

```
Shared/           state, config, HUD bridge, boot guard — used by every component
VCamHost/         the daemon dylib: hooks, frame engine, pixel conversion
VCamClient/       per-app gating, injected into apps
VCamSpringBoard/  the floating HUD
VCamPrefs/        Settings pane
VCamApp/          companion app
layout/           package payload and maintainer scripts
```

---

## Using it

1. Install the `.deb` for your jailbreak. The camera daemon restarts
   automatically; no respring needed.
2. Open **Wam Bam VCam**.
3. **Media Source → Choose Video or Photo**, and pick something.
4. Toggle **Enable VCam**.
5. Open any camera app.

If the preview looks wrong, the fix is almost always in **Framing**: try
**Rotation 90°** for landscape footage, and **Fill** rather than **Fit** if you
are seeing bars.

Not working at all? Check these in order:
- Is media actually selected? (**Status** says `No media selected` if not.)
- Is the kill switch engaged? (**Safety → Kill Switch**.)
- Is Per-App Mode on with the app you are testing not in the list?
- Try **Safety → Restart Camera Daemon**.

---

## Current state

Everything described above is implemented, and not yet validated on physical
hardware.

**[`docs/AUDIT.md`](docs/AUDIT.md) is the honest account** — a full review of
what works, what is missing, and what to build next, in priority order. Read it
before relying on this or sending a patch. The short version:

Confirmed gaps that will make real apps fail:

- **Per-connection geometry and pixel format.** We derive one output size
  globally instead of per sink invocation, so a client that asked for 640×480 or
  for BGRA on a video path gets the wrong shape.
- **No synthetic source or stream publication.** Some clients never build a
  capture graph without one; front-camera sessions in particular can end up with
  no device at all.
- **No client-side component.** Apps that use only `AVCaptureVideoPreviewLayer`
  with no data output can still show the real camera, and there is a window at
  session start before the graph exists.

Known missing features: virtual microphone (config and UI exist, no hook yet —
real-mic pass-through works), movie recording in Camera.app, and the
`BWStillImageScalerNode` photo-scaling path.

Missing infrastructure: there is **no redundancy**. Every capability has exactly
one implementation, and a failed hook is logged and skipped rather than falling
back. The audit proposes a six-tier scheme with a health arbiter; none of it is
built yet.

Logs go to the unified log under subsystem `com.yiffysec.wambamvcam`:

```bash
log stream --predicate 'subsystem == "com.yiffysec.wambamvcam"' --level debug
```

Issues and PRs welcome, particularly device reports: iOS version, jailbreak,
device, and what you saw.

---

## License

MIT. Free as in free — see [LICENSE](LICENSE).

## Thanks

To everyone who published their findings on the `BW*` graph, the `OSType` ABI
trap, and the third-party delivery path. Standing on those shoulders is the only
reason this exists.
