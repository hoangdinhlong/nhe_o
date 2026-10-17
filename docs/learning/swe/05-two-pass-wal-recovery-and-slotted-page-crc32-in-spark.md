# Two-Pass Committed-Only WAL Recovery & Slotted-Page CRC32 Verification in SPARK

> **Takeaway:** A single-pass WAL replay silently resurrects uncommitted transactions that wrote intermediate TOAST or data frames before crashing. By encoding a `WAL_Frame_Kind` byte (`Data`, `Commit`, `KV`) inside the CRC32-protected WAL header and splitting recovery into **Pass 1 (Analysis / Commit-Marker Discovery)** and **Pass 2 (Committed-Only Redo)** over a bounded `Commit_Log` (`CLOG`), an embedded engine achieves crash-safe ACID atomicity and durability in 100% `SPARK_Mode (On)`.

**Tags:** swe
**Related ADRs:** [ADR-006](../../DECISIONS.md), [ADR-007](../../DECISIONS.md)

---

## 1. Context — the problem

During the post-Epic-03 adversarial audit (`CRIT-01`, `CRIT-04`, `CRIT-05` in [`ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md)), we identified three classic storage-engine hazards that **Absence of Run-Time Errors (AoRTE)** alone cannot catch:

1. **Single-Pass WAL Replay of Uncommitted Transactions (`CRIT-05`)**:
   - When a transaction writes a multi-page 16KB TOAST chain (`Write_TOAST_Chain`), it appends 3–5 intermediate WAL frames (`Frame 0 .. Frame k-1`) before calling `Commit_Tx`.
   - If the process crashes before `Commit_Tx` writes the final commit frame, a naive single-pass `Redo_WAL_Recovery` sees valid CRC32 checksums on `Frame 0 .. Frame k-1` and replays them onto `.db`—violating ACID **Atomicity**!
2. **Torn Tail Frames vs. Clean EOF (`HIGH-06`)**:
   - If `Read_WAL_Frame` returns a single `Success : out Boolean` flag, `Redo_WAL_Recovery` cannot tell whether `Success = False` means a clean 0-byte EOF at a frame boundary (`N_Read = 0`) or a mid-frame disk error / torn write (`0 < N_Read < 4120`).
3. **Volatile Tuple Directories (`CRIT-01`)**:
   - Without a primary 4096-byte `"SLOT"` slotted-page serializer containing the `MVCC_Tuple_Header` (`Xmin`, `Xmax`) and 16-byte `TOAST_Pointer` values, TOAST overflow chains on disk become unreachable after a restart.

---

## 2. The concept, explained simply

### 1. Frame Classification Inside the CRC32 Envelope (`WAL_Frame_Kind`)
Every 4,120-byte WAL frame (`24B header + 4096B page`) carries a 1-byte `WAL_Frame_Kind` tag at byte 17:
- `0` (`WAL_Frame_Data`): Intermediate transaction page write (e.g., TOAST overflow chunks).
- `1` (`WAL_Frame_Commit`): Transaction commit barrier written exclusively by `Commit_Tx`.
- `2` (`WAL_Frame_KV`): Self-contained durable Key-Value mutation (`"KVMG"` page).

Crucially, `Compute_WAL_CRC32` hashes header bytes `1..12`, **bytes `17..24`**, and payload bytes `25..4120`. Any bit flip in `Frame_Kind` invalidates the frame's CRC32.

### 2. Two-Pass Committed-Only Recovery (`Redo_WAL_Recovery`)
Instead of writing pages to `.db` on the first scan, `Redo_WAL_Recovery` executes two bounded loops:
- **Pass 1 (Analysis Pass)**: Scans frames `0 .. Max_Frames - 1`. At each frame:
  - Calls 5-argument `Read_WAL_Frame (WAL_Path, Frame_Idx, Frame, Read_Ok, Is_EOF)`.
  - If `not Read_Ok and Is_EOF`, stops cleanly (`Hit_EOF := True`).
  - If `not Read_Ok and not Is_EOF` (or `not Verify_WAL_Frame (Frame)`), aborts with `Status_IO_Error`.
  - If `Get_WAL_Frame_Kind (Frame) = WAL_Frame_Commit`, records `Set_CLOG_State (CLOG, Frame_Tx, Tx_Committed)`.
- **Pass 2 (Redo Pass)**: Re-scans frames `0 .. Total_Frames - 1` and writes `Page` to `.db` **if and only if** `Is_Tx_Committed (CLOG, Frame_Tx)` holds!

---

## 3. Where it lives in the project

- **ADR**: [`ADR-006`](../../DECISIONS.md) — *2-Pass Committed-Only WAL Recovery, Bounded CLOG, Primary `"SLOT"` Slotted Pages & 2-Stage 4096-D Vector TOAST Re-Ranking*.
- **Domain Specification**: [`docs/domain/storage-and-wal-format.md`](../../domain/storage-and-wal-format.md).
- **Code Modules**: [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads), [`src/nhe_o-transaction.adb`](../../../src/nhe_o-transaction.adb), and [`src/nhe_o-io.adb`](../../../src/nhe_o-io.adb).
