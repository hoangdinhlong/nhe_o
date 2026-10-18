# Epic 04 — Post-Epic-03 Grooming & Core Hardening (Adversarial Audit Remediation)

**Goal:** Execute the project's first dedicated **Grooming & Hardening Epic** following Feature Epics 01–03 by remediating all 40 findings across both rounds of `ADVERSARIAL-REVIEW.md` (**Round 1: 24 findings `CRIT-01`..`LOW-03` [Done]; Round 2: 16 findings `R2-CRIT-01`..`R2-LOW-04` [Done]**), resolving open questions `Q-003` (4096-D Vector TOAST overflow storage & Stage-2 Exact Re-Ranking) and `Q-004` (Optional WAL-backed KV durability and recovery), codifying binary page/WAL/TOAST/B+Tree byte layouts in `docs/domain/storage-and-wal-format.md`, and proving 100% SPARK Stone, Bronze, Silver (AoRTE), and Gold contracts (`2,863 / 2,863` checks proved, `0 unproved` checks, `0 warnings`) across all 26 source files in `src/`.

**Definition of done:**
1. Remediate all 7 Round-1 Critical findings (`CRIT-01`..`CRIT-07`), 9 High findings (`HIGH-01`..`HIGH-09`), 5 Medium findings (`MED-01`..`MED-05`), and 3 Low findings (`LOW-01`..`LOW-03`) in Tasks 1–6.
2. Remediate all 16 Round-2 Deep System Audit findings (`R2-CRIT-01`..`R2-CRIT-02`, `R2-HIGH-01`..`R2-HIGH-05`, `R2-MED-01`..`R2-MED-05`, `R2-LOW-01`..`R2-LOW-04`) in Tasks 7–11:
   - True `NO-STEAL` / commit-gated page persistence, `Default_CLOG := [others => Tx_Idle]`, strict `Is_Tx_Committed`, transactional rollback, durable `Delete_Document`, metadata persistence in `Recover_RAG_Engine`, TOAST reclamation, and short-read retry (`R2-CRIT-01`, `R2-HIGH-01`, `R2-HIGH-03`, `R2-MED-03`, `R2-LOW-04`).
   - IEEE-754-faithful `"VTST"` Vector TOAST encoding (`R2-HIGH-02`), SQL `LIMIT` enforcement & safe `Fallback_D` in `Execute_Hybrid_RAG_Query` (`R2-HIGH-04`), and `BTree.Total_Keys` split accounting + `Delete_Key` (`R2-MED-04`).
   - `Recover_KV_From_WAL` overflow detection (`R2-HIGH-05`), `Sanitize_SQL` quote boundary & single-statement enforcement (`R2-MED-01`), strict `Parse_JSONB` delimiter/capacity checks (`R2-MED-02`), and safe `Flush_Committed_Notifications` (`R2-MED-05`).
   - Non-destructive `C_Init_With_Paths` recovery (`R2-CRIT-02`), C ABI `nhe_o_rag_delete` + JSONB metadata/parent support (`R2-LOW-03`), Python SDK path validation (`R2-LOW-02`), and exact byte-offset alignment in `docs/domain/storage-and-wal-format.md` & Lesson 06 (`R2-LOW-01`).
