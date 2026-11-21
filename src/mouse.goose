// Mouse handling for the active tab: click-to-focus in the sidebar, the
// borderless window drag, text selection with its edge auto-scroll, link
// clicks, wheel scrolling, and reporting to programs that asked for the mouse.
//
// Everything that belongs to the terminal itself (pasting, zooming, closing a
// tab) comes back to main as an Intent, so this module never has to call into
// the window loop.

namespace mouse;

import std;
import gfx;
import slice_pool;
import .buffer;
import .input;
import .keys;
import .pty;
import .renderer;
import .scroll;
import .tab;

// A press has to travel this far before it becomes a window drag, so that a
// Cmd+click on a link is still a click.
const DRAG_THRESHOLD: f32 = 3.0;

struct State {
    click_count: i64 = 1,
    selecting: bool = false,
    last_col: i64 = -1,
    last_row: i64 = -1,
    dragging: bool = false,
    drag_pending: bool = false,
    press_x: f32 = 0.0,
    press_y: f32 = 0.0,
}

enum Intent {
    None,
    ZoomIn,
    ZoomOut,
    CloseTab,
    PastePrimary,
}

// Wheel notches that the alternate screen turns into arrow keys, kept as a
// fraction so a touchpad's sub-notch deltas still add up.
var alt_wheel: f32 = 0.0;

fn note_button(st: State&, e: gfx::Event) {
    if e.down && e.button == gfx::MOUSE_LEFT { st.click_count = e.clicks; }
}

fn open_link(t: tab::Tab&, id: u16) {
    if id == 0 { return; }
    var uri: u8[>..] = [];
    buffer::link_uri(t.term, id, uri);
    if starts_with(uri, "http://") || starts_with(uri, "https://") ||
       starts_with(uri, "mailto:") {
        pty::open_url(uri);
    }
}

fn starts_with(s: const u8[:], prefix: const u8[:]) -> bool {
    if s.len < prefix.len { return false; }
    var i = 0;
    while i < prefix.len {
        if s[i] != prefix[i] { return false; }
        i++;
    }
    return true;
}

// The sidebar's empty area is the closest thing the borderless window has to
// a title bar, so it moves the window with no modifier. Cmd/Super+drag moves
// it from anywhere, which is the only handle left once the sidebar auto-hides
// with a single tab.
fn sidebar_grip(mp: float2, sz: int2, show_sidebar: bool, r: renderer::Renderer&,
                tab_count: i64) -> bool {
    if !show_sidebar { return false; }
    if mp.x >= renderer::sidebar_width(r, sz.x) { return false; }
    let idx = renderer::tab_index_at(r, mp.y);
    return idx < 0 || idx >= tab_count;
}

// True when the sidebar owns this position and handled it.
fn sidebar_click(mp: float2, sz: int2, show_sidebar: bool, r: renderer::Renderer&,
                 tabs: tab::Tab[:], active: i64&, intent: Intent&, arg: i64&) -> bool {
    if !show_sidebar { return false; }
    let sw = renderer::sidebar_width(r, sz.x);
    if mp.x >= sw { return false; }
    let idx = renderer::tab_index_at(r, mp.y);
    if idx >= 0 && idx < tabs.len {
        if gfx::mouse_pressed(gfx::MOUSE_LEFT) {
            // Only a click stops the coast; resting the pointer here does not.
            scroll::stop();
            // Each tab keeps its own viewport; switching does not reset it.
            if active != idx { active = idx; }
        } else if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) {
            scroll::stop();
            intent = Intent.CloseTab;
            arg = idx;
        }
    }
    return true;
}

