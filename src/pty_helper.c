// The C side of the terminal's PTY and window handling. Everything that is
// awkward or impossible from Goose lives here: forkpty, the variadic ioctl,
// non-blocking reads and writes, and the SDL3 calls gfx does not expose.
//
// Goose slices cross the boundary as { data, len } structs, and `T&`
// parameters as pointers, so the signatures below match what
// src/pty.goose declares.
//
// Linux and macOS share the whole file: both have the POSIX pieces, and only
// the header that declares forkpty differs.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

// forkpty: glibc declares it in <pty.h> (hence _GNU_SOURCE above), macOS in
// <util.h>, and links it from libSystem.
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

// SDL3, declared by hand: this file is compiled on its own, and the gfx
// package supplies the SDL it needs at link time.
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Surface SDL_Surface;
typedef struct SDL_IOStream SDL_IOStream;
typedef struct SDL_Rect {
    int x, y, w, h;
} SDL_Rect;
extern SDL_Window **SDL_GetWindows(int *count);
extern bool SDL_SetTextInputArea(SDL_Window *window, const SDL_Rect *rect, int cursor);
extern bool SDL_SetWindowBordered(SDL_Window *window, bool bordered);
extern bool SDL_SetWindowFullscreen(SDL_Window *window, bool fullscreen);
extern bool SDL_GetWindowPosition(SDL_Window *window, int *x, int *y);
extern bool SDL_SetWindowPosition(SDL_Window *window, int x, int y);
extern uint32_t SDL_GetGlobalMouseState(float *x, float *y);
extern char *SDL_GetPrimarySelectionText(void);
extern bool SDL_SetPrimarySelectionText(const char *text);
extern bool SDL_OpenURL(const char *url);
extern void SDL_free(void *mem);
extern bool SDL_SetWindowIcon(SDL_Window *window, SDL_Surface *icon);
extern void SDL_DestroySurface(SDL_Surface *surface);
extern SDL_IOStream *SDL_IOFromConstMem(const void *mem, size_t size);
extern SDL_Surface *SDL_LoadBMP_IO(SDL_IOStream *src, bool closeio);

struct gt_slice_in {
    const uint8_t *data;
    int64_t len;
};

struct gt_slice_mut {
    uint8_t *data;
    int64_t len;
};

// Spawn `shell` on a fresh PTY with a `rows` x `cols` window. Returns the
// master fd, or -1 with errno set. The child gets TERM=xterm-256color and a
// non-blocking master is handed back.
// The errno of the last failed spawn, for gt_spawn_error.
static int gt_spawn_errno = 0;

int32_t gt_spawn_pty(struct gt_slice_in shell, int32_t rows, int32_t cols,
                     int32_t *master_fd, int32_t *child_pid) {
    gt_spawn_errno = 0;
    char path[1024];
    if (shell.len <= 0 || shell.len >= (int64_t)sizeof(path)) {
        gt_spawn_errno = EINVAL;
        return -1;
    }
    memcpy(path, shell.data, (size_t)shell.len);
    path[shell.len] = 0;

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);

    // A write to a master whose child has just exited must come back as
    // EPIPE, not kill the whole terminal with SIGPIPE.
    signal(SIGPIPE, SIG_IGN);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        gt_spawn_errno = errno;
        return -1;
    }
    if (pid == 0) {
        // The shell starts with the default disposition, not ours.
        signal(SIGPIPE, SIG_DFL);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        unsetenv("LINES");
        unsetenv("COLUMNS");
        char *argv[] = { path, NULL };
        execv(path, argv);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    fcntl(master, F_SETFD, FD_CLOEXEC);
    *master_fd = master;
    *child_pid = (int32_t)pid;
    return master;
}

