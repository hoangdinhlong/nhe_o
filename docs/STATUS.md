# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-19_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)**, **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)**, and **Epic 03 (GNATprove Formal Proofs, C ABI / FFI SDK & Interactive CLI)**, and is in **Epic 04 (Post-Epic-03 Grooming & Core Hardening — Round 1 [24/24] & Round 2 [16/16] Remediated in Tasks 1–11; Round 3 [18 Findings: `R3-CRIT-01`..`R3-LOW-04`] Recorded & Scheduled in Tasks 12–16)**. Open questions `Q-001`..`Q-004` are all resolved (`ADR-003`..`ADR-007`), domain invariants (`BR-001`..`BR-007`) and binary storage layouts (`storage-and-wal-format.md`) are ratified, and the Ada 2022 / SPARK 2022 codebase (`v0.3.0`) is implemented in **100% `pragma SPARK_Mode (On);`** across all 26 source files (`src/*.ads` and `src/*.adb`), formally verified at **100% SPARK Stone, Bronze, Silver (AoRTE) + Gold** with `gnatprove 16.1.0` (**2,863 / 2,863 checks proved across all 14 units — 1,062 Flow [142 Data Dependencies, 735 Initialization, 185 Termination] + 1,801 Provers [930 Run-time Checks, 279 Assertions, 579 Functional Contracts, 13 Termination] — 0 unproved, 0 warnings**), runtime-verified across 11 verification suites (`alr run`) plus the Python `ctypes` SDK (`bindings/python/nhe_o.py` over `lib/libnhe_o.so`), and published to GitHub (`hoangdinhlong/nhe_o`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md` `BR-001`..`BR-007`, `storage-and-wal-format.md`, and 7 lessons in `docs/learning/`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-007`): unified multi-model engine (`ADR-001`), 100% `SPARK_Mode (On)` POSIX syscall I/O (`ADR-002`), 4KB TOAST overflow chains + 4096-D & `Int8`/Binary quantized vectors for universal local LLM RAG (`ADR-003`), dual-mode in-memory + `DURABLE` WAL-committed Pub/Sub (`ADR-004`), precondition-free defensive C ABI / FFI SDK boundary in 100% SPARK (`ADR-005`), 2-stage 4096-D Hybrid RAG with `"VTST"` TOAST Stage-2 Exact Re-Ranking & primary 4KB `"SLOT"` slotted pages (`ADR-006`), and `NO-STEAL` commit-gated page persistence, 2-pass committed-only WAL recovery (`CLOG`), positional `pwrite` WAL appends & optional durable KV WAL (`ADR-007`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL Dialect Sanitizer & Parser (`Nhe_O.SQL`), 4096-D Vector Engine (`Nhe_O.Vector` with `<->`, `<=>`, `<#>`, scale-aware `Int8` SQ8, `1-bit` Binary Hamming, and `"VTST"` tiered scientific Vector TOAST serialization), and RFC 8259 JSON/JSONB Engine (`Nhe_O.JSON` with strict `Parse_JSONB`, `->`, `->>`, `@>`, `?`) implemented and proven in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager with `NO-STEAL` WAL staging, bounded `Commit_Log` (`CLOG`, `Default_CLOG := [others => Tx_Idle]`), CRC32 WAL/Slotted-Page Framer (`"SLOT"`), 4KB TOAST Overflow Page Chains (`Write_TOAST_Chain`, `Read_TOAST_Chain`), and 2-pass committed-only WAL Redo Recovery (`Redo_WAL_Recovery`) in `Nhe_O.Transaction`.
- ✅ Multi-Page B+Tree Index with depth-8 root-to-leaf routing, internal/leaf node splitting, `Delete_Key`, and 64-bit CRC32 page serialization (`Nhe_O.BTree`), plus Multi-Layer HNSW Vector Graph Index with distance-pruned edges and multi-wave beam search (`Nhe_O.HNSW`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Redis-style KV Cache with optional WAL durability (`Set_Durable`, `Del_Durable`, `Expire_Durable`, `Incr_By_Durable`, `Recover_KV_From_WAL`) and overflow detection (`Nhe_O.KV`), Dual-Mode In-Memory + WAL-Commit-Gated `DURABLE` Pub/Sub Broker with `Owner_Tx` verification (`Nhe_O.PubSub`), and Universal Local LLM RAG & Hybrid SQL Executor with Stage-2 TOAST Re-Ranking, durable `Delete_Document`, `Rollback_RAG_Tx`, and JSONB metadata recovery (`Nhe_O.RAG`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Formally verified C ABI / FFI SDK (`Nhe_O.C_API` including non-destructive `C_Init_With_Paths` recovery, `C_RAG_Delete`, `C_RAG_Ingest_Full_ND`, and `C_RAG_Query_Full_ND`, `include/nhe_o.h`, `nhe_o_lib.gpr` -> `lib/libnhe_o.so`, `bindings/python/nhe_o.py`) and CLI execution modes (`--verify`, `--sql`, `--kv`, `--rag-demo`) in `src/nhe_o_main.adb`.
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO` spec and body `src/nhe_o-io.adb` both in `SPARK_Mode => On`) persisting 4KB pages (`pread`/`pwrite`) and positional WAL frames (`lseek`/`pwrite`/`pread`/`fsync` with `EINTR` & short-read retry loops) to disk with zero `SPARK_Mode (Off)` in the repository.

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ✅ Done |
| `02-storage-indexing-and-rag-executor` | 4KB TOAST overflow, 4096-D quantized HNSW, B+Tree, Durable Pub/Sub & Universal RAG Executor | ✅ Done |
| `03-formal-proof-and-c-ffi-sdk` | `gnatprove` Flow & AoRTE Formal Proofs (100% Stone/Bronze/Silver + Partial Gold: 1,543/1,543 VCs), C ABI / Python SDK & Interactive CLI | ✅ Done |
| `04-post-epic-03-grooming-and-hardening` | Post-Epic-03 Grooming & Core Hardening: Round 1 (24/24) & Round 2 (16/16) remediated (`Tasks 1–11 Done`); Round 3 (18 findings `R3-CRIT-01`..`R3-LOW-04`) recorded (`Tasks 12–16 Todo`) | ◐ In Progress (11/16) |
| `05-catalog-buffer-pool-and-sql-executor` | Persistent Page-0 System Catalog, Clock-Sweep 4KB Buffer Pool Manager & End-to-End SQL Execution Engine | ⏳ Planned |

## Next up

**Active Epic: `04-post-epic-03-grooming-and-hardening` (`docs/epics/04-post-epic-03-grooming-and-hardening/PROGRESS.md`)**
- ✅ **Tasks 1–11 Completed**: All 40 Round-1 (`CRIT-01`..`LOW-03`) and Round-2 (`R2-CRIT-01`..`R2-LOW-04`) adversarial findings are remediated and formally verified (`2,863 / 2,863` checks proved, `0 unproved`, `0 warnings`).
- ☐ **Tasks 12–16 (Round 3 Remediation)**: Remediate all 18 Round-3 findings (`R3-CRIT-01`..`R3-LOW-04` in `docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md`) before advancing to **Epic 05 (`05-catalog-buffer-pool-and-sql-executor`)**.

## Known issues / blockers

- **Round 3 Adversarial Audit Findings (`R3-CRIT-01`..`R3-LOW-04` — 3 Critical, 5 High, 6 Medium, 4 Low)**: Tracked in `docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md` (Part III) and scheduled for remediation in Epic 04 Tasks 12–16:
  - `R3-CRIT-01`: `Max_CLOG_Entries = 1024` horizon cliff for `Tx_Id > 1024` & shared `G_Next_Tx` depletion by durable KV ops in `Nhe_O.C_API`.
  - `R3-CRIT-02`: `Commit_Tx` 256-frame scan ceiling (`Max_Commit_Scan = 256`) without `Scan_EOF` check & silent skipping of corrupted `WAL_Frame_Data` frames.
  - `R3-CRIT-03`: `Ingest_Document` TOAST page allocator self-collision between `Start_Pg` and `Retired_Vec_Ptr` & `.wal` frame append before `Stage_Notify`.
  - `R3-HIGH-01`..`R3-HIGH-05`, `R3-MED-01`..`R3-MED-06`, `R3-LOW-01`..`R3-LOW-04`: Recovery error propagation in `C_Init_With_Paths`, HNSW/B+Tree rollback & delete synchronization, durable KV `WAL-before-Data` rollback, inline RAG metadata/summary truncation on Page 1, SQL clause-order/identifier grammar guards, JSON escape decoding & `@>` comparison, `"VTST"` exponent tier continuity, Pub/Sub `*` glob matching, GraphRAG self-loop guard, and doc drift.

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


