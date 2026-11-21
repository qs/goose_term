// goose-term: a minimal GPU terminal emulator.
//
// The window event loop lives here. Every frame it takes gfx's input, sends
// translated keystrokes to the active PTY, drains every tab's PTY (with a
// byte budget so a flood cannot stall the UI), and resizes the grids to the
// window. It draws the grid and the vertical tab sidebar only when something
// changed; idle frames present the last image.

import std;
import os;
import gfx;
import ui;
import slice_pool;
import .buffer;
import .parser;
import .pty;
import .tab;
import .input;
import .renderer;
import .search;

const MAX_TABS: i64 = 16;
const AUTO_HIDE_SIDEBAR: bool = true;
const READ_BUDGET: i64 = 65536;
const WHEEL_LINES: f32 = 3.0;
const DEFAULT_FONT_PX: f32 = 20.0;
const PRIMARY_CAP: i64 = 65536;

// Touchpad momentum. Wheel deltas are applied immediately; after a short
// quiet gap the last measured velocity coasts and decays. Keeping the gap
// avoids adding momentum while the fingers are still sending deltas.
const MOMENTUM_DELAY: f64 = 0.055;
const MOMENTUM_RESET: f64 = 0.18;
const MOMENTUM_DECAY: f64 = 6.0;
const MOMENTUM_MIN: f32 = 10.0;
const MOMENTUM_MAX: f32 = 5000.0;
const MOMENTUM_DT_MAX: f64 = 0.05;
// Cap the smooth-scroll redraw rate at ~125 Hz instead of spinning as fast as
// the window system accepts presents.
const MOMENTUM_FRAME_MS: i64 = 8;

var cells = slice_pool<buffer::Cell> {};
var tabs: tab::Tab[>..] = [];
var active: i64 = 0;
var rend = renderer::Renderer { .. };
var font_px: f32 = DEFAULT_FONT_PX;
var running = true;
var selecting = false;
var is_fullscreen = false;
var dirty = true;
var cursor_on = true;
var last_blink = 0.0;
var click_count: i64 = 1;
var scroll_vel: f32 = 0.0;
var last_wheel_time: f64 = 0.0;
var last_tick: f64 = 0.0;
var search_state = search::State { .. };
var mouse_last_col: i64 = -1;
var mouse_last_row: i64 = -1;
var dragging = false;

// --- layout ----------------------------------------------------------------

fn show_sidebar() -> bool {
    return !AUTO_HIDE_SIDEBAR || tabs.len > 1;
}

fn content_origin() -> float2 {
    var x = renderer::PAD;
    if show_sidebar() {
        let sz = gfx::screen_size();
        x += renderer::sidebar_width(rend, sz.x);
    }
    return float2 { x, renderer::PAD };
}

fn grid_dims() -> i64, i64 {
    let sz = gfx::screen_size();
    let cs = renderer::cell_size(rend);
    let ox = content_origin().x;
    let cols = max(2, ((sz.x - ox - renderer::PAD) / cs.x) as i64);
    let rows = max(1, ((sz.y - renderer::PAD * 2.0) / cs.y) as i64);
    return cols, rows;
}

fn clamp_scroll(t: tab::Tab&) {
    if t.term.alt_active {
        stop_momentum();
        t.scroll = 0;
        t.scroll_frac = 0.0;
        return;
    }
    t.scroll = clamp(t.scroll, 0, t.term.hist_count);
    if t.scroll >= t.term.hist_count {
        t.scroll = t.term.hist_count;
        t.scroll_frac = 0.0;
        stop_momentum();
        return;
    }
    let ch = renderer::cell_size(rend).y;
    if t.scroll_frac < 0.0 || t.scroll_frac >= ch {
        t.scroll_frac = 0.0;
        stop_momentum();
    }
}

fn update_layout() {
    if tabs.len == 0 { return; }
    let cols, rows = grid_dims();
    for i in tabs.len {
        if tabs[i].term.cols != cols || tabs[i].term.rows != rows {
            stop_momentum();
            tab::resize(tabs[i], cells, cols, rows);
            dirty = true;
        }
        clamp_scroll(tabs[i]);
    }
}

// --- tabs ------------------------------------------------------------------

fn shell_path() -> u8[>..] {
    var out: u8[>..] = [];
    if env("SHELL", out) && out.len > 0 { return out; }
    out.clear();
    out.append("/bin/sh");
    return out;
}

