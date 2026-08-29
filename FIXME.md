# FIXME

Known problems, written down when found rather than when fixed. Each one says
what is wrong, why it has been left alone, and what would settle it.

Nothing here is urgent. Both entries below are macOS-specific and neither has
been observed — they come from reading SDL's headers and its documented
behaviour, so the first step for each is to find out whether it is real.

---

## Retina displays will undo the pixel alignment

**Where:** `src/main.zig`, `SDL_CreateWindow`.

The window is created without `SDL_WINDOW_HIGH_PIXEL_DENSITY`. On a high density
display macOS then gives the window a 1x backing store and the compositor scales
it up to fit the physical pixels.

That is a problem for this program specifically. Glyph quads are placed on whole
pixels and rasterised at four subpixel offsets so that stems land exactly on the
pixel grid; scaling the finished frame resamples all of it. The expected symptom
is text that looks soft and roughly half the intended physical size.

**Left alone because** the flag is the small part. Setting it means window
coordinates and pixels stop being the same number, and every place that treats
them as interchangeable has to be found: the viewport, the pen origin, the
baseline step, the caret, and hit-testing. That is worth doing once, after the
layout code exists, rather than twice.

Hit-testing has since joined that list and is the clearest instance of it.
`SDL_EVENT_MOUSE_BUTTON_DOWN` reports window coordinates, and
`TextView.moveCaretTo` compares them against a layout placed in pixels. On every
display those two are the same number, and on a Retina one they differ by the
scale factor, so clicks would land at half the distance from the origin they
should. Scaling by `SDL_GetWindowPixelDensity` at the call site would paper over
it and would be one more place to find later; the fix is the audit, not the
patch.

**To assess:** run on a Retina Mac and compare a nearest-neighbour zoom of a
stem against the same text on Windows. Hard-edged means the assumption held;
a soft gradient means it did not.

**Likely fix:** add `SDL_WINDOW_HIGH_PIXEL_DENSITY`, keep using the pixel size
that `SDL_WaitAndAcquireGPUSwapchainTexture` already reports, and audit
everything that mixes the two coordinate systems. SDL's documentation adds that
macOS also wants `NSHighResolutionCapable` set in the Info.plist, which this
program does not currently have — there is no bundle, only a bare executable.

---

## The resize watch may run off the main thread

**Where:** `src/main.zig`, `redrawWhileResizing`.

Redrawing during a resize happens from an `SDL_AddEventWatch` callback, because
the platform's modal resize loop does not return until the drag ends. SDL's
header warns: "Be very careful of what you do in the event filter function, as
it may run in a different thread!"

The callback submits GPU work. On Windows it runs on the thread that pumps
messages, which is the main thread, so this is fine there. Whether macOS pushes
window events from the same thread has not been checked.

If it does not, the bug is a correctness one rather than a slow one, and it will
not look like a performance problem: expect a crash, a Metal validation failure,
or corrupted drawing during a resize, not a low frame rate.

**Left alone because** it may well not be real, and the mitigation depends on
what is actually happening. Guessing at a fix would add a thread hop to a path
that may not need one.

**To assess:** log `SDL_GetCurrentThreadID()` from the watch and from `main`,
resize the window on macOS, and compare. A Debug build is the one to use, since
Metal's validation layer is what would catch a misuse.

**Likely fix, if real:** have the watch hand the redraw to the main thread and
wait for it, or drive the resize redraw from a platform-specific callback rather
than the event watch. Which of those is right depends on whether the main thread
is reachable at all while the modal loop owns it — if it is not, neither works
and the answer is a display link or a redraw timer for the duration of the drag.
