# Ideas

A parking lot for **pre-decision ideas** — appealing directions worth capturing so the thinking
isn't lost, but **not committed to building yet**. An idea here may never happen; that's fine.

## What belongs here (and what doesn't)

| | `ideas/` | ADR *(proposed)* in `../DECISIONS.md` |
|---|---|---|
| What | an idea being **explored**; may never ship | a concrete decision **about to be committed** |
| Bar to add | low — capture it before it's lost | high — a specific choice with rationale |
| Content | pitch, why appealing, design considerations, open questions | "we choose X, because Y, consequences Z" |
| Lifecycle | `Exploring` → `Promoted → ADR-x` / `Dropped` | `proposed` → `accepted` |

> **Lifecycle rule:** an idea **graduates** into an ADR + epic (+ catalog entry) *when we decide to
> build it*. Then set its status to `Promoted → ADR-xxx` (or `Dropped`). This keeps `ideas/` a
> snapshot of what's *under consideration*, never competing with `DECISIONS.md` (authoritative for
> what's *decided*).

Every idea carries a **Status**: `Exploring` · `Promoted → ADR-xxx` · `Dropped`.

## Conventions

- One file per idea: `NNNN-short-slug.md` (4-digit id, never reused).
- Copy `_TEMPLATE.md` to start.

## Index

| ID | Idea | Status |
|----|------|--------|
| _(none yet)_ | | |
