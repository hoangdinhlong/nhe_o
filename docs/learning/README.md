# Learning

A teaching corpus that explains the **concepts behind this project's decisions**, in plain language
with concrete examples. Lessons make knowledge durable: easy to re-learn after time away, useful for
interview prep, and friendly to anyone who clones the project to learn by doing.

## How this relates to the other docs

| Doc | Role | Voice |
|-----|------|-------|
| `../DECISIONS.md` (ADR) | **Records** a decision — what & why (terse, authoritative) | concise |
| `../reference/*` | The current map & destination | reference |
| **`learning/`** | **Teaches** the concept behind a decision | beginner-friendly, examples |

> **Rule:** the ADR is the source of truth for a *decision*; a lesson teaches the *concept*. Lessons
> link to ADRs; ADRs may link to lessons. If they disagree, the **ADR wins** — lessons are
> educational, not specification.

## Structure

- `swe/` — software engineering lessons.
- `ai/` — AI lessons.
- Cross-cutting (e.g. AI × SWE) topics live in whichever bucket dominates, with a `Tags:` line and a
  cross-link — no third folder, to keep the tree simple.
- `_TEMPLATE.md` — copy this to start a new lesson.

## Index

### swe/
- _(none yet)_

### ai/
- _(none yet)_

## Writing a lesson

Copy `_TEMPLATE.md`, emphasize *meaning* (understanding *why*, not just *what*), prefer examples
from this project, and end with a few self-check questions (interview-style).
