# Optimizations

What has been done for latency and resource usage, why, and — since each one
leans on some assumption about the platform — how to check it still holds.

Numbers come from Windows on an RTX 3090 unless stated otherwise. macOS has run
all of this on an M2, and one of them — 6 — has been checked there; the rest are
still unmeasured on it. What is left to settle is in [FIXME.md](FIXME.md).

## Where each one stands

| # | Optimization | Linux | Windows | macOS |
| --- | --- | --- | --- | --- |
| 1 | [Idle costs nothing](#1-idle-costs-nothing) | runs | measured | runs |
| 2 | [Redraw only on change](#2-redraw-only-on-change) | runs | measured | runs |
| 3 | [One frame per burst](#3-one-frame-per-burst) | runs | measured | runs |
| 4 | [Drawing during a resize](#4-drawing-during-a-resize) | n/a | measured | **unverified** |
| 5 | [Rasterise once, not per frame](#5-rasterise-once-not-per-frame) | runs | runs | runs |
| 6 | [Pixel-aligned quads](#6-pixel-aligned-quads-nearest-sampling) | runs | measured | measured |
| 7 | [Shader format fixed at build time](#7-shader-format-fixed-at-build-time) | runs | runs | runs |
| 8 | [No font discovery](#8-no-font-discovery) | runs | runs | runs |
| 9 | [One call for the text](#9-one-draw-call-for-the-text) | runs | runs | measured |
| 10 | [Per-line layout cache](#10-per-line-layout-cache) | runs | runs | runs |
| 11 | [Only the lines on screen](#11-only-the-lines-on-screen) | runs | runs | measured |

"runs" means the build starts and draws, not that anything was measured.
"measured" means the numbers below were taken on that platform.

Row 4 is unverified because the check for it is a live resize drag, which has to
be done by hand; everything else here has at least been run on an M2.

## 1. Idle costs nothing

The loop blocks in `SDL_WaitEvent`. There is no frame timer and no poll loop, so
a window nobody is touching does no work at all.

**Rests on:** SDL genuinely blocking rather than spinning on the platform's
event source.

**Check:** leave it alone for ten seconds and read CPU from
`top -pid $(pgrep yaz)`. It should be 0.0%, not 0.3%.

## 2. Redraw only on change

Waking up is not a reason to draw. Mouse motion produces a stream of events that
alter no pixel, so the loop tracks whether anything changed and skips the frame
otherwise.

Windows, four seconds of continuous mouse movement over the window:

| | redraws | CPU |
| --- | --- | --- |
| drawing on every event | 271 | 31–62 ms |
| drawing on change | 3 | 0–16 ms |

**Rests on:** mouse motion arriving as ordinary events that the loop can ignore.
If macOS delivers something that gets marked dirty — or delivers exposure events
continuously — the saving disappears.

Motion is read in one case: while the pointer is holding the scrollbar's thumb,
where a redraw per event is the point rather than the waste. Nothing else looks
at it.

**Check:** the counter patch in [Counting redraws](#counting-redraws), then move
the mouse over the window for a few seconds. Expect a redraw count in the low
single digits, not one per motion event.

## 3. One frame per burst

After the blocking wait returns, the loop drains the queue with `SDL_PollEvent`
and folds everything already waiting into the same frame.

This is about latency more than work. Presenting blocks on the swapchain, so a
redundant redraw costs a vsync; a burst of them would put a keystroke behind
several frames of drawing content that had not moved.

**Rests on:** nothing platform-specific. Listed because it is the mechanism that
bounds input latency. The number that would prove it, keystroke to photon, has
not been taken.

**Check:** covered by 2's redraw count. A count that tracks the event count means
the drain is not working.

## 4. Drawing during a resize

Windows and macOS both run a modal loop of their own while a window is being
resized, and it does not hand control back until the drag ends. A main loop in
`SDL_WaitEvent` never gets to redraw, so the window keeps the last frame and the
area it grew into stays blank. yaz draws from an `SDL_AddEventWatch` callback
instead, which SDL runs as events are pushed — from inside that modal loop.

**Rests on:** macOS behaving like Windows here. macOS enters
`NSEventTrackingRunLoopMode` during a live resize, and the watch is the
documented cross-platform answer, but that is reasoning rather than evidence.

**Check:** drag a corner slowly outward and watch the area being revealed. Text
should fill it as it grows. A strip of flat background trailing the edge is the
layer's own colour showing through before a frame lands, which is expected and is
6's business; a strip that stays empty until the mouse is released is not, and
means the watch is not firing on macOS and this needs a different mechanism.

On macOS the strip is flat background rather than stretched text because the
layer's `contentsGravity` is `kCAGravityTopLeft`, and it is the theme's
background rather than black because the layer is given a background colour to
match. Both are set in `sdl.zig`. Before either, a resize stretched the previous
frame over the new bounds instead, which on proportional text read as the glyphs
changing width.

**Also check:** the watch may run on a thread other than the one that owns the
GPU work. See [FIXME.md](FIXME.md).

## 5. Rasterise once, not per frame

A glyph is rasterised the first time it is asked for and kept. Shaping decides
what exists, so the atlas cannot be filled ahead of time, but a glyph is
rasterised once however often it is drawn. A redraw that shapes nothing new
uploads nothing and allocates nothing.

**Rests on:** nothing platform-specific.

**Check:** RSS flat while the window redraws, and no transfer in a steady-state
frame. `heaptrack` or Instruments' allocations template.

## 6. Pixel-aligned quads, nearest sampling

Glyph quads are positioned and sized in pixels, and land on whole pixels; the
fractional part of the pen position picks between four subpixel rasterisations
of the glyph rather than moving the quad. Because a quad is exactly the size of
its source rectangle, every sample lands on a texel centre, so the sampler is
`NEAREST` — interpolation would only soften what it touches.

**Rests on:** SDL_GPU normalising clip space and texture coordinate origins the
same way on Metal as on Vulkan. The shader assumes NDC with a lower-left origin
and texture coordinates with an upper-left one, and corrects for exactly that
once. If Metal differs, glyphs land half a pixel off and go soft, or the atlas
comes out upside down.

**Check:** screenshot the window on macOS, zoom in on a stem with nearest-
neighbour magnification, and compare it against the same text on Windows. Stems
should be hard-edged, one or two columns wide, not a three-column gradient.

**Measured:** on an M2 Retina display, stems came back as a three-column
gradient — the window was created without `SDL_WINDOW_HIGH_PIXEL_DENSITY`, so a
1024x768 back buffer was being scaled onto 2048x1536 physical pixels and the
alignment above was resampled away. With the flag, and the layout scaled to
match, the same stems are hard-edged. Metal's origins agree with Vulkan's; the
softness was the back buffer, not the shader.

## 7. Shader format fixed at build time

The build compiles shaders to exactly one bytecode format, chosen from the
target, and the program requests that format when creating the device. There is
no runtime probe, and no unused bytecode in the binary. It also pins the
backend, since SDL can only pick one that accepts the format.

**Rests on:** the target's format being the right one. macOS gets MSL and
therefore Metal.

**Check:** the startup log says `gpu backend: metal on <device>`. Anything else
means the format and the backend have come apart.

## 8. No font discovery

The font is embedded in the binary and read from memory. There is no font
matching, no fontconfig, and on macOS no CoreText involvement, so startup does
not touch the system font stack at all.

**Rests on:** nothing platform-specific.

**Check:** the startup log appears immediately. A pause before the window
suggests something is scanning fonts, which would mean SDL is doing it, not us.

## 9. One draw call for the text

Every glyph is one instance of a four-vertex triangle strip, and the screenful is
a single `SDL_DrawGPUPrimitives`. Nothing is sent per glyph: where each lands,
what to sample and how big it is come out of a storage buffer the vertex shader
indexes by `gl_InstanceIndex`.

Components add quads to a painter under a key -- a layer, a pipeline and a colour
-- and `present` sorts by it, so one call covers every quad wanting the same
thing however many components produced them. A frame is three keys today, and
would still be three with a hundred text views.

**Rests on:** `first_instance` reaching the shader through `gl_InstanceIndex` on
Metal as it does on Vulkan. Metal's `[[instance_id]]` counts from zero whatever
the base instance is, so the translation has to add it back; if it does not, the
caret's draw recolours the first glyph on screen and leaves the caret alone.

**Check:** set `caret_colour` to something loud and look at the first character
on the first line. Only the caret should change. Done on an M2: it did.

Draw calls are not where a frame goes, and this is not here for speed. Measured
over 2000 calls on an M2, generating every quad of a screenful -- 2282 of them --
costs 4.5us, or 0.03% of a frame at 60Hz, in Debug and ReleaseFast alike. The
shaping that would be expensive is already cached per line, so a redraw only
copies. Batching is for keeping the number of calls flat as components are added,
not for saving time there is none of.

## 10. Per-line layout cache

Shaping depends only on a line's bytes, so it is done once and kept. A keystroke
reshapes the line it landed in; every other line is placed by adding an origin to
coordinates it already had.

**Rests on:** the origin being whole pixels, which is 6's business — a fractional
one would change which subpixel variant each cached glyph points at.

**Check:** `TextView.layout` asserts its `x` is rounded, and the cache asserts
its length against the document's line count every frame. Run a Debug build.

## 11. Only the lines on screen

`layout` places the lines that intersect the window and stops. A line below it is
not placed and, more to the point, is not shaped: `visibleCount` bounds the loop
and the existing `if (!entry.shaped)` does the rest.

Opening a 5000-line file, measured on an M2 by disabling the bound in an
otherwise identical binary:

| | lines shaped | sprites | first frame |
| --- | --- | --- | --- |
| every line | 5001 | 211,142 | 2076, 2202, 2052 ms |
| on screen only | 51 | 2,281 | 127, 151, 115 ms |

**Rests on:** the window's pixel height, read each redraw from
`SDL_GetWindowSizeInPixels` rather than the swapchain, which is not acquired
until `present`. The two can disagree for one frame during a live resize, which
is one line too many or too few for that frame.

The caret is the exception the bound has to make: its line is shaped and its quad
built even when it is below the window, since `present` draws one unconditionally.

**Check:** shrink the window and count what is drawn -- 1536 pixels of height
gives 51 lines and 600 gives 20, at the current size. Then hold Return past the
bottom of the window in a Debug build: the caret leaves the drawn range, and
nothing asserts.

Scrolling rests on this too, and on the offset being whole pixels. `layout`
asserts that; the symptom if it ever stops holding is text that shimmers rather
than moves. Checked by scrolling a pixel at a time and comparing frames: at 1, 2
and 30 pixels the image is the one before it translated by exactly that much.

## 12. Resolving the tool paths once

Startup spawns `rg --version` and `fzf --version` to check both tools work, and
that check is on the path to the first frame. Measured on an M2, it cost
**26.5ms** -- and only 11ms of that was the two spawns.

The other 15.5ms was ours. `path` asked the environment for `HOME` through
`Environ.getAlloc`, which builds a hash map of the whole environment before
answering, and it was called once per tool: **7.8ms a call**. Asking once, and
through `getPosix` -- a scan of the environment block rather than a map of it --
took the whole check to **11ms**.

What is left is process creation for two statically linked binaries of 4MB and
4.8MB, and it does not move: ReleaseFast measures 12-13ms, the same as Debug,
because none of it is our code. A shell doing the same two spawns takes 8.8ms.

**Rests on:** `getPosix` being implemented on the host. It is not on Windows,
which still pays for `getAlloc` -- once now, rather than twice.

**Check:** time `tools.missing` around the call. Anything near 26ms means the
per-tool path lookup is back.

## 13. Keeping a file that was looked away from

Switching files used to free the document and read the file again on the way
back, which threw away a gap buffer, a line index, and every line already
shaped, to buy nothing. `App` keeps it instead, by path, and hands it straight
back.

Measured on an M2: a first visit is **1240us**, a return **95us**, and the
return reshapes **0 lines** where the first visit shaped 51. A document is in
exactly one view or parked, never both, so nothing has to be kept in step.

**Costs memory, and is not bounded.** Nine files of this codebase -- 5050 lines
-- park in about 520KB: 205KB of text and 315KB of cache entries, at 64 bytes a
line whether or not that line was ever drawn, plus the sprites of the ones that
were. A session that visits a hundred files would hold a few MB.

**Check:** count `shapeLine` calls across a return trip. Anything above zero
means the document is being rebuilt rather than handed back.

## Not optimizations yet

Stated so they are not mistaken for finished work:

- **Nothing evicts a parked document.** Every file visited stays in memory for
  the life of the window. Fine for a working set of a few dozen files; a cap
  would be the fix if it stops being.
- **Startup pays ~11ms to spawn both tools.** The check is that they *run*,
  which is what catches a truncated download or a wrong-architecture binary --
  a stat would pass both. Recording the result and re-checking only when the
  file changes would make it nearly free after the first launch.
- **The whole window redraws.** There is no damage tracking, so a one-character
  edit will repaint everything.
- **Blending is done on sRGB-encoded values**, not in linear light. With the
  dark-on-light theme this makes text render slightly lighter than it should;
  it was slightly heavier when the theme was the other way up, and the error
  changes sign with the theme rather than going away. Universal, and cheap to
  fix later.

## Measuring on macOS

### Counting redraws

Nothing counts redraws in the shipped code. Add this to `src/main.zig`, measure,
and take it back out — it is not meant to be committed:

```zig
var redraws: usize = 0;                     // near the imports

        if (dirty) {
            redraws += 1;                   // in the main loop
            try app.redraw();
            dirty = false;
        }

        redraws += 1;                       // in redrawWhileResizing
        app.redraw() catch {};

    std.log.info("redraws: {d}", .{redraws});   // before the loop's last brace
```

Then run it, exercise whatever is being measured, close the window, and read the
count off stderr.

### CPU

```sh
top -pid $(pgrep yaz) -stats cpu -l 4
```

Four seconds of continuous mouse movement over the window is the comparison used
above. Idle should be 0.0%.

### The reference numbers

Windows, ReleaseFast, RTX 3090, 1024x768 window, four seconds of scripted mouse
movement across the window at roughly 64 moves per second:

```
redraws on every event : 271, 270, 273      cpu 31.2, 62.5, 46.9 ms
redraws on change      :   3,   3,   3      cpu 15.6,  0.0,  0.0 ms
idle, four seconds     :                    cpu  0.0 ms
```

Take the macOS numbers the same way, on a build made with `-Doptimize=ReleaseFast`.
Absolute CPU will differ; the ratio between the two rows is the thing to compare.
