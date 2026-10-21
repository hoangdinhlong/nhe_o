# Two-Pass Committed-Only WAL Recovery & Slotted-Page CRC32 Verification in SPARK

> **Takeaway:** A single-pass WAL replay silently resurrects uncommitted transactions that wrote intermediate TOAST or data frames before crashing. By encoding a `WAL_Frame_Kind` byte (`Data`, `Commit`, `KV`) inside the CRC32-protected WAL header, making the durable append of the commit barrier the commit point, repairing torn WAL / `.db` tails before any scan, and splitting recovery into **Pass 1 (Analysis / Commit-Marker Discovery)** and **Pass 2 (Committed-Only Redo, in commit order)** over a bounded `Commit_Log` (`CLOG`), an embedded engine achieves crash-safe ACID atomicity and durability in 100% `SPARK_Mode (On)`.

**Tags:** swe
**Related ADRs:** [ADR-006](../../DECISIONS.md), [ADR-007](../../DECISIONS.md), [ADR-009](../../DECISIONS.md), [ADR-011](../../DECISIONS.md)

---

## 1. Context — the problem

During the post-Epic-03 adversarial audit ([`ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md)), we identified three classic storage-engine hazards that **Absence of Run-Time Errors (AoRTE)** alone cannot catch:

1. **Single-Pass WAL Replay of Uncommitted Transactions**:
   - When a transaction writes a multi-page 16KB TOAST chain (`Write_TOAST_Chain`), it stages 3–5 intermediate `WAL_Frame_Data` frames (`Frame 0 .. Frame k-1`) before calling `Commit_Tx`.
   - If the process crashes before `Commit_Tx` writes the final commit frame, a naive single-pass `Redo_WAL_Recovery` sees valid CRC32 checksums on `Frame 0 .. Frame k-1` and replays them onto `.db`—violating ACID **Atomicity**!
2. **Torn Tail Frames vs. Clean EOF**:
   - If `Read_WAL_Frame` returns a single `Success : out Boolean` flag, `Redo_WAL_Recovery` cannot tell whether `Success = False` means a clean 0-byte EOF at a frame boundary (`N_Read = 0`) or a mid-frame disk error / torn write (`0 < N_Read < 4120`).
3. **Volatile Tuple Directories**:
   - Without a primary 4096-byte `"SLOT"` slotted-page serializer containing the `MVCC_Tuple_Header` (`Xmin`, `Xmax`) and 16-byte `TOAST_Pointer` values, TOAST overflow chains on disk become unreachable after a restart.

> **Update (0.4):** Round 12 (`ADR-009`) found the next layer of hazards: a torn WAL tail, a CRC-bad final frame or a torn `.db` tail made a database permanently unopenable; a failure after a durable commit barrier was reported as an abort yet resurrected by recovery (a phantom commit); WAL-order redo diverged from run-time materialization when two transactions wrote the same page; and reusing the id of a crashed transaction let a later commit adopt its orphan frames. Section 2 describes the protocol that closes them.

---

## 2. The concept, explained simply

### 1. Frame Classification Inside the CRC32 Envelope (`WAL_Frame_Kind`)
Every 4,120-byte WAL frame (`24B header + 4096B page`) carries a 1-byte `WAL_Frame_Kind` tag at byte 17:
- `0` (`WAL_Frame_Data`): Intermediate transaction page write (`NO-STEAL` staging for TOAST overflow chunks and primary pages).
- `1` (`WAL_Frame_Commit`): Transaction commit barrier written by `Commit_Tx` (a checkpoint, `C_Checkpoint`, also writes one for the frozen Page 1 of transaction `1` into the replacement WAL, `ADR-011`).
- `2` (`WAL_Frame_KV`): Self-contained durable Key-Value mutation (`"KVMG"` page).

Crucially, `Compute_WAL_CRC32` hashes the `Tx_Id` (bytes `5..8`), the `Page_Id` (bytes `9..12`), **the kind byte (byte `17`)**, and payload bytes `25..4120`, while `Verify_WAL_Frame` checks the `"NHEO"` magic (bytes `1..4`) and the zeroed bytes `18..24` directly. Any bit flip in the kind byte invalidates the frame's CRC32.

### 2. Two-Pass Committed-Only Recovery (`Redo_WAL_Recovery`)
Instead of writing pages to `.db` on the first scan, `Redo_WAL_Recovery` first repairs torn tails and then executes two bounded loops:
- **Step 0 (Tail Repair, `ADR-009`)**: Appends are sequential and durable, so a crash can only tear the *last* frame. `Repair_WAL_Tail` classifies every complete frame before truncating anything, then drops a partial trailing frame or a final complete frame that fails `Verify_WAL_Frame`; an invalid frame before the last, foreign bytes, or more than `Max_WAL_Frames` frames fail closed with `Status_IO_Error` and leave the file untouched. `Repair_DB_Tail` truncates a partial trailing `.db` page, which the replay rebuilds. (Before 0.4 such a torn tail made the database permanently unopenable.)
- **Pass 1 (Analysis Pass)**: Scans frames `0 .. Max_Frames - 1`. At each frame:
  - Calls 5-argument `Read_WAL_Frame (WAL_Path, Frame_Idx, Frame, Read_Ok, Is_EOF)`.
  - If `not Read_Ok and Is_EOF`, stops cleanly (`Hit_EOF := True`).
  - If `not Read_Ok and not Is_EOF` (or `not Verify_WAL_Frame (Frame)`), aborts with `Status_IO_Error`: after the tail repair this means mid-log corruption or a read error, never a torn tail.
  - If `Get_WAL_Frame_Kind (Frame) = WAL_Frame_Commit`, records `Set_CLOG_State (CLOG, Frame_Tx, Tx_Committed)`; a second commit frame for the same transaction is corruption.
  - Tracks `Max_Seen_Tx`, the largest transaction id of any data or commit frame, committed or not. Callers seed new transaction ids above it, so a reused id can never adopt a crashed transaction's staged frames.
- **Pass 2 (Redo Pass, in commit order)**: For each commit frame, in WAL order, writes to `.db` the `WAL_Frame_Data` pages its transaction staged **before** that barrier, then the barrier's own page — exactly the order in which `Commit_Tx` materialized them at run time. Data frames of uncommitted transactions, and data frames that appear after their own transaction's barrier, are never replayed; `WAL_Frame_KV` frames are left to `Recover_KV_From_WAL`. (Before 0.4, Pass 2 replayed every committed frame in WAL order, which diverged from run-time materialization when two transactions wrote the same page.)

> **Update (0.4) — the commit point and checkpoints (`ADR-009`, `ADR-011`):** The durable append of the `WAL_Frame_Commit` barrier is the commit point. Once it is appended, `Commit_Tx` returns `Status_Ok` even if materializing the staged pages into `.db` fails, and reports `Flush_Pending = True` so the caller repairs `.db` with `Redo_WAL_Recovery` (`Commit_RAG_Tx` does so in place). A checkpoint (`C_Checkpoint`, also run automatically past fixed thresholds) replaces the WAL with a KV snapshot plus that single commit frame of transaction `1`, and transaction ids restart at `2`, so the fixed WAL and transaction-id capacities are no longer a lifetime budget.

---

## 3. Where it lives in the project

- **ADR**: [`ADR-006`](../../DECISIONS.md) — *NO-STEAL WAL Staging, 2-Pass Committed-Only WAL Recovery, Unified 8192-Entry CLOG, Primary `"SLOT"` Pages & `"VTST"` / `"RMET"` TOAST Chains* (partially superseded: its recovery order and torn-file handling by `ADR-009`).
- **ADR**: [`ADR-009`](../../DECISIONS.md) — *Crash-Consistent WAL Protocol v2: Durable-Barrier Commit Point, Torn-Tail Repair & Commit-Order Redo*; [`ADR-011`](../../DECISIONS.md) — *WAL Checkpoint: Freeze, Atomic WAL Replacement & Automatic Thresholds*.
- **Domain Specification**: [`docs/domain/storage-and-wal-format.md`](../../domain/storage-and-wal-format.md) (Section 1).
- **Code Modules**: [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads), [`src/nhe_o-transaction.adb`](../../../src/nhe_o-transaction.adb), and [`src/nhe_o-io.adb`](../../../src/nhe_o-io.adb).
