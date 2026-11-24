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

static VCamSharedState *g_shm   = NULL;
static size_t           g_shmsz = 0;

// -- vcam_shm_open --------------------------------------------------------
int vcam_shm_open(void) {
    if (g_shm) return 0;

    mkdir(kVCamLibraryDir, 0755);

    int fd = open(kVCamShmPath, O_RDWR | O_CREAT, 0666);
    if (fd < 0) {
        VCamLogE("shm_open: open(%{public}s) failed errno=%d", kVCamShmPath, errno);
        return -1;
    }

    g_shmsz = sizeof(VCamSharedState);

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

    g_shm = (VCamSharedState *)map;

    // First-ever map of a fresh file: zoom of 0.0 would divide-by-zero in the
    // frame engine, so seed sane defaults exactly once.
    if (g_shm->zoom == 0.0f) {
        g_shm->zoom       = kVCamDefaultZoom;
        g_shm->hudEnabled = 1;
        g_shm->useRealAudio = 1;
    }

    VCamLogI("shm_open: mapped %zu bytes at %p", g_shmsz, (void *)g_shm);
    return 0;
}

// -- vcam_shm_close -------------------------------------------------------
void vcam_shm_close(void) {
    if (g_shm) {
        munmap(g_shm, g_shmsz);
        g_shm   = NULL;
        g_shmsz = 0;
    }
}

// -- vcam_shm_ptr ---------------------------------------------------------
VCamSharedState *vcam_shm_ptr(void) {
    return g_shm;
}

// -- vcam_shm_read (seqlock read) -----------------------------------------
void vcam_shm_read(VCamSharedState *out) {
    if (!out) return;

    if (!g_shm) {
        memset(out, 0, sizeof(*out));
        out->zoom = kVCamDefaultZoom;
        return;
    }

    uint32_t seq1, seq2;
    int spins = 0;
    do {
        seq1 = atomic_load_explicit(&g_shm->seq, memory_order_acquire);
        if (seq1 & 1u) {
            // Writer mid-update. Yield rather than burn the frame deadline.
            if (++spins > 1000) {
                memset(out, 0, sizeof(*out));
                out->zoom = kVCamDefaultZoom;
                return;
            }
            continue;
        }
        memcpy((uint8_t *)out   + kVCamStateBodyOffset,
               (uint8_t *)g_shm + kVCamStateBodyOffset,
               kVCamStateBodySize);
        atomic_thread_fence(memory_order_acquire);
        seq2 = atomic_load_explicit(&g_shm->seq, memory_order_acquire);
    } while (seq1 != seq2);

    out->seq = seq1;

    // Defensive: a corrupt or never-initialised region must not divide by zero.
    if (!(out->zoom > 0.0f)) out->zoom = kVCamDefaultZoom;
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
