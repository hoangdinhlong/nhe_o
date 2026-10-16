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
- **Decision:** Adopt Monion's `project-docs` archetype (Revision R8) as the self-maintaining documentation system for `nhe_o` (`Nhe_O`).
- **Why:** Provides strict role separation between vision (`VISION.md`), architecture (`ARCHITECTURE.md`), domain invariants (`docs/domain/`), technical decisions (`DECISIONS.md`), open questions (`OPEN-QUESTIONS.md`), epic tracking (`docs/epics/`), and automated end-of-session verification (`docs/_meta/SELF-AUDIT.md`).
- **Consequences:** All AI agents working on `nhe_o` follow `AGENTS.md`, read `docs/STATUS.md` at session start, and execute `docs/_meta/SELF-AUDIT.md` before ending any session.

## ADR-002 — 100% SPARK_Mode (On) Mandate Across All Source Files via Contract-Bound POSIX Syscall I/O
- **Date:** 2026-10-16
- **Decision:** Enforce `pragma SPARK_Mode (On);` across 100% of `Nhe_O`'s specifications, bodies, and entrypoints (`src/*.ads` and `src/*.adb`, 18/18 files). Physical disk and WAL operations in `Nhe_O.IO` (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`) bind directly in `SPARK_Mode (On)` (`Convention => C, Import => True, Side_Effects`) to atomic, exception-free POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) and `Ada.Text_IO`.
- **Why:** Embedded databases sit at the trust root of applications: memory corruption, integer overflow in page offsets, divide-by-zero in vector cosine similarity, or broken transaction visibility can silently corrupt persistent user data. Standard Ada file I/O libraries (`Ada.Direct_IO`, `Ada.Streams.Stream_IO`) signal disk errors by raising Ada exceptions, which would force the I/O implementation body out of SPARK (`SPARK_Mode (Off)`). Binding directly to POSIX C syscalls — which never raise Ada exceptions and instead return explicit status/byte counts (`int` / `ssize_t`) — keeps 100% of I/O orchestration (`To_C_Path`, embedded-NUL path rejection, bounded 64-bit page offsets `Valid_Page_Id`, short-read/write detection, and `fsync` verification) inside `SPARK_Mode (On)`.
- **Consequences:** Zero files in `src/` may use `pragma SPARK_Mode (Off);`. All internal buffers, pages, AST descriptors, vectors, KV slots, and Pub/Sub rings use statically bounded types without dynamic heap allocation or exception propagation. `SELF-AUDIT.md` check `B5` mechanically enforces `SPARK_Mode (On)` across every file in `src/`.

## ADR-003 — Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over MVCC/WAL)
- **Date:** 2026-10-16
- **Decision:** Build `Nhe_O` as an integrated multi-model embedded engine where PostgreSQL relational tables, `VECTOR(d)` embeddings, `JSONB` documents, and Redis-compatible Key-Value cache entries share a unified 4096-byte slotted-page storage format, header-and-payload CRC32-verified Write-Ahead Log (WAL), and MVCC snapshot isolation (`xmin`/`xmax`), complemented by a bounded ring-buffer Pub/Sub broker.
- **Why:** Running separate SQLite, pgvector, and Redis instances for embedded/edge/laptop workloads introduces synchronization bugs and operational overhead. Sharing a single ACID storage and WAL engine ensures that Key-Value mutations, JSONB updates, and vector insertions participate in the same crash-safe durability guarantees while allowing direct KV and Pub/Sub calls to bypass SQL parsing overhead.
- **Consequences:** `Nhe_O.Types` defines the canonical PostgreSQL type tags used across SQL, KV, and JSONB subsystems. `Nhe_O.Transaction` manages monotonic transaction IDs (`Tx_Id`), WAL frame serialization/verification, and MVCC visibility rules across all data models.

## ADR-004 — Ada/Alire/GNAT Naming and File Krunching Convention (`nhe_o` / `Nhe_O` / `nhe_o-<module>.ad[sb]`)
- **Date:** 2026-10-16
- **Decision:** Follow the *Ada Quality and Style Guide* (§3.1.3) and GNAT/Alire ecosystem conventions for the project's two-word name (inspired by the owner's cat **"Nhé O"**):
  1. **Alire crate, GPR project file, directory, and repository name**: lowercase `snake_case` **`nhe_o`** (`nhe_o.gpr`).
  2. **Ada package and subprogram identifiers**: `Mixed_Case_With_Underscores` — root package **`Nhe_O`**, child packages **`Nhe_O.<Module>`**, and entrypoint **`Nhe_O_Main`**.
  3. **GNAT source file krunching**: `_` separates words inside an identifier while `-` strictly separates parent and child packages (`src/nhe_o.ads`, `src/nhe_o_main.adb`, `src/nhe_o-<module>.ads`, `src/nhe_o-<module>.adb`).
- **Why:** In Ada syntax, `-` is the subtraction operator and cannot appear in identifiers, while GNAT's default file naming rule reserves `-` exclusively for child package hierarchy separators (`.`). Using `_` inside `nhe_o` and `-` before `<module>` satisfies Alire crate rules, GNAT unit resolution, and Ada style conventions simultaneously.
- **Consequences:** All source files, GPR build descriptors, and documentation references use `nhe_o` for the crate/repository and `Nhe_O` for the root Ada package.
