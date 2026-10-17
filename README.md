# Nhé O — Formally Verified Multi-Model Embedded Database in Ada/SPARK

> **SQLite's embedded simplicity + PostgreSQL's SQL syntax, Data Types, JSONB & `pgvector` + Redis's Key-Value Cache & Pub/Sub — 100% formally verified in SPARK (`pragma SPARK_Mode (On);`), including contract-bound POSIX physical I/O.**

---

## Overview

**Nhé O** (Alire crate/repository `nhe_o`, Ada root package `Nhe_O`) is an embedded, disk-persistent, fully ACID database management system written in **Ada 2022 and SPARK 2022**:

1. **Embedded & Persistent Like SQLite**: Runs in-process with zero external server daemons, storing data in 4096-byte slotted pages (`.nhe_o`) with PostgreSQL-style 4KB TOAST overflow chains backed by an append-only, CRC32-checksummed Write-Ahead Log (`.wal`).
2. **PostgreSQL Syntax & Data Types**: Native support for PostgreSQL types (`SMALLINT`/`INT2`, `INTEGER`/`INT4`, `BIGINT`/`INT8`, `REAL`/`FLOAT4`, `DOUBLE PRECISION`/`FLOAT8`, `NUMERIC`, `BOOLEAN`, `TEXT`, `BYTEA`, `UUID`, `TIMESTAMPTZ`, `JSON`, `JSONB`, `VECTOR(d)`) and PostgreSQL SQL idioms (`$1` parameters, `::type` casts, `ON CONFLICT DO UPDATE`, `RETURNING`, `LISTEN`/`NOTIFY`).
3. **Native 4096-D Vector Database & Quantized HNSW (`pgvector` compatible)**: Built-in `VECTOR(d)` type (up to `4096` dimensions for local LLMs like `Qwen3-Embedding-8B`, `text-embedding-3-large`, `bge-m3`), `Float32`, `Int8` (SQ8), and `1-bit` Binary Hamming quantization, Multi-Layer HNSW graph indexing, and formally verified similarity operators:
   - `<->` Euclidean (L2) distance
   - `<=>` Cosine distance
   - `<#>` Negative inner product
4. **PostgreSQL JSON / JSONB Engine**: Structural validation and field/containment operators (`->`, `->>`, `@>`, `?`).
5. **Full ACID via MVCC, TOAST & WAL**: Multi-Version Concurrency Control (`xmin`/`xmax` snapshot isolation) combined with 4KB TOAST overflow chains, Multi-Page B+Tree indexing, CRC32-verified Write-Ahead Logging, hardware `fsync`, and deterministic WAL redo recovery.
6. **Redis-Compatible Key-Value Cache**: Direct sub-microsecond `GET`, `SET`, `DEL`, `EXISTS`, `INCRBY`, `EXPIRE`, and `TTL` operations with deterministic TTL expiration and LRU cache eviction.
7. **Dual-Mode Pub/Sub Messaging**: Bounded ring-buffer broker supporting `PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, wildcard pattern subscriptions (`*`), and PostgreSQL-style `DURABLE` WAL-committed notification dispatch (`LISTEN`/`NOTIFY`).
8. **Universal Local LLM Hybrid RAG & C/Python SDK**: Single-pass execution combining B+Tree PK lookup, HNSW ANN vector search, JSONB metadata pre-filtering (`@>`), lexical keyword boosting, TOAST chunk retrieval, and 1-hop GraphRAG expansion — exposed via a formally verified C ABI (`include/nhe_o.h`, `lib/libnhe_o.so`) and Python `ctypes` SDK (`bindings/python/nhe_o.py`).
9. **100% SPARK Verification Mandate (`BR-001` / `ADR-002` / `ADR-005`)**:
   - **100% of specifications, bodies, and entrypoints** (all 26 files across 14 units in `src/`) operate under `pragma SPARK_Mode (On);` with zero occurrences of `SPARK_Mode (Off)`.
   - **1,543 / 1,543 Formal Checks Proved (100% SPARK Stone, Bronze & Silver + Partial Gold)**: Verified by `gnatprove 16.1.0` (`Why3` + `Z3` + `cvc5` + `Alt-Ergo`) with `0 unproved` checks and `0 warnings`.
   - **Contract-Bound POSIX I/O (`src/nhe_o-io.adb`)**: Physical disk operations bypass exception-raising `Ada.Streams.Stream_IO` and bind directly in `SPARK_Mode (On)` to atomic POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`).

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
| `Nhe_O.IO` | `src/nhe_o-io.ad[sb]` | `SPARK_Mode (On)` | Contract-bound POSIX syscall I/O (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) |
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

# 4. Run formal SPARK verification (1,543 / 1,543 checks proved — 0 unproved)
gnatprove -P nhe_o.gpr --mode=all --level=2
```

---

## Documentation Map (Monion `project-docs` R8)

- [`AGENTS.md`](AGENTS.md) — Instructions for AI coding agents working in this repository.
- [`docs/STATUS.md`](docs/STATUS.md) — Current project status, active epic, and next tasks.
- [`docs/reference/VISION.md`](docs/reference/VISION.md) — Product vision, capabilities, and guiding principles.
- [`docs/reference/ARCHITECTURE.md`](docs/reference/ARCHITECTURE.md) — Technical architecture and SPARK/Ada boundary design.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — Authoritative Architectural Decision Records (`ADR-001`..`ADR-005`).
- [`docs/domain/business-rules.md`](docs/domain/business-rules.md) — Core database and formal verification invariants (`BR-001`..`BR-007`).
- [`docs/learning/README.md`](docs/learning/README.md) — Teaching corpus (`swe/` & `ai/` lessons) explaining the concepts behind our ADRs.
- [`docs/OPEN-QUESTIONS.md`](docs/OPEN-QUESTIONS.md) — Open architectural questions awaiting benchmarks or owner decisions.
- [`docs/_meta/SELF-AUDIT.md`](docs/_meta/SELF-AUDIT.md) — End-of-session verification checklist.

---

## License

Released under the [MIT License](LICENSE).
