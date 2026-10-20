# Nhé O — Formally Verified Multi-Model Embedded Database in Ada/SPARK

> **SQLite's embedded simplicity + PostgreSQL's SQL syntax, Data Types, JSONB & `pgvector` + Redis's Key-Value Cache & Pub/Sub + Hybrid RAG & Property Graph — 100% formally verified in SPARK (`pragma SPARK_Mode (On);`), including contract-bound POSIX physical I/O.**

---

## Overview

**Nhé O** (Alire crate/repository `nhe_o`, Ada root package `Nhe_O`) is an embedded, disk-persistent, ACID-compliant multi-model database management system written in **Ada 2022 and SPARK 2022**:

1. **Embedded & Persistent Like SQLite**: Runs in-process with zero external server daemons, storing data in 4096-byte slotted pages (`.nhe_o`) with non-overlapping PostgreSQL-style 4KB TOAST overflow chains (`"TOAS"`, `"VTST"`, `"RMET"`) backed by a 4,120-byte CRC32-checksummed Write-Ahead Log (`.wal`).
2. **PostgreSQL Syntax & Data Types**: Native support for PostgreSQL types (`SMALLINT`/`INT2`, `INTEGER`/`INT4`, `BIGINT`/`INT8`, `REAL`/`FLOAT4`, `DOUBLE PRECISION`/`FLOAT8`, `NUMERIC`, `BOOLEAN`, `TEXT`, `BYTEA`, `UUID`, `TIMESTAMPTZ`, `JSON`, `JSONB`, `VECTOR(d)`) and PostgreSQL SQL idioms (`$1` parameters, `::type` casts, `CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO UPDATE`, `RETURNING`, `LISTEN`/`NOTIFY`) via `Nhe_O.Types` and `Nhe_O.SQL` *(stateful multi-table Page-0 Catalog, Clock-Sweep Buffer Pool, and DDL/DML Executor scheduled in **Epic 05**)*.
3. **Native 4096-D Vector Database & Quantized HNSW (`pgvector` compatible)**: Built-in `VECTOR(d)` type (up to `4096` dimensions for local LLMs like `Qwen3-Embedding-8B`, `text-embedding-3-large`, `bge-m3`), `Float32`, scale-preserving `Int8` (SQ8), and `1-bit` Binary Hamming quantization, Multi-Layer HNSW graph indexing (`Insert_Vector`, `Remove_Vector`, `Restore_Vector_Node`, `Search_KNN`), and formally verified similarity operators:
   - `<->` Euclidean (L2) distance
   - `<=>` Cosine distance
   - `<#>` Negative inner product
4. **PostgreSQL JSON / JSONB Engine**: Strict RFC 8259 validation, `\uXXXX` UTF-8 escape decoding, structured `JSONB_Document` storage, and field/multi-level containment operators (`->`, `->>`, `@>`, `?`).
5. **Full ACID via MVCC, `NO-STEAL` WAL & 2-Pass Recovery**: Multi-Version Concurrency Control (`xmin`/`xmax` snapshot isolation over a unified 8,192-entry `Commit_Log`) combined with `NO-STEAL` commit-gated page persistence, Multi-Page B+Tree indexing (with leaf compaction/reclamation), hardware `fsync`, and 2-pass committed-only WAL redo recovery.
6. **Redis-Compatible Dual-Mode Key-Value Store**: Sub-microsecond in-memory `GET`, `SET`, `DEL`, `EXISTS`, `INCRBY`, `EXPIRE`, and `TTL` operations (`Global => null`) with deterministic TTL expiration and LRU eviction, plus optional `"KVMG"` WAL-durable persistence (`Set_Durable`, `Del_Durable`, `Expire_Durable`, `Incr_By_Durable`, `Recover_KV_From_WAL`) with `WAL-before-Data` rollback on I/O failure.
7. **Dual-Mode Pub/Sub Messaging**: Bounded ring-buffer broker supporting `PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, general `*` glob wildcard pattern subscriptions, and PostgreSQL-style `DURABLE` WAL-committed notification dispatch (`LISTEN`/`NOTIFY`).
8. **Universal Local LLM Hybrid RAG, Property Graph & C/Python SDK**: Two-stage Hybrid RAG execution combining B+Tree PK lookup, Stage-1 HNSW candidate generation, Stage-2 `"VTST"` 4096-D exact TOAST re-ranking, `"RMET"` lossless summary/JSONB metadata TOAST chains, `@>` pre-filtering, lexical keyword boosting, and 1-hop GraphRAG expansion — evolving into a full bi-directional CSR **Labeled Property Graph & Multi-Hop Knowledge GraphRAG Engine (`Nhe_O.Graph`, `SQL/PGQ MATCH` in Epic 06 / `ADR-008`)** — exposed via a formally verified C ABI (`include/nhe_o.h`, `lib/libnhe_o.so`) and Python `ctypes` SDK (`bindings/python/nhe_o.py`).
9. **100% SPARK Verification Mandate (`BR-001` / `ADR-002` / `ADR-005`)**:
   - **100% of specifications, bodies, and entrypoints** (all 26 files across 14 units in `src/`) operate under `pragma SPARK_Mode (On);` with zero occurrences of `SPARK_Mode (Off)` and zero `pragma Assume` statements.
   - **4,246 / 4,246 Formal Checks Proved (100% SPARK Stone, Bronze, Silver & Gold Contracts)**: Verified by `gnatprove 16.1.0` (`Why3` + `Z3` + `cvc5` + `Alt-Ergo`) with `0 unproved` checks, `0 justified` checks, and `0 warnings` (max proof time `< 1s`).
   - **Contract-Bound POSIX I/O (`src/nhe_o-io.adb`)**: Physical disk operations bypass exception-raising `Ada.Streams.Stream_IO` and bind directly in `SPARK_Mode (On)` to atomic POSIX kernel syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`, `access`).

