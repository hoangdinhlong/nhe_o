# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-17_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)**, **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)**, and **Epic 03 (GNATprove Formal Proofs, C ABI / FFI SDK & Interactive CLI)**. Open questions `Q-001` and `Q-002` are resolved (`ADR-003`, `ADR-004`), domain invariants (`BR-001`..`BR-007`) are ratified, and the Ada 2022 / SPARK 2022 codebase (`v0.3.0`) is implemented in **100% `pragma SPARK_Mode (On);`** across all 26 source files (`src/*.ads` and `src/*.adb`), formally verified at **100% SPARK Stone, Bronze, Silver (AoRTE) + Partial Gold** with `gnatprove 16.1.0` (**1,543 / 1,543 checks proved across all 14 units — 133 Flow, 1,285 AoRTE/Loop/Range/Overflow/Float, 125 `Pre`/`Post` Integrity Contracts — 0 unproved, 0 warnings**), runtime-verified across 11 verification suites (`alr run`) plus the Python `ctypes` SDK (`bindings/python/nhe_o.py` over `lib/libnhe_o.so`), and published to GitHub (`hoangdinhlong/nhe_o`).

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

## Next up

All committed epics (**Epic 01**, **Epic 02**, and **Epic 03**) are complete. Candidate scope for **Epic 04** (awaiting owner confirmation):
- **Epic 04 (`04-catalog-buffer-pool-and-sql-executor`)**: **Persistent System Catalog, Clock-Sweep Buffer Pool Manager & End-to-End SQL Execution Engine** — Binding `Nhe_O.SQL` ASTs directly to persistent multi-table schemas (`pg_class` / `pg_attribute` catalog on Page 0), a bounded Clock-Sweep / LRU 4KB page buffer pool with dirty-page flushing and WAL checkpointing, and full DDL/DML execution (`CREATE TABLE`, `INSERT INTO ... ON CONFLICT DO UPDATE`, `SELECT ... WHERE ... ORDER BY <-> LIMIT`, `UPDATE`, `DELETE`) in 100% SPARK Silver/Gold.

## Known issues / blockers

- None. Full Ada/SPARK toolchain (`alr 2.1.1`, `gnat_native 16.1.0`, `gprbuild 26.0.1`, `gnatprove 16.1.0`, `GNAT Studio 2026.2`, `als 2027.0`) is installed in `/home/long/Apps/`, compiles all 26 SPARK files cleanly (`alr build` & `gprbuild -P nhe_o_lib.gpr`) with zero warnings, and proves 100% of all 1,543 verification conditions (`gnatprove -P nhe_o.gpr`).


## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.
- `ADR-005`: Formally Verified C ABI / FFI Boundary via Precondition-Free Defensive Subprograms in 100% SPARK.

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.