// Reporting to programs that asked for the mouse. Returns true when the
// program owns the mouse, so the emulator must not select or scroll.
fn terminal_mouse(t: tab::Tab&, inside: bool, col: i64, row: i64, mods: i32,
                  last_col: i64, last_row: i64) -> bool {
    if !buffer::wants_mouse(t.term) { return false; }
    if (mods & gfx::MOD_SHIFT) != 0 { return false; }
    if !inside { return true; }

    let x10 = buffer::has_mode(t.term, buffer::MODE_MOUSE_X10);
    let mode = t.term.modes;
    let wheel = gfx::mouse_wheel();
    if wheel != 0.0 {
        scroll::stop();
        // Ctrl+wheel is the zoom gesture, not a scroll for the program.
        if (mods & gfx::MOD_CTRL) != 0 { return false; }
        report(t, if wheel > 0.0 { 64 } else { 65 }, false, false, mods, col, row);
        return true;
    }

    if gfx::mouse_pressed(gfx::MOUSE_LEFT) { report(t, 0, false, false, mods, col, row); }
    if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) { report(t, 1, false, false, mods, col, row); }
    if gfx::mouse_pressed(gfx::MOUSE_RIGHT) { report(t, 2, false, false, mods, col, row); }
    if !x10 {
        if gfx::mouse_released(gfx::MOUSE_LEFT) { report(t, 0, true, false, mods, col, row); }
        if gfx::mouse_released(gfx::MOUSE_MIDDLE) { report(t, 1, true, false, mods, col, row); }
        if gfx::mouse_released(gfx::MOUSE_RIGHT) { report(t, 2, true, false, mods, col, row); }
    }

    let moved = col != last_col || row != last_row;
    if moved && !x10 && (mode & (buffer::MODE_MOUSE_DRAG | buffer::MODE_MOUSE_MOVE)) != 0 {
        var held: i64 = -1;
        if gfx::mouse_down(gfx::MOUSE_LEFT) { held = 0; }
        else if gfx::mouse_down(gfx::MOUSE_MIDDLE) { held = 1; }
        else if gfx::mouse_down(gfx::MOUSE_RIGHT) { held = 2; }
        if held >= 0 {
            report(t, held, false, true, mods, col, row);
        } else if (mode & buffer::MODE_MOUSE_MOVE) != 0 {
            report(t, 3, false, true, mods, col, row);
        }
    }
    return true;
}

fn report(t: tab::Tab&, button: i64, release: bool, motion: bool, mods: i32,
          col: i64, row: i64) {
    var out: u8[>..] = [];
    input::encode_mouse(out, button, col, row, release, motion, mods,
                        buffer::has_mode(t.term, buffer::MODE_MOUSE_SGR),
                        buffer::has_mode(t.term, buffer::MODE_MOUSE_UTF8));
    tab::write_bytes(t, out);
}

// In the alternate screen a program that does not track the mouse (less, man,
// vim with the mouse off) still expects arrow keys for the wheel.
fn wheel_arrows(t: tab::Tab&, d: f32) {
    alt_wheel += d * scroll::WHEEL_LINES;
    var lines = 0;
    while alt_wheel >= 1.0 { lines += 1; alt_wheel -= 1.0; }
    while alt_wheel <= -1.0 { lines -= 1; alt_wheel += 1.0; }
    if lines == 0 { return; }
    var out: u8[>..] = [];
    var n = if lines > 0 { lines } else { -lines };
    for i in n {
        if lines > 0 { input::arrow(out, 'A', 0); } else { input::arrow(out, 'B', 0); }
    }
    tab::write_bytes(t, out);
}

