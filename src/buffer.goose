// The terminal grid, its SGR state, and the scrollback ring.
//
// Every tab owns one Terminal. The cells themselves live in a slice pool
// shared by all tabs, and a Terminal only keeps offsets into it: that way a
// Terminal is fixed-size and can sit in an ordinary grow-only array, while
// the memory behind it grows in slices as the window and the history do.

namespace buffer;

import std;
import slice_pool;

const MAX_SCROLLBACK: i64 = 10000;
const HIST_INITIAL: i64 = 256;
const DEFAULT_FG: u32 = 0xE6E6E6FF;
const DEFAULT_BG: u32 = 0x14141CFF;

// Cell attribute bits, as SGR sets them.
const ATTR_BOLD: u8 = 1;
const ATTR_DIM: u8 = 2;
const ATTR_ITALIC: u8 = 4;
const ATTR_UNDERLINE: u8 = 8;
const ATTR_INVERSE: u8 = 16;

// Terminal modes, mostly set by CSI ? ... h / l.
const MODE_WRAP: u32 = 1;
const MODE_BRACKETED_PASTE: u32 = 2;
const MODE_CURSOR_VISIBLE: u32 = 4;
const MODE_INSERT: u32 = 8;
const MODE_MOUSE_X10: u32 = 16;
const MODE_MOUSE_BUTTON: u32 = 32;
const MODE_MOUSE_DRAG: u32 = 64;
const MODE_MOUSE_MOVE: u32 = 128;
const MODE_MOUSE_UTF8: u32 = 256;
const MODE_MOUSE_SGR: u32 = 512;
const MODE_FOCUS_EVENTS: u32 = 1024;

const MAX_LINKS: i64 = 64;
const LINK_DATA_MAX: i64 = 16384;

// One character cell: code point, resolved colors, attributes, and a
// combining mark drawn over the same cell. A cp of 0 marks the second half
// of a wide (two-column) character.
struct Cell {
    cp: u32 = 32,
    cp2: u32 = 0,
    fg: u32 = 0xE6E6E6FF,
    bg: u32 = 0x14141CFF,
    flags: u8 = 0,
    link: u16 = 0,      // 1 + an index in Terminal's link table, 0 for none
}

struct Terminal {
    cols: i64 = 0,
    rows: i64 = 0,
    grid_off: i64 = 0,
    grid_len: i64 = 0,
    hist_off: i64 = 0,
    hist_len: i64 = 0,
    hist_cap: i64 = 0,
    hist_count: i64 = 0,
    hist_total: i64 = 0,
    cur_x: i64 = 0,
    cur_y: i64 = 0,
    saved_x: i64 = 0,
    saved_y: i64 = 0,
    scroll_top: i64 = 0,
    scroll_bot: i64 = 0,
    fg: u32 = 0xE6E6E6FF,
    bg: u32 = 0x14141CFF,
    attrs: u8 = 0,
    wrap_pending: bool = false,
    modes: u32 = 5,

    // Alternate screen (`CSI ? 1049 h`): the normal grid and cursor are
    // parked in main_* while the full-screen app draws on a fresh grid.
    alt_active: bool = false,
    main_grid_off: i64 = 0,
    main_grid_len: i64 = 0,
    main_cur_x: i64 = 0,
    main_cur_y: i64 = 0,
    main_saved_x: i64 = 0,
    main_saved_y: i64 = 0,
    main_scroll_top: i64 = 0,
    main_scroll_bot: i64 = 0,
    main_wrap_pending: bool = false,

    // OSC 8 hyperlinks are interned per terminal so a cell only stores a
    // small id. This table lives as long as the cells that refer to it.
    link_data: u8[16384] = [0; 16384],
    link_off: i64[64] = [0; 64],
    link_len: i64[64] = [0; 64],
    nlinks: i64 = 0,
    link_bytes: i64 = 0,
    link_id: u16 = 0,
}

fn blank() -> Cell {
    Cell { cp: 32, fg: DEFAULT_FG, bg: DEFAULT_BG, flags: 0 }
}

