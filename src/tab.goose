// A tab: its PTY, terminal grid, parser, title and viewport selection.

namespace tab;

import std;
import slice_pool;
import .buffer;
import .parser;
import .pty;

struct Tab {
    proc: pty::Pty = pty::Pty { .. },
    term: buffer::Terminal = buffer::Terminal { .. },
    parser: parser::Parser = parser::Parser { .. },
    title: u8[..128] = [],
    scroll: i64 = 0,
    // Sub-line part of the scroll position, in pixels. Zero is a line
    // boundary; anything else lets touchpads move the viewport smoothly.
    scroll_frac: f32 = 0.0,
    alive: bool = true,
    sel_active: bool = false,
    sel_anchor_line: i64 = 0,
    sel_anchor_col: i64 = 0,
    sel_line: i64 = 0,
    sel_col: i64 = 0,
}

fn create(shell: const u8[:], pool: slice_pool<buffer::Cell>&, cols: i64, rows: i64) -> Tab {
    var t = Tab { proc: pty::spawn(shell, rows, cols), .. };
    buffer::init(t.term, pool, cols, rows);
    // The tab starts out named after the shell, until OSC 0/2 renames it.
    var start = 0;
    var i = 0;
    while i < shell.len {
        if shell[i] == '/' { start = i + 1; }
        i++;
    }
    if start < shell.len {
        i = start;
        while i < shell.len { t.title.push(shell[i]); i++; }
    } else {
        for b in "shell" { t.title.push(b); }
    }
    t.alive = t.proc.alive;
    return t;
}

fn close(t: Tab&) {
    pty::close(t.proc);
    t.alive = false;
}

fn resize(t: Tab&, pool: slice_pool<buffer::Cell>&, cols: i64, rows: i64) {
    if t.term.cols == cols && t.term.rows == rows { return; }
    buffer::resize(t.term, pool, cols, rows);
    pty::resize(t.proc, rows, cols);
    t.scroll = 0;
    t.scroll_frac = 0.0;
    t.sel_active = false;
}

fn write_bytes(t: Tab&, data: const u8[:]) -> i64 {
    return pty::write_bytes(t.proc, data);
}

// --- selection -------------------------------------------------------------
// Lines are absolute: 0 is the oldest scrollback line, hist_count the first
// visible one.

fn cell_le(a_line: i64, a_col: i64, b_line: i64, b_col: i64) -> bool {
    a_line < b_line || (a_line == b_line && a_col <= b_col)
}

fn order(t: Tab&) -> i64, i64, i64, i64 {
    let al = t.sel_anchor_line;
    let ac = t.sel_anchor_col;
    let el = t.sel_line;
    let ec = t.sel_col;
    if cell_le(al, ac, el, ec) { return al, ac, el, ec; }
    return el, ec, al, ac;
}

fn selection_start(t: Tab&, line: i64, col: i64) {
    t.sel_active = true;
    t.sel_anchor_line = line;
    t.sel_anchor_col = col;
    t.sel_line = line;
    t.sel_col = col;
}

fn selection_extend(t: Tab&, line: i64, col: i64) {
    t.sel_line = line;
    t.sel_col = col;
}

fn selection_space(cp: u32) -> bool {
    cp == 32 || cp == 0xA0 || cp == 9
}

// Kitty's default word set: Unicode alphanumerics plus @-./_~?&=%+#.
// The wide-character continuation cell (cp == 0) is not a word character.
fn selection_word_char(cp: u32) -> bool {
    if cp >= 48 && cp <= 57 { return true; }   // 0-9
    if cp >= 65 && cp <= 90 { return true; }   // A-Z
    if cp >= 97 && cp <= 122 { return true; }  // a-z
    if cp == 64 || cp == 45 || cp == 46 || cp == 47 || cp == 95 || cp == 126 ||
       cp == 63 || cp == 38 || cp == 61 || cp == 37 || cp == 43 || cp == 35 {
        return true;
    }
    // Common alphabetic ranges. Everything else, including punctuation,
    // box drawing, dingbats and emoji, breaks a word.
    if cp >= 0x00C0 && cp <= 0x024F {
        if cp == 0x00D7 || cp == 0x00F7 { return false; }
        return true;
    }
    if cp >= 0x0370 && cp <= 0x052F { return true; } // Greek, Cyrillic
    if cp >= 0x0530 && cp <= 0x058F { return true; } // Armenian
    if cp >= 0x0590 && cp <= 0x06FF { return true; } // Hebrew, Arabic
    if cp >= 0x0900 && cp <= 0x0DFF { return true; } // Indic
    if cp >= 0x0E00 && cp <= 0x0EFF { return true; } // Thai
    if cp >= 0x1E00 && cp <= 0x1EFF { return true; } // Latin extended
    if cp >= 0x3040 && cp <= 0x30FF { return true; } // kana
    if cp >= 0x3400 && cp <= 0x9FFF { return true; } // CJK
    if cp >= 0xAC00 && cp <= 0xD7AF { return true; } // Hangul
    return false;
}

