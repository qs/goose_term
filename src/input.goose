// Keyboard translation: gfx events to the byte sequences a VT100 terminal
// sends, and clipboard text to a bracketed or plain paste.

namespace input;

import std;
import gfx;

const ESC: u8 = 27;

fn push_text(out: u8[>..]&, cp: u32) {
    push_utf8(out, cp);
}

fn modifier(mods: i32) -> i64 {
    var m = 1;
    if (mods & gfx::MOD_SHIFT) != 0 { m += 1; }
    if (mods & gfx::MOD_ALT) != 0 { m += 2; }
    if (mods & gfx::MOD_CTRL) != 0 { m += 4; }
    m
}

fn arrow(out: u8[>..]&, final: u8, mods: i32) {
    let m = modifier(mods);
    out.push(ESC);
    out.push('[');
    if m == 1 {
        out.push(final);
    } else {
        out.push('1');
        out.push(';');
        format(out, m);
        out.push(final);
    }
}

fn home_end(out: u8[>..]&, final: u8, mods: i32) {
    let m = modifier(mods);
    out.push(ESC);
    out.push('[');
    if m > 1 {
        out.push('1');
        out.push(';');
        format(out, m);
    }
    out.push(final);
}

fn tilde(out: u8[>..]&, code: i64, mods: i32) {
    let m = modifier(mods);
    out.push(ESC);
    out.push('[');
    format(out, code);
    if m > 1 {
        out.push(';');
        format(out, m);
    }
    out.push('~');
}

fn function_key(out: u8[>..]&, n: i64) {
    out.push(ESC);
    if n <= 4 {
        out.push('O');
        out.push('P' + (n - 1) as u8);
        return;
    }
    var code = 0;
    if n == 5 { code = 15; }
    else if n == 6 { code = 17; }
    else if n == 7 { code = 18; }
    else if n == 8 { code = 19; }
    else if n == 9 { code = 20; }
    else if n == 10 { code = 21; }
    else if n == 11 { code = 23; }
    else if n == 12 { code = 24; }
    if code != 0 {
        out.push('[');
        format(out, code);
        out.push('~');
    }
}

// Translate one key event. False when the key is ordinary typing, which the
// EVENT_TEXT events already carry.
fn encode_key(out: u8[>..]&, scancode: i32, keycode: i32, mods: i32) -> bool {
    let name = gfx::key_name(scancode);
    let ctrl = (mods & gfx::MOD_CTRL) != 0;
    let alt = (mods & gfx::MOD_ALT) != 0;

    if name == "Up" { arrow(out, 'A', mods); return true; }
    if name == "Down" { arrow(out, 'B', mods); return true; }
    if name == "Right" { arrow(out, 'C', mods); return true; }
    if name == "Left" { arrow(out, 'D', mods); return true; }
    if name == "Home" { home_end(out, 'H', mods); return true; }
    if name == "End" { home_end(out, 'F', mods); return true; }
    if name == "Insert" { tilde(out, 2, mods); return true; }
    if name == "Delete" { tilde(out, 3, mods); return true; }
    if name == "PageUp" { tilde(out, 5, mods); return true; }
    if name == "PageDown" { tilde(out, 6, mods); return true; }
    if name == "Return" || name == "Enter" { out.push(13); return true; }
    if name == "Backspace" { out.push(127); return true; }
    if name == "Tab" {
        if (mods & gfx::MOD_SHIFT) != 0 {
            out.push(ESC);
            out.push('[');
            out.push('Z');
        } else {
            out.push(9);
        }
        return true;
    }
    if name == "Escape" { out.push(ESC); return true; }
    if name == "Space" && ctrl { out.push(0); return true; }

    var fnum = 0;
    if name.len == 2 && name[0] == 'F' && name[1] >= '1' && name[1] <= '9' {
        fnum = name[1] - '0';
    } else if name == "F10" { fnum = 10; }
    else if name == "F11" { fnum = 11; }
    else if name == "F12" { fnum = 12; }
    if fnum > 0 { function_key(out, fnum); return true; }

    if ctrl {
        var ch = -1;
        if keycode >= 64 && keycode <= 95 { ch = keycode - 64; }
        else if keycode >= 97 && keycode <= 122 { ch = keycode - 96; }
        else if keycode == 32 { ch = 0; }
        else if keycode == 63 { ch = 127; }
        if ch >= 0 {
            if alt { out.push(ESC); }
            out.push(ch as u8);
            return true;
        }
    }
    if alt && keycode > 0 {
        out.push(ESC);
        push_text(out, keycode as u32);
        return true;
    }
    return false;
}

// Mouse reporting. `button` is 0/1/2 for left/middle/right, or 64/65 for the
// wheel; `motion` adds the protocol's motion bit and `release` selects the
// release form. SGR (1006) is unambiguous for release; the legacy X10 form
// reports button 3 on release.
fn encode_mouse(out: u8[>..]&, button: i64, col: i64, row: i64, release: bool,
                motion: bool, mods: i32, sgr: bool, utf8: bool) {
    var b = button;
    if motion { b += 32; }
    var modbits: i64 = 0;
    if (mods & gfx::MOD_SHIFT) != 0 { modbits += 4; }
    if (mods & gfx::MOD_ALT) != 0 { modbits += 8; }
    if (mods & gfx::MOD_CTRL) != 0 { modbits += 16; }
    b += modbits;
    let x = max(col + 1, 1);
    let y = max(row + 1, 1);

    if sgr {
        out.push(ESC);
        out.push('[');
        out.push('<');
        format(out, b);
        out.push(';');
        format(out, x);
        out.push(';');
        format(out, y);
        if release { out.push('m'); } else { out.push('M'); }
        return;
    }

    out.push(ESC);
    out.push('[');
    out.push('M');
    if release { b = 3 + modbits; }
    out.push((32 + b) as u8);
    if utf8 {
        push_utf8(out, 32 + x);
        push_utf8(out, 32 + y);
    } else {
        out.push((32 + min(x, 223)) as u8);
        out.push((32 + min(y, 223)) as u8);
    }
}

fn focus(out: u8[>..]&, gained: bool) {
    out.push(ESC);
    out.push('[');
    if gained { out.push('I'); } else { out.push('O'); }
}

// Clipboard text as keystrokes. Newlines become carriage returns, and in
// bracketed paste mode the text is wrapped as the shell expects.
fn paste(out: u8[>..]&, text: const u8[:], bracketed: bool) {
    if bracketed {
        out.push(ESC); out.push('['); out.push('2'); out.push('0'); out.push('0'); out.push('~');
    }
    for b in text {
        if b == 10 { out.push(13); }
        else if b != 13 { out.push(b); }
    }
    if bracketed {
        out.push(ESC); out.push('['); out.push('2'); out.push('0'); out.push('1'); out.push('~');
    }
}