fn init(t: Terminal&, pool: slice_pool<Cell>&, cols: i64, rows: i64) {
    t.cols = max(cols, 2);
    t.rows = max(rows, 1);
    t.grid_len = t.cols * t.rows;
    let grid = pool.alloc_slice(t.grid_len);
    t.grid_off = pool.items.range_index(grid);
    for i in t.grid_len { pool.items[t.grid_off + i] = blank(); }

    t.hist_cap = HIST_INITIAL;
    t.hist_len = t.hist_cap * t.cols;
    let hist = pool.alloc_slice(t.hist_len);
    t.hist_off = pool.items.range_index(hist);
    for i in t.hist_len { pool.items[t.hist_off + i] = blank(); }

    t.hist_count = 0;
    t.hist_total = 0;
    t.cur_x = 0;
    t.cur_y = 0;
    t.saved_x = 0;
    t.saved_y = 0;
    t.scroll_top = 0;
    t.scroll_bot = t.rows - 1;
    t.fg = DEFAULT_FG;
    t.bg = DEFAULT_BG;
    t.attrs = 0;
    t.wrap_pending = false;
    t.modes = MODE_WRAP | MODE_CURSOR_VISIBLE;
    t.alt_active = false;
    t.nlinks = 0;
    t.link_bytes = 0;
    t.link_id = 0;
}

fn cell_at(t: Terminal&, pool: slice_pool<Cell>&, x: i64, y: i64) -> Cell {
    if x < 0 || x >= t.cols || y < 0 || y >= t.rows { return blank(); }
    return pool.items[t.grid_off + y * t.cols + x];
}

fn set_cell(t: Terminal&, pool: slice_pool<Cell>&, x: i64, y: i64, c: Cell) {
    if x < 0 || x >= t.cols || y < 0 || y >= t.rows { return; }
    pool.items[t.grid_off + y * t.cols + x] = c;
}

// A cell by absolute buffer line: 0 is the oldest scrollback line, and
// hist_count on is the visible grid.
fn cell_at_abs(t: Terminal&, pool: slice_pool<Cell>&, abs: i64, col: i64) -> Cell {
    if col < 0 || col >= t.cols { return blank(); }
    if abs < 0 { return blank(); }
    if abs < t.hist_count {
        let oldest = t.hist_total - t.hist_count;
        let slot = (oldest + abs) % t.hist_cap;
        return pool.items[t.hist_off + slot * t.cols + col];
    }
    let y = abs - t.hist_count;
    if y >= t.rows { return blank(); }
    return cell_at(t, pool, col, y);
}

fn clear_row(t: Terminal&, pool: slice_pool<Cell>&, y: i64) {
    if y < 0 || y >= t.rows { return; }
    let base = t.grid_off + y * t.cols;
    for x in t.cols { pool.items[base + x] = blank(); }
}

fn clear_row_from(t: Terminal&, pool: slice_pool<Cell>&, y: i64, x: i64) {
    if y < 0 || y >= t.rows { return; }
    var col = max(x, 0);
    while col < t.cols {
        pool.items[t.grid_off + y * t.cols + col] = blank();
        col++;
    }
}

fn clear_row_to(t: Terminal&, pool: slice_pool<Cell>&, y: i64, x: i64) {
    if y < 0 || y >= t.rows { return; }
    var col = 0;
    let last = min(x, t.cols - 1);
    while col <= last {
        pool.items[t.grid_off + y * t.cols + col] = blank();
        col++;
    }
}

fn clear_scrollback(t: Terminal&, pool: slice_pool<Cell>&) {
    for i in t.hist_len { pool.items[t.hist_off + i] = blank(); }
    t.hist_count = 0;
    t.hist_total = 0;
}

// --- hyperlinks ------------------------------------------------------------

