// libdisplayfix: loaded into the Ash Chrome process.
//
// Ash is a ChromeOS build: it assumes an X display already exists and that
// XAUTHORITY points at a readable cookie. Under a plain Linux session neither
// is guaranteed (started from a TTY, a display manager that keeps its cookie
// private, ...), so fill the gaps before main() runs.
//
// Because the launcher preloads this into every Chrome child process it stays
// silent unless it actually had to fix DISPLAY.
#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>

static void wlog(const char* m) {
  int fd = open("/tmp/xwrap.log", O_WRONLY|O_CREAT|O_APPEND, 0666);
  if (fd >= 0) { write(fd, m, strlen(m)); close(fd); }
}

// Pick the HOST X display instead of assuming :0. startx takes the first free
// :N, so the real session may sit on :1 — while the Xwayland serving Linux apps
// is always :10 (hard-set by the session). The lowest socket is therefore the
// host display Chrome must reach; :10 would be the wrong target. Fails (-1)
// only when no X socket exists at all.
static int lowest_x_socket(char* path, size_t len) {
  DIR* d = opendir("/tmp/.X11-unix");
  if (!d) return -1;
  int best = -1;
  struct dirent* e;
  while ((e = readdir(d)) != NULL) {
    if (e->d_name[0] != 'X') continue;
    char* end = NULL;
    long n = strtol(e->d_name + 1, &end, 10);
    if (end == e->d_name + 1 || *end != '\0' || n < 0 || n > 63) continue;
    if (best < 0 || n < best) best = (int)n;
  }
  closedir(d);
  if (best < 0) return -1;
  snprintf(path, len, "/tmp/.X11-unix/X%d", best);
  return best;
}

__attribute__((constructor(101)))
static void fix_display(void) {
  char buf[512];
  pid_t pid = getpid();
  const char* d = getenv("DISPLAY");

  setenv("XAUTHORITY", "/tmp/ash-xauth", 1);
  if (d && d[0]) {
    return;  /* sane environment, nothing to log */
  }

  char sock[64];
  int n = lowest_x_socket(sock, sizeof sock);
  if (n < 0) {
    setenv("DISPLAY", ":0", 1);   /* no socket anywhere — conventional guess */
    snprintf(buf, sizeof(buf), "[fix] pid=%d DISPLAY was unset, no X socket -> :0\n",
             (int)pid);
    wlog(buf);
    return;
  }

  char disp[16];
  snprintf(disp, sizeof disp, ":%d", n);
  setenv("DISPLAY", disp, 1);

  struct stat st;
  int sr = stat(sock, &st);
  snprintf(buf, sizeof(buf), "[fix] pid=%d DISPLAY was unset -> %s (low socket %s); stat=%d\n",
           (int)pid, disp, sock, sr);
  wlog(buf);

  if (sr == 0) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s >= 0) {
      struct sockaddr_un addr;
      memset(&addr, 0, sizeof(addr));
      addr.sun_family = AF_UNIX;
      strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1);
      errno = 0;
      int cr = connect(s, (struct sockaddr*)&addr, sizeof(addr));
      snprintf(buf, sizeof(buf), "[fix] pid=%d connect(%s)=%d errno=%d\n",
               (int)pid, sock, cr, errno);
      wlog(buf);
      close(s);
    }
  }
}
