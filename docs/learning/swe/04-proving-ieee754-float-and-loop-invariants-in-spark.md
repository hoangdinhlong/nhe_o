# Proving IEEE-754 Floating-Point Arithmetic and Inductive Loop Invariants in SPARK

> **Takeaway:** Automated SMT solvers (`cvc5`, `Z3`, `Alt-Ergo`) reason about loops by mathematical induction (forgetting everything outside `pragma Loop_Invariant`) and treat IEEE-754 floating-point arithmetic as non-associative and rounding-sensitive. To achieve 100% formal proof (`0 unproved`) in a vector database, you must (1) bound floating-point accumulators linearly by iteration count (`Sum <= Float (I) * Max_Step`), (2) guard floating-point divisions (`abs (Dot) < Denom`) against rounding overshoot, and (3) state quantified inductive loop invariants (`for all J in 1 .. I => ...`) that directly imply the subprogram's `Post` contract.

**Tags:** swe, ai
**Related ADRs:** [ADR-002](../../DECISIONS.md), [ADR-003](../../DECISIONS.md)

---

## 1. Context — the problem

When we ran `gnatprove --mode=prove` across **Nhé O**'s 4096-dimensional vector engine (`Nhe_O.Vector`), HNSW graph (`Nhe_O.HNSW`), TOAST page chains (`Nhe_O.Transaction`), and KV/JSONB engines (`Nhe_O.KV`, `Nhe_O.JSON`), 17 verification conditions initially timed out or failed to prove.

Every single one of those 17 unproved checks fell into one of three fundamental categories of formal verification:

1. **IEEE-754 Floating-Point Accumulation & Division Drift**:
   - In real arithmetic, if `|x| <= |y|` and `y > 0`, then `|x / y| <= 1.0`. And if you sum 4096 numbers each bounded by `4.0e12`, the sum cannot overflow `Float'Last` (`3.4e38`).
   - Why did the SMT solvers fail to prove that `Sum := Sum + Diff * Diff` in `L2_Distance_Squared` won't overflow `Float'Last`, or that `Cosine := Dot / Denom` lies in `[-1.0 .. 1.0]`?
   - Because in **IEEE-754 floating-point**, without a loop invariant bounding `Sum` at step `I`, the solver assumes `Sum` at iteration `I - 1` could be *any* `Non_Negative_Float` up to `Float'Last`, so `Sum + Diff * Diff` overflows!
2. **Accumulated State Drift Across Loop Iterations**:
   - In `Write_TOAST_Chain`, maintaining two mutable counters (`Src_Pos := Src_Pos + Chunk_Bytes` and `Remaining := Remaining - Chunk_Bytes`) across loop iterations required proving that the two counters stay in lockstep.
3. **Missing Quantified Bridge Between Loop Body and `Post` Contract**:
   - In `Nhe_O.KV.Set`, the postcondition `Post => Exists (Store, Key, Now)` requires the solver to know *what* `Exists` returns (`for some I in KV_Slot_Index => ...`). Without a postcondition on `Exists` itself, `Exists` is an opaque boolean function to callers!

---

## 2. The concept, explained simply

### Principle 1: Bound Floating-Point Sums Linearly by Iteration Index `I`
Never write a weak loop invariant like `pragma Loop_Invariant (Sum >= 0.0);` on a floating-point accumulator loop.
If `Sum` can be `Float'Last` at the start of iteration `I`, then adding `Sq` overflows `Float'Last`!
Instead, bound both the step increment `Sq` and the running accumulator `Sum` as a linear function of the loop index `I`:

```ada
   --  Each component is in [-1.0e6 .. 1.0e6], so |Diff| <= 2.0e6 and Sq <= 4.0e12
   for I in 1 .. A.Dim loop
      pragma Loop_Invariant
        (I in 1 .. A.Dim
         and then Sum in 0.0 .. Float (I - 1) * 4.0e12);
      Diff := Float (A.Elements (I)) - Float (B.Elements (I));
      Sq   := Diff * Diff;
      pragma Assert (Sq in 0.0 .. 4.0e12);
      Sum  := Sum + Sq;
   end loop;
```
At `I = 4096`, `Float (4095) * 4.0e12 + 4.0e12 = 1.6384e16 << Float'Last (3.4e38)`. Both `cvc5` and `Z3` prove `fp_overflow` absence in under 1 second!

