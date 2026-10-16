# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-16_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)** and is ready for **Epic 02 (B+Tree Storage Indexing, HNSW Vector Graph & Query Executor)**. The documentation system is scaffolded from Monion's `project-docs` archetype (Revision R8), core architectural decisions (`ADR-001`..`ADR-002`) and domain invariants (`BR-001`..`BR-005`) are ratified, and the foundational Ada 2022 / SPARK 2022 codebase is implemented in **100% `pragma SPARK_Mode (On);`** across all 18 source files, compiled with zero warnings, runtime-verified with contract assertions (`-gnata`), and published to GitHub (`hoangdinhlong/nhe_o`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-002`): unified multi-model engine over shared MVCC/WAL (`ADR-001`) and 100% `SPARK_Mode (On)` via statically bounded memory and contract-bound POSIX syscall I/O (`ADR-002`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL Dialect Parser (`Nhe_O.SQL`), Vector Engine (`Nhe_O.Vector` with `<->`, `<=>`, `<#>`), and JSON/JSONB Engine (`Nhe_O.JSON` with `->`, `->>`, `@>`, `?`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager & CRC32 WAL/Slotted-Page Framer (`Nhe_O.Transaction`), Redis-style KV Cache with TTL & LRU eviction (`Nhe_O.KV`), and Ring-Buffer Pub/Sub Broker (`Nhe_O.PubSub`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO` spec and body `src/nhe_o-io.adb` both in `SPARK_Mode => On`) persisting 4KB pages (`pread`/`pwrite`) and WAL frames (`write`/`pread`/`fsync`) to disk with zero `SPARK_Mode (Off)` in the repository.
- ⛔ Multi-page B+Tree table/index splits and HNSW graph persistence (planned for Epic 02).
- ⛔ Full SQL Volcano/Vectorized execution pipeline joining relational, JSONB, and vector predicates (planned for Epic 02).

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ☑ Done |

## Active epic → `epics/01-scaffold-and-architecture/PROGRESS.md`

Epic 01 is complete. Next concrete tasks for upcoming Epic 02:
1. Implement multi-page B+Tree node splitting and WAL crash-recovery redo pass in `Nhe_O.Transaction`.
2. Add bounded HNSW navigable small-world graph index over `Nhe_O.Vector` for sub-linear approximate nearest neighbor search.
3. Connect `Nhe_O.SQL` parsed AST statements to physical B+Tree, JSONB, and Vector scan executors.

## Known issues / blockers

- No blockers. GNAT 16 (`gnatmake` using the compiler switches in `nhe_o.gpr`) compiles all 18 SPARK units cleanly with `-gnat2022 -gnatwa -gnata -gnatQ`.
- Minimum compiler is GNAT 14. GNAT 14.2 (Ubuntu 24.04 `gnat-14`) also compiles cleanly with `-gnatwe`, and `bin/nhe_o_main` passes all 6 suites (checked 2026-10-16). GNAT 13, which is Ubuntu 24.04's default `gnat` and what plain `gprbuild` picks there, rejects the `Side_Effects` aspect in `src/nhe_o-io.adb` with 8 warnings. The build still links and the suites still pass, but the zero-warnings bar is not met.
- `GNATprove` has not been run yet, so the AoRTE goal in `ARCHITECTURE.md` is still unproven. So far, contracts have only been checked at runtime (`-gnata`).

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.
