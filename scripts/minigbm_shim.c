/* libminigbm.so — drop-in replacement for the ChromeOS minigbm.
 *
 * Chrome is built against ChromeOS' minigbm (DT_NEEDED: libminigbm.so), but
 * this host only has Mesa's libgbm. Dropping Mesa's .so in under the minigbm
 * name does not work: minigbm knows about DRM usages and import types that
 * Mesa does not, and Mesa's gbm silently returns NULL for them. Symptoms:
 * "Could not find SharedImageBackingFactory", "nullptr returned from
 * gbm_bo_import", and finally white X11 windows.
 *
 * This shim resolves every gbm entry point Chrome imports against the real
 * Mesa library (libgbm.so.1, falling back to libgbm.so) at load time and
 * translates the two incompatible corners:
 *
 *   1. usage flags — minigbm sets bits Mesa does not know (e.g. TEXTURING);
 *      keep the low six bits and force GBM_BO_USE_RENDERING when none of
 *      SCANOUT/CURSOR/RENDERING is set;
 *   2. import types — minigbm's GBM_BO_IMPORT_FD_MODIFIER is 0x5505 while
 *      Mesa's is 0x5504; anything else falls through to Mesa's default
 *      (NULL). On failure we retry with modifier=0 (LINEAR) and then with
 *      the legacy GBM_BO_IMPORT_FD descriptor.
 *
 * It also bridges a Mesa-on-amdgpu quirk: when the GPU process creates its
 * GBM device on the render node, Mesa's GEM handles live in that file's handle
 * table only. amdgpu (unlike i915) has per-file handle tables, so the
 * drmModeAddFB2 that Chrome issues on the card node fails with ENOENT and no
 * scanout buffer is ever created. The ioctl interposer detects that failure,
 * exports each plane via PRIME from the render node and re-imports it into the
 * card node, then retries the same ADDFB2.
 *
 * Everything is logged to /tmp/gbm-shim.log (cleared by the session script
 * on start) — that file is how the failure chain above was diagnosed.
 *
 * Build: cc -shared -fPIC -O2 -o libminigbm.so minigbm_shim.c -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

struct gbm_device;
struct gbm_bo;

union gbm_bo_handle {
  uint32_t u32;
  uint64_t u64;
  void *pointer;
};

/* minigbm vs Mesa import type codes. */
#define MINIGBM_IMPORT_FD_MODIFIER 0x5505
#define MESA_IMPORT_FD_MODIFIER 0x5504
#define MESA_IMPORT_FD 0x5503

/* struct drm_mode_fb_cmd2 from the kernel UAPI; kept local so the shim does
 * not need libdrm headers at build time. */
struct shim_fb_cmd2 {
  uint32_t fb_id;
  uint32_t width;
  uint32_t height;
  uint32_t pixel_format;
  uint32_t flags;
  uint32_t handles[4];
  uint32_t pitches[4];
  uint32_t offsets[4];
  uint64_t modifier[4];
};

/* DRM_IOCTL_MODE_ADDFB2 = _IOWR('d', 0xb8, struct drm_mode_fb_cmd2). */
#define SHIM_DRM_IOCTL_MODE_ADDFB2 \
  _IOWR('d', 0xb8, struct shim_fb_cmd2)

/* PRIME/GEM ioctls, again kept local to avoid a libdrm build dependency. */
struct shim_prime_handle {
  uint32_t handle;
  uint32_t flags;
  int32_t fd;
};

struct shim_gem_close {
  uint32_t handle;
  uint32_t pad;
};

#define SHIM_DRM_IOCTL_PRIME_HANDLE_TO_FD \
  _IOWR('d', 0x2d, struct shim_prime_handle)
#define SHIM_DRM_IOCTL_PRIME_FD_TO_HANDLE \
  _IOWR('d', 0x2e, struct shim_prime_handle)
#define SHIM_DRM_IOCTL_GEM_CLOSE _IOW('d', 0x09, struct shim_gem_close)

/* Bits Mesa's gbm understands; anything above is minigbm-specific. */
#define GBM_USAGE_MASK 0x3f
#define GBM_USAGE_LOW3 0x7 /* SCANOUT | CURSOR | RENDERING */
#define GBM_BO_USE_RENDERING 0x4
#define SHIM_GBM_BO_USE_SCANOUT 0x1

/* Resolved against Mesa in the constructor below; NULL when unavailable. */
static struct gbm_device *(*p_create_device)(int fd);
static void (*p_device_destroy)(struct gbm_device *gbm);
static int (*p_device_is_format_supported)(struct gbm_device *gbm,
                                           uint32_t format,
                                           uint32_t usage);
