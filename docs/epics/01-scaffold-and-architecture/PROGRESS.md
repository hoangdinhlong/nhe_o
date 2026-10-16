# Epic 01 — Scaffold and Architecture

**Goal:** Establish the foundational architecture, Monion `project-docs` R8 documentation framework, formal SPARK specifications and bodies (`SPARK_Mode => On`) for all database subsystems (PostgreSQL types/SQL, Vector search, JSON/JSONB, ACID MVCC/WAL transactions, Redis KV cache, and Pub/Sub), and the strictly isolated Ada I/O boundary (`Nheo.IO`).

**Definition of done:** All documentation artifacts complete and passing `SELF-AUDIT.md`, all core packages and `nheo_main.adb` implemented in `SPARK_Mode => On` with formal contracts (`Pre`/`Post`), `SPARK_Mode => Off` strictly confined to `src/nheo-io.adb`, project compiling cleanly with zero warnings under `gnatmake -gnat2022 -gnatwa -gnata`, end-to-end verification executable passing all assertions, and repository published as a private GitHub repository (`hoangdinhlong/NheO`).

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Adopt Monion `project-docs` R8 template and replace all placeholders | ☑ | `SELF-AUDIT.md` A1–A3, B7 passed |
| 2 | Author `VISION.md`, `ARCHITECTURE.md`, `DECISIONS.md` (`ADR-001`..`ADR-003`), and `business-rules.md` (`BR-001`..`BR-005`) | ☑ | Manual review & `SELF-AUDIT.md` |
| 3 | Implement PostgreSQL type system in SPARK (`Nheo.Types`) | ☑ | Compiled (`-gnat2022 -gnatwa -gnata`) & runtime verified |
| 4 | Implement Vector similarity engine (`<->`, `<=>`, `<#>`) in SPARK (`Nheo.Vector`) | ☑ | Compiled & contract assertions verified |
| 5 | Implement PostgreSQL JSON/JSONB validator and operators (`->`, `->>`, `@>`, `?`) in SPARK (`Nheo.JSON`) | ☑ | Compiled & contract assertions verified |
| 6 | Implement ACID MVCC Snapshot Isolation & CRC32 WAL/Page framing in SPARK (`Nheo.Transaction`) | ☑ | Compiled & WAL disk persistence verified |
| 7 | Implement Redis-compatible Key-Value Cache with TTL & LRU eviction in SPARK (`Nheo.KV`) | ☑ | Compiled & TTL/LRU assertions verified |
| 8 | Implement deterministic Ring-Buffer Pub/Sub broker in SPARK (`Nheo.PubSub`) | ☑ | Compiled & channel/pattern assertions verified |
| 9 | Implement PostgreSQL SQL dialect tokenizer, parser, and statement classifier in SPARK (`Nheo.SQL`) | ☑ | Compiled & SQL statement assertions verified |
| 10 | Implement isolated physical I/O boundary (`nheo-io.ads` in SPARK, `nheo-io.adb` in Ada) and `nheo.gpr` | ☑ | Compiled & `.nheo`/`.wal` disk I/O verified |
| 11 | Initialize Git repository and push to private GitHub repo (`hoangdinhlong/NheO`) | ☑ | `git push` & `gh repo view` verified |

## Notes / sequencing
- Per `BR-001` and `ADR-002`, every single logic package `.ads` and `.adb` (plus `src/nheo_main.adb`) must maintain `pragma SPARK_Mode (On);`.
- Only `src/nheo-io.adb` may use `pragma SPARK_Mode (Off);`.

## Open questions
- Strategic architectural questions tracked in `docs/OPEN-QUESTIONS.md` (`Q-001`, `Q-002`).
