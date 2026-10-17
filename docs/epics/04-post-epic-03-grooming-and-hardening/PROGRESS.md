# Epic 04 — Post-Epic-03 Grooming & Core Hardening (Adversarial Audit Remediation)

**Goal:** Execute the project's first dedicated **Grooming & Hardening Epic** following Feature Epics 01–03 by remediating all 24 findings (`7 Critical, 9 High, 5 Medium, 3 Low`) from `ADVERSARIAL-REVIEW.md`, resolving open questions `Q-003` (4096-D Vector TOAST overflow storage & Stage-2 Exact Re-Ranking) and `Q-004` (Optional WAL-backed KV durability and recovery), codifying binary page/WAL/TOAST/B+Tree byte layouts in `docs/domain/storage-and-wal-format.md`, and proving 100% SPARK Stone, Bronze, Silver (AoRTE), and Gold contracts (`0 unproved` checks, `0 warnings`) across all 26 source files in `src/`.

**Definition of done:**
1. Remediate all 7 Critical findings (`CRIT-01`..`CRIT-07`): primary 4KB `"SLOT"` slotted-page persistence & `Recover_RAG_Engine` (`CRIT-01`), multi-level `Max_BTree_Depth = 8` B+Tree routing/splitting (`CRIT-02`), full 64-bit key + `Children` + CRC32 B+Tree page serialization (`CRIT-03`), bounded `Commit_Log` (`CLOG`) + MVCC prior-version chain + `Delete_Document` (`CRIT-04`), 2-pass committed-only `Redo_WAL_Recovery` with `WAL_Frame_Kind` byte 17 (`CRIT-05`), distance-pruned HNSW small-world edge selection + `Doc_Id` deduplication + multi-wave beam search (`CRIT-06`), and scale-aware `Int8` SQ8 distance + saturating dequantization + 4096-D Vector TOAST Stage-2 Exact Re-Ranking (`CRIT-07`, `Q-003`).
2. Remediate all 9 High findings (`HIGH-01`..`HIGH-09`): bounded C/Python FFI buffer writes, `G_Initialized` guard, `nhe_o_init_with_paths`, N-D vector/RAG FFI, and KV/PubSub C exports (`HIGH-01`, `HIGH-02`), SQL comment/quote sanitization + structured descriptor extraction + `VECTOR(1..4096)` bounds (`HIGH-03`), RFC 8259 scalar JSON validation + `Parse_JSONB` + `->` vs `->>` distinction (`HIGH-04`), RAG empty-keyword guard + additive zero-distance tie-break + `PK_Tree` lookup (`HIGH-05`), positional `pwrite` WAL append + `EINTR` retry loops + 5-arg `Read_WAL_Frame` `Is_EOF` + 4-arg `Read_CLI_Arg` `Too_Long` (`HIGH-06`), Pub/Sub `Owner_Tx` verification + ring overflow `Dropped` counter (`HIGH-07`), optional WAL-backed `Set_Durable`/`Del_Durable`/`Recover_KV_From_WAL` + KV `Post` contracts + `--kv SET <key> <val> [ttl]` CLI parsing (`HIGH-08`, `Q-004`), and `Max_Safe_TOAST_Page` preservation (`HIGH-09`).
3. Remediate all 5 Medium and 3 Low findings (`MED-01`..`MED-05`, `LOW-01`..`LOW-03`), including `config/nhe_o_config.*` (`0.3.0`, `-O2 -g`), `Decode_TOAST_Pointer` `Chunk_Count` cross-check, and `docs/domain/storage-and-wal-format.md`.
4. Pass `gnatprove -P nhe_o.gpr --mode=all --level=2` with `0 unproved` checks and `0 warnings`, `alr build && alr run` (all 11 suites), and `gprbuild -P nhe_o_lib.gpr && python3 bindings/python/nhe_o.py`.

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Remediate Storage, MVCC, WAL & TOAST findings (`CRIT-01`, `CRIT-04`, `CRIT-05`, `HIGH-06`, `MED-01`, `MED-02`, `LOW-01`) in `Nhe_O.IO` and `Nhe_O.Transaction` | ☑ | `alr run` Suite `[4/11]` & `[5/11]` + `gnatprove` (`Nhe_O.IO` & `Nhe_O.Transaction` 100% proved) |
| 2 | Remediate Multi-Level B+Tree & 64-Bit CRC32 Page Serialization findings (`CRIT-02`, `CRIT-03`, `MED-03`) in `Nhe_O.BTree` | ☑ | `alr run` Suite `[6/11]` (20-key multi-level split & CRC32 page test) |
| 3 | Remediate 4096-D Vector, SQ8 Scale, HNSW Graph & Stage-2 TOAST Re-Ranking (`CRIT-06`, `CRIT-07`, `HIGH-05`, `HIGH-09`, `Q-003`) in `Nhe_O.Vector`, `Nhe_O.HNSW`, and `Nhe_O.RAG` | ☑ | `alr run` Suite `[2/11]`, `[7/11]`, `[10/11]` (`Nhe_O.Vector` 17/17 100% proved) |
| 4 | Remediate SQL Sanitizer/Descriptor, RFC 8259 JSON/JSONB Parser, Pub/Sub `Owner_Tx`, and Durable KV WAL (`HIGH-03`, `HIGH-04`, `HIGH-07`, `HIGH-08`, `Q-004`) in `Nhe_O.SQL`, `Nhe_O.JSON`, `Nhe_O.PubSub`, and `Nhe_O.KV` | ☑ | `alr run` Suite `[1/11]`, `[3/11]`, `[8/11]`, `[9/11]` + `gnatprove` (`SQL`, `JSON`, `PubSub`, `KV` 100% proved) |
| 5 | Remediate C ABI / Python SDK, Build Config & Domain Spec findings (`HIGH-01`, `HIGH-02`, `MED-04`, `MED-05`, `LOW-02`, `LOW-03`) across `Nhe_O.C_API`, `include/nhe_o.h`, `bindings/python/nhe_o.py`, `nhe_o_main.adb`, `config/`, and `docs/` | ☑ | `alr run` Suite `[11/11]` + `python3 bindings/python/nhe_o.py` (`Nhe_O.C_API` 100% proved) |
| 6 | Discharge final 9 `gnatprove` VCs (`2,638 / 2,647` proved = `99.66%`) and eliminate `-gnatwa` membership warnings in `nhe_o-transaction.adb` and `nhe_o_main.adb` | ◐ | 9 remaining VCs: `BTree.Insert_Key` (1), `HNSW.Add_Edge_Pruned` (1), `HNSW.Node_Distance` (2), `RAG.Delete_Document` (1 flow), `Nhe_O_Main` (3), `Parse_Positive_Int` (1) |

## Notes / sequencing
- Follows the **Feature Epic → Grooming Epic** cadence codified in `AGENTS.md` and `docs/epics/README.md`.
- See [`ADVERSARIAL-REVIEW.md`](ADVERSARIAL-REVIEW.md) for the complete 24-finding audit log and remediation verification matrix.
- **Session Handoff Checkpoint (2026-10-17)**: All 24 adversarial findings are implemented and pass 100% of runtime tests (`alr build && alr run` Suites `[1/11]`..`[11/11]` and `python3 bindings/python/nhe_o.py`). 10 of 14 units (`Nhe_O`, `Types`, `Vector`, `JSON`, `IO`, `Transaction`, `KV`, `PubSub`, `SQL`, `C_API`) are 100% proved by `gnatprove`; only 9 VCs out of 2,647 remain in Task 6 for the start of the next session.

## Open questions
- `Q-003` and `Q-004` resolved and marked `Answered` in `docs/OPEN-QUESTIONS.md` (`ADR-006`, `ADR-007`).

