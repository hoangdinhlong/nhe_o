# Adversarial System Review (`v0.3.0` — Epics 01–03 Audit & Epic 04 Multi-Round Remediation Record)

_Date: 2026-10-18 · Status: 🚧 Round 1 (24 findings: `CRIT-01`..`LOW-03`) ✅ Remediated & Formally Verified (`2,626 / 2,626` checks proved) · Round 2 (16 findings: `R2-CRIT-01`..`R2-LOW-04`) ☐ Recorded for Remediation in Epic 04_

This document records both rounds of full-system adversarial audits conducted on **Nhé O (`v0.3.0`)** in **Epic 04 (`04-post-epic-03-grooming-and-hardening`)**:
- **Part I (Round 1 Audit — 24 Findings: `7 Critical, 9 High, 5 Medium, 3 Low`)**: All 24 findings remediated and formally verified in Tasks 1–6.
- **Part II (Round 2 Deep System Audit — 16 Findings: `2 Critical, 5 High, 5 Medium, 4 Low`)**: Semantic ACID/MVCC, FFI persistence, IEEE 754 `Float32` TOAST precision, parser boundary, and binary spec findings queued for Tasks 7–11.

---

# Part I — Round 1 Audit & Remediation (`CRIT-01` .. `LOW-03`)

## 1. Critical Findings (`CRIT-01` .. `CRIT-07`)

| ID | Subsystem | Summary & Code Location | Remediation Status |
|---|---|---|---|
| `CRIT-01` | `Nhe_O.Transaction` / `Nhe_O.RAG` | **Primary 4KB Slotted-Page Implementation & Durable `RAG_Engine` Recovery (`BR-006` / `ADR-006`):** Added 4096-byte `"SLOT"` primary slotted-page layout (`Slotted_Page`, `Encode_Slotted_Page`, `Decode_Slotted_Page` with 24B header, 16×8B line pointer directory, 16×240B MVCC/TOAST/inline tuples, and IEEE 802.3 CRC32) in `Nhe_O.Transaction`, plus `Build_RAG_Slotted_Page` and `Recover_RAG_Engine` in `Nhe_O.RAG`. | ✅ Remediated in Epic 04 (Task 1 & Task 3) |
| `CRIT-02` | `Nhe_O.BTree` | **Multi-Level B+Tree Routing & Internal Node Splitting (`Max_BTree_Depth = 8`):** Replaced depth-2 routing with iterative root-to-leaf `Route_To_Leaf` (`Path_Nodes`/`Path_Slots` up to depth 8), bottom-up leaf and internal node splitting + root promotion in `Insert_Key`, and leftmost-leaf descent via `Children (1)` in `Range_Scan`. Verified with 20+ sequential 64-bit keys. | ✅ Remediated in Epic 04 (Task 2) |
| `CRIT-03` | `Nhe_O.BTree` | **Full 64-Bit Key, `Children (1..5)` & CRC32 Node Page Serialization:** Updated `Encode_Node_Page` and `Decode_Node_Page` (`"BTRE"` magic) to serialize full 64-bit `Integer_64` keys (`Hi` + `Lo`), internal `Children (1..5)`, strict pointer validation, and a 32-bit IEEE 802.3 page CRC32. | ✅ Remediated in Epic 04 (Task 2) |
| `CRIT-04` | `Nhe_O.Transaction` / `Nhe_O.RAG` | **CLOG-Verified MVCC Snapshot Isolation & Prior-Version Chains (`BR-002` / `ADR-006`):** Added bounded `Commit_Log` (`CLOG`, `Set_CLOG_State`, `Is_Tx_Committed`, and 3-arg `Is_Tuple_Visible`), preserved prior MVCC tuple versions (`Has_Prior_Version`, `Prior_Tuple_Hdr`, `Prior_Toast_Ptr`) in `RAG_Document_Entry` on update, and added `Delete_Document` setting `Xmax := Ctx.Id`. | ✅ Remediated in Epic 04 (Task 1 & Task 3) |
| `CRIT-05` | `Nhe_O.Transaction` | **2-Pass Committed-Only WAL Recovery & `WAL_Frame_Kind` Marker (`BR-002` / `ADR-006`):** Encoded `WAL_Frame_Kind` (`WAL_Frame_Data`, `WAL_Frame_Commit`, `WAL_Frame_KV`) in WAL header byte 17 (covered by `Compute_WAL_CRC32`), and upgraded `Redo_WAL_Recovery` to a 2-pass algorithm (Pass 1 discovers `WAL_Frame_Commit` transactions; Pass 2 replays only committed frames and reports `Status_Capacity_Exceeded` if `Max_Frames` is exceeded before EOF). | ✅ Remediated in Epic 04 (Task 1) |
| `CRIT-06` | `Nhe_O.HNSW` | **Distance-Pruned Small-World Neighbor Selection, `Doc_Id` Deduplication & Multi-Wave Beam Search:** Updated `Insert_Vector` to deduplicate existing `Doc_Id` entries in-place, select nearest candidates by metric distance, prune full adjacency lists by replacing the farthest neighbor only when closer (`Add_Edge_Pruned`), and execute greedy upper-layer descent + 4-wave small-world beam expansion in `Search_KNN`. | ✅ Remediated in Epic 04 (Task 3) |
| `CRIT-07` | `Nhe_O.HNSW` / `Nhe_O.Vector` / `Nhe_O.RAG` | **Scale-Aware `Int8` SQ8 Distance, Saturating Dequantization & 2-Stage 4096-D Vector TOAST Re-Ranking (`Q-003` / `ADR-006`):** Added `Int8_Scale` to `HNSW_Node`, added scale-aware `Int8_L2_Distance`, applied `Sqrt_Bounded` in `Node_Distance`, fixed `Dequantize_From_Int8` to saturate per-component to `[-Max_Component .. Max_Component]`, added `Encode_Vector_TOAST`/`Decode_Vector_TOAST`, and implemented Stage-2 Exact Re-Ranking in `Nhe_O.RAG`. | ✅ Remediated in Epic 04 (Task 3) |

