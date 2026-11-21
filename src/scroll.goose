// Viewport scrolling: sub-line positions, whole-line and page moves, and the
// touchpad momentum that carries a flick on after the fingers stop. Both the
// mouse and the keyboard drive it, so it lives apart from the window loop.
//
// Positions are in pixels from the bottom of the scrollback: 0 is the newest
// line, hist_count * line_height the oldest.

namespace scroll;

import std;
import gfx;
import .tab;

const WHEEL_LINES: f32 = 3.0;

// Wheel deltas are applied immediately; after a short quiet gap the last
// measured velocity coasts and decays. Keeping the gap avoids adding momentum
// while the fingers are still sending deltas.
const MOMENTUM_DELAY: f64 = 0.055;
const MOMENTUM_RESET: f64 = 0.18;
const MOMENTUM_DECAY: f64 = 6.0;
const MOMENTUM_MIN: f32 = 10.0;
const MOMENTUM_MAX: f32 = 5000.0;

var vel: f32 = 0.0;
var last_wheel: f64 = 0.0;

fn stop() {
    vel = 0.0;
    last_wheel = 0.0;
}

fn coasting(now: f64) -> bool {
    return vel != 0.0 && now - last_wheel >= MOMENTUM_DELAY;
}

fn pixels(t: tab::Tab&, ch: f32) -> f32 {
    return t.scroll * ch + t.scroll_frac;
}

fn set_pixels(t: tab::Tab&, px: f32, ch: f32) {
    if ch <= 0.0 { return; }
    let max_px = t.term.hist_count * ch;
    var p = px;
    if p < 0.0 { p = 0.0; }
    if p > max_px { p = max_px; }
    t.scroll = (p / ch) as i64;
    t.scroll_frac = p - t.scroll * ch;
    if t.scroll >= t.term.hist_count {
        t.scroll = t.term.hist_count;
        t.scroll_frac = 0.0;
    } else if t.scroll_frac < 0.001 {
        t.scroll_frac = 0.0;
    }
}

// One frame of coasting. Returns true when the view moved.
fn update(t: tab::Tab&, now: f64, dt: f64, ch: f32) -> bool {
    if vel == 0.0 { return false; }
    if t.term.alt_active {
        vel = 0.0;
        return false;
    }
    // Do not add motion while the fingers are still producing deltas.
    if now - last_wheel < MOMENTUM_DELAY { return false; }
    if dt <= 0.0 { return false; }

    let before = pixels(t, ch);
    set_pixels(t, before + vel * (dt as f32), ch);
    let after = pixels(t, ch);
    // Reaching either end stops the coast instead of pinning a useless
    // velocity against the boundary.
    if abs(after - before) < 0.001 {
        vel = 0.0;
        return false;
    }
    vel *= exp(-MOMENTUM_DECAY * dt) as f32;
    if abs(vel) < MOMENTUM_MIN { vel = 0.0; }
    return true;
}

// Keep a tab's viewport inside its scrollback after the buffer changed under
// it. The alternate screen owns its own scrolling, so it stays at the bottom.
fn clamp_tab(t: tab::Tab&, ch: f32) {
    if t.term.alt_active {
        stop();
        t.scroll = 0;
        t.scroll_frac = 0.0;
        return;
    }
    t.scroll = clamp(t.scroll, 0, t.term.hist_count);
    if t.scroll >= t.term.hist_count {
        t.scroll = t.term.hist_count;
        t.scroll_frac = 0.0;
        stop();
        return;
    }
    if t.scroll_frac < 0.0 || t.scroll_frac >= ch {
        t.scroll_frac = 0.0;
        stop();
    }
}

fn by_pixels(t: tab::Tab&, dy: f32, ch: f32) -> bool {
    if t.term.alt_active { return false; }
    set_pixels(t, pixels(t, ch) + dy, ch);
    return true;
}

fn by(t: tab::Tab&, lines: i64, ch: f32) -> bool {
    stop();
    return by_pixels(t, lines * ch, ch);
}

fn page(t: tab::Tab&, direction: i64, ch: f32) -> bool {
    return by(t, direction * max(t.term.rows - 1, 1), ch);
}

fn top(t: tab::Tab&) -> bool {
    if t.term.alt_active { return false; }
    stop();
    t.scroll = t.term.hist_count;
    t.scroll_frac = 0.0;
    return true;
}

fn bottom(t: tab::Tab&) -> bool {
    stop();
    t.scroll = 0;
    t.scroll_frac = 0.0;
    return true;
}

// A wheel event. SDL's sign as it arrives: positive is up, toward the
// scrollback. A desktop with natural scrolling already flips touchpad deltas
// before they get here, so flipping again here scrolled the wrong way.
fn wheel(t: tab::Tab&, d: f32, ch: f32) -> bool {
    if d == 0.0 || t.term.alt_active { return false; }
    let dy = d * WHEEL_LINES * ch;

    // Seed the coast from the rate of the wheel stream. The first event after
    // a long pause only scrolls normally; subsequent events build the velocity
    // used once the stream goes quiet.
    let now = gfx::time();
    let gap = now - last_wheel;
    if gap > 0.0 && gap <= MOMENTUM_RESET {
        let sample_dt = max(gap, 0.004);
        let inst = clamp(dy / (sample_dt as f32), -MOMENTUM_MAX, MOMENTUM_MAX);
        let same_dir = (inst > 0.0) == (vel > 0.0);
        if gap > MOMENTUM_DELAY || !same_dir || vel == 0.0 {
            vel = inst;
        } else if abs(inst) > abs(vel) {
            // Keep the peak speed of a flick rather than letting its final
            // low-delta event erase the momentum.
            vel = inst;
        } else {
            vel += (inst - vel) * 0.35;
        }
    } else {
        vel = 0.0;
    }
    last_wheel = now;
    return by_pixels(t, dy, ch);
}
