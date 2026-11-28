// Drawing: the terminal grid and a vertical tab sidebar on the left, through
// ui's font atlas and canvas.
//
// The primary face is JuliaMono: its block elements fill the cell's full
// height, so quadrant-block art tiles vertically without the gaps a code
// face leaves between its glyph height and the line box. Its symbols also
// cover Claude's spinner and tool markers without a fallback.
// JetBrains Mono is merged only for anything JuliaMono lacks.

namespace renderer;

import std;
import gfx;
import ui;
import slice_pool;
import .buffer;
import .tab;

const PAD: f32 = 8.0;
const LINE_FALLBACK: f32 = 1.05;
const SIDEBAR_COLS: f32 = 25.0;
const SIDEBAR_TOP: f32 = 6.0;
const TAB_ROW_GAP: f32 = 6.0;

const THEME_BG: u32 = 0x14141CFF;
const THEME_FG: u32 = 0xE6E6E6FF;
const THEME_SIDEBAR_BG: u32 = 0x171722FF;
const THEME_SIDEBAR_LINE: u32 = 0x2A2A3AFF;
const THEME_SIDEBAR_ACTIVE: u32 = 0x343450FF;
const THEME_SIDEBAR_DIM: u32 = 0x9292B0FF;
const THEME_CURSOR: u32 = 0x89B4FAFF;
const THEME_SEARCH_BG: u32 = 0x5B5B2AFF;
const THEME_SEARCH_FG: u32 = 0xFFFFFFFF;
const THEME_LINK: u32 = 0x89B4FAFF;

let FONT_DATA: const u8[:] = embed_file("../assets/JuliaMono-Regular.ttf");
let FALLBACK_DATA: const u8[:] = embed_file("../assets/font.ttf");

// What is baked into the atlas: basic Latin, Latin-1 and extended, spacing
// and combining marks, Greek, Cyrillic, punctuation, currency, letterlike
// symbols, arrows, math, box drawing, blocks, geometric shapes, Claude's
// technical symbols, dingbats and braille spinners. Missing glyphs fall
// through to JetBrains Mono, then to '?'.
const UNICODE_RANGES: u32[36] = [
    0x0020, 0x007E,
    0x00A0, 0x024F,
    0x02B0, 0x02FF,
    0x0300, 0x036F,
    0x0370, 0x03FF,
    0x0400, 0x04FF,
    0x2000, 0x206F,
    0x20A0, 0x20BF,
    0x2100, 0x214F,
    0x2190, 0x21FF,
    0x2200, 0x22FF,
    0x2300, 0x23FF,
    0x2500, 0x259F,
    0x25A0, 0x25FF,
    0x2600, 0x26FF,
    0x2700, 0x27BF,
    0x2800, 0x28FF,
    0x2B00, 0x2BFF,
];

struct Renderer {
    ctx: ui::Context = ui::Context { 0 },
    atlas: ui::FontAtlas = ui::FontAtlas { 0 },
    font: ui::Font = ui::Font { 0 },
    font_px: f32 = 0.0,
    cell_w: f32 = 8.0,
    cell_h: f32 = 16.0,
    valid: bool = false,
}

struct Drawn {
    cp: u32 = 32,
    cp2: u32 = 0,
    fg: u32 = 0xE6E6E6FF,
    bg: u32 = 0x14141CFF,
    underline: bool = false,
    bold: bool = false,
}

// Everything one frame needs to know besides the terminal state. Passing
// this instead of six loose parameters keeps the draw calls readable as the
// view gains overlays.
struct View {
    active: i64 = 0,
    show_sidebar: bool = false,
    cursor_on: bool = true,
    search_active: bool = false,
    search_query: u8[128] = [0; 128],
    search_query_len: i64 = 0,
    search_cursor: i64 = 0,
    search_found: bool = false,
    hit_line: i64 = 0,
    hit_start: i64 = 0,
    hit_end: i64 = 0,
    // The link under the pointer while Ctrl/Cmd is held. Underlining it shows
    // the click target before the click.
    hover_link: buffer::Span = buffer::Span { .. },
}

fn color(c: u32) -> ui::Color {
    ui::Color {
        r: ((c >> 24) & 255) as u8,
        g: ((c >> 16) & 255) as u8,
        b: ((c >> 8) & 255) as u8,
        a: (c & 255) as u8,
    }
}

fn dim(c: u32) -> u32 {
    let r = (((c >> 24) & 255) as i64 * 6) / 10;
    let g = (((c >> 16) & 255) as i64 * 6) / 10;
    let b = (((c >> 8) & 255) as i64 * 6) / 10;
    buffer::pack_color(r, g, b)
}

