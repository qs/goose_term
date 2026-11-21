// The application's keyboard shortcuts, in one table.
//
// Both chord sets the terminal claims — Ctrl+Shift on Linux and Cmd on macOS —
// resolve their key through `action` here, so the two lists cannot drift
// apart. Keys are SDL scancodes: a scancode names a physical key, so it does
// not move with the keyboard layout or with Shift, and its number is a stable
// part of SDL's ABI. `keycode` is the typed character ("!" for Shift+1), and
// the names `gfx::key_name` returns are SDL's spellings, which call Return
// "Return" and the bracket keys "[" and "]" — neither names a key reliably
// enough for a shortcut table.

namespace keys;

import std;
import gfx;

// SDL3 scancodes, from SDL_scancode.h.
const K_C: i32 = 6;
const K_F: i32 = 9;
const K_T: i32 = 23;
const K_U: i32 = 24;
const K_V: i32 = 25;
const K_W: i32 = 26;
const K_1: i32 = 30;         // the digits 1..9 run from here
const K_RETURN: i32 = 40;
const K_ESCAPE: i32 = 41;
const K_BACKSPACE: i32 = 42;
const K_TAB: i32 = 43;
const K_MINUS: i32 = 45;
const K_EQUALS: i32 = 46;
const K_LEFTBRACKET: i32 = 47;
const K_RIGHTBRACKET: i32 = 48;
const K_F11: i32 = 68;
const K_INSERT: i32 = 73;
const K_HOME: i32 = 74;
const K_PAGEUP: i32 = 75;
const K_DELETE: i32 = 76;
const K_END: i32 = 77;
const K_PAGEDOWN: i32 = 78;
const K_RIGHT: i32 = 79;
const K_LEFT: i32 = 80;
const K_DOWN: i32 = 81;
const K_UP: i32 = 82;
const K_KP_MINUS: i32 = 86;
const K_KP_PLUS: i32 = 87;

// What a shortcut asks the terminal to do. Which key asks for it lives only in
// `action`; the modifiers that make it a shortcut live in `handle_key`.
enum Action {
    None,
    NewTab,
    CloseTab,
    PrevTab,
    NextTab,
    Jump,
    Copy,
    Paste,
    Search,
    Fullscreen,
    ZoomIn,
    ZoomOut,
    ScrollUp,
    ScrollDown,
    ScrollTop,
    ScrollBottom,
}

// The digit a key event comes from, 0..8 for 1..9, or -1.
fn digit(e: gfx::Event) -> i64 {
    if e.scancode >= K_1 && e.scancode <= K_1 + 8 { return e.scancode - K_1; }
    return -1;
}

// The action a key stands for, with its argument (the tab index for Jump).
fn action(e: gfx::Event) -> Action, i64 {
    if e.scancode == K_T { return Action.NewTab, 0; }
    if e.scancode == K_W { return Action.CloseTab, 0; }
    if e.scancode == K_C { return Action.Copy, 0; }
    if e.scancode == K_V { return Action.Paste, 0; }
    if e.scancode == K_F { return Action.Search, 0; }
    if e.scancode == K_RETURN { return Action.Fullscreen, 0; }
    if e.scancode == K_PAGEUP || e.scancode == K_LEFTBRACKET || e.scancode == K_LEFT ||
       e.scancode == K_TAB {
        return Action.PrevTab, 0;
    }
    if e.scancode == K_PAGEDOWN || e.scancode == K_RIGHTBRACKET || e.scancode == K_RIGHT {
        return Action.NextTab, 0;
    }
    if e.scancode == K_UP { return Action.ScrollUp, 0; }
    if e.scancode == K_DOWN { return Action.ScrollDown, 0; }
    if e.scancode == K_HOME { return Action.ScrollTop, 0; }
    if e.scancode == K_END { return Action.ScrollBottom, 0; }
    if e.scancode == K_EQUALS || e.scancode == K_KP_PLUS { return Action.ZoomIn, 0; }
    if e.scancode == K_MINUS || e.scancode == K_KP_MINUS { return Action.ZoomOut, 0; }
    let d = digit(e);
    if d >= 0 { return Action.Jump, d; }
    return Action.None, 0;
}

// Held keys: the modifier mask for a mouse gesture. Unlike input::modifier
// this includes Command/Super, because the window drag needs to know about it.
fn held() -> i32 {
    var m: i32 = 0;
    if gfx::key_down("Left Shift") || gfx::key_down("Right Shift") { m = m | gfx::MOD_SHIFT; }
    if gfx::key_down("Left Ctrl") || gfx::key_down("Right Ctrl") { m = m | gfx::MOD_CTRL; }
    if gfx::key_down("Left Alt") || gfx::key_down("Right Alt") { m = m | gfx::MOD_ALT; }
    if gfx::key_down("Left GUI") || gfx::key_down("Right GUI") { m = m | gfx::MOD_GUI; }
    return m;
}

// AltGr composes a character rather than pressing Meta, and SDL reports it as
// its own modifier bit (KMOD_MODE); gfx does not name it, so it is spelled
// here. Text typed under it must reach the terminal.
const MOD_ALTR: i32 = 16384;

// Whether a text event belongs to a chord rather than to typed text.
fn text_is_chord(e: gfx::Event) -> bool {
    if (e.mods & MOD_ALTR) != 0 { return false; }
    return (e.mods & (gfx::MOD_CTRL | gfx::MOD_ALT)) != 0 ||
           (gfx::key_down("Left Ctrl") || gfx::key_down("Right Ctrl") ||
            gfx::key_down("Left Alt") || gfx::key_down("Right Alt"));
}