fn update_title() {
    var s: u8[>..] = [];
    if tabs.len == 0 {
        s.append("goose-term");
    } else {
        if tabs[active].title.len > 0 {
            s.append(tabs[active].title);
        } else {
            s.append("goose-term");
        }
        s.append(" - goose-term");
    }
    gfx::set_title(s);
}

fn close_search_on_tab_change() {
    if search_state.active { search::close(search_state); }
}

fn spawn_tab() {
    if tabs.len >= MAX_TABS { return; }
    stop_momentum();
    close_search_on_tab_change();
    let cols, rows = grid_dims();
    let shell = shell_path();
    tabs.push(tab::create(shell, cells, cols, rows));
    active = tabs.len - 1;
    update_title();
    dirty = true;
}

fn close_tab_at(i: i64) {
    if i < 0 || i >= tabs.len { return; }
    if i == active {
        stop_momentum();
        close_search_on_tab_change();
    }
    tab::close(tabs[i]);
    remove_at(tabs, i);
    dirty = true;
    if tabs.len == 0 {
        active = 0;
        running = false;
        gfx::quit();
        return;
    }
    if active > i { active -= 1; }
    if active >= tabs.len { active = tabs.len - 1; }
    update_title();
}

fn close_active() {
    close_tab_at(active);
}

fn next_tab() {
    if tabs.len == 0 { return; }
    stop_momentum();
    close_search_on_tab_change();
    active = (active + 1) % tabs.len;
    update_title();
    dirty = true;
}

fn prev_tab() {
    if tabs.len == 0 { return; }
    stop_momentum();
    close_search_on_tab_change();
    active = (active - 1 + tabs.len) % tabs.len;
    update_title();
    dirty = true;
}

fn jump_tab(i: i64) {
    if i >= 0 && i < tabs.len {
        stop_momentum();
        close_search_on_tab_change();
        active = i;
        update_title();
        dirty = true;
    }
}

// --- pty -------------------------------------------------------------------

fn write_pty(data: const u8[:]) {
    if tabs.len == 0 || data.len == 0 { return; }
    tab::write_bytes(tabs[active], data);
}

fn send(data: const u8[:]) {
    if tabs.len == 0 || data.len == 0 { return; }
    stop_momentum();
    write_pty(data);
    if !tabs[active].term.alt_active &&
       (tabs[active].scroll != 0 || tabs[active].scroll_frac > 0.001) {
        tabs[active].scroll = 0;
        tabs[active].scroll_frac = 0.0;
        dirty = true;
    }
    if !cursor_on {
        cursor_on = true;
        dirty = true;
    }
    last_blink = gfx::time();
}

fn apply_clipboard_events(i: i64) {
    if !tabs[i].parser.clipboard_pending { return; }
    let n = tabs[i].parser.clipboard_len;
    if n > 0 {
        if tabs[i].parser.clipboard_primary {
            pty::set_primary(tabs[i].parser.clipboard[..n]);
        } else {
            gfx::set_clipboard(tabs[i].parser.clipboard[..n]);
        }
    }
    tabs[i].parser.clipboard_pending = false;
    tabs[i].parser.clipboard_len = 0;
}

fn pump_all() {
    var buf: u8[8192] = [0; 8192];
    for i in tabs.len {
        if !tabs[i].proc.alive { continue; }
        let before_hist = tabs[i].term.hist_count;
        let before_alt = tabs[i].term.alt_active;
        var budget = READ_BUDGET;
        while budget > 0 {
            // Never read past the budget: bytes over it would be dropped.
            let want = min(8192, budget);
            let n = pty::read(tabs[i].proc, buf[..want]);
            if n < 0 { break; }
            if n == 0 {
                tabs[i].alive = false;
                break;
            }
            parser::feed(tabs[i].parser, tabs[i].term, cells, buf[..n]);
            dirty = true;
            budget -= n;
            if n < want { break; }
        }
        apply_clipboard_events(i);
        if tabs[i].parser.title_changed {
            tabs[i].title.clear();
            var k = 0;
            while k < tabs[i].parser.title.len {
                tabs[i].title.push(tabs[i].parser.title[k]);
                k++;
            }
            tabs[i].parser.title_changed = false;
            dirty = true;
            if i == active { update_title(); }
        }
        if tabs[i].term.alt_active != before_alt {
            // Selections and the viewport are tied to the normal screen;
            // full-screen apps own the alt screen.
            tabs[i].sel_active = false;
            tabs[i].scroll = 0;
            tabs[i].scroll_frac = 0.0;
            if i == active { close_search_on_tab_change(); }
            dirty = true;
        }
        // While scrolled up, keep the viewport on the same lines as new
        // output arrives instead of dragging it toward the bottom.
        let added = tabs[i].term.hist_count - before_hist;
        if !tabs[i].term.alt_active && added > 0 &&
           (tabs[i].scroll > 0 || tabs[i].scroll_frac > 0.001) {
            tabs[i].scroll += added;
        }
        clamp_scroll(tabs[i]);
    }

    // End of file on the PTY means the shell is gone: Ctrl+D, `exit`, or a
    // crash. Finish the tab instead of leaving a dead prompt behind.
    var i = tabs.len - 1;
    while i >= 0 {
        if !tabs[i].alive {
            close_tab_at(i);
            if !running { return; }
        }
        i--;
    }
}

