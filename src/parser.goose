// The VT100/ANSI escape sequence state machine, after Paul Williams' DEC
// parser: Ground, Escape, Csi*, OscString. It decodes UTF-8 first and hands
// whole code points to the buffer, which knows nothing about escape
// sequences.

namespace parser;

import std;
import gfx;
import slice_pool;
import .buffer;
import .pty;

enum State {
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    CsiIgnore,
    OscString,
    DcsPassthrough,
}

const MAX_PARAMS: i64 = 32;

struct Parser {
    state: State = State.Ground,
    params: i32[32] = [0; 32],
    nparams: i64 = 0,
    cur: i64 = 0,
    has_cur: bool = false,
    prefix: u8 = 0,
    inter: u8 = 0,
    osc: u8[32768] = [0; 32768],
    osc_len: i64 = 0,
    osc_esc: bool = false,
    title: u8[..128] = [],
    title_changed: bool = false,
    // The decoded OSC 52 payload is written into the front of `osc` in place
    // (it is always shorter than the base64 that produced it) and handed to
    // the clipboard as soon as the sequence completes, before the next OSC
    // can reuse the buffer.
    clipboard_len: i64 = 0,
    clipboard_primary: bool = false,
    utf8: u8[4] = [0; 4],
    utf8_len: i64 = 0,
    utf8_need: i64 = 0,
}

fn reset_csi(p: Parser&) {
    p.nparams = 0;
    p.cur = 0;
    p.has_cur = false;
    p.prefix = 0;
    p.inter = 0;
}

fn push_param(p: Parser&) {
    if p.nparams < MAX_PARAMS {
        p.params[p.nparams] = p.cur as i32;
        p.nparams += 1;
    }
    p.cur = 0;
    p.has_cur = false;
}

// A parameter, or `dflt` where it is absent; 0 also means the default for
// the movements and erasures that use this.
fn param(p: Parser&, i: i64, dflt: i64) -> i64 {
    if i >= p.nparams { return dflt; }
    let v = p.params[i] as i64;
    if v == 0 { return dflt; }
    return v;
}

fn param_raw(p: Parser&, i: i64) -> i64 {
    if i >= p.nparams { return 0; }
    return p.params[i];
}

fn feed(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, data: u8[:]) {
    for b in data {
        step(p, t, pool, b);
    }
}

fn step(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, b: u8) {
    match p.state {
        Ground => ground(p, t, pool, b),
        Escape => escape_state(p, t, pool, b),
        EscapeIntermediate => { p.state = State.Ground; },
        CsiEntry => csi_entry(p, t, pool, b),
        CsiParam => csi_param(p, t, pool, b),
        CsiIntermediate => { if b >= 0x40 && b <= 0x7e { dispatch(p, t, pool, b); } },
        CsiIgnore => { if b >= 0x40 && b <= 0x7e { p.state = State.Ground; } },
        OscString => osc_byte(p, t, b),
        DcsPassthrough => {
            if b == 0x1b {
                p.osc_esc = true;
            } else if p.osc_esc && b == '\\' {
                p.osc_esc = false;
                p.state = State.Ground;
            }
        },
    }
}

fn ground(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, b: u8) {
    if p.utf8_len > 0 {
        if b >= 0x80 && b <= 0xbf {
            if p.utf8_len < 4 { p.utf8[p.utf8_len] = b; }
            p.utf8_len += 1;
            if p.utf8_len == p.utf8_need {
                let cp = decode_utf8(p);
                p.utf8_len = 0;
                p.utf8_need = 0;
                buffer::put_char(t, pool, cp);
            }
            return;
        }
        p.utf8_len = 0;
        p.utf8_need = 0;
        buffer::put_char(t, pool, 0xFFFD);
        // The byte that broke the sequence starts a new one.
    }

    if b < 0x20 || b == 0x7f {
        control(p, t, pool, b);
        return;
    }
    if b < 0x80 {
        buffer::put_char(t, pool, b);
        return;
    }
    if b == 0x9b {
        reset_csi(p);
        p.state = State.CsiEntry;
        return;
    }
    if b == 0x9d {
        p.osc_len = 0;
        p.osc_esc = false;
        p.state = State.OscString;
        return;
    }
    if b >= 0xc2 && b <= 0xdf {
        p.utf8[0] = b;
        p.utf8_len = 1;
        p.utf8_need = 2;
    } else if b >= 0xe0 && b <= 0xef {
        p.utf8[0] = b;
        p.utf8_len = 1;
        p.utf8_need = 3;
    } else if b >= 0xf0 && b <= 0xf4 {
        p.utf8[0] = b;
        p.utf8_len = 1;
        p.utf8_need = 4;
    } else {
        buffer::put_char(t, pool, 0xFFFD);
    }
}

