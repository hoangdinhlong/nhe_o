# Core Business Rules (Catalog)

Authoritative index of key domain rules, database invariants, and formal verification policies in **Nhé O** (`nhe_o` / `Nhe_O`).

---

| Rule ID | Rule Name | Business Definition | Code / File Reference |
|---|---|---|---|
| `BR-001` | 100% `SPARK_Mode (On)` Verification Invariant | 100% of specifications and bodies in `src/` (all 24 `.ads`/`.adb` files including `Nhe_O.BTree`, `Nhe_O.HNSW`, `Nhe_O.RAG`, `Nhe_O_Main`, and `Nhe_O.IO` POSIX syscall I/O) must operate under `pragma SPARK_Mode (On);`. Zero files in `src/` may use `SPARK_Mode (Off)`. | `src/nhe_o-io.ads`, `src/nhe_o-io.adb` |
| `BR-002` | MVCC Snapshot Visibility & WAL Durability | A tuple `(Xmin, Xmax)` is visible at snapshot `S` iff `Xmin > 0 and Xmin <= S and (Xmax = 0 or Xmax > S)`. No transaction transitions to `Committed` without flushing a CRC32-valid WAL commit frame via `Nhe_O.IO`. | `src/nhe_o-transaction.ads` |
| `BR-003` | PostgreSQL Vector, Quantization & JSONB Integrity | Vector distance operators (`<->`, `<=>`, `<#>`, Hamming) require matching dimensions (`A.Dim = B.Dim`, up to `Max_Vector_Dim = 4096`) and matching encoding (`Float32`, `Int8` scalar quantization, or `Binary` 1-bit quantization) with bounded components `[-1.0e6 .. 1.0e6]` to guarantee overflow freedom. JSON/JSONB values must pass balanced structural validation before storage or operator evaluation. | `src/nhe_o-vector.ads`, `src/nhe_o-hnsw.ads`, `src/nhe_o-json.ads` |
| `BR-004` | Key-Value TTL & Bounded Cache Eviction | A Key-Value entry with `Has_TTL = True` is expired when `Now >= Expires_At` and must never be returned by `Get` or `Exists`. When the KV store is full, expired slots are reclaimed first, followed by the Least Recently Used (`Last_Access`) slot. | `src/nhe_o-kv.ads` |
| `BR-005` | Dual-Mode Pub/Sub Delivery (In-Memory & Durable WAL) | Standard channels deliver messages in FIFO order immediately to matching active subscribers (exact channel or `*` prefix pattern) in bounded ring buffers. `Durable` transactional notifications (`NOTIFY`) are staged per transaction and delivered to subscribers iff the transaction commits to the WAL (`Commit_Tx`), or discarded on `Rollback_Tx`. | `src/nhe_o-pubsub.ads`, `src/nhe_o-transaction.ads` |
| `BR-006` | 4KB Slotted-Page & TOAST Overflow Chain Invariant | Primary tuples reside in 4096-byte slotted pages; attributes exceeding the inline threshold (e.g., high-dimensional vectors up to 4096-D or parent-document RAG chunks) store a 16-byte inline TOAST pointer (`Root_Overflow_Page`, `Total_Byte_Length`, `Chunk_Count`, `Payload_CRC32`) referencing linked 4KB TOAST overflow pages governed by the owning tuple's MVCC (`Xmin`/`Xmax`) visibility and CRC32 verification. | `src/nhe_o-transaction.ads`, `src/nhe_o-rag.ads` |