// Intern `uri` and return its id (1-based), or 0 when the table is full.
// Repeating a URI reuses its id, which is the common OSC 8 pattern.
fn register_link(t: Terminal&, uri: const u8[:]) -> u16 {
    if uri.len == 0 { return 0; }
    var i = 0;
    while i < t.nlinks {
        if t.link_len[i] == uri.len {
            var same = true;
            var k = 0;
            while k < uri.len {
                if t.link_data[t.link_off[i] + k] != uri[k] { same = false; break; }
                k++;
            }
            if same { return (i + 1) as u16; }
        }
        i++;
    }
    if t.nlinks >= MAX_LINKS { return 0; }
    if t.link_bytes + uri.len > LINK_DATA_MAX { return 0; }
    t.link_off[t.nlinks] = t.link_bytes;
    t.link_len[t.nlinks] = uri.len;
    var k = 0;
    while k < uri.len {
        t.link_data[t.link_bytes + k] = uri[k];
        k++;
    }
    t.link_bytes += uri.len;
    t.nlinks += 1;
    return t.nlinks as u16;
}

fn set_link(t: Terminal&, uri: const u8[:]) {
    t.link_id = register_link(t, uri);
}

fn link_uri(t: Terminal&, id: u16, out: u8[>..]&) {
    let i = id as i64 - 1;
    if i < 0 || i >= t.nlinks { return; }
    var k = 0;
    while k < t.link_len[i] {
        out.push(t.link_data[t.link_off[i] + k]);
        k++;
    }
}

// --- alternate screen ------------------------------------------------------

fn enter_alt(t: Terminal&, pool: slice_pool<Cell>&) {
    if t.alt_active { return; }
    t.main_grid_off = t.grid_off;
    t.main_grid_len = t.grid_len;
    t.main_cur_x = t.cur_x;
    t.main_cur_y = t.cur_y;
    t.main_saved_x = t.saved_x;
    t.main_saved_y = t.saved_y;
    t.main_scroll_top = t.scroll_top;
    t.main_scroll_bot = t.scroll_bot;
    t.main_wrap_pending = t.wrap_pending;

    t.grid_len = t.cols * t.rows;
    let grid = pool.alloc_slice(t.grid_len);
    t.grid_off = pool.items.range_index(grid);
    for i in t.grid_len { pool.items[t.grid_off + i] = blank(); }

    t.cur_x = 0;
    t.cur_y = 0;
    t.saved_x = 0;
    t.saved_y = 0;
    t.scroll_top = 0;
    t.scroll_bot = t.rows - 1;
    t.wrap_pending = false;
    t.link_id = 0;
    t.alt_active = true;
}

fn exit_alt(t: Terminal&, pool: slice_pool<Cell>&) {
    if !t.alt_active { return; }
    let off = t.grid_off;
    let len = t.grid_len;
    pool.free_slice(pool.items[off..off + len]);

    t.grid_off = t.main_grid_off;
    t.grid_len = t.main_grid_len;
    t.cur_x = clamp(t.main_cur_x, 0, t.cols - 1);
    t.cur_y = clamp(t.main_cur_y, 0, t.rows - 1);
    t.saved_x = clamp(t.main_saved_x, 0, t.cols - 1);
    t.saved_y = clamp(t.main_saved_y, 0, t.rows - 1);
    t.scroll_top = clamp(t.main_scroll_top, 0, t.rows - 1);
    t.scroll_bot = clamp(t.main_scroll_bot, t.scroll_top, t.rows - 1);
    t.wrap_pending = t.main_wrap_pending;
    t.link_id = 0;
    t.alt_active = false;
}

fn set_alt_screen(t: Terminal&, pool: slice_pool<Cell>&, on: bool) {
    if on { enter_alt(t, pool); } else { exit_alt(t, pool); }
}

fn wants_mouse(t: Terminal&) -> bool {
    (t.modes & (MODE_MOUSE_X10 | MODE_MOUSE_BUTTON | MODE_MOUSE_DRAG | MODE_MOUSE_MOVE)) != 0
}