fn decode_utf8(p: Parser&) -> u32 {
    let len = p.utf8_len;
    if len == 2 {
        let cp = (((p.utf8[0] as u32) & 0x1f) << 6) | ((p.utf8[1] as u32) & 0x3f);
        if cp < 0x80 { return 0xFFFD; }
        return cp;
    }
    if len == 3 {
        let cp = (((p.utf8[0] as u32) & 0x0f) << 12) | (((p.utf8[1] as u32) & 0x3f) << 6) |
                 ((p.utf8[2] as u32) & 0x3f);
        if cp < 0x800 { return 0xFFFD; }
        if cp >= 0xd800 && cp <= 0xdfff { return 0xFFFD; }
        return cp;
    }
    if len == 4 {
        let cp = (((p.utf8[0] as u32) & 0x07) << 18) | (((p.utf8[1] as u32) & 0x3f) << 12) |
                 (((p.utf8[2] as u32) & 0x3f) << 6) | ((p.utf8[3] as u32) & 0x3f);
        if cp < 0x10000 || cp > 0x10ffff { return 0xFFFD; }
        return cp;
    }
    return 0xFFFD;
}

fn control(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, b: u8) {
    if b == 0x1b {
        reset_csi(p);
        p.state = State.Escape;
    } else if b == 0x0a || b == 0x0b || b == 0x0c {
        buffer::line_feed(t, pool);
    } else if b == 0x0d {
        buffer::carriage_return(t);
    } else if b == 0x08 {
        buffer::backspace(t);
    } else if b == 0x09 {
        buffer::tab_forward(t);
    } else if b == 0x18 || b == 0x1a {
        p.state = State.Ground;
    }
    // BEL (0x07) and the other C0 controls are ignored.
}

fn escape_state(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, b: u8) {
    if b == '[' {
        reset_csi(p);
        p.state = State.CsiEntry;
    } else if b == ']' {
        p.osc_len = 0;
        p.osc_esc = false;
        p.state = State.OscString;
    } else if b == 'P' || b == '^' || b == '_' {
        p.state = State.DcsPassthrough;
    } else if b == '(' || b == ')' || b == '*' || b == '+' {
        p.state = State.EscapeIntermediate;
    } else {
        p.state = State.Ground;
        if b == '7' {
            buffer::save_cursor(t);
        } else if b == '8' {
            buffer::restore_cursor(t);
        } else if b == 'D' {
            buffer::line_feed(t, pool);
        } else if b == 'E' {
            buffer::carriage_return(t);
            buffer::line_feed(t, pool);
        } else if b == 'M' {
            buffer::reverse_index(t, pool);
        } else if b == 'c' {
            buffer::reset(t, pool);
        }
    }
}

fn csi_entry(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, b: u8) {
    if b >= '0' && b <= '9' {
        p.cur = b - '0';
        p.has_cur = true;
        p.state = State.CsiParam;
    } else if b == ';' {
        push_param(p);
        p.state = State.CsiParam;
    } else if b >= 0x3c && b <= 0x3f {
        p.prefix = b;
    } else if b >= 0x20 && b <= 0x2f {
        p.inter = b;
        p.state = State.CsiIntermediate;
    } else if b >= 0x40 && b <= 0x7e {
        dispatch(p, t, pool, b);
    } else if b == 0x1b {
        reset_csi(p);
        p.state = State.Escape;
    }
}