---

## 2. High-Severity Findings (`HIGH-01` .. `HIGH-09`)

| ID | Subsystem | Summary & Code Location | Remediation Status |
|---|---|---|---|
| `HIGH-01` | `Nhe_O.C_API` | **Bounded Output Writes, Retrieved `Top_Parent` Buffer & Complete KV/PubSub Exports:** Changed C output buffers to `in out` writing only `1 .. Out_Len` (never overwriting 512 bytes unconditionally), returned retrieved TOAST parent text in `C_RAG_Query_ND`, and exported `nhe_o_kv_exists`, `nhe_o_kv_expire`, `nhe_o_kv_ttl`, and `nhe_o_pubsub_unsubscribe`. | ✅ Remediated in Epic 04 (Task 5) |
| `HIGH-02` | `Nhe_O.C_API` | **Configurable Paths (`nhe_o_init_with_paths`), `G_Initialized` Enforcement, N-D Vector/RAG FFI & Negative TTL Rejection:** Added `C_Init_With_Paths`, enforced `G_Initialized` (`C_Status_Not_Initialized`), added `nhe_o_vector_distance_nd`, `nhe_o_rag_ingest_nd`, and `nhe_o_rag_query_nd` (1..4096-D), and rejected `TTL_Sec < 0` with `C_Status_Invalid_Arg`. | ✅ Remediated in Epic 04 (Task 5) |
| `HIGH-03` | `Nhe_O.SQL` | **SQL Quote/Comment/Paren Sanitizer, Structured Descriptor Extraction & `VECTOR(1..4096)` Validation:** Added `Sanitize_SQL` (rejecting unclosed `'`, `"`, `/* */`, and unbalanced `()`, while stripping `--` and `/* */` comments), extracted `Table_Or_Target`, `Column_Count`, `Has_Where`, `Has_Order_By`, `Has_Limit`, `Limit_Value`, fixed `CREATE TABLE` with `view`/`index` column names, supported tight `?`, and enforced `VECTOR(1..4096)`. | ✅ Remediated in Epic 04 (Task 4) |
| `HIGH-04` | `Nhe_O.JSON` | **JSON-to-`JSONB_Document` Parser (`Parse_JSONB`), Validated `Put_Field` & `->` vs `->>` Semantics:** Implemented `Parse_JSONB`, added `Is_Valid_Field_Value` validation in `Put_Field`, and differentiated `Get_Field` (`->`, returning quoted JSON string `"val"`) from `Get_Field_Text` (`->>`, returning unquoted text `val`). | ✅ Remediated in Epic 04 (Task 4) |
| `HIGH-05` | `Nhe_O.RAG` | **Empty-Keyword Guard, Zero-Distance Tie-Breaking & B+Tree `PK_Tree` Verification:** Updated `Contains_Keyword` to return `False` when `Keyword.Length = 0`, added additive tie-breaking when `Distance = 0.0`, and routed document lookup through `Search_Key (Engine.PK_Tree, ...)` in `Execute_Hybrid_RAG_Query`. | ✅ Remediated in Epic 04 (Task 3) |
| `HIGH-06` | `Nhe_O.IO` / `Nhe_O_Main` | **Positional `pwrite` WAL Append, Clean EOF vs Torn Frame Detection & CLI `Too_Long` Guard:** Replaced `O_APPEND` `write` with positional `Posix_Pwrite_WAL` aligned via `Posix_Lseek (SEEK_END)`, added 5-arg `Read_WAL_Frame` with `Is_EOF`, and added 4-arg `Read_CLI_Arg` with `Too_Long` detection. | ✅ Remediated in Epic 04 (Task 1 & Task 5) |
| `HIGH-07` | `Nhe_O.PubSub` | **Transaction `Owner_Tx` Verification & Ring-Buffer Overflow `Dropped` Counter (`BR-005`):** Enforced `Staging.Owner_Tx = Ctx.Id` in `Stage_Notify`, `Flush_Committed_Notifications`, and `Discard_Staged_Notifications`, and added `Dropped` overflow tracking + `Is_Valid_Subscriber_Ring`. | ✅ Remediated in Epic 04 (Task 4) |
| `HIGH-08` | `Nhe_O.KV` / `Nhe_O_Main` | **Optional WAL-Backed KV Durability (`Q-004`), Strengthened `Post` Contracts & CLI `--kv SET` Support:** Added `Set_Durable`, `Del_Durable`, and `Recover_KV_From_WAL` (`"KVMG"` magic + CRC32), strengthened `Post` contracts on `Get`/`Expire`/`Remaining_TTL`/`Incr_By`, and updated `--kv` CLI to parse `SET <key> <val> [ttl]`. | ✅ Remediated in Epic 04 (Task 4 & Task 5) |
| `HIGH-09` | `Nhe_O.RAG` | **`Max_Safe_TOAST_Page` Invariant & TOAST Page Reuse on Same-Size Update:** Defined `Max_Safe_TOAST_Page := Max_Page_Id - (2 * Max_TOAST_Chunks)` and proved `Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page` in `Ingest_Document`'s `Post` contract. | ✅ Remediated in Epic 04 (Task 3) |