// --- scrolling and clipboard ----------------------------------------------

fn stop_momentum() {
    scroll_vel = 0.0;
    last_wheel_time = 0.0;
}

fn momentum_coasting() -> bool {
    return scroll_vel != 0.0 && gfx::time() - last_wheel_time >= MOMENTUM_DELAY;
}

fn update_momentum(now: f64, dt: f64) {
    if scroll_vel == 0.0 { return; }
    if tabs.len == 0 || tabs[active].term.alt_active {
        scroll_vel = 0.0;
        return;
    }
    // Do not add motion while the fingers are still producing deltas.
    if now - last_wheel_time < MOMENTUM_DELAY { return; }
    if dt <= 0.0 { return; }

    let before = scroll_pixels(tabs[active]);
    set_scroll_pixels(tabs[active], before + scroll_vel * (dt as f32));
    let after = scroll_pixels(tabs[active]);
    // Reaching either end stops the coast instead of pinning a useless
    // velocity against the boundary.
    if abs(after - before) < 0.001 {
        scroll_vel = 0.0;
        return;
    }
    dirty = true;

    scroll_vel *= exp(-MOMENTUM_DECAY * dt) as f32;
    if abs(scroll_vel) < MOMENTUM_MIN { scroll_vel = 0.0; }
}

fn scroll_pixels(t: tab::Tab&) -> f32 {
    return t.scroll * renderer::cell_size(rend).y + t.scroll_frac;
}

fn set_scroll_pixels(t: tab::Tab&, px: f32) {
    let ch = renderer::cell_size(rend).y;
    if ch <= 0.0 { return; }
    let max_px = t.term.hist_count * ch;
    var p = px;
    if p < 0.0 { p = 0.0; }
    if p > max_px { p = max_px; }
    t.scroll = (p / ch) as i64;
    t.scroll_frac = p - t.scroll * ch;
    if t.scroll >= t.term.hist_count {
        t.scroll = t.term.hist_count;
        t.scroll_frac = 0.0;
    } else if t.scroll_frac < 0.001 {
        t.scroll_frac = 0.0;
    }
}

fn scroll_by_pixels(dy: f32) {
    if tabs.len == 0 || tabs[active].term.alt_active { return; }
    set_scroll_pixels(tabs[active], scroll_pixels(tabs[active]) + dy);
    dirty = true;
}

fn scroll_by(lines: i64) {
    stop_momentum();
    let ch = renderer::cell_size(rend).y;
    scroll_by_pixels(lines * ch);
}

fn scroll_wheel(wheel: f32) {
    if wheel == 0.0 || tabs.len == 0 || tabs[active].term.alt_active { return; }
    let ch = renderer::cell_size(rend).y;
    // SDL's sign as it arrives: positive is up, toward the scrollback. A
    // desktop with natural scrolling already flips touchpad deltas before
    // they get here, so flipping again here scrolled the wrong way.
    let dy = wheel * WHEEL_LINES * ch;

    // Seed the coast from the rate of the wheel stream. The first event after
    // a long pause only scrolls normally; subsequent events build the velocity
    // used once the stream goes quiet.
    let now = gfx::time();
    let gap = now - last_wheel_time;
    if gap > 0.0 && gap <= MOMENTUM_RESET {
        let sample_dt = max(gap, 0.004);
        let inst = clamp(dy / (sample_dt as f32), -MOMENTUM_MAX, MOMENTUM_MAX);
        let same_dir = (inst > 0.0) == (scroll_vel > 0.0);
        if gap > MOMENTUM_DELAY || !same_dir || scroll_vel == 0.0 {
            scroll_vel = inst;
        } else if abs(inst) > abs(scroll_vel) {
            // Keep the peak speed of a flick rather than letting its final
            // low-delta event erase the momentum.
            scroll_vel = inst;
        } else {
            scroll_vel += (inst - scroll_vel) * 0.35;
        }
    } else {
        scroll_vel = 0.0;
    }
    last_wheel_time = now;
    scroll_by_pixels(dy);
}

