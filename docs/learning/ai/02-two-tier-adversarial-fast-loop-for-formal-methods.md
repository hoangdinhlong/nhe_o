# Two-Tier Adversarial Fast-Loop for Formally Verified Systems

> **Takeaway:** Running a heavyweight formal prover (`gnatprove --mode=all --level=2`) inside every iteration of a multi-round adversarial audit wastes 90%+ of wall-clock time re-proving code that the next audit round may immediately modify; decoupling the workflow into a **Tier-1 Fast Inner Compile-and-Test Loop** (~1.5 seconds per round until `0` issues remain) followed by a **Tier-2 Single Outer Heavy Formal Gate** achieves multi-round zero-defect convergence an order of magnitude faster without sacrificing formal assurance.

**Tags:** ai, swe
**Related ADRs:** [ADR-002](../../DECISIONS.md), [ADR-005](../../DECISIONS.md), [ADR-007](../../DECISIONS.md)

---

## 1. Context — the problem

In high-assurance software engineering (such as **Nhé O**, where all 26 source files in `src/` operate under `pragma SPARK_Mode (On);` with `4,246` formal checks), a single adversarial review pass is rarely sufficient. Tightening a parser rule in Round $r$ can expose a new edge case in a caller or a contract tautology in Round $r+1$.

However, naively coupling **multi-round adversarial review** with **full formal verification** on every round creates a severe bottleneck:
- A full `gnatprove -P nhe_o.gpr --mode=all --level=2 -j24` pass across 4,200+ VCs takes **3 to 5 minutes** of multi-core SMT solving (`cvc5`, `Z3`, `Alt-Ergo`).
- An incremental `gprbuild` compile (`-gnatwa -gnatwe`) plus all 11 runtime verification suites (`./bin/nhe_o_main`) and the Python `ctypes` FFI test suite (`python3 bindings/python/nhe_o.py`) takes **~1.5 seconds**.
- If an AI agent runs 4 adversarial rounds and invokes `gnatprove` after every round, it spends ~20 minutes waiting on SMT solvers for intermediate code states that get rewritten in the very next round.

---

## 2. The concept, explained simply

The **Two-Tier Adversarial Fast-Loop** separates **defect discovery & behavioral convergence** (Tier 1) from **exhaustive mathematical proof** (Tier 2), while keeping Tier-1 edits *proof-ready*:

```text
+-------------------------------------------------------------------------+
| TIER 1: Inner Fast-Compile Adversarial Loop (~1.5s / round)             |
|                                                                         |
|   Round r:                                                              |
|     1. Adversarial Audit across 5 Attack Surfaces                       |
|        (Specs/Tautologies · Bodies/Loops · I/O & FFI · Tests · Docs)    |
|     2. Any issues found?                                                |
|        +-- YES --> Fix with proof-ready SPARK annotations (`Loop_Variant`|
|        |           `Loop_Invariant`, modular `Post`), add regression    |
|        |           test, run `fast_loop_runner.py run-fast` (~1.5s),    |
|        |           advance to Round r + 1.                              |
|        +-- NO  --> CONVERGED (0 issues in Round N)! Exit Tier 1.        |
+------------------------------------+------------------------------------+
                                     |
                                     v
+-------------------------------------------------------------------------+
| TIER 2: Single Outer Heavy Verification Gate (Run Once After Round N)   |
|                                                                         |
|   Run `fast_loop_runner.py run-heavy` (`gnatprove --mode=all -j24`):    |
|     - 0 unproved checks & 0 warnings? --> DONE!                         |
|     - Any unproved VC? --> Fix only the proof annotation, re-run        |
|       single-unit `gnatprove -u <file> -j24`, then confirm `run-heavy`. |
+-------------------------------------------------------------------------+
```

### Why "Proof-Ready" Edits in Tier 1 Matter
Skipping `gnatprove` during Tier 1 does **not** mean writing careless code and hoping it proves later. Every Tier-1 fix must follow three discipline rules:
1. **Bounded Loops or Explicit `pragma Loop_Variant`**: Prefer `for Step in 1 .. Max_Text_Len loop` over unstructured `while` loops, or write `pragma Loop_Variant (Increases => Pos);` immediately when writing the loop.
2. **Index Bounds in `pragma Loop_Invariant`**: Maintain cursor bounds (`Pos in 1 .. Clean_Query.Length + 1`) inside every loop invariant.
3. **Non-Tautological Modular `Post` Contracts**: Never write `Post => True`; give every new helper a concise, true `Post` contract so Tier 2 does not suffer contextual inlining timeouts.

---

