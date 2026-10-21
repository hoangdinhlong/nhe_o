# Eliminating Tautological Contracts & Controlling Contextual Inlining in SPARK

> **Takeaway:** A SPARK postcondition that merely restates a return subtype's static range (`Non_Negative_Float'Result >= 0.0`) or literally states `Post => True` inflates proof counts without constraining behavior; replacing subtype-range tautologies with relational/input-dependent postconditions and attaching concise, non-tautological `Post` contracts to loop-heavy `.adb` helpers simultaneously increases contract strength (SPARK Gold) and prevents `gnatprove` from contextually inlining large loops into callers.

**Tags:** swe
**Related ADRs:** [ADR-002](../../DECISIONS.md), [ADR-003](../../DECISIONS.md), [ADR-005](../../DECISIONS.md), [ADR-006](../../DECISIONS.md), [ADR-015](../../DECISIONS.md), [ADR-016](../../DECISIONS.md)

---

## 1. Context — the problem

When scaling a formally verified codebase past 4,000 verification conditions (VCs), two subtle anti-patterns frequently emerge in `Pre`/`Post` specifications:

1. **Tautological Postconditions (Vacuous Gold Contracts)**:
   - **Subtype-Range Tautologies**: Suppose a subtype is defined as:
     ```ada
     subtype Non_Negative_Float is Float range 0.0 .. Float'Last;
     ```
     If a function returning `Non_Negative_Float` specifies `Post => L2_Distance'Result >= 0.0`, the SMT solver proves the `Post` in 0 steps—because *every* value of `Non_Negative_Float` is already `>= 0.0` by type definition! If `L2_Distance` accidentally returned a constant `42.0` even when `A = B`, that postcondition would still pass.
   - **Literal `Post => True` Placeholders**: Developers sometimes attach `with Post => True` to local helper subprograms in `.adb` files just to disable `gnatprove`'s contextual inlining. While effective as an inlining barrier, `Post => True` is a literal tautology that fails strict adversarial contract audits (`R9-MED-02`).

2. **Contextual Inlining Blowup When `Post => True` Is Removed**:
   - In SPARK, if a local subprogram in a `.adb` body has **no `Pre` or `Post` contract** (only `Global => null, Always_Terminates`), `gnatprove` treats it as an implementation helper and **contextually inlines** its body at every call site (`info: analyzing call to "..." in context`).
   - If a complex top-level procedure like `Analyze_SQL` calls loop-heavy helpers (today the lexer `Tokenize` and the token-level checkers `Check_Select`, `Check_Insert` and `Check_Create_Table`, `ADR-016`), removing their `Post` contracts makes `gnatprove` inline their 512-iteration character- and token-scanning loops directly into `Analyze_SQL`, multiplying SMT proof time.

---

## 2. The concept, explained simply

### Rule 1: Every Public `Post` Must Constrain the Output Beyond Its Static Subtype
To test whether a postcondition is tautological, ask:
> *"Does there exist at least one type-valid return value that violates this `Post` for a given input?"*

- If **No** (e.g., `Make_Ident'Result.Length <= Max_Ident_Len` when `Length` has type `Ident_Length` (`0 .. Max_Ident_Len`)), the clause is redundant with the type system.
- If **Yes** (e.g., `L2_Distance'Result = Sqrt_Bounded (L2_Distance_Squared (A, B))` or `Make_Ident'Result.Length = S'Length`), the postcondition expresses a genuine **functional relation** between inputs and outputs.

### Rule 2: Use Concise, Non-Tautological `Post` Contracts as Modular SMT Boundaries
Instead of using `Post => True` on loop-heavy `.adb` helpers—or leaving them without a `Post` and suffering contextual inlining—give each helper a **true, one-line structural postcondition** that summarizes what the caller actually needs:
- `gnatprove` verifies the helper's loop once in isolation.
- At every call site in `Analyze_SQL`, `gnatprove` replaces the 100-line loop body with the one-line `Post` axiom!

---

## 3. Concrete examples from Nhé O

### Example A: Upgrading Subtype-Range Tautologies in `Nhe_O.Vector` and `Nhe_O.Types`