---

## 3. Medium & Low Findings (`MED-01` .. `MED-05`, `LOW-01` .. `LOW-03`)

| ID | Severity | Subsystem | Summary & Remediation Status |
|---|---|---|---|
| `MED-01` | Medium | `Nhe_O.IO` | Added 5-arg `Read_WAL_Frame` (`Post => not (Success and Is_EOF)`) and 4-arg `Read_CLI_Arg` (`Post => not (Found and Too_Long)`), with justified `SPARK_Mode (On)` boundary annotations. (**✅ Remediated in Epic 04**) |
| `MED-02` | Medium | `Nhe_O.IO` | Added bounded `EINTR` retry loops (`Max_IO_Retries = 3`) around `Posix_Pwrite`, `Posix_Pread`, `Posix_Pwrite_WAL`, and `Posix_Pread_WAL`, and replaced `O_APPEND` with positional `pwrite`. (**✅ Remediated in Epic 04**) |
| `MED-03` | Medium | `src/*.ads` | Added structural invariant functions (`Is_Valid_Node`, `Is_Valid_Tree`, `Is_Valid_HNSW`, `Is_Valid_RAG_Engine`, `Is_Valid_Subscriber_Ring`) enforced in subprogram `Pre`/`Post` contracts. (**✅ Remediated in Epic 04**) |
| `MED-04` | Medium | `docs/STATUS.md` | Synchronized exact `gnatprove` proof counts across `STATUS.md`, `ARCHITECTURE.md`, `VISION.md`, and `README.md`. (**✅ Remediated in Epic 04**) |
| `MED-05` | Medium | `config/` & `*.gpr` | Updated `config/nhe_o_config.*` to `0.3.0` and imported `config/nhe_o_config.gpr` with `-O2 -g` in `nhe_o.gpr` and `nhe_o_lib.gpr`. (**✅ Remediated in Epic 04**) |
| `LOW-01` | Low | `Nhe_O.JSON` / `Transaction` | Added RFC 8259 scalar root support in `Is_Valid_JSON` and cross-checked `Chunk_Count = ((Total_Byte_Length - 1) / TOAST_Chunk_Max_Bytes) + 1` in `Decode_TOAST_Pointer`. (**✅ Remediated in Epic 04**) |
| `LOW-02` | Low | `docs/` & headers | Updated `ADR-002`, `Epic 02 PROGRESS.md`, `Lesson 02`, `Lesson 04`, `include/nhe_o.h`, and `bindings/python/nhe_o.py` (`SPARK 2022`). (**✅ Remediated in Epic 04**) |
| `LOW-03` | Low | `docs/domain/` | Created `docs/domain/storage-and-wal-format.md` and indexed it in `docs/domain/business-rules.md`. (**✅ Remediated in Epic 04**) |