## 3. Concrete example — Epic 04 Fast-Loop Rounds 9–11

During Task 20 of **Epic 04 (`04-post-epic-03-grooming-and-hardening`)**, we executed the Two-Tier Adversarial Fast-Loop across the entire Nhé O repository:

1. **Fast-Loop Round 1 (Overall Round 9 — `1.63s` compile + test)**:
   - Audited all 26 `.ads`/`.adb` files and uncovered `R9-HIGH-01` (unified `CREATE TABLE` `<col_ident> <pg_type>` validation in `Count_Create_Table_Columns` and multi-tuple `INSERT VALUES (...), (...)` validation), `R9-MED-01` (removing raw-string `@>` shortcuts in `Nhe_O.JSON` so `Max_JSON_Fields = 16` completeness is always enforced), and `R9-MED-02` (eliminating all 15 literal `Post => True` contracts and subtype-range tautologies).
2. **Fast-Loop Round 2 (Overall Round 10 — `1.48s` compile + test)**:
   - Re-audited all modified units and uncovered `R10-MED-01`: tightened `Validate_Clause_Structure` to enforce `ON CONFLICT` and `RETURNING` clause ordering/uniqueness, rejected `DOUBLE PRECISION(...)` type modifiers, and added `Post` contracts to `Analyze_SQL` and `Resolve_Pg_Type`.
3. **Fast-Loop Round 3 (Overall Round 11 — `1.49s` compile + test)**:
   - Re-audited all 5 attack surfaces and found **`0` issues** (convergence).
   - **Total Tier-1 compile-and-test time across all 3 rounds: `4.6 seconds`!**
4. **Tier-2 Heavy Proof Gate (`gnatprove -P nhe_o.gpr --mode=all --level=2 -j24`)**:
   - Proved **`4,246 / 4,246` checks (`1,316` Flow + `2,930` Provers, `0 unproved`, `0 warnings`, max proof time `< 1s`)**.

---

## 4. Trade-offs & alternatives

| Workflow Strategy | Wall-Clock Time (3 Audit Rounds) | Defect & Proof Quality | Best For |
|---|---|---|---|
| **1. Single-Pass Audit + Heavy Prove** | ~4 min | Misses secondary bugs introduced by Round-1 fixes or cross-module interactions. | Trivial single-file patches. |
| **2. Heavy Prove Inside Every Audit Round** | ~15–20 min | High assurance, but wastes 80%+ of time proving intermediate code that gets refactored in Round $r+1$. | Tiny packages with `< 100` VCs. |
| **3. Two-Tier Fast-Loop + Outer Heavy Gate (Nhé O's choice)** | **~4.6s (Tier 1) + ~4 min (Tier 2)** | Identical 100% formal assurance (`4,246 / 4,246` VCs proved) with 4x–5x faster multi-round convergence. | Full-system adversarial audits on SPARK, Rust (`Kani`/`Verus`), or Lean/Coq codebases. |

---

## 5. Where it lives in the project

- **Epic Cadence Rule**: [`AGENTS.md`](../../../AGENTS.md) (*Epic cadence: Feature Epic → Grooming Epic* and *CPU parallelism for builds and formal proofs*).
- **Adversarial Review Record (Rounds 1–11)**: [`docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md).
- **11-Suite Fast Verification Harness**: [`src/nhe_o_main.adb`](../../../src/nhe_o_main.adb) and [`bindings/python/nhe_o.py`](../../../bindings/python/nhe_o.py).

---

## 6. Further reading

- [`swe/07-closing-protocol-invariant-gaps-and-modular-spark-contracts.md`](../swe/07-closing-protocol-invariant-gaps-and-modular-spark-contracts.md) — Why 100% AoRTE still requires multi-round adversarial protocol audits.
- [`swe/09-eliminating-tautological-contracts-and-contextual-inlining-in-spark.md`](../swe/09-eliminating-tautological-contracts-and-contextual-inlining-in-spark.md) — Writing proof-ready non-tautological contracts during Tier 1 so Tier 2 proves in `< 1s` per VC.

---

## 7. Check yourself

1. **Why is running `gprbuild` (`-gnatwa -gnatwe`) + runtime verification suites inside the inner loop sufficient to converge on functional and contract edge cases before invoking `gnatprove`?**
2. **What happens during the Tier-2 heavy gate if a Tier-1 edit removes `Post => True` from a loop-heavy `.adb` helper without replacing it with a concise non-tautological `Post` contract?**
3. **Why must the inner loop require a full `0-issue` convergence round ($N$) before advancing to the Tier-2 heavy verification gate?**