// Grow the scrollback ring, keeping the lines it already holds. Growing
// renumbers the lines, so anything that stored an absolute line (a
// selection) is cleared by the caller.
fn grow_history(t: Terminal&, pool: slice_pool<Cell>&) {
    if t.hist_cap >= MAX_SCROLLBACK { return; }
    var new_cap = t.hist_cap * 2;
    if new_cap > MAX_SCROLLBACK { new_cap = MAX_SCROLLBACK; }
    let new_len = new_cap * t.cols;
    let fresh = pool.alloc_slice(new_len);
    let fresh_off = pool.items.range_index(fresh);
    for i in new_len { pool.items[fresh_off + i] = blank(); }

    let oldest = t.hist_total - t.hist_count;
    var line = 0;
    while line < t.hist_count {
        let old_slot = (oldest + line) % t.hist_cap;
        let to = fresh_off + line * t.cols;
        let from = t.hist_off + old_slot * t.cols;
        pool.items[to..to + t.cols].move_from(pool.items[from..from + t.cols]);
        line++;
    }

    let old_off = t.hist_off;
    let old_len = t.hist_len;
    pool.free_slice(pool.items[old_off..old_off + old_len]);
    t.hist_off = fresh_off;
    t.hist_len = new_len;
    t.hist_cap = new_cap;
    t.hist_total = t.hist_count;
}

// Move the oldest lines out: keep at most `keep` of them, newest last. The
// lines are renumbered, so a caller holding an absolute line (a selection, a
// scroll offset) has to let go of it.
fn trim_history(t: Terminal&, pool: slice_pool<Cell>&, keep: i64) {
    if keep >= t.hist_count { return; }
    var want = if keep < 0 { 0 } else { keep };
    let new_cap = max(want, 64);
    let new_len = new_cap * t.cols;
    let fresh = pool.alloc_slice(new_len);
    let fresh_off = pool.items.range_index(fresh);
    for i in new_len { pool.items[fresh_off + i] = blank(); }

    let oldest = t.hist_total - t.hist_count;
    var line = t.hist_count - want;
    var w = 0;
    while line < t.hist_count {
        let slot = (oldest + line) % t.hist_cap;
        let to = fresh_off + w * t.cols;
        let from = t.hist_off + slot * t.cols;
        pool.items[to..to + t.cols].move_from(pool.items[from..from + t.cols]);
        w++;
        line++;
    }
    pool.free_slice(pool.items[t.hist_off..t.hist_off + t.hist_len]);
    t.hist_off = fresh_off;
    t.hist_len = new_len;
    t.hist_cap = new_cap;
    t.hist_count = w;
    t.hist_total = w;
}

fn history_push(t: Terminal&, pool: slice_pool<Cell>&, y: i64) {
    if t.hist_count == t.hist_cap { grow_history(t, pool); }
    let slot = t.hist_total % t.hist_cap;
    let base = t.hist_off + slot * t.cols;
    let from = t.grid_off + y * t.cols;
    pool.items[base..base + t.cols].move_from(pool.items[from..from + t.cols]);
    t.hist_total += 1;
    if t.hist_count < t.hist_cap { t.hist_count += 1; }
}

fn scroll_up(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    let count = clamp(n, 0, t.scroll_bot - t.scroll_top + 1);
    for k in count {
        // The alternate screen is not part of scrollback; full-screen apps
        // own their own scrolling.
        if !t.alt_active && t.scroll_top == 0 && t.scroll_bot == t.rows - 1 {
            history_push(t, pool, t.scroll_top);
        }
        var y = t.scroll_top;
        while y < t.scroll_bot {
            let to = t.grid_off + y * t.cols;
            let from = to + t.cols;
            pool.items[to..to + t.cols].move_from(pool.items[from..from + t.cols]);
            y++;
        }
        clear_row(t, pool, t.scroll_bot);
    }
}

fn scroll_down(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    let count = clamp(n, 0, t.scroll_bot - t.scroll_top + 1);
    for k in count {
        var y = t.scroll_bot;
        while y > t.scroll_top {
            let to = t.grid_off + y * t.cols;
            let from = to - t.cols;
            pool.items[to..to + t.cols].move_from(pool.items[from..from + t.cols]);
            y--;
        }
        clear_row(t, pool, t.scroll_top);
    }
}

fn line_feed(t: Terminal&, pool: slice_pool<Cell>&) {
    t.wrap_pending = false;
    if t.cur_y == t.scroll_bot {
        scroll_up(t, pool, 1);
    } else if t.cur_y < t.rows - 1 {
        t.cur_y += 1;
    }
}

