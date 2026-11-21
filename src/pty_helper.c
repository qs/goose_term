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
extern SDL_Window **SDL_GetWindows(int *count);
extern bool SDL_SetWindowBordered(SDL_Window *window, bool bordered);
extern bool SDL_SetWindowFullscreen(SDL_Window *window, bool fullscreen);
extern bool SDL_GetWindowPosition(SDL_Window *window, int *x, int *y);
extern bool SDL_SetWindowPosition(SDL_Window *window, int x, int y);
extern uint32_t SDL_GetGlobalMouseState(float *x, float *y);
extern char *SDL_GetPrimarySelectionText(void);
extern bool SDL_SetPrimarySelectionText(const char *text);
extern bool SDL_OpenURL(const char *url);
extern void SDL_free(void *mem);

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
int32_t gt_spawn_pty(struct gt_slice_in shell, int32_t rows, int32_t cols,
                     int32_t *master_fd, int32_t *child_pid) {
    char path[1024];
    if (shell.len <= 0 || shell.len >= (int64_t)sizeof(path)) return -1;
    memcpy(path, shell.data, (size_t)shell.len);
    path[shell.len] = 0;

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;
    if (pid == 0) {
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

// Write as much as the PTY will take without blocking; the count written.
int32_t gt_write_pty(int32_t master_fd, struct gt_slice_in buf, int32_t len) {
    int32_t want = (int32_t)(buf.len < len ? buf.len : len);
    int32_t done = 0;
    while (done < want) {
        ssize_t n = write(master_fd, buf.data + done, (size_t)(want - done));
        if (n > 0) {
            done += (int32_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    return done;
}

// Hang up the child's whole process group, not just the shell: a foreground
// job (`sleep 100`, an editor) would otherwise keep the PTY open and leave
// the close waiting. Closing the master and SIGKILLing the group finish it,
// and reaping is bounded so a stuck child can never freeze the UI.
void gt_close_pty(int32_t master_fd, int32_t child_pid) {
    if (child_pid > 0) {
        killpg(child_pid, SIGHUP);
        killpg(child_pid, SIGTERM);
    }
    if (master_fd >= 0) close(master_fd);
    if (child_pid > 0) {
        killpg(child_pid, SIGKILL);
        for (int i = 0; i < 20; i++) {
            int status = 0;
            pid_t r = waitpid(child_pid, &status, WNOHANG);
            if (r == child_pid || (r < 0 && errno == ECHILD)) break;
            usleep(1000);
        }
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

// Idle pacing for the frame loop, which would otherwise spin when there is
// nothing to draw.
void gt_sleep_ms(int32_t ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
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
