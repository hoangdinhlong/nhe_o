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

## ADR-001 — Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL)
- **Date:** 2026-10-16
- **Decision:** Build Nhé O (crate `nhe_o`, Ada root package `Nhe_O`) as a single in-process multi-model engine where PostgreSQL relational tables, `VECTOR(d)` embeddings, `JSONB` documents, and Redis-compatible Key-Value cache entries share a unified 4096-byte slotted-page layout, header-and-payload CRC32-verified Write-Ahead Log (WAL), and MVCC snapshot isolation (`xmin`/`xmax`), paired with a bounded ring-buffer Pub/Sub broker.
- **Why:** Running separate SQLite, `pgvector`, and Redis processes for embedded or local-first workloads adds operational overhead and cross-store consistency bugs. Sharing one ACID storage and WAL engine guarantees crash-safe durability across relational, vector, document, and KV mutations while allowing direct KV and Pub/Sub calls to bypass SQL parsing overhead.
- **Consequences:** `Nhe_O.Types` defines the canonical PostgreSQL type tags shared across SQL, KV, and JSONB subsystems; `Nhe_O.Transaction` governs monotonic transaction IDs (`Tx_Id`), WAL frame encoding/decoding/verification, and MVCC visibility across all models.

## ADR-002 — 100% SPARK_Mode (On) Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O
- **Date:** 2026-10-16
- **Decision:** Enforce `pragma SPARK_Mode (On);` across 100% of specifications, bodies, and entrypoints (`src/*.ads` and `src/*.adb`, 18/18 files). Use statically bounded containers (zero dynamic heap allocation) and bind `Nhe_O.IO` (`src/nhe_o-io.ad[sb]`) directly in `SPARK_Mode (On)` (`Convention => C, Import => True, Side_Effects`) to atomic, exception-free POSIX syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) and `Ada.Text_IO`.
- **Why:** Standard Ada file libraries (`Ada.Direct_IO`, `Ada.Streams.Stream_IO`) report I/O errors by raising Ada exceptions, which would force the physical I/O body out of SPARK (`SPARK_Mode (Off)`). Binding directly to POSIX C syscalls — which never raise Ada exceptions and instead return explicit status/byte counts (`int` / `ssize_t`) — keeps 100% of I/O orchestration (`To_C_Path`, embedded-NUL path rejection, 64-bit page offset bounds `Valid_Page_Id`, short-read/write detection, and `fsync` checks) inside `SPARK_Mode (On)`.
- **Consequences:** Zero files in `src/` may use `pragma SPARK_Mode (Off);` (`BR-001`, mechanically enforced by `SELF-AUDIT.md` check `B5`). All buffers, pages, vectors, JSONB documents, KV slots, and Pub/Sub rings use fixed capacity bounds without exception propagation.