3. Pass `gnatprove -P nhe_o.gpr --mode=all --level=2 -j24` with `0 unproved` checks and `0 warnings`, `alr build && alr run` (all 11 suites), and `gprbuild -P nhe_o_lib.gpr && python3 bindings/python/nhe_o.py`.

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Remediate Storage, MVCC, WAL & TOAST findings (`CRIT-01`, `CRIT-04`, `CRIT-05`, `HIGH-06`, `MED-01`, `MED-02`, `LOW-01`) in `Nhe_O.IO` and `Nhe_O.Transaction` | ☑ | `alr run` Suite `[4/11]` & `[5/11]` + `gnatprove` (`Nhe_O.IO` & `Nhe_O.Transaction` 100% proved) |
| 2 | Remediate Multi-Level B+Tree & 64-Bit CRC32 Page Serialization findings (`CRIT-02`, `CRIT-03`, `MED-03`) in `Nhe_O.BTree` | ☑ | `alr run` Suite `[6/11]` (20-key multi-level split & CRC32 page test) |
| 3 | Remediate 4096-D Vector, SQ8 Scale, HNSW Graph & Stage-2 TOAST Re-Ranking (`CRIT-06`, `CRIT-07`, `HIGH-05`, `HIGH-09`, `Q-003`) in `Nhe_O.Vector`, `Nhe_O.HNSW`, and `Nhe_O.RAG` | ☑ | `alr run` Suite `[2/11]`, `[7/11]`, `[10/11]` (`Nhe_O.Vector` 17/17 100% proved) |
| 4 | Remediate SQL Sanitizer/Descriptor, RFC 8259 JSON/JSONB Parser, Pub/Sub `Owner_Tx`, and Durable KV WAL (`HIGH-03`, `HIGH-04`, `HIGH-07`, `HIGH-08`, `Q-004`) in `Nhe_O.SQL`, `Nhe_O.JSON`, `Nhe_O.PubSub`, and `Nhe_O.KV` | ☑ | `alr run` Suite `[1/11]`, `[3/11]`, `[8/11]`, `[9/11]` + `gnatprove` (`SQL`, `JSON`, `PubSub`, `KV` 100% proved) |
| 5 | Remediate C ABI / Python SDK, Build Config & Domain Spec findings (`HIGH-01`, `HIGH-02`, `MED-04`, `MED-05`, `LOW-02`, `LOW-03`) across `Nhe_O.C_API`, `include/nhe_o.h`, `bindings/python/nhe_o.py`, `nhe_o_main.adb`, `config/`, and `docs/` | ☑ | `alr run` Suite `[11/11]` + `python3 bindings/python/nhe_o.py` (`Nhe_O.C_API` 100% proved) |
| 6 | Discharge final Round-1 `gnatprove` VCs (`2,626 / 2,626` proved = `100%`) and eliminate `-gnatwa`/`-gnatwc` compiler warnings in `nhe_o-transaction.adb` and `nhe_o_main.adb` | ☑ | `gnatprove -P nhe_o.gpr --mode=all --level=2 -j24` (`2,626/2,626` checks proved across all 14 units, `0 unproved`, `0 warnings`, max time `<1s`) + `gprbuild -f -j24` (`0 warnings`) |
| 7 | Remediate Round-2 ACID/MVCC, Durable Delete, Metadata Recovery, TOAST Reclamation & Short-Read Retry findings (`R2-CRIT-01`, `R2-HIGH-01`, `R2-HIGH-03`, `R2-MED-03`, `R2-LOW-04`) in `Nhe_O.IO`, `Nhe_O.Transaction`, and `Nhe_O.RAG` | ☑ | `alr run` Suites `[4/11]`, `[5/11]`, `[10/11]` + `gnatprove -j24` (`Nhe_O.IO`, `Nhe_O.Transaction`, `Nhe_O.RAG` 100% proved) |
| 8 | Remediate Round-2 Vector TOAST Precision/Header, RAG SQL `LIMIT` & `Fallback_D`, and B+Tree Split `Total_Keys` + `Delete_Key` (`R2-HIGH-02`, `R2-HIGH-04`, `R2-MED-04`) in `Nhe_O.Vector`, `Nhe_O.BTree`, and `Nhe_O.RAG` | ☑ | `alr run` Suites `[2/11]`, `[6/11]`, `[10/11]` + `gnatprove -j24` (`Nhe_O.Vector`, `Nhe_O.BTree`, `Nhe_O.RAG` 100% proved) |
| 9 | Remediate Round-2 KV WAL Overflow Detection, SQL Quote Boundary / Multi-Statement Guard, Strict `Parse_JSONB`, and Pub/Sub `Flush_Committed_Notifications` (`R2-HIGH-05`, `R2-MED-01`, `R2-MED-02`, `R2-MED-05`) in `Nhe_O.KV`, `Nhe_O.SQL`, `Nhe_O.JSON`, and `Nhe_O.PubSub` | ☑ | `alr run` Suites `[1/11]`, `[3/11]`, `[8/11]`, `[9/11]` + `gnatprove -j24` (`KV`, `SQL`, `JSON`, `PubSub` 100% proved) |
| 10 | Remediate Round-2 Non-Destructive `C_Init_With_Paths` Recovery, C ABI RAG Delete/Metadata/Parent Support, and Python SDK Path Validation (`R2-CRIT-02`, `R2-LOW-02`, `R2-LOW-03`) in `Nhe_O.C_API`, `include/nhe_o.h`, and `bindings/python/nhe_o.py` | ☑ | `alr run` Suite `[11/11]` + `python3 bindings/python/nhe_o.py` (`Nhe_O.C_API` 31/31 subprograms 100% proved) |
| 11 | Align `docs/domain/storage-and-wal-format.md` & Lesson 06 byte offsets (`R2-LOW-01`) and re-verify 100% `gnatprove -j24` (`0 unproved`, `0 warnings`) + all Ada & Python test suites | ☑ | `gnatprove -P nhe_o.gpr --mode=all --level=2 -j24` (`2,863 / 2,863` checks proved, `0 unproved`, `0 warnings`) + `gprbuild -f -j24` (`0 warnings`) + `./bin/nhe_o_main` + `python3 bindings/python/nhe_o.py` |

## Notes / sequencing
- Follows the **Feature Epic → Grooming Epic** cadence codified in `AGENTS.md` and `docs/epics/README.md`.
- See [`ADVERSARIAL-REVIEW.md`](ADVERSARIAL-REVIEW.md) for both the Round 1 (24 findings, all `✅ Remediated`) and Round 2 (16 findings, all `✅ Remediated` in Tasks 7–11) audit matrices.

## Open questions
- `Q-003` and `Q-004` resolved and marked `Answered` in `docs/OPEN-QUESTIONS.md` (`ADR-006`, `ADR-007`).