fn metrics(r: Renderer&) {
    var w = ui::text_width(r.font, "M");
    if w <= 0.1 { w = r.font_px * 0.6; }
    r.cell_w = w;
    // A terminal cell has to be exactly as tall as the full block glyph, or
    // stacked blocks show a seam. Nuklear's block can be a little taller
    // than its nominal line height, so take the larger real measurement.
    let info = ui::info(r.font);
    var h = max(info.height, r.font_px * LINE_FALLBACK);
    let full, own = ui::find_glyph(r.font, 0x2588);
    if own && full.h > h { h = full.h; }
    r.cell_h = h;
}

fn init(r: Renderer&, size: f32) -> bool {
    r.atlas = ui::create_font_atlas();
    if r.atlas.id == 0 { return false; }
    var cfg = ui::FontConfig { oversample_h: 2, oversample_v: 2 };
    r.font = ui::add_font_from_memory(r.atlas, FONT_DATA, size, cfg, UNICODE_RANGES);
    if r.font.id == 0 {
        ui::destroy(r.atlas);
        r.atlas = ui::FontAtlas { 0 };
        return false;
    }
    // Merged into the first font, so terminal text keeps one font handle.
    var fallback_cfg = ui::FontConfig { oversample_h: 2, oversample_v: 2, merge_mode: true };
    let fallback = ui::add_font_from_memory(r.atlas, FALLBACK_DATA, size, fallback_cfg, UNICODE_RANGES);
    if fallback.id == 0 {
        ui::destroy(r.atlas);
        r.atlas = ui::FontAtlas { 0 };
        r.font = ui::Font { 0 };
        return false;
    }
    if !ui::bake(r.atlas) {
        ui::destroy(r.atlas);
        r.atlas = ui::FontAtlas { 0 };
        return false;
    }
    r.ctx = ui::create_context(r.font);
    if r.ctx.id == 0 {
        ui::destroy(r.atlas);
        r.atlas = ui::FontAtlas { 0 };
        return false;
    }
    var st = ui::style(r.ctx);
    st.window.fixed_background = ui::style_item_hide();
    ui::set_style(r.ctx, st);
    r.font_px = size;
    metrics(r);
    r.valid = true;
    return true;
}

fn set_font(r: Renderer&, size: f32) -> bool {
    if !r.valid { return false; }
    ui::destroy(r.ctx);
    ui::destroy(r.atlas);
    r.ctx = ui::Context { 0 };
    r.atlas = ui::FontAtlas { 0 };
    r.valid = false;
    return init(r, size);
}

fn destroy(r: Renderer&) {
    if r.valid {
        ui::destroy(r.ctx);
        ui::destroy(r.atlas);
        r.valid = false;
    }
}

fn cell_size(r: Renderer&) -> float2 {
    float2 { r.cell_w, r.cell_h }
}

// Where the grid starts: past the sidebar when it is showing.
fn grid_origin(r: Renderer&, show_sidebar: bool) -> float2 {
    var x = PAD;
    if show_sidebar { x += sidebar_width(r, gfx::screen_size().x); }
    return float2 { x, PAD };
}

fn tab_row_height(r: Renderer&) -> f32 {
    r.cell_h + TAB_ROW_GAP
}

// Wide enough for a readable tab name, but never more than a little over a
// third of the window, so the grid keeps most of it.
fn sidebar_width(r: Renderer&, screen_w: f32) -> f32 {
    var w = SIDEBAR_COLS * r.cell_w + 12.0;
    let cap = screen_w * 0.36;
    if w > cap { w = cap; }
    let floor = 11.0 * r.cell_w + 12.0;
    if w < floor { w = floor; }
    return w;
}

// Which sidebar row a y coordinate is over; -1 above the first.
fn tab_index_at(r: Renderer&, y: f32) -> i64 {
    if y < SIDEBAR_TOP { return -1; }
    return ((y - SIDEBAR_TOP) / tab_row_height(r)) as i64;
}

fn cp_count(s: const u8[:]) -> i64 {
    var n = 0;
    for b in s {
        if (b & 0xC0) != 0x80 { n++; }
    }
    return n;
}

fn byte_at_cp(s: const u8[:], want: i64) -> i64 {
    var n = 0;
    var i = 0;
    while i < s.len {
        if (s[i] & 0xC0) != 0x80 {
            if n == want { return i; }
            n++;
        }
        i++;
    }
    return s.len;
}