fn reverse_index(t: Terminal&, pool: slice_pool<Cell>&) {
    t.wrap_pending = false;
    if t.cur_y == t.scroll_top {
        scroll_down(t, pool, 1);
    } else if t.cur_y > 0 {
        t.cur_y -= 1;
    }
}

fn carriage_return(t: Terminal&) {
    t.cur_x = 0;
    t.wrap_pending = false;
}

fn backspace(t: Terminal&) {
    t.cur_x = max(t.cur_x - 1, 0);
    t.wrap_pending = false;
}

fn tab_forward(t: Terminal&) {
    let next = ((t.cur_x / 8) + 1) * 8;
    t.cur_x = min(next, t.cols - 1);
    t.wrap_pending = false;
}

// How many columns a code point takes: 0 for combining marks, 2 for East
// Asian wide/fullwidth characters and emoji, 1 otherwise.
fn char_width(cp: u32) -> i64 {
    if cp >= 0x0300 && cp <= 0x036f { return 0; }
    if cp >= 0x1ab0 && cp <= 0x1aff { return 0; }
    if cp >= 0x1dc0 && cp <= 0x1dff { return 0; }
    if cp >= 0x20d0 && cp <= 0x20ff { return 0; }
    if cp >= 0xfe00 && cp <= 0xfe0f { return 0; }
    if cp >= 0xfe20 && cp <= 0xfe2f { return 0; }
    if cp == 0x200d { return 0; }

    if cp >= 0x1100 && cp <= 0x115f { return 2; }
    if cp >= 0x2e80 && cp <= 0x303e { return 2; }
    if cp >= 0x3041 && cp <= 0x33ff { return 2; }
    if cp >= 0x3400 && cp <= 0x4dbf { return 2; }
    if cp >= 0x4e00 && cp <= 0x9fff { return 2; }
    if cp >= 0xa000 && cp <= 0xa4cf { return 2; }
    if cp >= 0xac00 && cp <= 0xd7a3 { return 2; }
    if cp >= 0xf900 && cp <= 0xfaff { return 2; }
    if cp >= 0xfe30 && cp <= 0xfe4f { return 2; }
    if cp >= 0xff00 && cp <= 0xff60 { return 2; }
    if cp >= 0xffe0 && cp <= 0xffe6 { return 2; }
    if cp >= 0x1f300 && cp <= 0x1faff { return 2; }
    if cp >= 0x20000 && cp <= 0x3fffd { return 2; }
    return 1;
}

fn put_char(t: Terminal&, pool: slice_pool<Cell>&, cp: u32) {
    let width = char_width(cp);

    // A combining mark joins the cell just written instead of taking one.
    if width == 0 {
        var x = t.cur_x;
        if !t.wrap_pending { x -= 1; }
        if x < 0 { x = 0; }
        if cell_at(t, pool, x, t.cur_y).cp == 0 && x > 0 { x -= 1; }
        var c = cell_at(t, pool, x, t.cur_y);
        c.cp2 = cp;
        set_cell(t, pool, x, t.cur_y, c);
        return;
    }

    if t.wrap_pending && (t.modes & MODE_WRAP) != 0 {
        t.wrap_pending = false;
        t.cur_x = 0;
        line_feed(t, pool);
    }
    t.wrap_pending = false;

    // A wide character that would straddle the right edge moves down whole.
    if width == 2 && t.cur_x + 1 >= t.cols && t.cur_x > 0 {
        t.cur_x = 0;
        line_feed(t, pool);
    }
    if t.cur_x >= t.cols { t.cur_x = t.cols - 1; }

    set_cell(t, pool, t.cur_x, t.cur_y,
             Cell { cp: cp, fg: t.fg, bg: t.bg, flags: t.attrs, link: t.link_id });
    if width == 2 && t.cur_x + 1 < t.cols {
        set_cell(t, pool, t.cur_x + 1, t.cur_y,
                 Cell { cp: 0, fg: t.fg, bg: t.bg, flags: t.attrs, link: t.link_id });
    }

    if t.cur_x + width >= t.cols {
        t.cur_x = t.cols - 1;
        t.wrap_pending = true;
    } else {
        t.cur_x += width;
    }
}