fn csi_param(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, b: u8) {
    if b >= '0' && b <= '9' {
        p.cur = p.cur * 10 + (b - '0');
        if p.cur > 65535 { p.cur = 65535; }
        p.has_cur = true;
    } else if b == ';' || b == ':' {
        push_param(p);
    } else if b >= 0x20 && b <= 0x2f {
        p.inter = b;
        p.state = State.CsiIntermediate;
    } else if b >= 0x40 && b <= 0x7e {
        dispatch(p, t, pool, b);
    } else if b == 0x1b {
        reset_csi(p);
        p.state = State.Escape;
    }
}

fn dispatch(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, final: u8) {
    if p.has_cur || p.nparams == 0 { push_param(p); }
    let count = param(p, 0, 1);

    // A private marker (? < > =) or an intermediate byte makes this a
    // terminal-mode or device sequence, not SGR or a cursor movement.
    // Claude sends CSI > 4 ; 2 m for modifyOtherKeys; read as SGR that is
    // underline plus dim, which then sticks to everything after it.
    if p.prefix != 0 {
        if p.prefix == '?' && (final == 'h' || final == 'l') {
            set_modes(p, t, pool, final == 'h');
        }
        p.state = State.Ground;
        return;
    }
    if p.inter != 0 {
        p.state = State.Ground;
        return;
    }

    if final == 'A' { buffer::cursor_up(t, count); }
    else if final == 'B' { buffer::cursor_down(t, count); }
    else if final == 'C' { buffer::cursor_right(t, count); }
    else if final == 'D' { buffer::cursor_left(t, count); }
    else if final == 'E' {
        buffer::cursor_down(t, count);
        buffer::carriage_return(t);
    } else if final == 'F' {
        buffer::cursor_up(t, count);
        buffer::carriage_return(t);
    } else if final == 'G' || final == '`' {
        buffer::set_column(t, count - 1);
    } else if final == 'd' {
        buffer::set_row(t, count - 1);
    } else if final == 'H' || final == 'f' {
        let row = param(p, 0, 1);
        let col = param(p, 1, 1);
        buffer::set_position(t, row - 1, col - 1);
    } else if final == 'J' {
        buffer::erase_display(t, pool, param_raw(p, 0));
    } else if final == 'K' {
        buffer::erase_line(t, pool, param_raw(p, 0));
    } else if final == 'L' {
        buffer::insert_lines(t, pool, count);
    } else if final == 'M' {
        buffer::delete_lines(t, pool, count);
    } else if final == '@' {
        buffer::insert_chars(t, pool, count);
    } else if final == 'P' {
        buffer::delete_chars(t, pool, count);
    } else if final == 'X' {
        buffer::erase_chars(t, pool, count);
    } else if final == 'S' {
        buffer::scroll_up(t, pool, count);
    } else if final == 'T' {
        buffer::scroll_down(t, pool, count);
    } else if final == 'r' {
        let top = param(p, 0, 1);
        let bottom = param(p, 1, t.rows);
        buffer::set_scroll_region(t, top - 1, bottom - 1);
    } else if final == 'm' {
        sgr(p, t);
    } else if final == 'h' || final == 'l' {
        set_modes(p, t, pool, final == 'h');
    } else if final == 's' {
        buffer::save_cursor(t);
    } else if final == 'u' {
        buffer::restore_cursor(t);
    }
    p.state = State.Ground;
}

