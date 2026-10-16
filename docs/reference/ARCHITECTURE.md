# NheO — Architecture

How we build the vision in `VISION.md`. This is the **map** for design decisions.

---

## 1. System overview

NheO is structured as a strict two-zone architecture:
1. **The Formally Verified Core (`SPARK_Mode => On`)**: Contains 100% of the database logic — data types, SQL parser/planner, vector similarity engine, JSON/JSONB processor, ACID MVCC transaction manager, slotted-page & WAL framing logic, Redis-like Key-Value cache, and Pub/Sub broker.
2. **The Isolated I/O Substrate (`SPARK_Mode => Off` in package body only)**: A thin, contract-guarded byte-page and WAL file persistence layer (`Nheo.IO`) that translates verified page/frame buffers into OS disk reads, writes, and `fsync` calls.

```text
+-----------------------------------------------------------------------------+
|                              NheO Embedded DBMS                             |
|                                                                             |
|  +-----------------------------------------------------------------------+  |
|  |            FORMALLY VERIFIED CORE (pragma SPARK_Mode (On))            |  |
|  |                                                                       |  |
|  |  +----------------------+ +-------------------+ +------------------+  |  |
|  |  |  PostgreSQL SQL &    | |   Redis-Compatible| |  Pub/Sub Event   |  |  |
|  |  |  Query Planner       | |   KV Cache Engine | |  Broker (RingBuf)|  |  |
|  |  |  (`Nheo.SQL`)        | |   (`Nheo.KV`)     | |  (`Nheo.PubSub`) |  |  |
|  |  +----------+-----------+ +---------+---------+ +--------+---------+  |  |
|  |             |                       |                    |            |  |
|  |  +----------v-----------------------v--------------------v---------+  |  |
|  |  |               Multi-Model Data & Operator Engines               |  |  |
|  |  |  +-----------------+  +------------------+  +----------------+  |  |  |
|  |  |  | PG Type System  |  | Vector Engine    |  | JSON / JSONB   |  |  |  |
|  |  |  | (`Nheo.Types`)  |  | (`Nheo.Vector`)  |  | (`Nheo.JSON`)  |  |  |  |
|  |  |  | INT2/4/8, TEXT, |  | <-> L2, <=> Cos, |  | ->, ->>, @>, ? |  |  |  |
|  |  |  | UUID, NUMERIC   |  | <#> Inner Prod   |  | Structural AST |  |  |  |
|  |  |  +-----------------+  +------------------+  +----------------+  |  |  |
|  |  +----------------------------------+------------------------------+  |  |
|  |                                     |                                 |  |
|  |  +----------------------------------v------------------------------+  |  |
|  |  |          ACID Storage, MVCC & WAL Framing (`Nheo.Transaction`)  |  |  |
|  |  |   Snapshot Isolation (xmin/xmax) · 4KB Slotted Pages · CRC32    |  |  |
|  |  +----------------------------------+------------------------------+  |  |
|  |                                     |                                 |  |
|  |  +----------------------------------v------------------------------+  |  |
|  |  |          Formal I/O Contract Specification (`nheo-io.ads`)      |  |  |
|  |  +----------------------------------+------------------------------+  |  |
|  +-------------------------------------|---------------------------------+  |
|                                        | (Strict SPARK Verification Boundary)|
|  +-------------------------------------v---------------------------------+  |
|  |         ISOLATED I/O IMPLEMENTATION (`nheo-io.adb` — Ada Only)        |  |
|  |     `pragma SPARK_Mode (Off)` · Direct Page I/O · WAL Append · fsync  |  |
|  +-----------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------+
```

---

## 2. Components / modules

### 2.1 Formally Verified Core (`SPARK_Mode => On` in both `.ads` and `.adb`)

- **`Nheo`** (`src/nheo.ads`): Root package defining engine constants, version identifiers, and global configuration bounds.
- **`Nheo.Types`** (`src/nheo-types.ad[sb]`): PostgreSQL-compatible type taxonomy (`Pg_Int2`, `Pg_Int4`, `Pg_Int8`, `Pg_Float4`, `Pg_Float8`, `Pg_Numeric`, `Pg_Bool`, `Pg_Text`, `Pg_Bytea`, `Pg_UUID`, `Pg_Timestamptz`, `Pg_JSON`, `Pg_JSONB`, `Pg_Vector`), bounded byte/string buffers, status codes, and value comparison predicates.
- **`Nheo.Vector`** (`src/nheo-vector.ad[sb]`): Fixed-bound vector representation (`Vector_Value`) and formally verified similarity operators matching PostgreSQL `pgvector`:
  - Euclidean / L2 distance (`<->` / `L2_Distance_Squared`)
  - Cosine distance (`<=>` / `Cosine_Distance`)
  - Negative inner product (`<#>` / `Negative_Inner_Product`)
  - Dimension compatibility preconditions (`Dim_A = Dim_B`) and bounded floating-point safety preventing overflow and division by zero.
