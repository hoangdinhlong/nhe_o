# Epic 02 — B+Tree Storage, TOAST Overflow, 4096-D Quantized HNSW & Universal RAG Executor

**Goal:** Deliver multi-page B+Tree indexing, PostgreSQL-style 4KB TOAST overflow page chains (`ADR-003` / `BR-006`), 4096-dimensional Vector support with `Int8`/Binary quantization and bounded HNSW graph indexing (`ADR-003` / `BR-003`), dual-mode In-Memory + Durable WAL Pub/Sub (`ADR-004` / `BR-005`), and a unified SQL/RAG execution engine supporting Dense, Hybrid (Vector + JSONB/BM25), Parent-Document, and Graph/Agentic RAG for local LLMs (e.g., Qwen 3.8 27B / 35B-A3B) — all in 100% `pragma SPARK_Mode (On);`.

**Definition of done:** All new and updated `.ads`/`.adb` modules in `src/` compile with zero warnings under `gnatmake -gnat2022 -gnatwa -gnata` in 100% `SPARK_Mode (On)` (zero `SPARK_Mode (Off)`), support up to 4096-D vectors (`Float32`, `Int8`, `Binary`) via 4KB TOAST overflow pages, provide bounded HNSW ANN search, execute hybrid SQL+JSONB+Vector RAG queries, support `DURABLE` WAL-committed `LISTEN`/`NOTIFY` dispatch, and pass all runtime contract assertions in `nhe_o_main`.

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Implement 4KB TOAST overflow page chains (`Overflow_Page_Id`, 16-byte inline TOAST pointer, and multi-page WAL redo pass) in `Nhe_O.Transaction` (`ADR-003`, `BR-006`) | ☑ | Suite `[5/11]` (`Write_TOAST_Chain`, `Read_TOAST_Chain`, `Redo_WAL_Recovery` verified) |
| 2 | Expand `Nhe_O.Vector` to `Max_Vector_Dim = 4096` and implement Scalar (`Int8`) & Binary (`1-bit` Hamming) quantization alongside `Float32` (`ADR-003`, `BR-003`) | ☑ | Suite `[2/11]` (4096-D `Float32`, `Int8` SQ8, and `Binary` Hamming verified) |
| 3 | Implement multi-page B+Tree relational/primary-key index with deterministic node splitting in `SPARK_Mode (On)` | ☑ | Suite `[6/11]` (`Nhe_O.BTree` leaf/root splits, `Search_Key`, `Range_Scan`, page encode/decode verified) |
| 4 | Implement bounded HNSW navigable small-world graph index for sub-linear ANN search over `Float32`, `Int8`, and `Binary` vectors | ☑ | Suite `[7/11]` (`Nhe_O.HNSW` multi-layer ANN search across all 3 encodings verified) |
| 5 | Implement Dual-Mode Pub/Sub (`ADR-004`, `BR-005`): add transactional `Durable` notification staging and post-WAL-commit dispatch (`LISTEN`/`NOTIFY`) | ☑ | Suite `[9/11]` (`Stage_Notify`, rollback discard, and post-WAL `Flush_Committed_Notifications` verified) |
| 6 | Implement Universal RAG & Hybrid SQL Query Executor joining B+Tree scan, JSONB metadata filter (`@>`), TOAST parent-chunk retrieval, and HNSW Vector top-K search | ☑ | Suite `[10/11]` (`Nhe_O.RAG` Hybrid SQL + `JSONB` + Keyword + HNSW + TOAST + GraphRAG verified) |

## Notes / sequencing
- Task 1 (4KB TOAST overflow pages) and Task 2 (4096-D & quantized vectors) go first as the storage foundation for Tasks 4 and 6.
- Per `BR-001` and `ADR-002`, 100% of `.ads` and `.adb` files in `src/` must maintain `pragma SPARK_Mode (On);` with zero occurrences of `SPARK_Mode (Off);`.

## Open questions
- None (`Q-001` and `Q-002` resolved via `ADR-003` and `ADR-004`).