static struct gbm_bo *(*p_bo_create)(struct gbm_device *gbm, uint32_t width,
                                     uint32_t height, uint32_t format,
                                     uint32_t flags);
static struct gbm_bo *(*p_bo_create_with_modifiers)(
    struct gbm_device *gbm,
    uint32_t width,
    uint32_t height,
    uint32_t format,
    const uint64_t *modifiers,
    size_t count);
static void (*p_bo_destroy)(struct gbm_bo *bo, struct gbm_device *gbm);
static struct gbm_bo *(*p_bo_import)(struct gbm_device *gbm, uint32_t type,
                                     const void *buf, uint32_t flags);
static union gbm_bo_handle (*p_bo_get_handle)(struct gbm_bo *bo);
static union gbm_bo_handle (*p_bo_get_handle_for_plane)(struct gbm_bo *bo,
                                                        int plane);
static uint32_t (*p_bo_get_width)(struct gbm_bo *bo);
static uint32_t (*p_bo_get_height)(struct gbm_bo *bo);
static uint32_t (*p_bo_get_stride)(struct gbm_bo *bo, int plane);
static uint32_t (*p_bo_get_offset)(struct gbm_bo *bo, int plane);
static uint64_t (*p_bo_get_modifier)(struct gbm_bo *bo);
static int (*p_bo_get_plane_count)(struct gbm_bo *bo);
static int (*p_bo_get_plane_fd)(struct gbm_bo *bo, int plane);
static uint64_t (*p_bo_get_plane_size)(struct gbm_bo *bo, int plane);
static int (*p_bo_get_fd_for_plane)(struct gbm_bo *bo, int plane);
static int (*p_bo_get_fd)(struct gbm_bo *bo);
static void *(*p_bo_map)(struct gbm_bo *bo,
                         uint32_t x,
                         uint32_t y,
                         uint32_t width,
                         uint32_t height,
                         uint32_t flags,
                         uint32_t *stride,
                         void *map_data);
static void (*p_bo_unmap)(struct gbm_bo *bo, void *map_data);

/* Real libc ioctl, used by the scanout-format fallback below. */
static int (*p_ioctl)(int fd, unsigned long request, ...);

#define SHIM_LOG_PATH "/tmp/gbm-shim.log"

__attribute__((constructor)) static void shim_init(void) {
  void *h = dlopen("libgbm.so.1", RTLD_NOW);
  if (!h) {
    h = dlopen("libgbm.so", RTLD_NOW);
  }
  if (!h) {
    return;
  }

#define RESOLVE(name, var) var = (__typeof__(var))dlsym(h, name)
  RESOLVE("gbm_create_device", p_create_device);
  RESOLVE("gbm_device_destroy", p_device_destroy);
  RESOLVE("gbm_device_is_format_supported", p_device_is_format_supported);
  RESOLVE("gbm_bo_create", p_bo_create);
  RESOLVE("gbm_bo_create_with_modifiers", p_bo_create_with_modifiers);
  RESOLVE("gbm_bo_destroy", p_bo_destroy);
  RESOLVE("gbm_bo_import", p_bo_import);
  RESOLVE("gbm_bo_get_handle", p_bo_get_handle);
  RESOLVE("gbm_bo_get_handle_for_plane", p_bo_get_handle_for_plane);
  RESOLVE("gbm_bo_get_width", p_bo_get_width);
  RESOLVE("gbm_bo_get_height", p_bo_get_height);
  RESOLVE("gbm_bo_get_stride_for_plane", p_bo_get_stride);
  RESOLVE("gbm_bo_get_offset", p_bo_get_offset);
  RESOLVE("gbm_bo_get_modifier", p_bo_get_modifier);
  RESOLVE("gbm_bo_get_plane_count", p_bo_get_plane_count);
  RESOLVE("gbm_bo_get_plane_fd", p_bo_get_plane_fd);
  RESOLVE("gbm_bo_get_plane_size", p_bo_get_plane_size);
  RESOLVE("gbm_bo_get_fd_for_plane", p_bo_get_fd_for_plane);
  RESOLVE("gbm_bo_get_fd", p_bo_get_fd);
  RESOLVE("gbm_bo_map", p_bo_map);
  RESOLVE("gbm_bo_unmap", p_bo_unmap);
#undef RESOLVE

  p_ioctl = (__typeof__(p_ioctl))dlsym(RTLD_NEXT, "ioctl");
}