---

## SPARK Formal Verification Levels (Stone → Platinum)

Evaluated across all **14 compilation units (26 `.ads`/`.adb` files)** in `src/` via `gnatprove -P nhe_o.gpr --mode=all --level=2`:

| SPARK Level | Assurance Objective | Coverage / Proved % | Proved Checks (`gnatprove`) | Details |
|---|---|---|---|---|
| **Stone** | Valid SPARK 2022 Subset (`SPARK_Mode (On)`) | **100.0%** (`26 / 26` files) | `14 / 14` units (`257 / 257` Ada subprograms/packages + `10` POSIX C syscall bindings) | Zero `SPARK_Mode (Off)` anywhere in `src/` (`BR-001`). |
| **Bronze** | Initialization & Correct Data Flow (`--mode=flow`) | **100.0%** | **`1,316 / 1,316`** (`0 unproved`) | `171` Data Dependencies, `920` Initialization, `2` Non-Aliasing, `223` Flow Termination. |
| **Silver** | Absence of Run-Time Errors (AoRTE) & Termination | **100.0%** | **`1,587 / 1,587`** prover checks (`2,903 / 2,903` incl. Bronze) | `1,519` Run-time Checks (overflow, range, index, division, discriminant) + `68` Prover Termination checks (`0` `pragma Assume`). |
| **Gold** | Proof of Key Integrity Properties & Functional Contracts | **100.0%** of specified contracts | **`1,343 / 1,343`** prover checks (`4,246 / 4,246` cumulative) | `807` Functional Contracts (`Pre`/`Post`) + `536` Inductive Loop Invariants & Assertions (`0 unproved`, `0 justified`, `0` `Post => True` tautologies). |
| **Platinum** | Full Functional Equivalence & Complete Ghost Model Proof | **~35%** *(Scoped to Core Invariants)* | Proven on core state machines; full Ghost relational model planned for Epic 05+ | Proves `CLOG` state machine, `BTree.Total_Keys` conservation, `KV` `WAL-before-Data` rollback (`Store = Store'Old`), and C ABI defensive bounds. |

### `gnatprove` Check Breakdown (`4,246 / 4,246` Total — `0 Unproved`, `0 Warnings`)

| Category | Total | Flow Analysis | SMT Provers (`cvc5`, `Z3`, `Alt-Ergo`) | Justified | Unproved |
|---|---:|---:|---:|---:|---:|
| Data Dependencies | `171` | `171` | — | `0` | `0` |
| Initialization | `920` | `920` | — | `0` | `0` |
| Non-Aliasing | `2` | `2` | — | `0` | `0` |
| Run-time Checks (AoRTE) | `1,519` | — | `1,519` (`cvc5` 96%, `Trivial` 4%, `Z3` 1%) | `0` | `0` |
| Assertions & Loop Invariants | `536` | — | `536` (`cvc5` 99%, `Z3` 1%, `Trivial` <1%) | `0` | `0` |
| Functional Contracts (`Pre`/`Post`) | `807` | — | `807` (`cvc5` 95%, `Z3` 3%, `Trivial` 2%) | `0` | `0` |
| Termination | `291` | `223` | `68` (`cvc5` 100%) | `0` | `0` |
| **Total** | **`4,246`** | **`1,316` (31%)** | **`2,930` (69%)** | **`0`** | **`0`** |

---

## Architecture & Package Map

Following professional Ada Quality & Style Guide (`Mixed_Case_With_Underscores` for identifiers) and GNAT/Alire file naming conventions (`_` for word separators inside an identifier, `-` for child package hierarchy):