In [`src/nhe_o-vector.ads`](../../../src/nhe_o-vector.ads), `L2_Distance_Squared`, `Sqrt_Bounded`, and `L2_Distance` return `Non_Negative_Float`. During Fast-Loop Round 9 (`R9-MED-02`), we replaced their vacuous `>= 0.0` postconditions with upper-bound, bracketing and composition laws:

```ada
function L2_Distance_Squared
  (A, B : Vector_Value) return Non_Negative_Float
  with Global => null,
       Pre    => A.Dim = B.Dim,
       Post   => L2_Distance_Squared'Result <= Float (A.Dim) * 4.0e12;

function Sqrt_Bounded (X : Non_Negative_Float) return Non_Negative_Float
  with Global => null,
       Post   => (if X = 0.0 then Sqrt_Bounded'Result = 0.0
                  elsif X >= 1.0 then Sqrt_Bounded'Result in 1.0 .. X
                  else Sqrt_Bounded'Result in X .. 1.0);

function L2_Distance
  (A, B : Vector_Value) return Non_Negative_Float
  with Global => null,
       Pre    => A.Dim = B.Dim,
       Post   => L2_Distance'Result = Sqrt_Bounded (L2_Distance_Squared (A, B))
                 and then L2_Distance'Result <= Float (A.Dim) * 4.0e12;
```

In the same round, [`src/nhe_o-types.ads`](../../../src/nhe_o-types.ads) strengthened `Make_Ident` and `Make_Text` from a length-only law (`Length = S'Length`) to exact length plus character-by-character preservation:

```ada
function Make_Ident (S : String) return Bounded_Ident
  with Global => null,
       Pre    => S'Length <= Max_Ident_Len,
       Post   => Make_Ident'Result.Length = S'Length
                 and then (for all I in 1 .. S'Length =>
                             Make_Ident'Result.Data (I) = S (S'First + (I - 1)));
```

### Example B: Catching a Subtle Bug via Non-Tautological Helper Contracts (Canonical JSON Numbers)

In Round 9 (`R9-MED-01`, `R9-MED-02`), the JSON number normalizer of that time in [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb) carried only a tautological `Post` (a length bound its result type already implied). Replacing it with a real canonical-zero invariant (a zero result is never negative and carries no exponent) immediately caught a latent edge case in `gnatprove`: when the number was a bare `"-"`, `Is_Neg` was set to `True` before the guard that returns when the sign is the last character, returning `Is_Zero = True` AND `Is_Neg = True`! Moving `Is_Neg := True;` after the guard satisfied the postcondition and made canonical zero normalization airtight.

Round 12 replaced that normalizer with `Canonical_Number`, which compares numbers exactly through a canonical form (`ADR-015`). Its sign guard still precedes `Neg := True`, and its contract keeps the canonical-zero law:

```ada
function Canonical_Number (T : Bounded_Text; P : Positive) return Number_Form
  with Global => null,
       Pre    => P <= T.Length,
       Post   => (if Canonical_Number'Result.In_Range then
                    (T.Data (P) = '-' or else T.Data (P) in '0' .. '9')
                    and then
                    (if Canonical_Number'Result.Is_Zero then
                       Canonical_Number'Result.Sig_Count = 0
                       and then not Canonical_Number'Result.Is_Neg
                     else
                       Canonical_Number'Result.Sig_Count > 0
                       and then Canonical_Number'Result.Sig_First in P .. T.Length
                       and then Canonical_Number'Result.E_Msd
                                  in -PG_Max_Dscale .. PG_Max_Msd_Exp));
```

### Example C: Modularizing `Analyze_SQL` Without `Post => True`

In [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb), `Nhe_O.SQL` is a PostgreSQL-faithful lexer (`Tokenize`) plus a token-level validator (`ADR-016`; before 0.4 the same role was played by substring-scanning helpers). Concise, non-tautological `Post` contracts on its internal helpers prevent `gnatprove` from inlining their loops into `Analyze_SQL`:

```ada
procedure Tokenize
  (Query : in     Bounded_Text;
   Toks  :    out Token_List;
   Valid :    out Boolean)
  with Global => null,
       Always_Terminates,
       Post   => Toks.Count <= Query.Length;

procedure Parse_Limit_Part
  (T    : in     Token_List;
   I    : in     Positive;
   L    : in     Natural;
   Info : in out Query_Info;
   Next :    out Natural)
  with Global => null,
       Always_Terminates,
       Pre    => L <= T.Count and then I <= L and then Limit_Info_OK (Info),
       Post   => Limit_Info_OK (Info)
                 and then Info.Column_Count = Info.Column_Count'Old
                 and then (Next = 0 or else Next in I + 2 .. L + 1);

procedure Check_Create_Table
  (Q       : in     Bounded_Text;
   T       : in     Token_List;
   L       : in     Natural;
   Name    :    out Bounded_Ident;
   Columns :    out Natural;
   OK      :    out Boolean)
  with Global => null,
       Always_Terminates,
       Pre    => L <= T.Count,
       Post   => (if OK then Name.Length > 0 and then Columns > 0);
```

`Limit_Info_OK` is exactly the row-limit consistency that `Analyze_SQL` promises in its own `Post`; `Check_Select`, `Check_Query` and `Check_Insert` export it too, so `Analyze_SQL` proves that part of its contract from the helpers' summaries instead of re-analyzing every token loop.

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to use |
|---|---|---|---|
| **1. No `Post` on `.adb` helpers** | Zero annotation effort on private helpers. | `gnatprove` contextually inlines the helper at every call site; nested or sequential loops cause massive VC timeouts. | Tiny 1–5 line expression-like helpers (`Is_WS_Char`, `To_Lower_Char`). |
| **2. Literal `Post => True` on `.adb` helpers** | Stops contextual inlining immediately. | Vacuous contract; hides helper bugs (as a vacuous `Post` hid the Round 9 number normalizer's bug on `"-"`) and fails anti-tautology audits. | Never in production SPARK Gold codebases. |
| **3. Concise Non-Tautological `Post` Contracts (Nhé O's choice)** | Stops contextual inlining, proves each loop modularly, and catches real edge-case bugs in helpers. | Requires identifying at least one meaningful output property per helper. | All loop-heavy procedures and functions in `SPARK_Mode (On)`. |

---

## 5. Where it lives in the project

- **Vector & Type Contracts**: [`src/nhe_o-vector.ads`](../../../src/nhe_o-vector.ads), [`src/nhe_o-types.ads`](../../../src/nhe_o-types.ads).
- **JSONB Parser & Canonical Number Normalization Contracts**: [`src/nhe_o-json.ads`](../../../src/nhe_o-json.ads), [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb).
- **Modular SQL Lexer & Token-Level Validator Contracts**: [`src/nhe_o-sql.ads`](../../../src/nhe_o-sql.ads), [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb).
- **Adversarial Audit Record (`R9-MED-02`, `R10-MED-01`)**: [`docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md).

---

## 6. Further reading

- SPARK User's Guide — *Contextual Analysis of Subprograms Without Contracts* (`info-unrolling-inlining`).
- John Barnes — *SPARK: The Proven Approach to High Integrity Software* (Modular Verification vs. Inlining).

---

## 7. Check yourself

1. **Why is `Post => Sqrt_Bounded'Result >= 0.0` tautological when `Sqrt_Bounded` returns `Non_Negative_Float`, and how does `Post => (if X = 0.0 then Sqrt_Bounded'Result = 0.0 elsif X >= 1.0 then Sqrt_Bounded'Result in 1.0 .. X else Sqrt_Bounded'Result in X .. 1.0)` fix it?**
2. **What does `gnatprove`'s diagnostic `info: local subprogram "..." only analyzed in the context of calls` mean for SMT solver performance when that subprogram contains a 512-iteration loop?**
3. **How did replacing the tautological `Post` of the Round 9 number normalizer with a canonical-zero law (a zero is never negative) expose a bug on the input string `"-"`, and which clause of `Canonical_Number`'s `Post` carries that law today?**
