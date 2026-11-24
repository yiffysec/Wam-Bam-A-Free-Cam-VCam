// VCamSharedState.c -- Seqlock-protected shared memory IPC
//
// File-backed mmap at kVCamShmPath so the region survives individual process
// restarts within a boot. MAP_SHARED, so a write from the app or SpringBoard
// is visible to cameracaptured on its very next frame without any XPC hop.

#include "VCamSharedState.h"
#include "VCamTypes.h"

#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <notify.h>

#define kVCamStateBodyOffset (offsetof(VCamSharedState, enabled))
#define kVCamStateBodySize   (sizeof(VCamSharedState) - kVCamStateBodyOffset)

static VCamSharedRegion *g_region = NULL;
static VCamSharedState  *g_shm    = NULL;   // &g_region->state, for brevity
static size_t            g_shmsz  = 0;

static void vcam_shm_reinit_locked(void);

// -- vcam_shm_open --------------------------------------------------------
int vcam_shm_open(void) {
    if (g_shm) return 0;

    mkdir(kVCamLibraryDir, 0755);

    int fd = open(kVCamShmPath, O_RDWR | O_CREAT, 0666);
    if (fd < 0) {
        VCamLogE("shm_open: open(%{public}s) failed errno=%d", kVCamShmPath, errno);
        return -1;
    }

    g_shmsz = sizeof(VCamSharedRegion);

    struct stat st;
    if (fstat(fd, &st) == 0 && (size_t)st.st_size < g_shmsz) {
        if (ftruncate(fd, (off_t)g_shmsz) != 0) {
            VCamLogE("shm_open: ftruncate failed errno=%d", errno);
            close(fd);
            return -1;
        }
    }

    void *map = mmap(NULL, g_shmsz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (map == MAP_FAILED) {
        VCamLogE("shm_open: mmap failed errno=%d", errno);
        return -1;
    }

    g_region = (VCamSharedRegion *)map;
    g_shm    = &g_region->state;

    // Validate the header. A fresh file reads as all zeroes, and a file written
    // by a different build of this struct reads as the wrong layout -- in which
    // case every field, `enabled` included, is garbage. Reinitialise rather than
    // trust it.
    if (g_shm->magic      != kVCamShmMagic   ||
        g_shm->version    != kVCamShmVersion ||
        g_shm->structSize != (uint16_t)sizeof(VCamSharedRegion)) {

        if (g_shm->magic != 0 || g_shm->version != 0) {
            VCamLogI("shm_open: header mismatch "
                     "(magic=0x%08x ver=%u size=%u; expected 0x%08x/%u/%zu) -- "
                     "reinitialising",
                     g_shm->magic, g_shm->version, g_shm->structSize,
                     kVCamShmMagic, kVCamShmVersion, sizeof(VCamSharedRegion));
        }
        vcam_shm_reinit_locked();
    }

    VCamLogI("shm_open: mapped %zu bytes at %p (v%u)",
             g_shmsz, (void *)g_shm, g_shm->version);
    return 0;
}

// -- vcam_shm_reinit_locked -----------------------------------------------
// Zeroes the region, stamps the header and seeds defaults. A zoom of 0 would
// divide by zero in the frame engine, and an all-zero state would also leave
// the HUD disabled and the microphone replaced, neither of which is a sane
// default for a fresh install.
static void vcam_shm_reinit_locked(void) {
    if (!g_region) return;

    memset(g_region, 0, sizeof(VCamSharedRegion));

    g_shm->magic      = kVCamShmMagic;
    g_shm->version    = kVCamShmVersion;
    g_shm->structSize = (uint16_t)sizeof(VCamSharedRegion);

    g_shm->zoom         = kVCamDefaultZoom;
    g_shm->hudEnabled   = 1;
    g_shm->useRealAudio = 1;

    // Start even, so the first reader sees a stable value.
    atomic_store_explicit(&g_shm->seq, 2u, memory_order_release);
}

// -- vcam_shm_close -------------------------------------------------------
void vcam_shm_close(void) {
    if (g_region) {
        munmap(g_region, g_shmsz);
        g_region = NULL;
        g_shm    = NULL;
        g_shmsz  = 0;
    }
}

// -- vcam_shm_ptr ---------------------------------------------------------
VCamSharedState *vcam_shm_ptr(void) {
    return g_shm;
}

VCamDiagnostics *vcam_shm_diag_ptr(void) {
    return g_region ? &g_region->diag : NULL;
}

// -- vcam_shm_read (seqlock read) -----------------------------------------
void vcam_shm_read(VCamSharedState *out) {
    if (!out) return;

    // Not mapped, or mapped over a region another process is mid-reinitialise
    // on: return safe defaults rather than a garbage `enabled`.
    if (!g_shm ||
        g_shm->magic   != kVCamShmMagic ||
        g_shm->version != kVCamShmVersion) {
        memset(out, 0, sizeof(*out));
        out->zoom = kVCamDefaultZoom;
        return;
    }

    // Written as an explicit loop rather than do/while. An earlier version used
    // `continue` for the odd-sequence case, which jumped straight to a
    // `while (seq1 != seq2)` test with seq2 still uninitialised -- so if the
    // stack garbage happened to match seq1 the loop exited and the caller got
    // an unvalidated copy, `enabled` included. In the camera daemon that reads
    // as the virtual camera turning itself on or off at random.
    for (int spins = 0; spins < 1000; spins++) {
        uint32_t seq1 = atomic_load_explicit(&g_shm->seq, memory_order_acquire);

        // Odd means a writer is mid-update. Retry.
        if (seq1 & 1u) continue;

        memcpy((uint8_t *)out   + kVCamStateBodyOffset,
               (uint8_t *)g_shm + kVCamStateBodyOffset,
               kVCamStateBodySize);

        atomic_thread_fence(memory_order_acquire);

        uint32_t seq2 = atomic_load_explicit(&g_shm->seq, memory_order_acquire);
        if (seq1 != seq2) continue;   // torn read; the writer moved under us

        out->seq = seq1;

        // A corrupt or never-initialised region must not divide by zero in the
        // frame engine.
        if (!(out->zoom > 0.0f)) out->zoom = kVCamDefaultZoom;
        return;
    }

    // Spun out. A writer holding the lock this long means something is very
    // wrong, and safe defaults beat a torn read.
    VCamLogE("shm_read: spun out waiting for a stable sequence");
    memset(out, 0, sizeof(*out));
    out->zoom = kVCamDefaultZoom;
}

// -- internal writer ------------------------------------------------------
static void vcam_shm_write_impl(const VCamSharedState *in, int notify) {
    if (!g_shm || !in) return;

    // Move to the next odd value: readers treat odd as "write in progress".
    uint32_t cur = atomic_load_explicit(&g_shm->seq, memory_order_relaxed);
    uint32_t odd = cur + 1u;
    if ((odd & 1u) == 0) odd += 1u;

    atomic_store_explicit(&g_shm->seq, odd, memory_order_release);
    atomic_thread_fence(memory_order_release);

    memcpy((uint8_t *)g_shm + kVCamStateBodyOffset,
           (const uint8_t *)in + kVCamStateBodyOffset,
           kVCamStateBodySize);

    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&g_shm->seq, odd + 1u, memory_order_release);

    if (notify) vcam_notify_post(kVCamNotifyConfigChanged);
}

void vcam_shm_write(const VCamSharedState *in) {
    vcam_shm_write_impl(in, 1);
}

void vcam_shm_write_quiet(const VCamSharedState *in) {
    vcam_shm_write_impl(in, 0);
}

// -- notifications --------------------------------------------------------
void vcam_notify_post(const char *name) {
    if (name) notify_post(name);
}

int vcam_notify_observe(const char *name, dispatch_queue_t queue,
                        void (^block)(void)) {
    if (!name || !block) return -1;
    int token = -1;
    uint32_t st = notify_register_dispatch(name, &token,
                                           queue ?: dispatch_get_main_queue(),
                                           ^(int t) { (void)t; block(); });
    if (st != NOTIFY_STATUS_OK) {
        VCamLogE("notify_observe: register '%{public}s' failed st=%u", name, st);
        return -1;
    }
    return token;
}

void vcam_notify_cancel(int token) {
    if (token >= 0) notify_cancel(token);
}
