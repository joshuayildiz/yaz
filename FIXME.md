# FIXME

Known problems, written down when found rather than when fixed. Each one says
what is wrong, why it has been left alone, and what would settle it.

The first entry below is real and reproducible. The other two have not been
observed: one is reasoned from what the atlas costs at a scale nobody here has
run it at, the other from reading SDL's headers, so the first step for each is
to find out whether it is real.

---

## Edits can hide in a file that is not on screen

**Where:** `src/main.zig`, `App.park`.

There is still no way to save, and a document now survives being looked away
from. Together those mean typing into a file, opening another, and losing the
first edit on close without ever seeing a sign of it. Before documents were
parked the edit died at the switch, which was worse but at least visible.

Nothing anywhere says a parked file has been changed. The finder lists paths and
the window titles the first one, and neither knows the difference between a file
as it is on disk and a file with an hour of typing in it.

**Left alone because** the answer is saving, not a warning about not saving.
Marking modified files would be work thrown away the moment writing to disk
exists, and a warning that a file cannot be saved is not much of a warning.

**To assess:** type into a file, open another through the finder, and close the
window. Nothing asks, and nothing is written.

**Likely fix:** writing to disk, which is what the README already says is
missing. Once a document can be saved, a modified flag on it has somewhere to
be shown -- the finder's rows and the window title are both already built out of
per-file information.

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