fn set_position(t: Terminal&, row: i64, col: i64) {
    t.cur_y = clamp(row, 0, t.rows - 1);
    t.cur_x = clamp(col, 0, t.cols - 1);
    t.wrap_pending = false;
}

fn cursor_up(t: Terminal&, n: i64) {
    let floor = min(t.scroll_top, t.cur_y);
    t.cur_y = max(t.cur_y - max(n, 1), floor);
    t.wrap_pending = false;
}

fn cursor_down(t: Terminal&, n: i64) {
    let ceiling = max(t.scroll_bot, t.cur_y);
    t.cur_y = min(t.cur_y + max(n, 1), ceiling);
    t.wrap_pending = false;
}

fn cursor_left(t: Terminal&, n: i64) {
    t.cur_x = max(t.cur_x - max(n, 1), 0);
    t.wrap_pending = false;
}

fn cursor_right(t: Terminal&, n: i64) {
    t.cur_x = min(t.cur_x + max(n, 1), t.cols - 1);
    t.wrap_pending = false;
}

fn set_column(t: Terminal&, col: i64) {
    t.cur_x = clamp(col, 0, t.cols - 1);
    t.wrap_pending = false;
}

fn set_row(t: Terminal&, row: i64) {
    t.cur_y = clamp(row, 0, t.rows - 1);
    t.wrap_pending = false;
}

fn save_cursor(t: Terminal&) {
    t.saved_x = t.cur_x;
    t.saved_y = t.cur_y;
}

fn restore_cursor(t: Terminal&) {
    t.cur_x = clamp(t.saved_x, 0, t.cols - 1);
    t.cur_y = clamp(t.saved_y, 0, t.rows - 1);
    t.wrap_pending = false;
}

fn erase_display(t: Terminal&, pool: slice_pool<Cell>&, mode: i64) {
    if mode == 0 {
        clear_row_from(t, pool, t.cur_y, t.cur_x);
        var y = t.cur_y + 1;
        while y < t.rows {
            clear_row(t, pool, y);
            y++;
        }
    } else if mode == 1 {
        clear_row_to(t, pool, t.cur_y, t.cur_x);
        var y = 0;
        while y < t.cur_y {
            clear_row(t, pool, y);
            y++;
        }
    } else if mode == 2 {
        for y in t.rows { clear_row(t, pool, y); }
    } else if mode == 3 {
        for y in t.rows { clear_row(t, pool, y); }
        clear_scrollback(t, pool);
    }
}

fn erase_line(t: Terminal&, pool: slice_pool<Cell>&, mode: i64) {
    if mode == 0 {
        clear_row_from(t, pool, t.cur_y, t.cur_x);
    } else if mode == 1 {
        clear_row_to(t, pool, t.cur_y, t.cur_x);
    } else if mode == 2 {
        clear_row(t, pool, t.cur_y);
    }
}

fn insert_lines(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    if t.cur_y < t.scroll_top || t.cur_y > t.scroll_bot { return; }
    let count = min(max(n, 1), t.scroll_bot - t.cur_y + 1);
    var y = t.scroll_bot;
    while y >= t.cur_y + count {
        let to = t.grid_off + y * t.cols;
        let from = t.grid_off + (y - count) * t.cols;
        pool.items[to..to + t.cols].move_from(pool.items[from..from + t.cols]);
        y--;
    }
    var k = 0;
    while k < count {
        clear_row(t, pool, t.cur_y + k);
        k++;
    }
    t.cur_x = 0;
}

fn delete_lines(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    if t.cur_y < t.scroll_top || t.cur_y > t.scroll_bot { return; }
    let count = min(max(n, 1), t.scroll_bot - t.cur_y + 1);
    var y = t.cur_y;
    while y + count <= t.scroll_bot {
        let to = t.grid_off + y * t.cols;
        let from = t.grid_off + (y + count) * t.cols;
        pool.items[to..to + t.cols].move_from(pool.items[from..from + t.cols]);
        y++;
    }
    var k = 0;
    while k < count {
        clear_row(t, pool, t.scroll_bot - k);
        k++;
    }
    t.cur_x = 0;
}

