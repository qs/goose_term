# goose-term

A small, fast GPU terminal emulator written in [Goose](https://github.com/aardappel/goose). It uses the standard `gfx` and `ui` packages for the window, font atlas and drawing, and a thin C layer for the PTY and the few SDL hooks `gfx` does not expose.

It targets Linux with X11 or Wayland through SDL3.

## Build

The build produces an optimized release executable by default. It needs the
[Goose AOT compiler](https://github.com/aardappel/goose/releases) (the JIT
runner is not enough because the terminal links C), plus a C compiler and the
Linux development packages required to link an X11/Wayland application.

On Debian or Ubuntu, start with:

```bash
sudo apt install build-essential libc6-dev libx11-dev libxext-dev libxi-dev libxcb1-dev
```

Download and unpack the Linux x64 Goose release, then add its directory to
`PATH`. Goose keeps its compiler cache outside this repository, under
`~/.goose` by default.

```bash
./build.sh                 # -> build/goose-term
GOOSE=/path/to/goose ./build.sh
```

`build.sh` uses `goose` from `PATH`, or `./goose-bin` if present.

## Releases

Pushing an annotated `v*` tag builds and publishes a GitHub Release with a
`goose-term-linux-x86_64.tar.gz` archive and its SHA-256 checksum. The release
is built on Ubuntu 22.04 and currently targets 64-bit Linux only.

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

The GitHub Actions workflow downloads the pinned Goose compiler release and
verifies its checksum before compiling the application. A published archive
contains the executable; the fonts are embedded at build time.

## Run

```bash
./build/goose-term
```

It starts your `$SHELL` (falling back to `/bin/sh`) in a new tab. Start more tabs with `Ctrl+Shift+T`; closing the last tab exits.

## Features

- **Tabs** in a wider vertical sidebar that auto-hides when only one is open.
- **Scrollback** of 10,000 lines per tab, with viewport anchoring while output arrives.
- **Smooth scrolling**: high-resolution touchpad/wheel deltas move the viewport in sub-line pixels instead of jumping by whole lines. After the input pauses, the viewport coasts with a short frame-rate-independent momentum decay. The wheel direction is inverted for natural touchpad use.
- **Selection**: drag, kitty-style double-click word selection, triple-click for a line, and copy with `Ctrl+Shift+C` / `Ctrl+Insert`.
- **Clipboard**: `Ctrl+Shift+V` / `Shift+Insert` paste with bracketed-paste support. Middle-click pastes the X11/Wayland PRIMARY selection.
- **Alternate screen**: `CSI ? 1049 h/l` (also 47 and 1047). Full-screen programs such as vim, less and Claude get their own grid and restore the normal screen on exit.
- **Mouse reporting**: X10, 1000 (button), 1002 (drag), 1003 (any motion), 1005 (UTF-8 coordinates) and 1006 (SGR). Hold Shift to override reporting and select text locally.
- **OSC 8 hyperlinks** are attached to cells. Ctrl+click a `http://`, `https://` or `mailto:` link to open it with the desktop handler.
- **OSC 52 clipboard writes** (`OSC 52 ; c ; base64`). Reads are intentionally not implemented.
- **Scrollback search** with `Ctrl+Shift+F`, case-insensitive, with next/previous and a highlighted hit.
- **Unicode** through JuliaMono as the primary face, with JetBrains Mono as a fallback. JuliaMono's full-height block elements and tighter line metrics keep Claude/quadrant art aligned without the empty seams a code face leaves.
- **Slim bar cursor** (one quad, no glyph redraw), cursor blink, focus tracking, full-screen toggle and font zoom.
- Truecolor SGR, 256-color, bold, dim, italic, underline and inverse.

## Keys

| Shortcut | Action |
| :--- | :--- |
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close active tab |
| `Ctrl+Shift+Tab` / `Ctrl+Shift+PageUp` | Previous tab |
| `Ctrl+Shift+PageDown` / `Ctrl+Shift+Right` | Next tab |
| `Ctrl+Shift+1..9` | Jump to tab |
| `Ctrl+Shift+C` / `Ctrl+Insert` | Copy selection |
| `Ctrl+Shift+V` / `Shift+Insert` | Paste clipboard |
| `Shift+PageUp` / `Shift+PageDown` | Scroll one page |
| `Ctrl+Shift+Up` / `Down` | Scroll one line |
| `Ctrl+Shift+Home` / `End` | Scroll to top / bottom |
| `F11` or `Ctrl+Shift+Enter` | Toggle full-screen |
| `Ctrl+Shift+Plus` / `Minus` | Font larger / smaller |
| `Ctrl+Shift+F` | Search scrollback |
| `Enter` / `Shift+Enter` in search | Next / previous hit |
| `Escape` in search | Close search |

## Layout

```text
src/
  main.goose       window loop, tabs, input dispatch, mouse, search UI
  buffer.goose     cells, grid, scrollback, alternate screen, links
  parser.goose     VT100/ANSI state machine, OSC 8/52
  tab.goose        per-tab PTY, terminal, selection
  input.goose      keyboard, paste and mouse-report encoding
  renderer.goose   font atlas, grid/sidebar/search drawing
  search.goose     scrollback matching and hit navigation
  pty.goose        PTY and SDL helper bindings
  pty_helper.c     forkpty, non-blocking I/O, SDL primary/URL hooks
assets/            JuliaMono primary + JetBrains Mono fallback and licenses
```

## Limitations

- OSC 52 reads are disabled by design; programs can only set the clipboard.
- Links are restricted to `http`, `https` and `mailto` before being handed to the desktop.
- CJK and emoji outside the baked ranges still fall back to `?`; adding a wide-glyph face is the next font step.
- Momentum is disabled in the alternate screen, where full-screen apps own scrolling.
- Terminal graphics protocols (Sixel, Kitty images) and OSC 133 shell integration are not implemented.
