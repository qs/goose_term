// goose-term: a minimal GPU terminal emulator.
//
// The window event loop lives here. Every frame it takes gfx's input, sends
// translated keystrokes to the active PTY, drains every tab's PTY (with a
// byte budget so a flood cannot stall the UI), and resizes the grids to the
// window. It draws the grid and the vertical tab sidebar only when something
// changed; idle frames wait on the PTYs, so a quiet terminal costs no CPU.
//
// The pieces with state of their own live in modules: scrolling and momentum
// in scroll, mouse gestures in mouse, the shortcut table in keys, the search
// bar in search_ui, and the terminal grid in buffer.

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
import .keys;
import .mouse;
import .renderer;
import .scroll;
import .search;
import .search_ui;

const MAX_TABS: i64 = 16;
const AUTO_HIDE_SIDEBAR: bool = true;
const READ_BUDGET: i64 = 65536;
const DEFAULT_FONT_PX: f32 = 20.0;
const PRIMARY_CAP: i64 = 65536;
const MOMENTUM_DT_MAX: f64 = 0.05;

// Cap the smooth-scroll redraw rate at ~125 Hz instead of spinning as fast as
// the window system accepts presents.
const MOMENTUM_FRAME_MS: i64 = 8;

// An idle frame sleeps on the PTYs. Ten milliseconds bounds both the input
// latency while nothing is happening and the wake-ups per second; output wakes
// the loop immediately, so typing and builds are unaffected.
const IDLE_WAIT_MS: i64 = 10;

// A window resize waits this long to settle before the grids are reallocated:
// every column change rebuilds each tab's scrollback.
const RESIZE_SETTLE: f64 = 0.03;

// All tabs' scrollbacks together stay under this many cells; at 20 bytes a
// cell that is about 130 MB, whatever the tab count and window width.
const HISTORY_CELL_BUDGET: i64 = 6000000;
const MIN_HIST_KEEP: i64 = 128;

var cells = slice_pool<buffer::Cell> {};
var tabs: tab::Tab[>..] = [];
var active: i64 = 0;
var rend = renderer::Renderer { .. };
var font_px: f32 = DEFAULT_FONT_PX;
var running = true;
var is_fullscreen = false;
var dirty = true;
var cursor_on = true;
var last_blink = 0.0;
var last_tick: f64 = 0.0;
var search_state = search::State { .. };
var mouse_state = mouse::State { .. };
var idle_fds: i32[MAX_TABS] = [0; MAX_TABS];
var target_cols: i64 = 0;
var target_rows: i64 = 0;
var resize_since: f64 = 0.0;
var last_budget_check: f64 = 0.0;

// --- layout ----------------------------------------------------------------

fn show_sidebar() -> bool {
    return !AUTO_HIDE_SIDEBAR || tabs.len > 1;
}

fn cell_height() -> f32 {
    return renderer::cell_size(rend).y;
}

fn grid_dims() -> i64, i64 {
    let sz = gfx::screen_size();
    let cs = renderer::cell_size(rend);
    let ox = renderer::grid_origin(rend, show_sidebar()).x;
    let cols = max(2, ((sz.x - ox - renderer::PAD) / cs.x) as i64);
    let rows = max(1, ((sz.y - renderer::PAD * 2.0) / cs.y) as i64);
    return cols, rows;
}