fn insert_chars(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    let count = min(max(n, 1), t.cols - t.cur_x);
    var x = t.cols - 1;
    while x >= t.cur_x + count {
        pool.items[t.grid_off + t.cur_y * t.cols + x] =
            pool.items[t.grid_off + t.cur_y * t.cols + x - count];
        x--;
    }
    var k = 0;
    while k < count {
        set_cell(t, pool, t.cur_x + k, t.cur_y, blank());
        k++;
    }
}

fn delete_chars(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    let count = min(max(n, 1), t.cols - t.cur_x);
    var x = t.cur_x;
    while x + count < t.cols {
        pool.items[t.grid_off + t.cur_y * t.cols + x] =
            pool.items[t.grid_off + t.cur_y * t.cols + x + count];
        x++;
    }
    var k = 0;
    while k < count {
        set_cell(t, pool, t.cols - count + k, t.cur_y, blank());
        k++;
    }
}

fn erase_chars(t: Terminal&, pool: slice_pool<Cell>&, n: i64) {
    let count = min(max(n, 1), t.cols - t.cur_x);
    var k = 0;
    while k < count {
        set_cell(t, pool, t.cur_x + k, t.cur_y, blank());
        k++;
    }
}

fn set_scroll_region(t: Terminal&, top: i64, bottom: i64) {
    let a = clamp(top, 0, t.rows - 1);
    let b = clamp(bottom, 0, t.rows - 1);
    if a < b {
        t.scroll_top = a;
        t.scroll_bot = b;
        t.cur_x = 0;
        t.cur_y = a;
        t.wrap_pending = false;
    }
}

fn set_mode_bit(t: Terminal&, bit: u32, on: bool) {
    if on {
        t.modes = t.modes | bit;
    } else {
        t.modes = t.modes & ~bit;
    }
}

fn has_mode(t: Terminal&, bit: u32) -> bool {
    (t.modes & bit) != 0
}

fn reset(t: Terminal&, pool: slice_pool<Cell>&) {
    if t.alt_active { exit_alt(t, pool); }
    for y in t.rows { clear_row(t, pool, y); }
    t.cur_x = 0;
    t.cur_y = 0;
    t.saved_x = 0;
    t.saved_y = 0;
    t.scroll_top = 0;
    t.scroll_bot = t.rows - 1;
    t.fg = DEFAULT_FG;
    t.bg = DEFAULT_BG;
    t.attrs = 0;
    t.wrap_pending = false;
    t.modes = MODE_WRAP | MODE_CURSOR_VISIBLE;
}

// Reallocate one grid for a new geometry, keeping the overlapping text.
fn resize_grid(pool: slice_pool<Cell>&, old_off: i64, old_len: i64,
               old_cols: i64, old_rows: i64, cols: i64, rows: i64) -> i64, i64 {
    let len = cols * rows;
    let fresh = pool.alloc_slice(len);
    let off = pool.items.range_index(fresh);
    for i in len { pool.items[off + i] = blank(); }
    let copy_rows = min(old_rows, rows);
    let copy_cols = min(old_cols, cols);
    var y = 0;
    while y < copy_rows {
        let to = off + y * cols;
        let from = old_off + y * old_cols;
        pool.items[to..to + copy_cols].move_from(pool.items[from..from + copy_cols]);
        y++;
    }
    pool.free_slice(pool.items[old_off..old_off + old_len]);
    return off, len;
}