fn set_modes(p: Parser&, t: buffer::Terminal&, pool: slice_pool<buffer::Cell>&, on: bool) {
    if p.prefix != '?' {
        if param_raw(p, 0) == 4 {
            buffer::set_mode_bit(t, buffer::MODE_INSERT, on);
        }
        return;
    }
    var i = 0;
    while i < p.nparams {
        let m = p.params[i] as i64;
        if m == 2004 {
            buffer::set_mode_bit(t, buffer::MODE_BRACKETED_PASTE, on);
        } else if m == 25 {
            buffer::set_mode_bit(t, buffer::MODE_CURSOR_VISIBLE, on);
        } else if m == 7 {
            buffer::set_mode_bit(t, buffer::MODE_WRAP, on);
        } else if m == 1049 || m == 1047 || m == 47 {
            buffer::set_alt_screen(t, pool, on);
        } else if m == 1048 {
            if on { buffer::save_cursor(t); } else { buffer::restore_cursor(t); }
        } else if m == 1004 {
            buffer::set_mode_bit(t, buffer::MODE_FOCUS_EVENTS, on);
        } else if m == 1005 {
            buffer::set_mode_bit(t, buffer::MODE_MOUSE_UTF8, on);
        } else if m == 1006 {
            buffer::set_mode_bit(t, buffer::MODE_MOUSE_SGR, on);
        } else if m == 9 || m == 1000 || m == 1002 || m == 1003 {
            // The tracking levels are alternatives; turning one on replaces
            // whichever level was active before.
            if on { t.modes = t.modes & ~(buffer::MODE_MOUSE_X10 | buffer::MODE_MOUSE_BUTTON |
                                          buffer::MODE_MOUSE_DRAG | buffer::MODE_MOUSE_MOVE); }
            if m == 9 { buffer::set_mode_bit(t, buffer::MODE_MOUSE_X10, on); }
            else if m == 1000 { buffer::set_mode_bit(t, buffer::MODE_MOUSE_BUTTON, on); }
            else if m == 1002 { buffer::set_mode_bit(t, buffer::MODE_MOUSE_DRAG, on); }
            else if m == 1003 { buffer::set_mode_bit(t, buffer::MODE_MOUSE_MOVE, on); }
        }
        i++;
    }
}

fn sgr(p: Parser&, t: buffer::Terminal&) {
    var i = 0;
    while i < p.nparams {
        let v = p.params[i] as i64;
        if v == 0 {
            t.fg = buffer::DEFAULT_FG;
            t.bg = buffer::DEFAULT_BG;
            t.attrs = 0;
        } else if v == 1 {
            t.attrs = t.attrs | buffer::ATTR_BOLD;
        } else if v == 2 {
            t.attrs = t.attrs | buffer::ATTR_DIM;
        } else if v == 3 {
            t.attrs = t.attrs | buffer::ATTR_ITALIC;
        } else if v == 4 {
            t.attrs = t.attrs | buffer::ATTR_UNDERLINE;
        } else if v == 7 {
            t.attrs = t.attrs | buffer::ATTR_INVERSE;
        } else if v == 21 || v == 22 {
            t.attrs = t.attrs & ~(buffer::ATTR_BOLD | buffer::ATTR_DIM);
        } else if v == 23 {
            t.attrs = t.attrs & ~buffer::ATTR_ITALIC;
        } else if v == 24 {
            t.attrs = t.attrs & ~buffer::ATTR_UNDERLINE;
        } else if v == 27 {
            t.attrs = t.attrs & ~buffer::ATTR_INVERSE;
        } else if v >= 30 && v <= 37 {
            t.fg = buffer::ansi_color(v - 30);
        } else if v == 39 {
            t.fg = buffer::DEFAULT_FG;
        } else if v >= 40 && v <= 47 {
            t.bg = buffer::ansi_color(v - 40);
        } else if v == 49 {
            t.bg = buffer::DEFAULT_BG;
        } else if v >= 90 && v <= 97 {
            t.fg = buffer::ansi_color(v - 90 + 8);
        } else if v >= 100 && v <= 107 {
            t.bg = buffer::ansi_color(v - 100 + 8);
        } else if v == 38 || v == 48 {
            var color = buffer::DEFAULT_FG;
            var used = 0;
            if i + 1 < p.nparams {
                let kind = p.params[i + 1] as i64;
                if kind == 5 && i + 2 < p.nparams {
                    color = buffer::color256(p.params[i + 2]);
                    used = 2;
                } else if kind == 2 && i + 4 < p.nparams {
                    color = buffer::pack_color(p.params[i + 2],
                                               p.params[i + 3],
                                               p.params[i + 4]);
                    used = 4;
                }
            }
            if v == 38 { t.fg = color; } else { t.bg = color; }
            i += used;
        }
        i++;
    }
}