fn update_layout(now: f64) {
    if tabs.len == 0 { return; }
    let cols, rows = grid_dims();

    var needs = false;
    for i in tabs.len {
        if tabs[i].term.cols != cols || tabs[i].term.rows != rows { needs = true; }
    }
    if needs {
        if cols != target_cols || rows != target_rows {
            // The window is still moving; remember where it is heading and
            // wait for it to settle.
            target_cols = cols;
            target_rows = rows;
            resize_since = now;
            return;
        }
        if now - resize_since < RESIZE_SETTLE { return; }
        scroll::stop();
        for i in tabs.len {
            if tabs[i].term.cols != cols || tabs[i].term.rows != rows {
                tab::resize(tabs[i], cells, cols, rows);
                dirty = true;
            }
        }
    }

    let ch = cell_height();
    for i in tabs.len { scroll::clamp_tab(tabs[i], ch); }
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

fn report_spawn_error(shell: const u8[:]) {
    var why: u8[>..] = [];
    if !pty::spawn_error(why) { why.append("unknown error"); }
    write_stderr(str("goose-term: could not start ", shell, ": ", why, "\n"));
}

fn spawn_tab() -> bool {
    if tabs.len >= MAX_TABS {
        write_stderr(str("goose-term: at most ", MAX_TABS, " tabs\n"));
        return false;
    }
    scroll::stop();
    close_search_on_tab_change();
    let cols, rows = grid_dims();
    let shell = shell_path();
    tabs.push(tab::create(shell, cells, cols, rows));
    if !tabs[tabs.len - 1].proc.alive {
        // A tab that could not start would otherwise appear and vanish.
        remove_at(tabs, tabs.len - 1);
        report_spawn_error(shell);
        return false;
    }
    active = tabs.len - 1;
    update_title();
    dirty = true;
    return true;
}

fn switch_to(i: i64) {
    scroll::stop();
    close_search_on_tab_change();
    active = i;
    update_title();
    dirty = true;
}

fn close_tab_at(i: i64) {
    if i < 0 || i >= tabs.len { return; }
    if i == active {
        scroll::stop();
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
    switch_to((active + 1) % tabs.len);
}

fn prev_tab() {
    if tabs.len == 0 { return; }
    switch_to((active - 1 + tabs.len) % tabs.len);
}

fn jump_tab(i: i64) {
    if i >= 0 && i < tabs.len { switch_to(i); }
}

// --- pty -------------------------------------------------------------------

fn write_pty(data: const u8[:]) {
    if tabs.len == 0 || data.len == 0 { return; }
    let sent = tab::write_bytes(tabs[active], data);
    if sent < data.len {
        // The PTY buffer stayed full: the program is not reading its input.
        // Say what was lost instead of dropping it silently.
        write_stderr(str("goose-term: ", data.len - sent, " bytes of input dropped\n"));
    }
}

fn send(data: const u8[:]) {
    if tabs.len == 0 || data.len == 0 { return; }
    scroll::stop();
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

fn pump_all() {
    var buf: u8[8192] = [0; 8192];
    let ch = cell_height();
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
                // execv failing (a $SHELL that is not there) exits 127 and
                // leaves nothing else behind to explain it.
                if pty::exit_code(tabs[i].proc) == 127 {
                    write_stderr(str("goose-term: could not run ", tabs[i].title, "\n"));
                }
                break;
            }
            parser::feed(tabs[i].parser, tabs[i].term, cells, buf[..n]);
            dirty = true;
            budget -= n;
            if n < want { break; }
        }
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
        scroll::clamp_tab(tabs[i], ch);
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

// The scrollbacks are the bulk of the memory a session holds. When they grow
// past the budget, the tab with the most history gives half of it back.
fn history_cells() -> i64 {
    var n = 0;
    for i in tabs.len { n += tabs[i].term.hist_len + tabs[i].term.grid_len; }
    return n;
}

fn enforce_history_budget() {
    var total = history_cells();
    while total > HISTORY_CELL_BUDGET && tabs.len > 0 {
        var worst = 0;
        var worst_len = 0;
        for i in tabs.len {
            if tabs[i].term.hist_len > worst_len {
                worst_len = tabs[i].term.hist_len;
                worst = i;
            }
        }
        let keep = tabs[worst].term.hist_count / 2;
        if keep < MIN_HIST_KEEP { break; }
        buffer::trim_history(tabs[worst].term, cells, keep);
        // The surviving lines were renumbered, so the old selection and
        // viewport positions no longer name them.
        tabs[worst].sel_active = false;
        tabs[worst].scroll = clamp(tabs[worst].scroll, 0, tabs[worst].term.hist_count);
        tabs[worst].scroll_frac = 0.0;
        if search_state.active { search_state.found = false; }
        dirty = true;
        total = history_cells();
    }
}

// --- clipboard -------------------------------------------------------------

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
    scroll::stop();
    font_px = size;
    if renderer::set_font(rend, size) {
        for i in tabs.len { tabs[i].scroll_frac = 0.0; }
        dirty = true;
    }
}

// --- search ----------------------------------------------------------------

fn search_open() {
    if tabs.len == 0 { return; }
    scroll::stop();
    search::open(search_state);
    if search_state.query.len > 0 {
        search_ui::step(search_state, tabs[active], cells, true);
    }
    dirty = true;
}

fn scroll_by(lines: i64) {
    if tabs.len == 0 { return; }
    if scroll::by(tabs[active], lines, cell_height()) { dirty = true; }
}

fn scroll_top() {
    if tabs.len == 0 { return; }
    if scroll::top(tabs[active]) { dirty = true; }
}

fn scroll_bottom() {
    if tabs.len == 0 { return; }
    if scroll::bottom(tabs[active]) { dirty = true; }
}

fn alt_screen_active() -> bool {
    return tabs.len > 0 && tabs[active].term.alt_active;
}

// --- input -----------------------------------------------------------------

fn run_action(action: keys::Action, arg: i64, repeat: bool) {
    if tabs.len == 0 && action != keys::Action.NewTab { return; }
    match action {
        NewTab => { if !repeat { spawn_tab(); } },
        CloseTab => { if !repeat { close_active(); } },
        PrevTab => { prev_tab(); },
        NextTab => { next_tab(); },
        Jump => { if !repeat { jump_tab(arg); } },
        Copy => { if !repeat { copy_selection(); } },
        Paste => { if !repeat { paste_clipboard(); } },
        Search => { if !repeat { search_open(); } },
        Fullscreen => { if !repeat { toggle_fullscreen(); } },
        ZoomIn => { change_font(1.0); },
        ZoomOut => { change_font(-1.0); },
        ScrollUp => { scroll_by(1); },
        ScrollDown => { scroll_by(-1); },
        ScrollTop => { scroll_top(); },
        ScrollBottom => { scroll_bottom(); },
        None => {},
    }
}

fn handle_key(e: gfx::Event) -> bool {
    let ctrl = (e.mods & gfx::MOD_CTRL) != 0;
    let shift = (e.mods & gfx::MOD_SHIFT) != 0;
    let gui = (e.mods & gfx::MOD_GUI) != 0;

    // macOS keeps the full-screen toggle on Ctrl+Cmd+F; check it before the
    // Cmd table, which would otherwise read the F as search.
    if ctrl && gui && e.scancode == keys::K_F {
        if !e.repeat { toggle_fullscreen(); }
        return true;
    }
    if e.scancode == keys::K_F11 && !ctrl && !shift && !gui {
        if !e.repeat { toggle_fullscreen(); }
        return true;
    }
    // The X11 terminal convention: Ctrl+Insert copies, Shift+Insert pastes.
    if e.scancode == keys::K_INSERT && ctrl && !shift && !gui {
        if !e.repeat { copy_selection(); }
        return true;
    }
    if e.scancode == keys::K_INSERT && shift && !ctrl && !gui {
        if !e.repeat { paste_clipboard(); }
        return true;
    }

    // The application's chords: Ctrl+Shift everywhere, Cmd on macOS, where the
    // same table answers for both. An unbound Cmd chord is still consumed,
    // because a terminal never sends one to the shell and an unhandled
    // Cmd+arrow would otherwise escape as a plain arrow.
    if (ctrl && shift) || gui {
        let action, arg = keys::action(e);
        if action == keys::Action.None { return gui; }
        run_action(action, arg, e.repeat);
        return true;
    }

    // PageUp/PageDown page the scrollback, with or without Shift. Full-screen
    // programs own the alternate screen and page with CSI 5~ / CSI 6~
    // themselves, so there the keys fall through to the encoder instead.
    if !ctrl && e.scancode == keys::K_PAGEUP {
        if tabs.len == 0 || alt_screen_active() { return tabs.len == 0; }
        scroll_by(max(tabs[active].term.rows - 1, 1));
        return true;
    }
    if !ctrl && e.scancode == keys::K_PAGEDOWN {
        if tabs.len == 0 || alt_screen_active() { return tabs.len == 0; }
        scroll_by(-max(tabs[active].term.rows - 1, 1));
        return true;
    }
    return false;
}

// Held Ctrl/Alt alone means a chord, not text; AltGr is the exception, since
// it composes a character (€, ł, í) that must reach the terminal.
fn handle_events() {
    let events = gfx::events();
    for e in events {
        if search_state.active &&
           (e.kind == gfx::EVENT_KEY || e.kind == gfx::EVENT_TEXT) {
            if tabs.len > 0 {
                if search_ui::handle(e, search_state, tabs[active], cells) {
                    dirty = true;
                    continue;
                }
            } else if e.kind == gfx::EVENT_KEY && e.down && e.scancode == keys::K_ESCAPE {
                search::close(search_state);
                dirty = true;
                continue;
            }
        }
        if e.kind == gfx::EVENT_KEY && e.down {
            if handle_key(e) { continue; }
            var out: u8[>..] = [];
            if input::encode_key(out, e.scancode, e.keycode, e.mods) && out.len > 0 {
                send(out);
            }
        } else if e.kind == gfx::EVENT_TEXT {
            if keys::text_is_chord(e) { continue; }
            var out: u8[>..] = [];
            input::push_text(out, e.codepoint);
            send(out);
        } else if e.kind == gfx::EVENT_MOUSE_BUTTON {
            mouse::note_button(mouse_state, e);
        }
    }
}

fn focus_report(focused: bool) {
    if tabs.len == 0 { return; }
    if !buffer::has_mode(tabs[active].term, buffer::MODE_FOCUS_EVENTS) { return; }
    var out: u8[>..] = [];
    input::focus(out, focused);
    write_pty(out);
}

// Sleep until a PTY has output or the timeout passes. Returns at once when a
// tab is already readable, so a program that is streaming never waits.
fn idle_wait(ms: i64) {
    var n = 0;
    for i in tabs.len {
        if n >= MAX_TABS { break; }
        if !tabs[i].proc.alive || tabs[i].proc.fd < 0 { continue; }
        idle_fds[n] = tabs[i].proc.fd;
        n++;
    }
    pty::wait(idle_fds[..n], ms);
}

// Keep the IME's candidate window next to the text cursor.
fn update_ime_area() {
    if tabs.len == 0 { return; }
    let o = renderer::grid_origin(rend, show_sidebar());
    let cs = renderer::cell_size(rend);
    pty::set_ime_area(o.x + tabs[active].term.cur_x * cs.x,
                      o.y + tabs[active].term.cur_y * cs.y, cs.x * 2.0, cs.y);
}

// --- main ------------------------------------------------------------------

fn main() {
    guard gfx::open("goose-term", 1200, 760, gfx::WINDOW_RESIZABLE | gfx::NO_VSYNC) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();

    pty::set_borderless(true);
    pty::set_window_icon();
    gfx::text_input(true);

    guard renderer::init(rend, font_px) else {
        write_stderr(str("goose-term: could not bake assets/JuliaMono-Regular.ttf\n"));
        return;
    }
    defer renderer::destroy(rend);

    if !spawn_tab() {
        write_stderr(str("goose-term: no shell to start\n"));
        return;
    }
    last_tick = gfx::time();
    last_blink = gfx::time();

    var last_w: i64 = -1;
    var last_h: i64 = -1;
    var last_focus = gfx::focused();
    while running && gfx::frame() {
        let now = gfx::time();

        handle_events();
        if !running || tabs.len == 0 { break; }
        pump_all();
        if !running || tabs.len == 0 { break; }

        let before_active = active;
        let intent, arg, mouse_moved =
            mouse::update(mouse_state, tabs, active, cells, rend, show_sidebar());
        if mouse_moved { dirty = true; }
        if active != before_active { update_title(); dirty = true; }
        match intent {
            NewTab => { spawn_tab(); },
            ZoomIn => { change_font(1.0); },
            ZoomOut => { change_font(-1.0); },
            CloseTab => { close_tab_at(arg); },
            PastePrimary => { paste_primary(); },
            None => {},
        }
        if !running || tabs.len == 0 { break; }

        update_layout(now);

        var dt = now - last_tick;
        last_tick = now;
        if dt < 0.0 { dt = 0.0; }
        if dt > MOMENTUM_DT_MAX { dt = MOMENTUM_DT_MAX; }
        if scroll::update(tabs[active], now, dt, cell_height()) { dirty = true; }

        if now - last_budget_check >= 1.0 {
            last_budget_check = now;
            enforce_history_budget();
        }

        let sz = gfx::screen_size();
        if sz.x != last_w || sz.y != last_h {
            dirty = true;
            last_w = sz.x;
            last_h = sz.y;
        }
        let focused = gfx::focused();
        if focused != last_focus {
            if !focused { scroll::stop(); }
            focus_report(focused);
            dirty = true;
            last_focus = focused;
            if focused {
                cursor_on = true;
                last_blink = now;
            }
        }
        if focused { update_ime_area(); }

        if focused && now - last_blink >= 0.53 {
            last_blink = now;
            cursor_on = !cursor_on;
            dirty = true;
        }

        // A terminal only changes when bytes, input, or the window do. Draw
        // then; on idle frames sleep on the PTYs instead of polling.
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
                search_cursor: search_state.cursor,
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
            if scroll::coasting(now) { pty::sleep_ms(MOMENTUM_FRAME_MS); }
        } else {
            idle_wait(IDLE_WAIT_MS);
        }
    }

    for i in tabs.len { tab::close(tabs[i]); }
}
