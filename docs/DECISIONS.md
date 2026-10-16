# Decisions Log (ADR)

Record of non-trivial **technical** decisions. Newest at the bottom.
Format: ID · date · decision · context/why · consequences.

Scope note: do **not** record cosmetic/housekeeping churn (renames, directory reshuffles, etc.) —
such entries have no value on re-read. Record genuine technical decisions. The owner decides when
an exception applies.

Per `../AGENTS.md`: if work contradicts a reference doc, either update that doc or add an entry here
explaining what supersedes it.

Numbering is contiguous (ADR-001, ADR-002, …). When a decision is reversed, mark it **Superseded by
ADR-xxx** (or remove it if it was never built on and has no re-read value — owner's call).

---

## ADR-001 — Adoption of Monion's project-docs R8 documentation framework
- **Date:** 2026-10-16
- **Decision:** Adopt the `project-docs` archetype from Monion (Revision R8) as the foundational self-maintaining documentation system for NheO.
- **Why:** NheO has well-defined technical requirements (embedded multi-model ACID database in Ada/SPARK). `project-docs` R8 provides clear separation between vision, architecture, domain invariants (`docs/domain/`), technical decisions (`DECISIONS.md`), open questions (`OPEN-QUESTIONS.md`), epic progress (`docs/epics/`), and automated end-of-session verification (`docs/_meta/SELF-AUDIT.md`).
- **Consequences:** All AI agents working on NheO must follow `AGENTS.md`, read `docs/STATUS.md` at session start, and execute `docs/_meta/SELF-AUDIT.md` before ending any session.

## ADR-002 — Strict SPARK Verification Mandate with Isolated I/O-Only Ada Boundary
- **Date:** 2026-10-16
- **Decision:** Enforce `pragma SPARK_Mode (On);` across 100% of NheO's database logic specifications, bodies, and main entrypoint (`Nheo`, `Nheo.Types`, `Nheo.Vector`, `Nheo.JSON`, `Nheo.Transaction`, `Nheo.KV`, `Nheo.PubSub`, `Nheo.SQL`, `Nheo.IO` spec, and `Nheo_Main`). Standard unverified Ada (`pragma SPARK_Mode (Off);`) is strictly restricted to the physical I/O implementation body (`src/nheo-io.adb`).
- **Why:** Embedded databases sit at the trust root of applications. Memory corruption, integer overflow in page offsets, divide-by-zero in vector cosine similarity, or broken transaction visibility logic can silently corrupt persistent user data. By confining `SPARK_Mode (Off)` exclusively to raw OS file/stream operations, every algorithmic invariant in NheO can be mathematically proved free of run-time errors (AoRTE) and verified against formal `Pre`/`Post` contracts.
- **Consequences:** Core packages cannot use pointers (`access` types with dynamic allocation), exception propagation, or unbounded strings. All internal buffers, pages, AST nodes, vectors, KV slots, and Pub/Sub rings must use statically bounded types with explicit range constraints. `nheo-io.adb` must catch all `Ada.IO_Exceptions` and translate them into status codes defined in `nheo-io.ads`.

## ADR-003 — Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over MVCC/WAL)
- **Date:** 2026-10-16
- **Decision:** Build NheO as an integrated multi-model embedded engine where PostgreSQL relational tables, `VECTOR(d)` embeddings, `JSONB` documents, and Redis-compatible Key-Value cache entries share a unified 4096-byte slotted-page storage format, CRC32-verified Write-Ahead Log (WAL), and MVCC snapshot isolation (`xmin`/`xmax`), complemented by a bounded ring-buffer Pub/Sub broker.
- **Why:** Running separate SQLite, pgvector, and Redis instances for embedded/edge/laptop workloads introduces synchronization bugs and operational overhead. Sharing a single ACID storage and WAL engine ensures that Key-Value mutations, JSONB updates, and vector insertions participate in the same crash-safe durability guarantees while still allowing direct KV and Pub/Sub calls to bypass SQL parsing overhead.
- **Consequences:** `Nheo.Types` defines the canonical PostgreSQL type tags used across SQL, KV, and JSONB subsystems. `Nheo.Transaction` manages monotonic transaction IDs (`Tx_ID`), WAL frame serialization, and MVCC visibility rules across all data models.
