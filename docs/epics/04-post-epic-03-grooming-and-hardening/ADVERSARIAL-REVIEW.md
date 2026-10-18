# Adversarial System Review (`v0.3.0` — Epics 01–03 Audit & Epic 04 Multi-Round Remediation Record)

_Date: 2026-10-18 · Status: ✅ All 40 Findings Remediated (Round 1: 24/24 `CRIT-01`..`LOW-03` · Round 2: 16/16 `R2-CRIT-01`..`R2-LOW-04`) & Formally Verified (`2,863 / 2,863` checks proved, `0 unproved`, `0 warnings`)_

This document records both rounds of full-system adversarial audits conducted on **Nhé O (`v0.3.0`)** in **Epic 04 (`04-post-epic-03-grooming-and-hardening`)**:
- **Part I (Round 1 Audit — 24 Findings: `7 Critical, 9 High, 5 Medium, 3 Low`)**: All 24 findings remediated and formally verified in Tasks 1–6.
- **Part II (Round 2 Deep System Audit — 16 Findings: `2 Critical, 5 High, 5 Medium, 4 Low`)**: All 16 semantic ACID/MVCC, FFI persistence, `"VTST"` `Float32` TOAST precision, parser boundary, and binary spec findings remediated and formally verified in Tasks 7–11.

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

Conducted on `2026-10-18` across all 26 Ada/SPARK specifications and bodies (`src/*.ad[sb]`), C/Python FFI boundaries (`include/nhe_o.h`, `bindings/python/nhe_o.py`), and domain specifications (`docs/domain/`). All 16 findings are remediated and verified in Tasks 7–11.

## 4. Round 2 Critical Findings (`R2-CRIT-01` .. `R2-CRIT-02`)

| ID | Subsystem | Detailed Finding & Remediation Summary | Remediation Status |
|---|---|---|---|
| `R2-CRIT-01` | `Nhe_O.Transaction` / `Nhe_O.RAG` | **True `NO-STEAL` Page Writes, Deferred `CLOG` Commit, Safe `Default_CLOG := [others => Tx_Idle]`, Strict `Is_Tx_Committed`, and Transactional Rollback (`src/nhe_o-transaction.ad[sb]`, `src/nhe_o-rag.ad[sb]`):** (1) Changed `Write_TOAST_Chain`, `Ingest_Document`, and `Delete_Document` to stage 4KB `"TOAS"` and `"SLOT"` pages exclusively as `WAL_Frame_Data` frames in `WAL_Path` during `Tx_Active` (`Set_CLOG_State (Engine.CLOG, Ctx.Id, Tx_Active)`), and updated `Commit_Tx` to flush all `WAL_Frame_Data` frames of `Ctx.Id` to `DB_Path` only after the `WAL_Frame_Commit` barrier frame is durable. (2) Changed `Default_CLOG` to `[others => Tx_Idle]` and `Is_Tx_Committed` to return `False` for `Id > Max_CLOG_Entries`. (3) Saved/restored `Saved_Engine` on mid-operation failure and added `Rollback_RAG_Tx`. | ✅ Remediated in Epic 04 (Task 7) |
| `R2-CRIT-02` | `Nhe_O.C_API` | **Non-Destructive `C_Init_With_Paths` Recovery & Durable KV Persistence (`src/nhe_o-c_api.adb`):** Removed unconditional `Delete_File_If_Exists` from `C_Init_With_Paths` so existing `.db` and `.wal` files are recovered via `Recover_KV_From_WAL`, `Redo_WAL_Recovery`, and `Recover_RAG_Engine`, and updated `C_KV_Set`/`C_KV_Del` to persist via `Set_Durable`/`Del_Durable` when `G_WAL_Path` is configured. | ✅ Remediated in Epic 04 (Task 10) |

---

## 5. Round 2 High-Severity Findings (`R2-HIGH-01` .. `R2-HIGH-05`)