// Reallocate the grid and the scrollback for a new size, keeping the text
// that still fits. History is renumbered from its oldest surviving line.
// While the alternate screen is active both grids are resized, so leaving it
// later restores the normal screen at the new size.
fn resize(t: Terminal&, pool: slice_pool<Cell>&, cols: i64, rows: i64) {
    let new_cols = max(cols, 2);
    let new_rows = max(rows, 1);
    if new_cols == t.cols && new_rows == t.rows { return; }

    let old_cols = t.cols;
    let old_rows = t.rows;
    let old_hist_off = t.hist_off;
    let old_hist_len = t.hist_len;
    let was_alt = t.alt_active;

    let new_grid_off, new_grid_len = resize_grid(pool, t.grid_off, t.grid_len,
                                                 old_cols, old_rows, new_cols, new_rows);
    t.grid_off = new_grid_off;
    t.grid_len = new_grid_len;
    if was_alt {
        let main_off, main_len = resize_grid(pool, t.main_grid_off, t.main_grid_len,
                                             old_cols, old_rows, new_cols, new_rows);
        t.main_grid_off = main_off;
        t.main_grid_len = main_len;
    }

    // The scrollback is laid out by columns: a height-only resize (dragging
    // the window's bottom edge, say) can keep it as it is.
    if new_cols != old_cols {
        let fresh_hist_len = t.hist_cap * new_cols;
        let fresh_hist = pool.alloc_slice(fresh_hist_len);
        let fresh_hist_off = pool.items.range_index(fresh_hist);
        for i in fresh_hist_len { pool.items[fresh_hist_off + i] = blank(); }

        let oldest = t.hist_total - t.hist_count;
        let copy = min(old_cols, new_cols);
        var line = 0;
        while line < t.hist_count {
            let old_slot = (oldest + line) % t.hist_cap;
            let to = fresh_hist_off + line * new_cols;
            let from = old_hist_off + old_slot * old_cols;
            pool.items[to..to + copy].move_from(pool.items[from..from + copy]);
            line++;
        }
        pool.free_slice(pool.items[old_hist_off..old_hist_off + old_hist_len]);

        t.hist_off = fresh_hist_off;
        t.hist_len = fresh_hist_len;
        t.hist_total = t.hist_count;
    }

    t.cols = new_cols;
    t.rows = new_rows;
    t.cur_x = clamp(t.cur_x, 0, t.cols - 1);
    t.cur_y = clamp(t.cur_y, 0, t.rows - 1);
    t.saved_x = clamp(t.saved_x, 0, t.cols - 1);
    t.saved_y = clamp(t.saved_y, 0, t.rows - 1);
    t.scroll_top = 0;
    t.scroll_bot = t.rows - 1;
    t.wrap_pending = false;

    if was_alt {
        t.main_cur_x = clamp(t.main_cur_x, 0, t.cols - 1);
        t.main_cur_y = clamp(t.main_cur_y, 0, t.rows - 1);
        t.main_saved_x = clamp(t.main_saved_x, 0, t.cols - 1);
        t.main_saved_y = clamp(t.main_saved_y, 0, t.rows - 1);
        t.main_scroll_top = 0;
        t.main_scroll_bot = t.rows - 1;
        t.main_wrap_pending = false;
    }
}

// Colors: packed as 0xRRGGBBAA.

fn pack_color(r: i64, g: i64, b: i64) -> u32 {
    ((clamp(r, 0, 255) as u32) << 24) | ((clamp(g, 0, 255) as u32) << 16) |
        ((clamp(b, 0, 255) as u32) << 8) | 255
}

fn ansi_color(i: i64) -> u32 {
    match i {
        0 => 0x1E1E2EFF,
        1 => 0xF38BA8FF,
        2 => 0xA6E3A1FF,
        3 => 0xF9E2AFFF,
        4 => 0x89B4FAFF,
        5 => 0xCBA6F7FF,
        6 => 0x94E2D5FF,
        7 => 0xCDD6F4FF,
        8 => 0x585B70FF,
        9 => 0xF37799FF,
        10 => 0xB9F0A9FF,
        11 => 0xFBEBAFFF,
        12 => 0xA6C8FFFF,
        13 => 0xDDB6F7FF,
        14 => 0xA9E8DFFF,
        15 => 0xE6E9F0FF,
        _ => 0xE6E6E6FF,
    }
}

fn color256(n: i64) -> u32 {
    if n < 16 { return ansi_color(n); }
    if n < 232 {
        let k = n - 16;
        let steps: i64[6] = [0, 95, 135, 175, 215, 255];
        return pack_color(steps[k / 36], steps[(k / 6) % 6], steps[k % 6]);
    }
    if n < 256 {
        let v = 8 + (n - 232) * 10;
        return pack_color(v, v, v);
    }
    return DEFAULT_FG;
}
