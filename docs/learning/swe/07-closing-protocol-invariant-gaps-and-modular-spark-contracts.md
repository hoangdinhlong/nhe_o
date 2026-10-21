# Closing Protocol Invariant Gaps & Preventing VC Explosion with Modular SPARK Contracts

> **Takeaway:** Proving 100% Absence of Run-Time Errors (Silver) and local subprogram contracts (Gold) does not automatically prevent cross-module **protocol invariant gaps**—such as mismatched horizon constants (`Max_CLOG_Entries` vs. `Max_Tx_Id`), silent scan truncation (`Max_WAL_Scan_Frames`), or self-overlapping and cross-transaction page range reuse. Closing these gaps requires unifying domain subtypes across package boundaries, validating all capacity/notify preconditions *before* appending WAL frames, and giving every loop-heavy validator helper (the `@>` JSONB containment walker, the SQL lexer and its token-level checkers) explicit modular contracts (`Global => null`, `Always_Terminates` or a `Subprogram_Variant`, and concise non-tautological `Post` bounds) to prevent `gnatprove` contextual-inlining blowup.

**Tags:** swe
**Related ADRs:** [ADR-006](../../DECISIONS.md), [ADR-007](../../DECISIONS.md), [ADR-015](../../DECISIONS.md), [ADR-016](../../DECISIONS.md), [ADR-019](../../DECISIONS.md)

---

## 1. Context — why 100% AoRTE still needs adversarial protocol audits