/* Append-only diagnostic log; a failed open/write is silently ignored. */
static void shim_log(const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n <= 0) {
    return;
  }
  /* vsnprintf returns the length it *wanted* to write; on truncation that can
   * exceed sizeof(buf). Clamp before write(), otherwise we'd read past the
   * end of our own 512-byte stack buffer. */
  if ((size_t)n >= sizeof(buf)) {
    n = (int)sizeof(buf) - 1;
  }
  int fd = open(SHIM_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0666);
  if (fd < 0) {
    return;
  }
  write(fd, buf, (size_t)n);
  close(fd);
}

/* Drop minigbm-only usage bits; make sure the buffer is at least renderable.
 * A zero usage stays zero (callers distinguish "no flags" from "masked"). */
static uint64_t mask_usage(uint32_t usage) {
  if (!usage) {
    return 0;
  }
  uint64_t masked = usage & GBM_USAGE_MASK;
  if ((usage & GBM_USAGE_LOW3) == 0) {
    masked |= GBM_BO_USE_RENDERING;
  }
  return masked;
}

/* Little-endian byte `i` of a DRM fourcc, for the '%c%c%c%c' log fields. */
static char fourcc_char(uint32_t format, int i) {
  return (char)(format >> (8 * i));
}

/* i915's primary plane only exposes alpha-less RGB formats (XR24/XB24 on
 * Haswell). Chrome asks for an ARGB8888 scanout buffer (BGRA_8888);
 * drmModeAddFB2 then fails with EINVAL for the X-tiled buffer, the compositor
 * never gets a framebuffer to flip, and the screen stays on the initial black
 * buffer while the hardware cursor still moves.
 *
 * ARGB8888 and XRGB8888 have the same memory layout (B,G,R,A vs B,G,R,X),
 * bpp and tiling, so the same buffer can be described as XRGB for scanout;
 * the primary plane ignores the alpha byte. Retry only after the kernel
 * rejects an alpha-format *tiled* framebuffer, which leaves the cursor
 * (linear AR24) and every working path untouched. */
static uint32_t alpha_less_format(uint32_t format) {
  switch (format) {
    case 0x34325241: /* 'AR24' ARGB8888 */
      return 0x34325258; /* 'XR24' XRGB8888 */
    case 0x34324241: /* 'AB24' ABGR8888 */
      return 0x34324258; /* 'XB24' XBGR8888 */
    case 0x30335241: /* 'AR30' ARGB2101010 */
      return 0x30335258; /* 'XR30' XRGB2101010 */
    case 0x30334241: /* 'AB30' ABGR2101010 */
      return 0x30334258; /* 'XB30' XBGR2101010 */
    default:
      return format;
  }
}

/* Real path of the DRM device directory shared by all nodes of one GPU, e.g.
 * /sys/devices/pci.../drm for both card1 and renderD128. */
static int drm_device_dir(int fd, char *out, size_t out_len) {
  char link[64];
  char path[PATH_MAX];
  char sysfs[PATH_MAX];
  char resolved[PATH_MAX];
  const char *base;
  ssize_t n;

  snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
  n = readlink(link, path, sizeof(path) - 1);
  if (n <= 0)
    return 0;
  path[n] = '\0';
  base = strrchr(path, '/');
  base = base ? base + 1 : path;
  if (strlen(base) >= 64)
    return 0;
  snprintf(sysfs, sizeof(sysfs), "/sys/class/drm/%s/device", base);
  if (!realpath(sysfs, resolved))
    return 0;
  if ((size_t)snprintf(out, out_len, "%s", resolved) >= out_len)
    return 0;
  return 1;
}

/* GBM devices opened by this process. A GEM handle is only meaningful in the
 * DRM file that created it, so the ADDFB2 fallback must export from the exact
 * fd Chrome passed to gbm_create_device. Entries are validated against st_rdev
 * on use in case the number was reused. */
struct gbm_fd_entry {
  int fd;
  dev_t rdev;
  char device[PATH_MAX];
  char devpath[64];
  void *dev;
};

#define MAX_GBM_FDS 8
static struct gbm_fd_entry gbm_fds[MAX_GBM_FDS];
static int gbm_fd_count;