// Tell the kernel the terminal's new size; it sends SIGWINCH to the child.
int32_t gt_resize_pty(int32_t master_fd, int32_t rows, int32_t cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

// Read up to max_len bytes without blocking. Returns the count, 0 at end of
// file (the child is gone), and -1 when there is simply nothing to read yet.
int32_t gt_read_pty(int32_t master_fd, struct gt_slice_mut buf, int32_t max_len) {
    int32_t want = (int32_t)(buf.len < max_len ? buf.len : max_len);
    if (want <= 0) return -1;
    ssize_t n = read(master_fd, buf.data, (size_t)want);
    if (n > 0) return (int32_t)n;
    if (n == 0) return 0;
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
    return 0;
}

// A single write may wait this long for a program that is behind on its
// input: long enough for a shell to drain a paste, short enough never to
// stall the UI. What is still unwritten after the retries is reported back,
// so the caller can say so instead of dropping it silently.
#define GT_WRITE_WAIT_MS 10
#define GT_WRITE_RETRIES 2

int32_t gt_write_pty(int32_t master_fd, struct gt_slice_in buf, int32_t len) {
    int32_t want = (int32_t)(buf.len < len ? buf.len : len);
    int32_t done = 0;
    int waits = 0;
    while (done < want) {
        ssize_t n = write(master_fd, buf.data + done, (size_t)(want - done));
        if (n > 0) {
            done += (int32_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && waits < GT_WRITE_RETRIES) {
            struct pollfd p;
            p.fd = master_fd;
            p.events = POLLOUT;
            p.revents = 0;
            if (poll(&p, 1, GT_WRITE_WAIT_MS) <= 0) break;
            waits++;
            continue;
        }
        break;
    }
    return done;
}

// Hang up the child's whole process group, not just the shell: a foreground
// job (`sleep 100`, an editor) would otherwise keep the PTY open and leave
// the close waiting. The escalation gives each signal a short grace period
// first, so a shell runs its own exit path (saving history, killing jobs)
// instead of being killed outright; reaping is bounded so a stuck child can
// never freeze the UI.
void gt_close_pty(int32_t master_fd, int32_t child_pid) {
    if (child_pid > 0) killpg(child_pid, SIGHUP);
    if (master_fd >= 0) close(master_fd);
    if (child_pid <= 0) return;
    for (int i = 0; i < 100; i++) {
        int status = 0;
        pid_t r = waitpid(child_pid, &status, WNOHANG);
        if (r == child_pid || (r < 0 && errno == ECHILD)) return;
        if (i == 30) killpg(child_pid, SIGTERM);
        else if (i == 60) killpg(child_pid, SIGKILL);
        usleep(1000);
    }
}

// gfx opens its window with SDL's decorations; strip them for a borderless
// terminal. It is the only SDL window this process makes, so it is the one
// SDL lists.
int32_t gt_set_borderless(int32_t on) {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows || count <= 0) return 0;
    return SDL_SetWindowBordered(windows[0], on == 0);
}

// The window icon, for the taskbar and the window switcher. The bitmap is
// embedded in the executable, so there is no file to find at run time.
// Wayland ignores this (the icon comes from the .desktop file), and macOS
// takes a plain executable's dock icon from its bundle.
int32_t gt_set_window_icon(struct gt_slice_in bmp) {
    if (bmp.len <= 0 || bmp.data == NULL) return 0;
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows || count <= 0) return 0;
    SDL_IOStream *io = SDL_IOFromConstMem(bmp.data, (size_t)bmp.len);
    if (!io) return 0;
    // closeio: the stream reads from the embedded bytes and is ours to free.
    SDL_Surface *icon = SDL_LoadBMP_IO(io, true);
    if (!icon) return 0;
    bool ok = SDL_SetWindowIcon(windows[0], icon);
    SDL_DestroySurface(icon);
    return ok ? 1 : 0;
}

// Idle pacing for the frame loop, which would otherwise spin when there is
// nothing to draw.
void gt_sleep_ms(int32_t ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

// Block until one of the given PTY masters is readable, or the timeout
// passes. The frame loop uses this to sleep instead of polling, so a quiet
// terminal costs no CPU and an echoing one is still answered immediately.
int32_t gt_wait_pty(struct gt_slice_in fds, int32_t timeout_ms) {
    const int32_t *in = (const int32_t *)fds.data;
    int32_t n = (int32_t)(fds.len / (int64_t)sizeof(int32_t));
    struct pollfd p[64];
    if (n > 64) n = 64;
    nfds_t used = 0;
    for (int32_t i = 0; i < n; i++) {
        if (in[i] < 0) continue;
        p[used].fd = in[i];
        p[used].events = POLLIN;
        p[used].revents = 0;
        used++;
    }
    if (used == 0) {
        gt_sleep_ms(timeout_ms);
        return 0;
    }
    int r = poll(p, used, timeout_ms > 0 ? timeout_ms : 0);
    if (r <= 0) return 0;
    for (nfds_t i = 0; i < used; i++) {
        if ((p[i].revents & POLLIN) != 0) return 1;
    }
    return 0;
}

// Where SDL should put the IME's candidate window: beside the text cursor,
// rather than at whatever spot the platform last remembered.
int32_t gt_set_ime_area(int32_t x, int32_t y, int32_t w, int32_t h) {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows || count <= 0) return 0;
    SDL_Rect rect;
    rect.x = x;
    rect.y = y;
    rect.w = w;
    rect.h = h;
    return SDL_SetTextInputArea(windows[0], &rect, 0) ? 1 : 0;
}

