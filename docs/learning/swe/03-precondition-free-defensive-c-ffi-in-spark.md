# Precondition-Free Defensive C ABI / FFI Boundaries in 100% SPARK

> **Takeaway:** Exporting Ada/SPARK procedures to C and Python (`Convention => C, Export => True`) without `SPARK_Mode (Off)` requires two architectural rules: (1) pass bounded `Interfaces.C.char_array` buffers with explicit integer lengths instead of raw C pointers (`chars_ptr`), and (2) give exported FFI procedures **no preconditions (`Pre => True`)**, defensively validating all untrusted C inputs inside the boundary before calling precondition-guarded internal SPARK subprograms.

**Tags:** swe, ai
**Related ADRs:** [ADR-002](../../DECISIONS.md), [ADR-005](../../DECISIONS.md)

---

## 1. Context — the problem

When embedding a formally verified Ada/SPARK database engine like **Nhé O** into Python local LLM pipelines (`ctypes`), C/C++ inference servers (`llama.cpp`), or Rust agents, we must expose a **C Application Binary Interface (ABI)**.

However, two classic pitfalls usually force developers to disable formal verification (`pragma SPARK_Mode (Off);`) at the FFI layer:

1. **The Raw Pointer Trap (`chars_ptr`)**:
   - In standard C, strings and buffers are passed as raw pointers (`const char *`).
   - In Ada, `Interfaces.C.Strings.chars_ptr` is an unrestricted access-to-object type. Because raw C pointers can alias arbitrary memory or be `NULL`, SPARK 2014 forbids `chars_ptr` in `SPARK_Mode (On)`.
2. **The Unverified Precondition Trap (`Pre` on Exported C Symbols)**:
   - Internal SPARK procedures rely on preconditions (e.g., `Pre => Key.Length > 0` or `Pre => Vec.Dim = Index.Dim`).
   - If you place a SPARK precondition (`with Pre => Key_Len in 1 .. 64`) directly on an exported C function (`Export => True, Convention => C`), **who proves that the C or Python caller obeys that precondition?**
   - Neither `gnatprove` nor the C compiler can prove what an arbitrary Python script passes at runtime! If a Python caller passes `key_len = -5` or `vx = 1.0e35`, an unguarded internal conversion will trigger a `Constraint_Error` across the C ABI boundary.

---

## 2. The concept, explained simply

We keep **100% of the FFI layer inside `pragma SPARK_Mode (On);`** (`Nhe_O.C_API`) and achieve **100% formal verification (`0 unproved` checks in `gnatprove`)** by combining **Fixed-Bound Reference Buffers** with **Precondition-Free Defensive Firewalls**:

### Rule 1: Fixed-Capacity `char_array` Buffers Over the C ABI
In Ada's C interfacing standard (`Interfaces.C`, RM B.3), a constrained array of `Interfaces.C.char` (`char_array`) passed as an `in` or `out` parameter to a `Convention => C` procedure is passed **by reference (as a `const char *` or `char *` pointer at the machine ABI level)** — with zero heap allocation and zero access types in SPARK!

```ada
   --  64-byte and 512-byte C buffers passed as `const char *` / `char *` in C ABI
   subtype C_Ident_Index is size_t range 1 .. size_t (Max_Ident_Len);
   subtype C_Ident_Buf is char_array (C_Ident_Index);

   subtype C_Text_Index is size_t range 1 .. size_t (Max_Text_Len);
   subtype C_Text_Buf is char_array (C_Text_Index);
```

### Rule 2: Precondition-Free Exported Wrappers (`Pre => True`) + Internal Validation
Every exported `Nhe_O.C_API` procedure has **no precondition** (`Pre => True` implicitly). Inside the procedure body, it treats all incoming C `int`, `int64_t`, and `C_float` arguments as **untrusted external inputs**:
1. It checks every scalar bound (`Key_Len in 1 .. 64`, `VX in -1.0e6 .. 1.0e6`, `TTL_Sec` overflow bounds) using standard `if ... then Out_Status := C_Status_Invalid_Arg; return; end if;` guards.
2. Only after those guards succeed does it construct strongly typed SPARK records (`Bounded_Ident`, `Bounded_Text`, `Vector_Value`) and call the internal `Nhe_O.*` engines.

```text
Untrusted C / Python Caller (`bindings/python/nhe_o.py`)
   |
   |  Passes arbitrary `int`, `float`, `char[64]` across C ABI
   v
+-----------------------------------------------------------------------+
|  `Nhe_O.C_API` (`SPARK_Mode => On`, `Export => True, Convention => C`)|
|  Precondition: NONE (`Pre => True` — accepts any C input safely!)     |
|                                                                       |
|  1. Defensive Boundary Firewall:                                      |
|     if Key_Len <= 0 or else Key_Len > 64 or else Now_Sec < 0 then     |
|        Out_Status := C_Status_Invalid_Arg; return;                    |
|     end if;                                                           |
|                                                                       |
|  2. Proven Conversion (`To_Bounded_Ident` with `Post => Length = Len`)|
|  3. Calls Internal Engine (`Nhe_O.KV.Set` — `gnatprove` proves `Pre`!)|
+-----------------------------------------------------------------------+
```

Because the `if` guards dominate the internal call, `gnatprove` proves that:
1. No subtype conversion inside `Nhe_O.C_API` can ever raise `Constraint_Error`.
2. Every precondition of the internal `Nhe_O.KV`, `Nhe_O.Vector`, `Nhe_O.PubSub`, and `Nhe_O.RAG` calls is 100% satisfied!

---

## 3. A concrete example