fn scroll_page(direction: i64) {
    if tabs.len == 0 { return; }
    let page = max(tabs[active].term.rows - 1, 1);
    scroll_by(direction * page);
}

fn scroll_top() {
    if tabs.len == 0 || tabs[active].term.alt_active { return; }
    stop_momentum();
    tabs[active].scroll = tabs[active].term.hist_count;
    tabs[active].scroll_frac = 0.0;
    dirty = true;
}

fn scroll_bottom() {
    if tabs.len == 0 { return; }
    stop_momentum();
    tabs[active].scroll = 0;
    tabs[active].scroll_frac = 0.0;
    dirty = true;
}

fn copy_selection() {
    if tabs.len == 0 { return; }
    let text = tab::selection_text(tabs[active], cells);
    if text.len > 0 { gfx::set_clipboard(text); }
}

fn paste_text(text: const u8[:]) {
    if tabs.len == 0 || text.len == 0 { return; }
    var data: u8[>..] = [];
    input::paste(data, text, buffer::has_mode(tabs[active].term, buffer::MODE_BRACKETED_PASTE));
    send(data);
}

fn paste_clipboard() {
    if tabs.len == 0 { return; }
    paste_text(gfx::clipboard());
}

fn paste_primary() {
    if tabs.len == 0 { return; }
    var text: u8[>..] = [];
    text.resize(PRIMARY_CAP, 0);
    let n = pty::get_primary(text);
    if n <= 0 { return; }
    text.resize(min(n, PRIMARY_CAP), 0);
    paste_text(text);
}

// --- window ----------------------------------------------------------------

fn toggle_fullscreen() {
    is_fullscreen = !is_fullscreen;
    pty::set_fullscreen(is_fullscreen);
    if !is_fullscreen { pty::set_borderless(true); }
    dirty = true;
}

fn change_font(delta: f32) {
    let size = clamp(font_px + delta, 10.0, 48.0);
    if size == font_px { return; }
    stop_momentum();
    font_px = size;
    if renderer::set_font(rend, size) {
        for i in tabs.len { tabs[i].scroll_frac = 0.0; }
        dirty = true;
    }
}

// --- search ----------------------------------------------------------------

fn search_recompute() {
    if tabs.len == 0 || !search_state.active { return; }
    stop_momentum();
    search::find_first(search_state, tabs[active], cells);
    search::reveal(tabs[active], search_state);
    dirty = true;
}

fn search_step(forward: bool) {
    if tabs.len == 0 || !search_state.active { return; }
    stop_momentum();
    if forward {
        search::next(search_state, tabs[active], cells);
    } else {
        search::prev(search_state, tabs[active], cells);
    }
    search::reveal(tabs[active], search_state);
    dirty = true;
}

fn search_open() {
    if tabs.len == 0 { return; }
    stop_momentum();
    search::open(search_state);
    dirty = true;
}

fn search_close() {
    if !search_state.active { return; }
    search::close(search_state);
    dirty = true;
}

fn handle_search_event(e: gfx::Event) {
    if e.kind == gfx::EVENT_TEXT {
        if e.codepoint >= 32 && e.codepoint != 127 {
            search::add_text(search_state, e.codepoint);
            search_recompute();
        }
        return;
    }
    if e.kind != gfx::EVENT_KEY || !e.down { return; }
    let name = gfx::key_name(e.scancode);
    let ctrl = (e.mods & gfx::MOD_CTRL) != 0;
    let shift = (e.mods & gfx::MOD_SHIFT) != 0;
    let cmd = (e.mods & gfx::MOD_GUI) != 0;
    if ((ctrl && shift) || cmd) && name == "F" {
        search_close();
        return;
    }
    if name == "Escape" {
        search_close();
    } else if name == "Return" || name == "Enter" {
        if !e.repeat { search_step(!shift); }
    } else if name == "Backspace" {
        search::backspace(search_state);
        search_recompute();
    } else if name == "Up" {
        if !e.repeat { search_step(false); }
    } else if name == "Down" {
        if !e.repeat { search_step(true); }
    }
}

