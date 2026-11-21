// The POSIX PTY layer. All the C lives in pty_helper.c; these are the five
// bindings the spec calls for, plus the window-decoration and window-drag
// hooks gfx does not expose.

namespace pty;

import std;

struct Pty {
    fd: i32 = -1,
    pid: i32 = -1,
    alive: bool = false,
}

extern fn gt_spawn_pty(shell: const u8[:], rows: i32, cols: i32,
                       master_fd: i32&, child_pid: i32&) -> i32;
extern fn gt_resize_pty(master_fd: i32, rows: i32, cols: i32) -> i32;
extern fn gt_read_pty(master_fd: i32, buf: u8[:], max_len: i32) -> i32;
extern fn gt_write_pty(master_fd: i32, buf: const u8[:], len: i32) -> i32;
extern fn gt_close_pty(master_fd: i32, child_pid: i32);
extern fn gt_set_borderless(on: i32) -> i32;
extern fn gt_set_fullscreen(on: i32) -> i32;
extern fn gt_begin_window_drag() -> i32;
extern fn gt_update_window_drag();
extern fn gt_end_window_drag();
extern fn gt_sleep_ms(ms: i32);
extern fn gt_wait_pty(fds: const i32[:], timeout_ms: i32) -> i32;
extern fn gt_spawn_error(out: u8[:]) -> i32;
extern fn gt_child_exit(child_pid: i32) -> i32;
extern fn gt_set_ime_area(x: i32, y: i32, w: i32, h: i32) -> i32;
extern fn gt_get_primary(buf: u8[:]) -> i32;
extern fn gt_set_primary(text: const u8[:]) -> i32;
extern fn gt_open_url(url: const u8[:]) -> i32;

fn spawn(shell: const u8[:], rows: i64, cols: i64) -> Pty {
    var fd: i32 = -1;
    var pid: i32 = -1;
    gt_spawn_pty(shell, rows as i32, cols as i32, fd, pid);
    Pty { fd: fd, pid: pid, alive: fd >= 0 }
}

fn read(p: Pty&, buf: u8[:]) -> i64 {
    if !p.alive || p.fd < 0 { return -1; }
    let n = gt_read_pty(p.fd, buf, buf.len as i32);
    if n == 0 { p.alive = false; }
    return n;
}

fn write_bytes(p: Pty&, data: const u8[:]) -> i64 {
    if !p.alive || p.fd < 0 || data.len == 0 { return 0; }
    return gt_write_pty(p.fd, data, data.len as i32);
}

// The exit code if the child has already been reaped, else -1.
fn exit_code(p: Pty&) -> i64 {
    if p.pid <= 0 { return -1; }
    return gt_child_exit(p.pid);
}

fn resize(p: Pty&, rows: i64, cols: i64) {
    if !p.alive || p.fd < 0 { return; }
    gt_resize_pty(p.fd, rows as i32, cols as i32);
}

fn close(p: Pty&) {
    if p.fd >= 0 || p.pid > 0 {
        gt_close_pty(p.fd, p.pid);
    }
    p.fd = -1;
    p.pid = -1;
    p.alive = false;
}

// Ask SDL to drop the window decorations.
fn set_borderless(on: bool) {
    gt_set_borderless(if on { 1 } else { 0 });
}

// Desktop fullscreen, or the borderless window again.
fn set_fullscreen(on: bool) {
    gt_set_fullscreen(if on { 1 } else { 0 });
}

// Start moving the window from the pointer's current position. False when
// there is no window to move.
fn drag_begin() -> bool {
    return gt_begin_window_drag() != 0;
}

// Move the window to follow the pointer, from the point drag_begin took.
fn drag_update() {
    gt_update_window_drag();
}

fn drag_end() {
    gt_end_window_drag();
}

// Idle pacing: lets the frame loop rest without a busy spin.
fn sleep_ms(ms: i64) {
    if ms > 0 { gt_sleep_ms(ms as i32); }
}

// Block until one of these PTY masters has bytes to read, or the timeout
// passes. Wake-ups on output only: a quiet terminal stays asleep instead of
// polling four times a millisecond.
fn wait(fds: const i32[:], timeout_ms: i64) {
    gt_wait_pty(fds, timeout_ms as i32);
}

// Why the last spawn failed, as the C library words it. False when there is
// nothing to report.
fn spawn_error(out: u8[>..]&) -> bool {
    out.resize(256, 0);
    let n = gt_spawn_error(out);
    if n <= 0 {
        out.clear();
        return false;
    }
    out.resize(n, 0);
    return true;
}

// Point the IME's candidate window at the text cursor.
fn set_ime_area(x: f32, y: f32, w: f32, h: f32) {
    gt_set_ime_area(x as i32, y as i32, w as i32, h as i32);
}

// The X11/Wayland PRIMARY selection, which middle-click paste uses. SDL
// owns the buffer; C copies it out before freeing it. macOS has no such
// selection, so there the calls read nothing and set nothing.
fn get_primary(out: u8[:]) -> i64 {
    return gt_get_primary(out);
}

fn set_primary(text: const u8[:]) -> bool {
    return gt_set_primary(text) != 0;
}

// Hand a URI to the desktop's URL handler. OSC 8 hyperlinks use this.
fn open_url(url: const u8[:]) -> bool {
    return gt_open_url(url) != 0;
}
