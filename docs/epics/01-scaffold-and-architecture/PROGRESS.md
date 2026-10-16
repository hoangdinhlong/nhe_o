# Epic 01 — Scaffold and Architecture

**Goal:** Establish the foundational architecture, Monion `project-docs` R8 documentation framework, formal SPARK specifications and bodies (`SPARK_Mode => On`) for all database subsystems (PostgreSQL types/SQL, Vector search, JSON/JSONB, ACID MVCC/WAL transactions, Redis KV cache, and Pub/Sub), and the strictly isolated Ada I/O boundary (`Nhe_O.IO`).

**Definition of done:** All documentation artifacts complete and passing `SELF-AUDIT.md`, all core packages and `nhe_o_main.adb` implemented in `SPARK_Mode => On` with formal contracts (`Pre`/`Post`), `SPARK_Mode => Off` strictly confined to `src/nhe_o-io.adb`, project compiling cleanly with zero warnings under `gnatmake -gnat2022 -gnatwa -gnata`, end-to-end verification executable passing all assertions, and repository published as a private GitHub repository (`hoangdinhlong/nhe_o`).

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Adopt Monion `project-docs` R8 template and replace all placeholders | ☑ | `SELF-AUDIT.md` A1–A3, B7 passed |
| 2 | Author `VISION.md`, `ARCHITECTURE.md`, `DECISIONS.md` (`ADR-001`..`ADR-004`), and `business-rules.md` (`BR-001`..`BR-005`) | ☑ | Manual review & `SELF-AUDIT.md` |
| 3 | Implement PostgreSQL type system in SPARK (`Nhe_O.Types`) | ☑ | Compiled (`-gnat2022 -gnatwa -gnata`) & runtime verified |
| 4 | Implement Vector similarity engine (`<->`, `<=>`, `<#>`) in SPARK (`Nhe_O.Vector`) | ☑ | Compiled & contract assertions verified |
| 5 | Implement PostgreSQL JSON/JSONB validator and operators (`->`, `->>`, `@>`, `?`) in SPARK (`Nhe_O.JSON`) | ☑ | Compiled & contract assertions verified |
| 6 | Implement ACID MVCC Snapshot Isolation & CRC32 WAL/Page framing in SPARK (`Nhe_O.Transaction`) | ☑ | Compiled & WAL disk persistence verified |
| 7 | Implement Redis-compatible Key-Value Cache with TTL & LRU eviction in SPARK (`Nhe_O.KV`) | ☑ | Compiled & TTL/LRU assertions verified |
| 8 | Implement deterministic Ring-Buffer Pub/Sub broker in SPARK (`Nhe_O.PubSub`) | ☑ | Compiled & channel/pattern assertions verified |
| 9 | Implement PostgreSQL SQL dialect tokenizer, parser, and statement classifier in SPARK (`Nhe_O.SQL`) | ☑ | Compiled & SQL statement assertions verified |
| 10 | Implement isolated physical I/O boundary (`nhe_o-io.ads` in SPARK, `nhe_o-io.adb` in Ada) and `nhe_o.gpr` | ☑ | Compiled & `.nhe_o`/`.wal` disk I/O verified |
| 11 | Initialize Git repository, standardize Ada/Alire naming (`nhe_o` / `Nhe_O`), and push to private GitHub repo (`hoangdinhlong/nhe_o`) | ☑ | `git push` & `gh repo view` verified |

## Notes / sequencing
- Per `BR-001` and `ADR-002`, every single logic package `.ads` and `.adb` (plus `src/nhe_o_main.adb`) must maintain `pragma SPARK_Mode (On);`.
- Only `src/nhe_o-io.adb` may use `pragma SPARK_Mode (Off);`.

## Open questions
- Strategic architectural questions tracked in `docs/OPEN-QUESTIONS.md` (`Q-001`, `Q-002`).
