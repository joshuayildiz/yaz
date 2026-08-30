# yaz

A text editor built for low latency, low resource usage, and high performance.

Native GPU rendering with proportional (variable-width) fonts, targeting Linux,
macOS, and Windows.

## Status

Early. Currently: a window, a GPU device, and lines of text shaped by HarfBuzz
and drawn from a glyph atlas that FreeType fills as glyphs are asked for.
Proportional and kerned, with a per-line layout cache so a keystroke reshapes
one line rather than the screen. The text comes out of a gap buffer, there is a
caret, and you can type into it or click to put the caret somewhere else. It
opens a file named on the command line.

**There is no way to save.** Anything typed is lost when the window closes, and
that includes edits to a file that was opened. Nothing is written to disk.

Built and run on Linux, Windows and macOS. Building happens on a Linux or macOS
host; Windows and macOS binaries are cross-compiled.

## Requirements

- **Zig 0.16.0** or later. Earlier versions will not work: 0.15 replaced the
  `std.io` reader/writer types and 0.16 changed `main` to take
  `std.process.Init`.
- `curl`, to fetch the shader compiler on the first build.
- Targeting macOS additionally needs `git` and a C++ compiler. See
  [macOS](#macos).

SDL, FreeType and HarfBuzz are built from source by the Zig build system and
linked statically, so no system `-dev` packages are needed.

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
```

One optional argument, and the window takes its title from the path as typed.
`assets/sample.txt` is there to be opened: it is the text the editor was
developed against, and it exercises ligatures, a combining mark, `.notdef` and
proportional advances in six lines.

Naming a file that does not exist is not an error — that is how a new file
begins. Anything else is: a directory, a file that cannot be read, or one past
the size limit. Each says which and stops, because the alternative is an empty
window that looks exactly like an empty file.

```
$ yaz war-and-peace.txt
error: war-and-peace.txt is larger than the 1MB yaz will open, because layout
       draws every line rather than the ones on screen
```

That limit is not about reading. `TextView.layout` places every glyph of every
line on every frame, so a large file is slow for reasons that have nothing to do
with the file, and the atlas runs out of room long before memory does. Refusing
with a number beats opening something that appears to hang. It comes out when
layout draws only what is on screen.

**A file that is not valid UTF-8 is refused**, with the offset of the byte that
made it so:

```
$ yaz notes.txt
error: notes.txt is not UTF-8: the byte at offset 4102 does not begin or
       continue a character
```

Refused rather than drawn, because everything above the bytes assumes UTF-8 and
only one layer would complain. HarfBuzz substitutes a replacement character and
carries on, so the text would merely look wrong — but stepping the caret back
over a character walks continuation bytes until it finds one that is not, and
over stray bytes it steps back over as many as happen to be adjacent and deletes
all of them. An editor that quietly makes a file worse than it found it is worse
than one that will not open it. A Latin-1 file lands here, as does anything
binary.

**CRLF is converted to LF as the file is read**, so a file written on Windows
does not show a `.notdef` box at the end of every line, and everything
downstream has one kind of line ending to assume. The bytes in memory therefore
stop matching the bytes on disk — a trade worth revisiting when there is a way
to save, and not before.

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
nothing downstream reads, and the coordinates on a mouse event, which are
multiplied by `SDL_GetWindowPixelDensity` before hit-testing. Nothing comes back
out: the size `SDL_WaitAndAcquireGPUSwapchainTexture` reports is already pixels
and goes straight to the viewport.

The window is created with `SDL_WINDOW_HIGH_PIXEL_DENSITY`. Without it the
platform hands back a back buffer at the window's size in window coordinates and
scales the finished frame up to the display — which on a Retina Mac meant a
1024×768 swapchain stretched onto 2048×1536 physical pixels, undoing the whole
point of rasterizing glyphs at four subpixel offsets. It looked like soft text
and nothing else; the pipeline was correct and the frame was resampled after it.

SDL's documentation adds that macOS wants `NSHighResolutionCapable` in an
Info.plist for this. It is not needed here: yaz is a bare executable with no
bundle, and a bare executable on current macOS is high-resolution by default —
measured, on an M2, as a density of 2.0 with the flag and 1.0 without it.

How large to draw comes from `SDL_GetWindowDisplayScale`, not from the density.
The two agree on macOS and differ where it counts: Windows at 150% on an ordinary
panel reports a density of 1.0 and a scale of 1.5, and sizing text by density
there would silently ignore what the user asked for. `config.font_size` is the
nominal size, and the scale is what turns it into pixels — so a `32` means the
same size to look at on every display, and only the number of pixels spent on it
changes.

The scale is read at the top of each redraw and compared, rather than listened
for. Three window events can imply it changed, and one of the ways it changes —
dragging the window to another display — happens inside the platform's modal
loop, where the resize watch below is the only code that runs at all. A float
compare on a path that only runs because something changed anyway cannot miss
any of that. When it does change, the atlas is rebuilt in place: the texture
survives, since its size does not depend on the scale, and what is given up is
the packing state, the metrics, and every shaped line.

### Redrawing

The render loop blocks in `SDL_WaitEvent` and draws only when something has
changed what is on screen. Waking up is not a reason to draw. Events already
queued when the loop wakes are folded into one frame, and a resize draws from an
event watch, because the platform's own modal loop will not hand control back
until the drag ends.

Redrawing during the drag is only half of it on macOS. A `CAMetalLayer` keeps
`CALayer`'s default `contentsGravity` of `kCAGravityResize`, so between the
window's bounds changing and the next frame arriving the compositor stretches the
old frame to fit — which on a proportional layout reads as the glyphs themselves
changing width. SDL sets that property nowhere, and does not hand out the view it
created, so the layer is reached through the two window properties that say where
it is (`SDL.window.cocoa.window` and `SDL.window.cocoa.metal_view_tag`) and four
Objective-C messages. `contentsGravity` is set to `kCAGravityTopLeft` instead,
which leaves the old frame at its own size in the corner text is laid out from.

Not stretching the old frame leaves a strip with nothing in it, and that strip
has to be some colour until a redraw fills it. A `CALayer`'s background is unset
by default and SDL marks the layer opaque, so it composites as black — against a
light theme, a dark edge that trails the drag and snaps back. The layer is given
`config.background` to show there instead, so the worst case is a moment of empty
margin in the colour the margin is anyway. Measured by growing the window and
suspending redraws: the strip is 100% black without it and 100% white with it.

Both of those live in `sdl.zig`, beside the `@cImport` — the same kind of
boundary, reached around in the same one place.

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
themselves. Note that building *on* macOS is the one path not yet exercised;
only cross-compiling to it is.

Apple's SDK is not ours to redistribute, and its licence contemplates use on
Apple hardware. It is downloaded at build time from a third-party mirror rather
than vendored, so nothing of Apple's enters the repository.

## Fonts

One font ships inside the binary: `assets/DejaVuSans.ttf`, embedded with
`@embedFile` and rasterized by FreeType. There is no system font discovery, and
there is not meant to be. Every platform then renders the same pixels from the
same bytes, which makes rendering bugs reproducible and removes a whole class of
platform-specific font-matching code.

The cost is 759KB of binary. Subsetting to the ranges the editor actually draws
would cut most of that if it ever matters.

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

That pair comes from **GPOS**: DejaVu Sans has a `kern` feature there for the
`latn` script, and HarfBuzz prefers it over the legacy `kern` table. The font
happens to carry both, with the same -131 font units in each, so this particular
pair would also have come out right from the legacy table that FreeType reads.
The general case will not — GPOS kerning is contextual, so it cannot be reduced
to a table of pairs, which is why shaping is a library and not a lookup.

HarfBuzz reads the font tables directly here rather than going through FreeType
(`hb-ft`), and that choice matters more than it looks. FreeType reports advances
rounded to whole pixels once hinting is on. Whole-pixel advances put every pen
position on a whole pixel, which means the subpixel atlas below would only ever
be asked for one of its four variants. Reading the tables keeps advances
fractional — `A` advances 21.890625px, not 22 — and all four variants get used.

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

Right-to-left text is therefore not merely unsupported, it comes out wrong and
says nothing about it. Hebrew and Arabic glyphs are in the font, and HarfBuzz
will even produce correct Arabic joining forms — those come from `init`, `medi`
and `fina`, which are substitutions and have nothing to do with direction. It
will then set them down left to right, which is backwards. There is no UAX #9
bidi pass here and there is not meant to be one.

The language is stated rather than guessed for a separate reason:
`hb_buffer_guess_segment_properties` takes it from the system locale, and the
point of embedding the font is that every machine draws the same pixels.

The script tag alongside them is a shortcut rather than a decision — but with
this font, a measured one. `ГА` and `ΑΤ` shape to identical advances under
`latn` and under their own tags, and the scripts where the tag would change the
outcome are not in DejaVu Sans to begin with: Devanagari and Thai both come back
as `.notdef`. It becomes a real question if the embedded font changes, and not
before.

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
megabyte, except on macOS, where it is 2048×2048 and four. Every Mac SDL runs on
is Retina, so the glyphs there are rasterized at twice the size and take four
times the area; doubling the texture at build time keeps the same ceiling. The
size is chosen from the target rather than at runtime because it is a texture, not
a knob, and the one platform where density is not a question is the one where it
matters.

At the density each is sized for, the 46 distinct glyphs of `assets/sample.txt`
occupy 82 rows, so the ceiling is somewhere near 500 glyphs, and a CJK document reaches it
long before a Latin one does. The ceiling is driven by density rather than by
platform, though, so Windows on a 4K panel at 200% is as dense as a Mac and gets
the smaller texture; see [FIXME.md](FIXME.md).

Nothing is ever evicted, and **running out is fatal**: it panics, naming the
glyph, its size, and how many glyphs were already in.

```
panic: glyph atlas is full: no room for glyph 28 at 17x23 in 256x256, 41 glyphs in
```

Crashing beats carrying on without the glyph, which would read as a renderer
bug rather than a full atlas. `renderer.zig` carries a TODO at that point with
the two ways out: a larger texture, or growing one at runtime.

### Glyphs that are not there

A character the font has no glyph for draws as **`.notdef`** — glyph zero, which
every TrueType font defines for exactly this. No code produces it: shaping hands
back glyph zero, and the atlas rasterizes it like any other glyph.

Both ways a glyph can fail to *reach* the atlas — no room, and FreeType refusing
to rasterize it — panic instead. The font is compiled into the binary, so a
glyph it will not rasterize is a broken build rather than bad input.

### The layout cache

Shaping is the expensive half of turning a line into pixels, and it depends on
**the line's bytes and nothing else** — not on where the line sits. So each
line's sprites are shaped once and kept, in coordinates of the line's own: x
from where the line starts, y from its baseline. Placing them is then an add.

That is what makes the cache survive an ordinary edit. Typing a newline at the
top of the file moves every line below it down a row, but moves nothing within
any of them; those lines are the same shaped lines at a different baseline. Had
the cache been keyed by screen position, that edit would have invalidated the
whole document — exactly backwards.

Two things follow from it. The origin has to be a whole number of pixels, or the
translation would change which subpixel variant each glyph points at; `layout`
asserts that. And each line's baseline is rounded once for the line rather than
once per glyph, which is the same answer for anything without a fractional
vertical offset, meaning everything in this font.

Invalidation is not a search. `Buffer.insert` and `Buffer.delete` already work
out which line an edit landed in and how many lines it created or destroyed —
they have to, to patch the line index — so they return it as an `Edit` and the
cache gets the same splice the index got. Every other entry survives. The buffer
never learns that shaping exists; the atlas never learns that a document does.

Both live inside `TextView`, so an edit and its splice are one call. Nothing
can perform one without the other, which is the only real way to keep two
structures indexed the same way from drifting apart.

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
about a nanosecond a glyph. It is also work spent on lines nobody can see, since
the window holds twenty of them. Laying out only what is on screen is the next
thing worth doing and the cache is what makes it possible, but it is not done
yet.

The cost is memory: 24 bytes a glyph, so 37KB for a screenful and 3.7MB for a
2,000-line document. Nothing is evicted, for the same reason nothing is evicted
from the atlas — and the same day will fix both.

### Drawing

A frame is two draw calls, whatever is on screen, and the second one draws a
single quad. The vertex shader builds each quad's four corners from
`gl_VertexIndex` and reads everything that differs between glyphs — where it
lands, where to sample it, how big it is — out of a storage buffer indexed by
`gl_InstanceIndex`. There is no vertex buffer, and nothing is sent per glyph:

```
SDL_DrawGPUPrimitives(pass, 4, glyph_count, 0, 0);          // the text
SDL_DrawGPUPrimitives(pass, 4, 1, 0, glyph_count);          // the caret
```

The caret is a second call only so that it can be a different colour. It is the
last quad in the same buffer, drawn by the same pipeline with the same bindings;
what changes between the two calls is the fragment uniform and nothing else. The
alternative is a colour on every sprite — four more floats on a struct written
and uploaded once per glyph per frame, to repeat the same value every time.

What is left in the vertex uniform block is what the whole frame shares: the
viewport and the atlas size. The fragment stage has one of its own holding the
colour to draw in, because the atlas stores coverage rather than colour — a
glyph's bitmap says how much of each pixel is ink, and nothing about what ink is.
That colour, the caret's, and the background they are cleared against are the
theme, and all three live in `config.zig` rather than one of them living in a
shader. It is black on white, caret included;
`config.zig` names the softened pair it replaced, one edit away.

The caret goes through this shader too, sampling a patch of the atlas that is
opaque everywhere, so it needs no second pipeline and no shader that knows what a
caret is.

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

Editing somewhere else moves the hole there first, which is one `memmove` of the
text in between and is the only operation here that is not constant time. That
is the bet the structure makes, and it is a good one for an editor: editing is
local, so the distance is usually a few characters. A jump across the whole file
is a single pass at memory bandwidth, not a data structure to maintain.

A rope or a piece table wins past roughly 100MB, where that `memmove` starts to
dominate. Below it they lose on every operation that matters, paying with
pointer chasing, per-node headers and cache misses to walk a tree. Huge files
are out of scope, so the gap buffer is the faster structure here and a fraction
of the code. The interface it is used through — `insert`, `delete`, `lineSlice`,
`byteLen` — says nothing about how it stores anything, so that judgement can be
revisited without the renderer noticing.

### The line index

Alongside it is a flat array of byte offsets: where each line starts.

```
starts = [0, 41, 78, 112, ...]
```

This has to exist because nothing else can find a line. A monospace editor
computes `y = line * cell_height` and never asks where a line begins; with
proportional text there is no cell width and lines are variable-length byte
strings, so locating line 300 without an index means counting newlines from the
start of the file, on every redraw, for every line.

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

Text arrives as **finished characters, not keys**. `SDL_StartTextInput` puts the
window into text-input mode, and what comes back through
`SDL_EVENT_TEXT_INPUT` is UTF-8 that the platform's input method has already
resolved: a dead key and the letter after it arrive as the one accented
character they compose to, and a CJK conversion arrives as the characters it was
converted into. None of that is our code, which is most of the reason SDL is
here.

Return and backspace are not text and do not arrive as any, so they come from
`SDL_EVENT_KEY_DOWN` instead.

Backspace removes **a whole UTF-8 sequence rather than a byte** — one press
takes off `é` or `漢` entire. It is not yet a whole grapheme cluster: `e`
followed by a combining acute is two characters and takes two presses. Getting
that right needs Unicode tables this project does not carry yet, and it is not
worth the dependency until there is cursor movement to be wrong about.

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

Turning that into a place on screen is the part proportional text makes real
work. There is no column width to multiply by, so the offset has to be measured
against the shaped line — and it cannot be measured against the *glyphs* of that
line, because shaping is not one glyph per character in either direction. A
space produces no glyph at all. `ffi` produces one glyph for three characters.

So shaping records the answer while it has it. Alongside the sprites, each
cached line keeps its **caret positions**: one per cluster boundary HarfBuzz
reported, plus one past the last glyph, in the line's own coordinates. It comes
out of the loop that was already walking the shaped run, and it is the only
thing that survives shaping which the sprites cannot reconstruct.

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

It is reachable. Type `fai`, put the caret between the `a` and the `i`, and
delete the `a`: what is left is `fi`, one ligature, with the caret inside it.
The width of the cluster is divided across its bytes, which puts the caret
somewhere sensible rather than snapping it to the ligature's start.

That is an approximation, and the honest description of it is that it stops
mattering rather than gets fixed: once the cursor moves by graphemes instead of
by characters it will not land there at all. That is the same change that makes
backspacing over an accent take one press instead of two.

### Drawing it

The caret is a filled rectangle, and the pipeline only knows how to draw quads
that sample the glyph atlas. So the atlas holds **one patch that is not a
glyph**: a square of full coverage, sized to the line height, reserved before
any glyph is rasterised. A quad pointed at it comes out solid.

That makes the caret one more instance in the frame's sprite buffer. No second
pipeline, no second draw call, no shader that knows what a caret is. It is
appended last so it draws over the glyph beside it rather than under it.

The caret does not blink. Blinking means waking up twice a second forever to
change nothing, which is the opposite of what the event loop is for.

## Layout

```
src/
  main.zig         # SDL setup, the window, the event loop
  text_view.zig    # the document, the caret, the per-line layout cache
  renderer.zig     # GPU device, pipeline, drawing
  glyph_atlas.zig  # shaping, rasterizing, atlas uploads
  sdl.zig          # the one @cImport of SDL
  config.zig       # font file and size
assets/
  DejaVuSans.ttf
  shaders/
```

`config.zig` holds the settings that get changed while working on the editor —
the font file and its rasterisation size. `build.zig` imports it too, so the
font path is stated once and the build embeds the file it names.

`glyph_atlas.zig` keeps shaping and rasterizing together because neither can be
asked without the other. Shaping decides which glyphs exist, so it is the only
thing that can say what to rasterize; rasterizing decides where they land in the
atlas, so it is the only thing that can say what to sample. It shapes one line
at a time, into coordinates of that line's own, and knows nothing about
documents.

`text_view.zig` holds a document beside the layout of its lines. The cache is
there rather than with the atlas because it belongs to a view rather than to a
font: one atlas serves every document, and each view of one caches its own
lines. Keeping the two in a single struct is also what makes them impossible to
get out of step — an edit and the splice that answers it are one call, not two
that a caller has to remember to pair.

`renderer.zig` is handed a finished array of glyph positions and knows nothing
else about them: not what they spell, not which line each came from, not that
shaping happened at all.

`sdl.zig` exists so there is exactly one `@cImport` of SDL. Two blocks that
differ by so much as whitespace generate two unrelated sets of types, and a
`*SDL_Window` from one will not pass as a `*SDL_Window` to the other. Keeping it
in a file of its own also keeps the imports acyclic: everything points at
`sdl.zig` and it points at nothing.

## Shaders

Shaders are authored in GLSL under `assets/shaders/` and compiled to the one
bytecode format the target needs:

| Target | Output | How |
| --- | --- | --- |
| Linux, Windows | SPIR-V | glslang |
| macOS | MSL | glslang, then SDL_shadercross via SPIRV-Cross |

This happens as part of `zig build`. The bytecode is a build artifact: it lands
in `.zig-cache`, never in the source tree, and is embedded into the executable.
Editing a `.glsl` file rebuilds it like any other source change.

The format is a compile-time constant rather than a runtime probe, so it also
pins the backend — the GPU device is created requesting exactly that format, and
SDL can only select a backend that accepts it.

GLSL rather than HLSL for a second reason beyond avoiding DXC, covered under
[Platform notes](#platform-notes): a GLSL `sampler2D` is a combined image
sampler, which is exactly what SDL's Vulkan backend binds. HLSL separates
textures from samplers and needs a translation pass to put them back together.

### The shader compiler

Nothing to install. On the first build, `vendor/setup-shader-toolchain.sh`
downloads glslang into `vendor/toolchain/` — an 8MB archive, 28MB unpacked, a
couple of seconds. Later builds skip it. Everything under `vendor/` except the script is
git-ignored.

Targeting macOS additionally builds SPIRV-Cross and SDL_shadercross from source,
which needs `git`, a C++ compiler, and a few minutes; it uses the system `cmake`
if there is one and downloads a prebuilt CMake otherwise. Set
`YAZ_KEEP_SOURCES=1` to keep the intermediate sources. Non-macOS targets never
pay this cost.