| Package / Unit | File(s) | Mode | Responsibility |
|---|---|---|---|
| `Nhe_O` | `src/nhe_o.ads` | `SPARK_Mode (On)` | Root constants, version (`0.3.0`), and engine bounds |
| `Nhe_O.Types` | `src/nhe_o-types.ad[sb]` | `SPARK_Mode (On)` | PostgreSQL data types, bounded buffers, and typed values |
| `Nhe_O.Vector` | `src/nhe_o-vector.ad[sb]` | `SPARK_Mode (On)` | 4096-D `VECTOR(d)`, `Float32`/`Int8`/`Binary` quantization, and `<->`, `<=>`, `<#>` math |
| `Nhe_O.JSON` | `src/nhe_o-json.ad[sb]` | `SPARK_Mode (On)` | `JSON`/`JSONB` structural validation and `->`, `->>`, `@>`, `?` operators |
| `Nhe_O.Transaction` | `src/nhe_o-transaction.ad[sb]` | `SPARK_Mode (On)` | ACID MVCC, 4KB slotted pages, TOAST overflow chains, CRC32 WAL & redo recovery |
| `Nhe_O.BTree` | `src/nhe_o-btree.ad[sb]` | `SPARK_Mode (On)` | Multi-page B+Tree primary-key index with deterministic node splitting |
| `Nhe_O.HNSW` | `src/nhe_o-hnsw.ad[sb]` | `SPARK_Mode (On)` | Multi-layer HNSW graph index across `Float32`, `Int8`, and `Binary` vectors |
| `Nhe_O.KV` | `src/nhe_o-kv.ad[sb]` | `SPARK_Mode (On)` | Redis-like Key-Value store with TTL expiration and LRU eviction |
| `Nhe_O.PubSub` | `src/nhe_o-pubsub.ad[sb]` | `SPARK_Mode (On)` | Dual-mode in-memory + `DURABLE` WAL-committed Publish/Subscribe broker |
| `Nhe_O.SQL` | `src/nhe_o-sql.ad[sb]` | `SPARK_Mode (On)` | PostgreSQL SQL dialect tokenizer, parser, and statement classifier |
| `Nhe_O.RAG` | `src/nhe_o-rag.ad[sb]` | `SPARK_Mode (On)` | Universal Local LLM Hybrid RAG & 1-hop GraphRAG query executor |
| `Nhe_O.C_API` | `src/nhe_o-c_api.ad[sb]` | `SPARK_Mode (On)` | Precondition-free defensive C ABI / FFI boundary (`include/nhe_o.h`, `lib/libnhe_o.so`) |
| `Nhe_O.IO` | `src/nhe_o-io.ad[sb]` | `SPARK_Mode (On)` | Contract-bound POSIX syscall I/O (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`, `access`) |
| `Nhe_O_Main` | `src/nhe_o_main.adb` | `SPARK_Mode (On)` | 11-suite verification harness and interactive CLI (`--verify`, `--sql`, `--kv`, `--rag-demo`) |

---

## Building, Formal Verification & Running

Requires Alire (`alr`), GNAT (`gnat_native` Ada 2022), `gprbuild`, and `gnatprove`:

```bash
# 1. Build and run all 11 verification suites (CLI binary bin/nhe_o_main)
alr build
alr run

# 2. Run CLI modes directly
./bin/nhe_o_main --sql "SELECT id, content FROM docs WHERE meta @> '{\"lang\":\"vi\"}' ORDER BY emb <=> \$1 LIMIT 5;"
./bin/nhe_o_main --kv SET session:user:42 '{"role":"admin"}' 300
./bin/nhe_o_main --rag-demo

# 3. Build shared library (lib/libnhe_o.so) and run Python ctypes SDK test suite
gprbuild -P nhe_o_lib.gpr
python3 bindings/python/nhe_o.py

# 4. Run formal SPARK verification (4,246 / 4,246 checks proved — 0 unproved)
gnatprove -P nhe_o.gpr --mode=all --level=2 -j24
```

---

## Documentation Map (Monion `project-docs` R8)

- [`AGENTS.md`](AGENTS.md) — Instructions for AI coding agents working in this repository.
- [`docs/STATUS.md`](docs/STATUS.md) — Current project status, active epic, and next tasks.
- [`docs/reference/VISION.md`](docs/reference/VISION.md) — Product vision, capabilities, and guiding principles.
- [`docs/reference/ARCHITECTURE.md`](docs/reference/ARCHITECTURE.md) — Technical architecture and SPARK/Ada boundary design.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — Authoritative Architectural Decision Records (`ADR-001`..`ADR-008`).
- [`docs/domain/business-rules.md`](docs/domain/business-rules.md) — Core database and formal verification invariants (`BR-001`..`BR-008`).
- [`docs/domain/storage-and-wal-format.md`](docs/domain/storage-and-wal-format.md) — Binary byte layouts for `"SLOT"` pages, `"TOAS"`/`"VTST"`/`"RMET"` chains, `"BTRE"` nodes, `"KVMG"` KV WAL pages, and 4,120-byte WAL frames.
- [`docs/learning/README.md`](docs/learning/README.md) — Teaching corpus (`swe/` & `ai/` lessons) explaining the concepts behind our ADRs.
- [`docs/OPEN-QUESTIONS.md`](docs/OPEN-QUESTIONS.md) — Open architectural questions awaiting benchmarks or owner decisions.
- [`docs/_meta/SELF-AUDIT.md`](docs/_meta/SELF-AUDIT.md) — End-of-session verification checklist.

---

## License

Released under the [MIT License](LICENSE).
