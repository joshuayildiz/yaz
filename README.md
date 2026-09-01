# yaz

A text editor built for low latency, low resource usage, and high performance.

Native GPU rendering with proportional (variable-width) fonts, targeting Linux,
macOS, and Windows.

## Status

Early. Lines of text shaped by HarfBuzz and drawn from a glyph atlas FreeType
fills as glyphs are asked for: proportional, kerned, with a per-line layout cache
so a keystroke reshapes one line rather than the screen. The text comes out of a
gap buffer, there is a caret, and you can type or click to move it. Files are
opened by naming them on the command line or by picking them with cmd+P.

**cmd+S writes the file back** to where it came from. A file with no name — the
blank one `yaz` on its own opens — cannot be saved yet, and nothing asks on the
way out, so closing a window still throws away whatever its tabs are still
marked with.

Built and run on Linux, Windows and macOS, from a Linux or macOS host. Windows
binaries are cross-compiled.

## Requirements

- **Zig 0.16.0** or later. Earlier versions will not work: 0.15 replaced the
  `std.io` reader/writer types and 0.16 changed `main` to take
  `std.process.Init`.
- `curl`, to fetch the shader compiler on the first build.
- Targeting macOS additionally needs `git` and a C++ compiler. See
  [macOS](#macos).

SDL, FreeType and HarfBuzz are built from source by the Zig build system and
linked statically, so no system `-dev` packages are needed.

## The one library

The finder is built on **[fff](https://github.com/dmtrKovalenko/fff)**, which
indexes the directory yaz was run in, honours .gitignore, ranks paths against
what has been typed, and keeps the index current with a watcher of its own. It
is not bundled. Install it with:

```sh
yaz setup
```

It lands in `~/.config/yaz/lib/`, and that is the only place yaz looks. No
search path is consulted: yaz loads what it installed and checked, so another
copy elsewhere cannot quietly change what the finder does.

The version is **pinned and checksummed**. `setup` refuses to install bytes that
do not hash to the SHA-256 recorded in `src/tools.zig`, taken from the `.sha256`
published beside the release — the same rule `vendor/setup-macos-sdk.sh` applies
to the macOS SDK, for the same reason: a downloaded library is code about to be
run.

`yaz setup` is the only thing in yaz that touches the network, and it does so
because it was asked to. It is idempotent, and skips a library that already
loads.

**Nothing else runs until it is there.** On startup yaz opens the library and
resolves every symbol it calls; if that fails, the window shows what is missing
and where it looked, and no file on the command line is even read — a bad path
would otherwise report the wrong problem first.

It is loaded with `std.DynLib` rather than linked, so it is not part of the
build: no Rust toolchain, no rpath, nothing for a cross-compile to arrange.
This replaced ripgrep and fzf, which were two binaries yaz spawned as
processes — `rg --files` on every cmd+P and `fzf --filter` on every keystroke,
with the whole listing piped through it each time.

Spawning rather than checking the file exists is deliberate: a truncated
download or a binary for the wrong architecture is present and executable, and
only running it says otherwise. It costs about 11ms of startup, which
[OPTIMIZATIONS.md](OPTIMIZATIONS.md) §12 measures and accounts for.

The check happens once. Installing the tools while that window is up means
starting yaz again.

## Build and run

```sh
zig build run
zig build test
```

The first build downloads the shader compiler: an 8MB archive, 28MB unpacked.
Later builds skip it. Targeting macOS costs more the first time; see
[macOS](#macos).

## Opening a file

```sh
yaz               # an empty document
yaz notes.md      # notes.md, with the caret at the top
yaz new.md        # new.md does not exist: an empty document under that name
yaz a.md b.md     # both, in equal columns
```

Any number of paths, in equal columns left to right in the order named; the
window takes its title from the first. A **tab bar** runs along the top with one
tab per file open in the window — the ones named here and the ones picked with
cmd+P.

**Pressing a tab shows that file and nothing else**, and **cmd+1** to **cmd+9**
do the same for the first nine of them — **alt+1** to **alt+9** off macOS, which
is what the tab strip of every other window on those machines answers to.
Choosing one of something is choosing it instead of the rest, so the other
columns go back to being open but not on screen — nothing is closed.

A tab says two things at once, because with the window split they have different
answers. **Its ground says whether the file is on screen**: lifted out of the
strip for a file in a column, recessed into it for one that is only open.
**Its name's colour says whether it has the keyboard**: black for the one being
typed into, grey for the rest.

**cmd+alt+1** to **cmd+alt+9** put that file beside what is already split, or
take it away again when it is already there — **shift+alt+1** to **shift+alt+9**
off macOS. This is the one binding that adds a column rather than replacing what
is there. Taking one away is not closing it: the file stays open with its tab
and its caret where you left it, so putting it back costs nothing and it lands
where it was, since the columns follow the bar's order. The last column stays —
something has to be there to type into.

*(The digits are the one family of bindings that is not the same on every
platform. macOS cannot use shift for the second of them — shift+cmd+3 and
shift+cmd+4 are the system's screenshots and never reach an application — so it
adds alt instead. Everywhere else alt is already the first of them, and shift is
free. Ctrl says nothing about a digit off macOS: with alt meaning a tab, ctrl+1
and ctrl+alt+1 are chords yaz has no answer for. Every other binding is still
cmd on macOS and ctrl elsewhere, either accepted on any platform.)*

**cmd+W** closes the file the focused column is showing: its tab goes, the file
goes out of memory, and its column goes with it, so there is one less to split.
The last column stays and falls back to the first file nothing else is showing —
or to an empty file when there is none, which is where a window with no file
named starts. It closes what that column has, so a file sitting in another column
is reached with the digit binding or a press before it can be closed.

**With nothing left on the bar, cmd+W closes the window.** That is also how a
window that was never given a file ends, so `yaz` on its own is not a thing you
have to reach for the mouse to be rid of.

**Nothing asks on the way out**, so closing a file with a mark on its tab throws
the edit away — and the last cmd+W throws away every file still open. cmd+S
first is the whole of the answer to that for now.

A tab carries a **mark to the left of its name when the file has been changed and
not saved**. A save clears it, and a save that failed does not — which is half of
how a write that could not happen is reported, the other half being a line on
stderr. The mark's room is reserved whether it is drawn or not, so typing
into a file does not shift the bar along, and again on the other side of the name
so the name sits in the middle of its tab rather than hard against one edge. The
mark stays on a file that is open behind another, which is what makes an
unsaved edit visible rather than hidden — see [FIXME.md](FIXME.md).

`assets/sample.txt` is there to be opened — six lines exercising ligatures, a
combining mark, `.notdef` and proportional advances.

Naming a file that does not exist is how a new file begins, so that is not an
error. A directory, an unreadable file, one past 1MB, or one that is not UTF-8
each say which and stop, because an empty window otherwise looks exactly like an
empty file.

```
$ yaz war-and-peace.txt
error: war-and-peace.txt is larger than the 1MB yaz will open, because layout
       draws every line rather than the ones on screen

$ yaz latin1.txt
error: latin1.txt is not UTF-8: the byte at offset 4102 does not begin or
       continue a character
```

The size limit is not about reading, and no longer about drawing either — see
[the layout cache](#the-layout-cache). What is left is that the cache holds a
64-byte entry per line of the document however little is on screen, and the line
index behind it is the same shape.

UTF-8 is refused rather than drawn because only one layer would complain.
HarfBuzz substitutes a replacement character and carries on, so bad bytes would
merely look wrong — but stepping the caret back walks continuation bytes until
it finds one that is not, so backspace over stray bytes deletes however many
happen to be adjacent.

**CRLF becomes LF as the file is read**, so a file written on Windows does not
show a `.notdef` box at the end of every line. Only `\n` starts a line, so the
bytes in memory stop matching the file exactly — and **the file remembers what it
came in as**, so a save puts the returns back. Opening a file written on Windows
and saving it does not rewrite every line of it.

## Finding a file

**cmd+P** (ctrl+P elsewhere; either works on any platform) opens a finder over
whatever is on screen. Type to narrow, up and down to move the selection, return
to open, escape to close.

**Nothing is offered until something is typed.** A list of every file in the
repository is not an answer to a question nobody has asked yet, and drawing one
would be a screenful of shaping done on the way to being replaced by the first
keystroke. Until then the panel is one box: the line you are typing, and how many
files there are to search.

The panel hangs a short way from the top of the window, and the input and the
list are **two separate surfaces** with a gap between them. Neither dims what is
behind it. Each is opaque with a hairline edge and asks for exactly the height it
needs — one line of text for the input, one row per match for the list — so the
list is absent rather than empty when nothing has been typed, and the panel is
never taller than what is in it. The row return would open is tinted across the
full width of the list.

It does no listing and no matching of its own, and nothing is spawned to do it
either. The index is built when the window opens and kept current by a watcher,
so cmd+P has nothing to read and a keystroke is a call into memory: **0.02ms on
this repository and 1.8ms on a tree of 19,542 files**, measured on an M2.

Matching is typo-resistant, which is worth more here than an exact prefix:
`txtvw` finds `text_view.zig`, `opnfl` finds `open_file.zig`.

A file created while yaz is running is in the index without a restart. That is
the watcher, and it is the reason for the whole arrangement.

Returning on a file that is **already open focuses that view** rather than
opening a second copy of it. Otherwise the focused view is pointed at the new
file, and the one it was showing is **kept rather than thrown away** — its
buffer, its line index, every line already shaped, and where the caret and the
scroll were.

So a file is read from disk once per session. Coming back to one is 95µs and
reshapes nothing, against 1.2ms and a full re-read the first time. Nothing is
written to disk; it all lasts as long as the window.

## Platform notes

The GPU backend is **Vulkan** on Linux and Windows, and **Metal** on macOS.
The program logs which one it got, and on which device:

```
info: gpu backend: vulkan on NVIDIA GeForce RTX 3090
```

Read that line before trusting any performance measurement.

Windows runs Vulkan rather than Direct3D 12 deliberately. D3D12 wants shaders as
DXIL, and the only compiler that emits DXIL is DirectXShaderCompiler: LLVM-based,
a 500MB dependency, with no macOS build. Choosing GLSL and glslang instead keeps
the toolchain at 28MB and portable on every host, at the cost of depending on the
GPU vendor's Vulkan driver rather than on an API guaranteed present on Windows.

### Display density

**Inside the program there is one unit: the device pixel.** Window coordinates
exist only at SDL's boundary and are converted the moment they cross it. There
are exactly two places they get in — the size passed to `SDL_CreateWindow`, which
nothing downstream reads, and the coordinates on a mouse event, multiplied by
`SDL_GetWindowPixelDensity` before hit-testing. Nothing comes back out: the size
`SDL_WaitAndAcquireGPUSwapchainTexture` reports is already pixels.

The window is created with `SDL_WINDOW_HIGH_PIXEL_DENSITY`. Without it the
platform hands back a back buffer at the window's size in window coordinates and
scales the finished frame up — on a Retina Mac, a 1024×768 swapchain stretched
onto 2048×1536 physical pixels, undoing the whole point of rasterizing glyphs at
four subpixel offsets. The pipeline was correct and the frame was resampled after
it. SDL's documentation mentions `NSHighResolutionCapable` in an Info.plist;
yaz is a bare executable with no bundle, and needs it on neither count — measured
on an M2 as a density of 2.0 with the flag and 1.0 without.

How large to draw comes from `SDL_GetWindowDisplayScale`, not the density. They
agree on macOS and differ where it counts: Windows at 150% on an ordinary panel
reports a density of 1.0 and a scale of 1.5, so sizing by density there would
ignore the setting. `config.font_size` is nominal and the scale turns it into
pixels, so one value is the same size to look at on every display.

The scale is read at the top of each redraw and compared, rather than listened
for. Three window events can imply it changed, and one of the ways it changes —
dragging to another display — happens inside the platform's modal loop, where
only the resize watch runs. When it does change the atlas is rebuilt in place:
the texture survives, and what is given up is the packing state, the metrics and
every shaped line.

### Scrolling

The wheel moves **the view under the pointer**. Pointing at something and turning
the wheel is a whole instruction by itself, so it does not wait on focus and will
not start to once focus exists. A view being dragged by its scrollbar keeps the
pointer wherever it wanders, so a drag that leaves the view still scrolls it.

An edit brings the caret back to the **middle** of the
window if it had scrolled out of sight, rather than nudging it to whichever edge
it went behind — something typed where the view had wandered off wants what is
around it. A click reads the view where it is and leaves it alone.

The far end of the scroll is where the **last line reaches the top** of the
window, not the bottom, so the end of a file is not somewhere the view cannot
follow you to. A document shorter than the window scrolls by the same rule.

**The offset is a whole number of pixels.** Baselines are rounded per line and
`line_height` is fractional, so they already round unevenly — 15, 15, 16, 15 —
and that pattern only survives if the offset shifts every line by the same whole
amount. A fractional offset re-rounds each line on its own and the text shimmers
as it moves. What a gesture leaves over waits in `pending` for the next event
rather than rounding away, so a slow drag still moves.

What a wheel delta counts is **the platform's business**. macOS reports a precise
device in tenths of a point, so ten times it is how far the finger moved and a
trackpad tracks it exactly. Everywhere else the field is detents, and a detent is
**three lines** — what Windows scrolls by default, and what the desktops
elsewhere settled on.

Reading detents as points was ten pixels a notch on Windows: two thirds of a line
at every display scale, against the three lines every other window there moves.
Only the point path wants the display density, since a line is measured in pixels
already. A Windows precision touchpad sends a fraction of a detent and gets that
fraction of the lines, so it stays as smooth as a trackpad.

A notched mouse on macOS is still short in the same way — SDL floors its delta to
whole lines there — but nothing in the event says which device sent it, and
guessing would cost the trackpad its 1:1.

Momentum is macOS's own. SDL disables it by default, and
`SDL_HINT_MAC_SCROLL_MOMENTUM` — set before `SDL_Init` — turns it back on, so a
flick keeps scrolling with the system's curve and the system's settings. It costs
nothing when nothing is moving: momentum is more wheel events, and they stop
arriving when it stops, so the loop goes back to blocking. There is no animation
timer here and there does not need to be one.

### The scrollbar

A thumb down the left edge, always drawn, with the text starting after it — the
margin in `main.zig` is measured from the bar rather than from the window.

The track stands for **the document and nothing else**, so the thumb is the
window's share of it and sits where the window sits. Scrolling past the last line
therefore carries the thumb below the track, where it is clipped: counting that
empty space as something to scroll through would shrink the thumb to pay for
space that holds nothing. It stops shrinking at a minimum, or a long document
would take it below anything there is to catch hold of.

It is drawn by the pipeline that samples nothing; see [Drawing](#drawing) for why
it cannot come from the atlas.

**Dragging it scrolls.** The whole left gutter takes hold, not just the thumb's
eight points — that is a small thing to ask anyone to hit — and a press on the
track rather than the thumb takes hold of its middle, so the thumb jumps to the
pointer and carries on from there. The scrollbar is asked before the text, so a
press on it moves the view rather than the caret.

A drag that wanders out of the window keeps arriving without anything being done
about it. SDL captures the mouse on its own while a button is held, on the three
backends that implement capture at all — Cocoa, Windows and X11 — and Wayland
delivers it anyway through the compositor's implicit pointer grab. Calling
`SDL_CaptureMouse` here would be redundant on the first three and unsupported on
the fourth.

This is the one thing that looks at mouse motion. The loop ignores it otherwise,
which is what [OPTIMIZATIONS.md](OPTIMIZATIONS.md) §2 measures; motion is read
only while the pointer is holding the thumb, so an idle sweep across the window
still costs nothing.

### Redrawing

The render loop blocks in `SDL_WaitEvent` and draws only when something has
changed what is on screen. Waking up is not a reason to draw. Events already
queued when the loop wakes are folded into one frame, and a resize draws from an
event watch, because the platform's own modal loop will not hand control back
until the drag ends.

Redrawing during the drag is only half of it on macOS. A `CAMetalLayer` keeps
`CALayer`'s default `kCAGravityResize`, so until the next frame arrives the
compositor stretches the last one over the new bounds — on proportional text,
that reads as the glyphs changing width. It is set to `kCAGravityTopLeft`
instead.

That leaves a strip with nothing in it, which has to be some colour until a
redraw fills it. A `CALayer`'s background is unset and SDL marks the layer
opaque, so it composites as black: against a light theme, a dark edge trailing
the drag. The layer is given `config.background` instead. Measured by growing the
window with redraws suspended, the strip is 100% black without it and 100% white
with it.

SDL sets neither property and will not hand over the view it made, so the layer
is reached through the two window properties that say where it is
(`SDL.window.cocoa.window` and `SDL.window.cocoa.metal_view_tag`) and four
Objective-C messages, in `sdl.zig`.

The reasoning, the measurements, and what to re-check when porting are in
[OPTIMIZATIONS.md](OPTIMIZATIONS.md). Known problems not yet acted on are in
[FIXME.md](FIXME.md).

### Developing under WSL

WSL has no Vulkan ICD for the GPU — Ubuntu does not ship Mesa's `dzn`
(Vulkan-over-D3D12) driver, so a Linux build under WSL falls back to
**llvmpipe**, a software rasterizer:

```
info: gpu backend: vulkan on llvmpipe (LLVM 21.1.8, 256 bits)
```

It renders correctly and is fine for correctness work, but **no latency or
throughput number from it means anything.**

For real hardware, cross-compile to Windows and run the executable directly
from the WSL shell:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
./zig-out/bin/yaz.exe
```

### macOS

Cross-compiles from Linux, and the resulting binary has been run on Apple
Silicon. Zig applies the ad-hoc code signature that arm64 macOS requires, and
every dynamic dependency is a system framework, so nothing needs shipping
alongside it:

```sh
zig build -Dtarget=aarch64-macos    # or x86_64-macos for an Intel Mac
```

Two things cost extra on the first macOS build. The shader toolchain grows a
Metal translator, which is built from source and adds about 20MB, and SDL needs
a macOS SDK to resolve the frameworks it links
against — Zig ships none. `vendor/setup-macos-sdk.sh` fetches one, verifies its
checksum, and unpacks it into `vendor/macos-sdk`: about 80MB compressed,
expanding to roughly 1.8GB. It is never committed, and no other target fetches
it.

On a Mac none of that SDK machinery runs — Zig and SDL find the system SDK
themselves. Building on macOS is exercised; so is cross-compiling to it.

**cmd+W has to be taken back off the menu bar.** With no nib to load, SDL builds
a default menu bar whose Window menu binds Close to it. SDL still delivers the
key, so the tab closed *and* the window did — `sdl.unbindCloseShortcut` clears
the item's key equivalent after `SDL_Init`, which leaves it working from the menu
and stops it holding the shortcut. cmd+Q, cmd+M and cmd+F are on that menu too;
only the ones yaz binds have to be freed.

Apple's SDK is not ours to redistribute, and its licence contemplates use on
Apple hardware. It is downloaded at build time from a third-party mirror rather
than vendored, so nothing of Apple's enters the repository.

## Fonts

One font ships inside the binary: `assets/DejaVuSans.ttf`, embedded with
`@embedFile` and rasterized by FreeType. There is no system font discovery and
there is not meant to be — every platform renders the same pixels from the same
bytes, which makes rendering bugs reproducible.

The cost is 759KB of binary, most of which subsetting would recover if it ever
matters.

DejaVu Sans is under the Bitstream Vera licence, which permits redistribution;
see `assets/DejaVuSans.LICENSE`.

Proportional, not monospace — that choice is what makes shaping and a per-line
layout cache necessary rather than optional, and it is the constraint the text
pipeline is designed around.

### Shaping

Text becomes glyphs through HarfBuzz, not through a loop over characters. With a
proportional font that is not an optimization, it is the only correct way to get
a pen position: advances differ per character, and kerning depends on which
characters are adjacent. `AV` at 32px is 41.73px wide; `A` and `V` measured
alone sum to 43.78px, and nothing but kerning accounts for the 2.05px.

That pair comes from **GPOS**, which HarfBuzz prefers over the legacy `kern`
table. This font carries both with the same -131 units, so this pair would have
come out right either way; the general case will not, because GPOS kerning is
contextual and cannot be reduced to a table of pairs. That is why shaping is a
library and not a lookup.

HarfBuzz reads the font tables directly rather than going through `hb-ft`, which
would report advances the way FreeType does — rounded to whole pixels once
hinting is on. That would put every pen position on a whole pixel and the
subpixel atlas below would only ever be asked for one of its four variants.
Reading the tables keeps `A` at 21.890625px rather than 22.

Shaping is also what makes contextual glyphs appear at all. `fi` is a single
glyph in DejaVu Sans, `ffi` is another, and `e` followed by a combining acute
composes into the same glyph as a precomposed `é`. None of those is what any
character maps to; they exist only because `liga` and `ccmp` substituted them
in.

### Direction

**yaz is left-to-right, strictly.** Not left-to-right until someone reports it —
left-to-right by decision, the same way there is no plugin system. The shaper
says so outright rather than working it out per line:

```zig
hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
hb_buffer_set_script(buffer, HB_SCRIPT_LATIN);
hb_buffer_set_language(buffer, hb_language_from_string("en", -1));
```

Right-to-left text is therefore not merely unsupported: it comes out wrong and
says nothing about it. Arabic joining forms will even be correct, since `init`,
`medi` and `fina` are substitutions and have nothing to do with direction — and
then they are set down left to right, backwards. There is no UAX #9 bidi pass and
there is not meant to be one.

The language is stated rather than guessed because
`hb_buffer_guess_segment_properties` takes it from the system locale, and the
point of embedding the font is that every machine draws the same pixels.

The script tag is a shortcut, but a measured one: `ГА` and `ΑΤ` shape to identical
advances under `latn` and under their own tags, and the scripts where it would
change the outcome are not in DejaVu Sans anyway — Devanagari and Thai both come
back as `.notdef`. It becomes a real question if the font changes.

### The atlas

The atlas starts empty and fills as glyphs are asked for, which is the only
arrangement that works once text is shaped. A glyph like `fi` is reachable from
no character, so no walk over characters would ever rasterize it; only laying
out real text can say what exists. A miss rasterizes all four subpixel variants
and queues them, and the queue is uploaded in one copy pass before the frame's
render pass opens. Steady-state redraws upload nothing.

Entries are keyed by **`(glyph id, subpixel offset)`** — glyph ids, because that
is what shaping answers in, and characters are not the same numbering.
Proportional advances put glyph origins on fractional pixels, so each glyph is
rasterized at four horizontal offsets — quarter, half, three-quarter, whole — and
the pen's fractional part chooses between them. The quad itself always lands on
whole pixels; only the coverage inside it shifts. Sampling is `NEAREST`, because
a quad is sized to its source rectangle and every sample lands on a texel centre,
so interpolation has nothing left to do but soften what it touches.

Four offsets rather than more: the atlas grows linearly in that number, and past
a quarter of a pixel the difference stops being visible.

The texture is single-channel, so it costs its area in bytes: 1024×1024 and a
megabyte, except on macOS, where every Mac is Retina, glyphs are rasterized at
twice the size for four times the area, and 2048×2048 keeps the same ceiling.
Chosen from the target at build time rather than the display at runtime.

At the density each is sized for, the 46 distinct glyphs of `assets/sample.txt`
occupy 82 rows, putting the ceiling near 500 — a CJK document reaches that long
before a Latin one. The ceiling follows density rather than platform, though, so
Windows on a 4K panel at 200% gets the smaller texture; see
[FIXME.md](FIXME.md).

Nothing is ever evicted, and **running out is fatal**: it panics, naming the
glyph, its size, and how many glyphs were already in.

```
panic: glyph atlas is full: no room for glyph 28 at 17x23 in 256x256, 41 glyphs in
```

Crashing beats carrying on without the glyph, which would read as a renderer bug
rather than a full atlas. A TODO at that point names the two ways out.

### Glyphs that are not there

A character the font has no glyph for draws as **`.notdef`** — glyph zero, which
every TrueType font defines for this. No code produces it: shaping hands back
glyph zero and the atlas rasterizes it like any other.

Both ways a glyph can fail to *reach* the atlas — no room, and FreeType refusing
to rasterize it — panic instead. The font is compiled in, so a glyph it will not
rasterize is a broken build rather than bad input.

### The layout cache

Shaping is the expensive half of turning a line into pixels, and it depends on
**the line's bytes and nothing else** — not on where the line sits. So each
line's sprites are shaped once and kept **on the open file**, in coordinates of
the line's own: x from where the line starts, y from its baseline. Placing them
is then an add.

That is what makes the cache survive an ordinary edit. A newline at the top of
the file moves every line below it down a row without moving anything within
them — the same shaped lines at a different baseline. Keyed by screen position,
that edit would have invalidated the whole document.

Two things follow. The origin has to be a whole number of pixels or the
translation would change which subpixel variant each glyph points at, which
`draw` asserts. And each line's baseline is rounded once for the line rather
than per glyph, which is the same answer for anything without a fractional
vertical offset — everything in this font.

Only the lines that intersect the window are placed, and a line outside it is not
shaped either — which is where the cost of opening a long file went. `draw`
takes the window's pixel height and `visibleLines` turns it into a range of line
indices; the existing `if (!entry.shaped)` does the rest. The caret is the exception: its
line is shaped and its quad built even when it is outside the range, because the
renderer draws one unconditionally. The numbers are in
[OPTIMIZATIONS.md](OPTIMIZATIONS.md).

Invalidation is not a search. `Buffer.insert` and `Buffer.delete` already work
out which line an edit landed in and how many it created or destroyed, because
they have to patch the line index, so they return it as an `Edit` and the cache
gets the same splice. The buffer never learns that shaping exists; the atlas
never learns that an open file does.

Both live inside `OpenFile`, so an edit and its splice are one call — the only
real way to keep two structures indexed the same way from drifting apart.

Measured on a synthetic Latin document, ReleaseFast, native x86-64. This is all
CPU work — HarfBuzz and FreeType — so no GPU enters into it:

| lines | glyphs | before, every redraw | after, one keystroke | after, nothing changed |
| ---: | ---: | ---: | ---: | ---: |
| 20 | 1,125 | 55 µs | 4 µs | 1.1 µs |
| 200 | 11,230 | 686 µs | 14 µs | 10 µs |
| 2,000 | 112,297 | 7.0 ms | 130 µs | 120 µs |

A screenful is 14× cheaper per keystroke and 50× cheaper per redraw. The first
frame is 7–20% *slower*, since a cold line is now shaped into its own array and
then copied into the frame's — the one case the cache cannot help and does have
to pay for.

What remains is that copy: at 2,000 lines it is essentially all of the 120 µs,
about a nanosecond a glyph. It was also work spent on lines nobody could see,
since the window holds twenty of them — these numbers were taken before only the
visible ones were placed, which the cache is what made possible and which has its
own measurements in [OPTIMIZATIONS.md](OPTIMIZATIONS.md) 11.

The cost is memory: 24 bytes a glyph, so 37KB for a screenful and 3.7MB for a
2,000-line document. Nothing is evicted, for the same reason nothing is evicted
from the atlas — and the same day will fix both.

### Drawing

Every component draws into one `Painter`. A quad goes in under a **key** — a
layer, a pipeline and a colour — and `present` sorts the runs by that key and
issues one call per distinct one, so quads wanting the same thing end up in one
call however many components produced them. A screenful is nine calls — three
for a column, six for the bar — and sixteen with the finder over it. It is still
nine with a dozen columns, since they share their colours.

**The layer is what makes the sort safe.** These quads are alpha blended, so
reordering them is only correct where they do not overlap, and the layer states
that rule rather than assuming it: *within a layer, nothing overlaps.* Glyphs are
0, the caret 1, the scrollbar 2.

A call covers a contiguous span of instances, so the runs are staged in sorted
order — one `memcpy` per run into the transfer buffer, each left saying where it
landed — instead of the whole array in one go.

A component may not draw outside the rect it was given: `Painter.clipTo` trims
each quad to that rect and drops what falls entirely outside, so a long line
stops at the edge of the room its view was given, whatever is beside it. That is
done on
the CPU rather than with `SDL_SetGPUScissor` because a scissor is per-call state,
and calls here deliberately merge quads from several components — scissoring
would put the rect in the key and split those calls back apart. It is exact: a
`Sprite` carries one size for both the quad and the region it samples, so moving
an edge moves both together.

The vertex shader builds each quad's four corners from `gl_VertexIndex` and reads
everything that differs between glyphs — where it lands, where to sample it, how
big it is — out of a storage buffer indexed by `gl_InstanceIndex`. There is no
vertex buffer, and nothing is sent per glyph.

**There are two pipelines**, and they differ by their fragment shader alone —
same vertex shader, same storage buffer, same blend, same target. One samples the
atlas; the other samples nothing and writes a flat colour.

That second one exists because a `Sprite` carries **one size for both the quad
and the region it samples**, so a quad drawn from the atlas can be no larger than
what it points at. That is fine for a caret, which is a line tall by
construction, and impossible for a scrollbar, which is as tall as the window. A
pipeline that samples nothing has no source rectangle to outgrow.

The selection band, the caret and the scrollbar share that pipeline and take a
call each only because they are three colours. The alternative is a colour on
every sprite — four more floats uploaded per glyph per frame to repeat one value.

The vertex uniform holds what the whole frame shares, the viewport and the atlas
size. The fragment stage has one of its own for the colour, because the atlas
stores coverage rather than colour: a glyph's bitmap says how much of each pixel
is ink, and nothing about what ink is. That colour, the caret's and the
background are the theme, and all three live in `config.zig`.

Neither shader knows what a selection, a caret or a scrollbar is; they are quads
with a colour, and the colour is the only thing the second pipeline is told.

The sprite array is copied to the GPU exactly as `glyph_atlas.zig` built it, so
the Zig struct and the one declared in the shader have to agree byte for byte.
std430 gives three `vec2` a stride of 24, which is what the Zig `extern struct`
lays out; a test asserts the size and the field offsets, because nothing else
would notice the day they stop matching.

The GPU buffer and the staging buffer behind it are created once and grown by
doubling, never per frame. A redraw maps the staging buffer, writes the frame's
sprites into it, and copies them across in a copy pass before the swapchain is
acquired — work that does not need a frame handed back first, so it is done
before the wait rather than after it.

## The open file

Text lives in a **gap buffer**: one contiguous allocation with a hole in it,
kept wherever the last edit happened. It sits in `open_file.zig`, underneath
everything else the file carries.

```
The quick[                    ]brown fox
^ text    ^ gap               ^ text
```

Inserting writes into the hole and shrinks it. Deleting grows the hole over the
bytes next to it — they stay where they are and stop being part of the document.
Both are a write and a bounds change: constant time, no allocation, nothing
shifted.

Editing somewhere else moves the hole there first: one `memmove` of the text in
between, and the only operation here that is not constant time. That is the bet —
editing is local, so the distance is usually a few characters, and a jump across
the whole file is a single pass at memory bandwidth rather than a data structure
to maintain.

A rope or a piece table wins past roughly 100MB where that `memmove` starts to
dominate, and below it loses on every operation that matters, paying with pointer
chasing, per-node headers and cache misses. Huge files are out of scope. The
interface — `insert`, `delete`, `lineSlice`, `byteLen` — says nothing about
storage, so the judgement can be revisited without the renderer noticing.

### The line index

Alongside it is a flat array of byte offsets: where each line starts.

```
starts = [0, 41, 78, 112, ...]
```

Nothing else can find a line. A monospace editor computes `y = line *
cell_height` and never asks where one begins; with proportional text, locating
line 300 without an index means counting newlines from the start of the file, on
every redraw, for every line.

It is patched on each edit rather than rebuilt. Inserting shifts the starts
after the insertion along by the length inserted and adds one for each newline
in it; deleting drops the starts whose newline was inside the range and shifts
what is left back. The offsets ignore the gap, so they stay correct as it moves,
and a lookup translates by one comparison and an add.

A line that happens to contain the gap is not contiguous and cannot be handed
back as a slice, so it is copied out first. Only one line can contain the gap,
which is why one scratch buffer serves all of them.

Nothing types into any of this yet. Correctness rests on unit tests plus a
randomized one that replays several thousand edits against a plain array holding
the same document the obvious way, comparing the text and every line after each
one.

## Typing

Text arrives as **finished characters, not keys**. `SDL_EVENT_TEXT_INPUT`
carries UTF-8 the platform's input method has already resolved: a dead key and
the letter after it arrive as the accented character they compose to, and a CJK
conversion as the characters it produced. None of that is our code, which is most
of the reason SDL is here.

Return and backspace are not text and do not arrive as any, so they come from
`SDL_EVENT_KEY_DOWN` instead.

Backspace removes **a whole UTF-8 sequence rather than a byte** — one press
takes off `é` or `漢` entire. Not yet a whole grapheme cluster, though: `e` plus
a combining acute takes two presses. That needs Unicode tables, and is not worth
the dependency until there is cursor movement to be wrong about. With something
selected it takes the selection instead, and no more than it.

Two things are deliberately missing. The caret moves by typing, by clicking and
by what the clipboard does, and by nothing else: **there are no arrow keys yet.**
And in-progress IME conversion — `SDL_EVENT_TEXT_EDITING`, the underlined preedit
text a CJK input method shows before you commit it — is not drawn.

A keystroke reshapes the one line it landed in. See the layout cache above for
how the rest are spared.

## Selecting

A press puts **both ends of the selection where it landed**, and dragging moves
the end under the pointer while the other stays. **Shift+click extends** what is
there rather than starting again, and **cmd+A takes the whole file** (ctrl+A
elsewhere). A file remembers its selection the way it remembers its caret and its
scroll, so looking away from it and back leaves it as it was.

The two ends are `cursor` and `anchor`, and **the two being equal is the whole of
what "nothing is selected" means** — a caret is a selection of nothing, so
nothing has to ask which of two states a file is in before reading it. Which end
is which is not fixed either: dragging upwards leaves the anchor after the
cursor, so everything that reads a selection asks for it in order.

Motion reaches a column **only while the pointer is down**. A hover used to be
routed to whatever column it crossed and dropped there; now that the same path
would extend a selection, the routing is what stops it.

### What a double-click takes

Where it landed decides:

- Past the last glyph on a line, **the line** — its ending included, so cutting
  one takes the break with it rather than leaving a blank behind.
- Beside a bracket — `()`, `[]` or `{}` — **what the bracket holds**, the
  bracket itself left out. Nesting is counted and nothing else is: a bracket in a
  string or a comment is a bracket here, which is the price of not knowing what
  language the file is written in.
- Otherwise **the word**. A word runs through letters, digits, underscores and
  every byte above ASCII, so a word with an accent in it stays one word — the
  same bargain backspace makes above, for the same reason.

The character ahead of the caret is looked at before the one behind it, so a
click landing between two things takes the one it is in front of, and a bracket
beats a word when both are there. A double-click on none of the three — on a
space — leaves the caret where the first of the two presses put it rather than
reaching for something to select.

### Drawing it

The band under the text is **a layer of its own** rather than an ordering. Within
a painter layer a solid quad is drawn after a glyph, so a highlight added at the
text's own layer would cover the text; everything the view draws above the text
moved up one to make room.

A line whose ending is inside the selection gets **a stub past its last glyph**,
without which three selected lines look like three selected pieces of text.

### Cut, copy and paste

**cmd+X**, **cmd+C** and **cmd+V** (ctrl elsewhere). The model makes the SDL
calls: the effects name a column and carry nothing else, since the text is in the
file already or on the clipboard already, and copying it into an effect would
make it the one thing there that owned memory.

Pasted text has its **line endings mended** first. Windows puts CRLF on the
clipboard and SDL hands it over unchanged, and only `\n` starts a line here, so a
`\r` left in would sit at the end of every pasted line as a glyph nobody typed
and a column count nobody could explain. Reading a file strips CRLF on the way in
for the same reason; a paste also takes a bare `\r`, which is how older Mac text
ends its lines. Text that already ends its lines the right way is not copied to
find that out.

Copying nothing leaves the clipboard alone, so cutting an empty selection cannot
throw away what somebody else put there. Copying does not ask for a frame either
— the clipboard is not drawn.

The letters are safe to bind because **SDL drops a keystroke whose text is a
control character**, so ctrl+C does not also arrive as the 0x03 Windows makes of
it and land in the file.

`SDL_SetClipboardText` takes a C string, so a selection spanning a zero byte
copies as far as the first one. One can only get in by opening a file that has
one — it is valid UTF-8, so the check on the way in lets it through — and
the platforms' own text formats are terminated the same way, so a byte-exact copy
would only be faithful from one yaz window to another.

## Saving

**cmd+S writes the focused column's file back** to the path it was opened from
(ctrl+S elsewhere). A file nothing has changed is not written at all, so a save
with nothing to do does not so much as touch the file's timestamp.

It goes through **a temporary beside the file and a rename over the top**, so a
write that fails part way through leaves the file that was already there rather
than half of a new one. `tools.install` follows the same rule for the same
reason. The temporary is in the file's own directory rather than anywhere
tidier, because a rename is only atomic within one filesystem and that is the
one place guaranteed to be on the same one.

A file that came in with **CRLF goes back out with CRLF**. The returns are taken
out on the way in so that only `\n` starts a line, and the file remembers that
they were there, so opening something written on Windows and saving it does not
rewrite every line of it.

**A save that fails is reported, not fatal.** A read-only file, a full disk or a
directory that has gone leaves a line on stderr and the mark still on the tab;
the window carries on. Returning the error instead would take the window down
over a file that could not be written.

A file with no name cannot be saved yet: `yaz` on its own opens a blank one, and
cmd+S there says so and writes nothing.

## The caret

The cursor is **one byte offset into the document**, not a line and a column.
Every edit already speaks in offsets, and a pair would be a second thing to keep
in step for nothing gained.

Turning that into a place on screen is where proportional text makes real work.
There is no column width to multiply by, and it cannot be measured against the
*glyphs* either, because shaping is not one glyph per character in either
direction: a space produces none, `ffi` produces one for three characters.

So shaping records the answer while it has it. Each cached line keeps its **caret
positions** alongside the sprites — one per cluster boundary HarfBuzz reported,
plus one past the last glyph — out of the loop already walking the shaped run.
It is the only thing shaping produces that the sprites cannot reconstruct.

Both directions are then a binary search over that array:

- **Drawing the caret** looks up the offset and takes the position.
- **A click** looks up the position and takes the **nearest** boundary, not the
  one before it — clicking the right half of a character puts the caret after
  it. Getting that backwards is not subtly wrong; every click feels one
  character behind.

A click below the last line or right of a line's end is not a miss. It lands on
the nearest place the caret can go, which is what makes clicking into empty
space behave the way it does everywhere else.

### Inside a ligature

Cluster boundaries are not character boundaries. `ffi` is one glyph covering
three bytes, so the two characters inside it have no boundary of their own, and
an offset that lands there has no position to be given.

It is reachable: type `fai`, put the caret between the `a` and the `i`, and
delete the `a` — what is left is `fi`, one ligature, with the caret inside it.
The cluster's width is divided across its bytes rather than snapping to its
start.

An approximation that stops mattering rather than gets fixed: once the cursor
moves by graphemes it will not land there at all, which is the same change that
makes backspacing over an accent take one press.

### Drawing it

The caret is one more instance in the frame's sprite buffer, appended after every
glyph so it draws over the one it sits beside. It goes through the pipeline that
samples nothing rather than the one that samples the atlas, so it is a rectangle
and a colour and no more than that.

It used to be drawn from a patch of full coverage reserved in the atlas, which
worked because a caret is a line tall. The scrollbar is as tall as the window and
a sprite's one size serves both its quad and the region it samples, so that patch
could not stretch to it — and once a second pipeline existed for the scrollbar,
the caret had no reason not to use it either. The patch is gone.

The caret does not blink. Blinking means waking up twice a second forever to
change nothing, which is the opposite of what the event loop is for.

## Layout

```
src/
  main.zig         # SDL setup, the window, the event loop, the command line
  model.zig        # the state the window is showing, and reading a file
  fff.zig          # the file index, and the library it is kept in
  components/      # anything that is given a rect and draws in it
    vtuple.zig     #   the components of a window, top to bottom
    editor.zig     #   the files, and the finder over them
    workbench.zig  #   the files that are open, and where each one is
    tabs.zig       #   a tab per file open in the window
    text_view.zig  #   scrolling, the caret, hit-testing
    finder.zig     #   cmd+P: the query, and what it matched
    healthcheck.zig#   what is shown when a tool is missing
  painter.zig      # what a frame is made of, before the GPU hears about it
  text.zig         # placing a shaped line, and how wide one is
  tools.zig        # the pinned library, and installing it
  message.zig      # what happened, in our words rather than SDL's
  open_file.zig    # the gap buffer, the line index, the layout cache, the caret
  renderer.zig     # GPU device, the two pipelines, drawing
  glyph_atlas.zig  # shaping, rasterizing, atlas uploads
  sdl.zig          # the one @cImport of SDL
  config.zig       # font file, size, and the theme
assets/
  DejaVuSans.ttf
  shaders/
```

**Nothing imports upwards**, which is the shortest description of the design and
the order to read it in:

| | imports |
| --- | --- |
| `config.zig`, `sdl.zig` | nothing of ours |
| `message.zig` | sdl |
| `glyph_atlas.zig` | config, sdl |
| `open_file.zig` | glyph_atlas |
| `painter.zig` | glyph_atlas |
| `text.zig` | glyph_atlas, painter |
| `renderer.zig` | config, sdl, glyph_atlas, painter |
| `fff.zig` | nothing of ours |
| `tools.zig` | fff |
| `model.zig` | fff, glyph_atlas, open_file, tools |
| `components/vtuple.zig` | model, message, painter |
| `components/tabs.zig` | config, model, message, glyph_atlas, open_file, painter, text |
| `components/text_view.zig` | config, model, message, glyph_atlas, open_file, painter, text |
| `components/healthcheck.zig` | config, model, message, glyph_atlas, painter, text, tools |
| `components/finder.zig` | config, model, message, glyph_atlas, painter, text, vtuple |
| `components/editor.zig` | model, message, painter, finder, workbench |
| `components/workbench.zig` | model, message, open_file, painter, tabs, text_view, vtuple |
| `main.zig` | all of the above |

**The only components that import another are the ones whose whole job is
composition.** A tuple or a list holds members and forwards to them; the
workbench is a bar over a row of columns and the finder is a query over a list
of results. Nothing else knows another component exists: each is given a rect,
told what happened in it and asked for its quads.

**Every one of those calls takes a `Model` first.** It carries the allocator,
`std.Io`, the glyph atlas, the files that are open but not on screen, and
whether the window is still up. Nothing stores it -- a component that kept a
copy of the allocator would have a second one to keep in step with the first,
which is what this exists to stop, and it is why `deinit` takes one too.

Where to start depends on what you are changing: what a keystroke does is
`TextView.update`; where text lands on screen is `TextView.draw`; what a glyph
looks like is `glyph_atlas.zig`; how big or what colour anything is is
`config.zig`.

**SDL stops at the event loop.** `Message.init` turns what SDL sends into what
happened — quit, resized, typed text, a key, a wheel delta, a press, a move, a
release — and answers null for the rest, which is most of it. Window coordinates
become pixels there, once, so nothing downstream knows what a display scale is.

What comes out goes to `App` first, which acts on the two events that belong to
the window itself — quit and resize — and hands everything else to the one
component it was given. It asks no questions about what that component is.
Nothing below takes an `SDL_Event`.

Every component shares the same four: `place` to be given room, `update` to be
told what happened, `draw` to add quads to a painter, and `invalidate` for the
one thing none of them survives — the atlas rebuilt at a different scale. A
parent calls them on its children, so the tree is the type system rather than a
vtable.

**`update` is handed the model to read and nothing more.** Its signature says
so — `*const Model` — and what it returns is an `Effect`: the change it worked
out should happen, named rather than made. `Model.apply` is the other half, and
it is the only place in the program where any of this moves.

That is what makes the redraw question answer itself. An effect is a change, so
the frame is asked for once, in `apply`, rather than by every component
remembering to say it changed something; `nothing` is the absence of a change
and leaves the window alone. There is no damage tracking — the whole window is
redrawn — but presenting blocks on the swapchain, so the question worth asking
is only ever *whether* to draw.

The one seam is `place`. Fitting a file to the room a column has — clamping a
scroll to a shorter column, bringing the caret back on screen after typing —
needs a height that nothing knew when the keystroke arrived, so layout is
allowed to write that much back. Everything else goes through an effect.

**A window is one component, and that component is the whole of what is on
screen.** With the library missing it is a `Healthcheck` and nothing else is
built: no files are read, no finder exists. Otherwise it is an `Editor`, which
is the files with the finder over them. `App` is generic over which one it got,
so a component that is not in this window is not in this build of it, and no
code below `main` can ask whether a tool is missing because nothing below `main`
is told.

**Which of the two the `Editor` is showing is not something it remembers.**
`model.finding` is null or it is not, and that is the whole of what "the panel
is open" means. A keystroke goes to the panel while there is one and to the
files while there is not; both draw, panel last, because it lies over them.
That is why the finder can be two small surfaces with the code still at full
contrast either side of them — the file underneath is genuinely still being
drawn — and why a click cannot reach a column the panel is covering.

**An `Effect` owns no memory.** A tab is named by where it sits on the bar and
a match by the fact that it is the selected one, so nothing here is a path that
somebody has to free — which is the whole of what the finder and the workbench
have to say to each other. The finder knows a file was picked and nothing about
columns; `apply` knows what a picked file means and nothing about panels.

Some effects carry what only the component could work out. A click becomes the
byte offset it landed on, a wheel becomes the whole pixel to scroll to and the
fraction left over, because resolving either needs the layout and the room.

**The columns divide the window between them.** They sit side by side in equal
shares, *all of them draw* because none covers another, and *the one with the
keyboard is told what happened*. A press moves the keyboard and takes the
pointer until the release, so a scrollbar drag that wanders out of the column it
began in stays with it. Only the pointer is caught that way — typing goes to the
focused column even mid-drag, and the wheel turns whatever it is under without
deciding where typing lands.

Focus is not drawn in the columns themselves — every view shows the same caret —
but the bar above them says it twice over: a tab is lifted out of the strip when
its file is in a column, and its name is black rather than grey when that column
has the keyboard.

Choosing a file — from the bar or from the finder — hands the keyboard to the
column the file landed in, so a tab press ends with the document ready to be
typed into rather than with the bar holding it.

`Tabs` lays its own tabs out rather than dividing the bar evenly, because a row
of equal shares is the wrong shape for a row of words: each tab is as wide as
the name in it. It answers a press with `Effect.show` and the tab's place on the
bar, which is exactly what the digit binding means, so a tab reached either way
says the same thing and neither has to name a file.

**`VTuple` stacks members top to bottom, and is the one place where they are
not all the same size.** Each is asked how tall it wants to be, and one that
does not say takes what is left. That is what the atlas in the `Model` is
for during `place`: a height is nearly always a number of lines, and what a line
is worth belongs to the font at the display's scale rather than to the layout.

The finder is one — `VTuple(&.{ Query, Results })`. The query says it is a line,
a rule and the air around them; the list says nothing and gets the rest of the
window. Neither has to be told where the other ends, and the finder itself no
longer computes a single baseline: it owns the two processes and the bytes they
produce, and hands the matches to the list.

The view therefore names no SDL type and makes no SDL call. It does reach
`sdl.zig` through `message.zig`, so the separation is one of vocabulary rather than
of linkage.

`open_file.zig` is one file the window has open: the text, where its lines
begin, what each line shaped to, the name on its tab, and where its reader was.
It does not know that text gets drawn, and holds no coordinates but its own,
which is why it can be read and tested on its own.

The layout cache is there rather than in the view because it depends on a line's
bytes and the atlas scale and on nothing a view has, which is also what lets
`insert` and `delete` splice it themselves rather than leaving that to a
caller.

`glyph_atlas.zig` keeps shaping and rasterizing together because neither can be
asked without the other — shaping decides which glyphs exist, rasterizing decides
where they land. It shapes one line at a time, into that line's own coordinates,
and knows nothing about files.

`components/text_view.zig` points at an open file and adds what a *view* of one
has: a scrollbar, the rect everything is measured from, and the gesture in
progress. It is the only thing that turns a click into a byte offset. Pointing
it at another file hands nothing back and drops nothing — the file it was
showing stays open, which is why looking away from one and returning to it
reshapes nothing and the caret is where you left it.

`renderer.zig` is handed a finished array of quads and knows nothing else: not
what they spell, not which line each came from, not that shaping happened.

`sdl.zig` is the one `@cImport` of SDL, and the one place SDL has to be reached
around. Keeping it separate also keeps the imports acyclic: everything points at
it and it points at nothing.

`config.zig` holds the settings changed while working on the editor. `build.zig`
imports it too, so the font path is stated once and the build embeds the file it
names.

## Shaders

Shaders are authored in GLSL under `assets/shaders/` and compiled to the one
bytecode format the target needs:

| Target | Output | How |
| --- | --- | --- |
| Linux, Windows | SPIR-V | glslang |
| macOS | MSL | glslang, then SDL_shadercross via SPIRV-Cross |

This happens as part of `zig build`. The bytecode lands in `.zig-cache`, never
in the source tree, and is embedded into the executable.

The format is a compile-time constant rather than a runtime probe, so it also
pins the backend: the device is created requesting exactly that format and SDL
can only select one that accepts it.

GLSL rather than HLSL for a second reason beyond avoiding DXC, covered under
[Platform notes](#platform-notes): a GLSL `sampler2D` is a combined image
sampler, which is what SDL's Vulkan backend binds. HLSL separates textures from
samplers and needs a translation pass to put them back.

### The shader compiler

Nothing to install. On the first build `vendor/setup-shader-toolchain.sh`
downloads glslang into `vendor/toolchain/` — 8MB archived, 28MB unpacked. Later
builds skip it, and everything under `vendor/` but the script is git-ignored.

Targeting macOS additionally builds SPIRV-Cross and SDL_shadercross from source,
needing `git`, a C++ compiler and a few minutes; it uses the system `cmake` if
there is one. `YAZ_KEEP_SOURCES=1` keeps the intermediate sources. Other targets
never pay this.
