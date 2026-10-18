# Learning

A teaching corpus that explains the **concepts behind this project's decisions**, in plain language
with concrete examples. Lessons make knowledge durable: easy to re-learn after time away, useful for
interview prep, and friendly to anyone who clones the project to learn by doing.

## How this relates to the other docs

| Doc | Role | Voice |
|-----|------|-------|
| `../DECISIONS.md` (ADR) | **Records** a decision — what & why (terse, authoritative) | concise |
| `../reference/*` | The current map & destination | reference |
| **`learning/`** | **Teaches** the concept behind a decision | beginner-friendly, examples |

> **Rule:** the ADR is the source of truth for a *decision*; a lesson teaches the *concept*. Lessons
> link to ADRs; ADRs may link to lessons. If they disagree, the **ADR wins** — lessons are
> educational, not specification.

## Structure

- `swe/` — software engineering lessons.
- `ai/` — AI lessons.
- Cross-cutting (e.g. AI × SWE) topics live in whichever bucket dominates, with a `Tags:` line and a
  cross-link — no third folder, to keep the tree simple.
- `_TEMPLATE.md` — copy this to start a new lesson.

## Index

### swe/
- [`01-contract-bound-posix-syscalls-in-spark.md`](swe/01-contract-bound-posix-syscalls-in-spark.md) — Contract-Bound POSIX Syscalls in `SPARK_Mode (On)`: bypassing exception-raising Ada file streams to achieve 100% SPARK verification across disk page and WAL I/O (`ADR-002`).
- [`02-transactional-pubsub-wal-commit-barrier.md`](swe/02-transactional-pubsub-wal-commit-barrier.md) — Dual-Mode Pub/Sub & The WAL Commit Barrier: combining Redis immediate in-memory streaming with PostgreSQL `LISTEN`/`NOTIFY` WAL-committed dispatch to prevent premature MVCC reads and phantom RAG indexing (`ADR-004`).
- [`03-precondition-free-defensive-c-ffi-in-spark.md`](swe/03-precondition-free-defensive-c-ffi-in-spark.md) — Precondition-Free Defensive C ABI / FFI Boundaries in 100% SPARK: replacing raw C pointers (`chars_ptr`) with bounded `char_array` buffers and internal defensive validation so `gnatprove` proves 100% AoRTE across untrusted C/Python callers (`ADR-005`).
- [`04-proving-ieee754-float-and-loop-invariants-in-spark.md`](swe/04-proving-ieee754-float-and-loop-invariants-in-spark.md) — Proving IEEE-754 Floating-Point Arithmetic and Inductive Loop Invariants in SPARK: bounding `Float32` dot products (`<= 10^15`), proving `Sqrt` Newton-Raphson convergence without overflow/NaN, clamping accumulators to avoid IEEE-754 distributivity timeouts, and preventing nested loop unrolling without `-gnatwa`/`-gnatwc` warnings (`ADR-003`, `ADR-005`, `ADR-006`).
- [`05-two-pass-wal-recovery-and-slotted-page-crc32-in-spark.md`](swe/05-two-pass-wal-recovery-and-slotted-page-crc32-in-spark.md) — Two-Pass Committed-Only WAL Recovery, CLOG MVCC & 4KB Slotted-Page CRC32 in SPARK: preventing dirty/aborted WAL replay and proving self-referential page checksums (`ADR-006`, `ADR-007`).
- [`06-two-stage-toast-vector-reranking-and-hnsw-pruning.md`](swe/06-two-stage-toast-vector-reranking-and-hnsw-pruning.md) — Two-Stage 4096-D Vector TOAST Re-Ranking, Scale-Aware SQ8 & Distance-Pruned HNSW in SPARK: combining compact HNSW RAM Stage-1 candidate generation with on-disk `"VTST"` TOAST Stage-2 exact 4096-D re-ranking (`ADR-003`, `ADR-006`).


### ai/
- [`01-toast-overflow-and-vector-quantization-for-local-llm-rag.md`](ai/01-toast-overflow-and-vector-quantization-for-local-llm-rag.md) — 4KB TOAST Overflow Pages & Vector Quantization (`Float32` / `Int8` / `Binary`) for Universal Local LLM RAG: scaling up to 4096-D embeddings and parent-document chunks while saving 4x–32x HNSW RAM alongside local LLMs (`ADR-003`).
- *(Cross-cutting AI × SWE)* [`swe/06-two-stage-toast-vector-reranking-and-hnsw-pruning.md`](swe/06-two-stage-toast-vector-reranking-and-hnsw-pruning.md) — Two-Stage 4096-D Vector TOAST Re-Ranking, Scale-Aware SQ8 & Distance-Pruned HNSW (`ADR-006`).


## Writing a lesson

Copy `_TEMPLATE.md`, emphasize *meaning* (understanding *why*, not just *what*), prefer examples
from this project, and end with a few self-check questions (interview-style).
