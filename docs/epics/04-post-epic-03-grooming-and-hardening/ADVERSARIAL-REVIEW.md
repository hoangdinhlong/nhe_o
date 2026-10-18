# Adversarial System Review (`v0.3.0` — Epics 01–03 Audit & Epic 04 Remediation Record)

_Date: 2026-10-18 · Status: ✅ All 24 findings remediated & formally verified in Epic 04 (`2,626 / 2,626` checks proved, `0 unproved`, `0 warnings`)_

This document records the 24 verified findings (**7 Critical, 9 High, 5 Medium, 3 Low**) uncovered during the comprehensive adversarial review of **Nhé O (`v0.3.0`)** after completing Epics 01–03, together with their concrete remediation in **Epic 04 (`04-post-epic-03-grooming-and-hardening`)**.

---

## 1. Critical Findings (`CRIT-01` .. `CRIT-07`)

| ID | Subsystem | Summary & Code Location | Remediation Status |
|---|---|---|---|
| `CRIT-01` | `Nhe_O.Transaction` / `Nhe_O.RAG` | **Primary 4KB Slotted-Page Implementation & Durable `RAG_Engine` Recovery (`BR-006` / `ADR-006`):** Added 4096-byte `"SLOT"` primary slotted-page layout (`Slotted_Page`, `Encode_Slotted_Page`, `Decode_Slotted_Page` with 24B header, 16×8B line pointer directory, 16×240B MVCC/TOAST/inline tuples, and IEEE 802.3 CRC32) in `Nhe_O.Transaction`, plus `Build_RAG_Slotted_Page` and `Recover_RAG_Engine` in `Nhe_O.RAG`. | ✅ Remediated in Epic 04 (Task 1 & Task 3) |
| `CRIT-02` | `Nhe_O.BTree` | **Multi-Level B+Tree Routing & Internal Node Splitting (`Max_BTree_Depth = 8`):** Replaced depth-2 routing with iterative root-to-leaf `Route_To_Leaf` (`Path_Nodes`/`Path_Slots` up to depth 8), bottom-up leaf and internal node splitting + root promotion in `Insert_Key`, and leftmost-leaf descent via `Children (1)` in `Range_Scan`. Verified with 20+ sequential 64-bit keys. | ✅ Remediated in Epic 04 (Task 2) |
| `CRIT-03` | `Nhe_O.BTree` | **Full 64-Bit Key, `Children (1..5)` & CRC32 Node Page Serialization:** Updated `Encode_Node_Page` and `Decode_Node_Page` (`"BTRE"` magic) to serialize full 64-bit `Integer_64` keys (`Hi` + `Lo`), internal `Children (1..5)`, strict pointer validation, and a 32-bit IEEE 802.3 page CRC32 at bytes `4093..4096`. | ✅ Remediated in Epic 04 (Task 2) |
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
