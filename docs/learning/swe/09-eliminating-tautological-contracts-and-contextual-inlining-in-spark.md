# Eliminating Tautological Contracts & Controlling Contextual Inlining in SPARK

> **Takeaway:** A SPARK postcondition that merely restates a return subtype's static range (`Non_Negative_Float'Result >= 0.0`) or literally states `Post => True` inflates proof counts without constraining behavior; replacing subtype-range tautologies with relational/input-dependent postconditions and attaching concise, non-tautological `Post` contracts to loop-heavy `.adb` helpers simultaneously increases contract strength (SPARK Gold) and prevents `gnatprove` from contextually inlining large loops into callers.

**Tags:** swe
**Related ADRs:** [ADR-002](../../DECISIONS.md), [ADR-003](../../DECISIONS.md), [ADR-005](../../DECISIONS.md), [ADR-006](../../DECISIONS.md)

---

## 1. Context — the problem

When scaling a formally verified codebase past 4,000 verification conditions (VCs), two subtle anti-patterns frequently emerge in `Pre`/`Post` specifications:

1. **Tautological Postconditions (Vacuous Gold Contracts)**:
   - **Subtype-Range Tautologies**: Suppose a subtype is defined as:
     ```ada
     subtype Non_Negative_Float is Float range 0.0 .. Float'Last;
     ```
     If a function returning `Non_Negative_Float` specifies `Post => L2_Distance'Result >= 0.0`, the SMT solver proves the `Post` in 0 steps—because *every* value of `Non_Negative_Float` is already `>= 0.0` by type definition! If `L2_Distance` accidentally returned a constant `42.0` even when `Left = Right`, that postcondition would still pass.
   - **Literal `Post => True` Placeholders**: Developers sometimes attach `with Post => True` to local helper subprograms in `.adb` files just to disable `gnatprove`'s contextual inlining. While effective as an inlining barrier, `Post => True` is a literal tautology that fails strict adversarial contract audits (`R9-MED-02`).

2. **Contextual Inlining Blowup When `Post => True` Is Removed**:
   - In SPARK, if a local subprogram in a `.adb` body has **no `Pre` or `Post` contract** (only `Global => null, Always_Terminates`), `gnatprove` treats it as an implementation helper and **contextually inlines** its body at every call site (`info: analyzing call to "..." in context`).
   - If a complex top-level procedure like `Analyze_SQL` calls four loop-heavy helpers (`Sanitize_SQL`, `Parse_Limit_Clause`, `Count_Select_Columns`, `Count_Create_Table_Columns`), removing their `Post` contracts causes `gnatprove` to inline all four 512-iteration string-scanning loops directly into `Analyze_SQL`, multiplying SMT proof time by 10x–30x.

---

## 2. The concept, explained simply

### Rule 1: Every Public `Post` Must Constrain the Output Beyond Its Static Subtype
To test whether a postcondition is tautological, ask:
> *"Does there exist at least one type-valid return value that violates this `Post` for a given input?"*

- If **No** (e.g., `Result <= Max_Ident_Len` when `Result` has type `Ident_Len_Range is 0 .. Max_Ident_Len`), the clause is redundant with the type system.
- If **Yes** (e.g., `(if A = B then L2_Distance'Result = 0.0)` or `Make_Ident'Result.Length = Natural'Min (Source'Length, Max_Ident_Len)`), the postcondition expresses a genuine **functional relation** between inputs and outputs.

### Rule 2: Use Concise, Non-Tautological `Post` Contracts as Modular SMT Boundaries
Instead of using `Post => True` on loop-heavy `.adb` helpers—or leaving them without a `Post` and suffering contextual inlining—give each helper a **true, one-line structural postcondition** that summarizes what the caller actually needs:
- `gnatprove` verifies the helper's loop once in isolation.
- At every call site in `Analyze_SQL`, `gnatprove` replaces the 100-line loop body with the one-line `Post` axiom!

---

## 3. Concrete examples from Nhé O

### Example A: Upgrading Subtype-Range Tautologies in `Nhe_O.Vector` and `Nhe_O.Types`

In [`src/nhe_o-vector.ads`](../../../src/nhe_o-vector.ads), `L2_Distance_Squared`, `Sqrt_Bounded`, and `L2_Distance` return `Non_Negative_Float`. During Fast-Loop Round 9 (`R9-MED-02`), we replaced their vacuous `>= 0.0` postconditions with zero-identity and upper-bound laws:

```ada
function L2_Distance_Squared
  (Left  : Vector_Value;
   Right : Vector_Value) return Non_Negative_Float
with
  Global => null,
  Pre    => Left.Dim = Right.Dim,
  Post   => L2_Distance_Squared'Result <=
              Float (Max_Vector_Dim) * 4.0 * Max_Component * Max_Component
            and then (if Left.Data = Right.Data
                      then L2_Distance_Squared'Result = 0.0);

function Sqrt_Bounded (X : Non_Negative_Float) return Non_Negative_Float with
  Global => null,
  Post   => (if X = 0.0 then Sqrt_Bounded'Result = 0.0
             else Sqrt_Bounded'Result > 0.0);
```