During the Full-System Adversarial Audit ([`ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md)), the codebase already had `100%` of its Silver (AoRTE) and existing Gold contracts proved. Yet adversarial inspection uncovered three classes of semantic protocol bugs:

1. **Cross-Constant Horizon Mismatch**:
   - `Valid_Tx_Id` allowed `1 .. 1_000_000_000`, while `Commit_Log` (`CLOG`) only indexed `1 .. 1024`.
   - To satisfy AoRTE, `Set_CLOG_State` guarded `if Id <= Max_CLOG_Entries` and `Is_Tx_Committed` returned `False` for `Id > 1024`.
   - That defensive guard was *memory-safe*, so `gnatprove` proved it 100%—yet semantically, transaction `1025` became permanently invisible (`Is_Tuple_Visible = False`), and deleting a tuple committed at `Xmin <= 1024` during `Xmax = 1025` turned it into an undeletable zombie!
2. **Multi-Chain Page Allocator Self-Overlap**:
   - A single RAG document owns up to three 4KB TOAST overflow chains: parent chunk (`Toast_Ptr`), 4096-D vector (`Vec_Toast_Ptr`), and extended summary/JSONB metadata (`Meta_Toast_Ptr`), plus retained prior versions (`Prior_*`).
   - Recomputing `Engine.Next_TOAST_Pg` from active pointers alone allowed a growing parent chain to allocate across the page range of the document's retired vector chain, which the allocator of that time then reused in place for the new `"VTST"` vector chain—overwriting the document's own parent chunk!
3. **Contextual Inlining VC Explosion in Multi-Level `@>` Containment**:
   - In SPARK, local helper functions without any `Pre`/`Post` or `Global` contracts are **contextually inlined** by `gnatprove` at every call site.
   - The Epic 04 implementation of nested JSONB object/array `@>` containment was a depth-4 ladder of non-recursive object and array helpers (top-level, inner, leaf and flat levels); uncontracted helpers caused `gnatprove` to inline a 200-line parser inside nested loops, exploding a single VC into tens of thousands of AST nodes.
   - *Update (0.4):* Round 12 replaced the ladder with one fuel-bounded recursive walker, `Value_Contains`, that follows PostgreSQL's `JsonbDeepContains` at every depth (`ADR-015`). The lesson carries over unchanged, because the walker and its helpers keep explicit contracts (Pattern 3).

---

## 2. The engineering patterns that closed the gaps

### Pattern 1: Unify Domain Subtypes Instead of Silently Clipping
Rather than allowing `Valid_Tx_Id` to exceed `CLOG`'s index range and silently ignoring out-of-range IDs:
- We unified `Max_CLOG_Entries : constant := 8192;` and `Max_Tx_Id : constant := Max_CLOG_Entries;` in [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads).
- `Set_CLOG_State` now carries an unconditional postcondition:
  ```ada
  procedure Set_CLOG_State
    (CLOG  : in out Commit_Log;
     Id    : in     Valid_Tx_Id;
     State : in     Tx_State)
    with Global => null,
         Always_Terminates,
         Post   => CLOG (Id) = State
                   and then (for all K in CLOG_Tx_Index =>
                               (if K /= Id then CLOG (K) = CLOG'Old (K)));
  ```
- Furthermore, durable KV WAL frames in `Nhe_O.C_API` now use their own sequence counter (`G_Next_KV_Seq`) so KV traffic never consumes MVCC transaction IDs.

### Pattern 2: Range-Overlap Predicates & Pre-WAL Validation
`Ingest_Document` in [`src/nhe_o-rag.adb`](../../../src/nhe_o-rag.adb) places each of its chains (parent, vector, `"RMET"`) on the lowest free run of pages from page `10` (`Find_TOAST_Range`, first fit: the only candidates are page `10` and the end of every reserved range). A candidate run is taken only if `Is_TOAST_Range_Available` holds: `Is_TOAST_Range_Free` rejects any overlap with the live and prior chains of every other document (`Toast_Ptr`, `Vec_Toast_Ptr`, `Meta_Toast_Ptr`, `Prior_*`) and with the chains the updated document keeps as its prior version, `not Ranges_Overlap (...)` keeps the new version's parent, vector, and metadata chains disjoint, and the pages staged by any other *active* transaction stay reserved through each document slot's staged hull (`Staged_Tx`, `Staged_First`, `Staged_End`) until that transaction commits or aborts (`ADR-019`). `Engine.Next_TOAST_Pg` is only an upper bound of the reserved pages: `Recompute_TOAST_High_Water_Mark` makes it the exact high-water mark after an ingest, rollback, freeze or recovery, and a commit keeps it. All in-memory capacity and `Stage_Notify` checks execute *before* writing the first `"TOAS"` or `.wal` frame to disk.

> **Update (0.4):** Round 13 found the cross-transaction version of the self-overlap gap: the pages of a version superseded inside an active transaction were released while its WAL frames remained, so a concurrent transaction could commit on the same pages, and the first transaction's commit then overwrote them with stale bytes. The staged hull closes it by construction (a slot whose staged pages belong to another active transaction is also a write conflict), while a transaction may still reuse pages it staged itself, because its later frames overwrite them in WAL order at commit and in redo.

### Pattern 3: Modular Helper Contracts (`Global => null, Always_Terminates` + Concise `Post`) to Prevent Inlining Blowup
In [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb) and [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb), attaching explicit modular contracts (`Global => null`, `Always_Terminates` and concise non-tautological `Post` bounds) instructs `gnatprove` to verify complex helpers **modularly** rather than contextually inlining large loops into every caller:
- `Nhe_O.SQL` is a PostgreSQL-faithful lexer plus a token-level validator (`ADR-016`): `Tokenize` carries `Post => Toks.Count <= Query.Length`, `Parse_Limit_Part` preserves `Limit_Info_OK (Info)` (the row-limit consistency that `Analyze_SQL` promises in its own `Post`), and `Check_Create_Table` guarantees `(if OK then Name.Length > 0 and then Columns > 0)`.
- In `Nhe_O.JSON`, `@>` is the single fuel-bounded recursive walker `Value_Contains` (`ADR-015`): `Subprogram_Variant => (Decreases => Fuel)` proves its termination, its `Post` states that a match implies equal value kinds, and its helpers (`Last_Member_Value`, `Key_Repeats_Later`, `Equal_Number_Tokens`, ...) each carry their own `Global => null` and concise `Post`.

Result: each helper's loops are proved once, in isolation, and every caller reasons only about the helper's contract. (See [`swe/09-eliminating-tautological-contracts-and-contextual-inlining-in-spark.md`](09-eliminating-tautological-contracts-and-contextual-inlining-in-spark.md) for why concise non-tautological `Post` contracts beat literal `Post => True`.)

---

## 3. Where it lives in the project

- **Unified CLOG & Pre-Commit 4096-Frame WAL Scan**: [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads) and [`src/nhe_o-transaction.adb`](../../../src/nhe_o-transaction.adb).
- **First-Fit Non-Overlapping TOAST Allocator With Reserved Staged Pages (`ADR-019`), `"RMET"` Metadata TOAST & HNSW Rollback Sync**: [`src/nhe_o-rag.adb`](../../../src/nhe_o-rag.adb) and [`src/nhe_o-hnsw.adb`](../../../src/nhe_o-hnsw.adb).
- **Fuel-Bounded JSONB `@>` Walker (`Value_Contains`, `ADR-015`) & `\uXXXX` Decoder**: [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb).
- **PostgreSQL-Faithful Lexer & Token-Level SQL Validator (`Tokenize`, `ADR-016`)**: [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb).

---

## 4. Check yourself

1. **Why can a defensive `if Id <= Max_CLOG_Entries` guard pass 100% of `gnatprove` Silver (AoRTE) checks while still causing a critical MVCC visibility bug?**
2. **Why must `Ingest_Document` validate `Stage_Notify` capacity and HNSW/B+Tree index capacity *before* calling `Write_TOAST_Chain`?**
3. **Why does adding a concise `Post` contract to a non-recursive helper function in a `.adb` body dramatically speed up `gnatprove` when that helper is called inside nested loops?**