- **`Nheo.JSON`** (`src/nheo-json.ad[sb]`): PostgreSQL `JSON` and `JSONB` validation, key-value field extraction (`->` object field as JSON, `->>` object field as text), key-existence (`?`), and structural containment (`@>`), proven free of buffer overruns.
- **`Nheo.Transaction`** (`src/nheo-transaction.ad[sb]`): ACID transaction lifecycle (`Begin_Tx`, `Commit_Tx`, `Rollback_Tx`), MVCC tuple headers (`Xmin`, `Xmax`), snapshot visibility predicate (`Is_Tuple_Visible`), 4096-byte slotted page serialization, and CRC32 WAL frame encoding/verification.
- **`Nheo.KV`** (`src/nheo-kv.ad[sb]`): Redis-compatible high-speed Key-Value store and cache engine supporting `Set`, `Get`, `Del`, `Exists`, `Incr_By`, `Expire`, and `TTL`. Enforces lazy and active TTL expiration and deterministic LRU eviction when the cache reaches capacity.
- **`Nheo.PubSub`** (`src/nheo-pubsub.ad[sb]`): Bounded in-process Publish/Subscribe broker supporting `Subscribe`, `Unsubscribe`, `Publish`, and `Poll_Message` across named channels and prefix/wildcard patterns (`*`), backed by circular message queues.
- **`Nheo.SQL`** (`src/nheo-sql.ad[sb]`): Tokenizer, parser, and statement classifier for PostgreSQL-dialect SQL (`CREATE TABLE`, `INSERT INTO ... ON CONFLICT`, `SELECT ... WHERE ... ORDER BY embedding <-> $1`, `BEGIN`, `COMMIT`, `ROLLBACK`, `LISTEN`, `NOTIFY`).
- **`Nheo.IO` Specification** (`src/nheo-io.ads`): `SPARK_Mode => On` interface declaring page-level and WAL-frame disk read/write/sync contracts (`Write_Page`, `Read_Page`, `Append_WAL_Frame`, `Sync_Disk`).

### 2.2 Isolated I/O Layer (`SPARK_Mode => Off` in `.adb` only)

- **`Nheo.IO` Body** (`src/nheo-io.adb`): The **only** engine package body permitted to use `pragma SPARK_Mode (Off);`. Implements physical file I/O using `Ada.Streams.Stream_IO` / OS descriptors with defensive exception handling that maps any OS I/O error into verified `IO_Status` codes without raising unhandled exceptions across the SPARK boundary.

---

## 3. Technology stack

| Concern | Choice |
|---------|--------|
| **Language** | Ada 2022 (`-gnat2022`) |
| **Formal Verification** | SPARK 2022 (`pragma SPARK_Mode (On);` / `gnatprove`) |
| **Compiler & Build** | GNAT 16+ / `gprbuild` (`nheo.gpr`) |
| **Storage Layout** | 4096-byte Slotted Pages + Append-Only CRC32 Write-Ahead Log (WAL) |
| **Concurrency / Isolation** | MVCC Snapshot Isolation (`xmin`/`xmax`) |
| **Vector Indexing** | Exact Flat Scan + Bounded Navigable Small World (HNSW) Graph |

---

## 4. Key conventions

1. **The Golden SPARK Rule (`BR-001`)**:
   - Every core specification (`.ads`) and body (`.adb`) **must** begin with `pragma SPARK_Mode (On);`.
   - Only `src/nheo-io.adb` (and human CLI demo entrypoints using `Ada.Text_IO`) may specify `pragma SPARK_Mode (Off);`.
2. **Zero Unbounded Allocation in Verified Units**:
   - All strings, byte pages, vectors, JSON tokens, KV tables, and Pub/Sub queues use statically bounded arrays and subtypes so `GNATprove` can prove 100% Absence of Run-Time Errors (AoRTE).
3. **Package & File Naming**:
   - Hierarchical Ada naming `Nheo.<Module>` mapped to lowercase hyphenated filenames `nheo-<module>.ads` and `nheo-<module>.adb`.

---

## 5. Deployment / runtime

- **Library & CLI**: Compiles into a static/shared library linkable into any Ada, C, C++, or Rust host application, plus a standalone CLI binary `bin/nheo_main`.
- **Database Files**: A database instance consists of `<name>.nheo` (4KB slotted data pages) and `<name>.nheo.wal` (write-ahead log frames).

---

## 6. Cross-cutting concerns

- **Crash Recovery & Checksums**: Every 4KB page and WAL frame carries a 32-bit CRC checksum computed in `SPARK_Mode (On)`. Torn writes or corrupted frames are detected deterministically before mutation.
- **Boundary Error Containment**: `Nheo.IO` catches all `Ada.IO_Exceptions` inside `nheo-io.adb` and returns explicit `IO_Result` records so no exception ever crosses into SPARK code.

---

*See `VISION.md` for the why, `../DECISIONS.md` for the record of choices, and
`../STATUS.md` for current state and the active epic.*