// Copy at most max_chars code points, ending in an ellipsis if cut. Cutting
// by code points keeps a multi-byte character whole.
fn append_clipped(out: u8[>..]&, s: const u8[:], max_chars: i64) {
    if max_chars <= 0 { return; }
    if cp_count(s) <= max_chars {
        out.append(s);
        return;
    }
    if max_chars == 1 {
        push_utf8(out, 0x2026);
        return;
    }
    let cut = byte_at_cp(s, max_chars - 1);
    out.append(s[..cut]);
    push_utf8(out, 0x2026);
}

fn drawn_cell(t: tab::Tab&, pool: slice_pool<buffer::Cell>&, abs: i64, x: i64,
              sel_active: bool, l0: i64, c0: i64, l1: i64, c1: i64) -> Drawn {
    let c = buffer::cell_at_abs(t.term, pool, abs, x);
    var fg = c.fg;
    var bg = c.bg;
    if (c.flags & buffer::ATTR_INVERSE) != 0 {
        let tmp = fg;
        fg = bg;
        bg = tmp;
    }
    if tab::cell_in_range(sel_active, l0, c0, l1, c1, abs, x) {
        let tmp = fg;
        fg = bg;
        bg = tmp;
    }
    if (c.flags & buffer::ATTR_DIM) != 0 { fg = dim(fg); }
    Drawn { cp: c.cp, cp2: c.cp2, fg: fg, bg: bg,
            underline: (c.flags & buffer::ATTR_UNDERLINE) != 0,
            bold: (c.flags & buffer::ATTR_BOLD) != 0 }
}

fn hit_cell(d: Drawn, view: View, abs: i64, x: i64) -> Drawn {
    if view.search_active && view.search_found && abs == view.hit_line &&
       x >= view.hit_start && x <= view.hit_end {
        return Drawn { cp: d.cp, cp2: d.cp2, fg: THEME_SEARCH_FG, bg: THEME_SEARCH_BG,
                       underline: d.underline, bold: d.bold };
    }
    return d;
}

// While Ctrl/Cmd is held over a link, the whole target is underlined and
// tinted, so the click has a visible target before it happens.
fn hover_cell(d: Drawn, view: View, abs: i64, x: i64) -> Drawn {
    if !view.hover_link.ok || !buffer::span_has(view.hover_link, abs, x) { return d; }
    return Drawn { cp: d.cp, cp2: d.cp2, fg: THEME_LINK, bg: d.bg,
                   underline: true, bold: d.bold };
}

// One row of resolved cells, reused between rows and frames.
var row_buf: Drawn[>..] = [];

fn draw_grid(r: Renderer&, pool: slice_pool<buffer::Cell>&, t: tab::Tab&, ox: f32, oy: f32,
             view: View) {
    let cw = r.cell_w;
    let ch = r.cell_h;
    // Sub-line scrolling shifts the whole grid up by `frac` and exposes one
    // extra line at the top. The partial rows are clipped to the grid in
    // draw(), after they have been painted.
    let frac = if t.term.alt_active { 0.0 } else { t.scroll_frac };
    let partial = frac > 0.001;
    let first = if t.term.alt_active {
        t.term.hist_count
    } else {
        t.term.hist_count - t.scroll - (if partial { 1 } else { 0 })
    };
    let draw_rows = t.term.rows + (if partial { 1 } else { 0 });
    let y0 = oy - frac;
    // Resolve the selection once: it is one range for every cell on screen.
    let sel = t.sel_active;
    let l0, c0, l1, c1 = tab::order(t);
    var text: u8[>..] = [];
    var y = 0;
    while y < draw_rows {
        let abs = first + y;
        let py = y0 + y * ch;
        // Resolve the row once, search highlight included: the run loop below
        // has to read every cell again to find where the attributes change,
        // so computing each cell twice was the hot spot of a frame.
        if row_buf.len < t.term.cols { row_buf.resize(t.term.cols, Drawn { .. }); }
        var x = 0;
        while x < t.term.cols {
            row_buf[x] = hover_cell(
                hit_cell(drawn_cell(t, pool, abs, x, sel, l0, c0, l1, c1), view, abs, x),
                view, abs, x);
            x++;
        }
        x = 0;
        while x < t.term.cols {
            let d0 = row_buf[x];
            text.clear();
            var text_end = 0;
            var j = x;
            while j < t.term.cols {
                let d = row_buf[j];
                if d.fg != d0.fg || d.bg != d0.bg || d.underline != d0.underline ||
                   d.bold != d0.bold { break; }
                // A zero is the second half of a wide glyph, which the
                // one drawn for the first half already covers.
                if d.cp != 0 {
                    let cp = if d.cp < 32 { 32 as u32 } else { d.cp };
                    push_utf8(text, cp);
                    if d.cp2 != 0 {
                        push_utf8(text, d.cp2);
                        text_end = text.len;
                    } else if cp != 32 {
                        text_end = text.len;
                    }
                }
                j++;
            }
            let x0 = ox + x * cw;
            let w = (j - x) * cw;
            if d0.bg != buffer::DEFAULT_BG {
                ui::fill_rect(r.ctx, ui::rect(x0, py, w, ch), 0.0, color(d0.bg));
            }
            // Trailing spaces are already covered by the background: drawing
            // their quads every frame is pure waste.
            if text_end > 0 {
                ui::draw_text(r.ctx, ui::rect(x0, py + (ch - r.font_px) * 0.5, w, ch),
                              text[..text_end], r.font, color(0), color(d0.fg));
                // No bold face is baked; a second, sub-pixel-shifted pass is
                // the usual way a terminal thickens an already-loaded face.
                if d0.bold {
                    ui::draw_text(r.ctx, ui::rect(x0 + 0.7, py + (ch - r.font_px) * 0.5, w, ch),
                                  text[..text_end], r.font, color(0), color(d0.fg));
                }
            }
            if d0.underline {
                ui::fill_rect(r.ctx, ui::rect(x0, py + ch - 2.0, w, 1.0), 0.0, color(d0.fg));
            }
            x = j;
        }
        y++;
    }
}