| ID | Subsystem | Detailed Finding & Remediation Summary | Remediation Status |
|---|---|---|---|
| `R2-HIGH-01` | `Nhe_O.RAG` / `Nhe_O.C_API` | **Durable `Delete_Document` with WAL/Slotted-Page Persistence & `nhe_o_rag_delete` Export (`src/nhe_o-rag.ad[sb]`, `src/nhe_o-c_api.ad[sb]`, `include/nhe_o.h`, `bindings/python/nhe_o.py`):** Added 6-argument durable `Delete_Document` staging `"SLOT"` Page 1 in `WAL_Path`, updated `Recover_RAG_Engine` to mark `Tuple_Hdr.Xmin`/`Xmax` in `CLOG` and exclude deleted (`Xmax > 0`) rows from `Doc_Count` and post-delete visibility, and exported `nhe_o_rag_delete` (`C_RAG_Delete`) and `NheOEngine.rag_delete`. | ✅ Remediated in Epic 04 (Task 7 & Task 10) |
| `R2-HIGH-02` | `Nhe_O.Vector` / `docs/learning/` | **8-Byte `"VTST"` Header & Tiered Scientific `Float32` TOAST Encoding (`src/nhe_o-vector.ad[sb]`, `src/nhe_o-transaction.ads`):** Increased `Max_TOAST_Payload_Bytes` to `16_392` (`8B "VTST" header + 4096 * 4B`), added `Vector_TOAST_Byte_Length`, prepended `"VTST"` + big-endian `Dim` in `Encode_Vector_TOAST`, verified header/dimension in `Decode_Vector_TOAST`, and replaced fixed-point scaling with 8-decade tiered scientific encoding (`Exp_Code 0..7`, `Mantissa 0..10^8`) preserving magnitudes down to `1.0e-7`. | ✅ Remediated in Epic 04 (Task 8 & Task 11) |
| `R2-HIGH-03` | `Nhe_O.RAG` | **Structured `JSONB_Document` Metadata Persistence in `"SLOT"` Page 1 (`src/nhe_o-rag.adb`):** Updated `Build_RAG_Slotted_Page` and `Recover_RAG_Engine` to pack `Summary_Text` in `Inline_Data (17..96)` and serialize up to `Max_JSON_Fields` `JSONB_Document` key/value/kind entries in `Inline_Data (97..208)` so both summary text and `@>` JSONB metadata survive crash recovery. | ✅ Remediated in Epic 04 (Task 7) |
| `R2-HIGH-04` | `Nhe_O.RAG` | **SQL `LIMIT` Enforcement & Safe `Fallback_D := Float'Last` in `Execute_Hybrid_RAG_Query` (`src/nhe_o-rag.adb`):** Capped `Effective_K` by `SQL_Desc.Limit_Value` when `SQL_Desc.Has_Limit` is true (returning `0` hits on `LIMIT 0`) and initialized `Fallback_D := Float'Last` with an explicit `Found_Node` guard in the fallback scan. | ✅ Remediated in Epic 04 (Task 8) |
| `R2-HIGH-05` | `Nhe_O.KV` | **WAL Overflow Detection Beyond `Max_Frames` in `Recover_KV_From_WAL` (`src/nhe_o-kv.adb`):** Probed frame `Valid_Page_Id (Max_Frames)` after the recovery loop and returned `Status_Capacity_Exceeded` if additional frames exist before EOF. | ✅ Remediated in Epic 04 (Task 9) |

---

## 6. Round 2 Medium & Low Findings (`R2-MED-01` .. `R2-MED-05`, `R2-LOW-01` .. `R2-LOW-04`)