Similarly, in [`src/nhe_o-types.ads`](../../../src/nhe_o-types.ads), `Make_Ident` and `Make_Text` were upgraded from `Length <= Max_Ident_Len` (tautological for `Ident_Len_Range`) to exact length and first-character preservation:

```ada
function Make_Ident (Source : String) return Identifier_String with
  Global => null,
  Post   => Make_Ident'Result.Length =
              Natural'Min (Source'Length, Max_Ident_Len)
            and then (if Source'Length > 0 then
                        Make_Ident'Result.Data (1) = Source (Source'First));
```

### Example B: Catching a Subtle Bug via Non-Tautological Helper Contracts (`Normalize_JSON_Number`)

In [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb), replacing `Post => True` on `Normalize_JSON_Number` with a real invariant:

```ada
procedure Normalize_JSON_Number
  (Num      : Bounded_Text;
   Is_Neg   : out Boolean;
   Int_Part : out Bounded_Text;
   Frac_Len : out Text_Len_Range;
   Exp_Val  : out Integer;
   Is_Zero  : out Boolean)
with
  Global => null,
  Post   => (if Is_Zero then not Is_Neg and then Exp_Val = 0)
            and then Frac_Len <= Num.Length;
```

immediately caught a latent edge case in `gnatprove`: when `Num` was a bare `"-"`, `Is_Neg` was set to `True` before checking `if Pos = Num.Length then return;`, returning `Is_Zero = True` AND `Is_Neg = True`! Moving `Is_Neg := True;` after the guard satisfied the postcondition and made canonical zero normalization airtight.

### Example C: Modularizing `Analyze_SQL` Without `Post => True`

In [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb), attaching concise, non-tautological `Post` contracts to the internal SQL helpers prevented `gnatprove` from inlining their loops into `Analyze_SQL`:

```ada
procedure Sanitize_SQL
  (Query : Bounded_Text;
   Clean : out Bounded_Text;
   Valid : out Boolean)
with
  Global => null,
  Post   => Clean.Length = Query.Length;

procedure Parse_Limit_Clause
  (Raw_Query   : Bounded_Text;
   Clean_Query : Bounded_Text;
   Limit_Pos   : Positive;
   Valid       : out Boolean;
   Limit_Val   : out Natural)
with
  Global => null,
  Pre    => Raw_Query.Length = Clean_Query.Length,
  Post   => (if not Valid then Limit_Val = 0);

function Count_Create_Table_Columns
  (Raw_Query   : Bounded_Text;
   Clean_Query : Bounded_Text) return Natural
with
  Global => null,
  Pre    => Raw_Query.Length = Clean_Query.Length,
  Post   => Count_Create_Table_Columns'Result <= Clean_Query.Length + 1;
```

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to use |
|---|---|---|---|
| **1. No `Post` on `.adb` helpers** | Zero annotation effort on private helpers. | `gnatprove` contextually inlines the helper at every call site; nested or sequential loops cause massive VC timeouts. | Tiny 1–5 line expression-like helpers (`Is_Space_Or_Punct`, `To_Lower_Char`). |
| **2. Literal `Post => True` on `.adb` helpers** | Stops contextual inlining immediately. | Vacuous contract; hides helper bugs (like `Normalize_JSON_Number` on `"-"`) and fails anti-tautology audits. | Never in production SPARK Gold codebases. |
| **3. Concise Non-Tautological `Post` Contracts (Nhé O's choice)** | Stops contextual inlining, proves each loop modularly in `< 1s`, and catches real edge-case bugs in helpers. | Requires identifying at least one meaningful output property per helper. | All loop-heavy procedures and functions in `SPARK_Mode (On)`. |

---

## 5. Where it lives in the project

- **Vector & Type Contracts**: [`src/nhe_o-vector.ads`](../../../src/nhe_o-vector.ads), [`src/nhe_o-types.ads`](../../../src/nhe_o-types.ads).
- **JSONB Parser & Canonical Number Normalization Contracts**: [`src/nhe_o-json.ads`](../../../src/nhe_o-json.ads), [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb).
- **Modular SQL Sanitizer & Clause Analyzer Contracts**: [`src/nhe_o-sql.ads`](../../../src/nhe_o-sql.ads), [`src/nhe_o-sql.adb`](../../../src/nhe_o-sql.adb).
- **Adversarial Audit Record (`R9-MED-02`, `R10-MED-01`)**: [`docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md).

---

## 6. Further reading

- SPARK User's Guide — *Contextual Analysis of Subprograms Without Contracts* (`info-unrolling-inlining`).
- John Barnes — *SPARK: The Proven Approach to High Integrity Software* (Modular Verification vs. Inlining).

---

## 7. Check yourself

1. **Why is `Post => Sqrt_Bounded'Result >= 0.0` tautological when `Sqrt_Bounded` returns `Non_Negative_Float`, and how does `Post => (if X = 0.0 then Sqrt_Bounded'Result = 0.0 else Sqrt_Bounded'Result > 0.0)` fix it?**
2. **What does `gnatprove`'s diagnostic `info: local subprogram "..." only analyzed in the context of calls` mean for SMT solver performance when that subprogram contains a 512-iteration loop?**
3. **How did replacing `Post => True` on `Normalize_JSON_Number` with `(if Is_Zero then not Is_Neg and then Exp_Val = 0)` expose a bug on the input string `"-"`?**
