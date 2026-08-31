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

**There is no way to save.** Anything typed is lost when the window closes, and
that includes edits to a file that was opened. Nothing is written to disk.

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

## The two tools

yaz runs on two external binaries — **ripgrep** to list the files the finder
chooses between, and **fzf** to rank them against what has been typed. Neither
is bundled. Install them with:

```sh
yaz setup
```

They land in `~/.config/yaz/bin/`, and that is the only place yaz looks. `PATH`
is deliberately not consulted: yaz runs what it installed and checked, so
another `rg` earlier on the path cannot quietly change what the finder does.

Versions are **pinned and checksummed**. `setup` refuses to install an archive
whose bytes do not hash to the SHA-256 recorded in `src/tools.zig`, taken from
the checksum files published beside each release — the same rule
`vendor/setup-macos-sdk.sh` applies to the macOS SDK, for the same reason: a
downloaded binary is code about to be run.

`yaz setup` is the only thing in yaz that touches the network, and it does so
because it was asked to. It is idempotent, and skips a tool that already runs.

**Nothing else runs until both are there.** On startup yaz spawns each binary
with `--version` and requires it to exit cleanly; if either does not, the window
shows what is missing and where it looked, and no file on the command line is
even read — a bad path would otherwise report the wrong problem first.

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
window takes its title from the first.

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
show a `.notdef` box at the end of every line. The bytes in memory then stop
matching the file exactly, which is a trade to revisit when there is a way to
save.

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

It does no listing and no matching of its own. `rg --files` says what there is
to choose between, so .gitignore is honoured for free, and `fzf --filter` ranks
it against what has been typed — the same ranking as fzf itself, because it *is*
fzf.

That second one costs a process: **about 6.5ms per character typed**, measured
on an M2. The listing is read once per opening rather than per keystroke, so
that part does not grow with the repository; what a bigger one costs is fzf's
own matching, 63ms for 50,000 candidates, which is the work fzf does anywhere.

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

A wheel delta is read as **points, always**: SDL reports tenths of a point from a
precise device and whole lines from a notched one, in one field with no flag
between them, and macOS registers a single mouse with no name, so nothing can
tell them apart. A trackpad therefore tracks the finger exactly and a wheel click
moves about ten points.

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
line's sprites are shaped once and kept **on the document**, in coordinates of
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
never learns that a document does.

Both live inside `Document`, so an edit and its splice are one call — the only
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
call however many components produced them. A screenful is three calls with one
text view, and still three with a dozen.

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

The caret and the scrollbar share that pipeline and take a call each only because
they are two colours. The alternative is a colour on every sprite — four more
floats uploaded per glyph per frame to repeat one value.

The vertex uniform holds what the whole frame shares, the viewport and the atlas
size. The fragment stage has one of its own for the colour, because the atlas
stores coverage rather than colour: a glyph's bitmap says how much of each pixel
is ink, and nothing about what ink is. That colour, the caret's and the
background are the theme, and all three live in `config.zig`.

Neither shader knows what a caret or a scrollbar is; they are quads with a
colour, and the colour is the only thing the second pipeline is told.

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

## The document

Text lives in a **gap buffer**: one contiguous allocation with a hole in it,
kept wherever the last edit happened. It sits in `text_view.zig`, underneath the
view that owns it.

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
the dependency until there is cursor movement to be wrong about.

Two things are deliberately missing. The caret moves by typing and by clicking,
and by nothing else: **there are no arrow keys yet.** And in-progress IME
conversion — `SDL_EVENT_TEXT_EDITING`, the underlined preedit text a CJK input
method shows before you commit it — is not drawn.

A keystroke reshapes the one line it landed in. See the layout cache above for
how the rest are spared.

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
  main.zig         # SDL setup, the window, the event loop, opening a file
  components/      # anything that is given a rect and draws in it
    ztuple.zig     #   the components of a window, back to front
    htuple.zig     #   the components of a window, left to right
    vtuple.zig     #   the components of a window, top to bottom
    hlist.zig      #   however many components of one kind, left to right
    text_view.zig  #   scrolling, the caret, hit-testing
    finder.zig     #   cmd+P, driving rg and fzf
    healthcheck.zig#   what is shown when a tool is missing
  painter.zig      # what a frame is made of, before the GPU hears about it
  text.zig         # placing a shaped line, and how wide one is
  tools.zig        # the pinned binaries, and installing them
  event.zig        # what happened, in our words rather than SDL's
  document.zig     # the gap buffer, the line index, the layout cache
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
| `event.zig` | sdl |
| `glyph_atlas.zig` | config, sdl |
| `document.zig` | glyph_atlas |
| `painter.zig` | glyph_atlas |
| `text.zig` | glyph_atlas, painter |
| `renderer.zig` | config, sdl, glyph_atlas, painter |
| `tools.zig` | nothing of ours |
| `components/ztuple.zig`, `components/htuple.zig`, `components/vtuple.zig` | event, glyph_atlas, painter |
| `components/hlist.zig` | event, glyph_atlas, painter |
| `components/text_view.zig` | config, document, event, glyph_atlas, painter, text |
| `components/healthcheck.zig` | config, event, glyph_atlas, painter, text, tools |
| `components/finder.zig` | config, event, glyph_atlas, painter, text, tools, vtuple |
| `main.zig` | all of the above |

