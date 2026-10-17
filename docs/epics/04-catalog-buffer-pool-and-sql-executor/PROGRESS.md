# Epic 04 — Persistent System Catalog, Clock-Sweep Buffer Pool Manager & End-to-End SQL Execution Engine

**Goal:** Transform `Nhe_O` from a collection of formally verified database subsystems into a unified, disk-backed SQL execution engine by adding a persistent Page-0 System Catalog (`Nhe_O.Catalog`, analogous to PostgreSQL's `pg_class` / `pg_attribute`), a bounded Clock-Sweep 4KB Page Buffer Pool Manager (`Nhe_O.Buffer_Pool`) enforcing the Write-Ahead Logging (`WAL-before-Data`) invariant, and an End-to-End SQL DDL/DML Executor (`Nhe_O.Executor`) wired into the C ABI (`Nhe_O.C_API`), Python SDK (`bindings/python/nhe_o.py`), and CLI (`nhe_o_main`) — all proven at 100% SPARK Silver/Gold (`pragma SPARK_Mode (On);`, `0 unproved` checks).

**Definition of done:**
1. `Nhe_O.Catalog` (`src/nhe_o-catalog.ads` and `src/nhe_o-catalog.adb`, 100% `SPARK_Mode (On)`) stores multi-table schemas (table IDs, names, column definitions with PostgreSQL types `INT8`/`TEXT`/`JSONB`/`VECTOR(d)`, B+Tree root page IDs, and HNSW vector dimension/quantization metadata) and serializes/deserializes deterministically to and from Page 0 with CRC32 verification.
2. `Nhe_O.Buffer_Pool` (`src/nhe_o-buffer_pool.ads` and `src/nhe_o-buffer_pool.adb`, 100% `SPARK_Mode (On)`) manages a statically bounded pool of 4096-byte page frames with `Pin_Count`, `Dirty`, `Usage_Count` (PostgreSQL Clock-Sweep replacement), `Page_LSN` tracking, and WAL-before-Data flush/checkpoint verification via `Nhe_O.IO`.
3. `Nhe_O.Executor` (`src/nhe_o-executor.ads` and `src/nhe_o-executor.adb`, 100% `SPARK_Mode (On)`) executes PostgreSQL DDL/DML statements end-to-end (`CREATE TABLE`, `INSERT INTO ... VALUES ... ON CONFLICT DO UPDATE`, `SELECT ... WHERE ... ORDER BY embedding <-> $1 LIMIT k`, `UPDATE`, `DELETE`) across `Nhe_O.Catalog`, `Nhe_O.Buffer_Pool`, `Nhe_O.Transaction` (MVCC + 4KB TOAST overflow), `Nhe_O.BTree`, and `Nhe_O.HNSW`.
4. `Nhe_O.C_API` (`include/nhe_o.h`, `lib/libnhe_o.so`), `bindings/python/nhe_o.py`, and `src/nhe_o_main.adb` expose live stateful SQL execution (`--sql` and Python `Engine.execute_sql`) alongside a new Verification Suite `[12/12]` testing persistent catalog recovery, Clock-Sweep eviction, and end-to-end SQL execution.
5. `gnatprove -P nhe_o.gpr --mode=all --level=2` proves 100% of all flow, AoRTE (Silver), and functional contract (Gold) verification conditions (`0 unproved` checks, `0 warnings`) across all units in `src/`.

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 0 | Remediate Epics 01–03 adversarial review findings (`ADVERSARIAL-REVIEW.md`: `CRIT-02`..`CRIT-07`, `HIGH-01`..`HIGH-02`, `HIGH-05`..`HIGH-09`, `MED-01`..`MED-05`, `LOW-01`..`LOW-03`) across `BTree`, `HNSW`, `Vector`, `Transaction` (CLOG + WAL commit flag), `PubSub`, `KV`, `RAG`, and `C_API` | ☐ | — |
| 1 | Implement `Nhe_O.Catalog` (`src/nhe_o-catalog.ad[sb]` in 100% `SPARK_Mode (On)`) for persistent table/column/index metadata (`pg_class` / `pg_attribute`) with Page-0 CRC32 serialization | ☐ | — |
| 2 | Implement `Nhe_O.Buffer_Pool` (`src/nhe_o-buffer_pool.ad[sb]` in 100% `SPARK_Mode (On)`) with primary 4KB slotted-page encoding (`CRIT-01`), bounded frame caching, Clock-Sweep eviction, pin tracking, and WAL-before-Data flush invariants | ☐ | — |
| 3 | Expand `Nhe_O.SQL` & `Nhe_O.JSON` (`HIGH-03`, `HIGH-04`) and implement `Nhe_O.Executor` (`src/nhe_o-executor.ad[sb]` in 100% `SPARK_Mode (On)`) connecting SQL ASTs to `Catalog`, `Buffer_Pool`, `Transaction` (MVCC + TOAST), `BTree`, and `HNSW` for `CREATE TABLE`, `INSERT`/`UPSERT`, `SELECT`, `UPDATE`, and `DELETE` | ☐ | — |
| 4 | Wire stateful SQL execution and safe bounded C/Python buffer outputs (`HIGH-01`, `HIGH-02`) into `Nhe_O.C_API` (`include/nhe_o.h`, `lib/libnhe_o.so`), Python SDK (`bindings/python/nhe_o.py`), and CLI (`src/nhe_o_main.adb` + Suite `[12/12]`) | ☐ | — |
| 5 | Prove 100% SPARK Stone, Bronze (Flow), Silver (AoRTE), and Gold contracts across `Nhe_O.Catalog`, `Nhe_O.Buffer_Pool`, `Nhe_O.Executor`, and all hardened units via `gnatprove -P nhe_o.gpr` (`0 unproved` checks) | ☐ | — |

## Notes / sequencing
- See [`ADVERSARIAL-REVIEW.md`](ADVERSARIAL-REVIEW.md) for the complete catalog of 24 verified findings (`7 Critical, 9 High, 5 Medium, 3 Low`) discovered during the post-Epic-03 adversarial audit.
- Task 0 hardens existing `BTree`, `HNSW`, `Vector`, `Transaction` (CLOG + WAL commit marker), `PubSub`, `RAG`, and `C_API` subsystems before layering `Nhe_O.Catalog` (Task 1), `Nhe_O.Buffer_Pool` (Task 2), and `Nhe_O.Executor` (Task 3).

## Open questions
- Promoted to `docs/OPEN-QUESTIONS.md` (`Q-003` and `Q-004`).

