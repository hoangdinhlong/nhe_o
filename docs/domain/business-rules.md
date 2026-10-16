# Core Business Rules (Catalog)

Authoritative index of key domain rules, database invariants, and formal verification policies in **Nhé O** (`nhe_o` / `Nhe_O`).

---

| Rule ID | Rule Name | Business Definition | Code / File Reference |
|---|---|---|---|
| `BR-001` | 100% `SPARK_Mode (On)` Verification Invariant | 100% of specifications and bodies in `src/` (types, SQL, vector math, JSON/JSONB, ACID MVCC/WAL framing, KV cache, Pub/Sub, `Nhe_O_Main`, and `Nhe_O.IO` POSIX syscall I/O) must operate under `pragma SPARK_Mode (On);`. Zero files in `src/` may use `SPARK_Mode (Off)`. | `src/nhe_o-io.ads`, `src/nhe_o-io.adb` |
| `BR-002` | MVCC Snapshot Visibility & WAL Durability | A tuple `(Xmin, Xmax)` is visible at snapshot `S` iff `Xmin > 0 and Xmin <= S and (Xmax = 0 or Xmax > S)`. No transaction transitions to `Committed` without flushing a CRC32-valid WAL commit frame via `Nhe_O.IO`. | `src/nhe_o-transaction.ads` |
| `BR-003` | PostgreSQL Vector & JSONB Integrity | Vector distance operators (`<->`, `<=>`, `<#>`) require matching dimensions (`A.Dim = B.Dim`) with bounded components `[-1.0e6 .. 1.0e6]` to guarantee overflow freedom. JSON/JSONB values must pass balanced structural validation before storage or operator evaluation. | `src/nhe_o-vector.ads`, `src/nhe_o-json.ads` |
| `BR-004` | Key-Value TTL & Bounded Cache Eviction | A Key-Value entry with `Has_TTL = True` is expired when `Now >= Expires_At` and must never be returned by `Get` or `Exists`. When the KV store is full, expired slots are reclaimed first, followed by the Least Recently Used (`Last_Access`) slot. | `src/nhe_o-kv.ads` |
| `BR-005` | Deterministic Pub/Sub Ring-Buffer Delivery | Messages published to a channel are delivered in FIFO order to all matching active subscribers (exact channel or `*` prefix pattern) within bounded ring buffers without dynamic memory allocation. | `src/nhe_o-pubsub.ads` |
