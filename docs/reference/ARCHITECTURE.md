# Nhé O — Architecture

How we build the vision in `VISION.md`. This is the **map** for design decisions.

---

## 1. System overview

**Nhé O** (crate `nhe_o`, Ada root package `Nhe_O`) is structured as a **100% `pragma SPARK_Mode (On);` architecture** (`ADR-002`):
1. **Formally Verified Multi-Model Core (`SPARK_Mode => On`)**: Contains 100% of the database logic — data types, SQL parser/planner, vector similarity engine, JSON/JSONB processor, ACID MVCC transaction manager, slotted-page & WAL framing logic, Redis-like Key-Value cache, and Pub/Sub broker.
2. **Contract-Bound POSIX Syscall I/O Substrate (`SPARK_Mode => On` in both `.ads` and `.adb`)**: `Nhe_O.IO` (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`) operates entirely in `SPARK_Mode (On)` by binding directly to exception-free POSIX kernel syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`) with formally verified NUL-terminated path construction (`To_C_Path`), bounded 64-bit page offset calculation (`Valid_Page_Id`), and explicit return-code verification.

```text
+-----------------------------------------------------------------------------+
|   External Callers: CLI (`nhe_o_main`) · C99/C++ (`nhe_o.h`) · Python SDK   |
+-------------------------------------|---------------------------------------+
                                      | (Precondition-Free Defensive C ABI)
+-------------------------------------v---------------------------------------+
|            Nhé O (`Nhe_O`) Embedded DBMS — 100% pragma SPARK_Mode (On)      |
|      [2,863 / 2,863 Checks Proved: 100% SPARK Silver + Gold Contracts]      |
|                                                                             |
|  +----------------------+ +-------------------+ +------------------------+  |
|  |  PostgreSQL SQL &    | |   Redis-Compatible| |  Dual-Mode Pub/Sub     |  |
|  |  Hybrid RAG Executor | |   KV Cache Engine | |  Broker (Mem + WAL)    |  |
|  |  (`SQL` / `RAG`)     | |   (`Nhe_O.KV`)    | |  (`Nhe_O.PubSub`)      |  |
|  +----------+-----------+ +---------+---------+ +-----------+------------+  |
|             |                       |                       |               |
|  +----------v-----------------------v-----------------------v------------+  |
|  |           Multi-Model Data, Vector & Indexing Engines                 |  |
|  |  +-----------------+   +-------------------+   +-------------------+  |  |
|  |  | PG Type & JSONB |   | 4096-D Vector &   |   | Multi-Page B+Tree |  |  |
|  |  | (`Types`/`JSON`)|   | Quantized HNSW    |   | Primary Key Index |  |  |
|  |  | ->, ->>, @>, ?  |   | (`Vector`/`HNSW`) |   | (`Nhe_O.BTree`)   |  |  |
|  |  +-----------------+   +-------------------+   +-------------------+  |  |
|  +----------------------------------+------------------------------------+  |
|                                     |                                       |
|  +----------------------------------v------------------------------------+  |
|  |    ACID Storage, MVCC, 4KB TOAST & WAL Framing (`Nhe_O.Transaction`)  |  |
|  |   Snapshot Isolation (xmin/xmax) · 4KB Slotted Pages · CRC32 Checksum |  |
|  +----------------------------------+------------------------------------+  |
|                                     |                                       |
|  +----------------------------------v------------------------------------+  |
|  |   Contract-Bound POSIX I/O (`Nhe_O.IO` — `nhe_o-io.ad[sb]` in SPARK)  |  |
|  |  `To_C_Path` · `Valid_Page_Id` · `pread`/`pwrite` · `lseek` · `fsync` |  |
|  +----------------------------------+------------------------------------+  |
+-------------------------------------|---------------------------------------+
                                      | (OS Kernel Syscall Boundary)
+-------------------------------------v---------------------------------------+
|     POSIX / Linux Kernel (`open`, `pread`, `pwrite`, `lseek`, `fsync`)      |
+-----------------------------------------------------------------------------+
```

---

## 2. Components / modules

### 2.1 100% Formally Verified Modules (`SPARK_Mode => On` in all `.ads` and `.adb` files)