static void register_gbm_fd(int fd, void *dev) {
  struct stat st;
  char device[PATH_MAX];
  char link[64];
  char devpath[64] = "?";
  ssize_t n;
  int i;

  if (fd < 0 || fstat(fd, &st) < 0 ||
      !drm_device_dir(fd, device, sizeof(device)))
    return;
  snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
  n = readlink(link, devpath, sizeof(devpath) - 1);
  if (n > 0)
    devpath[n] = '\0';
  for (i = 0; i < gbm_fd_count; i++) {
    if (gbm_fds[i].fd == fd) {
      gbm_fds[i].rdev = st.st_rdev;
      gbm_fds[i].dev = dev;
      snprintf(gbm_fds[i].device, sizeof(gbm_fds[i].device), "%s", device);
      snprintf(gbm_fds[i].devpath, sizeof(gbm_fds[i].devpath), "%s", devpath);
      return;
    }
  }
  if (gbm_fd_count == MAX_GBM_FDS) {
    memmove(&gbm_fds[0], &gbm_fds[1],
            sizeof(gbm_fds[0]) * (MAX_GBM_FDS - 1));
    gbm_fd_count--;
  }
  gbm_fds[gbm_fd_count].fd = fd;
  gbm_fds[gbm_fd_count].rdev = st.st_rdev;
  gbm_fds[gbm_fd_count].dev = dev;
  snprintf(gbm_fds[gbm_fd_count].device, sizeof(gbm_fds[gbm_fd_count].device),
           "%s", device);
  snprintf(gbm_fds[gbm_fd_count].devpath,
           sizeof(gbm_fds[gbm_fd_count].devpath), "%s", devpath);
  gbm_fd_count++;
}

/* Node name ("card1", "renderD128") for a gbm device, or "?" if unknown. */
static const char *gbm_dev_name(void *dev) {
  int i;

  for (i = 0; i < gbm_fd_count; i++) {
    if (gbm_fds[i].dev == dev) {
      const char *slash = strrchr(gbm_fds[i].devpath, '/');
      return slash ? slash + 1 : gbm_fds[i].devpath;
    }
  }
  return "?";
}

/* Export `handle` from a GBM fd of the same GPU as `card_dev`; returns the
 * dmabuf or -1. Newest fd first — the scanout device is usually the latest. */
static int export_handle(const char *card_dev, uint32_t handle) {
  struct stat st;
  int i;

  for (i = gbm_fd_count - 1; i >= 0; i--) {
    struct shim_prime_handle ph;

    if (fstat(gbm_fds[i].fd, &st) < 0 || st.st_rdev != gbm_fds[i].rdev)
      continue;
    if (strcmp(gbm_fds[i].device, card_dev) != 0)
      continue;
    memset(&ph, 0, sizeof(ph));
    ph.handle = handle;
    ph.flags = O_CLOEXEC;
    if (p_ioctl(gbm_fds[i].fd, SHIM_DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph) == 0 &&
        ph.fd >= 0)
      return ph.fd;
  }
  return -1;
}

/* Is `handle` already in the card file's handle table? */
static int handle_on_fd(int fd, uint32_t handle) {
  struct shim_prime_handle ph;

  memset(&ph, 0, sizeof(ph));
  ph.handle = handle;
  ph.flags = O_CLOEXEC;
  if (p_ioctl(fd, SHIM_DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph) < 0 || ph.fd < 0)
    return 0;
  close(ph.fd);
  return 1;
}

/* Move ADDFB2's buffers from the GBM device's handle table into the card
 * file's, then retry the ioctl in place. amdgpu keeps per-file GEM handle
 * tables, so handles from a render-node GBM device are unknown to the card
 * node and the kernel rejects ADDFB2 with ENOENT. i915's handles are global,
 * which is why the same code worked there. Returns the ioctl result; on an
 * import failure returns -1 and the caller restores the original errno. */