fn scroll_lines_for(t: tab::Tab&) -> i64 {
    if t.scroll_frac > 0.001 { return t.scroll + 1; }
    return t.scroll;
}

fn draw_sidebar(r: Renderer&, tabs: tab::Tab[:], active: i64, w: f32, h: f32) {
    let sw = sidebar_width(r, w);
    let rh = tab_row_height(r);
    let inner = sw - PAD * 2.0;
    var max_chars = (inner / r.cell_w) as i64;
    if max_chars < 3 { max_chars = 3; }

    ui::fill_rect(r.ctx, ui::rect(0, 0, sw, h), 0.0, color(THEME_SIDEBAR_BG));
    ui::fill_rect(r.ctx, ui::rect(sw - 1.0, 0, 1.0, h), 0.0, color(THEME_SIDEBAR_LINE));

    var y = SIDEBAR_TOP;
    for i in tabs.len {
        if y + rh > h - r.cell_h - 8.0 { break; }
        var label: u8[>..] = [];
        format(label, i + 1);
        label.push(':');
        label.push(' ');
        if tabs[i].title.len > 0 {
            label.append(tabs[i].title);
        } else {
            label.append("shell");
        }
        if i == active { label.push('*'); }
        var clipped: u8[>..] = [];
        append_clipped(clipped, label, max_chars);
        if i == active {
            ui::fill_rect(r.ctx, ui::rect(2.0, y - 3.0, sw - 4.0, rh - 2.0), 0.0,
                          color(THEME_SIDEBAR_ACTIVE));
        }
        let fg = if i == active { THEME_FG } else { THEME_SIDEBAR_DIM };
        ui::draw_text(r.ctx, ui::rect(PAD, y, inner, rh), clipped, r.font,
                      color(0), color(fg));
        y += rh;
    }

    if active >= 0 && active < tabs.len && scroll_lines_for(tabs[active]) > 0 {
        let s = str("+", scroll_lines_for(tabs[active]), " lines");
        var clipped: u8[>..] = [];
        append_clipped(clipped, s, max_chars);
        let sy = h - r.cell_h - 4.0;
        ui::draw_text(r.ctx, ui::rect(PAD, sy, inner, r.cell_h), clipped, r.font,
                      color(0), color(THEME_CURSOR));
    }
}

// With the sidebar hidden there is no place for the scroll position, so it
// goes over the grid's top-right corner.
fn draw_scroll_hint(r: Renderer&, scroll: i64, w: f32) {
    if scroll <= 0 { return; }
    let s = str("[SCROLL +", scroll, "]");
    let sw = ui::text_width(r.font, s);
    if sw >= w - PAD * 2.0 { return; }
    let bh = r.cell_h;
    ui::fill_rect(r.ctx, ui::rect(w - sw - PAD - 4.0, 2.0, sw + 8.0, bh), 0.0,
                  color(THEME_SIDEBAR_BG));
    ui::draw_text(r.ctx, ui::rect(w - sw - PAD, 3.0, sw + 2.0, bh), s, r.font,
                  color(0), color(THEME_CURSOR));
}