- **`Nhe_O`** (`src/nhe_o.ads`): Root package defining engine constants, version identifiers, and global configuration bounds.
- **`Nhe_O.Types`** (`src/nhe_o-types.ad[sb]`): PostgreSQL-compatible type taxonomy (`Pg_Smallint`, `Pg_Integer`, `Pg_Bigint`, `Pg_Real`, `Pg_Double_Precision`, `Pg_Numeric`, `Pg_Boolean`, `Pg_Text`, `Pg_Bytea`, `Pg_UUID`, `Pg_Timestamptz`, `Pg_JSON`, `Pg_JSONB`, `Pg_Vector`), bounded byte/string buffers, status codes, and value comparison predicates.
- **`Nhe_O.Vector`** (`src/nhe_o-vector.ad[sb]`): Fixed-bound vector representation (`Vector_Value`, expanding up to `Max_Vector_Dim = 4096` per `ADR-003`) supporting `Float32`, Scalar (`Int8`), and Binary (`1-bit` Hamming) quantization alongside formally verified similarity operators matching PostgreSQL `pgvector`:
  - Euclidean / L2 distance (`<->` / `L2_Distance_Squared`)
  - Cosine distance (`<=>` / `Cosine_Distance`)
  - Negative inner product (`<#>` / `Negative_Inner_Product`)
  - Dimension compatibility preconditions (`Dim_A = Dim_B`) and bounded floating-point safety preventing overflow and division by zero.
- **`Nhe_O.JSON`** (`src/nhe_o-json.ad[sb]`): PostgreSQL `JSON` and `JSONB` validation, key-value field extraction (`->` object field as JSON, `->>` object field as text), key-existence (`?`), and structural containment (`@>`), proven free of buffer overruns.
- **`Nhe_O.Transaction`** (`src/nhe_o-transaction.ad[sb]`): ACID transaction lifecycle (`Begin_Tx`, `Commit_Tx`, `Rollback_Tx`), MVCC tuple headers (`Xmin`, `Xmax`), snapshot visibility predicate (`Is_Tuple_Visible`), 4096-byte primary slotted page serialization with PostgreSQL-style 4KB TOAST overflow page chains (`Write_TOAST_Chain`, `Read_TOAST_Chain`, `ADR-003` / `BR-006`), and CRC32 WAL frame encoding, verification, and crash-recovery replay (`Redo_WAL_Recovery`).
- **`Nhe_O.BTree`** (`src/nhe_o-btree.ad[sb]`): Multi-page B+Tree index mapping `Integer_64` keys to `(Target_Page, Target_Slot, TOAST_Root)` with deterministic leaf and root splitting (`Insert_Key`), exact lookup (`Search_Key`), ordered range scan (`Range_Scan`), and 4KB page serialization (`Encode_Node_Page` / `Decode_Node_Page`).
- **`Nhe_O.HNSW`** (`src/nhe_o-hnsw.ad[sb]`): Bounded multi-layer Hierarchical Navigable Small World (HNSW) graph index supporting sub-linear ANN search (`Search_KNN`) across `Float32`, `Int8` (SQ8), and `4096-D` `Binary` (1-bit Hamming) encodings.
- **`Nhe_O.KV`** (`src/nhe_o-kv.ad[sb]`): Redis-compatible high-speed Key-Value store and cache engine supporting `Set`, `Get`, `Del`, `Exists`, `Incr_By`, `Expire`, and `TTL` (plus optional `"KVMG"` WAL-durable `Set_Durable`, `Del_Durable`, `Expire_Durable`, `Incr_By_Durable`, and `Recover_KV_From_WAL`). Enforces lazy and active TTL expiration and deterministic LRU eviction when the cache reaches capacity.
- **`Nhe_O.PubSub`** (`src/nhe_o-pubsub.ad[sb]`): Bounded in-process Publish/Subscribe broker supporting `Subscribe`, `Unsubscribe`, `Publish`, and `Poll_Message` across named channels and prefix/wildcard patterns (`*`), backed by circular message queues with dual delivery modes: default fast in-memory (Redis) and optional `Durable` WAL-committed dispatch (`Stage_Notify`, `Flush_Committed_Notifications`, `Discard_Staged_Notifications`, per `ADR-004`).
- **`Nhe_O.SQL`** (`src/nhe_o-sql.ad[sb]`): Tokenizer, parser, and statement classifier for PostgreSQL-dialect SQL (`CREATE TABLE`, `INSERT INTO ... ON CONFLICT`, `SELECT ... WHERE ... ORDER BY embedding <-> $1`, `BEGIN`, `COMMIT`, `ROLLBACK`, `LISTEN`, `NOTIFY`).
- **`Nhe_O.RAG`** (`src/nhe_o-rag.ad[sb]`): Universal Local LLM RAG & Hybrid SQL Query Executor unifying B+Tree primary-key indexing, multi-layer HNSW quantized ANN search, `JSONB` metadata pre-filtering (`@>`), lexical keyword boosting, 4KB TOAST parent-document chunk retrieval, 1-hop GraphRAG neighbor expansion, and `DURABLE` `rag.indexed` WAL notifications.
- **`Nhe_O.C_API`** (`src/nhe_o-c_api.ad[sb]`): Precondition-free, defensively validated C ABI / FFI SDK layer (`Export => True, Convention => C`) operating in 100% `pragma SPARK_Mode (On);` (`ADR-005`), paired with C99/C++17 header `include/nhe_o.h`, Stand-Alone Shared Library project `nhe_o_lib.gpr` (`lib/libnhe_o.so`), and Python `ctypes` SDK `bindings/python/nhe_o.py`.
- **`Nhe_O.IO`** (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`): Both specification and body operate under `pragma SPARK_Mode (On);`. Binds directly to exception-free POSIX kernel syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`) with `Side_Effects, Import => True, Convention => C`, `Ada.Text_IO`, and `Ada.Command_Line`, verifying NUL-terminated path construction (`To_C_Path`), bounded 64-bit page offsets (`Valid_Page_Id`), exact byte counts, and hardware `fsync` completion.

