# Dual-Mode Pub/Sub & The WAL Commit Barrier (`PUBLISH` vs. Transactional `NOTIFY`)

> **Takeaway:** Supporting both immediate in-memory ring-buffer delivery (Redis `PUBLISH`) and WAL-commit-gated notification dispatch (PostgreSQL `LISTEN`/`NOTIFY`) lets an embedded engine stream ephemeral agent telemetry at zero latency while preventing background RAG indexers from acting on uncommitted or rolled-back transactions.

**Tags:** swe, ai
**Related ADRs:** [ADR-004](../../DECISIONS.md)

---

## 1. Context — the problem

In an Agentic RAG or multi-model database system like **Nhé O**, applications use Publish/Subscribe messaging for two fundamentally different workloads:

1. **Ephemeral Real-Time Telemetry (Redis-style)**:
   - An LLM agent publishes token-generation progress, heartbeat signals, or UI status updates (`PUBLISH agent:stream "step 2..."`).
   - Subscribers want **immediate, sub-microsecond delivery** in memory without waiting for disk I/O or an ACID transaction.
2. **State-Change Triggers for Background Workers (PostgreSQL-style)**:
   - A transaction inserts a new document chunk into a table and notifies a background embedding / HNSW indexing worker (`NOTIFY rag_ingest, 'doc_id=108'`).
   - What happens if the notification is delivered **immediately** before the transaction commits?
     - **Race Condition (Premature Read)**: The background worker wakes up and queries `doc_id=108` *before* the inserting transaction commits. Under MVCC Snapshot Isolation (`Is_Version_Visible`), the row is invisible (`Not Found`)!
     - **Phantom Indexing on Rollback**: Worse, if the transaction later fails a constraint check or I/O check and rolls back (`Rollback_Tx`), a fire-and-forget notification has already been sent — causing the RAG worker to index phantom data that does not exist in the database.

---

## 2. The concept, explained simply

A **WAL Commit Barrier** solves both the premature-read race condition and the phantom-rollback bug by separating **staging a notification** from **dispatching it to subscribers**:

- **Mode 1: Immediate In-Memory Delivery (`Durable => False`, Redis `PUBLISH` semantics)**
  - Calling `Publish` writes the message directly into the bounded FIFO ring buffers of all matching active subscribers (exact channel or `*` glob pattern at any position, `Matches_Channel`).
  - Zero disk I/O; independent of transactions.
- **Mode 2: Transactional WAL-Committed Delivery (`Durable => True`, PostgreSQL `NOTIFY` semantics)**
  - When a transaction calls `Stage_Notify (Ctx, Staging, Channel, Payload, Status)` while `Ctx.State = Tx_Active`, the message is **not** placed into subscriber ring buffers yet. Instead, it is appended to a bounded **Transactional Staging Queue** associated with `Ctx.Id`.
  - **On `Commit_Tx`**:
    1. `Nhe_O.Transaction` encodes the WAL frame with CRC32 and flushes it to disk (`Posix_Pwrite_WAL` + `Posix_Fsync`).
    2. **Only after `Status = Status_Ok` and `Ctx.State = Tx_Committed`** (the *WAL Commit Barrier*), the staged notifications for `Ctx.Id` are atomically flushed into the subscriber ring buffers of `Nhe_O.PubSub`.
  - **On `Rollback_Tx` (or failed `Commit_Tx`)**:
    - The staged notifications for `Ctx.Id` are simply discarded (`Staging.Count = 0`). Subscribers never see a notification from an aborted transaction.

```text
Transaction T1 (Active)                        Subscriber (RAG Indexer Worker)
-----------------------                        -------------------------------
1. Begin_Tx (T1)
2. Insert Document Chunk (doc_id=108)
3. Stage_Notify (T1, "rag_ingest", "108")
      |
      +--> [Staged in T1 Queue]  (Blocked by WAL Commit Barrier)
                                 (Subscriber sees NOTHING yet)
4. Commit_Tx (T1):
   - Write WAL Frame + CRC32
   - Posix_Fsync (WAL) == 0  <=== WAL COMMIT BARRIER PASSED!
   - Ctx.State := Tx_Committed
      |
      +--> Flush_Committed_Notifications (T1)
                    -------------------------> 5. Poll_Message ("rag_ingest")
                                               6. Reads doc_id=108 (Guaranteed
                                                  visible under MVCC & durable!)
```

---

## 3. A concrete example

In **Nhé O**, a bounded transactional notification staging buffer in `SPARK_Mode (On)` enforces the commit barrier through formal contracts (`Pre` and `Post`):

