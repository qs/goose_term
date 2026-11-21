// Scrollback search. A query is matched case-insensitively per line; the
// result is one highlighted range, and next/previous wrap through the active
// tab's history and visible grid. The bar that types the query is search_ui.

namespace search;

import std;
import slice_pool;
import .buffer;
import .tab;

const QUERY_MAX: i64 = 128;

struct State {
    active: bool = false,
    found: bool = false,
    line: i64 = 0,
    start: i64 = 0,
    end: i64 = 0,
    // Byte index of the editing caret in `query`.
    cursor: i64 = 0,
    // Bounded, not growable: a State sits inside other structs, and the query
    // is capped anyway.
    query: u8[..QUERY_MAX] = [],
}

// Opening keeps the last query: re-running the previous search is the common
// case after closing the bar.
fn open(s: State&) {
    s.active = true;
    s.cursor = s.query.len;
    s.found = false;
    s.line = 0;
    s.start = 0;
    s.end = 0;
}

fn close(s: State&) {
    s.active = false;
    s.found = false;
}

fn add_text(s: State&, cp: u32) {
    var encoded: u8[>..] = [];
    push_utf8(encoded, cp);
    insert_bytes(s, encoded);
}

fn insert_bytes(s: State&, bytes: const u8[:]) {
    if bytes.len == 0 || s.query.len + bytes.len > QUERY_MAX { return; }
    let old_len = s.query.len;
    s.query.resize(old_len + bytes.len, 0);
    // Shift the tail right from the caret, last byte first.
    var i = old_len;
    while i > s.cursor {
        s.query[i - 1 + bytes.len] = s.query[i - 1];
        i--;
    }
    var k = 0;
    while k < bytes.len {
        s.query[s.cursor + k] = bytes[k];
        k++;
    }
    s.cursor += bytes.len;
    s.found = false;
}

fn remove_range(s: State&, a: i64, b: i64) {
    if a < 0 || b > s.query.len || a >= b { return; }
    let n = b - a;
    var i = a;
    while i + n < s.query.len {
        s.query[i] = s.query[i + n];
        i++;
    }
    s.query.resize(s.query.len - n);
}

// Delete the code point before the caret.
fn backspace(s: State&) {
    if s.cursor <= 0 { return; }
    var n = s.cursor - 1;
    while n > 0 && (s.query[n] & 0xC0) == 0x80 { n -= 1; }
    remove_range(s, n, s.cursor);
    s.cursor = n;
    s.found = false;
}

// Delete the code point at the caret.
fn delete_forward(s: State&) {
    if s.cursor >= s.query.len { return; }
    var n = s.cursor + 1;
    while n < s.query.len && (s.query[n] & 0xC0) == 0x80 { n += 1; }
    remove_range(s, s.cursor, n);
    s.found = false;
}

fn left(s: State&) {
    if s.cursor <= 0 { return; }
    var n = s.cursor - 1;
    while n > 0 && (s.query[n] & 0xC0) == 0x80 { n -= 1; }
    s.cursor = n;
}

fn right(s: State&) {
    if s.cursor >= s.query.len { return; }
    var n = s.cursor + 1;
    while n < s.query.len && (s.query[n] & 0xC0) == 0x80 { n += 1; }
    s.cursor = n;
}

fn home(s: State&) { s.cursor = 0; }
fn end(s: State&) { s.cursor = s.query.len; }

fn clear(s: State&) {
    s.query.clear();
    s.cursor = 0;
    s.found = false;
}

fn fold(b: u8) -> u8 {
    if b >= 'A' && b <= 'Z' { return b + 32; }
    return b;
}

// The text of one line and, for each byte, the column it came from. A wide
// character's second cell contributes no bytes, so a match stays on the cell
// that draws it.
fn line_text(t: tab::Tab&, pool: slice_pool<buffer::Cell>&, line: i64,
             text: u8[>..]&, cols: i64[>..]&) {
    text.clear();
    cols.clear();
    var x = 0;
    while x < t.term.cols {
        let c = buffer::cell_at_abs(t.term, pool, line, x);
        if c.cp != 0 {
            let cp = if c.cp < 32 { 32 as u32 } else { c.cp };
            push_utf8(text, cp);
            if c.cp2 != 0 { push_utf8(text, c.cp2); }
            while cols.len < text.len { cols.push(x); }
        }
        x++;
    }
}

