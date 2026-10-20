# Closing Protocol Invariant Gaps & Preventing VC Explosion with Modular SPARK Contracts

> **Takeaway:** Proving 100% Absence of Run-Time Errors (Silver) and local subprogram contracts (Gold) does not automatically prevent cross-module **protocol invariant gaps**—such as mismatched horizon constants (`Max_CLOG_Entries` vs. `Max_Tx_Id`), silent scan truncation (`Max_WAL_Scan_Frames`), or self-overlapping page range reuse. Closing these gaps requires unifying domain subtypes across package boundaries, validating all capacity/notify preconditions *before* appending WAL frames, and factoring multi-level recursive-style validators (`@>` JSONB containment and SQL clause analyzers) into non-recursive helpers carrying explicit modular contracts (`Global => null, Always_Terminates` and concise non-tautological `Post` bounds) to prevent `gnatprove` contextual-inlining blowup.

**Tags:** swe
**Related ADRs:** [ADR-006](../../DECISIONS.md), [ADR-007](../../DECISIONS.md)

---

## 1. Context — why 100% AoRTE still needs adversarial protocol audits

During the Full-System Adversarial Audit ([`ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md)), the codebase already had `100%` of its Silver (AoRTE) and existing Gold contracts proved. Yet adversarial inspection uncovered three classes of semantic protocol bugs:

1. **Cross-Constant Horizon Mismatch**:
   - `Valid_Tx_Id` allowed `1 .. 1_000_000_000`, while `Commit_Log` (`CLOG`) only indexed `1 .. 1024`.
   - To satisfy AoRTE, `Set_CLOG_State` guarded `if Id <= Max_CLOG_Entries` and `Is_Tx_Committed` returned `False` for `Id > 1024`.
   - That defensive guard was *memory-safe*, so `gnatprove` proved it 100%—yet semantically, transaction `1025` became permanently invisible (`Is_Tuple_Visible = False`), and deleting a tuple committed at `Xmin <= 1024` during `Xmax = 1025` turned it into an undeletable zombie!
2. **Multi-Chain Page Allocator Self-Overlap**:
   - A single RAG document owns up to three 4KB TOAST overflow chains: parent chunk (`Toast_Ptr`), 4096-D vector (`Vec_Toast_Ptr`), and extended summary/JSONB metadata (`Meta_Toast_Ptr`), plus retained prior versions (`Prior_*`).
   - Recomputing `Engine.Next_TOAST_Pg` from active pointers alone allowed a growing parent chain to allocate across the page range of `Retired_Vec_Ptr`, which was then reused in-place for the new `"VTST"` chain—overwriting the document's own parent chunk!
3. **Contextual Inlining VC Explosion in Multi-Level `@>` Containment**:
   - In SPARK, local helper functions without any `Pre`/`Post` or `Global` contracts are **contextually inlined** by `gnatprove` at every call site.
   - When implementing multi-level nested JSONB object/array `@>` containment (`Field_Values_Contain` -> `Object_Contains` / `Array_Contains` -> `Inner_Object_Contains` / `Inner_Array_Contains` -> `Leaf_Object_Contains` / `Leaf_Array_Contains` -> `Flat_Object_Contains` / `Extract_Array_Elements`), uncontracted helpers caused `gnatprove` to inline a 200-line parser inside nested loops, exploding a single VC into tens of thousands of AST nodes.

---

## 2. The engineering patterns that closed the gaps

### Pattern 1: Unify Domain Subtypes Instead of Silently Clipping
Rather than allowing `Valid_Tx_Id` to exceed `CLOG`'s index range and silently ignoring out-of-range IDs:
- We unified `Max_CLOG_Entries : constant := 8192;` and `Max_Tx_Id : constant := Max_CLOG_Entries;` in [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads).
- `Set_CLOG_State` now carries an unconditional postcondition:
  ```ada
  procedure Set_CLOG_State
    (CLOG  : in out Commit_Log;
     Id    : Valid_Tx_Id;
     State : Transaction_State)
  with
    Global => null,
    Post   => CLOG (Id) = State
              and then (for all K in CLOG'Range =>
                          (if K /= Id then CLOG (K) = CLOG'Old (K)));
  ```
- Furthermore, durable KV WAL frames in `Nhe_O.C_API` now use their own sequence counter (`G_Next_KV_Seq`) so KV traffic never consumes MVCC transaction IDs.

### Pattern 2: Range-Overlap Predicates & Pre-WAL Validation
Before reusing a retired TOAST page range or advancing `Engine.Next_TOAST_Pg`, [`src/nhe_o-rag.adb`](../../../src/nhe_o-rag.adb) checks `Is_TOAST_Range_Free (Engine, Cand_Start, Cand_Count, Exclude_Slot)` across all active and retained pointers (`Toast_Ptr`, `Vec_Toast_Ptr`, `Meta_Toast_Ptr`, `Prior_*`), and verifies disjointness (`not Ranges_Overlap (...)`) between the newly allocated parent, vector, and metadata chains within the same `Ingest_Document` call. All in-memory capacity and `Stage_Notify` checks execute *before* writing the first `"TOAS"` or `.wal` frame to disk.

### Pattern 3: Modular Helper Contracts (`Global => null, Always_Terminates` + Concise `Post`) to Prevent Inlining Blowup
In [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb) and [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb), attaching explicit modular contracts (`with Global => null, Always_Terminates;` and concise non-tautological `Post` bounds on `Sanitize_SQL`, `Parse_Limit_Clause`, `Count_Select_Columns`, and `Count_Create_Table_Columns`) instructs `gnatprove` to verify complex helpers **modularly** rather than contextually inlining large loops into every caller. Result: all 29 subprograms in `Nhe_O.JSON` and all 32 subprograms in `Nhe_O.SQL` prove with max proof time under 1 second! (See [`swe/09-eliminating-tautological-contracts-and-contextual-inlining-in-spark.md`](09-eliminating-tautological-contracts-and-contextual-inlining-in-spark.md) for why concise non-tautological `Post` contracts beat literal `Post => True`.)

---

## 3. Where it lives in the project

- **Unified CLOG & Pre-Commit 4096-Frame WAL Scan**: [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads) and [`src/nhe_o-transaction.adb`](../../../src/nhe_o-transaction.adb).
- **Non-Overlapping TOAST Allocator, `"RMET"` Metadata TOAST & HNSW Rollback Sync**: [`src/nhe_o-rag.adb`](../../../src/nhe_o-rag.adb) and [`src/nhe_o-hnsw.adb`](../../../src/nhe_o-hnsw.adb).
- **Modular Multi-Level JSONB `@>` & `\uXXXX` Decoder**: [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb).

---

## 4. Check yourself

1. **Why can a defensive `if Id <= Max_CLOG_Entries` guard pass 100% of `gnatprove` Silver (AoRTE) checks while still causing a critical MVCC visibility bug?**
2. **Why must `Ingest_Document` validate `Stage_Notify` capacity and HNSW/B+Tree index capacity *before* calling `Write_TOAST_Chain`?**
3. **Why does adding a concise `Post` contract to a non-recursive helper function in a `.adb` body dramatically speed up `gnatprove` when that helper is called inside nested loops?**