// Double-click follows kitty's word boundaries rather than swallowing
// adjacent punctuation. Clicking whitespace selects that whitespace run;
// clicking other punctuation selects a run of the same character.
fn selection_word(t: Tab&, pool: slice_pool<buffer::Cell>&, line: i64, col: i64) {
    var start = clamp(col, 0, t.term.cols - 1);
    // A click on the second half of a wide glyph means the glyph itself.
    if start > 0 && buffer::cell_at_abs(t.term, pool, line, start).cp == 0 {
        start -= 1;
    }
    var end = start;
    let clicked = buffer::cell_at_abs(t.term, pool, line, start).cp;
    let word = selection_word_char(clicked);
    if selection_space(clicked) {
        while start > 0 && buffer::cell_at_abs(t.term, pool, line, start - 1).cp == clicked {
            start -= 1;
        }
        while end + 1 < t.term.cols &&
              buffer::cell_at_abs(t.term, pool, line, end + 1).cp == clicked {
            end += 1;
        }
    } else if word {
        while start > 0 &&
              selection_word_char(buffer::cell_at_abs(t.term, pool, line, start - 1).cp) {
            start -= 1;
        }
        while end + 1 < t.term.cols &&
              selection_word_char(buffer::cell_at_abs(t.term, pool, line, end + 1).cp) {
            end += 1;
        }
    } else {
        while start > 0 && buffer::cell_at_abs(t.term, pool, line, start - 1).cp == clicked {
            start -= 1;
        }
        while end + 1 < t.term.cols &&
              buffer::cell_at_abs(t.term, pool, line, end + 1).cp == clicked {
            end += 1;
        }
    }
    t.sel_active = true;
    t.sel_anchor_line = line;
    t.sel_anchor_col = start;
    t.sel_line = line;
    t.sel_col = end;
}

// Triple-click: the whole line.
fn selection_line(t: Tab&, line: i64) {
    t.sel_active = true;
    t.sel_anchor_line = line;
    t.sel_anchor_col = 0;
    t.sel_line = line;
    t.sel_col = t.term.cols - 1;
}

fn is_selected(t: Tab&, line: i64, col: i64) -> bool {
    if !t.sel_active { return false; }
    let l0, c0, l1, c1 = order(t);
    if cell_le(line, col, l0, c0) { return line == l0 && col == c0; }
    if cell_le(l1, c1, line, col) { return line == l1 && col == c1; }
    return true;
}

fn selection_text(t: Tab&, pool: slice_pool<buffer::Cell>&) -> u8[>..] {
    var out: u8[>..] = [];
    if !t.sel_active { return out; }
    let l0, c0, l1, c1 = order(t);
    var line = l0;
    while line <= l1 {
        var begin = 0;
        var end = t.term.cols - 1;
        if line == l0 { begin = c0; }
        if line == l1 { end = c1; }
        while end >= begin {
            let c = buffer::cell_at_abs(t.term, pool, line, end);
            if c.cp != 32 && c.cp != 0 { break; }
            end--;
        }
        var col = begin;
        while col <= end {
            let c = buffer::cell_at_abs(t.term, pool, line, col);
            if c.cp == 0 {
                col++;
                continue;
            }
            let cp = if c.cp < 32 { 32 as u32 } else { c.cp };
            push_utf8(out, cp);
            if c.cp2 != 0 { push_utf8(out, c.cp2); }
            col++;
        }
        if line != l1 { out.push(10); }
        line++;
    }
    return out;
}