static int addfb2_via_prime(int fd, unsigned long request,
                           struct shim_fb_cmd2 *fb) {
  uint32_t original[4];
  uint32_t imported[4] = {0, 0, 0, 0};
  char card_dev[PATH_MAX];
  int ret;
  int i, j;
  int ok = 1;

  if (!drm_device_dir(fd, card_dev, sizeof(card_dev)))
    return -1;

  for (i = 0; i < 4; i++)
    original[i] = fb->handles[i];

  for (i = 0; i < 4 && ok; i++) {
    struct shim_prime_handle ph;
    uint32_t handle = original[i];
    uint32_t moved = 0;
    int dmabuf;

    if (!handle)
      continue;

    /* Planes can share one buffer; export it only once. */
    for (j = 0; j < i; j++) {
      if (original[j] == handle) {
        moved = imported[j];
        break;
      }
    }
    if (j < i) {
      if (!moved)
        continue;
      fb->handles[i] = moved;
      continue;
    }

    dmabuf = export_handle(card_dev, handle);
    if (dmabuf < 0) {
      /* Already valid on the card node (mixed fb): keep it as is. */
      if (handle_on_fd(fd, handle))
        continue;
      shim_log("[%d] PRIME: cannot export handle %u\n", getpid(), handle);
      ok = 0;
      break;
    }

    memset(&ph, 0, sizeof(ph));
    ph.fd = dmabuf;
    if (p_ioctl(fd, SHIM_DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
      shim_log("[%d] PRIME: dmabuf %d -> handle on fd %d failed (%s)\n",
               getpid(), dmabuf, fd, strerror(errno));
      close(dmabuf);
      ok = 0;
      break;
    }
    close(dmabuf);
    imported[i] = ph.handle;
    fb->handles[i] = ph.handle;
  }

  ret = ok ? p_ioctl(fd, request, fb) : -1;

  /* Restore the caller's handles: the framebuffer holds its own reference. */
  for (i = 0; i < 4; i++) {
    fb->handles[i] = original[i];
    if (imported[i]) {
      struct shim_gem_close gc;
      memset(&gc, 0, sizeof(gc));
      gc.handle = imported[i];
      for (j = i + 1; j < 4; j++) {
        if (imported[j] == imported[i])
          imported[j] = 0;
      }
      p_ioctl(fd, SHIM_DRM_IOCTL_GEM_CLOSE, &gc);
    }
  }
  return ret;
}

/* Interpose ioctl for the scanout-format fallback above. Only ADDFB2 failures
 * are inspected (and only tiled alpha formats are retried); everything else
 * is forwarded verbatim. */
int ioctl(int fd, unsigned long request, ...) {
  void *arg;
  va_list ap;
  va_start(ap, request);
  arg = va_arg(ap, void *);
  va_end(ap);

  if (!p_ioctl) {
    p_ioctl = (__typeof__(p_ioctl))dlsym(RTLD_NEXT, "ioctl");
  }
  if (!p_ioctl) {
    errno = ENOSYS;
    return -1;
  }

  int ret = p_ioctl(fd, request, arg);
  if (ret < 0 && request == SHIM_DRM_IOCTL_MODE_ADDFB2) {
    struct shim_fb_cmd2 *fb = (struct shim_fb_cmd2 *)arg;
    int original_errno = errno;

    /* amdgpu only: the buffer's handle belongs to the render node, so the
     * card node does not know it. Import it via PRIME and retry once. */
    if (fb && original_errno == ENOENT) {
      int moved = addfb2_via_prime(fd, request, fb);
      if (moved >= 0) {
        shim_log("[%d] ADDFB2 recovered via PRIME (fmt=0x%08x '%c%c%c%c')\n",
                 getpid(), fb->pixel_format, fourcc_char(fb->pixel_format, 0),
                 fourcc_char(fb->pixel_format, 1),
                 fourcc_char(fb->pixel_format, 2),
                 fourcc_char(fb->pixel_format, 3));
        return moved;
      }
      shim_log("[%d] ADDFB2 fd=%d fmt=0x%08x '%c%c%c%c' failed with ENOENT; "
               "PRIME fallback failed\n",
               getpid(), fd, fb->pixel_format,
               fourcc_char(fb->pixel_format, 0),
               fourcc_char(fb->pixel_format, 1),
               fourcc_char(fb->pixel_format, 2),
               fourcc_char(fb->pixel_format, 3));
      errno = original_errno;
    }

    if (fb && errno == EINVAL && fb->modifier[0] != 0) {
      uint32_t requested = fb->pixel_format;
      uint32_t fallback = alpha_less_format(requested);
      if (fallback != requested) {
        int fallback_errno = errno;
        fb->pixel_format = fallback;
        ret = p_ioctl(fd, request, fb);
        if (ret < 0) {
          fb->pixel_format = requested;
          errno = fallback_errno;
        }
      }
    }
  }
  return ret;
}

/* Layout of struct gbm_import_fd_modifier_data — identical in minigbm and
 * Mesa (GBM_MAX_PLANES = 4 on both sides). */
struct shim_import_mod {
  uint32_t width;
  uint32_t height;
  uint32_t format;
  uint32_t num_fds;
  int fds[4];
  int strides[4];
  int offsets[4];
  uint64_t modifier;
};

/* struct gbm_import_fd_data, as Mesa expects it for GBM_BO_IMPORT_FD. */
struct shim_import_fd {
  int fd;
  uint32_t width;
  uint32_t height;
  uint32_t stride;
  uint32_t format;
};

struct gbm_device *gbm_create_device(int fd) {
  struct gbm_device *dev = p_create_device ? p_create_device(fd) : NULL;
  char link[64];
  char path[PATH_MAX] = "?";

  if (dev)
    register_gbm_fd(fd, dev);
  snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
  ssize_t n = readlink(link, path, sizeof(path) - 1);
  if (n > 0)
    path[n] = '\0';
  shim_log("[%d] gbm_create_device(fd=%d %s) -> %s\n", getpid(), fd, path,
           dev ? "DEVICE" : "NULL");
  return dev;
}

void gbm_device_destroy(struct gbm_device *gbm) {
  if (p_device_destroy) {
    p_device_destroy(gbm);
  }
}

int gbm_device_is_format_supported(struct gbm_device *gbm, uint32_t format,
                                   uint32_t usage) {
  if (!p_device_is_format_supported) {
    return 0;
  }
  uint64_t masked = mask_usage(usage);
  int supported =
      p_device_is_format_supported(gbm, format, (uint32_t)masked);
  shim_log("[%d] is_format_supported(fmt=0x%08x '%c%c%c%c' usage=0x%llx "
           "masked=0x%llx) = %d\n",
           getpid(), format, fourcc_char(format, 0), fourcc_char(format, 1),
           fourcc_char(format, 2), fourcc_char(format, 3),
           (unsigned long long)usage, (unsigned long long)masked, supported);
  return supported;
}

struct gbm_bo *gbm_bo_create(struct gbm_device *gbm, uint32_t width,
                             uint32_t height, uint32_t format,
                             uint32_t flags) {
  if (!p_bo_create) {
    return NULL;
  }
  struct gbm_bo *bo =
      p_bo_create(gbm, width, height, format, (uint32_t)mask_usage(flags));
  shim_log("[%d] gbm_bo_create(%ux%u fmt=0x%08x '%c%c%c%c' usage=0x%llx) -> "
           "%s\n",
           getpid(), width, height, format, fourcc_char(format, 0),
           fourcc_char(format, 1), fourcc_char(format, 2),
           fourcc_char(format, 3), (unsigned long long)flags,
           bo ? "BO" : "NULL");
  return bo;
}

/* Formats Chrome uses for the primary scanout buffer (packed 32-bit RGB). */
static int scanout_rgb_format(uint32_t format) {
  switch (format) {
    case 0x34325241: /* 'AR24' ARGB8888 */
    case 0x34325258: /* 'XR24' XRGB8888 */
    case 0x34324241: /* 'AB24' ABGR8888 */
    case 0x34324258: /* 'XB24' XBGR8888 */
    case 0x30335241: /* 'AR30' ARGB2101010 */
    case 0x30335258: /* 'XR30' XRGB2101010 */
    case 0x30334241: /* 'AB30' ABGR2101010 */
    case 0x30334258: /* 'XB30' XBGR2101010 */
      return 1;
    default:
      return 0;
  }
}

struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *gbm,
                                             uint32_t width,
                                             uint32_t height,
                                             uint32_t format,
                                             const uint64_t *modifiers,
                                             size_t count) {
  struct gbm_bo *bo = NULL;
  size_t i;

  if (p_bo_create_with_modifiers) {
    bo = p_bo_create_with_modifiers(gbm, width, height, format, modifiers,
                                    count);
  }
  /* radeonsi only wires up resource_create_with_modifiers on GFX9+. On older
   * AMD GPUs (Wani/Carrizo is GFX8) every modifiers request returns NULL, so
   * Chrome's scanout-buffer creation fails before the first modeset. A plain
   * scanout BO is linear and its modifier is DRM_FORMAT_MOD_INVALID, which
   * Chrome then treats as "no modifiers" when it builds the framebuffer. */
  if (!bo && p_bo_create && scanout_rgb_format(format)) {
    bo = p_bo_create(gbm, width, height, format, SHIM_GBM_BO_USE_SCANOUT);
  }
  shim_log("[%d] gbm_bo_create_with_modifiers(%ux%u fmt=0x%08x '%c%c%c%c' "
           "nmods=%zu mods=[",
           getpid(), width, height, format, fourcc_char(format, 0),
           fourcc_char(format, 1), fourcc_char(format, 2),
           fourcc_char(format, 3), count);
  for (i = 0; i < count && i < 8; i++) {
    shim_log("%s0x%llx", i ? "," : "", (unsigned long long)modifiers[i]);
  }
  shim_log("%s]) -> %s\n", count > 8 ? ",..." : "", bo ? "BO" : "NULL");
  return bo;
}

