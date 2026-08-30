# Optimizations

What has been done for latency and resource usage, why, and — since each one
leans on some assumption about the platform — how to check it still holds.

Numbers come from Windows on an RTX 3090 unless stated otherwise. Nothing here
has been measured on macOS. Two of these are expected to need work when it is;
they are in [FIXME.md](FIXME.md).

## Where each one stands

| # | Optimization | Linux | Windows | macOS |
| --- | --- | --- | --- | --- |
| 1 | [Idle costs nothing](#1-idle-costs-nothing) | runs | measured | **unverified** |
| 2 | [Redraw only on change](#2-redraw-only-on-change) | runs | measured | **unverified** |
| 3 | [One frame per burst](#3-one-frame-per-burst) | runs | measured | **unverified** |
| 4 | [Drawing during a resize](#4-drawing-during-a-resize) | n/a | measured | **unverified** |
| 5 | [Rasterise once, not per frame](#5-rasterise-once-not-per-frame) | runs | runs | **unverified** |
| 6 | [Pixel-aligned quads](#6-pixel-aligned-quads-nearest-sampling) | runs | measured | **unverified** |
| 7 | [Shader format fixed at build time](#7-shader-format-fixed-at-build-time) | runs | runs | **unverified** |
| 8 | [No font discovery](#8-no-font-discovery) | runs | runs | **unverified** |

"runs" means the build starts and draws, not that anything was measured.
"measured" means the numbers below were taken on that platform.

A binary built for macOS was run on an Apple Silicon Mac once, at the point
where the program drew a single textured quad. Everything in this file landed
afterwards, so macOS has never run any of it.

## 1. Idle costs nothing

The loop blocks in `SDL_WaitEvent`. There is no frame timer and no poll loop, so
a window nobody is touching does no work at all.

**Rests on:** SDL genuinely blocking rather than spinning on the platform's
event source.

**Check:** start yaz, leave it alone for ten seconds, and look at CPU in
Activity Monitor or `top -pid $(pgrep yaz)`. It should be 0.0%, not 0.3%.

## 2. Redraw only on change

Waking up is not a reason to draw. Moving the mouse across the window produces a
stream of events, and none of them alter a pixel, so the loop tracks whether
anything actually changed and skips the frame otherwise.

Windows, four seconds of continuous mouse movement over the window:

| | redraws | CPU |
| --- | --- | --- |
| drawing on every event | 271 | 31–62 ms |
| drawing on change | 3 | 0–16 ms |

**Rests on:** mouse motion arriving as ordinary events that the loop can ignore.
If macOS delivers something that gets marked dirty — or delivers exposure events
continuously — the saving disappears.

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
bounds input latency, and because the number that would prove it — keystroke to
photon — cannot be taken until there is typing to measure.

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
and background should fill it as it grows. If it goes black or white until the
mouse is released, the watch is not firing on macOS and this needs a different
mechanism.

**Also check:** the watch may run on a thread other than the one that owns the
GPU work. See [FIXME.md](FIXME.md).

## 5. Rasterise once, not per frame

Every glyph is rasterised by FreeType at startup into one coverage texture.
Rasterising is the expensive part of drawing a glyph and none of it happens on
the frame path. Drawing a frame allocates nothing.

**Rests on:** nothing platform-specific.

**Check:** startup should stay well under a tenth of a second, and a redraw
should not allocate. `heaptrack`, Instruments' allocations template, or simply
watching RSS stay flat while the window redraws.

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

## Not optimizations yet

Stated so they are not mistaken for finished work:

- **One draw call per glyph.** Each glyph is a separate `SDL_DrawGPUPrimitives`
  with its own uniform push. Instancing collapses this to one call per frame;
  that is step 9.
- **No layout cache.** Advances are recomputed for every glyph of every line on
  every redraw. It does not show yet because there are three lines of text.
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
            try renderer.present(&sample_text);
            dirty = false;
        }

        redraws += 1;                       // in redrawWhileResizing
        renderer.present(&sample_text) catch {};

    std.log.info("redraws: {d}", .{redraws});   // last line of main
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