### Principle 2: Explicit Ratio Clamping Before IEEE-754 Division or Scaling
In `Cosine_Distance` (`1.0 - Dot / (Norm_A * Norm_B)`) and `Quantize_To_Int8` (`(Val / Max_Abs) * 127.0`), IEEE-754 rounding during intermediate square roots (`Sqrt_Bounded`) means the solver cannot assume `|Dot| <= Norm_A * Norm_B` purely from the Cauchy-Schwarz inequality (which holds over $\mathbb{R}$, not approximate Newton-Raphson floats!).
Guarding the division or clamping the quotient explicitly:

```ada
   if abs (Dot) >= Denom then
      if Dot >= 0.0 then
         Cosine := 1.0;
      else
         Cosine := -1.0;
      end if;
   else
      Cosine := Dot / Denom;
   end if;
```
makes the postcondition `Cosine_Distance'Result in 0.0 .. 2.0` **algebraically self-evident** to the SMT solver regardless of Newton-Raphson approximation error!

### Principle 3: Compute Loop Offsets Algebraically Instead of Accumulating State
Whenever a loop processes fixed-size chunks (such as `TOAST_Chunk_Max_Bytes = 4080` in `Write_TOAST_Chain`), compute the offset directly from the loop index `Chunk_Idx` rather than mutating `Src_Pos` and `Remaining` at the end of the loop:

```ada
   for Chunk_Idx in 1 .. Needed_Chunks loop
      pragma Loop_Invariant (Needed_Chunks <= Max_TOAST_Chunks);

      Src_Pos     := (Chunk_Idx - 1) * TOAST_Chunk_Max_Bytes + 1;
      Remaining   := Length - (Chunk_Idx - 1) * TOAST_Chunk_Max_Bytes;
      Cur_Page_Id := Start_Page_Id + (Chunk_Idx - 1);
      ...
```
Because `Src_Pos`, `Remaining`, and `Cur_Page_Id` are closed-form expressions of `Chunk_Idx`, the SMT solver proves every array slice and page ID bound in one step without needing a multi-variable inductive invariant!

### Principle 4: Quantified `Loop_Invariant` + Quantified Predicate `Post`
When a search function (`Equal_Ident`, `Has_Key`, `Exists`) loops from `1 .. N` and returns `False` (or `True`) at the end, the loop invariant at iteration `I` must state that **all elements `1 .. I - 1` examined so far did not match**:

```ada
   function Exists
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Boolean
     with Global => null,
          Post   => Exists'Result =
                      (for some I in KV_Slot_Index =>
                         Store.Slots (I).Occupied
                         and then not Is_Slot_Expired (Store.Slots (I), Now)
                         and then Equal_Ident (Store.Slots (I).Key, Key));
```
With `pragma Loop_Invariant (for all J in 1 .. I - 1 => not (...))` inside `Exists`, `gnatprove` proves both `Exists` and the postconditions of `Set` (`Post => Exists (Store, Key, Now)`) and `Del` (`Post => not Exists (Store, Key, 0)`).

### Principle 5: Explicit Accumulator Clamping to Avoid IEEE-754 Distributivity Timeouts
Even when `Sum_F <= Float (I - 1) * Max_Sq` and `Sq_F <= Max_Sq` hold at iteration `I`, proving `Sum_F + Sq_F <= Float (I) * Max_Sq` directly via `pragma Assert (Sum_F <= Float (I) * Max_Sq)` forces SMT solvers (`cvc5`, `Z3`) to reason about IEEE-754 bit-vector distributivity (`Float(I - 1) * Max_Sq + Max_Sq <= Float(I) * Max_Sq` under nearest-even rounding), which can time out when combined with helper calls like `Dequantize_Int8_Scalar`.

