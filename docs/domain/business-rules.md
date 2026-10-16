# Core Business Rules (Catalog)

Authoritative index of key domain rules, database invariants, and formal verification policies in NheO.

---

| Rule ID | Rule Name | Business Definition | Code / File Reference |
|---|---|---|---|
| `BR-001` | Strict SPARK / I/O Boundary Invariant | 100% of database logic (types, SQL, vector math, JSON/JSONB, ACID MVCC/WAL framing, KV cache, Pub/Sub) must be written in SPARK (`SPARK_Mode => On`). Only raw I/O operations (`src/nheo-io.adb`) may use standard Ada (`SPARK_Mode => Off`). | `src/nheo-io.ads`, `src/nheo-io.adb` |
| `BR-002` | MVCC Snapshot Visibility & WAL Durability | A tuple `(Xmin, Xmax)` is visible at snapshot `S` iff `Xmin > 0 and Xmin <= S and (Xmax = 0 or Xmax > S)`. No transaction transitions to `Committed` without flushing a CRC32-valid WAL commit frame via `Nheo.IO`. | `src/nheo-transaction.ads` |
| `BR-003` | PostgreSQL Vector & JSONB Integrity | Vector distance operators (`<->`, `<=>`, `<#>`) require matching dimensions (`A.Dim = B.Dim`) with bounded components `[-1.0e6 .. 1.0e6]` to guarantee overflow freedom. JSON/JSONB values must pass balanced structural validation before storage or operator evaluation. | `src/nheo-vector.ads`, `src/nheo-json.ads` |
| `BR-004` | Key-Value TTL & Bounded Cache Eviction | A Key-Value entry with `Has_TTL = True` is expired when `Now >= Expires_At` and must never be returned by `Get` or `Exists`. When the KV store is full, expired slots are reclaimed first, followed by the Least Recently Used (`Last_Access`) slot. | `src/nheo-kv.ads` |
| `BR-005` | Deterministic Pub/Sub Ring-Buffer Delivery | Messages published to a channel are delivered in FIFO order to all matching active subscribers (exact channel or `*` prefix pattern) within bounded ring buffers without dynamic memory allocation. | `src/nheo-pubsub.ads` |
