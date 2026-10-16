# Nhé O — Formally Verified Multi-Model Embedded Database in Ada/SPARK

> **SQLite's embedded simplicity + PostgreSQL's SQL syntax, Data Types, JSONB & `pgvector` + Redis's Key-Value Cache & Pub/Sub — 100% formally verified in SPARK (`pragma SPARK_Mode (On);`), including contract-bound POSIX physical I/O.**

---

## Overview

**Nhé O** (Alire crate/repository `nhe_o`, Ada root package `Nhe_O`) is an embedded, disk-persistent, fully ACID database management system written in **Ada 2022 and SPARK 2022**:

1. **Embedded & Persistent Like SQLite**: Runs in-process with zero external server daemons, storing data in 4096-byte slotted pages (`.nhe_o`) backed by an append-only, CRC32-checksummed Write-Ahead Log (`.wal`).
2. **PostgreSQL Syntax & Data Types**: Native support for PostgreSQL types (`SMALLINT`/`INT2`, `INTEGER`/`INT4`, `BIGINT`/`INT8`, `REAL`/`FLOAT4`, `DOUBLE PRECISION`/`FLOAT8`, `NUMERIC`, `BOOLEAN`, `TEXT`, `BYTEA`, `UUID`, `TIMESTAMPTZ`, `JSON`, `JSONB`, `VECTOR(d)`) and PostgreSQL SQL idioms (`$1` parameters, `::type` casts, `ON CONFLICT DO UPDATE`, `RETURNING`, `LISTEN`/`NOTIFY`).
3. **Native Vector Database (`pgvector` compatible)**: Built-in `VECTOR(d)` type and formally verified similarity operators:
   - `<->` Euclidean (L2) distance
   - `<=>` Cosine distance
   - `<#>` Negative inner product
4. **PostgreSQL JSON / JSONB Engine**: Structural validation and field/containment operators (`->`, `->>`, `@>`, `?`).
5. **Full ACID via MVCC & WAL**: Multi-Version Concurrency Control (`xmin`/`xmax` snapshot isolation) combined with CRC32-verified Write-Ahead Logging and hardware `fsync`.
6. **Redis-Compatible Key-Value Cache**: Direct sub-microsecond `GET`, `SET`, `DEL`, `EXISTS`, `INCRBY`, `EXPIRE`, and `TTL` operations with deterministic TTL expiration and LRU cache eviction.
7. **In-Process Pub/Sub Messaging**: Bounded ring-buffer broker supporting `PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, and wildcard pattern subscriptions (`*`).
8. **100% SPARK Verification Mandate (`BR-001` / `ADR-002`)**:
   - **100% of specifications, bodies, and entrypoints** (`Nhe_O`, `Nhe_O.Types`, `Nhe_O.Vector`, `Nhe_O.JSON`, `Nhe_O.Transaction`, `Nhe_O.KV`, `Nhe_O.PubSub`, `Nhe_O.SQL`, `Nhe_O.IO` spec & body, and `Nhe_O_Main`) operate under `pragma SPARK_Mode (On);` with zero occurrences of `SPARK_Mode (Off)`.
   - **Contract-Bound POSIX I/O (`src/nhe_o-io.adb`)**: Physical disk operations bypass exception-raising `Ada.Streams.Stream_IO` and bind directly in `SPARK_Mode (On)` to atomic POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) with formally verified NUL-terminated path construction (`To_C_Path`), embedded-NUL path rejection (`Has_Embedded_NUL`), bounded 64-bit page offset arithmetic (`Valid_Page_Id`), and explicit status verification.

---

## Architecture & Package Map

Following professional Ada Quality & Style Guide (`Mixed_Case_With_Underscores` for identifiers) and GNAT/Alire file naming conventions (`_` for word separators inside an identifier, `-` for child package hierarchy):

| Package / Unit | File(s) | Mode | Responsibility |
|---|---|---|---|
| `Nhe_O` | `src/nhe_o.ads` | `SPARK_Mode (On)` | Root constants, version, and engine bounds |
| `Nhe_O.Types` | `src/nhe_o-types.ad[sb]` | `SPARK_Mode (On)` | PostgreSQL data types, bounded buffers, and typed values |
| `Nhe_O.Vector` | `src/nhe_o-vector.ad[sb]` | `SPARK_Mode (On)` | `VECTOR(d)` representation and `<->`, `<=>`, `<#>` distance math |
| `Nhe_O.JSON` | `src/nhe_o-json.ad[sb]` | `SPARK_Mode (On)` | `JSON`/`JSONB` structural validation and `->`, `->>`, `@>`, `?` operators |
| `Nhe_O.Transaction` | `src/nhe_o-transaction.ad[sb]` | `SPARK_Mode (On)` | ACID transactions, MVCC `xmin`/`xmax` visibility, 4KB slotted pages & CRC32 WAL frames |
| `Nhe_O.KV` | `src/nhe_o-kv.ad[sb]` | `SPARK_Mode (On)` | Redis-like Key-Value store with TTL expiration and LRU eviction |
| `Nhe_O.PubSub` | `src/nhe_o-pubsub.ad[sb]` | `SPARK_Mode (On)` | Bounded ring-buffer Publish/Subscribe broker with wildcard matching |
| `Nhe_O.SQL` | `src/nhe_o-sql.ad[sb]` | `SPARK_Mode (On)` | PostgreSQL SQL dialect tokenizer, parser, and statement classifier |
| `Nhe_O.IO` (Spec) | `src/nhe_o-io.ads` | `SPARK_Mode (On)` | Formal contract specification for positional disk page, WAL frame, and console I/O |
| `Nhe_O.IO` (Body) | `src/nhe_o-io.adb` | `SPARK_Mode (On)` | Contract-bound POSIX syscall I/O (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) |
| `Nhe_O_Main` | `src/nhe_o_main.adb` | `SPARK_Mode (On)` | Formally verified verification suite and engine entrypoint |

---

## Building & Running

Requires GNAT (Ada 2022) and `gprbuild` or `gnatmake`:

```bash
mkdir -p obj bin
gnatmake -gnat2022 -gnatwa -gnata -gnatQ -Isrc -D obj src/nhe_o_main.adb -o bin/nhe_o_main
./bin/nhe_o_main
```

---

## Documentation Map (Monion `project-docs` R8)

- [`AGENTS.md`](AGENTS.md) — Instructions for AI coding agents working in this repository.
- [`docs/STATUS.md`](docs/STATUS.md) — Current project status, active epic, and next tasks.
- [`docs/reference/VISION.md`](docs/reference/VISION.md) — Product vision, capabilities, and guiding principles.
- [`docs/reference/ARCHITECTURE.md`](docs/reference/ARCHITECTURE.md) — Technical architecture and SPARK/Ada boundary design.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — Authoritative Architectural Decision Records (ADRs).
- [`docs/domain/business-rules.md`](docs/domain/business-rules.md) — Core database and formal verification invariants (`BR-001`..`BR-005`).
- [`docs/OPEN-QUESTIONS.md`](docs/OPEN-QUESTIONS.md) — Open architectural questions awaiting benchmarks or owner decisions.
- [`docs/_meta/SELF-AUDIT.md`](docs/_meta/SELF-AUDIT.md) — End-of-session verification checklist.
