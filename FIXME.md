# FIXME

Known problems, written down when found rather than when fixed. Each one says
what is wrong, why it has been left alone, and what would settle it.

Nothing here is urgent. Neither entry below has been observed: the first is
reasoned from what the atlas costs at a scale nobody here has run it at, and the
second from reading SDL's headers, so the first step for each is to find out
whether it is real.

---

## The atlas is sized by platform, but filled by density

**Where:** `src/glyph_atlas.zig`, `atlas_width`.

2048 square on macOS and 1024 elsewhere, chosen from the target at build time.
What decides how fast it fills is the display scale: a glyph at twice the size
takes four times the area. The proxy holds on macOS, where every Mac is Retina.

It does not hold on Windows, which offers 125% through 200% on hardware that may
or may not be dense and gets the smaller texture at all of them. At 200% on a 4K
panel the ceiling is near 125 distinct glyphs rather than 500, and running out
panics rather than degrading.

**Left alone because** a page of English is nowhere near either ceiling, so only
a CJK document reaches it -- and that wants eviction rather than a bigger number.
Sizing from the scale at runtime would also mean reallocating the texture on a
rebuild, which is the one thing a rescale does not currently have to do.

**To assess:** run on Windows at 200% and type until it panics; the message
names how many glyphs were in.

**Likely fix:** size the texture from the scale rather than the target, and
reallocate it when a rescale needs a different size. The rebuild path in
`GlyphAtlas.setScale` is where that would go -- it already gives up every slot,
so the only thing it would add is a new texture.

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