| ID | Severity | Subsystem | Detailed Finding & Remediation Summary | Remediation Status |
|---|---|---|---|---|
| `R2-MED-01` | Medium | `Nhe_O.SQL` | **Quote/Comment Keyword Boundary & Multi-Statement Rejection (`src/nhe_o-sql.adb`):** Preserved opening `'` in `Sanitize_SQL`, relaxed `Starts_With_Keyword` to accept any `not Is_Ident_Char (Next_C)` (`SELECT/*c*/1`, `SELECT'a'`, `SELECT(1)`), and added `Has_Multi_Statement_Tail` to reject trailing tokens after `;` or leading `;`. | ✅ Remediated in Epic 04 (Task 9) |
| `R2-MED-02` | Medium | `Nhe_O.JSON` | **Strict Single-Delimiter & Capacity Checks in `Parse_JSONB` (`src/nhe_o-json.adb`):** Enforced exact single `:` and `,` delimiters between members (rejecting `{,"a":1}`, `{"a":::1}`, `{"a":1,,"b":2}`) and returned `Status_Capacity_Exceeded` when keys or values exceed `Max_Ident_Len` / `Max_Text_Len`. | ✅ Remediated in Epic 04 (Task 9) |
| `R2-MED-03` | Medium | `Nhe_O.RAG` | **Retired TOAST Chain Reclamation & In-Place Reuse (`src/nhe_o-rag.ad[sb]`):** Added `Prior_Vec_Toast_Ptr` to `RAG_Document_Entry`, added `Recompute_TOAST_High_Water_Mark` to reclaim tail TOAST pages from superseded versions, and reused retired TOAST page ranges whenever `Needed_Chunks <= Retired_Ptr.Chunk_Count`. | ✅ Remediated in Epic 04 (Task 7) |
| `R2-MED-04` | Medium | `Nhe_O.BTree` | **`Total_Keys` Split Accounting & `Delete_Key` (`src/nhe_o-btree.ad[sb]`):** Verified `Tree.Total_Keys` increments across all leaf/internal/root split paths and implemented `Delete_Key` with proven `Total_Keys` decrement contract. | ✅ Remediated in Epic 04 (Task 8) |
| `R2-MED-05` | Medium | `Nhe_O.PubSub` | **Owner-Guarded `Staging` Reset in `Flush_Committed_Notifications` & `Discard_Staged_Notifications` (`src/nhe_o-pubsub.ad[sb]`):** Guarded `Staging` zeroing so a foreign or uncommitted transaction never wipes an active owner's staged notifications. | ✅ Remediated in Epic 04 (Task 9) |
| `R2-LOW-01` | Low | `docs/domain/` | **Exact Byte-Offset Alignment in `storage-and-wal-format.md` & Lesson 06 (`docs/domain/storage-and-wal-format.md`, `docs/learning/swe/06-*.md`):** Synchronized Tables 1–5 (`WAL_Frame_Buffer`, `"SLOT"` header/inline JSONB layout, `"VTST"` 8B header, `"BTRE"` CRC32 at `13..16` & `Node_Kind = 1/2`, and `"KVMG"` `Last_Access` at `21..28` & CRC32 at `29..32`) with the Ada implementation. | ✅ Remediated in Epic 04 (Task 11) |
| `R2-LOW-02` | Low | `bindings/python/` | **Strict Path Validation in `NheOEngine.__init__` (`bindings/python/nhe_o.py`):** Raised `ValueError` when only one of `db_path` or `wal_path` is provided instead of silently falling back to `/tmp/nhe_o_c_api.*`. | ✅ Remediated in Epic 04 (Task 10) |
| `R2-LOW-03` | Low | `Nhe_O.C_API` | **Full JSONB Metadata & 16,392-Byte TOAST Parent Support Across C ABI (`src/nhe_o-c_api.ad[sb]`, `include/nhe_o.h`, `bindings/python/nhe_o.py`):** Added `nhe_o_rag_ingest_full_nd` (`C_RAG_Ingest_Full_ND`) and `nhe_o_rag_query_full_nd` (`C_RAG_Query_Full_ND`) supporting JSONB metadata and full `C_Toast_Buf` (`16,392` bytes) parent payloads. | ✅ Remediated in Epic 04 (Task 10) |
| `R2-LOW-04` | Low | `Nhe_O.IO` | **Short-Read Retry in `Read_Page` & `Read_WAL_Frame` (`src/nhe_o-io.adb`):** Updated retry loops to continue retrying on short reads (`0 < N_Read < Target`) up to `Max_IO_Retries`. | ✅ Remediated in Epic 04 (Task 7) |

