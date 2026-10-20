# STATUS — Nhé O

> **Start here.** Entry point for any session (per `../AGENTS.md`).
> States where the project stands, the active epic, and the next task.

_Last updated: 2026-10-20_

---

## Where we are

**Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`) — A formally verified, disk-persistent, ACID-compliant embedded multi-model database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native 4096-D Vector search, JSON/JSONB processing, Hybrid RAG & Property Graph traversal, Redis-compatible Key-Value caching, and Pub/Sub messaging.

The project has completed **Epic 01 (Scaffold and Architecture)**, **Epic 02 (B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor)** and **Epic 03 (GNATprove Formal Proofs, C ABI / FFI SDK & Interactive CLI)**. **Epic 04 (Post-Epic-03 Grooming & Core Hardening)** remediated 84 findings in Rounds 1–11 (`v0.3.0`) and was reopened for an independent full-system re-review: Rounds 12–13 found 89 more findings (`3` Critical, `17` High, `26` Medium, `43` Low — crash safety, isolation, durability, JSON / SQL fidelity, index exactness and C ABI defects), all now fixed in `v0.4.0` (`ADR-009`..`ADR-019`). Review rounds continue until one finds no defect; the `gnatprove` gate then runs again and the proof counts below are refreshed (they still describe `v0.3.0`). The Ada 2022 / SPARK 2022 codebase (`v0.4.0`) is implemented in **100% `pragma SPARK_Mode (On);`** across all 26 source files (`src/*.ads` and `src/*.adb`), last formally verified at **100% SPARK Stone, Bronze, Silver (AoRTE) + Gold** with `gnatprove 16.1.0` for `v0.3.0` (**4,246 / 4,246 checks proved across all 14 units, 0 unproved, 0 warnings**), and runtime-verified across 11 verification suites (`alr run`) plus the Python `ctypes` SDK (`bindings/python/nhe_o.py` over `lib/libnhe_o.so`). Next come **Epic 05 (Catalog, Buffer Pool & SQL Executor)** and **Epic 06 (Formally Verified Property Graph Engine `Nhe_O.Graph`, `SQL/PGQ MATCH` & Multi-Hop GraphRAG)**.

- ✅ Monion `project-docs` R8 template applied and customized.
- ✅ System vision, 100% `SPARK_Mode (On)` architecture, and domain invariants documented (`VISION.md`, `ARCHITECTURE.md`, `business-rules.md` `BR-001`..`BR-008`, `storage-and-wal-format.md`, and 11 lessons in `docs/learning/`).
- ✅ Architectural decisions recorded (`ADR-001`..`ADR-019`): the original architecture (`ADR-001`..`ADR-008`) plus the `v0.4.0` decisions — WAL protocol v2 with crash-tail repair and commit-order redo (`ADR-009`), snapshot isolation by commit sequence numbers with writer snapshots (`ADR-010`), checkpoints (`ADR-011`), the write-fault latch (`ADR-012`), the C ABI `0.4` runtime model (`ADR-013`), slot-hinted KV frames (`ADR-014`), PostgreSQL-exact JSONB (`ADR-015`), the token-level SQL validator (`ADR-016`), exact top-K and lossless B+Tree delete (`ADR-017`), exact `"VTS2"` vectors (`ADR-018`) and first-fit TOAST allocation with reserved staged pages (`ADR-019`).
- ✅ PostgreSQL Type System (`Nhe_O.Types`), SQL lexer and fail-closed token-level validator (`Nhe_O.SQL`, dialect documented at the top of `src/nhe_o-sql.ads`), 4096-D Vector Engine (`Nhe_O.Vector` with `<->`, scale-invariant `<=>`, `<#>`, scale-aware `Int8` SQ8, `1-bit` Binary Hamming, and exact `"VTS2"` vector TOAST serialization), and RFC 8259 JSON/JSONB Engine (`Nhe_O.JSON` with UTF-8 and surrogate validation, PostgreSQL `numeric` range rules, `->`, `->>`, `?`, and PostgreSQL-exact `@>` at every depth) in 100% SPARK.
- ✅ Transaction layer (`Nhe_O.Transaction`): `NO-STEAL` WAL staging whose durable commit frame is the commit point, crash-tail repair (`Repair_WAL_Tail` never truncates a file that is not a WAL), commit-order redo with `Max_Seen_Tx`, 8,192-entry CLOG, CRC32 `"SLOT"` pages and contiguous 4KB TOAST chains.
- ✅ Multi-Page B+Tree Index with lossless dense-rebuild delete repair (`Nhe_O.BTree`) and Multi-Layer HNSW Vector Graph Index returning the exact top-K (`Nhe_O.HNSW`).
- ✅ Redis-style KV Cache (`Nhe_O.KV`) with slot-exact `"KVMG"` replay, Redis `DEL` / `INCRBY` semantics and `WAL-before-Data` rollback; Dual-Mode Pub/Sub Broker (`Nhe_O.PubSub`); Universal Local LLM RAG & Hybrid SQL Executor (`Nhe_O.RAG`) with snapshot isolation (no lost updates), Stage-2 exact re-ranking of every candidate, `"RMET"` metadata TOAST, SQL `LIMIT` / `OFFSET` windows, first-fit TOAST allocation that keeps pages staged by active transactions reserved, checkpoint freeze, and self-loop-free 1-hop GraphRAG.
- ✅ C ABI `0.4` (`Nhe_O.C_API`, `include/nhe_o.h`, `lib/libnhe_o.so`): one process-wide engine with serialized calls, `nhe_o_close` / `nhe_o_checkpoint`, automatic checkpoints, write-fault latch, `O_EXCL` per-process scratch files, absolute paths, alias / swap refusal; Python SDK (`bindings/python/nhe_o.py`) with a process-wide lock and `close()`; CLI modes (`--verify`, `--sql`, `--kv`, `--rag-demo`).
- ✅ Contract-bound POSIX I/O substrate (`Nhe_O.IO`, spec and body in `SPARK_Mode => On`): `open` (including `O_EXCL`), `pread`, `pwrite`, `lseek`, `fsync` (files and directories), `ftruncate`, `close`, `unlink`, `rename`, `stat`, `getcwd`, `getpid`, `access`, with alignment checks and `EINTR` / short-read retries.

## Epic overview

| Epic | Goal | Status |
|------|------|--------|
| `01-scaffold-and-architecture` | Establish project scaffolding, 100% SPARK core & POSIX I/O subsystems | ✅ Done |
| `02-storage-indexing-and-rag-executor` | 4KB TOAST overflow, 4096-D quantized HNSW, B+Tree, Durable Pub/Sub & Universal RAG Executor | ✅ Done |
| `03-formal-proof-and-c-ffi-sdk` | `gnatprove` Flow & AoRTE Formal Proofs (100% Stone/Bronze/Silver + Partial Gold: 1,543/1,543 VCs), C ABI / Python SDK & Interactive CLI | ✅ Done |
| `04-post-epic-03-grooming-and-hardening` | Post-Epic-03 Grooming & Core Hardening: 84 findings remediated in Rounds 1–11 (`v0.3.0`, Tasks 1–20, `4,246/4,246` VCs proved); reopened for the Round 12–13 re-review (89 findings remediated, Tasks 21–22), convergence rounds and proof gate in progress (Tasks 23–24) | 🚧 Active |
| `05-catalog-buffer-pool-and-sql-executor` | Persistent Page-0 System Catalog, Clock-Sweep 4KB Buffer Pool Manager & End-to-End SQL Execution Engine | ⏳ Planned |
| `06-property-graph-and-multi-hop-graphrag` | Formally Verified Labeled Property Graph Engine (`Nhe_O.Graph`, Bi-Directional CSR `"GRPH"` Pages, `SQL/PGQ MATCH` & Multi-Hop Knowledge GraphRAG) | ⏳ Planned |

## Next up

**Active: Epic 04 convergence (`04-post-epic-03-grooming-and-hardening`, Tasks 23–24)**
- ◐ Repeat full-system adversarial review rounds (Round 14 onward), fixing every finding, until a round finds no defect.
- ☐ Run the `gnatprove` gate on the converged code (`0 unproved`, `0 warnings`) and refresh the proof counts in `README.md`, this file, `BR-001` and `ARCHITECTURE.md`.
- ☐ Then start **Epic 05 (`05-catalog-buffer-pool-and-sql-executor`)**: `Nhe_O.Catalog` (Page 0), `Nhe_O.Buffer_Pool` (Clock-Sweep 4KB frames) and `Nhe_O.Executor` (end-to-end SQL), followed by **Epic 06 (`06-property-graph-and-multi-hop-graphrag`)**.

## Known issues / blockers

- Proof counts quoted in the docs describe `v0.3.0` until the Task-24 `gnatprove` run.
- Documented limits of `v0.4.0` (by design, see the cited records): each document keeps a single prior version (`ADR-010`); snapshots do not survive a checkpoint freeze, and transaction ids restart only after the WAL is replaced (`ADR-011`); after a durable I/O error writes stay refused until the database is reopened (`ADR-012`); the C ABI drives one process-wide engine whose calls must be serialized and needs about 256 KiB of stack (`ADR-013`); `->` / `->>` return numbers and containers as their stored literal, jsonb-equal but not text-equal to PostgreSQL (`ADR-015`); read recency of KV entries is not durable (`BR-004`).

## Decisions

See `DECISIONS.md`.
- `ADR-001`: Unified Multi-Model Engine (PostgreSQL SQL/JSONB/Vector + Redis KV & Pub/Sub over Shared MVCC/WAL).
- `ADR-002`: 100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O.
- `ADR-003`: 4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG.
- `ADR-004`: Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch.
- `ADR-005`: Formally Verified C ABI / FFI Boundary via Precondition-Free Defensive Subprograms in 100% SPARK.
- `ADR-006`: NO-STEAL WAL Staging, Unified 8192-Entry CLOG, Primary `"SLOT"` Pages & TOAST Chains (`Q-003`; partially superseded by `ADR-009`, `ADR-010`, `ADR-018`).
- `ADR-007`: Dual-Mode Key-Value Store (In-Memory Cache + `"KVMG"` WAL-Before-Data Persistence) & Feature → Grooming Epic Cadence (`Q-004`).
- `ADR-008`: Native Labeled Property Graph Engine (`Nhe_O.Graph`), Bi-Directional CSR Adjacency (`"GRPH"`), `SQL/PGQ MATCH` & Multi-Hop GraphRAG (`Epic 06`).
- `ADR-009`: Crash-Consistent WAL Protocol v2: Durable-Barrier Commit Point, Torn-Tail Repair & Commit-Order Redo.
- `ADR-010`: Snapshot Isolation by Commit Sequence Numbers & First-Updater-Wins Write Conflicts.
- `ADR-011`: WAL Checkpoint: Freeze, Atomic WAL Replacement & Automatic Thresholds.
- `ADR-012`: Write-Fault Latch After Durable I/O Errors (fsync-Failure Policy).
- `ADR-013`: C ABI 0.4 Runtime Model: One Process-Wide Engine, Serialized Calls, Safe Scratch Files & Proof-Based Library Build.
- `ADR-014`: Slot-Hinted KV WAL Frames & Redis-Exact DEL / INCRBY Semantics.
- `ADR-015`: PostgreSQL-Exact JSONB Containment, UTF-8 Validation & Uniform Ingest Limits.
- `ADR-016`: Fail-Closed Token-Level SQL Validator With a Documented Dialect.
- `ADR-017`: Exact Top-K Retrieval at Bounded Capacity & Lossless B+Tree Delete Repair.
- `ADR-018`: Exact `"VTS2"` Vector TOAST Payload (IEEE 754 binary32 Words).
- `ADR-019`: First-Fit TOAST Page Allocation With Reserved Staged Pages.

Pre-decision ideas live in `ideas/`. Questions still waiting on an answer live in
`OPEN-QUESTIONS.md`.