fn draw_search(r: Renderer&, view: View, w: f32, h: f32) {
    if !view.search_active { return; }
    let bh = r.cell_h + 8.0;
    let y = h - bh;
    ui::fill_rect(r.ctx, ui::rect(0, y, w, bh), 0.0, color(THEME_SIDEBAR_BG));
    ui::fill_rect(r.ctx, ui::rect(0, y, w, 1.0), 0.0, color(THEME_SEARCH_BG));

    var label: u8[>..] = [];
    label.append("Search: ");
    label.append(view.search_query[..view.search_query_len]);
    if view.search_query_len == 0 {
        label.append("  (type to search)");
    } else if !view.search_found {
        label.append("  (no match)");
    } else {
        label.append("  Enter next  Shift+Enter prev  Esc close");
    }
    var clipped: u8[>..] = [];
    var max_chars = ((w - PAD * 2.0) / r.cell_w) as i64;
    if max_chars < 3 { max_chars = 3; }
    append_clipped(clipped, label, max_chars);
    ui::draw_text(r.ctx, ui::rect(PAD, y + 4.0, w - PAD * 2.0, r.cell_h), clipped,
                  r.font, color(0), color(THEME_FG));

    // The caret, so the query can be edited in the middle of a word.
    var before: u8[>..] = [];
    before.append("Search: ");
    before.append(view.search_query[..clamp(view.search_cursor, 0, view.search_query_len)]);
    var cx = PAD + ui::text_width(r.font, before);
    if cx > w - PAD { cx = w - PAD; }
    ui::fill_rect(r.ctx, ui::rect(cx, y + 4.0, 1.0, r.cell_h), 0.0, color(THEME_CURSOR));
}

fn draw_cursor(r: Renderer&, t: tab::Tab&, ox: f32, oy: f32, cursor_on: bool) {
    if !cursor_on { return; }
    if t.scroll != 0 || t.scroll_frac > 0.001 { return; }
    if (t.term.modes & buffer::MODE_CURSOR_VISIBLE) == 0 { return; }
    // A terminal that does not have the keyboard focus shows no cursor.
    if !gfx::focused() { return; }
    let x = ox + t.term.cur_x * r.cell_w;
    let y = oy + t.term.cur_y * r.cell_h;
    // A slim bar needs one quad and no glyph re-draw, so it is at least as
    // cheap as the old full-cell block while leaving the character legible.
    let bw = max(2.0, r.cell_w * 0.16);
    ui::fill_rect(r.ctx, ui::rect(x + 0.5, y + 1.0, bw, r.cell_h - 2.0), 0.0,
                  color(THEME_CURSOR));
}

fn draw(r: Renderer&, pool: slice_pool<buffer::Cell>&, tabs: tab::Tab[:], view: View) {
    if !r.valid { return; }
    ui::input_from_gfx(r.ctx);
    let sz = gfx::screen_size();
    let w = sz.x as f32;
    let h = sz.y as f32;
    ui::window_set_bounds(r.ctx, "term", ui::rect(0, 0, w, h));
    if ui::begin(r.ctx, "term", ui::rect(0, 0, w, h),
                 ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        ui::fill_rect(r.ctx, ui::rect(0, 0, w, h), 0.0, color(THEME_BG));
        if tabs.len > 0 {
            var ox = PAD;
            var i = view.active;
            if i < 0 || i >= tabs.len { i = 0; }
            if view.show_sidebar {
                draw_sidebar(r, tabs, i, w, h);
                ox += sidebar_width(r, w);
            }
            draw_grid(r, pool, tabs[i], ox, PAD, view);
            let frac = if tabs[i].term.alt_active { 0.0 } else { tabs[i].scroll_frac };
            if frac > 0.001 {
                let grid_bottom = PAD + tabs[i].term.rows * r.cell_h;
                ui::fill_rect(r.ctx, ui::rect(ox, 0, w - ox, PAD), 0.0, color(THEME_BG));
                ui::fill_rect(r.ctx, ui::rect(ox, grid_bottom, w - ox, h - grid_bottom), 0.0,
                              color(THEME_BG));
            }
            draw_cursor(r, tabs[i], ox, PAD, view.cursor_on);
            if !view.show_sidebar && !view.search_active {
                draw_scroll_hint(r, scroll_lines_for(tabs[i]), w);
            }
        }
        draw_search(r, view, w, h);
    }
    ui::end(r.ctx);
}