Here is how `To_Bounded_Ident` and `C_KV_Set` in [`src/nhe_o-c_api.adb`](../../../src/nhe_o-c_api.adb) bridge untrusted C arguments into `Nhe_O.KV.Set`:

```ada
   --  Helper with formal Postcondition connecting C length to SPARK Bounded_Ident.Length
   function To_Bounded_Ident
     (Buf : C_Ident_Buf;
      Len : Ident_Length) return Bounded_Ident
     with Global => null,
          Post   => To_Bounded_Ident'Result.Length = Len
   is
      Res : Bounded_Ident := (Length => Len, Data => [others => ' ']);
   begin
      for I in 1 .. Len loop
         pragma Loop_Invariant (Res.Length = Len);
         Res.Data (I) := To_Ada (Buf (size_t (I)));
      end loop;
      return Res;
   end To_Bounded_Ident;

   --  Exported C ABI procedure (no precondition!)
   procedure C_KV_Set
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Val_Buf    : in     C_Text_Buf;
      Val_Len    : in     int;
      Now_Sec    : in     Integer_64;
      TTL_Sec    : in     Integer_64;
      Out_Status :    out int)
   is
      Key     : Bounded_Ident;
      Val     : Bounded_Text;
      Has_TTL : Boolean;
      TTL_Val : Epoch_Seconds;
   begin
      --  1. Defensive validation of untrusted C integers
      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Val_Len < 0 or else Val_Len > int (Max_Text_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      if TTL_Sec > 0 then
         if Now_Sec > Epoch_Seconds'Last - TTL_Sec then
            Out_Status := C_Status_Invalid_Arg;
            return;
         end if;
         Has_TTL := True;
         TTL_Val := TTL_Sec;
      else
         Has_TTL := False;
         TTL_Val := 0;
      end if;

      --  2. Proven safe conversions (Postcondition proves Key.Length = Key_Len > 0)
      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Val := To_Bounded_Text (Val_Buf, Text_Length (Val_Len));

      --  3. Internal SPARK call (Pre => Key.Length > 0 is 100% proved!)
      Set (G_KV_Store, Key, Val, Now_Sec, Has_TTL, TTL_Val);
      Out_Status := C_Status_Ok;
   end C_KV_Set;
```

Notice why `Post => To_Bounded_Ident'Result.Length = Len` on `To_Bounded_Ident` is essential: without that postcondition, `gnatprove` knows `Key_Len >= 1`, but would not know that `Key.Length >= 1` when checking `Nhe_O.KV.Set`'s precondition (`Pre => Key.Length > 0`)!

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to choose |
|---|---|---|---|
| **1. `SPARK_Mode (Off)` C Wrapper + `chars_ptr`** | Accepts arbitrary NUL-terminated C strings of any length. | Disables formal verification in the FFI layer; vulnerable to missing NUL terminators and buffer overruns. | Legacy bindings to unbounded C APIs. |
| **2. Exported SPARK Subprograms with `Pre` Contracts** | Avoids explicit `if` validation inside the wrapper. | Unsafe across language boundaries: C/Python callers do not check SPARK preconditions statically, risking runtime crashes. | Ada-to-Ada calls where both caller and callee are analyzed by `gnatprove`. |
| **3. Precondition-Free Defensive `SPARK_Mode (On)` Wrapper + Fixed `char_array` (Nhé O's choice)** | 100% formally proven AoRTE (`0 unproved`); immune to invalid arguments from C/Python; zero `SPARK_Mode (Off)`. | Callers pass fixed-size buffers (`char[64]`, `char[512]`) + explicit length. | High-assurance embedded engines (`ADR-005`). |

---

## 5. Where it lives in the project

- **ADR**: [`ADR-005`](../../DECISIONS.md) — *Formally Verified C ABI / FFI Boundary via Precondition-Free Defensive Subprograms in 100% SPARK*.
- **Ada/SPARK Specification & Body**: [`src/nhe_o-c_api.ads`](../../../src/nhe_o-c_api.ads) and [`src/nhe_o-c_api.adb`](../../../src/nhe_o-c_api.adb).
- **C99/C++17 Header**: [`include/nhe_o.h`](../../../include/nhe_o.h).
- **Shared Library GPR Project**: [`nhe_o_lib.gpr`](../../../nhe_o_lib.gpr) (`lib/libnhe_o.so`).
- **Python `ctypes` SDK**: [`bindings/python/nhe_o.py`](../../../bindings/python/nhe_o.py).

---

## 6. Further reading

- *Ada Reference Manual — Annex B.3: Interfacing with C (`Interfaces.C` parameter passing conventions for `char_array` and scalars)*.
- *SPARK 2014 User's Guide — Calling SPARK from C and Defensive Input Validation at the Boundary*.
- *GPRbuild User's Guide — Stand-Alone Libraries (`Library_Interface` and `Library_Auto_Init`)*.

---

## 7. Check yourself

1. **Why is placing a SPARK `Pre` contract on a `Convention => C, Export => True` procedure insufficient when the caller is written in C or Python?**
2. **How does `Interfaces.C.char_array` allow passing string buffers across the C ABI without using `Interfaces.C.Strings.chars_ptr` or `SPARK_Mode (Off)`?**
3. **Why did `To_Bounded_Ident` need the postcondition `Post => To_Bounded_Ident'Result.Length = Len` for `gnatprove` to prove `C_KV_Set`?**
4. **What does `for Library_Auto_Init use "true";` in `nhe_o_lib.gpr` do when Python loads `lib/libnhe_o.so` via `ctypes.CDLL`?**