// --- input -----------------------------------------------------------------

fn handle_key(e: gfx::Event) -> bool {
    let name = gfx::key_name(e.scancode);
    let ctrl = (e.mods & gfx::MOD_CTRL) != 0;
    let shift = (e.mods & gfx::MOD_SHIFT) != 0;
    let cmd = (e.mods & gfx::MOD_GUI) != 0;
    let repeat = e.repeat;

    // macOS keeps the full-screen toggle on Ctrl+Cmd+F; check it before the
    // Cmd block, which would otherwise read the F as search.
    if ctrl && cmd && name == "F" {
        if !repeat { toggle_fullscreen(); }
        return true;
    }

    // One-shot shortcuts are consumed on key repeat too, so holding them
    // cannot spawn or close a string of tabs; scrolling and zooming repeat.
    if name == "F11" && !ctrl && !shift {
        if !repeat { toggle_fullscreen(); }
        return true;
    }
    // The X11 terminal convention: Ctrl+Insert copies, Shift+Insert pastes.
    if ctrl && !shift && name == "Insert" {
        if !repeat { copy_selection(); }
        return true;
    }
    if shift && !ctrl && name == "Insert" {
        if !repeat { paste_clipboard(); }
        return true;
    }

    if ctrl && shift {
        if name == "F" { if !repeat { search_open(); } return true; }
        if name == "T" { if !repeat { spawn_tab(); } return true; }
        if name == "W" { if !repeat { close_active(); } return true; }
        if name == "Tab" { prev_tab(); return true; }
        if name == "PageUp" { prev_tab(); return true; }
        if name == "PageDown" { next_tab(); return true; }
        if name == "Right" { next_tab(); return true; }
        if name == "Left" { prev_tab(); return true; }
        if name == "C" { if !repeat { copy_selection(); } return true; }
        if name == "V" { if !repeat { paste_clipboard(); } return true; }
        if name == "Up" { scroll_by(1); return true; }
        if name == "Down" { scroll_by(-1); return true; }
        if name == "Home" { scroll_top(); return true; }
        if name == "End" { scroll_bottom(); return true; }
        if name == "Enter" { if !repeat { toggle_fullscreen(); } return true; }
        if name == "Equals" || name == "Plus" || e.keycode == 43 || e.keycode == 61 {
            change_font(1.0);
            return true;
        }
        if name == "Minus" || e.keycode == 45 || e.keycode == 95 {
            change_font(-1.0);
            return true;
        }
        if name.len == 1 && name[0] >= '1' && name[0] <= '9' {
            if !repeat { jump_tab(name[0] - '1'); }
            return true;
        }
    }

    // macOS puts the application shortcuts on Command, as Terminal.app does.
    // Cmd+Q, Cmd+H and Cmd+M belong to SDL's own menu bar; every other Cmd
    // chord is consumed here, because a terminal never sends one to the shell
    // and an unhandled Cmd+arrow would otherwise escape as a plain arrow.
    if cmd {
        if name == "T" { if !repeat { spawn_tab(); } }
        else if name == "W" { if !repeat { close_active(); } }
        else if name == "C" { if !repeat { copy_selection(); } }
        else if name == "V" { if !repeat { paste_clipboard(); } }
        else if name == "F" { if !repeat { search_open(); } }
        else if name == "Enter" { if !repeat { toggle_fullscreen(); } }
        else if name == "PageUp" { prev_tab(); }
        else if name == "PageDown" { next_tab(); }
        else if name == "[" { prev_tab(); }
        else if name == "]" { next_tab(); }
        else if name == "Equals" || name == "Plus" || e.keycode == 43 || e.keycode == 61 {
            change_font(1.0);
        }
        else if name == "Minus" || e.keycode == 45 || e.keycode == 95 {
            change_font(-1.0);
        }
        else if name.len == 1 && name[0] >= '1' && name[0] <= '9' {
            if !repeat { jump_tab(name[0] - '1'); }
        }
        return true;
    }

    // PageUp/PageDown page the scrollback, with or without Shift. Full-screen
    // programs own the alternate screen and page with CSI 5~ / CSI 6~
    // themselves, so there the keys fall through to the encoder instead.
    if !ctrl && name == "PageUp" {
        if alt_screen_active() { return false; }
        scroll_page(1);
        return true;
    }
    if !ctrl && name == "PageDown" {
        if alt_screen_active() { return false; }
        scroll_page(-1);
        return true;
    }
    return false;
}

