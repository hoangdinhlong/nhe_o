# AGENTS — How AI agents start and finish work in Nhé O

## Working language

- **Conversation with the owner: Vietnamese.**
- **All written artifacts: English.** Docs, code, comments, commit messages, ADRs, and
  lessons are written in English for consistency and open-sourcing.

So: talk to the owner in Vietnamese, but write everything that lands in the repo in
English.

## Start of a session

Read `docs/STATUS.md` first to learn where the project stands, which epic is active, and the
next task. For the overarching multi-crate roadmap across the Ouronic ecosystem (`nhe_o`, `mofia`,
`ee_json`, `ee_http`, `mc3`, `ouronic_alembic`), also consult the ecosystem umbrella at
[`../ouronic_meta/docs/STATUS.md`](../ouronic_meta/docs/STATUS.md) and
[`../ouronic_meta/docs/reference/ARCHITECTURE.md`](../ouronic_meta/docs/reference/ARCHITECTURE.md).

## After completing a task — update these docs (in order)

1. Update the active epic's `docs/epics/<epic>/PROGRESS.md` (task status + the Tests column).
2. Update the Epic Overview table in `docs/STATUS.md` if progress changed.
3. Update Known Issues / Blockers in `docs/STATUS.md` if discovered or fixed.
4. If a non-trivial **technical** decision was made, append a concise ADR to `docs/DECISIONS.md`.
   Do **not** record cosmetic/housekeeping churn (renames, directory moves) — see the note at the
   top of `DECISIONS.md`. The owner decides when an exception applies.
5. **If business rules or formulas were introduced or modified**, update or create the corresponding
   document in `docs/domain/` and index it in `docs/domain/business-rules.md`. Never let the code
   diverge from documented domain rules.
6. **If the session raised a question you cannot answer yourself** — one that needs a stakeholder,
   real data, or an experiment — file it in `docs/OPEN-QUESTIONS.md`, and state what it blocks in
   its **Impact** field. When an open question does get answered, mark it `Answered` and point to
   where the answer now lives (an ADR, a domain doc, an epic task). Do not delete it.
7. **Propose lessons — proactively, without being asked.** At the end of any session that made a
   non-trivial design decision or taught a generalizable concept, propose a short list of lessons to
   add or extend under `docs/learning/` (title + one-line rationale + bucket `swe`/`ai`). Then write
   the ones the owner approves.

## Before ending the session

Run the checklist in `docs/_meta/SELF-AUDIT.md` and report its three lines. It is short, and it is
the only thing standing between "self-maintaining docs" and docs that quietly rot.

## Ideas

When an appealing but not-yet-committed idea arises, file it under `docs/ideas/` (not
`DECISIONS.md`). It graduates into an ADR + epic when you commit to building it.

## Epic cadence: Feature Epic → Grooming Epic

Every **Feature Epic** (or group of feature epics) must be followed by a dedicated **Grooming & Hardening Epic** before starting the next major feature epic:
1. Run an adversarial audit (`ADVERSARIAL-REVIEW.md`) across all specs, bodies, FFI boundaries, and docs landed in the preceding feature epic(s).
2. Remediate all Critical, High, Medium, and Low findings (functional edge cases, persistence gaps, contract strength, build hygiene, and doc drift).
3. Resolve open questions (`docs/OPEN-QUESTIONS.md`) surfaced during the audit and re-verify `gnatprove` (`0 unproved` checks, `0 warnings`) before advancing to the next feature epic.

## CPU parallelism for builds and formal proofs (`gnatprove` / `gprbuild`)

- Before invoking `gnatprove` or heavy build/verification commands (directly or via a subagent), **inspect the current CPU core count and system load** (e.g., `nproc`, `uptime` / `/proc/loadavg`).
- Set the thread count (`-j<N>`) appropriately for the available CPU capacity, and **always use at least 16 threads (`-j16` minimum; `-j0` or `-j24`..`-j32` on this 32-thread workstation when idle)**. Never throttle `gnatprove` to low thread counts like `-j2` or `-j4`, and explicitly enforce this rule in every subagent prompt.

