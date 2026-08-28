# yaz

A text editor. The point of it is **low latency, low resource usage, and high
performance** — not feature count. When a tradeoff comes up, that is the tiebreak.

## Working rules

### Ask before deciding where things go

You do not know where to put what better than I do. File placement, project
structure, naming, and when to split a file are my calls, not yours. Ask.

The layout is deliberately flat: everything lives in `src/main.zig` until I say
otherwise. Do not create subdirectories or split files on your own initiative.

### Small commits, one per feature

Tidy history is a must.

- One commit per feature. Not per session, not per file.
- Plain imperative subjects: `Add glyph atlas`, `Fix cursor hit-testing`.
  No `feat:`/`chore:` prefixes.
- No `wip`, no `fix typo`, no `address review comments` commits. Squash them
  into the commit they belong to before they land.
- Each commit builds and passes `zig build test` on its own.
- No trailers. No `Co-Authored-By`, no session links, no tool attribution.
  The commit message is the message.