void gbm_bo_destroy(struct gbm_bo *bo, struct gbm_device *gbm) {
  if (p_bo_destroy) {
    p_bo_destroy(bo, gbm);
  }
}

/* A single bad client buffer can be retried thousands of times per second
 * (every compositor frame). Log the first few dozen attempts, then sample. */
static int import_log_budget = 60;

static int import_should_log(void) {
  static unsigned int seen;
  seen++;
  if (import_log_budget > 0) {
    import_log_budget--;
    return 1;
  }
  return (seen % 500) == 0;
}

/* Explain a failed gbm_bo_import. Mesa's import path reports EINVAL for nearly
 * every rejection, so also record what the fd actually is: a dmabuf shows up
 * as an anonymous inode whose size is the mapping length, while a bogus/closed
 * fd shows up as an error here too. */
static void log_import_failure(int fd, const char *stage) {
  int saved = errno;
  char link[64];
  char path[PATH_MAX] = "?";
  struct stat st;
  ssize_t n;

  snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
  n = readlink(link, path, sizeof(path) - 1);
  if (n > 0)
    path[n] = '\0';
  if (fstat(fd, &st) < 0)
    st.st_size = -1;
  shim_log("[%d]   %s: errno=%d (%s) fd=%d path=%s size=%lld ino=%llu\n",
           getpid(), stage, saved, strerror(saved), fd, path,
           (long long)st.st_size, (unsigned long long)st.st_ino);
}