**No component imports another.** Each is given a rect, told what happened in it
and asked for its quads; `App` in `main.zig` is the only thing that knows there
is more than one. That is what the directory is saying.

Where to start depends on what you are changing: what a keystroke does is
`TextView.update`; where text lands on screen is `TextView.draw`; what a glyph
looks like is `glyph_atlas.zig`; how big or what colour anything is is
`config.zig`.

**SDL stops at the event loop.** `Event.init` turns what SDL sends into what
happened — quit, resized, typed text, a key, a wheel delta, a press, a move, a
release — and answers null for the rest, which is most of it. Window coordinates
become pixels there, once, so nothing downstream knows what a display scale is.

What comes out goes to `App` first: it acts on what belongs to the window — quit,
resize, cmd+P — and hands the rest to its stack. Nothing below takes an
`SDL_Event`.

Every component shares the same six: `place` to be given room, `update` to be
told what happened, `draw` to add quads to a painter, `isDirty`/`setDirty` so a
parent answers for what it holds, and `invalidate` for the one thing none of them
survives — the atlas rebuilt at a different scale. A parent calls them on its
children, so the tree is the type system rather than a vtable.

**A window is a `ZTuple`, and it is the whole of what is on screen.** Its members
are fixed at compile time and their order is not: *everything in it draws, back
to front*, and *only the one in front is told what happened*. That is why the
finder can be two small surfaces with the code still at full contrast either
side of them — the document is genuinely still being drawn — and why a click
cannot reach a view the finder is covering. `raise` and `lowerFront` are the whole of opening a panel and putting
it away; there is no separate notion of a thing being open.

**The tool check decides which stack there is, once, in `main`.** With ripgrep or
fzf missing the window is `ZTuple(&.{Healthcheck})` and nothing else is built —
no files are read, no finder exists. Otherwise it is
`ZTuple(&.{ Finder, Views })`, listed back to front, so the finder sits behind
the text until cmd+P brings it forward. `App` is generic over which one it got,
so a component that is not in this window is not in this build of it: the
branches that name one are compiled out where there is none. No code below `main`
can ask whether a tool is missing, because nothing below `main` is told.

**A component answers an event with an `Intent`** — `nothing`, `dismiss`, or
`open` with a path. It is how the finder, which knows what was picked, reaches
`App`, which knows what to do with it, without the finder and the views knowing
about each other. `App` is the only thing that acts on one, because it is the
only thing that knows what else is in the stack — and it is where the parked
documents live, since a row is a layout and knows nothing about files.

**`HTuple` is the same idea across.** Same fixed members, and what varies is
which one has the keyboard rather than which one is in front: they sit side by
side in equal columns, *all of them draw* because none covers another, and *the
focused one is told what happened*. A press moves the keyboard and takes the
pointer until the release, so a scrollbar drag that wanders out of the column it
began in stays with it. Only the pointer is caught that way — typing goes to the
focused column even mid-drag, and the wheel turns whatever it is under without
deciding where typing lands.

Focus is not drawn: every view shows the same caret, so with more than one column
the way to tell which has the keyboard is to type. That is the first thing a
border or an active title would fix.

**A Tuple is a composition; a List is a repetition.** The three above take a
statically determined list of members that may all be different things, so a
window is `ZTuple(&.{ Finder, Views })` and knows at compile time exactly what is
in it. When the members are all the same kind and how many there are is not known
until the program runs, that is a **List** instead: `Views` is `HList(TextView)`,
because the column count comes off the command line. One member type means
reaching the nth is an index rather than a selection over a tuple, which is the
whole of the difference in the code. `VList` and `ZList` are the same file again
and will be written when something needs them.

**`VTuple` is the third of the tuples, and the only one whose members are not all
the same size.** A ZTuple gives every member the whole rect and an HTuple divides it
evenly; here each member is asked how tall it wants to be, and one that does not
say takes what is left. That is why `place` carries the atlas: a height is nearly
always a number of lines, and what a line is worth belongs to the font at the
display's scale rather than to the layout.

The finder is one — `VTuple(&.{ Query, Results })`. The query says it is a line,
a rule and the air around them; the list says nothing and gets the rest of the
window. Neither has to be told where the other ends, and the finder itself no
longer computes a single baseline: it owns the two processes and the bytes they
produce, and hands the matches to the list.

The view therefore names no SDL type and makes no SDL call. It does reach
`sdl.zig` through `event.zig`, so the separation is one of vocabulary rather than
of linkage.

`document.zig` is the text, where its lines begin, and what each line shaped to
— everything derived from the bytes and nothing else. It does not know that text
gets drawn or scrolled, and holds no coordinates but its own, which is why it can
be read and tested on its own.

The layout cache is there rather than in the view because it depends on a line's
bytes and the atlas scale and on nothing a view has, which is also what lets
`insert` and `delete` splice it themselves rather than leaving that to a
caller.

`glyph_atlas.zig` keeps shaping and rasterizing together because neither can be
asked without the other — shaping decides which glyphs exist, rasterizing decides
where they land. It shapes one line at a time, into that line's own coordinates,
and knows nothing about documents.

`components/text_view.zig` owns a document and adds what a *view* of one has: a
caret, a scroll offset, a scrollbar, and the rect all three are measured from. It
is the only thing that turns a click into a byte offset. Pointing it at another
file hands the whole document back rather than dropping it, which is why looking
away from one and returning to it reshapes nothing.

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