fn alt_screen_active() -> bool {
    return tabs.len > 0 && tabs[active].term.alt_active;
}

fn modifiers_down() -> bool {
    return gfx::key_down("Left Ctrl") || gfx::key_down("Right Ctrl") ||
           gfx::key_down("Left Alt") || gfx::key_down("Right Alt");
}

fn held_mods() -> i32 {
    var m: i32 = 0;
    if gfx::key_down("Left Shift") || gfx::key_down("Right Shift") { m = m | gfx::MOD_SHIFT; }
    if gfx::key_down("Left Ctrl") || gfx::key_down("Right Ctrl") { m = m | gfx::MOD_CTRL; }
    if gfx::key_down("Left Alt") || gfx::key_down("Right Alt") { m = m | gfx::MOD_ALT; }
    return m;
}

fn handle_events() {
    let events = gfx::events();
    for e in events {
        if search_state.active && (e.kind == gfx::EVENT_KEY || e.kind == gfx::EVENT_TEXT) {
            handle_search_event(e);
            continue;
        }
        if e.kind == gfx::EVENT_KEY && e.down {
            if handle_key(e) { continue; }
            var out: u8[>..] = [];
            if input::encode_key(out, e.scancode, e.keycode, e.mods) && out.len > 0 {
                send(out);
            }
        } else if e.kind == gfx::EVENT_TEXT {
            if modifiers_down() { continue; }
            var out: u8[>..] = [];
            input::push_text(out, e.codepoint);
            send(out);
        } else if e.kind == gfx::EVENT_MOUSE_BUTTON {
            if e.down && e.button == gfx::MOUSE_LEFT { click_count = e.clicks; }
        }
    }
}

// --- mouse -----------------------------------------------------------------

fn sidebar_click(mp: float2, sz: int2) -> bool {
    if !show_sidebar() { return false; }
    stop_momentum();
    let sw = renderer::sidebar_width(rend, sz.x);
    if mp.x >= sw { return false; }
    let idx = renderer::tab_index_at(rend, mp.y);
    if idx >= 0 && idx < tabs.len {
        if gfx::mouse_pressed(gfx::MOUSE_LEFT) {
            close_search_on_tab_change();
            active = idx;
            update_title();
            dirty = true;
        } else if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) {
            close_tab_at(idx);
        }
    }
    // A click on the sidebar's empty area is still the sidebar's.
    return true;
}

fn report_mouse(button: i64, release: bool, motion: bool, mods: i32, col: i64, row: i64) {
    if tabs.len == 0 { return; }
    var out: u8[>..] = [];
    input::encode_mouse(out, button, col, row, release, motion, mods,
                        buffer::has_mode(tabs[active].term, buffer::MODE_MOUSE_SGR),
                        buffer::has_mode(tabs[active].term, buffer::MODE_MOUSE_UTF8));
    write_pty(out);
}

// Returns true when the terminal app owns the mouse, so the emulator must not
// select or scroll. Shift is the conventional override for local selection.
fn handle_terminal_mouse(inside: bool, col: i64, row: i64, mods: i32) -> bool {
    if tabs.len == 0 { return false; }
    if !buffer::wants_mouse(tabs[active].term) { return false; }
    if (mods & gfx::MOD_SHIFT) != 0 { return false; }
    if !inside { return true; }

    let x10 = buffer::has_mode(tabs[active].term, buffer::MODE_MOUSE_X10);
    let mode = tabs[active].term.modes;
    let wheel = gfx::mouse_wheel();
    if wheel != 0.0 {
        stop_momentum();
        if (mods & gfx::MOD_CTRL) != 0 {
            change_font(if wheel > 0.0 { 1.0 } else { -1.0 });
        } else {
            report_mouse(if wheel > 0.0 { 64 } else { 65 }, false, false, mods, col, row);
        }
        return true;
    }

    if gfx::mouse_pressed(gfx::MOUSE_LEFT) {
        report_mouse(0, false, false, mods, col, row);
    }
    if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) {
        report_mouse(1, false, false, mods, col, row);
    }
    if gfx::mouse_pressed(gfx::MOUSE_RIGHT) {
        report_mouse(2, false, false, mods, col, row);
    }
    if !x10 {
        if gfx::mouse_released(gfx::MOUSE_LEFT) {
            report_mouse(0, true, false, mods, col, row);
        }
        if gfx::mouse_released(gfx::MOUSE_MIDDLE) {
            report_mouse(1, true, false, mods, col, row);
        }
        if gfx::mouse_released(gfx::MOUSE_RIGHT) {
            report_mouse(2, true, false, mods, col, row);
        }
    }

    let moved = col != mouse_last_col || row != mouse_last_row;
    if moved && !x10 && (mode & (buffer::MODE_MOUSE_DRAG | buffer::MODE_MOUSE_MOVE)) != 0 {
        var held: i64 = -1;
        if gfx::mouse_down(gfx::MOUSE_LEFT) { held = 0; }
        else if gfx::mouse_down(gfx::MOUSE_MIDDLE) { held = 1; }
        else if gfx::mouse_down(gfx::MOUSE_RIGHT) { held = 2; }
        if held >= 0 {
            report_mouse(held, false, true, mods, col, row);
        } else if (mode & buffer::MODE_MOUSE_MOVE) != 0 {
            report_mouse(3, false, true, mods, col, row);
        }
    }
    return true;
}

