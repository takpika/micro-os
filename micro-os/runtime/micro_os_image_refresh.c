// Fresh per-process __DATA for reused pool images.
//
// On a real device the loader can't give each process a private dylib copy (code
// signing) nor unload one (iOS dyld keeps images mapped across dlclose), so a
// device "framework pool" slot reuses the SAME signed image for successive
// processes. That breaks programs that keep mutable state in globals — toybox's
// toys/this/toybuf, and the CRT/libc shim's per-image state — because the next
// process inherits the previous one's leftovers.
//
// This snapshots a freshly-loaded image's writable data segments (the pristine
// post-load __DATA/__bss, before any process has run) the first time the loader
// prepares it, and restores that snapshot on every reuse — so a reused image
// behaves exactly like a freshly loaded one. It is generic (no program-specific
// knowledge) and keyed by mach_header, which is stable for the image's lifetime.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/vm_prot.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MICRO_OS_MAX_IMAGES 512
#define MICRO_OS_MAX_SEGS 4

struct image_snapshot {
    const struct mach_header *header;
    int nseg;
    struct { uint8_t *addr; size_t size; } seg[MICRO_OS_MAX_SEGS];
    uint8_t *blob;       // pristine bytes, segments concatenated
};

static struct image_snapshot g_snaps[MICRO_OS_MAX_IMAGES];
static int g_count;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// vmaddr slide for an already-loaded image, or 0 with *ok=0 if not found.
static intptr_t slide_for(const struct mach_header *mh, int *ok) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if (_dyld_get_image_header(i) == mh) { *ok = 1; return _dyld_get_image_vmaddr_slide(i); }
    }
    *ok = 0;
    return 0;
}

// Collect the image's writable data segments (globals + zero-filled __bss live
// here; __DATA_CONST is read-only after load and intentionally skipped).
static int collect(const struct mach_header *mh, intptr_t slide, struct image_snapshot *s) {
    if (mh->magic != MH_MAGIC_64) return 0;
    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)mh + sizeof(struct mach_header_64));
    s->nseg = 0;
    for (uint32_t i = 0; i < mh->ncmds && s->nseg < MICRO_OS_MAX_SEGS; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            if ((sc->initprot & VM_PROT_WRITE) && sc->vmsize > 0 &&
                (strcmp(sc->segname, "__DATA") == 0 || strcmp(sc->segname, "__DATA_DIRTY") == 0)) {
                s->seg[s->nseg].addr = (uint8_t *)(uintptr_t)(sc->vmaddr + slide);
                s->seg[s->nseg].size = (size_t)sc->vmsize;
                s->nseg++;
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return s->nseg;
}

// Make `header`'s data segments pristine for the process about to run: snapshot
// on first sighting (the image is still untouched), restore on every reuse.
void micro_os_image_refresh(const struct mach_header *header) {
    if (!header) return;
    pthread_mutex_lock(&g_lock);

    for (int i = 0; i < g_count; i++) {
        if (g_snaps[i].header == header) {
            struct image_snapshot *s = &g_snaps[i];
            size_t off = 0;
            for (int j = 0; j < s->nseg; j++) {
                memcpy(s->seg[j].addr, s->blob + off, s->seg[j].size);
                off += s->seg[j].size;
            }
            pthread_mutex_unlock(&g_lock);
            return;
        }
    }

    if (g_count < MICRO_OS_MAX_IMAGES) {
        int ok = 0;
        intptr_t slide = slide_for(header, &ok);
        struct image_snapshot *s = &g_snaps[g_count];
        s->header = header;
        if (ok && collect(header, slide, s) > 0) {
            size_t total = 0;
            for (int j = 0; j < s->nseg; j++) total += s->seg[j].size;
            s->blob = (uint8_t *)malloc(total);
            if (s->blob) {
                size_t off = 0;
                for (int j = 0; j < s->nseg; j++) {
                    memcpy(s->blob + off, s->seg[j].addr, s->seg[j].size);
                    off += s->seg[j].size;
                }
                g_count++;
            }
        }
    }
    pthread_mutex_unlock(&g_lock);
}
