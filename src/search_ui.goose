// The search bar: it edits the query and moves between hits, and tells main
// whether an event was its own. Anything it does not claim falls through to
// the terminal, so tabs, copy and quit keep working while the bar is open.

namespace search_ui;

import std;
import gfx;
import slice_pool;
import .buffer;
import .keys;
import .search;
import .tab;

fn recompute(s: search::State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&) {
    if s.query.len == 0 {
        s.found = false;
        return;
    }
    search::find_first(s, t, pool);
    search::reveal(t, s);
}

fn step(s: search::State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&, forward: bool) {
    if s.query.len == 0 {
        s.found = false;
        return;
    }
    if forward {
        search::next(s, t, pool);
    } else {
        search::prev(s, t, pool);
    }
    search::reveal(t, s);
}

// True when the event belonged to the bar.
fn handle(e: gfx::Event, s: search::State&, t: tab::Tab&, pool: slice_pool<buffer::Cell>&) -> bool {
    if e.kind == gfx::EVENT_TEXT {
        // Text under Ctrl/Cmd is a chord (Cmd+V and friends), not typing.
        if (e.mods & (gfx::MOD_CTRL | gfx::MOD_GUI)) != 0 { return false; }
        if e.codepoint < 32 || e.codepoint == 127 { return true; }
        search::add_text(s, e.codepoint);
        recompute(s, t, pool);
        return true;
    }
    if e.kind != gfx::EVENT_KEY || !e.down { return false; }

    let ctrl = (e.mods & gfx::MOD_CTRL) != 0;
    let shift = (e.mods & gfx::MOD_SHIFT) != 0;
    let gui = (e.mods & gfx::MOD_GUI) != 0;

    // The chord that opened the bar closes it too.
    if ((ctrl && shift) || gui) && e.scancode == keys::K_F {
        search::close(s);
        return true;
    }
    if e.scancode == keys::K_ESCAPE {
        search::close(s);
        return true;
    }
    if e.scancode == keys::K_RETURN {
        if !e.repeat { step(s, t, pool, !shift); }
        return true;
    }
    if e.scancode == keys::K_BACKSPACE {
        if ctrl || gui { search::clear(s); } else { search::backspace(s); }
        recompute(s, t, pool);
        return true;
    }
    if e.scancode == keys::K_DELETE {
        search::delete_forward(s);
        recompute(s, t, pool);
        return true;
    }
    if e.scancode == keys::K_LEFT { search::left(s); return true; }
    if e.scancode == keys::K_RIGHT { search::right(s); return true; }
    if e.scancode == keys::K_HOME { search::home(s); return true; }
    if e.scancode == keys::K_END { search::end(s); return true; }
    if e.scancode == keys::K_UP {
        if !e.repeat { step(s, t, pool, false); }
        return true;
    }
    if e.scancode == keys::K_DOWN {
        if !e.repeat { step(s, t, pool, true); }
        return true;
    }
    if ctrl && e.scancode == keys::K_U {
        search::clear(s);
        recompute(s, t, pool);
        return true;
    }
    return false;
}
