# Nhé O — Architecture

How we build the vision in `VISION.md`. This is the **map** for design decisions.

---

## 1. System overview

**Nhé O** (crate `nhe_o`, Ada root package `Nhe_O`) is structured as a **100% `pragma SPARK_Mode (On);` architecture** (`ADR-002`):
1. **Formally Verified Multi-Model Core (`SPARK_Mode => On`)**: Contains 100% of the database logic — data types, SQL lexer and validator, vector similarity engine, JSON/JSONB processor, ACID MVCC transaction manager, slotted-page & WAL framing logic, Redis-like Key-Value cache, and Pub/Sub broker.
2. **Contract-Bound POSIX Syscall I/O Substrate (`SPARK_Mode => On` in both `.ads` and `.adb`)**: `Nhe_O.IO` (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`) operates entirely in `SPARK_Mode (On)` by binding directly to exception-free POSIX kernel syscalls (`open` including `O_EXCL` creation, `pread`, `pwrite`, `lseek`, `fsync`, `ftruncate`, `close`, `unlink`, `rename`, `stat`, `fstat`, `flock`, `realpath`, `readlink`, `getcwd`, `getpid`, `access`, `signal`) with formally verified NUL-terminated path construction (`To_C_Path`), bounded 64-bit page offset calculation (`Valid_Page_Id`), and explicit return-code verification.

```text
+-----------------------------------------------------------------------------+
|   External Callers: CLI (`nhe_o_main`) · C99/C++ (`nhe_o.h`) · Python SDK   |
+-------------------------------------|---------------------------------------+
                                      | (Precondition-Free Defensive C ABI)
+-------------------------------------v---------------------------------------+
|            Nhé O (`Nhe_O`) Embedded DBMS — 100% pragma SPARK_Mode (On)      |
|      [6,629 / 6,629 Checks Proved: 100% SPARK Silver + Gold Contracts]      |
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
|  |   CLOG · Commit-Order Redo · 4KB Slotted Pages · CRC32 Checksum       |  |
|  +----------------------------------+------------------------------------+  |
|                                     |                                       |
|  +----------------------------------v------------------------------------+  |
|  |   Contract-Bound POSIX I/O (`Nhe_O.IO` — `nhe_o-io.ad[sb]` in SPARK)  |  |
|  |  `To_C_Path` · `Valid_Page_Id` · `pread`/`pwrite` · `lseek` · `fsync` |  |
|  +----------------------------------+------------------------------------+  |
+-------------------------------------|---------------------------------------+
                                      | (OS Kernel Syscall Boundary)
+-------------------------------------v---------------------------------------+
|  POSIX / Linux Kernel (`open`, `pread`, `pwrite`, `fsync`, `rename`, ...)  |
+-----------------------------------------------------------------------------+
```

---

## 2. Components / modules

### 2.1 100% Formally Verified Modules (`SPARK_Mode => On` in all `.ads` and `.adb` files)

- **`Nhe_O`** (`src/nhe_o.ads`): Root package defining engine constants, version identifiers, and global configuration bounds.
- **`Nhe_O.Types`** (`src/nhe_o-types.ad[sb]`): PostgreSQL-compatible type taxonomy (`Pg_Smallint`, `Pg_Integer`, `Pg_Bigint`, `Pg_Real`, `Pg_Double_Precision`, `Pg_Numeric`, `Pg_Boolean`, `Pg_Text`, `Pg_Bytea`, `Pg_UUID`, `Pg_Timestamptz`, `Pg_JSON`, `Pg_JSONB`, `Pg_Vector`), bounded byte/string buffers, status codes, and value comparison predicates.
- **`Nhe_O.Vector`** (`src/nhe_o-vector.ad[sb]`): Fixed-bound vector representation (`Vector_Value`, expanding up to `Max_Vector_Dim = 4096` per `ADR-003`) supporting `Float32`, Scalar (`Int8`), and Binary (`1-bit` Hamming) quantization alongside formally verified similarity operators matching PostgreSQL `pgvector`:
  - Euclidean / L2 distance (`<->` / `L2_Distance`; `L2_Distance_Squared` is its square)
  - Cosine distance (`<=>` / `Cosine_Distance`, scale invariant: each vector is normalized by its largest component)
  - Negative inner product (`<#>` / `Negative_Inner_Product`)
  - Dimension compatibility preconditions (`Dim_A = Dim_B`) and bounded floating-point safety preventing overflow and division by zero.
  - Exact `"VTS2"` TOAST serialization of every component's IEEE 754 binary32 bit pattern, negative zero being written as `+0.0` (`Encode_Vector_TOAST` / `Decode_Vector_TOAST`, `ADR-018`; legacy `"VTST"` payloads still decode).
- **`Nhe_O.JSON`** (`src/nhe_o-json.ad[sb]`): PostgreSQL `JSON` and `JSONB` validation (well-formed UTF-8, `\u` surrogate pairs, PostgreSQL 16 `numeric` range, uniform ingest limits), key-value field extraction (`->` object field as JSON, `->>` object field as text), key-existence (`?`), and structural containment (`@>`, one fuel-bounded recursive walker following PostgreSQL's `JsonbDeepContains` at every depth, `ADR-015`), proven free of buffer overruns.
- **`Nhe_O.Transaction`** (`src/nhe_o-transaction.ad[sb]`): ACID transaction lifecycle (`Begin_Tx`, `Commit_Tx` whose durable barrier append is the commit point, `Rollback_Tx`), the 8,192-entry CLOG, MVCC tuple headers (`Xmin`, `Xmax`) with the CLOG-only raw-tuple rule `Is_Tuple_Visible`, 4096-byte primary slotted page serialization with PostgreSQL-style 4KB TOAST overflow page chains (`Write_TOAST_Chain`, `Read_TOAST_Chain`, `ADR-003` / `BR-006`), and CRC32 WAL frame encoding, verification, torn-tail repair (`Repair_WAL_Tail`, `Repair_DB_Tail`) and commit-order crash-recovery replay (`Redo_WAL_Recovery`, `ADR-009`).
- **`Nhe_O.BTree`** (`src/nhe_o-btree.ad[sb]`): Multi-page B+Tree index mapping `Integer_64` keys to `(Target_Page, Target_Slot, TOAST_Root)` with deterministic leaf and root splitting (`Insert_Key`), lossless delete repair (`Delete_Key` rebuilds a dense tree when a leaf underflows), exact lookup (`Search_Key`), ordered range scan (`Range_Scan`, reporting truncation), and 4KB page serialization (`Encode_Node_Page` / `Decode_Node_Page`).
- **`Nhe_O.HNSW`** (`src/nhe_o-hnsw.ad[sb]`): Bounded multi-layer Hierarchical Navigable Small World (HNSW) graph index across `Float32`, `Int8` (SQ8), and `4096-D` `Binary` (1-bit Hamming) encodings; `Search_KNN` uses the graph to order candidates, then evaluates every remaining active node, so it returns the exact top-K by `Node_Distance` at the 32-node capacity (`ADR-017`). `Node_Distance` compares `Float32` / `Int8` vectors over their first `min (Dim, 64)` components (the in-node Matryoshka prefix) and binary vectors over all bits; exact full-vector ranking is RAG Stage 2.
- **`Nhe_O.KV`** (`src/nhe_o-kv.ad[sb]`): Redis-compatible high-speed Key-Value store and cache engine supporting `Set`, `Get`, `Del`, `Exists`, `Incr_By`, `Expire`, and `TTL` (plus optional `"KVMG"` WAL-durable `Set_Durable`, `Del_Durable`, `Expire_Durable`, `Incr_By_Durable`, and `Recover_KV_From_WAL`). Expired entries are never returned and are freed only by logged writes (reads never reclaim a slot), eviction is deterministic LRU, and slot-hinted `"KVMG"` frames make recovery reproduce the slot layout exactly (`ADR-014`).
- **`Nhe_O.PubSub`** (`src/nhe_o-pubsub.ad[sb]`): Bounded in-process Publish/Subscribe broker supporting `Subscribe`, `Unsubscribe`, `Publish`, and `Poll_Message` across named channels and prefix/wildcard patterns (`*`), backed by circular message queues with dual delivery modes: default fast in-memory (Redis) and optional `Durable` WAL-committed dispatch (`Stage_Notify`, `Flush_Committed_Notifications`, `Discard_Staged_Notifications`, per `ADR-004`).
- **`Nhe_O.SQL`** (`src/nhe_o-sql.ad[sb]`): PostgreSQL-faithful lexer (`Tokenize`: standard, `E''`, `N''`, `B''`/`X''` and dollar-quoted strings, nested comments, delimited identifiers) and fail-closed token-level validator and statement classifier for the dialect documented at the top of `src/nhe_o-sql.ads` (`WITH`, `SELECT` with joins and set operations, `INSERT ... ON CONFLICT ... RETURNING`, `UPDATE`, `DELETE`, `CREATE TABLE` with constraints, `BEGIN` / `COMMIT` / `ROLLBACK`, `LISTEN`, `NOTIFY`; `ADR-016`).
- **`Nhe_O.RAG`** (`src/nhe_o-rag.ad[sb]`): Universal Local LLM RAG & Hybrid SQL Query Executor unifying B+Tree primary-key indexing, multi-layer HNSW quantized search with Stage-2 exact re-ranking, `JSONB` metadata pre-filtering (`@>`), lexical keyword boosting, SQL `LIMIT` / `OFFSET` windows, 4KB TOAST parent-document chunk retrieval, 1-hop GraphRAG neighbor expansion (upgrading to Multi-Hop Knowledge GraphRAG via `Nhe_O.Graph` in Epic 06 per `ADR-008`), and `DURABLE` `rag.indexed` WAL notifications. MVCC snapshot isolation by commit sequence numbers with writer snapshots (`ADR-010`), first-fit TOAST allocation that keeps pages staged by active transactions reserved (`ADR-019`), and the checkpoint freeze (`Freeze_RAG_Engine`, `ADR-011`) live here.
- **`Nhe_O.C_API`** (`src/nhe_o-c_api.ad[sb]`): Precondition-free, defensively validated C ABI / FFI SDK layer (`Export => True, Convention => C`) operating in 100% `pragma SPARK_Mode (On);` (`ADR-005`), paired with C99/C++17 header `include/nhe_o.h` (ABI `0.4`: one process-wide engine whose calls must be serialized, one process per database through `flock` locks with per-process ownership, checkpoints, a write-fault latch after durable I/O errors, symlink-resolved paths, aliasing and page-0 database checks; `ADR-012`, `ADR-013`, `ADR-020`), Stand-Alone Shared Library project `nhe_o_lib.gpr` (`lib/libnhe_o.so`, built without `-gnata` since every assertion is proved), and Python `ctypes` SDK `bindings/python/nhe_o.py`.
- **`Nhe_O.IO`** (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`): Both specification and body operate under `pragma SPARK_Mode (On);`. Binds directly to exception-free POSIX kernel syscalls (`open` including `O_EXCL` creation, `pread`, `pwrite`, `lseek`, `fsync`, `ftruncate`, `close`, `unlink`, `rename`, `stat`, `fstat`, `flock`, `realpath`, `readlink`, `getcwd`, `getpid`, `access`, `signal`) with `Side_Effects, Import => True, Convention => C`, `Ada.Text_IO`, and `Ada.Command_Line`, verifying NUL-terminated path construction (`To_C_Path`), bounded 64-bit page offsets (`Valid_Page_Id`), exact byte counts, and hardware `fsync` completion.
- **Planned Modules (`Epic 05` & `Epic 06`, 100% `SPARK_Mode (On)`)**:
  - **`Nhe_O.Catalog`**, **`Nhe_O.Buffer_Pool`**, **`Nhe_O.Executor`** (`Epic 05`): Persistent Page-0 system catalog (`pg_class`/`pg_attribute`), Clock-Sweep 4KB page buffer pool manager, and stateful SQL DDL/DML executor.
  - **`Nhe_O.Graph`** (`Epic 06`, `ADR-008`, `BR-008`): Labeled Property Graph (LPG) engine using bi-directional index-based adjacency lists (`Out_Edges`/`In_Edges` CSR over 4KB `"GRPH"` pages), cycle-safe (`Always_Terminates`) $k$-hop BFS, Shortest Path (`BFS`/`Dijkstra`), Mutual Neighbors ($N(u) \cap N(v)$), ISO SQL:2023 `SQL/PGQ` `MATCH (a)-[e:KIND*1..k]->(b)` query integration, and Multi-Hop Knowledge GraphRAG.

---

## 3. Technology stack

| Concern | Choice |
|---------|--------|
| **Language** | Ada 2022 (`-gnat2022`) |
| **Formal Verification** | 100% SPARK 2022 (`pragma SPARK_Mode (On);` in all 26 files — **100% Stone, Bronze, Silver AoRTE & Gold Contracts**: `6,629 / 6,629` checks proved by `gnatprove 16.1.0` with `Z3`, `cvc5`, `Alt-Ergo`, `0 unproved`, `0 warnings`) |
| **Compiler & Build** | Alire `2.1.1` / GNAT `16.1.0` / `gprbuild 26.0.1` (`nhe_o.gpr` & `nhe_o_lib.gpr`) |
| **Storage Layout** | 4096-byte Primary Slotted Pages + 4KB TOAST Overflow Chains (`pread`/`pwrite`) + Positional CRC32 WAL (`lseek`/`pwrite`/`fsync`) |
| **Concurrency / Isolation** | MVCC snapshot isolation by commit sequence numbers with first-updater-wins / no-lost-update write conflicts (`ADR-010`); one process-wide engine per process, calls serialized by the caller (`ADR-013`); one process per database, enforced with exclusive `flock` locks on the database and WAL files (`ADR-020`) |
| **Vector Indexing, Graph & RAG** | Up to 4096-D (`Float32` / `Int8` / `Binary`) · Multi-Layer HNSW Graph + Multi-Page B+Tree + Hybrid JSONB/TOAST/GraphRAG + Bi-Directional CSR Property Graph (`ADR-008`, Epic 06) |
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
4. **Modular Why3 AST Verification Architecture**:
   - Test harness procedures (`src/nhe_o_main.adb`) are decomposed into discrete internal subprograms with `Always_Terminates`, avoiding monolithic Why3 AST memory explosion and enabling parallel verification across 24 cores in under 60 seconds.

---

## 5. Deployment / runtime

- **Library, Python SDK & CLI**: Compiles into a standalone CLI & verification binary `bin/nhe_o_main` (`nhe_o.gpr` — supporting `--verify`, `--sql`, `--kv`, and `--rag-demo`) and a relocatable shared library `lib/libnhe_o.so` (`nhe_o_lib.gpr`) with C header `include/nhe_o.h` and Python wrapper `bindings/python/nhe_o.py`.
- **Database Files**: A database instance consists of a database file (4KB slotted data pages, e.g. `<name>.nhe_o`) and its write-ahead log (e.g. `<name>.nhe_o.wal`); a checkpoint briefly writes `"<wal>.ckpt"` next to the WAL and renames it over the WAL (`ADR-011`).

---

## 6. Cross-cutting concerns

- **Crash Recovery & Checksums**: Every 4KB page and WAL frame carries a 32-bit CRC checksum computed in `SPARK_Mode (On)`. A torn last WAL frame or database page left by a crash is repaired before redo; a WAL path naming a file that is not a WAL, or a database path naming a file whose first page is not zero (the engine never writes page 0), is refused untouched; a corrupted frame anywhere else fails recovery closed (`ADR-009`).
- **Exception-Free Kernel Boundary**: `Nhe_O.IO` avoids `Ada.Streams.Stream_IO` / `Ada.Direct_IO` exceptions entirely by invoking POSIX kernel descriptors (`open` including `O_EXCL` creation, `pread`, `pwrite`, `lseek`, `fsync`, `ftruncate`, `close`, `unlink`, `rename`, `stat`, `fstat`, `flock`, `realpath`, `readlink`, `getcwd`, `getpid`, `access`, `signal`) that return explicit `int` / `ssize_t` status values checked inside `SPARK_Mode (On)`.

---

*See `VISION.md` for the why, `../DECISIONS.md` for the record of choices, and
`../STATUS.md` for current state and the active epic.*
