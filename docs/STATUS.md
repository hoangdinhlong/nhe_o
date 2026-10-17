# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-17_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)** and **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)**. Open questions `Q-001` and `Q-002` are resolved (`ADR-003`, `ADR-004`), domain invariants (`BR-001`..`BR-006`) are ratified, and the Ada 2022 / SPARK 2022 codebase (`v0.2.0`) is implemented in **100% `pragma SPARK_Mode (On);`** across all 24 source files (`src/*.ads` and `src/*.adb`), compiled with zero warnings, runtime-verified across 10 verification suites with contract assertions (`-gnata`), and published to GitHub (`hoangdinhlong/nhe_o`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-004`): unified multi-model engine (`ADR-001`), 100% `SPARK_Mode (On)` POSIX syscall I/O (`ADR-002`), 4KB TOAST overflow chains + 4096-D & `Int8`/Binary quantized vectors for universal local LLM RAG (`ADR-003`), and dual-mode in-memory + `DURABLE` WAL-committed Pub/Sub (`ADR-004`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL Dialect Parser (`Nhe_O.SQL`), 4096-D Vector Engine (`Nhe_O.Vector` with `<->`, `<=>`, `<#>`, `Int8` SQ8, and `1-bit` Binary Hamming), and JSON/JSONB Engine (`Nhe_O.JSON` with `->`, `->>`, `@>`, `?`) implemented in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager, CRC32 WAL/Slotted-Page Framer, 4KB TOAST Overflow Page Chains (`Write_TOAST_Chain`, `Read_TOAST_Chain`), and WAL Redo Recovery (`Redo_WAL_Recovery`) in `Nhe_O.Transaction`.
- ✅ Multi-Page B+Tree Index with deterministic leaf/root node splitting (`Nhe_O.BTree`) and Multi-Layer HNSW Vector Graph Index (`Nhe_O.HNSW`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Redis-style KV Cache (`Nhe_O.KV`), Dual-Mode In-Memory + WAL-Commit-Gated `DURABLE` Pub/Sub Broker (`Nhe_O.PubSub`), and Universal Local LLM RAG & Hybrid SQL Executor (`Nhe_O.RAG`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO` spec and body `src/nhe_o-io.adb` both in `SPARK_Mode => On`) persisting 4KB pages (`pread`/`pwrite`) and WAL frames (`write`/`pread`/`fsync`) to disk with zero `SPARK_Mode (Off)` in the repository.

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ✅ Done |
| `02-storage-indexing-and-rag-executor` | 4KB TOAST overflow, 4096-D quantized HNSW, B+Tree, Durable Pub/Sub & Universal RAG Executor | ✅ Done |

## Active epic → `epics/02-storage-indexing-and-rag-executor/PROGRESS.md`

Epic 01 and Epic 02 are complete (all 10 verification suites passing). Potential next directions for Epic 03:
1. Add C / Python / Rust FFI bindings (`Convention => C` exported API) for direct embedding into local Qwen 3.8 inference servers (`llama.cpp` / `vLLM` / `sglang`).
2. Add PostgreSQL wire-protocol (`v3`) socket listener for drop-in `psql` and `pgvector` client connectivity.
3. Run full formal proof verification reports (`gnatprove --mode=all`) with loop-invariant proof certificates.

## Known issues / blockers

- None. GNAT 16 (`gnatmake` using the compiler switches in `nhe_o.gpr`) compiles all 24 SPARK units cleanly with `-gnat2022 -gnatwa -gnata -gnatQ` and zero warnings.

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.

