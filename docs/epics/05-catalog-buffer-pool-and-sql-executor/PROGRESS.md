# Epic 05 — Persistent System Catalog, Clock-Sweep Buffer Pool Manager & End-to-End SQL Execution Engine

**Goal:** Build upon the hardened and formally verified multi-model core from Epics 01–04 by adding a persistent Page-0 System Catalog (`Nhe_O.Catalog`, analogous to PostgreSQL's `pg_class` / `pg_attribute`), a bounded Clock-Sweep 4KB Page Buffer Pool Manager (`Nhe_O.Buffer_Pool`) enforcing the Write-Ahead Logging (`WAL-before-Data`) invariant, and an End-to-End SQL DDL/DML Executor (`Nhe_O.Executor`) wired into the C ABI (`Nhe_O.C_API`), Python SDK (`bindings/python/nhe_o.py`), and CLI (`nhe_o_main`) — all proven at 100% SPARK Silver/Gold (`pragma SPARK_Mode (On);`, `0 unproved` checks).

**Definition of done:**
1. `Nhe_O.Catalog` (`src/nhe_o-catalog.ads` and `src/nhe_o-catalog.adb`, 100% `SPARK_Mode (On)`) stores multi-table schemas (table IDs, names, column definitions with PostgreSQL types `INT8`/`TEXT`/`JSONB`/`VECTOR(d)`, B+Tree root page IDs, and HNSW vector dimension/quantization metadata) and serializes/deserializes deterministically to and from Page 0 with CRC32 verification.
2. `Nhe_O.Buffer_Pool` (`src/nhe_o-buffer_pool.ads` and `src/nhe_o-buffer_pool.adb`, 100% `SPARK_Mode (On)`) manages a statically bounded pool of 4096-byte page frames with `Pin_Count`, `Dirty`, `Usage_Count` (PostgreSQL Clock-Sweep replacement), `Page_LSN` tracking, and WAL-before-Data flush/checkpoint verification via `Nhe_O.IO`.
3. `Nhe_O.Executor` (`src/nhe_o-executor.ads` and `src/nhe_o-executor.adb`, 100% `SPARK_Mode (On)`) executes PostgreSQL DDL/DML statements end-to-end (`CREATE TABLE`, `INSERT INTO ... VALUES ... ON CONFLICT DO UPDATE`, `SELECT ... WHERE ... ORDER BY embedding <-> $1 LIMIT k`, `UPDATE`, `DELETE`) across `Nhe_O.Catalog`, `Nhe_O.Buffer_Pool`, `Nhe_O.Transaction` (MVCC + 4KB `"SLOT"` slotted pages + 4KB `"TOAS"` overflow chains), `Nhe_O.BTree`, and `Nhe_O.HNSW`.
4. `Nhe_O.C_API` (`include/nhe_o.h`, `lib/libnhe_o.so`), `bindings/python/nhe_o.py`, and `src/nhe_o_main.adb` expose live stateful SQL execution (`--sql` and Python `NheOEngine.execute_sql`) alongside a new Verification Suite `[12/12]` testing persistent catalog recovery, Clock-Sweep eviction, and end-to-end SQL execution.
5. `gnatprove -P nhe_o.gpr --mode=all --level=2` proves 100% of all flow, AoRTE (Silver), and functional contract (Gold) verification conditions (`0 unproved` checks, `0 warnings`) across all units in `src/`.

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Implement `Nhe_O.Catalog` (`src/nhe_o-catalog.ad[sb]` in 100% `SPARK_Mode (On)`) for persistent table/column/index metadata (`pg_class` / `pg_attribute`) with Page-0 CRC32 serialization | ☐ | — |
| 2 | Implement `Nhe_O.Buffer_Pool` (`src/nhe_o-buffer_pool.ad[sb]` in 100% `SPARK_Mode (On)`) with bounded frame caching, Clock-Sweep eviction, pin tracking, and WAL-before-Data flush invariants | ☐ | — |
| 3 | Implement `Nhe_O.Executor` (`src/nhe_o-executor.ad[sb]` in 100% `SPARK_Mode (On)`) connecting `Nhe_O.SQL` descriptors to `Catalog`, `Buffer_Pool`, `Transaction` (MVCC + Slotted Page + TOAST), `BTree`, and `HNSW` for `CREATE TABLE`, `INSERT`/`UPSERT`, `SELECT`, `UPDATE`, and `DELETE` | ☐ | — |
| 4 | Wire stateful SQL execution into `Nhe_O.C_API` (`include/nhe_o.h`, `lib/libnhe_o.so`), Python SDK (`bindings/python/nhe_o.py`), and CLI (`src/nhe_o_main.adb` + Suite `[12/12]`) | ☐ | — |
| 5 | Prove 100% SPARK Stone, Bronze (Flow), Silver (AoRTE), and Gold contracts across `Nhe_O.Catalog`, `Nhe_O.Buffer_Pool`, and `Nhe_O.Executor` via `gnatprove -P nhe_o.gpr` (`0 unproved` checks) | ☐ | — |

## Notes / sequencing
- Prerequisite Grooming Epic **04 (`04-post-epic-03-grooming-and-hardening`)** is complete (`16/16` tasks done; all 58 findings across Rounds 1, 2, and 3 remediated and verified at `3,776 / 3,776` SPARK checks proved). Ready to begin Task 1 of Epic 05.

## Open questions
- None (`Q-001`..`Q-004` are all answered in `docs/OPEN-QUESTIONS.md`).