struct gbm_bo *gbm_bo_import(struct gbm_device *gbm, uint32_t type,
                             const void *buf, uint32_t flags) {
  /* minigbm's GBM_BO_IMPORT_FD_MODIFIER (0x5505) is Mesa's 0x5504. */
  uint32_t mesa_type =
      (type == MINIGBM_IMPORT_FD_MODIFIER) ? MESA_IMPORT_FD_MODIFIER : type;
  uint64_t masked = mask_usage(flags);
  int log_now = import_should_log();

  /* buf's layout depends on the import type: the legacy GBM_BO_IMPORT_FD
   * descriptor is only 20 bytes (shim_import_fd), whereas the modifier
   * descriptor is 72 (shim_import_mod). Only the modifier path may read
   * num_fds/modifier — doing so for the legacy path reads past the caller's
   * buffer (out-of-bounds). */
  const struct shim_import_mod *m = NULL;
  if (mesa_type == MESA_IMPORT_FD_MODIFIER) {
    m = (const struct shim_import_mod *)buf;
  }

  if (m) {
    /* Only meaningful for the modifier descriptor; >= 1 plane and <= 4 planes
     * is what Mesa's gbm_import_fd_modifier_data can address. */
    int sane = (m->num_fds >= 1 && m->num_fds <= 4);

    struct gbm_bo *bo =
        p_bo_import ? p_bo_import(gbm, mesa_type, buf, (uint32_t)masked) : NULL;

    if (log_now) {
      shim_log("[%d] gbm_bo_import(type=0x%x->0x%x dev=%s flags=0x%x->0x%llx, "
               "fmt=0x%08x %ux%u num_fds=%u mod=0x%llx off=%d) -> %s\n",
               getpid(), type, mesa_type, gbm_dev_name(gbm), flags,
               (unsigned long long)masked, m->format, m->width, m->height,
               m->num_fds, (unsigned long long)m->modifier, m->offsets[0],
               bo ? "BO" : "NULL");
    }

    if (bo || mesa_type != MESA_IMPORT_FD_MODIFIER || !sane) {
      if (!bo && log_now)
        log_import_failure(m->fds[0], "import FD_MODIFIER");
      return bo;
    }

    /* Chrome's GBM build asks for SCANOUT on every import
     * (GetSupportedGbmFlags() reports SCANOUT|TEXTURING). Mesa creates the
     * image fine, then dri2_validate_usage() rejects SCANOUT because the
     * producer allocated a non-displayable surface: Xwayland's glamor on GFX8
     * picks STANDARD micro-tiling (tiling_info bit 12), so radeonsi reports
     * is_displayable=false. The compositor only samples these buffers, so
     * retry without SCANOUT instead of failing the shared image and leaving
     * the client in an endless CreateBufferFromHandle loop. */
    if (masked & SHIM_GBM_BO_USE_SCANOUT) {
      errno = 0;
      bo = p_bo_import ? p_bo_import(gbm, mesa_type, buf,
                                     (uint32_t)(masked &
                                                ~(uint64_t)SHIM_GBM_BO_USE_SCANOUT))
                       : NULL;
      if (bo) {
        if (log_now)
          shim_log("[%d]   recovered without GBM_BO_USE_SCANOUT "
                   "(non-displayable producer surface)\n", getpid());
        return bo;
      }
    }

    /* Retry: vmwgfx rejects DRM_FORMAT_MOD_INVALID imports, LINEAR it accepts. */
    struct shim_import_mod linear = *m;
    linear.modifier = 0;
    errno = 0;
    bo = p_bo_import ? p_bo_import(gbm, MESA_IMPORT_FD_MODIFIER, &linear,
                                   (uint32_t)masked)
                     : NULL;
    if (bo) {
      if (log_now)
        shim_log("[%d]   recovered with modifier=0\n", getpid());
      return bo;
    }

    if (log_now)
      shim_log("[%d]   modified and LINEAR imports both failed (errno=%d)\n",
               getpid(), errno);

    /* Last resort: the legacy single-plane descriptor, rebuilt from the
     * modifier descriptor's first plane. */
    struct shim_import_fd legacy;
    legacy.fd = m->fds[0];
    legacy.width = m->width;
    legacy.height = m->height;
    legacy.stride = (uint32_t)m->strides[0];
    legacy.format = m->format;
    errno = 0;
    bo = p_bo_import ? p_bo_import(gbm, MESA_IMPORT_FD, &legacy,
                                   (uint32_t)masked)
                     : NULL;
    if (log_now) {
      shim_log("[%d]   legacy FD import(fd=%d %ux%u stride=%u fmt=0x%x) -> %s\n",
               getpid(), legacy.fd, legacy.width, legacy.height, legacy.stride,
               legacy.format, bo ? "BO" : "NULL");
      if (!bo) {
        log_import_failure(legacy.fd, "import after all fallbacks");
      }
    }
    return bo;
  }

  /* Legacy (or unknown) import type: buf is the 20-byte shim_import_fd. Log
   * only its own fields — never the modifier descriptor's — and pass through. */
  const struct shim_import_fd *fd_data = (const struct shim_import_fd *)buf;
  struct gbm_bo *bo =
      p_bo_import ? p_bo_import(gbm, mesa_type, buf, (uint32_t)masked) : NULL;
  if (log_now) {
    shim_log("[%d] gbm_bo_import(fd dev=%s type=0x%x flags=0x%x->0x%llx, "
             "fd=%d %ux%u stride=%u fmt=0x%x) -> %s\n",
             getpid(), gbm_dev_name(gbm), type, flags,
             (unsigned long long)masked, fd_data->fd, fd_data->width,
             fd_data->height, fd_data->stride, fd_data->format,
             bo ? "BO" : "NULL");
  }
  return bo;
}

