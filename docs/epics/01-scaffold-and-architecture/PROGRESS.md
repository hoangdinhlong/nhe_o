# Epic 01 — Scaffold and Architecture

**Goal:** Establish the foundational architecture, Monion `project-docs` R8 documentation framework, and **100% formal SPARK specifications and bodies (`pragma SPARK_Mode (On);`)** across all database subsystems (PostgreSQL types/SQL, Vector search, JSON/JSONB, ACID MVCC/WAL transactions, Redis KV cache, Pub/Sub, and contract-bound POSIX syscall I/O in `Nhe_O.IO`).

**Definition of done:** All documentation artifacts complete and passing `SELF-AUDIT.md`, all 18 `.ads`/`.adb` files in `src/` (including `nhe_o-io.adb` and `nhe_o_main.adb`) implemented in `SPARK_Mode => On` with formal contracts (`Pre`/`Post`) and zero occurrences of `SPARK_Mode => Off`, project compiling cleanly with zero warnings under `gnatmake -gnat2022 -gnatwa -gnata`, end-to-end verification executable passing all assertions, and repository published as a private GitHub repository (`hoangdinhlong/nhe_o`).

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
| 10 | Implement contract-bound POSIX syscall I/O (`nhe_o-io.ads` and `nhe_o-io.adb` both in `SPARK_Mode => On`) and `nhe_o.gpr` | ☑ | Compiled & `.nhe_o`/`.wal` POSIX `pread`/`pwrite`/`fsync` verified |
| 11 | Initialize Git repository, standardize Ada/Alire naming (`nhe_o` / `Nhe_O`), and push to private GitHub repo (`hoangdinhlong/nhe_o`) | ☑ | `git push` & `gh repo view` verified |

## Notes / sequencing
- Per `BR-001` and `ADR-002`, 100% of `.ads` and `.adb` files in `src/` (all 18 files, including `src/nhe_o-io.adb` and `src/nhe_o_main.adb`) must maintain `pragma SPARK_Mode (On);`.
- Zero files in `src/` may use `pragma SPARK_Mode (Off);`.

## Open questions
- Strategic architectural questions tracked in `docs/OPEN-QUESTIONS.md` (`Q-001`, `Q-002`).
