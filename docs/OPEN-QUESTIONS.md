# Open Questions

Questions whose answers **shape or block the work**, and that are waiting on something outside this
session — a stakeholder, a vendor, a measurement, an experiment.

Ids are `Q-xxx`, never reused.

## What belongs here (and what doesn't)

| | `OPEN-QUESTIONS.md` | `ideas/` | `DECISIONS.md` |
|---|---|---|---|
| What | something we **need answered** | something we **might build** | something we **have decided** |
| Waiting on | an answer (a person, data, an experiment) | nothing — it's optional | nothing — it's settled |
| Resolves into | an ADR, an epic task, or a domain rule | an ADR + epic, or `Dropped` | — (authoritative) |

Questions that will be settled *inside* one epic stay in that epic's
`epics/<epic>/PROGRESS.md` → **Open questions**. Promote a question up to this file only when it
outlives the epic, blocks someone else, or needs an answer from outside the team.

Status: `Open` · `Answered → <where the answer now lives>` · `No longer relevant`

> An answered question is **not deleted** — record where its answer landed (an ADR, a domain doc, an
> epic task) and keep the entry as a trace of the reasoning. Track the **Opened** date: a question
> left open for weeks is rarely one that's hard to answer, it's usually one **nobody was assigned to
> go ask**.

---

### Q-001: What should the maximum inline vs. TOAST-overflow vector dimension (`Max_Vector_Dim`) be for 4KB slotted pages?
* **Detail**: Currently `Nhe_O.Vector` defines `Max_Vector_Dim := 256` (1024 bytes of IEEE-754 32-bit floats) so multiple vectors fit directly inside a single 4096-byte slotted page without page-overflow chains. Modern LLM embeddings often use 768, 1536, or 3072 dimensions (requiring 3KB–12KB per vector). Should Nhé O increase the page size to 16KB or implement a PostgreSQL-style TOAST overflow page table for high-dimensional vectors?
* **Impact**: Shapes the on-disk layout of `Nhe_O.Transaction` slotted pages and `Nhe_O.Vector` storage bounds in Epic 02.
* **Waiting on**: Benchmark comparison between 16KB pages and 4KB TOAST overflow chains with owner (Long).
* **Opened**: 2026-10-16
* **Status**: Open

### Q-002: Should Pub/Sub channels optionally persist messages to the WAL for transactional `LISTEN` / `NOTIFY` replay?
* **Detail**: `Nhe_O.PubSub` currently provides low-latency in-memory bounded ring buffers (like Redis `PUBLISH`/`SUBSCRIBE`). PostgreSQL `NOTIFY` ties notification emission to transaction commit. Should Nhé O support a `DURABLE` channel flag that only dispatches messages when the publishing transaction commits to the WAL?
* **Impact**: Determines whether `Nhe_O.PubSub` integrates directly with `Nhe_O.Transaction.Commit_Tx` in Epic 02.
* **Waiting on**: Owner decision (Long) on transactional notification semantics vs. pure fire-and-forget Redis Pub/Sub.
* **Opened**: 2026-10-16
* **Status**: Open
