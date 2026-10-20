# Nhé O — Vision

> **A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native 4096-D Vector search, JSON/JSONB processing, Hybrid RAG & Property Graph traversal, Redis-compatible Key-Value caching, and Pub/Sub messaging.**

This document is the **north star**. Everything else (architecture, epics, decisions) exists to
serve the vision stated here. If a later decision contradicts this document, either update it or
record why it is superseded in `../DECISIONS.md`.

> **Note on intent.** **Nhé O** (Alire crate `nhe_o`, Ada root package `Nhe_O`)
> unifies the zero-configuration embedded footprint of SQLite, the rich SQL grammar and data types
> (`JSONB`, `VECTOR`) of PostgreSQL, the ultra-fast Key-Value caching and Pub/Sub semantics of
> Redis, and the multi-hop relational traversal of Labeled Property Graphs (`ADR-008`) inside a
> single formally verified Ada/SPARK codebase. **100% of all specifications and
> bodies in `src/` operate under `pragma SPARK_Mode (On);`**, including physical I/O (`src/nhe_o-io.adb`)
> via contract-bound POSIX kernel syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`, `access`).

---

## 1. The problem

Modern applications — especially local-first AI agents, social/knowledge graphs, edge systems, and high-assurance services — typically require five distinct data primitives:
1. **Relational ACID Storage** with expressive SQL and strong data types (PostgreSQL).
2. **Vector Similarity Search** for embeddings and semantic retrieval (`pgvector`).
3. **Structured Document Queries** over semi-structured payloads (`JSON` / `JSONB`).
4. **Low-Latency Key-Value Caching & Event Pub/Sub** for state caching and real-time notifications (Redis).
5. **Labeled Property Graph & Multi-Hop Traversal** for social networks, permission hierarchies (ReBAC), lineage, and multi-hop Knowledge GraphRAG (Neo4j / Apache AGE / KùzuDB).

Developers are forced either to run a heavy fleet of external server daemons (PostgreSQL + pgvector + Neo4j/AGE + Redis) or to settle for embedded engines written in C/C++ (SQLite + extensions) that lack PostgreSQL type fidelity, lack native KV/Pub-Sub/Graph integration, and remain susceptible to memory corruption, integer overflows, and subtle concurrency bugs.

---

## 2. The product

**Nhé O** (crate `nhe_o`, Ada root package `Nhe_O`) is a single-binary, embeddable multi-model database management system written in **Ada 2022 and SPARK 2022**:
- **SQLite-Style Embedded Footprint**: Runs directly in-process or as a lightweight local engine backed by a deterministic disk page file and Write-Ahead Log (WAL). Zero external servers required.
- **PostgreSQL Syntax & Data Types**: Supports PostgreSQL-compatible SQL syntax (`$1` parameters, `::type` casts, `CREATE TABLE IF NOT EXISTS`, `RETURNING`, `ON CONFLICT DO UPDATE`) and native PostgreSQL data types (`INT2`, `INT4`, `INT8`, `FLOAT4`, `FLOAT8`, `NUMERIC`, `BOOLEAN`, `TEXT`, `BYTEA`, `UUID`, `TIMESTAMPTZ`, `JSON`, `JSONB`, `VECTOR`) via `Nhe_O.Types` and `Nhe_O.SQL` *(persistent Page-0 Catalog, Clock-Sweep Buffer Pool, and multi-table SQL Executor scheduled in **Epic 05**)*.
- **Native Vector Database & Quantized HNSW**: First-class `VECTOR(d)` column and value type (up to `4096` dimensions) with `Float32`, scale-preserving `Int8` (SQ8), and `1-bit` Binary Hamming quantization, Multi-Layer HNSW indexing, and formally verified L2 distance (`<->`), cosine distance (`<=>`), and negative inner product (`<#>`) operators.
- **PostgreSQL JSON / JSONB Engine**: Strict RFC 8259 structural validation, `\uXXXX` UTF-8 escape decoding, structured `JSONB_Document` storage, and `->`, `->>`, `@>` (multi-level structural containment), and `?` (key-existence) operators.
- **Full ACID, `NO-STEAL` WAL, TOAST Overflow & Disk Persistence**: Multi-Version Concurrency Control (MVCC) with snapshot isolation (`xmin`/`xmax` over an 8,192-entry `Commit_Log`) paired with `NO-STEAL` CRC32-checksummed Write-Ahead Logging (WAL), 2-pass committed-only recovery, slotted 4KB primary disk pages (`"SLOT"`), non-overlapping 4KB TOAST overflow page chains (`"TOAS"`, `"VTST"`, `"RMET"`), and Multi-Page B+Tree indexing.
- **Redis-Grade Dual-Mode Key-Value Store & Pub/Sub**: Direct high-speed KV operations (`GET`, `SET`, `DEL`, `INCRBY`, `EXPIRE`, `TTL`) with deterministic TTL expiration, LRU eviction, and optional `"KVMG"` WAL-durable persistence (`Set_Durable`, `Del_Durable`, `Expire_Durable`, `Incr_By_Durable`), plus an in-process Pub/Sub message broker (`PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, `*` glob pattern matching) supporting both immediate in-memory delivery and `DURABLE` WAL-committed notifications (`LISTEN`/`NOTIFY`).
- **Universal Local LLM RAG, Labeled Property Graph & C/Python FFI SDK**: Two-stage Hybrid RAG (`Stage-1` HNSW + `Stage-2` `"VTST"` 4096-D exact TOAST re-ranking + `"RMET"` metadata TOAST) & 1-hop GraphRAG executor (`Nhe_O.RAG`) evolving into a full bi-directional CSR **Labeled Property Graph & Multi-Hop Knowledge GraphRAG Engine (`Nhe_O.Graph`, `SQL/PGQ MATCH`, `ADR-008` — Epic 06)**, exposed via a precondition-free C ABI (`include/nhe_o.h`, `lib/libnhe_o.so`) and Python `ctypes` SDK (`bindings/python/nhe_o.py`).
- **100% SPARK Verified Codebase (Silver + Gold)**: Every single module specification and body (26/26 files across 14 units in `src/`, including `Nhe_O.IO` and `Nhe_O.C_API`) operates under `pragma SPARK_Mode (On);` with zero occurrences of `SPARK_Mode (Off)`, achieving **4,246 / 4,246 formal checks proved (0 unproved, 0 warnings)** with `gnatprove 16.1.0`.

---

## 3. North-star capabilities

1. **PostgreSQL-Compatible SQL & Type Engine**: Parse and execute PostgreSQL DDL/DML with strict type checking and type casting (`::int4`, `::jsonb`, `::vector`).
2. **Provably Safe Vector Search**: Execute exact and approximate nearest-neighbor queries using `<->`, `<=>`, and `<#>` with SPARK-verified dimension invariants and absence of floating-point overflow/divide-by-zero.
3. **Rich JSON/JSONB Querying**: Store and query nested JSON documents using PostgreSQL's `->`, `->>`, `@>`, and `?` operators without memory safety vulnerabilities.
4. **Crash-Safe ACID Persistence**: Guarantee atomicity, consistency, snapshot isolation, and durability across power loss or process crashes via WAL redo recovery, hardware `fsync`, and page checksums.
5. **Embedded Redis-Compatible Cache**: Sub-microsecond in-memory Key-Value reads/writes with optional TTL expiration, LRU bounded eviction, and transparent WAL persistence.
6. **Real-Time & Transactional Pub/Sub Channels**: Publish and subscribe to named channels or wildcard patterns using bounded ring buffers with zero dynamic heap allocation and optional WAL-commit gating.
7. **Cycle-Safe Labeled Property Graph & Multi-Hop GraphRAG (`ADR-008`)**: Traverse $k$-hop directed labeled relationships (`Out_Edges`/`In_Edges` CSR over 4KB `"GRPH"` pages), compute shortest paths (`BFS`/`Dijkstra`) and mutual neighbors ($N(u) \cap N(v)$), and execute `SQL/PGQ MATCH` + 4096-D Vector GraphRAG queries with mathematically proven termination (`Always_Terminates`) even on cyclic graphs.
8. **100% `SPARK_Mode (On)` Verification (Stone / Bronze / Silver / Gold)**: Enforce that 100% of parsing, B+Tree/HNSW/Graph indexing, transaction visibility, vector math, JSON traversal, KV caching, Pub/Sub routing, C FFI boundaries (`Nhe_O.C_API`), and POSIX syscall I/O orchestration (`Nhe_O.IO`) operate under `SPARK_Mode (On)` with 100% proved Absence of Run-Time Errors (Silver) and key domain integrity contracts (Gold).


---

## 4. Principles

1. **100% `SPARK_Mode (On)` Everywhere (`BR-001` / `ADR-002`)**: No specification or body in `src/` may disable `SPARK_Mode`. Physical disk I/O in `Nhe_O.IO` binds directly to exception-free POSIX syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`, `unlink`, `access`) under `SPARK_Mode (On)`.
2. **Bounded & Deterministic Memory**: Avoid unbounded heap allocations inside the verified engine. Use bounded structures, fixed-size slotted pages (4096 bytes), and explicit capacity contracts (`Pre` / `Post` / `Type_Invariant`).
3. **PostgreSQL Ergonomics in an Embedded Package**: Users should write familiar PostgreSQL queries, JSONB expressions, and `pgvector` operators without managing a database server.
4. **ACID Without Compromise**: Caching speed must never corrupt durable state; MVCC visibility and WAL checksum invariants are enforced by formal contracts.

---

## 5. Non-goals

1. **Multi-Node Distributed Consensus (Raft/Paxos)**: Nhé O is an embedded single-node/in-process database engine like SQLite, not a distributed cluster database.
2. **Unverified JIT / Dynamic Scripting Extensions**: Stored procedures in unverified dynamic languages (e.g., PL/Python, PL/V8) are out of scope to preserve the formal SPARK safety proof.