---

# Part II — Round 2 Deep System Adversarial Audit (`R2-CRIT-01` .. `R2-LOW-04`)

Conducted on `2026-10-18` across all 26 Ada/SPARK specifications and bodies (`src/*.ad[sb]`), C/Python FFI boundaries (`include/nhe_o.h`, `bindings/python/nhe_o.py`), and domain specifications (`docs/domain/`).

## 4. Round 2 Critical Findings (`R2-CRIT-01` .. `R2-CRIT-02`)

| ID | Subsystem | Detailed Finding & Code Location | Remediation Status |
|---|---|---|---|
| `R2-CRIT-01` | `Nhe_O.Transaction` / `Nhe_O.RAG` | **Unconditional `STEAL` Page Writes Without `UNDO`, Premature `CLOG` Commit in `Ingest_Document`, Inverted `Default_CLOG`/`Is_Tx_Committed`, and Missing In-Memory Rollback (`src/nhe_o-transaction.ads:32-49`, `src/nhe_o-transaction.adb:435-518, 896-898`, `src/nhe_o-rag.adb:429-460`):** (1) `Write_TOAST_Chain` and `Ingest_Document` write 4KB pages directly to `DB_Path` while `Ctx.State = Tx_Active`, and `Ingest_Document` prematurely calls `Set_CLOG_State (Engine.CLOG, Ctx.Id, Tx_Committed)` at line 429 before `Commit_Tx` is invoked. (2) `Default_CLOG` initializes all `1..1024` entries to `Tx_Committed` instead of `Tx_Idle`/`Tx_Active`, and `Is_Tx_Committed` returns `True` for all `Id > 1024`, causing dirty reads and allowing `Redo_WAL_Recovery` Pass 2 to replay uncommitted frames when `Frame_Tx > 1024`. (3) Aborting or failing mid-`Ingest_Document` leaves `Engine.Docs`, `Engine.PK_Tree`, `Engine.Vector_Graph`, and `Engine.Next_TOAST_Pg` mutated in RAM. | ☐ Pending in Epic 04 (Task 7) |
| `R2-CRIT-02` | `Nhe_O.C_API` | **`C_Init_With_Paths` Unconditionally Deletes Existing `.db` and `.wal` Files (`src/nhe_o-c_api.adb:152-153`):** Calling `nhe_o_init_with_paths` executes `Delete_File_If_Exists (G_DB_Path); Delete_File_If_Exists (G_WAL_Path);`, destroying pre-existing database and WAL files on restart instead of invoking `Recover_RAG_Engine` and `Recover_KV_From_WAL` when persistent files exist. | ☐ Pending in Epic 04 (Task 10) |

---

## 5. Round 2 High-Severity Findings (`R2-HIGH-01` .. `R2-HIGH-05`)

