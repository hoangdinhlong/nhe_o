# NheO — Formally Verified Multi-Model Embedded Database in Ada/SPARK

> **SQLite's embedded simplicity + PostgreSQL's SQL syntax, Data Types, JSONB & `pgvector` + Redis's Key-Value Cache & Pub/Sub — 100% formally verified in SPARK, with standard Ada used strictly for physical I/O.**

---

## Overview

**NheO** is an embedded, disk-persistent, fully ACID database management system written in **Ada 2022 and SPARK 2022**:

1. **Embedded & Persistent Like SQLite**: Runs in-process with zero external server daemons, storing data in 4096-byte slotted pages (`.nheo`) backed by an append-only, CRC32-checksummed Write-Ahead Log (`.wal`).
2. **PostgreSQL Syntax & Data Types**: Native support for PostgreSQL types (`SMALLINT`/`INT2`, `INTEGER`/`INT4`, `BIGINT`/`INT8`, `REAL`/`FLOAT4`, `DOUBLE PRECISION`/`FLOAT8`, `NUMERIC`, `BOOLEAN`, `TEXT`, `BYTEA`, `UUID`, `TIMESTAMPTZ`, `JSON`, `JSONB`, `VECTOR(d)`) and PostgreSQL SQL idioms (`$1` parameters, `::type` casts, `ON CONFLICT DO UPDATE`, `RETURNING`, `LISTEN`/`NOTIFY`).
3. **Native Vector Database (`pgvector` compatible)**: Built-in `VECTOR(d)` type and formally verified similarity operators:
   - `<->` Euclidean (L2) distance
   - `<=>` Cosine distance
   - `<#>` Negative inner product
4. **PostgreSQL JSON / JSONB Engine**: Structural validation and field/containment operators (`->`, `->>`, `@>`, `?`).
5. **Full ACID via MVCC & WAL**: Multi-Version Concurrency Control (`xmin`/`xmax` snapshot isolation) combined with CRC32-verified Write-Ahead Logging and disk sync.
6. **Redis-Compatible Key-Value Cache**: Direct sub-microsecond `GET`, `SET`, `DEL`, `EXISTS`, `INCRBY`, `EXPIRE`, and `TTL` operations with deterministic TTL expiration and LRU cache eviction.
7. **In-Process Pub/Sub Messaging**: Bounded ring-buffer broker supporting `PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, and wildcard pattern subscriptions (`*`).
8. **Strict SPARK Verification Boundary (`BR-001`)**:
   - **100% of core database logic and entrypoints** (`Nheo`, `Nheo.Types`, `Nheo.Vector`, `Nheo.JSON`, `Nheo.Transaction`, `Nheo.KV`, `Nheo.PubSub`, `Nheo.SQL`, `Nheo.IO` spec, and `Nheo_Main`) are written in SPARK (`pragma SPARK_Mode (On);`) with formal `Pre` and `Post` contracts.
   - **Only physical I/O operations** (`src/nheo-io.adb`) use standard Ada (`pragma SPARK_Mode (Off);`).

---

## Architecture & Package Map

| Package / Unit | File(s) | Mode | Responsibility |
|---|---|---|---|
| `Nheo` | `src/nheo.ads` | `SPARK_Mode (On)` | Root constants, version, and engine bounds |
| `Nheo.Types` | `src/nheo-types.ad[sb]` | `SPARK_Mode (On)` | PostgreSQL data types, bounded buffers, and typed values |
| `Nheo.Vector` | `src/nheo-vector.ad[sb]` | `SPARK_Mode (On)` | `VECTOR(d)` representation and `<->`, `<=>`, `<#>` distance math |
| `Nheo.JSON` | `src/nheo-json.ad[sb]` | `SPARK_Mode (On)` | `JSON`/`JSONB` structural validation and `->`, `->>`, `@>`, `?` operators |
| `Nheo.Transaction` | `src/nheo-transaction.ad[sb]` | `SPARK_Mode (On)` | ACID transactions, MVCC `xmin`/`xmax` visibility, 4KB slotted pages & CRC32 WAL frames |
| `Nheo.KV` | `src/nheo-kv.ad[sb]` | `SPARK_Mode (On)` | Redis-like Key-Value store with TTL expiration and LRU eviction |
| `Nheo.PubSub` | `src/nheo-pubsub.ad[sb]` | `SPARK_Mode (On)` | Bounded ring-buffer Publish/Subscribe broker with wildcard matching |
| `Nheo.SQL` | `src/nheo-sql.ad[sb]` | `SPARK_Mode (On)` | PostgreSQL SQL dialect tokenizer, parser, and statement classifier |
| `Nheo_Main` | `src/nheo_main.adb` | `SPARK_Mode (On)` | Formally verified verification suite and engine entrypoint |
| `Nheo.IO` (Spec) | `src/nheo-io.ads` | `SPARK_Mode (On)` | Formal contract boundary for disk page, WAL frame, and console I/O |
| `Nheo.IO` (Body) | `src/nheo-io.adb` | `SPARK_Mode (Off)` | **Sole I/O-Only Ada implementation** (`Ada.Direct_IO`, `Stream_IO`, `Text_IO`) |

---

## Building & Running

Requires GNAT (Ada 2022) and `gprbuild` or `gnatmake`:

```bash
mkdir -p obj bin
gnatmake -gnat2022 -gnatwa -gnata -gnatQ -Isrc -D obj src/nheo_main.adb -o bin/nheo_main
./bin/nheo_main
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
