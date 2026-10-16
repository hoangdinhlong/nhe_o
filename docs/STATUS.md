# STATUS — NheO

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-16_

---

## Where we are

NheO — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)** and is ready for **Epic 02 (B+Tree Storage Indexing, HNSW Vector Graph & Query Executor)**. The documentation system is scaffolded from Monion's `project-docs` archetype (Revision R8), core architectural decisions (`ADR-001`..`ADR-003`) and domain invariants (`BR-001`..`BR-005`) are ratified, and the foundational Ada 2022 / SPARK 2022 codebase is implemented, compiled with zero warnings, runtime-verified with contract assertions (`-gnata`), and published to GitHub (`hoangdinhlong/NheO`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, two-zone SPARK/Ada architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md`).
- ✅ Architectural decisions recorded (`ADR-001`, `ADR-002`, `ADR-003`).
- ✅ PostgreSQL Type System (`Nheo.Types`), SQL Dialect Parser (`Nheo.SQL`), Vector Engine (`Nheo.Vector` with `<->`, `<=>`, `<#>`), and JSON/JSONB Engine (`Nheo.JSON` with `->`, `->>`, `@>`, `?`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager & CRC32 WAL/Slotted-Page Framer (`Nheo.Transaction`), Redis-style KV Cache with TTL & LRU eviction (`Nheo.KV`), and Ring-Buffer Pub/Sub Broker (`Nheo.PubSub`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ Strictly isolated I/O substrate (`Nheo.IO` spec in `SPARK_Mode => On`, body `src/nheo-io.adb` in `SPARK_Mode => Off`) persisting 4KB pages and WAL frames to disk.
- ⛔ Multi-page B+Tree table/index splits and HNSW graph persistence (planned for Epic 02).
- ⛔ Full SQL Volcano/Vectorized execution pipeline joining relational, JSONB, and vector predicates (planned for Epic 02).

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, SPARK core subsystems, and isolated Ada I/O boundary | ☑ Done |

## Active epic → `epics/01-scaffold-and-architecture/PROGRESS.md`

Epic 01 is complete. Next concrete tasks for upcoming Epic 02:
1. Implement multi-page B+Tree node splitting and WAL crash-recovery redo pass in `Nheo.Transaction`.
2. Add bounded HNSW navigable small-world graph index over `Nheo.Vector` for sub-linear approximate nearest neighbor search.
3. Connect `Nheo.SQL` parsed AST statements to physical B+Tree, JSONB, and Vector scan executors.

## Known issues / blockers

- None. GNAT 16 (`gnatmake` / `gprbuild`) compiles all SPARK and Ada units cleanly with `-gnat2022 -gnatwa -gnata -gnatQ`.

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Adoption of Monion's `project-docs` R8 documentation framework.
- `ADR-002`: Strict SPARK Verification Mandate with Isolated I/O-Only Ada Boundary.
- `ADR-003`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over MVCC/WAL).

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.
