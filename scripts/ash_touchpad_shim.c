/* libash-touchpad.so — make the touchpad usable under Ash's DRM evdev input.
 *
 * The ChromiumOS snapshot this project ships is a generic "Linux_ChromiumOS_Full"
 * build: `use_evdev_gestures = is_chromeos_device` is false, so it does not link
 * the ChromeOS libgestures/libinput glue. Ash's evdev backend therefore cannot
 * consume an absolute-multitouch touchpad:
 *
 *   EventConverterEvdevImpl::ProcessEvents() handles EV_KEY, EV_REL (REL_X,
 *   REL_Y only), EV_SYN and EV_SW.  EV_ABS is ignored, and so is REL_WHEEL.
 *
 * The TrackPoint works (it emits REL_X/REL_Y), the touchpad does not (it emits
 * ABS_MT_POSITION_*), and the touchpad's taps never turn into clicks.
 *
 * This shim is LD_PRELOADed into the browser process and sits between the
 * touchpad fd and that converter: it reads the kernel's MT stream and returns
 * an equivalent EV_REL/EV_KEY stream that the converter already understands:
 *
 *   - one finger       -> REL_X / REL_Y (with a small speed-based acceleration)
 *   - one-finger tap   -> BTN_LEFT click
 *   - two-finger tap   -> BTN_RIGHT click
 *   - physical click   -> passed through; with two fingers down BTN_LEFT is
 *                         remapped to BTN_RIGHT (clickfinger, the ChromeOS
 *                         default for BUTTONPAD touchpads)
 *   - two+ finger drag -> intentionally ignored: scrolling lives in the
 *                         missing gestures library, not in this shim
 *
 * No /dev/uinput, no root, no extra daemon: the device stays the same evdev
 * node, so Chrome still applies its own touchpad enable/disable setting.
 *
 * Build: cc -shared -fPIC -O2 -o libash-touchpad.so ash_touchpad_shim.c -ldl -pthread
 * Debug: ASH_TOUCHPAD_DEBUG=1 logs detection/clicks, =2 also logs motion to
 *        /tmp/ash-touchpad.log. Disable the shim with ASH_TOUCHPAD_SHIM=0.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Chrome reads at most `input_event inputs[4]` per callback; keep one frame
 * (buttons or motion + SYN) within that so a read never has to be split. */
#define MAX_OUT_EVENTS 4
#define MAX_SLOTS 64
#define FD_LIMIT 65536

/* Tap heuristics: a tap is short and does not move the finger(s) much. */
#define TAP_MAX_USEC 300000
#define TAP_MAX_MOVE 25.0 /* ABS units, ~0.8 mm on a 30 units/mm pad */

/* Pointer scaling: REL pixels per ABS unit. 0.45 moves the cursor about one
 * screen width per full pad swipe; speed adds up to 0.55 more. */
#define MOVE_BASE 0.45
#define MOVE_ACCEL 0.55
#define MOVE_ACCEL_SPEED 80.0
#define MOVE_MAX_STEP 120.0

struct contact {
  int used;
  int32_t x, y;
  int32_t tracking_id;
};

struct tp_state {
  unsigned int cur_slot;
  struct contact slots[MAX_SLOTS];

  int prev_count;
  double prev_x, prev_y;
  double acc_x, acc_y;

  int tap_active;
  int64_t tap_start_us;
  double tap_moved;
  int tap_max_contacts;
  int tap_button_during;

  /* BTN_LEFT remapped to BTN_RIGHT for a two-finger physical click. */
  int left_remap_code;
  /* Buttons queued in the frame currently being assembled. */
  int frame_buttons;
  /* Throttles the ASH_TOUCHPAD_DEBUG=2 motion log. */
  unsigned int dbg_frames;
};

static unsigned char fd_kind[FD_LIMIT]; /* 0 unknown, 1 touchpad, 2 passthrough */
static struct tp_state *fd_state[FD_LIMIT];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int active; /* 0 in Chrome child processes (zygote, renderer, ...) */

/* ------------------------------------------------------------------------- */
/* small helpers                                                             */
/* ------------------------------------------------------------------------- */

static ssize_t raw_read(int fd, void *buf, size_t count) {
  return syscall(SYS_read, fd, buf, count);
}

static int raw_close(int fd) {
  return (int)syscall(SYS_close, fd);
}

static int debug_level(void) {
  static int level = -1;
  if (level < 0) {
    const char *s = getenv("ASH_TOUCHPAD_DEBUG");
    level = s ? atoi(s) : 0;
  }
  return level;
}