fn link_starts_with(s: const u8[:], prefix: const u8[:]) -> bool {
    if s.len < prefix.len { return false; }
    var i = 0;
    while i < prefix.len {
        if s[i] != prefix[i] { return false; }
        i++;
    }
    return true;
}

fn open_link(id: u16) {
    if id == 0 || tabs.len == 0 { return; }
    var uri: u8[>..] = [];
    buffer::link_uri(tabs[active].term, id, uri);
    if link_starts_with(uri, "http://") || link_starts_with(uri, "https://") ||
       link_starts_with(uri, "mailto:") {
        pty::open_url(uri);
    }
}

fn select_at(inside: bool, col: i64, row: i64, abs: i64) {
    if gfx::mouse_pressed(gfx::MOUSE_LEFT) && inside {
        stop_momentum();
        if click_count >= 3 {
            tab::selection_line(tabs[active], abs);
        } else if click_count == 2 {
            tab::selection_word(tabs[active], cells, abs, col);
        } else {
            tab::selection_start(tabs[active], abs, col);
        }
        selecting = true;
        dirty = true;
    }
    if selecting && gfx::mouse_down(gfx::MOUSE_LEFT) {
        if tabs[active].sel_line != abs || tabs[active].sel_col != col {
            tab::selection_extend(tabs[active], abs, col);
            dirty = true;
        }
    }
    if gfx::mouse_released(gfx::MOUSE_LEFT) { selecting = false; }
    if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) && inside {
        stop_momentum();
        paste_primary();
    }
}

// The sidebar's empty area is the closest thing the borderless window has to
// a title bar, so it moves the window with no modifier. Cmd+drag moves it
// from anywhere, which is the only handle left once the sidebar auto-hides
// with a single tab.
fn sidebar_grip(mp: float2, sz: int2) -> bool {
    if !show_sidebar() { return false; }
    if mp.x >= renderer::sidebar_width(rend, sz.x) { return false; }
    let idx = renderer::tab_index_at(rend, mp.y);
    return idx < 0 || idx >= tabs.len;
}

fn handle_window_drag(mp: float2, sz: int2, mods: i32) -> bool {
    if dragging {
        if gfx::mouse_down(gfx::MOUSE_LEFT) {
            pty::drag_update();
        } else {
            pty::drag_end();
            dragging = false;
        }
        return true;
    }
    let cmd = (mods & gfx::MOD_GUI) != 0;
    if gfx::mouse_pressed(gfx::MOUSE_LEFT) && (cmd || sidebar_grip(mp, sz)) {
        dragging = pty::drag_begin();
        return dragging;
    }
    return false;
}

