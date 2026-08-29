# yaz

A text editor built for low latency, low resource usage, and high performance.

Native GPU rendering with proportional (variable-width) fonts, targeting Linux,
macOS, and Windows.

## Status

Early. Currently: a window, a GPU device, and lines of text drawn from a glyph
atlas that FreeType rasterizes at startup. Advances come straight from the font
face, so the text is proportional but unkerned; shaping is the next step.

Built and run on Linux, Windows and macOS. Building happens on a Linux or macOS
host; Windows and macOS binaries are cross-compiled.

## Requirements

- **Zig 0.16.0** or later. Earlier versions will not work: 0.15 replaced the
  `std.io` reader/writer types and 0.16 changed `main` to take
  `std.process.Init`.
- `curl`, to fetch the shader compiler on the first build.
- Targeting macOS additionally needs `git` and a C++ compiler. See
  [macOS](#macos).

SDL and FreeType are built from source by the Zig build system and linked
statically, so no system `-dev` packages are needed.

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
[OPTIMIZATIONS.md](OPTIMIZATIONS.md).

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

### The atlas

Every glyph is rasterized once at startup into a single-channel coverage
texture and packed onto shelves. Rasterizing is the expensive part of drawing a
glyph, and none of it happens per frame.

Entries are keyed by **`(character, subpixel offset)`**, not by character alone.
Proportional advances put glyph origins on fractional pixels, so each glyph is
rasterized at four horizontal offsets — quarter, half, three-quarter, whole — and
the pen's fractional part chooses between them. The quad itself always lands on
whole pixels; only the coverage inside it shifts. Sampling is `NEAREST`, because
a quad is sized to its source rectangle and every sample lands on a texel centre,
so interpolation has nothing left to do but soften what it touches.

Four offsets rather than more: the atlas grows linearly in that number, and past
a quarter of a pixel the difference stops being visible.

## Layout

```
src/
  main.zig      # SDL setup, the window, the event loop, the document
  renderer.zig  # GPU device, glyph atlas, drawing
  config.zig    # font file and size
assets/
  DejaVuSans.ttf
  shaders/
```

`config.zig` holds the settings that get changed while working on the editor —
the font file and its rasterisation size. `build.zig` imports it too, so the
font path is stated once and the build embeds the file it names.

`renderer.zig` owns the SDL `@cImport` and `main.zig` takes its SDL types from
there. Two `@cImport` blocks that differ by so much as whitespace generate two
unrelated sets of types, and a `*SDL_Window` from one will not pass as a
`*SDL_Window` to the other.

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
