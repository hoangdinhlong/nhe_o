# nhe_o (`Nhe_O`) — Architecture

How we build the vision in `VISION.md`. This is the **map** for design decisions.

---

## 1. System overview

`nhe_o` (`Nhe_O`) is structured as a **100% `pragma SPARK_Mode (On);` architecture** (`ADR-005`):
1. **Formally Verified Multi-Model Core (`SPARK_Mode => On`)**: Contains 100% of the database logic — data types, SQL parser/planner, vector similarity engine, JSON/JSONB processor, ACID MVCC transaction manager, slotted-page & WAL framing logic, Redis-like Key-Value cache, and Pub/Sub broker.
2. **Contract-Bound POSIX Syscall I/O Substrate (`SPARK_Mode => On` in both `.ads` and `.adb`)**: `Nhe_O.IO` (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`) operates entirely in `SPARK_Mode (On)` by binding directly to exception-free POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) with formally verified NUL-terminated path construction (`To_C_Path`), bounded 64-bit page offset calculation (`Valid_Page_Id`), and explicit return-code verification.

```text
+-----------------------------------------------------------------------------+
|                Nhe_O Embedded DBMS — 100% pragma SPARK_Mode (On)            |
|                                                                             |
|  +----------------------+ +-------------------+ +------------------------+  |
|  |  PostgreSQL SQL &    | |   Redis-Compatible| |  Pub/Sub Event         |  |
|  |  Query Planner       | |   KV Cache Engine | |  Broker (RingBuf)      |  |
|  |  (`Nhe_O.SQL`)       | |   (`Nhe_O.KV`)    | |  (`Nhe_O.PubSub`)      |  |
|  +----------+-----------+ +---------+---------+ +-----------+------------+  |
|             |                       |                       |               |
|  +----------v-----------------------v-----------------------v------------+  |
|  |                  Multi-Model Data & Operator Engines                  |  |
|  |  +-----------------+   +-------------------+   +-------------------+  |  |
|  |  | PG Type System  |   | Vector Engine     |   | JSON / JSONB      |  |  |
|  |  | (`Nhe_O.Types`) |   | (`Nhe_O.Vector`)  |   | (`Nhe_O.JSON`)    |  |  |
|  |  | INT2/4/8, TEXT, |   | <-> L2, <=> Cos,  |   | ->, ->>, @>, ?    |  |  |
|  |  | UUID, NUMERIC   |   | <#> Inner Prod    |   | Structural AST    |  |  |
|  |  +-----------------+   +-------------------+   +-------------------+  |  |
|  +----------------------------------+------------------------------------+  |
|                                     |                                       |
|  +----------------------------------v------------------------------------+  |
|  |         ACID Storage, MVCC & WAL Framing (`Nhe_O.Transaction`)        |  |
|  |   Snapshot Isolation (xmin/xmax) · 4KB Slotted Pages · CRC32 Checksum |  |
|  +----------------------------------+------------------------------------+  |
|                                     |                                       |
|  +----------------------------------v------------------------------------+  |
|  |   Contract-Bound POSIX I/O (`Nhe_O.IO` — `nhe_o-io.ad[sb]` in SPARK)  |  |
|  |  `To_C_Path` · `Valid_Page_Id` · `pread`/`pwrite` · `write` · `fsync` |  |
|  +----------------------------------+------------------------------------+  |
+-------------------------------------|---------------------------------------+
                                      | (OS Kernel Syscall Boundary)
+-------------------------------------v---------------------------------------+
|             POSIX / Linux Kernel (`open`, `pread`, `pwrite`, `fsync`)       |
+-----------------------------------------------------------------------------+
```

---

## 2. Components / modules

### 2.1 100% Formally Verified Modules (`SPARK_Mode => On` in all `.ads` and `.adb` files)

- **`Nhe_O`** (`src/nhe_o.ads`): Root package defining engine constants, version identifiers, and global configuration bounds.
- **`Nhe_O.Types`** (`src/nhe_o-types.ad[sb]`): PostgreSQL-compatible type taxonomy (`Pg_Int2`, `Pg_Int4`, `Pg_Int8`, `Pg_Float4`, `Pg_Float8`, `Pg_Numeric`, `Pg_Bool`, `Pg_Text`, `Pg_Bytea`, `Pg_UUID`, `Pg_Timestamptz`, `Pg_JSON`, `Pg_JSONB`, `Pg_Vector`), bounded byte/string buffers, status codes, and value comparison predicates.
- **`Nhe_O.Vector`** (`src/nhe_o-vector.ad[sb]`): Fixed-bound vector representation (`Vector_Value`) and formally verified similarity operators matching PostgreSQL `pgvector`:
  - Euclidean / L2 distance (`<->` / `L2_Distance_Squared`)
  - Cosine distance (`<=>` / `Cosine_Distance`)
  - Negative inner product (`<#>` / `Negative_Inner_Product`)
  - Dimension compatibility preconditions (`Dim_A = Dim_B`) and bounded floating-point safety preventing overflow and division by zero.
- **`Nhe_O.JSON`** (`src/nhe_o-json.ad[sb]`): PostgreSQL `JSON` and `JSONB` validation, key-value field extraction (`->` object field as JSON, `->>` object field as text), key-existence (`?`), and structural containment (`@>`), proven free of buffer overruns.
- **`Nhe_O.Transaction`** (`src/nhe_o-transaction.ad[sb]`): ACID transaction lifecycle (`Begin_Tx`, `Commit_Tx`, `Rollback_Tx`), MVCC tuple headers (`Xmin`, `Xmax`), snapshot visibility predicate (`Is_Tuple_Visible`), 4096-byte slotted page serialization, and CRC32 WAL frame encoding/verification.
- **`Nhe_O.KV`** (`src/nhe_o-kv.ad[sb]`): Redis-compatible high-speed Key-Value store and cache engine supporting `Set`, `Get`, `Del`, `Exists`, `Incr_By`, `Expire`, and `TTL`. Enforces lazy and active TTL expiration and deterministic LRU eviction when the cache reaches capacity.
- **`Nhe_O.PubSub`** (`src/nhe_o-pubsub.ad[sb]`): Bounded in-process Publish/Subscribe broker supporting `Subscribe`, `Unsubscribe`, `Publish`, and `Poll_Message` across named channels and prefix/wildcard patterns (`*`), backed by circular message queues.
- **`Nhe_O.SQL`** (`src/nhe_o-sql.ad[sb]`): Tokenizer, parser, and statement classifier for PostgreSQL-dialect SQL (`CREATE TABLE`, `INSERT INTO ... ON CONFLICT`, `SELECT ... WHERE ... ORDER BY embedding <-> $1`, `BEGIN`, `COMMIT`, `ROLLBACK`, `LISTEN`, `NOTIFY`).
- **`Nhe_O.IO`** (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`): Both specification and body operate under `pragma SPARK_Mode (On);`. Binds directly to exception-free POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) with `Side_Effects, Import => True, Convention => C` and `Ada.Text_IO`, verifying NUL-terminated path construction (`To_C_Path`), bounded 64-bit page offsets (`Valid_Page_Id`), exact byte counts, and hardware `fsync` completion.

---

## 3. Technology stack

| Concern | Choice |
|---------|--------|
| **Language** | Ada 2022 (`-gnat2022`) |
| **Formal Verification** | 100% SPARK 2022 (`pragma SPARK_Mode (On);` in all 18 files) |
| **Compiler & Build** | GNAT 16+ / `gprbuild` (`nhe_o.gpr`) |
| **Storage Layout** | 4096-byte Slotted Pages (`pread`/`pwrite`) + Append-Only CRC32 WAL (`write`/`fsync`) |
| **Concurrency / Isolation** | MVCC Snapshot Isolation (`xmin`/`xmax`) |
| **Vector Indexing** | Exact Flat Scan + Bounded Navigable Small World (HNSW) Graph |

---

## 4. Key conventions

1. **The 100% SPARK Rule (`BR-001` / `ADR-005`)**:
   - Every single specification (`.ads`) and body (`.adb`) in `src/` **must** begin with `pragma SPARK_Mode (On);`.
   - Zero files in `src/` may specify `pragma SPARK_Mode (Off);`.
2. **Zero Unbounded Allocation in Verified Units**:
   - All strings, byte pages, vectors, JSON tokens, KV tables, and Pub/Sub queues use statically bounded arrays and subtypes so `GNATprove` can prove 100% Absence of Run-Time Errors (AoRTE).
3. **Professional Ada / Alire / GNAT Naming (`ADR-004`)**:
   - Alire crate and GPR project file use lowercase `snake_case`: `nhe_o` (`nhe_o.gpr`).
   - Hierarchical Ada identifiers use `Mixed_Case_With_Underscores`: `Nhe_O.<Module>`, mapped to GNAT krunched filenames `src/nhe_o-<module>.ads` and `src/nhe_o-<module>.adb` (`_` inside identifier, `-` for child package hierarchy).

---

## 5. Deployment / runtime

- **Library & CLI**: Compiles into a static/shared library linkable into any Ada, C, C++, or Rust host application, plus a standalone CLI binary `bin/nhe_o_main`.
- **Database Files**: A database instance consists of `<name>.nhe_o` (4KB slotted data pages) and `<name>.nhe_o.wal` (write-ahead log frames).

---

## 6. Cross-cutting concerns

- **Crash Recovery & Checksums**: Every 4KB page and WAL frame carries a 32-bit CRC checksum computed in `SPARK_Mode (On)`. Torn writes or corrupted frames are detected deterministically before mutation.
- **Exception-Free Kernel Boundary**: `Nhe_O.IO` avoids `Ada.Streams.Stream_IO` / `Ada.Direct_IO` exceptions entirely by invoking POSIX kernel descriptors (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`) that return explicit `int` / `ssize_t` status values checked inside `SPARK_Mode (On)`.

---

*See `VISION.md` for the why, `../DECISIONS.md` for the record of choices, and
`../STATUS.md` for current state and the active epic.*