fn apply_mouse() {
    if tabs.len == 0 { return; }
    let cs = renderer::cell_size(rend);
    let origin = content_origin();
    let sz = gfx::screen_size();
    let mp = gfx::mouse_pos();
    let mods = held_mods();

    if handle_window_drag(mp, sz, mods) { return; }
    if sidebar_click(mp, sz) { return; }

    let inside = mp.x >= origin.x && mp.y >= origin.y &&
                 mp.x < sz.x - renderer::PAD && mp.y < sz.y - renderer::PAD;
    var col = ((mp.x - origin.x) / cs.x) as i64;
    col = clamp(col, 0, tabs[active].term.cols - 1);
    var row = ((mp.y - origin.y) / cs.y) as i64;
    row = clamp(row, 0, tabs[active].term.rows - 1);
    let frac = if tabs[active].term.alt_active { 0.0 } else { tabs[active].scroll_frac };
    let first = if tabs[active].term.alt_active {
        tabs[active].term.hist_count
    } else {
        tabs[active].term.hist_count - tabs[active].scroll -
            (if frac > 0.001 { 1 } else { 0 })
    };
    var abs = first + (((mp.y - origin.y + frac) / cs.y) as i64);
    if abs < 0 { abs = 0; }

    // Ctrl+click on an OSC 8 link is the terminal-level open gesture; it
    // works even while an app is tracking the mouse.
    if inside && (mods & gfx::MOD_CTRL) != 0 && click_count == 1 &&
       gfx::mouse_pressed(gfx::MOUSE_LEFT) {
        let c = buffer::cell_at_abs(tabs[active].term, cells, abs, col);
        if c.link != 0 {
            open_link(c.link);
            mouse_last_col = col;
            mouse_last_row = row;
            return;
        }
    }

    if handle_terminal_mouse(inside, col, row, mods) {
        mouse_last_col = col;
        mouse_last_row = row;
        return;
    }

    select_at(inside, col, row, abs);

    let wheel = gfx::mouse_wheel();
    if wheel != 0.0 && gfx::mouse_in_window() {
        if (mods & gfx::MOD_CTRL) != 0 {
            change_font(if wheel > 0.0 { 1.0 } else { -1.0 });
        } else {
            scroll_wheel(wheel);
        }
    }
    mouse_last_col = col;
    mouse_last_row = row;
}

fn focus_report(focused: bool) {
    if tabs.len == 0 { return; }
    if !buffer::has_mode(tabs[active].term, buffer::MODE_FOCUS_EVENTS) { return; }
    var out: u8[>..] = [];
    input::focus(out, focused);
    write_pty(out);
}

// --- main ------------------------------------------------------------------

fn main() {
    guard gfx::open("goose-term", 1200, 760, gfx::WINDOW_RESIZABLE | gfx::NO_VSYNC) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();

    pty::set_borderless(true);
    gfx::text_input(true);

    guard renderer::init(rend, font_px) else {
        write_stderr(str("goose-term: could not bake assets/JuliaMono-Regular.ttf\n"));
        return;
    }
    defer renderer::destroy(rend);

    spawn_tab();
    last_tick = gfx::time();

    var last_w: i64 = -1;
    var last_h: i64 = -1;
    var last_focus = gfx::focused();
    last_blink = gfx::time();
    while running && gfx::frame() {
        handle_events();
        if !running || tabs.len == 0 { break; }
        pump_all();
        if !running || tabs.len == 0 { break; }
        apply_mouse();
        update_layout();

        let now = gfx::time();
        var dt = now - last_tick;
        last_tick = now;
        if dt < 0.0 { dt = 0.0; }
        if dt > MOMENTUM_DT_MAX { dt = MOMENTUM_DT_MAX; }
        update_momentum(now, dt);

        let sz = gfx::screen_size();
        if sz.x != last_w || sz.y != last_h {
            dirty = true;
            last_w = sz.x;
            last_h = sz.y;
        }
        let focused = gfx::focused();
        if focused != last_focus {
            if !focused { stop_momentum(); }
            focus_report(focused);
            dirty = true;
            last_focus = focused;
            if focused { cursor_on = true; last_blink = now; }
        }
        if focused && now - last_blink >= 0.53 {
            last_blink = now;
            cursor_on = !cursor_on;
            dirty = true;
        }

        // A terminal only changes when bytes, input, or the window do. Draw
        // then; on idle frames just keep the screen and let the loop sleep.
        if dirty {
            var view = renderer::View {
                active: active,
                show_sidebar: show_sidebar(),
                cursor_on: cursor_on,
                search_active: search_state.active,
                search_found: search_state.found,
                hit_line: search_state.line,
                hit_start: search_state.start,
                hit_end: search_state.end,
            };
            var q = 0;
            while q < search_state.query.len && q < 128 {
                view.search_query[q] = search_state.query[q];
                q++;
            }
            view.search_query_len = q;
            renderer::draw(rend, cells, tabs, view);
            gfx::begin_screen(float4 { 0.08, 0.08, 0.11, 1.0 });
            gfx::end_pass();
            ui::render(rend.ctx);
            dirty = false;
            if momentum_coasting() { pty::sleep_ms(MOMENTUM_FRAME_MS); }
        } else {
            pty::sleep_ms(4);
        }
    }

    for i in tabs.len { tab::close(tabs[i]); }
}