fn update(st: State&, tabs: tab::Tab[:], active: i64&, pool: slice_pool<buffer::Cell>&,
          r: renderer::Renderer&, show_sidebar: bool) -> Intent, i64, bool {
    if tabs.len == 0 { return Intent.None, 0, false; }
    let cs = renderer::cell_size(r);
    let origin = renderer::grid_origin(r, show_sidebar);
    let sz = gfx::screen_size();
    let mp = gfx::mouse_pos();
    let mods = keys::held();
    let gui = (mods & gfx::MOD_GUI) != 0;
    var intent = Intent.None;
    var arg: i64 = 0;
    var changed = false;

    // A drag in progress owns every event until the button comes up.
    if st.dragging {
        if gfx::mouse_down(gfx::MOUSE_LEFT) {
            pty::drag_update();
        } else {
            pty::drag_end();
            st.dragging = false;
        }
        return Intent.None, 0, false;
    }
    // A press that might become a drag waits for the pointer to travel before
    // the window starts moving; until then it is an ordinary click.
    if st.drag_pending {
        if !gfx::mouse_down(gfx::MOUSE_LEFT) {
            st.drag_pending = false;
        } else {
            let dx = mp.x - st.press_x;
            let dy = mp.y - st.press_y;
            if dx * dx + dy * dy >= DRAG_THRESHOLD * DRAG_THRESHOLD {
                st.drag_pending = false;
                st.dragging = pty::drag_begin();
                return Intent.None, 0, false;
            }
        }
    }
    if gfx::mouse_pressed(gfx::MOUSE_LEFT) &&
       (gui || sidebar_grip(mp, sz, show_sidebar, r, tabs.len)) {
        st.press_x = mp.x;
        st.press_y = mp.y;
        st.drag_pending = true;
    }

    if sidebar_click(mp, sz, show_sidebar, r, tabs, active, intent, arg) {
        return intent, arg, intent != Intent.None;
    }

    let inside = mp.x >= origin.x && mp.y >= origin.y &&
                 mp.x < sz.x - renderer::PAD && mp.y < sz.y - renderer::PAD;
    var col = clamp(((mp.x - origin.x) / cs.x) as i64, 0, tabs[active].term.cols - 1);
    var row = clamp(((mp.y - origin.y) / cs.y) as i64, 0, tabs[active].term.rows - 1);
    let frac = if tabs[active].term.alt_active { 0.0 } else { tabs[active].scroll_frac };
    let first = tab::first_line(tabs[active]);
    var abs = first + (((mp.y - origin.y + frac) / cs.y) as i64);
    if abs < 0 { abs = 0; }

    // Ctrl+click (Cmd+click on macOS) on an OSC 8 link is the terminal-level
    // open gesture; it works even while an app is tracking the mouse.
    let link_mod = (mods & (gfx::MOD_CTRL | gfx::MOD_GUI)) != 0;
    if inside && link_mod && st.click_count == 1 && gfx::mouse_pressed(gfx::MOUSE_LEFT) {
        let c = buffer::cell_at_abs(tabs[active].term, pool, abs, col);
        if c.link != 0 {
            open_link(tabs[active], c.link);
            st.last_col = col;
            st.last_row = row;
            return Intent.None, 0, false;
        }
    }

    if terminal_mouse(tabs[active], inside, col, row, mods, st.last_col, st.last_row) {
        st.last_col = col;
        st.last_row = row;
        return Intent.None, 0, false;
    }

    if gfx::mouse_pressed(gfx::MOUSE_LEFT) && inside {
        scroll::stop();
        if st.click_count >= 3 {
            tab::selection_line(tabs[active], abs);
        } else if st.click_count == 2 {
            tab::selection_word(tabs[active], pool, abs, col);
        } else {
            tab::selection_start(tabs[active], abs, col);
        }
        st.selecting = true;
        changed = true;
    }
    if st.selecting && gfx::mouse_down(gfx::MOUSE_LEFT) {
        // Dragging past the top or bottom edge scrolls a line per frame and
        // keeps the selection endpoint on the line that came into view.
        var line = abs;
        let bottom = origin.y + tabs[active].term.rows * cs.y;
        if mp.y < origin.y {
            if scroll::by(tabs[active], 1, cs.y) { changed = true; }
            line = tab::first_line(tabs[active]);
        } else if mp.y >= bottom {
            if scroll::by(tabs[active], -1, cs.y) { changed = true; }
            line = tab::first_line(tabs[active]) + tabs[active].term.rows - 1;
        }
        if tabs[active].sel_line != line || tabs[active].sel_col != col {
            tab::selection_extend(tabs[active], line, col);
            changed = true;
        }
    }
    if gfx::mouse_released(gfx::MOUSE_LEFT) { st.selecting = false; }
    if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) && inside {
        scroll::stop();
        intent = Intent.PastePrimary;
    }

    let wheel = gfx::mouse_wheel();
    if wheel != 0.0 && gfx::mouse_in_window() {
        if (mods & gfx::MOD_CTRL) != 0 {
            intent = if wheel > 0.0 { Intent.ZoomIn } else { Intent.ZoomOut };
        } else if tabs[active].term.alt_active {
            wheel_arrows(tabs[active], wheel);
        } else if scroll::wheel(tabs[active], wheel, cs.y) {
            changed = true;
        }
    }
    st.last_col = col;
    st.last_row = row;
    return intent, arg, changed;
}
