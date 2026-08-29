# yaz

A text editor built for low latency, low resource usage, and high performance.

Native GPU rendering with proportional (variable-width) fonts, targeting Linux,
macOS, and Windows.

## Status

Early. Currently: a window, a GPU device, and lines of text shaped by HarfBuzz
and drawn from a glyph atlas that FreeType rasterizes at startup. Proportional
and kerned, but there is no buffer yet and nothing to type into.

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

### Redrawing

The render loop blocks in `SDL_WaitEvent` and draws only when something has
changed what is on screen. Waking up is not a reason to draw. Events already
queued when the loop wakes are folded into one frame, and a resize draws from an
event watch, because the platform's own modal loop will not hand control back
until the drag ends.

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

The texture is 1024×1024 single-channel — a megabyte. The sample text's 46
distinct glyphs occupy 82 of those rows, so the ceiling is somewhere near 500
glyphs, and a CJK document reaches it long before a Latin one does.

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

Lines are reshaped on every redraw, which is more often than they change. The
per-line layout cache that fixes it needs an editable buffer to invalidate
against, and there is not one yet.

## Layout

```
src/
  main.zig         # SDL setup, the window, the event loop, the document
  renderer.zig     # GPU device, pipeline, drawing
  glyph_atlas.zig  # shaping, layout, rasterizing, atlas uploads
  config.zig       # font file and size
assets/
  DejaVuSans.ttf
  shaders/
```

`config.zig` holds the settings that get changed while working on the editor —
the font file and its rasterisation size. `build.zig` imports it too, so the
font path is stated once and the build embeds the file it names.

`glyph_atlas.zig` is one file because it is one pipeline. Shaping decides which
glyphs exist, so it is the only thing that can say what to rasterize;
rasterizing decides where they land in the atlas, so it is the only thing that
can say what to sample. It hands `renderer.zig` a list of quads and their source
rectangles, and the renderer knows nothing about glyph ids, subpixel offsets or
FreeType.

`renderer.zig` owns the SDL `@cImport`; `main.zig` and `glyph_atlas.zig` both
take their SDL types from there. Two `@cImport` blocks that differ by so much as
whitespace generate two unrelated sets of types, and a `*SDL_Window` from one
will not pass as a `*SDL_Window` to the other.

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