// The child's exit code if it has already exited, else -1. Used to tell an
// exec failure (127) apart from a shell that simply exited.
int32_t gt_child_exit(int32_t child_pid) {
    if (child_pid <= 0) return -1;
    int status = 0;
    pid_t r = waitpid(child_pid, &status, WNOHANG);
    if (r != child_pid) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

// The message for the last failed spawn, which gt_spawn_pty recorded.
int32_t gt_spawn_error(struct gt_slice_mut buf) {
    if (gt_spawn_errno == 0) return 0;
    const char *msg = strerror(gt_spawn_errno);
    int32_t len = (int32_t)strlen(msg);
    int32_t n = len < (int32_t)buf.len ? len : (int32_t)buf.len;
    if (n > 0 && buf.data) memcpy(buf.data, msg, (size_t)n);
    gt_spawn_errno = 0;
    return n;
}

// Desktop fullscreen for the same window, which v1 of the gfx package does
// not expose.
int32_t gt_set_fullscreen(int32_t on) {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows || count <= 0) return 0;
    return SDL_SetWindowFullscreen(windows[0], on != 0);
}

// Copy the PRIMARY selection into a caller-owned buffer. Returns the length
// copied (which may be capped) and 0 when there is no selection.
int32_t gt_get_primary(struct gt_slice_mut buf) {
    char *text = SDL_GetPrimarySelectionText();
    if (!text) return 0;
    size_t len = strlen(text);
    size_t n = len < (size_t)buf.len ? len : (size_t)buf.len;
    if (n > 0 && buf.data) memcpy(buf.data, text, n);
    SDL_free(text);
    return (int32_t)n;
}

int32_t gt_set_primary(struct gt_slice_in text) {
    if (text.len <= 0 || text.len > 65536) return 0;
    char *copy = malloc((size_t)text.len + 1);
    if (!copy) return 0;
    memcpy(copy, text.data, (size_t)text.len);
    copy[text.len] = 0;
    bool ok = SDL_SetPrimarySelectionText(copy);
    free(copy);
    return ok ? 1 : 0;
}

int32_t gt_open_url(struct gt_slice_in url) {
    if (url.len <= 0 || url.len >= 4096) return 0;
    char copy[4096];
    memcpy(copy, url.data, (size_t)url.len);
    copy[url.len] = 0;
    return SDL_OpenURL(copy) ? 1 : 0;
}

// Borderless windows have no title bar, so nothing in the platform moves them
// and the drag is ours to do. The pointer's position inside the window cannot
// measure it: the window moves under a stationary pointer. The global mouse
// position can, so the press records the window's position and that global
// point once, and every update applies the delta from it. Re-applying from
// the same anchor keeps the window exactly under the pointer rather than
// accumulating rounding error frame by frame.
static int gt_drag_win_x = 0;
static int gt_drag_win_y = 0;
static float gt_drag_mouse_x = 0.0f;
static float gt_drag_mouse_y = 0.0f;
static int gt_dragging = 0;

int32_t gt_begin_window_drag(void) {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows || count <= 0) return 0;
    if (!SDL_GetWindowPosition(windows[0], &gt_drag_win_x, &gt_drag_win_y)) return 0;
    // The return value is the button mask, not success: ignore it.
    SDL_GetGlobalMouseState(&gt_drag_mouse_x, &gt_drag_mouse_y);
    gt_dragging = 1;
    return 1;
}

void gt_update_window_drag(void) {
    if (!gt_dragging) return;
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows || count <= 0) {
        gt_dragging = 0;
        return;
    }
    float mx = gt_drag_mouse_x;
    float my = gt_drag_mouse_y;
    SDL_GetGlobalMouseState(&mx, &my);
    int dx = (int)(mx - gt_drag_mouse_x);
    int dy = (int)(my - gt_drag_mouse_y);
    SDL_SetWindowPosition(windows[0], gt_drag_win_x + dx, gt_drag_win_y + dy);
}

void gt_end_window_drag(void) {
    gt_dragging = 0;
}
