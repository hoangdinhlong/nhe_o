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
- **Decision:** Adopt the `project-docs` archetype from Monion (Revision R8) as the foundational self-maintaining documentation system for `nhe_o` (`Nhe_O`).
- **Why:** `nhe_o` has well-defined technical requirements (embedded multi-model ACID database in Ada/SPARK). `project-docs` R8 provides clear separation between vision, architecture, domain invariants (`docs/domain/`), technical decisions (`DECISIONS.md`), open questions (`OPEN-QUESTIONS.md`), epic progress (`docs/epics/`), and automated end-of-session verification (`docs/_meta/SELF-AUDIT.md`).
- **Consequences:** All AI agents working on `nhe_o` must follow `AGENTS.md`, read `docs/STATUS.md` at session start, and execute `docs/_meta/SELF-AUDIT.md` before ending any session.

## ADR-002 — Strict SPARK Verification Mandate with Isolated I/O-Only Ada Boundary (Updated by ADR-005)
- **Date:** 2026-10-16
- **Decision:** Enforce `pragma SPARK_Mode (On);` across 100% of `Nhe_O`'s database logic specifications, bodies, and main entrypoint (`Nhe_O`, `Nhe_O.Types`, `Nhe_O.Vector`, `Nhe_O.JSON`, `Nhe_O.Transaction`, `Nhe_O.KV`, `Nhe_O.PubSub`, `Nhe_O.SQL`, `Nhe_O.IO` spec, and `Nhe_O_Main`). Initially permitted `pragma SPARK_Mode (Off);` only in `src/nhe_o-io.adb` (now upgraded to `SPARK_Mode (On)` by `ADR-005`).
- **Why:** Embedded databases sit at the trust root of applications. Memory corruption, integer overflow in page offsets, divide-by-zero in vector cosine similarity, or broken transaction visibility logic can silently corrupt persistent user data.
- **Consequences:** Core packages cannot use pointers (`access` types with dynamic allocation), exception propagation, or unbounded strings. All internal buffers, pages, AST nodes, vectors, KV slots, and Pub/Sub rings must use statically bounded types with explicit range constraints.

## ADR-003 — Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over MVCC/WAL)
- **Date:** 2026-10-16
- **Decision:** Build `Nhe_O` as an integrated multi-model embedded engine where PostgreSQL relational tables, `VECTOR(d)` embeddings, `JSONB` documents, and Redis-compatible Key-Value cache entries share a unified 4096-byte slotted-page storage format, CRC32-verified Write-Ahead Log (WAL), and MVCC snapshot isolation (`xmin`/`xmax`), complemented by a bounded ring-buffer Pub/Sub broker.
- **Why:** Running separate SQLite, pgvector, and Redis instances for embedded/edge/laptop workloads introduces synchronization bugs and operational overhead. Sharing a single ACID storage and WAL engine ensures that Key-Value mutations, JSONB updates, and vector insertions participate in the same crash-safe durability guarantees while still allowing direct KV and Pub/Sub calls to bypass SQL parsing overhead.
- **Consequences:** `Nhe_O.Types` defines the canonical PostgreSQL type tags used across SQL, KV, and JSONB subsystems. `Nhe_O.Transaction` manages monotonic transaction IDs (`Tx_ID`), WAL frame serialization, and MVCC visibility rules across all data models.

## ADR-004 — Professional Ada/Alire/GNAT Naming Convention (`nhe_o` / `Nhe_O` / `nhe_o-<module>.ad[sb]`)
- **Date:** 2026-10-16
- **Decision:** Standardize the project's naming (inspired by the owner's cat **"Nhé O"**) according to professional Ada/SPARK ecosystem standards:
  1. **Alire crate, GPR project file, directory, and repository name**: lowercase `snake_case` **`nhe_o`** (`nhe_o.gpr`).
  2. **Ada package and subprogram identifiers**: `Mixed_Case_With_Underscores` per the *Ada Quality and Style Guide* (§3.1.3) — root package **`Nhe_O`**, child packages **`Nhe_O.<Module>`**, and entrypoint **`Nhe_O_Main`**.
  3. **GNAT source file krunching**: `_` separates words inside an identifier while `-` strictly separates parent and child packages (`src/nhe_o.ads`, `src/nhe_o_main.adb`, `src/nhe_o-<module>.ads`, `src/nhe_o-<module>.adb`).
- **Why:** In Ada, `-` is the subtraction operator and cannot appear in identifiers, while GNAT reserves `-` in filenames exclusively for child package separators (`.` in Ada syntax). Using `nhe-o` for filenames would cause GNAT to expect a parent package `Nhe` and child package `Nhe.O`. Conversely, `NheO` without an underscore violates the Ada Quality and Style Guide (`Mixed_Case_With_Underscores`). Using `nhe_o` / `Nhe_O` / `nhe_o-<module>.ad[sb]` satisfies Alire, GNAT, and Ada style rules simultaneously.
- **Consequences:** All source files, GPR build descriptors, and documentation references use `nhe_o` for the crate/repo and `Nhe_O` for the root Ada package.

## ADR-005 — 100% SPARK_Mode (On) Across All Source Files via Contract-Bound POSIX Syscall I/O
- **Date:** 2026-10-16
- **Decision:** Upgrade `src/nhe_o-io.adb` from `pragma SPARK_Mode (Off);` (which used exception-raising `Ada.Direct_IO` and `Ada.Streams.Stream_IO`) to **`pragma SPARK_Mode (On);`** using `Convention => C, Import => True, Side_Effects` bindings to POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) and `Ada.Text_IO`. Every single `.ads` and `.adb` file in `src/` (18/18 files) now operates under `pragma SPARK_Mode (On);`.
- **Why:** Standard Ada file I/O libraries (`Ada.Direct_IO`, `Ada.Streams.Stream_IO`, `Ada.Directories`) signal disk errors by raising Ada exceptions (`Name_Error`, `Use_Error`, `Device_Error`), which forces the caller body out of SPARK (`SPARK_Mode (Off)`). By binding directly to POSIX C syscalls — which never raise Ada exceptions and instead return integer status/byte counts (`int` / `ssize_t`) — 100% of the I/O orchestration logic (NUL-terminated path construction `To_C_Path`, 64-bit page offset calculation `Off_T (Page_Id) * 4096` bounded by `Valid_Page_Id`, short-read/short-write detection, and hardware `fsync` verification) is brought inside `SPARK_Mode (On)`. Additionally, positional `pread`/`pwrite` and explicit `fsync(fd)` provide stronger ACID durability guarantees than `Stream_IO`.
- **Consequences:** Zero files in `src/` use `pragma SPARK_Mode (Off);`. `SELF-AUDIT.md` check `B5` enforces both that `SPARK_Mode (Off)` never appears in `src/` and that every `src/*.ad[sb]` file contains `pragma SPARK_Mode (On);`.