---

## 3. Technology stack

| Concern | Choice |
|---------|--------|
| **Language** | Ada 2022 (`-gnat2022`) |
| **Formal Verification** | 100% SPARK 2022 (`pragma SPARK_Mode (On);` in all 26 files — **100% Stone, Bronze, Silver AoRTE & Gold Contracts**: `2,863 / 2,863` checks proved by `gnatprove 16.1.0` with `Z3`, `cvc5`, `Alt-Ergo`) |
| **Compiler & Build** | Alire `2.1.1` / GNAT `16.1.0` / `gprbuild 26.0.1` (`nhe_o.gpr` & `nhe_o_lib.gpr`) |
| **Storage Layout** | 4096-byte Primary Slotted Pages + 4KB TOAST Overflow Chains (`pread`/`pwrite`) + Positional CRC32 WAL (`lseek`/`pwrite`/`fsync`) |
| **Concurrency / Isolation** | MVCC Snapshot Isolation (`xmin`/`xmax`) |
| **Vector Indexing & RAG** | Up to 4096-D (`Float32` / `Int8` / `Binary`) · Multi-Layer HNSW Graph + Multi-Page B+Tree + Hybrid JSONB/TOAST/GraphRAG |
| **C ABI / FFI & SDKs** | `Nhe_O.C_API` (`lib/libnhe_o.so`) · C99/C++17 (`include/nhe_o.h`) · Python `ctypes` (`bindings/python/nhe_o.py`) |



---

## 4. Key conventions

1. **The 100% SPARK Rule (`BR-001` / `ADR-002`)**:
   - Every single specification (`.ads`) and body (`.adb`) in `src/` **must** begin with `pragma SPARK_Mode (On);`.
   - Zero files in `src/` may specify `pragma SPARK_Mode (Off);`.
2. **Zero Unbounded Allocation in Verified Units**:
   - All strings, byte pages, vectors, JSON tokens, KV tables, and Pub/Sub queues use statically bounded arrays and subtypes so `GNATprove` can prove 100% Absence of Run-Time Errors (AoRTE).
3. **Professional Ada / Alire / GNAT Naming**:
   - Alire crate and GPR project file use lowercase `snake_case`: `nhe_o` (`nhe_o.gpr`).
   - Hierarchical Ada identifiers use `Mixed_Case_With_Underscores`: `Nhe_O.<Module>`, mapped to GNAT krunched filenames `src/nhe_o-<module>.ads` and `src/nhe_o-<module>.adb` (`_` inside identifier, `-` for child package hierarchy).

---

## 5. Deployment / runtime

- **Library, Python SDK & CLI**: Compiles into a standalone CLI & verification binary `bin/nhe_o_main` (`nhe_o.gpr` — supporting `--verify`, `--sql`, `--kv`, and `--rag-demo`) and a relocatable shared library `lib/libnhe_o.so` (`nhe_o_lib.gpr`) with C header `include/nhe_o.h` and Python wrapper `bindings/python/nhe_o.py`.
- **Database Files**: A database instance consists of `<name>.nhe_o` (4KB slotted data pages) and `<name>.nhe_o.wal` (write-ahead log frames).

---

## 6. Cross-cutting concerns

- **Crash Recovery & Checksums**: Every 4KB page and WAL frame carries a 32-bit CRC checksum computed in `SPARK_Mode (On)`. Torn writes or corrupted frames are detected deterministically before mutation.
- **Exception-Free Kernel Boundary**: `Nhe_O.IO` avoids `Ada.Streams.Stream_IO` / `Ada.Direct_IO` exceptions entirely by invoking POSIX kernel descriptors (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`) that return explicit `int` / `ssize_t` status values checked inside `SPARK_Mode (On)`.

---

*See `VISION.md` for the why, `../DECISIONS.md` for the record of choices, and
`../STATUS.md` for current state and the active epic.*