fn osc_byte(p: Parser&, t: buffer::Terminal&, b: u8) {
    if b == 0x07 {
        osc_finish(p, t);
        p.state = State.Ground;
        return;
    }
    if p.osc_esc {
        if b == '\\' {
            osc_finish(p, t);
            p.state = State.Ground;
            return;
        }
        p.osc_esc = false;
    }
    if b == 0x1b {
        p.osc_esc = true;
        return;
    }
    if p.osc_len < 32767 {
        p.osc[p.osc_len] = b;
        p.osc_len += 1;
    }
}

// OSC 0/2 title, OSC 8 hyperlink, OSC 52 clipboard. Everything else is
// dropped; OSC 52 reads are not supported (a terminal should never let a
// program fetch the user's clipboard without a prompt).
fn osc_finish(p: Parser&, t: buffer::Terminal&) {
    if p.osc_len < 2 { return; }
    let code = p.osc[0];
    if (code == '0' || code == '2') && p.osc[1] == ';' {
        p.title.clear();
        var i = 2;
        while i < p.osc_len && p.title.len < 127 {
            p.title.push(p.osc[i]);
            i++;
        }
        p.title_changed = true;
        return;
    }
    if code == '8' && p.osc[1] == ';' {
        var sep = 2;
        while sep < p.osc_len && p.osc[sep] != ';' { sep++; }
        if sep >= p.osc_len { return; }
        buffer::set_link(t, p.osc[sep + 1..p.osc_len]);
        return;
    }
    if code == '5' && p.osc_len >= 3 && p.osc[1] == '2' &&
       p.osc[2] == ';' {
        var sep = 3;
        while sep < p.osc_len && p.osc[sep] != ';' { sep++; }
        if sep >= p.osc_len { return; }
        p.clipboard_primary = sep > 3 && p.osc[3] == 'p';
        if decode_osc52(p, sep + 1) && p.clipboard_len > 0 {
            let payload = p.osc[..p.clipboard_len];
            if p.clipboard_primary {
                pty::set_primary(payload);
            } else {
                gfx::set_clipboard(payload);
            }
        }
    }
}

fn b64_value(b: u8) -> i64 {
    if b >= 'A' && b <= 'Z' { return b - 'A'; }
    if b >= 'a' && b <= 'z' { return (b - 'a') as i64 + 26; }
    if b >= '0' && b <= '9' { return (b - '0') as i64 + 52; }
    if b == '+' { return 62; }
    if b == '/' { return 63; }
    return -1;
}

const CLIPBOARD_MAX: i64 = 16384;

fn decode_osc52(p: Parser&, start: i64) -> bool {
    p.clipboard_len = 0;
    var acc: i64 = 0;
    var bits: i64 = 0;
    var i = start;
    while i < p.osc_len {
        let b = p.osc[i];
        i++;
        if b == '=' { break; }
        if b == ' ' || b == '\n' || b == '\r' || b == '\t' { continue; }
        let v = b64_value(b);
        if v < 0 {
            p.clipboard_len = 0;
            return false;
        }
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            if p.clipboard_len >= CLIPBOARD_MAX {
                p.clipboard_len = 0;
                return false;
            }
            // Decoding in place: the write index stays behind the read index,
            // since four base64 bytes carry three decoded ones.
            p.osc[p.clipboard_len] = ((acc >> bits) & 255) as u8;
            p.clipboard_len += 1;
        }
    }
    return true;
}
