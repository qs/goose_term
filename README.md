# goose-term

A small, fast GPU terminal emulator written in [Goose](https://github.com/aardappel/goose). It uses the standard `gfx` and `ui` packages for the window, font atlas and drawing, and a thin C layer for the PTY and the few SDL hooks `gfx` does not expose.

It targets Linux (X11 or Wayland) and macOS (arm64 and x86_64), through SDL3.

## Build

The build produces an optimized release executable by default. It needs the
[Goose AOT compiler](https://github.com/aardappel/goose/releases) (the JIT
runner is not enough because the terminal links C), plus a C compiler and the
Linux development packages required to link an X11/Wayland application.

On Debian or Ubuntu, start with:

```bash
sudo apt install build-essential libc6-dev libx11-dev libxext-dev libxi-dev libxcb1-dev
```

On macOS the Xcode command line tools supply clang, and CMake comes from
Homebrew:

```bash
xcode-select --install
brew install cmake
```

Download and unpack the Goose release for your platform (Linux x64,
macOS arm64 or macOS x64), then add its directory to `PATH`. Goose keeps its
compiler cache outside this repository, under `~/.goose` by default.

```bash
./build.sh                 # -> build/goose-term
GOOSE=/path/to/goose ./build.sh
```

`build.sh` uses `goose` from `PATH`, or `./goose-bin` if present.

## Releases

Pushing an annotated `v*` tag builds and publishes a GitHub Release with one
archive and SHA-256 checksum per platform:

| Archive | Built on |
| :--- | :--- |
| `goose-term-linux-x86_64.tar.gz` | Ubuntu 22.04 |
| `goose-term-macos-arm64.tar.gz` | macOS 15, Apple silicon |
| `goose-term-macos-x86_64.tar.gz` | macOS 15, Intel |

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

The GitHub Actions workflow downloads the pinned Goose compiler release for
each platform and verifies its checksum before compiling the application. A
published archive contains the executable; the fonts are embedded at build
time.

To check a download, save the archive and its `.sha256` in one directory and
run:

```bash
sha256sum --check goose-term-linux-x86_64.tar.gz.sha256
```

macOS has `shasum` rather than `sha256sum`:

```bash
shasum -a 256 --check goose-term-macos-arm64.tar.gz.sha256
```

## Run

```bash
./build/goose-term
```

It starts your `$SHELL` (falling back to `/bin/sh`) in a new tab. Start more tabs with `Ctrl+Shift+T`; closing the last tab exits. On macOS the same shortcuts live on `Cmd`; see [Keys](#keys).

The window is borderless. Drag the empty part of the tab sidebar, or hold
`Cmd` (macOS) / `Super` (Linux) and drag anywhere, to move it; `F11` or
`Cmd+Enter` goes full-screen.

## Features

- **Tabs** in a wider vertical sidebar that auto-hides when only one is open. Double-clicking the empty part of the sidebar opens a new tab.
- **Window icon**: an embedded 128×128 prompt tile, set through SDL for the taskbar and the window switcher.
- **Scrollback** of up to 10,000 lines per tab, with viewport anchoring while output arrives. All tabs together stay under a fixed memory budget (~130 MB of cells), and the tab with the most history gives half of it back when they exceed it.
- **Smooth scrolling**: high-resolution touchpad/wheel deltas move the viewport in sub-line pixels instead of jumping by whole lines. After the input pauses, the viewport coasts with a short frame-rate-independent momentum decay. The deltas are used with the sign the platform reports, so a desktop with natural scrolling behaves as the desktop configured it.
- **Selection**: drag, kitty-style double-click word selection, triple-click for a line, and copy with `Ctrl+Shift+C` / `Ctrl+Insert`. Dragging past the top or bottom edge scrolls the view and keeps extending the selection.
- **Clipboard**: `Ctrl+Shift+V` / `Shift+Insert` paste with bracketed-paste support. Middle-click pastes the X11/Wayland PRIMARY selection. Pasted text is text: control characters and ESC are dropped, so a clipboard can inject neither escape sequences nor a fake end-of-paste marker. If a program stops reading its input, whatever the PTY could not take is counted on stderr rather than lost silently.
- **Alternate screen**: `CSI ? 1049 h/l` (also 47 and 1047). Full-screen programs such as vim, less and Claude get their own grid and restore the normal screen on exit.
- **Mouse reporting**: X10, 1000 (button), 1002 (drag), 1003 (any motion), 1005 (UTF-8 coordinates) and 1006 (SGR). Hold Shift to override reporting and select text locally.
- **Wheel in full-screen programs**: when a program on the alternate screen does not track the mouse (`less`, `man`, `vim` with the mouse off), the wheel is sent as arrow keys, so its own scrolling still works.
- **OSC 8 hyperlinks** are attached to cells. Ctrl+click (Cmd+click on macOS) a `http://`, `https://` or `mailto:` link to open it with the desktop handler.
- **OSC 52 clipboard writes** (`OSC 52 ; c ; base64`). Reads are intentionally not implemented.
- **Scrollback search** with `Ctrl+Shift+F`, case-insensitive, with next/previous and a highlighted hit.
- **Unicode** through JuliaMono as the primary face, with JetBrains Mono as a fallback. JuliaMono's full-height block elements and tighter line metrics keep Claude/quadrant art aligned without the empty seams a code face leaves.
- **Slim bar cursor** (one quad, no glyph redraw), cursor blink, focus tracking, full-screen toggle and font zoom.
- **Idle cost**: a frame with nothing to do blocks on the PTYs, so a quiet terminal wakes about 100 times a second instead of 250, and a streaming one is read the moment output lands.
- **IME**: the candidate window is placed at the text cursor. Composed text is committed to the shell; in-progress preedit text is not drawn in the grid.
- Truecolor SGR, 256-color, bold, dim, italic, underline and inverse.

## Keys

| Shortcut | Action |
| :--- | :--- |
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close active tab |
| `Ctrl+Shift+Tab` / `Ctrl+Shift+PageUp` / `Ctrl+Shift+[` | Previous tab |
| `Ctrl+Shift+PageDown` / `Ctrl+Shift+Right` / `Ctrl+Shift+]` | Next tab |
| `Ctrl+Shift+1..9` | Jump to tab |
| `Ctrl+Shift+C` / `Ctrl+Insert` | Copy selection |
| `Ctrl+Shift+V` / `Shift+Insert` | Paste clipboard |
| `PageUp` / `PageDown` | Scroll one page (forwarded to full-screen programs) |
| `Shift+PageUp` / `Shift+PageDown` | Scroll one page |
| `Ctrl+Shift+Up` / `Down` | Scroll one line |
| `Ctrl+Shift+Home` / `End` | Scroll to top / bottom |
| `F11` or `Ctrl+Shift+Enter` | Toggle full-screen |
| `Ctrl+Shift+Plus` / `Minus` | Font larger / smaller |
| `Ctrl+Shift+F` | Search scrollback |
| `Enter` / `Shift+Enter` in search | Next / previous hit |
| `Escape` in search | Close search |
| `Left` / `Right` / `Home` / `End` in search | Move the query caret |
| `Ctrl+U` in search | Clear the query |

On macOS, `Cmd` takes the place of `Ctrl+Shift` for the application shortcuts
in this table (`Cmd+T`, `Cmd+W`, `Cmd+C`, `Cmd+V`, `Cmd+F`, `Cmd+Enter`,
`Cmd+Plus` / `Cmd+Minus`, `Cmd+1..9`, `Cmd+Shift+[` / `]`); `Cmd+Q` quits and
`Ctrl+Cmd+F` also toggles full-screen. The terminal's own `Ctrl` combinations
still reach the shell.

## Layout

```text
src/
  main.goose       window loop, tabs, PTY pumping, clipboard glue
  keys.goose       the application's shortcut table
  scroll.goose     viewport positions, paging and momentum
  mouse.goose      drag, selection, links, wheel, mouse reporting
  buffer.goose     cells, grid, scrollback, alternate screen, links
  parser.goose     VT100/ANSI state machine, OSC 8/52
  tab.goose        per-tab PTY, terminal, selection
  input.goose      keyboard, paste and mouse-report encoding
  renderer.goose   font atlas, grid/sidebar/search drawing
  search.goose     scrollback matching and hit navigation
  search_ui.goose  the search bar's editing and navigation
  pty.goose        PTY and SDL helper bindings
  pty_helper.c     forkpty, non-blocking I/O, IME area, SDL hooks
assets/            JuliaMono primary + JetBrains Mono fallback, the window icon, licenses
```

## Limitations

- The window icon is set through SDL, which reaches X11 taskbars; Wayland takes it from a `.desktop` file, and an unsigned macOS binary from its bundle.
- OSC 52 reads are disabled by design; programs can only set the clipboard.
- Links are restricted to `http`, `https` and `mailto` before being handed to the desktop.
- CJK and emoji outside the baked ranges still fall back to `?`; adding a wide-glyph face is the next font step.
- Middle-click paste reads the X11/Wayland PRIMARY selection, which macOS does not have; there the calls are no-ops and `Cmd+V` is the paste path.
- The release binaries are not code-signed or notarized. A downloaded macOS build needs a right-click → Open, or `xattr -d com.apple.quarantine goose-term`, the first time.
- Momentum is disabled in the alternate screen, where full-screen apps own scrolling; the wheel there is sent as arrow keys unless the app tracks the mouse.
- Terminal graphics protocols (Sixel, Kitty images) and OSC 133 shell integration are not implemented.

## License

MIT, see [LICENSE](LICENSE). The bundled fonts keep their own terms: JuliaMono
and JetBrains Mono are under the SIL Open Font License 1.1, in
`assets/OFL-JuliaMono.txt` and `assets/OFL.txt`.