By clamping both the step term `Sq_F` and the running sum `Sum_F` explicitly (as done in `Nhe_O.Vector.L2_Distance_Squared` and `Nhe_O.HNSW.Node_Distance`):

```ada
   Sq_F := Diff_F * Diff_F;
   if Sq_F > Max_Sq then
      Sq_F := Max_Sq;
   end if;
   Sum_F := Sum_F + Sq_F;
   if Sum_F > Float (I) * Max_Sq then
      Sum_F := Float (I) * Max_Sq;
   end if;
```
the upper bound `Sum_F <= Float (I) * Max_Sq` holds **by control-flow construction** at the end of every iteration, dropping proof time from a timeout (`>10s`) to `<0.1s`!

### Principle 6: Non-Tautological Outer Loop Invariants to Prevent Nested Loop Unrolling Without `-gnatwa`/`-gnatwc` Warnings
By default, `gnatprove` unrolls `for` loops with up to 20 iterations when they contain no `pragma Loop_Invariant`. If an outer loop of 16 slots (`for Slot in Page_Slot_Index loop` in `Encode_Slotted_Page` and `Decode_Slotted_Page`) wraps an inner loop of 208 bytes (`Inline_Tuple_Index`), unrolling the outer loop 16 times creates $16 \times 208 = 3,328$ loop iterations and 16 inlined calls to `Decode_TOAST_Pointer`, inflating verification time from 1 second to over 20 minutes.

However, writing a trivial loop-parameter invariant such as `pragma Loop_Invariant (Slot in Page_Slot_Index);` or `pragma Loop_Invariant (Slot >= 1);` triggers GNAT warnings (`-gnatwa` *"explicit membership test may be optimized away"* or `-gnatwc` *"condition is always True"*). Instead, place an invariant over **mutable local state** computed or preserved inside the loop:

```ada
   for Slot in Page_Slot_Index loop
      Dir_Base := 25 + (Slot - 1) * 8;
      Tup_Base := 153 + (Slot - 1) * 240;
      pragma Loop_Invariant
        (Dir_Base = 25 + (Slot - 1) * 8
         and then Tup_Base = 153 + (Slot - 1) * 240);
      ...
```
Because `Dir_Base` and `Tup_Base` are local variables assigned inside the loop body, GNAT emits **zero compiler warnings**, `gnatprove` does not unroll the 16-slot outer loop, and the invariant is discharged in `<0.01s`.

---

## 3. A concrete example: Newton-Raphson `Sqrt_Bounded` in Pure SPARK

In [`src/nhe_o-vector.adb`](../../../src/nhe_o-vector.adb), `Sqrt_Bounded` computes $\sqrt{X}$ using 80 Newton-Raphson iterations (`Guess := 0.5 * (Guess + X / Guess)`). To prove that `Guess + X / Guess` never overflows `Float'Last` and `X / Guess` never divides by zero across all 80 iterations, we split the computation into two half-terms (`Term1 := 0.5 * Guess` and `Term2 := 0.5 * (X / Guess)`) and clamp `Guess` to the invariant range `[1.0 .. X]` (for `X >= 1.0`) or `[X .. 1.0]` (for `X < 1.0`):

```ada
      if X >= 1.0 then
         Guess := X;
         for Iter in 1 .. 80 loop
            pragma Loop_Invariant (Guess in 1.0 .. X);
            Term1 := 0.5 * Guess;
            Term2 := 0.5 * (X / Guess);
            pragma Assert (Term1 in 0.0 .. 0.5 * X);
            pragma Assert (Term2 in 0.0 .. 0.5 * X);
            Guess := Term1 + Term2;
            if Guess < 1.0 then
               Guess := 1.0;
            elsif Guess > X then
               Guess := X;
            end if;
         end loop;
      end if;
```