static void dbg(int level, const char *fmt, ...) {
  char buf[256];
  va_list ap;
  int n;

  if (debug_level() < level)
    return;

  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n <= 0)
    return;

  int fd = (int)syscall(SYS_openat, AT_FDCWD, "/tmp/ash-touchpad.log",
                        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  if (fd < 0)
    return;
  (void)syscall(SYS_write, fd, buf, (size_t)n);
  raw_close(fd);
}

static int bit_set(const unsigned long *bits, unsigned int bit) {
  const unsigned int per_word = 8 * sizeof(unsigned long);
  return (int)((bits[bit / per_word] >> (bit % per_word)) & 1UL);
}

static int64_t ev_usec(const struct input_event *ev) {
  return (int64_t)ev->time.tv_sec * 1000000 + ev->time.tv_usec;
}

/* The browser process is the only one that opens input devices; children get
 * `--type=...` on their command line, and skipping them keeps a read hook out
 * of every renderer and GPU process. */
static int detect_active(void) {
  char buf[8192];
  int fd = (int)syscall(SYS_openat, AT_FDCWD, "/proc/self/cmdline",
                        O_RDONLY | O_CLOEXEC);
  ssize_t n;

  if (fd < 0)
    return 1;
  n = raw_read(fd, buf, sizeof(buf) - 1);
  raw_close(fd);
  if (n <= 0)
    return 1;
  buf[n] = '\0';
  for (ssize_t i = 0; i + 7 < n; i++) {
    if (memcmp(buf + i, "--type=", 7) == 0)
      return 0;
  }
  return 1;
}

/* Same classification rules as ui::EventDeviceInfo::HasTouchpad(): absolute
 * X/Y, INPUT_PROP_POINTER, not INPUT_PROP_DIRECT, plus an MT-B position. */
static int probe_touchpad(int fd) {
  unsigned long abs_bits[(ABS_CNT + 8 * sizeof(unsigned long) - 1) /
                         (8 * sizeof(unsigned long))];
  unsigned long prop_bits[(INPUT_PROP_CNT + 8 * sizeof(unsigned long) - 1) /
                          (8 * sizeof(unsigned long))];

  memset(abs_bits, 0, sizeof(abs_bits));
  memset(prop_bits, 0, sizeof(prop_bits));

  if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits) < 0)
    return 0;
  if (!bit_set(abs_bits, ABS_X) || !bit_set(abs_bits, ABS_Y))
    return 0;
  if (!bit_set(abs_bits, ABS_MT_POSITION_X) ||
      !bit_set(abs_bits, ABS_MT_POSITION_Y))
    return 0;

  if (ioctl(fd, EVIOCGPROP(sizeof(prop_bits)), prop_bits) < 0)
    return 0;
  if (!bit_set(prop_bits, INPUT_PROP_POINTER))
    return 0;
  if (bit_set(prop_bits, INPUT_PROP_DIRECT))
    return 0;

  return 1;
}

/* ------------------------------------------------------------------------- */
/* MT -> relative mouse translation                                          */
/* ------------------------------------------------------------------------- */

static int contact_count(const struct tp_state *st, double *cx, double *cy) {
  int count = 0;
  double sx = 0, sy = 0;

  for (unsigned int i = 0; i < MAX_SLOTS; i++) {
    if (!st->slots[i].used)
      continue;
    count++;
    sx += st->slots[i].x;
    sy += st->slots[i].y;
  }
  if (count) {
    if (cx)
      *cx = sx / count;
    if (cy)
      *cy = sy / count;
  }
  return count;
}

static void push_event(struct input_event *out, size_t *n, size_t cap,
                       const struct input_event *tmpl, uint16_t type,
                       uint16_t code, int32_t value) {
  struct input_event *ev;

  if (*n >= cap)
    return;
  ev = &out[(*n)++];
  ev->time = tmpl->time;
  ev->type = type;
  ev->code = code;
  ev->value = value;
}

static void reset_sequence(struct tp_state *st) {
  for (unsigned int i = 0; i < MAX_SLOTS; i++)
    st->slots[i].used = 0;
  st->cur_slot = 0;
  st->prev_count = 0;
  st->acc_x = st->acc_y = 0;
  st->tap_active = 0;
  st->frame_buttons = 0;
}