| ID | Subsystem | Detailed Finding & Code Location | Remediation Status |
|---|---|---|---|
| `R2-HIGH-01` | `Nhe_O.RAG` / `Nhe_O.C_API` | **`Delete_Document` Mutates `Xmax` Only in RAM Without WAL or Slotted-Page Persistence (`src/nhe_o-rag.adb:50-64`):** `Delete_Document` sets `Engine.Docs (Doc_Id).Tuple_Hdr.Xmax := Ctx.Id` in memory but never writes the updated `"SLOT"` Page 1 to the WAL or `.db`. Deleted documents resurrect as zombie rows after `Recover_RAG_Engine`, and no C ABI export (`nhe_o_rag_delete`) is exposed. | ☐ Pending in Epic 04 (Task 7 & Task 10) |
| `R2-HIGH-02` | `Nhe_O.Vector` / `docs/learning/` | **`Encode_Vector_TOAST` Fixed-Point Precision Loss for Small Components (`|c| < 1e-6`) & Missing `"VTST"` Header (`src/nhe_o-vector.adb:375-484`, `docs/learning/swe/06-two-stage-toast-vector-reranking-and-hnsw-pruning.md:51-65`):** `Encode_Vector_TOAST` uses a 2-range fixed-point multiplier (`* 1.0e6` / `* 1.0e3`) that flushes components with `|c| < 1.0e-6` to `0.0`, and writes `V.Dim * 4` bytes without the `"VTST"` header described in Lesson 06. Must use exponent-preserving / IEEE-754-faithful float encoding and align code with documentation. | ☐ Pending in Epic 04 (Task 8 & Task 11) |
| `R2-HIGH-03` | `Nhe_O.RAG` | **`Recover_RAG_Engine` Confuses `Summary_Text` with `Metadata` JSONB (`src/nhe_o-rag.adb:93-115, 261-265`):** `Encode_Engine_Slotted_Page` stores only `Summary_Text` in `Inline_Data (33..208)` and does not persist `Metadata : JSONB_Document`. On recovery, `Recover_RAG_Engine` passes `Summary_Val` into `Parse_JSONB`, losing structured JSONB metadata for normal text summaries or misinterpreting JSON-like summaries as metadata. | ☐ Pending in Epic 04 (Task 7) |
| `R2-HIGH-04` | `Nhe_O.RAG` | **`Execute_Hybrid_RAG_Query` Ignores SQL `LIMIT` Clause and Initializes `Fallback_D := 0.0` (`src/nhe_o-rag.adb:725-801`):** `SQL_Desc.Has_Limit` / `SQL_Desc.Limit_Value` extracted by `Analyze_SQL` is ignored during candidate ranking, and the fallback scan initializes `Fallback_D := 0.0` (perfect match distance) before scanning `Vector_Graph.Nodes`, which would rank an unindexed slot #1 with distance `0.0`. | ☐ Pending in Epic 04 (Task 8) |
| `R2-HIGH-05` | `Nhe_O.KV` | **`Recover_KV_From_WAL` Silently Truncates WAL Replay at `Max_Frames` (`src/nhe_o-kv.adb:626-671`):** Unlike `Redo_WAL_Recovery` (`src/nhe_o-transaction.adb:874-880`), `Recover_KV_From_WAL` stops after `Max_Frames` frames and returns `Status_Ok` without probing frame `Max_Frames` for `Status_Capacity_Exceeded`. | ☐ Pending in Epic 04 (Task 9) |

---

## 6. Round 2 Medium & Low Findings (`R2-MED-01` .. `R2-MED-05`, `R2-LOW-01` .. `R2-LOW-04`)