Why did splitting `0.5 * (Guess + X / Guess)` into `0.5 * Guess + 0.5 * (X / Guess)` matter?
Because if `Guess = X` and `X > Float'Last / 2.0`, then `Guess + X / Guess` (`X + 1.0`) could overflow before multiplying by `0.5`! By multiplying each term by `0.5` first (`Term1 <= 0.5 * X` and `Term2 <= 0.5 * X`), `Term1 + Term2 <= X <= Float'Last` is guaranteed overflow-free for all `X`!

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to choose |
|---|---|---|---|
| **1. Suppress Floating-Point Overflow Checks (`pragma Suppress`)** | Zero proof effort on floating-point loops. | Violates AoRTE guarantees; silent `Inf` or `NaN` values can corrupt HNSW graph edges. | Unverified prototypes only. |
| **2. Fixed-Point Arithmetic Only** | Integer/fixed-point SMT theories are much faster than IEEE-754 float theories. | Loses compatibility with standard `Float32` LLM embeddings (`pgvector` `VECTOR(d)`). | Financial/accounting columns (`Pg_Numeric`). |
| **3. Linearly Bounded IEEE-754 Loop Invariants + Algebraic Offsets (Nhé O's choice)** | Retains full `Float32` `pgvector` compatibility while proving 100% of all 3,776 checks in `gnatprove`. | Requires explicit range subtypes (`Vector_Component in -1.0e6 .. 1.0e6`) and linear loop bounds. | Formally verified vector & RAG databases (`ADR-002`, `ADR-003`, `ADR-006`). |

---

## 5. Where it lives in the project

- **Vector & Quantization Proofs**: [`src/nhe_o-vector.adb`](../../../src/nhe_o-vector.adb) (`L2_Distance_Squared`, `Inner_Product`, `Sqrt_Bounded`, `Cosine_Distance`, `Quantize_To_Int8`).
- **HNSW Distance Proofs**: [`src/nhe_o-hnsw.adb`](../../../src/nhe_o-hnsw.adb) (`Node_Distance`, `Node_Pair_Distance`, `Insert_Vector`).
- **Algebraic TOAST Chunk Indexing & Slotted-Page Loop Framing**: [`src/nhe_o-transaction.adb`](../../../src/nhe_o-transaction.adb) (`Write_TOAST_Chain`, `Encode_Slotted_Page`, `Decode_Slotted_Page`).
- **Quantified Search Invariants**: [`src/nhe_o-types.adb`](../../../src/nhe_o-types.adb), [`src/nhe_o-json.adb`](../../../src/nhe_o-json.adb), and [`src/nhe_o-kv.adb`](../../../src/nhe_o-kv.adb).

---

## 6. Further reading

- *SPARK 2014 User's Guide — How to Write Loop Invariants (Framing, Preservation, and Completeness)*.
- *David Goldberg — What Every Computer Scientist Should Know About Floating-Point Arithmetic (ACM Computing Surveys)*.
- *Why3 & SMT-LIB `FP` Theory — Automated Reasoning over IEEE-754 Floating-Point Numbers in CVC5 and Z3*.

---

## 7. Check yourself

1. **Why is `pragma Loop_Invariant (Sum >= 0.0);` insufficient to prove that `Sum := Sum + Sq;` will not overflow `Float'Last` inside a loop?**
2. **In `Sqrt_Bounded`, why is `0.5 * Guess + 0.5 * (X / Guess)` safer against floating-point overflow than `0.5 * (Guess + X / Guess)`?**
3. **Why does replacing mutable `Src_Pos := Src_Pos + Chunk_Bytes` with the closed-form expression `Src_Pos := (Chunk_Idx - 1) * TOAST_Chunk_Max_Bytes + 1` make `Write_TOAST_Chain` dramatically easier for an SMT solver to prove?**
4. **Why does `Nhe_O.KV.Set` (`Post => Exists (Store, Key, Now)`) require `Exists` itself to carry a quantified `Post` contract?**
5. **Why does placing a non-tautological `pragma Loop_Invariant` on an outer 16-iteration loop (`Page_Slot_Index`) that wraps a 208-iteration inner loop speed up `gnatprove` by more than $100\times$ without triggering `-gnatwa`/`-gnatwc` compiler warnings?**