union gbm_bo_handle gbm_bo_get_handle(struct gbm_bo *bo) {
  union gbm_bo_handle handle = {0};
  if (p_bo_get_handle) {
    handle = p_bo_get_handle(bo);
  }
  return handle;
}

union gbm_bo_handle gbm_bo_get_handle_for_plane(struct gbm_bo *bo,
                                                int plane) {
  union gbm_bo_handle handle = {0};
  if (p_bo_get_handle_for_plane) {
    handle = p_bo_get_handle_for_plane(bo, plane);
  }
  return handle;
}

uint32_t gbm_bo_get_width(struct gbm_bo *bo) {
  return p_bo_get_width ? p_bo_get_width(bo) : 0;
}

uint32_t gbm_bo_get_height(struct gbm_bo *bo) {
  return p_bo_get_height ? p_bo_get_height(bo) : 0;
}

uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane) {
  return p_bo_get_stride ? p_bo_get_stride(bo, plane) : 0;
}

uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane) {
  return p_bo_get_offset ? p_bo_get_offset(bo, plane) : 0;
}

uint64_t gbm_bo_get_modifier(struct gbm_bo *bo) {
  return p_bo_get_modifier ? p_bo_get_modifier(bo) : 0;
}

int gbm_bo_get_plane_count(struct gbm_bo *bo) {
  return p_bo_get_plane_count ? p_bo_get_plane_count(bo) : 0;
}

int gbm_bo_get_plane_fd(struct gbm_bo *bo, int plane) {
  if (p_bo_get_fd_for_plane) {
    return p_bo_get_fd_for_plane(bo, plane);
  }
  if (p_bo_get_fd) {
    return p_bo_get_fd(bo);
  }
  return -1;
}

uint64_t gbm_bo_get_plane_size(struct gbm_bo *bo, int plane) {
  if (p_bo_get_plane_size) {
    return p_bo_get_plane_size(bo, plane);
  }
  /* Mesa builds predating gbm_bo_get_plane_size: single-plane buffers are
   * tightly packed, so stride * height is the plane size. */
  if (p_bo_get_stride && p_bo_get_height) {
    return (uint64_t)p_bo_get_stride(bo, plane) * p_bo_get_height(bo);
  }
  return 0;
}

void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t width,
                 uint32_t height, uint32_t flags, uint32_t *stride,
                 void *map_data) {
  if (!p_bo_map) {
    return NULL;
  }
  return p_bo_map(bo, x, y, width, height, flags, stride, map_data);
}

void gbm_bo_unmap(struct gbm_bo *bo, void *map_data) {
  if (p_bo_unmap) {
    p_bo_unmap(bo, map_data);
  }
}
