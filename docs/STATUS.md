# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-17_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)**, **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)**, and **Epic 03 (GNATprove Formal Proofs, C ABI / FFI SDK & Interactive CLI)**. Open questions `Q-001` and `Q-002` are resolved (`ADR-003`, `ADR-004`), `Q-003` and `Q-004` are tracked in `OPEN-QUESTIONS.md`, domain invariants (`BR-001`..`BR-007`) are ratified, and the Ada 2022 / SPARK 2022 codebase (`v0.3.0`) is implemented in **100% `pragma SPARK_Mode (On);`** across all 26 source files (`src/*.ads` and `src/*.adb`), formally verified at **100% SPARK Stone, Bronze, Silver (AoRTE) + Partial Gold** with `gnatprove 16.1.0` (**1,543 / 1,543 checks proved across all 14 units — 601 Flow [86 Data Dependencies, 402 Initialization, 113 Termination] + 942 Provers [470 Run-time Checks, 125 Assertions, 347 Functional Contracts] — 0 unproved, 0 warnings**), runtime-verified across 11 verification suites (`alr run`) plus the Python `ctypes` SDK (`bindings/python/nhe_o.py` over `lib/libnhe_o.so`), and published to GitHub (`hoangdinhlong/nhe_o`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md` `BR-001`..`BR-007`, and 5 lessons in `docs/learning/`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-005`): unified multi-model engine (`ADR-001`), 100% `SPARK_Mode (On)` POSIX syscall I/O (`ADR-002`), 4KB TOAST overflow chains + 4096-D & `Int8`/Binary quantized vectors for universal local LLM RAG (`ADR-003`), dual-mode in-memory + `DURABLE` WAL-committed Pub/Sub (`ADR-004`), and precondition-free defensive C ABI / FFI SDK boundary in 100% SPARK (`ADR-005`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL Dialect Parser (`Nhe_O.SQL`), 4096-D Vector Engine (`Nhe_O.Vector` with `<->`, `<=>`, `<#>`, `Int8` SQ8, and `1-bit` Binary Hamming), and JSON/JSONB Engine (`Nhe_O.JSON` with `->`, `->>`, `@>`, `?`) implemented and proven in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager, CRC32 WAL/Slotted-Page Framer, 4KB TOAST Overflow Page Chains (`Write_TOAST_Chain`, `Read_TOAST_Chain`), and WAL Redo Recovery (`Redo_WAL_Recovery`) in `Nhe_O.Transaction`.
- ✅ Multi-Page B+Tree Index with deterministic leaf/root node splitting (`Nhe_O.BTree`) and Multi-Layer HNSW Vector Graph Index (`Nhe_O.HNSW`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Redis-style KV Cache (`Nhe_O.KV`), Dual-Mode In-Memory + WAL-Commit-Gated `DURABLE` Pub/Sub Broker (`Nhe_O.PubSub`), and Universal Local LLM RAG & Hybrid SQL Executor (`Nhe_O.RAG`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Formally verified C ABI / FFI SDK (`Nhe_O.C_API`, `include/nhe_o.h`, `nhe_o_lib.gpr` -> `lib/libnhe_o.so`, `bindings/python/nhe_o.py`) and CLI execution modes (`--verify`, `--sql`, `--kv`, `--rag-demo`) in `src/nhe_o_main.adb`.
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO` spec and body `src/nhe_o-io.adb` both in `SPARK_Mode => On`) persisting 4KB pages (`pread`/`pwrite`) and WAL frames (`write`/`pread`/`fsync`) to disk with zero `SPARK_Mode (Off)` in the repository.

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ✅ Done |
| `02-storage-indexing-and-rag-executor` | 4KB TOAST overflow, 4096-D quantized HNSW, B+Tree, Durable Pub/Sub & Universal RAG Executor | ✅ Done |
| `03-formal-proof-and-c-ffi-sdk` | `gnatprove` Flow & AoRTE Formal Proofs (100% Stone/Bronze/Silver + Partial Gold: 1,543/1,543 VCs), C ABI / Python SDK & Interactive CLI | ✅ Done |
| `04-post-epic-03-grooming-and-hardening` | Post-Epic-03 Grooming & Core Hardening: Remediate all 24 `ADVERSARIAL-REVIEW.md` findings, resolve `Q-003` & `Q-004`, codify `storage-and-wal-format.md`, and re-prove 100% SPARK (`Tasks 1–5 Done`, `Task 6` in progress: `2,638/2,647` VCs proved) | 🚧 Active |
| `05-catalog-buffer-pool-and-sql-executor` | Persistent Page-0 System Catalog, Clock-Sweep 4KB Buffer Pool Manager & End-to-End SQL Execution Engine | ⏳ Planned |

## Next up

**Active Epic: `04-post-epic-03-grooming-and-hardening` (`docs/epics/04-post-epic-03-grooming-and-hardening/PROGRESS.md`)**
- ✅ **Tasks 1–5 Completed**: All 24 adversarial review findings (`CRIT-01`..`CRIT-07`, `HIGH-01`..`HIGH-09`, `MED-01`..`MED-05`, `LOW-01`..`LOW-03`) and open questions `Q-003` (`ADR-006`) and `Q-004` (`ADR-007`) are implemented in code, documented in `docs/domain/storage-and-wal-format.md`, and verified at runtime across all 11 Ada suites (`alr build && alr run`) and the Python `ctypes` SDK (`python3 bindings/python/nhe_o.py`).
- ◐ **Next Task (Task 6 — Final `gnatprove` VC Discharge to Resume Next Session)**:
  - Out of **2,647 total `gnatprove` checks**, **2,638 (`99.66%`)** are already proved (`10 / 14` units at 100% including `Nhe_O.Transaction`, `Nhe_O.Vector`, `Nhe_O.JSON`, `Nhe_O.KV`, `Nhe_O.PubSub`, `Nhe_O.SQL`, `Nhe_O.IO`, and `Nhe_O.C_API`).
  - Discharge the remaining **9 VCs** (`BTree.Insert_Key` [1], `HNSW.Add_Edge_Pruned` [1], `HNSW.Node_Distance` [2], `RAG.Delete_Document` [1 flow], `Nhe_O_Main` [3], `Nhe_O_Main.Parse_Positive_Int` [1]) and silence the 7 `-gnatwa` membership warnings in `nhe_o-transaction.adb` / `nhe_o_main.adb` to close Epic 04 and advance to **Epic 05 (`05-catalog-buffer-pool-and-sql-executor`)**.

## Known issues / blockers

- **Epic 04 Task 6 Checkpoint (9 remaining `gnatprove` VCs out of 2,647)**: Code remediation for all 24 findings in [`docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md`](epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md) is complete and passes all runtime suites; only the 9 VCs listed in **Next up** remain to be discharged at the start of the next session.

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.
- `ADR-005`: Formally Verified C ABI / FFI Boundary via Precondition-Free Defensive Subprograms in 100% SPARK.
- `ADR-006`: Two-Stage 4096-D Hybrid RAG (HNSW RAM Stage-1 + TOAST Full-Vector Stage-2 Exact Re-Ranking) & Primary 4KB `"SLOT"` Pages (`Q-003`).
- `ADR-007`: Two-Pass Committed-Only WAL Recovery (`CLOG`), Positional `pwrite` WAL Appends & Optional Durable KV WAL (`Q-004`).

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.