static void frame_done(struct tp_state *st, const struct input_event *syn,
                       struct input_event *out, size_t *n, size_t cap) {
  double cx = st->prev_x, cy = st->prev_y;
  int count = contact_count(st, &cx, &cy);

  if (count == 0) {
    if (st->tap_active) {
      int64_t duration = ev_usec(syn) - st->tap_start_us;
      if (!st->tap_button_during && st->tap_max_contacts <= 2 &&
          st->tap_moved < TAP_MAX_MOVE && duration >= 0 &&
          duration < TAP_MAX_USEC) {
        uint16_t button =
            st->tap_max_contacts == 2 ? BTN_RIGHT : BTN_LEFT;
        dbg(1, "tap: %d finger(s) -> %s\n", st->tap_max_contacts,
            button == BTN_RIGHT ? "BTN_RIGHT" : "BTN_LEFT");
        push_event(out, n, cap, syn, EV_KEY, button, 1);
        push_event(out, n, cap, syn, EV_SYN, SYN_REPORT, 0);
        push_event(out, n, cap, syn, EV_KEY, button, 0);
        push_event(out, n, cap, syn, EV_SYN, SYN_REPORT, 0);
        st->tap_active = 0;
        st->frame_buttons = 0;
        return;
      }
    }
    st->tap_active = 0;
    st->prev_count = 0;
    st->acc_x = st->acc_y = 0;
  } else {
    if (!st->tap_active) {
      st->tap_active = 1;
      st->tap_start_us = ev_usec(syn);
      st->tap_moved = 0;
      st->tap_max_contacts = count;
      st->tap_button_during = 0;
    } else {
      if (count > st->tap_max_contacts)
        st->tap_max_contacts = count;
      if (st->prev_count > 0)
        st->tap_moved += hypot(cx - st->prev_x, cy - st->prev_y);
    }

    if (count == 1) {
      if (st->prev_count == 1) {
        double dx = cx - st->prev_x;
        double dy = cy - st->prev_y;
        double speed = hypot(dx, dy);
        double factor = MOVE_BASE + fmin(speed / MOVE_ACCEL_SPEED, 1.0) *
                                       MOVE_ACCEL;
        double step;

        st->acc_x += dx * factor;
        st->acc_y += dy * factor;

        /* A button was forwarded in this frame: it already uses the four
         * slots, so let the motion accumulate and go out with the next one. */
        if (!st->frame_buttons) {
          step = st->acc_x;
          if (step > MOVE_MAX_STEP)
            step = MOVE_MAX_STEP;
          if (step < -MOVE_MAX_STEP)
            step = -MOVE_MAX_STEP;
          int ix = (int)step;
          if (ix) {
            push_event(out, n, cap, syn, EV_REL, REL_X, ix);
            st->acc_x -= ix;
          }

          step = st->acc_y;
          if (step > MOVE_MAX_STEP)
            step = MOVE_MAX_STEP;
          if (step < -MOVE_MAX_STEP)
            step = -MOVE_MAX_STEP;
          int iy = (int)step;
          if (iy) {
            push_event(out, n, cap, syn, EV_REL, REL_Y, iy);
            st->acc_y -= iy;
          }

          if ((++st->dbg_frames % 25) == 0)
            dbg(2, "move dx=%.1f dy=%.1f speed=%.1f -> %d,%d\n", dx, dy,
                speed, ix, iy);
        }
      }
    } else {
      /* Two or more fingers: scrolling/gestures are not implemented here,
       * and the centroid jump when a finger lands must not move the cursor. */
      st->acc_x = st->acc_y = 0;
    }

    st->prev_count = count;
    st->prev_x = cx;
    st->prev_y = cy;
  }

  if (*n > 0)
    push_event(out, n, cap, syn, EV_SYN, SYN_REPORT, 0);
  st->frame_buttons = 0;
}

