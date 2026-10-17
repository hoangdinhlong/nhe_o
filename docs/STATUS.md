# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-17_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)** and initiated **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)**. Open questions `Q-001` and `Q-002` are resolved (`ADR-003`, `ADR-004`), domain invariants (`BR-001`..`BR-006`) are ratified, and the foundational Ada 2022 / SPARK 2022 codebase is implemented in **100% `pragma SPARK_Mode (On);`** across all 18 source files, compiled with zero warnings, runtime-verified with contract assertions (`-gnata`), and published to GitHub (`hoangdinhlong/nhe_o`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-004`): unified multi-model engine (`ADR-001`), 100% `SPARK_Mode (On)` POSIX syscall I/O (`ADR-002`), 4KB TOAST overflow chains + 4096-D & `Int8`/Binary quantized vectors for universal local LLM RAG (`ADR-003`), and dual-mode in-memory + `DURABLE` WAL-committed Pub/Sub (`ADR-004`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL Dialect Parser (`Nhe_O.SQL`), Vector Engine (`Nhe_O.Vector` with `<->`, `<=>`, `<#>`), and JSON/JSONB Engine (`Nhe_O.JSON` with `->`, `->>`, `@>`, `?`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager & CRC32 WAL/Slotted-Page Framer (`Nhe_O.Transaction`), Redis-style KV Cache with TTL & LRU eviction (`Nhe_O.KV`), and Ring-Buffer Pub/Sub Broker (`Nhe_O.PubSub`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO` spec and body `src/nhe_o-io.adb` both in `SPARK_Mode => On`) persisting 4KB pages (`pread`/`pwrite`) and WAL frames (`write`/`pread`/`fsync`) to disk with zero `SPARK_Mode (Off)` in the repository.
- 🚧 4KB TOAST overflow page chains, 4096-D `Float32`/`Int8`/`Binary` vector quantization, multi-page B+Tree splits, and HNSW ANN graph index (active in Epic 02).
- 🚧 Dual-mode `DURABLE` WAL Pub/Sub and Universal RAG Hybrid SQL Executor (active in Epic 02).

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ✅ Done |
| `02-storage-indexing-and-rag-executor` | 4KB TOAST overflow, 4096-D quantized HNSW, B+Tree, Durable Pub/Sub & Universal RAG Executor | 🚧 Active |

## Active epic → `epics/02-storage-indexing-and-rag-executor/PROGRESS.md`

Next concrete tasks in Epic 02:
1. Implement 4KB TOAST overflow page chains (`Overflow_Page_Id`, 16-byte inline TOAST pointer, and multi-page WAL redo pass) in `Nhe_O.Transaction` (`ADR-003`, `BR-006`).
2. Expand `Nhe_O.Vector` to `Max_Vector_Dim = 4096` and implement Scalar (`Int8`) & Binary (`1-bit` Hamming) quantization alongside `Float32` (`ADR-003`, `BR-003`).
3. Implement multi-page B+Tree relational/primary-key index with deterministic node splitting in `SPARK_Mode (On)`.
4. Implement bounded HNSW navigable small-world graph index for sub-linear ANN search over `Float32`, `Int8`, and `Binary` vectors.
5. Implement Dual-Mode Pub/Sub (`ADR-004`, `BR-005`) with transactional `Durable` notification staging and post-WAL-commit dispatch (`LISTEN`/`NOTIFY`).
6. Implement Universal RAG & Hybrid SQL Query Executor joining B+Tree scan, JSONB metadata filter (`@>`), TOAST parent-chunk retrieval, and HNSW Vector top-K search.

## Known issues / blockers

- None. GNAT 16 (`gnatmake` using the compiler switches in `nhe_o.gpr`) compiles all 18 SPARK units cleanly with `-gnat2022 -gnatwa -gnata -gnatQ`.

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.