fn matches_at(text: const u8[:], pos: i64, q: const u8[:]) -> bool {
    if pos + q.len > text.len { return false; }
    var i = 0;
    while i < q.len {
        if fold(text[pos + i]) != fold(q[i]) { return false; }
        i++;
    }
    return true;
}

fn find_line(t: tab::Tab&, pool: slice_pool<buffer::Cell>&, line: i64,
             q: const u8[:], from_col: i64, forward: bool) -> bool, i64, i64 {
    var text: u8[>..] = [];
    var cols: i64[>..] = [];
    line_text(t, pool, line, text, cols);
    if q.len == 0 || q.len > text.len { return false, 0, 0; }

    var found = false;
    var hit_start = 0;
    var hit_end = 0;
    var pos = 0;
    while pos + q.len <= text.len {
        if matches_at(text, pos, q) {
            let start = cols[pos];
            if forward {
                if start >= from_col {
                    return true, start, cols[pos + q.len - 1];
                }
            } else if start <= from_col {
                // Keep the last match at or before the cursor.
                found = true;
                hit_start = start;
                hit_end = cols[pos + q.len - 1];
            }
        }
        pos++;
    }
    return found, hit_start, hit_end;
}

// Scan from a line/column in one direction, wrapping through the searchable
// range. Alt-screen searches only see the visible alt grid.
fn scan(s: State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&,
        start_line: i64, start_col: i64, forward: bool) -> bool {
    let lo = if t.term.alt_active { t.term.hist_count } else { 0 };
    let hi = t.term.hist_count + t.term.rows - 1;
    let total = hi - lo + 1;
    if total <= 0 { return false; }

    var line = start_line;
    if forward {
        if line > hi { line = lo; }
    } else {
        if line < lo { line = hi; }
    }
    line = clamp(line, lo, hi);
    var first = true;
    var steps = 0;
    while steps <= total {
        let from = if first { start_col } else { if forward { 0 } else { t.term.cols - 1 } };
        let found, hs, he = find_line(t, pool, line, s.query, from, forward);
        if found {
            s.found = true;
            s.line = line;
            s.start = hs;
            s.end = he;
            return true;
        }
        if forward {
            line++;
            if line > hi { line = lo; }
        } else {
            line--;
            if line < lo { line = hi; }
        }
        first = false;
        steps++;
    }
    s.found = false;
    return false;
}

fn find_first(s: State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&) -> bool {
    if s.query.len == 0 { s.found = false; return false; }
    return scan(s, t, pool, tab::first_line(t), 0, true);
}

fn next(s: State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&) -> bool {
    if s.query.len == 0 { s.found = false; return false; }
    if !s.found { return find_first(s, t, pool); }
    var line = s.line;
    var col = s.start + 1;
    if col >= t.term.cols {
        col = 0;
        line++;
    }
    return scan(s, t, pool, line, col, true);
}

fn prev(s: State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&) -> bool {
    if s.query.len == 0 { s.found = false; return false; }
    if !s.found {
        let hi = t.term.hist_count + t.term.rows - 1;
        return scan(s, t, pool, hi, t.term.cols - 1, false);
    }
    var line = s.line;
    var col = s.start - 1;
    if col < 0 {
        col = t.term.cols - 1;
        line--;
    }
    return scan(s, t, pool, line, col, false);
}

// Put the hit roughly a third of the way down the viewport. Alt-screen
// scrolling belongs to the app, so its search does not move the view.
fn reveal(t: tab::Tab&, s: State&) {
    if !s.found { return; }
    if t.term.alt_active {
        t.scroll = 0;
        t.scroll_frac = 0.0;
        return;
    }
    let partial = if t.scroll_frac > 0.001 { 1 } else { 0 };
    let visible_row = s.line - t.term.hist_count + t.scroll + partial;
    if visible_row >= 0 && visible_row < t.term.rows { return; }
    let target_top = s.line - t.term.rows / 3;
    t.scroll = clamp(t.term.hist_count - target_top, 0, t.term.hist_count);
    t.scroll_frac = 0.0;
}