static void translate_event(struct tp_state *st, const struct input_event *ev,
                            struct input_event *out, size_t *n, size_t cap,
                            int *done) {
  switch (ev->type) {
    case EV_ABS:
      switch (ev->code) {
        case ABS_MT_SLOT:
          if (ev->value >= 0 && (unsigned int)ev->value < MAX_SLOTS)
            st->cur_slot = (unsigned int)ev->value;
          break;
        case ABS_MT_TRACKING_ID:
          if (st->cur_slot < MAX_SLOTS) {
            if (ev->value < 0) {
              st->slots[st->cur_slot].used = 0;
            } else {
              st->slots[st->cur_slot].used = 1;
              st->slots[st->cur_slot].tracking_id = ev->value;
            }
          }
          break;
        case ABS_MT_POSITION_X:
          if (st->cur_slot < MAX_SLOTS)
            st->slots[st->cur_slot].x = ev->value;
          break;
        case ABS_MT_POSITION_Y:
          if (st->cur_slot < MAX_SLOTS)
            st->slots[st->cur_slot].y = ev->value;
          break;
        default:
          break;
      }
      break;

    case EV_KEY:
      switch (ev->code) {
        case BTN_LEFT:
          if (ev->value) {
            int code = contact_count(st, NULL, NULL) >= 2 ? BTN_RIGHT
                                                          : BTN_LEFT;
            st->left_remap_code = code == BTN_RIGHT ? BTN_RIGHT : 0;
            push_event(out, n, cap, ev, EV_KEY, code, 1);
            if (code == BTN_RIGHT)
              dbg(1, "physical click with 2 fingers -> BTN_RIGHT\n");
          } else {
            int code = st->left_remap_code ? st->left_remap_code : BTN_LEFT;
            st->left_remap_code = 0;
            push_event(out, n, cap, ev, EV_KEY, code, 0);
          }
          st->frame_buttons++;
          st->tap_button_during = 1;
          break;
        case BTN_RIGHT:
        case BTN_MIDDLE:
          push_event(out, n, cap, ev, EV_KEY, ev->code, ev->value);
          st->frame_buttons++;
          st->tap_button_during = 1;
          break;
        default:
          /* BTN_TOUCH, BTN_TOOL_* and friends are touchpad bookkeeping,
           * not mouse buttons. */
          break;
      }
      break;

    case EV_SYN:
      if (ev->code == SYN_DROPPED) {
        reset_sequence(st);
        push_event(out, n, cap, ev, EV_SYN, SYN_DROPPED, 0);
        *done = 1;
      } else if (ev->code == SYN_REPORT) {
        frame_done(st, ev, out, n, cap);
        *done = 1;
      }
      break;

    default:
      break;
  }
}

/* ------------------------------------------------------------------------- */
/* interposed libc entry points                                              */
/* ------------------------------------------------------------------------- */

static struct tp_state *ensure_state(int fd) {
  struct tp_state *st;

  pthread_mutex_lock(&lock);
  if (fd_kind[fd] == 0) {
    if (probe_touchpad(fd)) {
      fd_kind[fd] = 1;
      fd_state[fd] = calloc(1, sizeof(struct tp_state));
      if (!fd_state[fd])
        fd_kind[fd] = 2;
      dbg(1, "touchpad detected on fd %d (pid %d)\n", fd, (int)getpid());
    } else {
      fd_kind[fd] = 2;
    }
  }
  st = fd_kind[fd] == 1 ? fd_state[fd] : NULL;
  pthread_mutex_unlock(&lock);
  return st;
}

ssize_t read(int fd, void *buf, size_t count) {
  struct tp_state *st;
  struct input_event out[MAX_OUT_EVENTS];
  size_t cap, n = 0;
  int done = 0;

  if (!active || fd < 0 || fd >= FD_LIMIT || count < sizeof(struct input_event))
    return raw_read(fd, buf, count);

  if (fd_kind[fd] == 2)
    return raw_read(fd, buf, count);

  st = ensure_state(fd);
  if (!st)
    return raw_read(fd, buf, count);

  cap = count / sizeof(struct input_event);
  if (cap > MAX_OUT_EVENTS)
    cap = MAX_OUT_EVENTS;

  pthread_mutex_lock(&lock);
  for (;;) {
    struct input_event ev;
    ssize_t r = raw_read(fd, &ev, sizeof(ev));

    if (r == (ssize_t)sizeof(ev)) {
      translate_event(st, &ev, out, &n, cap, &done);
      if (done && n > 0)
        break;
      continue;
    }
    pthread_mutex_unlock(&lock);
    if (r < 0)
      return -1; /* keep errno (EAGAIN/EINTR/...) */
    return r;    /* 0 or a short read: nothing usable */
  }
  pthread_mutex_unlock(&lock);

  memcpy(buf, out, n * sizeof(struct input_event));
  return (ssize_t)(n * sizeof(struct input_event));
}

int close(int fd) {
  struct tp_state *st = NULL;

  if (active && fd >= 0 && fd < FD_LIMIT) {
    pthread_mutex_lock(&lock);
    if (fd_kind[fd] == 1)
      st = fd_state[fd];
    fd_state[fd] = NULL;
    fd_kind[fd] = 0; /* allow a reused fd number to be re-probed */
    pthread_mutex_unlock(&lock);
    free(st);
  }
  return raw_close(fd);
}

__attribute__((constructor)) static void ash_touchpad_init(void) {
  active = detect_active();
  dbg(1, "loaded in pid %d (active=%d)\n", (int)getpid(), active);
}
