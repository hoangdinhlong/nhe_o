# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-20_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded multi-model database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native 4096-D Vector search, JSON/JSONB processing, Hybrid RAG & Property Graph traversal, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)**, **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)**, **Epic 03 (GNATprove Formal Proofs, C ABI / FFI SDK & Interactive CLI)**, and **Epic 04 (Post-Epic-03 Grooming & Core Hardening — 84/84 Adversarial Findings Remediated across Rounds 1–10 & Verified with 0 Issues in Round 11)**, and is ready to begin **Epic 05 (Catalog, Buffer Pool & SQL Executor)** followed by **Epic 06 (Formally Verified Property Graph Engine `Nhe_O.Graph`, `SQL/PGQ MATCH` & Multi-Hop GraphRAG)**. Open questions `Q-001`..`Q-004` are all resolved (`ADR-003`..`ADR-008`), domain invariants (`BR-001`..`BR-008`) and binary storage layouts (`storage-and-wal-format.md`) are ratified, and the Ada 2022 / SPARK 2022 codebase (`v0.3.0`) is implemented in **100% `pragma SPARK_Mode (On);`** across all 26 source files (`src/*.ads` and `src/*.adb`), formally verified at **100% SPARK Stone, Bronze, Silver (AoRTE) + Gold** with `gnatprove 16.1.0` (**4,246 / 4,246 checks proved across all 14 units — 1,316 Flow [171 Data Dependencies, 920 Initialization, 2 Non-Aliasing, 223 Termination] + 2,930 Provers [1,519 Run-time Checks, 536 Assertions, 807 Functional Contracts, 68 Termination] — 0 unproved, 0 warnings**), runtime-verified across 11 verification suites (`alr run`) plus the Python `ctypes` SDK (`bindings/python/nhe_o.py` over `lib/libnhe_o.so`), and published to GitHub (`hoangdinhlong/nhe_o`).

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md` `BR-001`..`BR-008`, `storage-and-wal-format.md`, and 11 lessons in `docs/learning/`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-008`): unified multi-model engine (`ADR-001`), 100% `SPARK_Mode (On)` POSIX syscall I/O (`ADR-002`), 4KB TOAST overflow chains + 4096-D & `Int8`/Binary quantized vectors for universal local LLM RAG (`ADR-003`), dual-mode in-memory + `DURABLE` WAL-committed Pub/Sub (`ADR-004`), precondition-free defensive C ABI / FFI SDK boundary in 100% SPARK (`ADR-005`), NO-STEAL WAL staging, 2-pass committed-only WAL recovery, unified 8192-entry CLOG, primary `"SLOT"` pages & `"VTST"` / `"RMET"` TOAST chains (`ADR-006`), dual-mode Key-Value store (`Global => null` cache + `"KVMG"` WAL-before-Data persistence with rollback & dedicated `G_Next_KV_Seq`) + Feature → Grooming epic cadence (`ADR-007`), and Native Labeled Property Graph Engine (`Nhe_O.Graph`, bi-directional CSR `"GRPH"` pages, `SQL/PGQ MATCH`, cycle-safe `Always_Terminates` traversal & Multi-Hop GraphRAG, `ADR-008`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL Dialect Sanitizer & Parser (`Nhe_O.SQL` with strict clause-order, comma-segment, `LIMIT`, `CREATE TABLE IF NOT EXISTS` with `<col_ident> <pg_type>` validation, `INSERT INTO` `VALUES (...)`/`SELECT`, `UPDATE ... SET <col> = <expr>`, `DELETE FROM`, `NOTIFY`, `NUMERIC(1..38)`, and transaction-control grammar guards), 4096-D Vector Engine (`Nhe_O.Vector` with `<->`, `<=>`, `<#>`, scale-aware `Int8` SQ8, `1-bit` Binary Hamming, and `"VTST"` 15-tier scientific Vector TOAST serialization), and RFC 8259 JSON/JSONB Engine (`Nhe_O.JSON` with strict `Parse_JSONB` escape decoding, `->`, `->>`, `@>` canonical number/multi-level nested containment up to depth 4, and `?`) implemented and proven in 100% SPARK (`SPARK_Mode => On`).
- ✅ ACID MVCC Transaction Manager with `NO-STEAL` WAL staging, pre-commit 4096-frame CRC32 WAL validation & duplicate/post-commit frame rejection, unified 8192-entry `Commit_Log` (`CLOG`, `Default_CLOG := [others => Tx_Idle]`), CRC32 WAL/Slotted-Page Framer (`"SLOT"`), contiguous 4KB TOAST Overflow Page Chains (`Write_TOAST_Chain`, `Read_TOAST_Chain`), and 2-pass committed-only WAL Redo Recovery (`Redo_WAL_Recovery`) in `Nhe_O.Transaction`.
- ✅ Multi-Page B+Tree Index with depth-8 root-to-leaf routing, internal/leaf node splitting, leaf compaction & reclamation in `Delete_Key`, and 64-bit CRC32 page serialization (`Nhe_O.BTree`), plus Multi-Layer HNSW Vector Graph Index with in-place `Doc_Id` deduplication, distance-pruned edges, `Remove_Vector` / `Restore_Vector_Node`, and multi-wave beam search (`Nhe_O.HNSW`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Redis-style KV Cache with `WAL-before-Data` rollback (`Set_Durable`, `Del_Durable`, `Expire_Durable`, `Incr_By_Durable`, `Recover_KV_From_WAL`) and overflow detection (`Nhe_O.KV`), Dual-Mode In-Memory + WAL-Commit-Gated `DURABLE` Pub/Sub Broker with general `*` glob wildcard matching and `Owner_Tx` verification (`Nhe_O.PubSub`), and Universal Local LLM RAG & Hybrid SQL Executor with Stage-2 `"VTST"` TOAST Re-Ranking, `"RMET"` lossless extended summary + JSONB metadata TOAST chains, startup & Stage-3 parent TOAST verification, non-overlapping TOAST allocator, synchronized HNSW/B+Tree `Delete_Document` & `Rollback_RAG_Tx`, and self-loop-free 1-hop GraphRAG (`Nhe_O.RAG`) in 100% SPARK (`SPARK_Mode => On`).
- ✅ Formally verified C ABI / FFI SDK (`Nhe_O.C_API` including non-destructive `C_Init_With_Paths` recovery with strict error/alignment/monotonicity checks, dedicated `G_Next_KV_Seq` sequence numbering, `C_RAG_Delete`, `C_RAG_Ingest_Full_ND`, and `C_RAG_Query_Full_ND`, `include/nhe_o.h`, `nhe_o_lib.gpr` -> `lib/libnhe_o.so`, `bindings/python/nhe_o.py`) and CLI execution modes (`--verify`, `--sql`, `--kv`, `--rag-demo`, plus strict unknown-flag rejection) in `src/nhe_o_main.adb`.
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO` spec and body `src/nhe_o-io.adb` both in `SPARK_Mode => On`) persisting 4KB pages (`pread`/`pwrite`, `Check_File_Exists` via `access(F_OK)`, `Posix_Lseek SEEK_END` 4096B file-size alignment checks, and 5-arg `Read_Page (..., Is_EOF)`) and positional WAL frames (`lseek`/`pwrite`/`pread`/`fsync` with `Max_WAL_Frames = 4096` bounds, 4120B alignment verification, and `EINTR` & short-read retry loops) to disk with zero `SPARK_Mode (Off)` in the repository.

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ✅ Done |
| `02-storage-indexing-and-rag-executor` | 4KB TOAST overflow, 4096-D quantized HNSW, B+Tree, Durable Pub/Sub & Universal RAG Executor | ✅ Done |
| `03-formal-proof-and-c-ffi-sdk` | `gnatprove` Flow & AoRTE Formal Proofs (100% Stone/Bronze/Silver + Partial Gold: 1,543/1,543 VCs), C ABI / Python SDK & Interactive CLI | ✅ Done |
| `04-post-epic-03-grooming-and-hardening` | Post-Epic-03 Grooming & Core Hardening: 84/84 Adversarial Findings Remediated across Rounds 1–10 + Round 11 0-Defect Verification (`Tasks 1–20 Done`; `4,246/4,246` VCs proved) | ✅ Done |
| `05-catalog-buffer-pool-and-sql-executor` | Persistent Page-0 System Catalog, Clock-Sweep 4KB Buffer Pool Manager & End-to-End SQL Execution Engine | ⏳ Planned |
| `06-property-graph-and-multi-hop-graphrag` | Formally Verified Labeled Property Graph Engine (`Nhe_O.Graph`, Bi-Directional CSR `"GRPH"` Pages, `SQL/PGQ MATCH` & Multi-Hop Knowledge GraphRAG) | ⏳ Planned |

## Next up

**Next Epic: `05-catalog-buffer-pool-and-sql-executor` (followed by `06-property-graph-and-multi-hop-graphrag`)**
- ✅ **Epic 04 Completed (`20/20` tasks)**: All 84 adversarial findings across Rounds 1–10 are remediated, verified with `0` issues in Round 11, and formally proved (`4,246 / 4,246` checks proved, `0 unproved`, `0 warnings`).
- ☐ **Start Epic 05 (`05-catalog-buffer-pool-and-sql-executor`)**: Implement `Nhe_O.Catalog` (Page 0), `Nhe_O.Buffer_Pool` (Clock-Sweep 4KB frames), and `Nhe_O.Executor` (End-to-End SQL), then advance to **Epic 06 (`06-property-graph-and-multi-hop-graphrag`)**.

## Known issues / blockers

- None. All 84 adversarial findings across Rounds 1–10 (and Round 11 zero-defect convergence verification) in `docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md` have been remediated and verified (`4,246 / 4,246` checks proved, `0 unproved`, `0 warnings`).

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.
- `ADR-005`: Formally Verified C ABI / FFI Boundary via Precondition-Free Defensive Subprograms in 100% SPARK.
- `ADR-006`: NO-STEAL WAL Staging, 2-Pass Committed-Only WAL Recovery, Unified 8192-Entry CLOG, Primary `"SLOT"` Pages & `"VTST"` / `"RMET"` TOAST Chains (`Q-003`).
- `ADR-007`: Dual-Mode Key-Value Store (In-Memory Cache + `"KVMG"` WAL-Before-Data Persistence) & Feature → Grooming Epic Cadence (`Q-004`).
- `ADR-008`: Native Labeled Property Graph Engine (`Nhe_O.Graph`), Bi-Directional CSR Adjacency (`"GRPH"`), `SQL/PGQ MATCH` & Multi-Hop GraphRAG (`Epic 06`).

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.


