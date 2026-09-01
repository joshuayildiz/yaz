# FIXME

Known problems, written down when found rather than when fixed. Each one says
what is wrong, why it has been left alone, and what would settle it.

The first entry below is real and reproducible, and is what is left of one that
has otherwise been fixed. The other two have not been observed: one is reasoned
from what the atlas costs at a scale nobody here has run it at, the other from
reading SDL's headers, so the first step for each is to find out whether it is
real.

---

## Nothing warns before an edit is thrown away

**Where:** `src/model.zig`, `Model.shut`, and `run`'s loop in `src/main.zig`.

cmd+S writes a file back, so an edit can now be kept. Nothing makes you keep it.
cmd+W closes a file and frees its document whether or not the tab says it has
been changed, and closes the window once the bar is empty; so does the window's
own close button. Neither asks, and neither looks at `OpenFile.modified`.

What that used to mean was that the edit was unkeepable. It is now merely
unasked-for: the mark on the tab says which files would go, and a save is one
keystroke, so the loss is both visible and avoidable the whole time.

**Left alone because** the answer is a prompt, and a prompt is a modal surface
this has none of yet -- something to draw, something to give the keyboard to, and
a third answer besides yes and no. The flag it would read is already right.

**To assess:** type into a file and press cmd+W. It goes, and nothing was asked.

**Likely fix:** `Model.shut` and the quit path both consult `modified` and put a
panel up when it is set. `components/healthcheck.zig` is the nearest thing to the
surface that would need, being a card over an otherwise empty window.

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
