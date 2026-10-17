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
| `04-catalog-buffer-pool-and-sql-executor` | Core Hardening (`ADVERSARIAL-REVIEW.md`), Persistent Page-0 System Catalog, Clock-Sweep 4KB Buffer Pool Manager & End-to-End SQL Execution Engine | ⏳ Planned |

## Next up

**Epic 04 (`04-catalog-buffer-pool-and-sql-executor`)** is defined in `docs/epics/04-catalog-buffer-pool-and-sql-executor/PROGRESS.md` (with adversarial audit findings cataloged in `docs/epics/04-catalog-buffer-pool-and-sql-executor/ADVERSARIAL-REVIEW.md`):
- **Task 0**: Remediate Epics 01–03 adversarial review findings (`CRIT-02`..`CRIT-07`, `HIGH-01`..`HIGH-02`, `HIGH-05`..`HIGH-09`, `MED-01`..`MED-05`, `LOW-01`..`LOW-03`) across `BTree`, `HNSW`, `Vector`, `Transaction` (CLOG + WAL commit flag), `PubSub`, `KV`, `RAG`, and `C_API`.
- **Task 1**: Implement `Nhe_O.Catalog` (`src/nhe_o-catalog.ad[sb]` in 100% `SPARK_Mode (On)`) for persistent table/column/index metadata (`pg_class` / `pg_attribute`) with Page-0 CRC32 serialization.
- **Task 2**: Implement `Nhe_O.Buffer_Pool` (`src/nhe_o-buffer_pool.ad[sb]` in 100% `SPARK_Mode (On)`) with primary 4KB slotted-page encoding (`CRIT-01`), bounded frame caching, Clock-Sweep eviction, pin tracking, and WAL-before-Data flush invariants.
- **Task 3**: Expand `Nhe_O.SQL` & `Nhe_O.JSON` (`HIGH-03`, `HIGH-04`) and implement `Nhe_O.Executor` (`src/nhe_o-executor.ad[sb]` in 100% `SPARK_Mode (On)`) connecting SQL ASTs to `Catalog`, `Buffer_Pool`, `Transaction` (MVCC + TOAST), `BTree`, and `HNSW`.
- **Task 4**: Wire stateful SQL execution and safe bounded C/Python buffer outputs into `Nhe_O.C_API`, `bindings/python/nhe_o.py`, and CLI (`src/nhe_o_main.adb` + Suite `[12/12]`).
- **Task 5**: Prove 100% SPARK Stone, Bronze (Flow), Silver (AoRTE), and Gold contracts across all new and hardened units via `gnatprove -P nhe_o.gpr` (`0 unproved` checks).

## Known issues / blockers

- **Post-Epic-03 Adversarial Review Findings (`24` issues: `7 Critical, 9 High, 5 Medium, 3 Low`)**: Documented in full in [`docs/epics/04-catalog-buffer-pool-and-sql-executor/ADVERSARIAL-REVIEW.md`](epics/04-catalog-buffer-pool-and-sql-executor/ADVERSARIAL-REVIEW.md) and scheduled for remediation in **Epic 04 (Tasks 0–5)**:
  - `CRIT-01`: Primary 4KB slotted-page tuple layout not yet implemented; `RAG_Engine` state (`Docs`, `PK_Tree`, `Vector_Graph`, `Toast_Ptr`) currently resides in volatile RAM.
  - `CRIT-02` & `CRIT-03`: `Nhe_O.BTree` is hardcoded to depth 2 (failing on the 13th sequential key, leaving 26/32 nodes unused) and `Encode_Node_Page`/`Decode_Node_Page` omit `Children`, truncate 64-bit keys to 32-bit, and lack page CRC32 checks.
  - `CRIT-04` & `CRIT-05`: `Nhe_O.Transaction` lacks a Commit Log (`CLOG`) and WAL commit-frame flag (`Is_Tuple_Visible` and `Redo_WAL_Recovery` do not filter out uncommitted/rolled-back transactions, and `Engine.Docs` overwrites `Xmin` in-place).
  - `CRIT-06` & `CRIT-07`: `Nhe_O.HNSW.Insert_Vector` links to the first 4 nodes `1..4` and overwrites slot 4 (orphaning nodes `5..N-1`), truncates `Float32`/`Int8` vectors to 64-D (`Q-003`), ignores `Scale` in `Int8` distance, returns squared L2 in `Node_Distance`, and leaves duplicate active nodes when updating an existing `Doc_Id`.
  - `HIGH-01`..`HIGH-09`: `Nhe_O.C_API` writes 512 bytes unconditionally to caller buffers, discards `Top_Parent` in `C_RAG_Query_3D`, and hardcodes `/tmp/nhe_o_c_api.db`; `Nhe_O.SQL` is currently a substring classifier rather than an AST parser; `Nhe_O.JSON` lacks a JSON-to-`JSONB_Document` parser; `Nhe_O.PubSub` ignores `Ctx` in `Flush_Committed_Notifications`; `Nhe_O.KV` is in-memory only (`Q-004`) and CLI `--kv` mis-indexes `SET`.



## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.
- `ADR-005`: Formally Verified C ABI / FFI Boundary via Precondition-Free Defensive Subprograms in 100% SPARK.

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.

