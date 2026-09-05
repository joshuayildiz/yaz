# Handoff: acme view (columns & rows), continued

Scratch note for picking this up on another machine. Delete when done. Reads
against `CLAUDE.md` (comment bar, one commit per feature, no trailers, ask before
new files/placement).

## Where it stands (green: `zig build && zig build test`, 158 pass / 1 skip)

Two views, switchable at runtime with **cmd+E** (`Message.toggle_view`):
- **sublime** — the original tab bar + row of columns (unchanged).
- **acme** — columns of stacked file windows, each a tag line over a body.

Commits this session for the acme work:
- `12c612c` — the toggle + the acme layout (Stage 1).
- `97549ef` — `New`/`Del` tag buttons (Stage 2a).

## Architecture (how the two views coexist)

- `model.files` is the shared set of open documents. Each view has its own layout
  state over it; `model.view: View` says which is live.
- **sublime** state: `model.columns` (`[]*OpenFile`, shown files) + `preview` +
  the tab bar. Left untouched while acme is live, so a toggle finds it as it was.
- **acme** state: `model.acme: []Column`, `Column { panes: []*OpenFile, rect }`.
  Every open file is a pane (no hidden files). `model.acme_tags: [2]LineLayout`
  are the shaped `New`/`Del` labels (so `place` draws them and hit-testing sizes
  the boxes).
- **The unifying trick**: `model.column(i)`, `windowCount()`, `columnOf()`,
  `showing()`, `onScreen()`, and `columnAt()` are all **view-aware** — sublime
  reads `columns`, acme walks `acme` panes in column-major order. So the
  column-indexed messages (`.caret{column}`, `.insert{column}`, …) address a
  window the same way in both views, and typing/click/caret/scroll are shared.
  `model.focus` is the flat window index in whichever view is live.
- `file.rect` is the window body rect, written by the live view's `place`; that's
  how `TextView` and hit-testing find a window. `switchView` resets `focus`/
  `holding`; entering acme calls `layOutAcme` (rebuild panes from `files`, ≤2
  equal columns).

Files: `model.zig` (state, `update`, `resolve`, accessors, `switchView`/
`layOutAcme`/`acmeNew`/`acmeDel`), `components/columns.zig` (acme `place`/`draw`
+ `Columns.button` hit-test), `components/editor.zig` (dispatch `place`/`draw` by
`model.view`), `message.zig` (`toggle_view`, `acme_new`, `acme_del`).

Decisions already made (don't re-ask): full acme (no hidden files); mouse
gestures for arranging; editable command tags are Stage 3; acme code lives in
`components/columns.zig`; toggle is cmd+E.

## Remaining work

Ordered as recommended. Each should stay green and be its own commit.

### Newcol / Delcol (small)
- Add `New`col and `Del`col buttons to the column header (more entries in
  `acme_tags`, more boxes in `Columns.button`).
- `acmeNewcol(after)`: `self.acme.insert(after+1, .{})` (empty column).
- `acmeDelcol(col)`: close every file in the column, remove the column, keep ≥1
  window (mirror `acmeDel`'s guards). Scrub each file from both views before
  freeing (as `acmeDel` does).

### Resize by dragging (medium — headline gesture)
- Add weights: `Column { width: f32 }` and make a pane carry a height, i.e.
  `Pane { file: *OpenFile, height: f32 }` and `Column.panes: []Pane`. Update
  everything that walks panes: `column()`, `windowCount()`, `columns.zig` `place`
  (split by normalized weights instead of equal), `layOutAcme`, `acmeNew`,
  `acmeDel`.
- Add an **acme drag mode** distinct from the text-selection drag (`file.drag`):
  e.g. `model.acme_drag: ?union(enum){ col_edge: usize, win_edge: struct{col,row} }`.
  In `resolve`: a press near a column boundary / a window's tag top edge starts
  the drag; `.move` adjusts the two adjacent weights from the pointer delta;
  `.release` ends it. These need their own resolved messages
  (`.acme_resize_col`, `.acme_resize_win`) or handle inline via the drag state.
- `resolve`'s `.move`/`.release` currently route to the holding column for text
  drags — branch on the acme drag mode first.

### Move by dragging (larger)
- Drag a window's tag (a drag-box) to another column or to reorder within one.
  Needs drag state (which pane) + drop-target hit-testing on release, then
  splice the pane out of one column and into another at the drop row.

### Stage 3 — editable command tags (a project of its own)
- Tags become editable text; button-2 runs the words as commands (New, Del,
  Snarf, Look, Edit, …). Big; separate effort.

## Gotchas
- `model.files` is shared: any close must scrub the file from `columns` **and**
  `acme` panes and `preview` before `close()` frees it (see `acmeDel`).
- `focus` is a flat index into the *live* view; `switchView` resets it.
- `file.tab_rect` is stale in acme; `resolve` guards the tab hit-test to sublime.
- Comment bar in `CLAUDE.md` applies to new code.
- Not verified in the GUI this session — only `zig build` + tests. Run it and
  sanity-check acme's metrics/feel (tag height, `tag_pad`, column split).
