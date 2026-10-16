# Epics

**Committed work, broken into shippable chunks.** An epic is a body of work the project has decided
to do — it delivers one observable capability and has a definition of done. Work that isn't
committed yet doesn't belong here: it lives in `../ideas/` until it graduates.

## Conventions

- One folder per epic: `NN-<slug>/` (`01-`, `02-`, … — the number is the intended order, not a hard
  dependency).
- Each folder holds a `PROGRESS.md`, copied from `_TEMPLATE/PROGRESS.md`.
- Keep the **Tests** column current as tasks land — it's what tells a future session whether a
  "done" task was actually verified.

## Creating an epic

1. Copy `_TEMPLATE/` to `NN-<slug>/`.
2. Fill in the goal and the definition of done, then list the tasks.
3. Register the epic in `../STATUS.md` → **Epic overview**, so a session that starts at `STATUS.md`
   can find it.

An epic usually starts life as an accepted ADR in `../DECISIONS.md` (the *why* and the *what*) —
the epic is then the *how* and the *how far along*.

## Where the index lives

The list of epics and their status lives in **`../STATUS.md`**, not here — one role per doc, no
overlap. This file explains the *conventions*; `STATUS.md` reports the *state*.

## Status legend

Inside `PROGRESS.md` (per task): ☐ todo · ◐ in progress · ☑ done
Inside `STATUS.md` (per epic): 🚧 Active · ⏳ Planned · ✅ Done