| ID | Severity | Subsystem | Detailed Finding & Code Location | Remediation Status |
|---|---|---|---|---|
| `R2-MED-01` | Medium | `Nhe_O.SQL` | **`Sanitize_SQL` Replaces Opening `'` with `'_'` (`Is_Ident_Char`) & `Analyze_SQL` Accepts Multi-Statement `;` Tail (`src/nhe_o-sql.adb:90-93, 529-617`):** Replacing `'` with `'_'` merges adjacent keywords without whitespace (`SELECT'a'` -> `SELECT_`), breaking keyword boundary detection; additionally, `Analyze_SQL` does not reject trailing statements after `;` (e.g., `SELECT 1; DROP TABLE x;`). | ☐ Pending in Epic 04 (Task 9) |
| `R2-MED-02` | Medium | `Nhe_O.JSON` | **`Parse_JSONB` Accepts Repeated/Leading Commas & Colons and Silently Truncates `> 512B` Values (`src/nhe_o-json.adb:454-460, 512-518, 539-552`):** Treating `,` and `:` as generic whitespace in `Parse_JSONB` accepts malformed objects like `{,"a":::1,,"b":2}`, and string/nested values exceeding `Max_Text_Len` are silently truncated instead of returning `Status_Capacity_Exceeded`. | ☐ Pending in Epic 04 (Task 9) |
| `R2-MED-03` | Medium | `Nhe_O.RAG` | **Unreclaimed TOAST Page Allocation on Different-Size Document Updates (`src/nhe_o-rag.adb:351-398`):** When updating an existing document whose new payload chunk count differs from its previous allocation, `Next_Toast_Page` advances monotonically without reclaiming superseded TOAST chains once no active/prior MVCC version references them. | ☐ Pending in Epic 04 (Task 7) |
| `R2-MED-04` | Medium | `Nhe_O.BTree` | **`Insert_Key` Omits `Total_Keys` Increment on Leaf Split & Missing `Delete_Key` (`src/nhe_o-btree.adb:269-369`):** `Tree.Total_Keys` is incremented only on the non-full leaf fast path (`lines 271-273`) and is not incremented when a full leaf splits (`lines 278-369`); additionally, `Nhe_O.BTree` lacks `Delete_Key` to remove deleted keys. | ☐ Pending in Epic 04 (Task 8) |
| `R2-MED-05` | Medium | `Nhe_O.PubSub` | **`Flush_Committed_Notifications` Unconditionally Zeroes `Staging` When Uncommitted or Mismatched `Owner_Tx` (`src/nhe_o-pubsub.adb:150-180`):** Lines `177-179` clear `Staging.Count := 0` even when `Ctx.State /= Tx_Committed` or `Staging.Owner_Tx /= Ctx.Id`, discarding staged notifications of an active transaction if called prematurely. | ☐ Pending in Epic 04 (Task 9) |
| `R2-LOW-01` | Low | `docs/domain/` | **Byte-Offset Discrepancies in `docs/domain/storage-and-wal-format.md` (`lines 18, 70-105`):** Table 1 (`WAL_Frame_Buffer` CRC32 coverage), Table 4 (`"BTRE"` `Node_Kind = 1/2` and `Page_CRC32` at bytes `13..16`), and Table 5 (`"KVMG"` `Last_Access` at `21..28` and `Page_CRC32` at `29..32`) differ from the byte offsets in `nhe_o-transaction.adb`, `nhe_o-btree.adb`, and `nhe_o-kv.adb`. | ☐ Pending in Epic 04 (Task 11) |
| `R2-LOW-02` | Low | `bindings/python/` | **`NheOEngine.__init__` Silently Ignores Single Path Argument & Hardcodes `/tmp/nhe_o_c_api.*` (`bindings/python/nhe_o.py:96-101`):** Passing only `db_path` without `wal_path` (or vice versa) silently falls back to `/tmp/nhe_o_c_api.*` instead of raising `ValueError`. | ☐ Pending in Epic 04 (Task 10) |
| `R2-LOW-03` | Low | `Nhe_O.C_API` | **C ABI RAG Ingest/Query Lacks JSONB Metadata & Truncates Parent Payload to 512B (`src/nhe_o-c_api.adb:791-944`):** `C_RAG_Ingest_ND` always passes `Empty_Meta` and limits parent payload to 512 bytes, and `C_RAG_Query_ND` lacks a metadata filter parameter. | ☐ Pending in Epic 04 (Task 10) |
| `R2-LOW-04` | Low | `Nhe_O.IO` | **`Read_Page` and `Read_WAL_Frame` Retry Loops Exit on Short Reads (`0 < N_Read < Target`) (`src/nhe_o-io.adb:211-214, 351-354`):** The retry condition `exit when N_Read >= 0;` exits immediately on a short read instead of retrying until `N_Read = Page_Size` (or `N_Read = 0` for EOF). | ☐ Pending in Epic 04 (Task 7) |

