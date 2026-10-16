# NheO — Vision

> **A formally verified, disk-persistent, ACID-compliant embedded database engine written in Ada/SPARK featuring PostgreSQL syntax and data types, native Vector search, JSON/JSONB processing, Redis-compatible Key-Value caching, and Pub/Sub messaging.**

This document is the **north star**. Everything else (architecture, epics, decisions) exists to
serve the vision stated here. If a later decision contradicts this document, either update it or
record why it is superseded in `../DECISIONS.md`.

> **Note on intent.** NheO unifies the zero-configuration embedded footprint of SQLite, the rich
> SQL grammar and data types (`JSONB`, `VECTOR`) of PostgreSQL, and the ultra-fast Key-Value caching
> and Pub/Sub semantics of Redis inside a single formally verified Ada/SPARK codebase. All database
> logic is mathematically proved in SPARK (`SPARK_Mode => On`); only raw OS/disk I/O operations use
> standard Ada (`SPARK_Mode => Off`).

---

## 1. The problem

Modern applications — especially local-first AI agents, edge systems, and high-assurance services — typically require four distinct data primitives:
1. **Relational ACID Storage** with expressive SQL and strong data types (PostgreSQL).
2. **Vector Similarity Search** for embeddings and semantic retrieval (`pgvector`).
3. **Structured Document Queries** over semi-structured payloads (`JSON` / `JSONB`).
4. **Low-Latency Key-Value Caching & Event Pub/Sub** for state caching and real-time notifications (Redis).

Developers are forced either to run a heavy fleet of external server daemons (PostgreSQL + pgvector + Redis) or to settle for embedded engines written in C/C++ (SQLite + extensions) that lack PostgreSQL type fidelity, lack native KV/Pub-Sub, and remain susceptible to memory corruption, integer overflows, and subtle concurrency bugs.

---

## 2. The product

**NheO** is a single-binary, embeddable multi-model database management system written in **Ada 2022 and SPARK 2022**:
- **SQLite-Style Embedded Footprint**: Runs directly in-process or as a lightweight local engine backed by a deterministic disk page file and Write-Ahead Log (WAL). Zero external servers required.
- **PostgreSQL Syntax & Data Types**: Supports PostgreSQL-compatible SQL syntax (`$1` parameters, `::type` casts, `RETURNING`, `ON CONFLICT DO UPDATE`) and native PostgreSQL data types (`INT2`, `INT4`, `INT8`, `FLOAT4`, `FLOAT8`, `NUMERIC`, `BOOLEAN`, `TEXT`, `BYTEA`, `UUID`, `TIMESTAMPTZ`, `JSON`, `JSONB`, `VECTOR`).
- **Native Vector Database**: First-class `VECTOR(d)` column and value type with formally verified L2 distance (`<->`), cosine distance (`<=>`), and negative inner product (`<#>`) operators.
- **PostgreSQL JSON / JSONB Engine**: Structural validation and binary tree indexing with `->`, `->>`, `@>` (containment), and `?` (key-existence) operators.
- **Full ACID & Disk Persistence**: Multi-Version Concurrency Control (MVCC) with snapshot isolation (`xmin`/`xmax`) paired with CRC32-checksummed Write-Ahead Logging (WAL) and slotted 4KB disk pages.
- **Redis-Grade Key-Value Cache & Pub/Sub**: Direct high-speed KV operations (`GET`, `SET`, `DEL`, `INCR`, `EXPIRE`, `TTL`) with deterministic TTL expiration and LRU eviction, plus an in-process Pub/Sub message broker (`PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, pattern matching).
- **100% SPARK Verified Logic**: Every single module of core logic is proved in SPARK (`pragma SPARK_Mode (On);`). Only raw I/O operations (`Nheo.IO` package body) are written in unverified Ada (`pragma SPARK_Mode (Off);`).

---

## 3. North-star capabilities

1. **PostgreSQL-Compatible SQL & Type Engine**: Parse and execute PostgreSQL DDL/DML with strict type checking and type casting (`::int4`, `::jsonb`, `::vector`).
2. **Provably Safe Vector Search**: Execute exact and approximate nearest-neighbor queries using `<->`, `<=>`, and `<#>` with SPARK-verified dimension invariants and absence of floating-point overflow/divide-by-zero.
3. **Rich JSON/JSONB Querying**: Store and query nested JSON documents using PostgreSQL's `->`, `->>`, `@>`, and `?` operators without memory safety vulnerabilities.
4. **Crash-Safe ACID Persistence**: Guarantee atomicity, consistency, snapshot isolation, and durability across power loss or process crashes via WAL redo recovery and page checksums.
5. **Embedded Redis-Compatible Cache**: Sub-microsecond in-memory Key-Value reads/writes with optional TTL expiration, LRU bounded eviction, and transparent WAL persistence.
6. **Real-Time Pub/Sub Channels**: Publish and subscribe to named channels or wildcard patterns using bounded, lock-free/protected ring buffers with zero dynamic heap allocation.
7. **Mathematically Verified Boundary**: Enforce that 100% of parsing, indexing, transaction visibility, vector math, JSON traversal, KV caching, and Pub/Sub routing are proved by `GNATprove`, isolating `SPARK_Mode (Off)` strictly to OS file/stream I/O bodies.

---

## 4. Principles

1. **SPARK Everywhere, Ada Only for I/O (`BR-001`)**: No business, storage, query, vector, JSON, KV, or Pub/Sub logic may disable `SPARK_Mode`. Only the low-level I/O implementation body (`Nheo.IO`) may use `SPARK_Mode (Off)`.
2. **Bounded & Deterministic Memory**: Avoid unbounded heap allocations inside the verified engine. Use bounded structures, fixed-size slotted pages (4096 bytes), and explicit capacity contracts (`Pre` / `Post` / `Type_Invariant`).
3. **PostgreSQL Ergonomics in an Embedded Package**: Users should write familiar PostgreSQL queries, JSONB expressions, and `pgvector` operators without managing a database server.
4. **ACID Without Compromise**: Caching speed must never corrupt durable state; MVCC visibility and WAL checksum invariants are enforced by formal contracts.

---

## 5. Non-goals

1. **Multi-Node Distributed Consensus (Raft/Paxos)**: NheO is an embedded single-node/in-process database engine like SQLite, not a distributed cluster database.
2. **Unverified JIT / Dynamic Scripting Extensions**: Stored procedures in unverified dynamic languages (e.g., PL/Python, PL/V8) are out of scope to preserve the formal SPARK safety proof.
