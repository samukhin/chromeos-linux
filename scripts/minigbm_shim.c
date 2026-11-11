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
 * Everything is logged to /tmp/gbm-shim.log (cleared by the session script
 * on start) — that file is how the failure chain above was diagnosed.
 *
 * Build: cc -shared -fPIC -O2 -o libminigbm.so minigbm_shim.c -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
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

/* Bits Mesa's gbm understands; anything above is minigbm-specific. */
#define GBM_USAGE_MASK 0x3f
#define GBM_USAGE_LOW3 0x7 /* SCANOUT | CURSOR | RENDERING */
#define GBM_BO_USE_RENDERING 0x4

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
  if (ret < 0 && errno == EINVAL && request == SHIM_DRM_IOCTL_MODE_ADDFB2) {
    struct shim_fb_cmd2 *fb = (struct shim_fb_cmd2 *)arg;
    if (fb && fb->modifier[0] != 0) {
      uint32_t requested = fb->pixel_format;
      uint32_t fallback = alpha_less_format(requested);
      if (fallback != requested) {
        int original_errno = errno;
        fb->pixel_format = fallback;
        ret = p_ioctl(fd, request, fb);
        if (ret < 0) {
          fb->pixel_format = requested;
          errno = original_errno;
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
  shim_log("[%d] gbm_create_device(fd=%d) -> %s\n", getpid(), fd,
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

struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *gbm,
                                             uint32_t width,
                                             uint32_t height,
                                             uint32_t format,
                                             const uint64_t *modifiers,
                                             size_t count) {
  if (!p_bo_create_with_modifiers) {
    return NULL;
  }
  return p_bo_create_with_modifiers(gbm, width, height, format, modifiers,
                                    count);
}

void gbm_bo_destroy(struct gbm_bo *bo, struct gbm_device *gbm) {
  if (p_bo_destroy) {
    p_bo_destroy(bo, gbm);
  }
}

struct gbm_bo *gbm_bo_import(struct gbm_device *gbm, uint32_t type,
                             const void *buf, uint32_t flags) {
  /* minigbm's GBM_BO_IMPORT_FD_MODIFIER (0x5505) is Mesa's 0x5504. */
  uint32_t mesa_type =
      (type == MINIGBM_IMPORT_FD_MODIFIER) ? MESA_IMPORT_FD_MODIFIER : type;
  uint64_t masked = mask_usage(flags);

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

    shim_log("[%d] gbm_bo_import(type=0x%x->0x%x flags=0x%x->0x%llx, "
             "fmt=0x%08x %ux%u num_fds=%u mod=0x%llx) -> %s\n",
             getpid(), type, mesa_type, flags, (unsigned long long)masked,
             m->format, m->width, m->height, m->num_fds,
             (unsigned long long)m->modifier, bo ? "BO" : "NULL");

    if (bo || mesa_type != MESA_IMPORT_FD_MODIFIER || !sane) {
      return bo;
    }

    /* Retry: vmwgfx rejects DRM_FORMAT_MOD_INVALID imports, LINEAR it accepts. */
    struct shim_import_mod linear = *m;
    linear.modifier = 0;
    bo = p_bo_import ? p_bo_import(gbm, MESA_IMPORT_FD_MODIFIER, &linear,
                                   (uint32_t)masked)
                     : NULL;
    shim_log("[%d]   fallback modifier=0 -> %s\n", getpid(),
             bo ? "BO" : "NULL");
    if (bo) {
      return bo;
    }

    /* Last resort: the legacy single-plane descriptor, rebuilt from the
     * modifier descriptor's first plane. */
    struct shim_import_fd legacy;
    legacy.fd = m->fds[0];
    legacy.width = m->width;
    legacy.height = m->height;
    legacy.stride = (uint32_t)m->strides[0];
    legacy.format = m->format;
    bo = p_bo_import ? p_bo_import(gbm, MESA_IMPORT_FD, &legacy,
                                   (uint32_t)masked)
                     : NULL;
    shim_log("[%d]   fallback legacy FD(fd=%d %ux%u stride=%u fmt=0x%x) -> %s\n",
             getpid(), legacy.fd, legacy.width, legacy.height, legacy.stride,
             legacy.format, bo ? "BO" : "NULL");
    return bo;
  }

  /* Legacy (or unknown) import type: buf is the 20-byte shim_import_fd. Log
   * only its own fields — never the modifier descriptor's — and pass through. */
  const struct shim_import_fd *fd_data = (const struct shim_import_fd *)buf;
  struct gbm_bo *bo =
      p_bo_import ? p_bo_import(gbm, mesa_type, buf, (uint32_t)masked) : NULL;
  shim_log("[%d] gbm_bo_import(fd type=0x%x flags=0x%x->0x%llx, "
           "fd=%d %ux%u stride=%u fmt=0x%x) -> %s\n",
           getpid(), type, flags, (unsigned long long)masked, fd_data->fd,
           fd_data->width, fd_data->height, fd_data->stride, fd_data->format,
           bo ? "BO" : "NULL");
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