```ada
   --  Stage a durable notification inside an active transaction
   procedure Stage_Notify
     (Ctx     : in     Transaction_Context;
      Staging : in out Tx_Notification_Buffer;
      Channel : in     Bounded_Ident;
      Payload : in     Bounded_Text;
      Status  :    out Engine_Status)
     with Pre  => Ctx.State = Tx_Active and then Channel.Length > 0,
          Post => (if Status = Status_Ok then
                     Staging.Count = Staging.Count'Old + 1
                     and then Staging.Owner_Tx = Ctx.Id);

   --  Flush staged notifications to Pub/Sub Broker ONLY after Tx_Committed
   --  and only when Staging.Owner_Tx matches Ctx.Id
   procedure Flush_Committed_Notifications
     (Ctx             : in     Transaction_Context;
      Staging         : in out Tx_Notification_Buffer;
      Broker          : in out PubSub_Broker;
      Total_Delivered :    out Natural)
     with Pre  => Ctx.State = Tx_Committed,
          Post => (if Staging'Old.Count = 0 or else Staging'Old.Owner_Tx = Ctx.Id
                   then Staging.Count = 0
                   else Staging = Staging'Old);

   --  Discard staged notifications on rollback
   procedure Discard_Staged_Notifications
     (Ctx     : in     Transaction_Context;
      Staging : in out Tx_Notification_Buffer)
     with Pre  => Ctx.State = Tx_Aborted,
          Post => (if Staging'Old.Count = 0 or else Staging'Old.Owner_Tx = Ctx.Id
                   then Staging.Count = 0
                   else Staging = Staging'Old);
```

Notice how the precondition `Pre => Ctx.State = Tx_Committed` on `Flush_Committed_Notifications` makes it **mathematically impossible** in `SPARK_Mode (On)` to dispatch a durable notification before `Commit_Tx` has transitioned the transaction to `Tx_Committed`! The `Owner_Tx` guard in both postconditions adds that a transaction can never flush or discard notifications staged by another transaction: such a buffer is left untouched.

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to choose |
|---|---|---|---|
| **1. Pure Fire-and-Forget Pub/Sub (Redis-only)** | Lowest possible latency; zero transaction coupling. | Causes MVCC visibility races and phantom notifications if a transaction rolls back after publishing. | Ephemeral UI streaming, heartbeats, and cache invalidation hints. |
| **2. Polling a Database Table (`SELECT ... WHERE processed = false`)** | Transactionally consistent without a Pub/Sub broker. | Wastes CPU/I/O polling empty tables; adds polling interval latency (`100ms–1000ms`). | Legacy systems without an in-process event broker. |
| **3. Dual-Mode Pub/Sub: In-Memory + WAL-Commit-Gated `NOTIFY` (Nhé O's choice)** | Combines microsecond Redis streaming (`Publish`) with zero-race, rollback-safe transactional triggers (`Stage_Notify` + `Commit_Tx`). | Requires a small bounded staging array per active transaction context. | Unified multi-model and Agentic RAG engines (`ADR-004`). |

---

## 5. Where it lives in the project

- **ADR**: [`ADR-004`](../../DECISIONS.md) — *Dual-Mode Pub/Sub: Fast In-Memory Ring Buffers + Optional `DURABLE` WAL-Committed Dispatch*.
- **Domain Invariant**: [`BR-005`](../../domain/business-rules.md) — *Dual-Mode Pub/Sub Delivery, `Owner_Tx` Guard & Overflow Accounting*.
- **Epic**: [`docs/epics/02-storage-indexing-and-rag-executor/PROGRESS.md`](../../epics/02-storage-indexing-and-rag-executor/PROGRESS.md) — Task 5.
- **Code Modules**: [`src/nhe_o-pubsub.ads`](../../../src/nhe_o-pubsub.ads) and [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads).

---

## 6. Further reading

- *PostgreSQL Documentation — `NOTIFY` and `LISTEN` Transactional Semantics* ("`NOTIFY` interacts with SQL transactions in some important ways: notifications are not delivered until the transaction is committed...").
- *Redis Documentation — Redis Pub/Sub (`PUBLISH`, `SUBSCRIBE`, `PSUBSCRIBE`)*.
- *Martin Kleppmann — Designing Data-Intensive Applications (Chapter 7: Transactions & Chapter 11: Stream Processing)*.

---

## 7. Check yourself

1. **What two bugs occur if a transaction publishes an event to a background RAG indexing worker *before* the transaction commits?**
2. **Why can a subscriber wake up upon receiving an immediate (non-transactional) notification and fail to see the newly inserted row under MVCC Snapshot Isolation (`Is_Version_Visible`)?**
3. **How does the SPARK precondition `Pre => Ctx.State = Tx_Committed` on `Flush_Committed_Notifications` guarantee that durable notifications respect the WAL Commit Barrier?**
4. **When should an Agentic RAG application use immediate `Publish` (Redis mode) versus transactional `Stage_Notify` (PostgreSQL `NOTIFY` mode)?**