## Upstream Algorithmic Reference & Gap Analysis (ouronic_alembic)

Ouronic adopts a strict pre-implementation distillation architecture: complex data structures, protocols, and algorithms must be distilled into language-agnostic, edge-case-hardened specifications inside **Ouronic Alembic (`ouronic_alembic`)** before implementation or enhancement.

### Upstream Anchors
- **Upstream Domain Index**: [`../ouronic_alembic/docs/domains/dbms/INDEX.md`](../ouronic_alembic/docs/domains/dbms/INDEX.md)
- **Local Traceability Matrix**: [`docs/domain/alembic-traceability.md`](docs/domain/alembic-traceability.md)
- **Upstream Conservatory Root**: [`../ouronic_alembic/docs/domains/`](../ouronic_alembic/docs/domains/)

### Step-by-Step Discovery & Query Protocol
Whenever the owner or an agent investigates algorithms, missing features, unhandled edge cases, or optimization opportunities:
1. **Query the Upstream Master Index**: Inspect `../ouronic_alembic/docs/domains/dbms/INDEX.md` to locate the target subsystem, the canonical algorithm identifier (`ALG-DBMS-*`), and the categorized edge-case checklist (`EC-*`).
2. **Consult the Local Traceability Matrix**: Open `docs/domain/alembic-traceability.md` to check the current implementation status:
   - `Implemented`: Verified with concrete source lines (`src/*.ad[sb]`).
   - `Partial / Improvable`: Implemented with simplified bounds or heuristics; note the documented enhancement opportunity.
   - `Missing`: Unimplemented upstream feature/algorithm/edge case; note target epic and priority.
   - `Omitted by Design`: Intentionally omitted due to architectural scope; cites governing `ADR-*`.
3. **Inspect Original Reference Code**: If investigating low-level mechanics, follow Section 4 source pointers (`repos/<repo>/<path>#Lstart-Lend`) in `ouronic_alembic` against pinned commit SHAs.
4. **Preserve Repository Purity**:
   - **Never** copy Ada/SPARK source code, compiler pragmas, or downstream crate names into `ouronic_alembic`.
   - Record gap analyses, implementation mappings, and enhancement roadmaps exclusively in this repository's `docs/domain/alembic-traceability.md`.

## Core rule


Reference docs are *not authoritative*. If work in a session contradicts a reference doc, the agent
must either (a) update the reference doc in the same session, or (b) append a note to
`docs/DECISIONS.md` explaining what supersedes it. Never silently work against a reference doc.

> These instructions are best-effort (model-followed), not mechanically enforced.

## Doc map

- `docs/STATUS.md` — entry point: current state, active epic, next tasks, known issues.
- `docs/DECISIONS.md` — ADR log: the authoritative record of technical decisions.
- `docs/OPEN-QUESTIONS.md` — what we still need answered; each entry names the decision it blocks.
- `docs/reference/VISION.md` — the north star (the "why").
- `docs/reference/ARCHITECTURE.md` — the technical map (the "how").
- `docs/domain/` — domain knowledge & business logic (rules, formulas, workflows).
- `docs/epics/` — committed work: conventions in `epics/README.md`, tasks in `<epic>/PROGRESS.md`.
- `docs/learning/` — teaching corpus (`swe/`, `ai/`) explaining the concepts behind decisions.
- `docs/ideas/` — pre-decision ideas (parking lot); an idea graduates to an ADR + epic when committed.
- `docs/_meta/SELF-AUDIT.md` — the end-of-session checklist; run it before you sign off.

## Template provenance

Scaffolded from Monion's `project-docs` archetype, revision **R8**.

To reconcile with a newer template, read `CHANGELOG.md` in that archetype, apply the **Migration**
note of every revision above this one, then update the stamp here and in
`<monion>/docs/PROJECTS.md`. A revision this project already satisfies its own way needs no change — say so
and move on.
