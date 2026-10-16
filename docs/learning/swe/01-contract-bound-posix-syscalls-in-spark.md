# Contract-Bound POSIX Syscalls in `SPARK_Mode (On)`

> **Takeaway:** By bypassing exception-raising Ada standard file libraries (`Ada.Direct_IO`, `Ada.Streams.Stream_IO`) and binding directly to exception-free POSIX C kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) with `Side_Effects`, an embedded storage engine can keep 100% of its I/O orchestration — path sanitization, NUL-termination, 64-bit offset arithmetic, short-read/write detection, and `fsync` durability checks — inside `pragma SPARK_Mode (On);`.

**Tags:** swe
**Related ADRs:** [ADR-002](../../DECISIONS.md)

---

## 1. Context — the problem

When building a formally verified database engine like **Nhé O** in Ada/SPARK, engineers often assume that the physical disk I/O package body (`Nhe_O.IO`) **must** be marked `pragma SPARK_Mode (Off);`.

Why does that assumption exist? Because standard Ada file I/O packages (`Ada.Streams.Stream_IO` and `Ada.Direct_IO`) report runtime failures — such as missing files, permission errors, short reads, or disk full conditions — by **raising Ada exceptions** (`Name_Error`, `Use_Error`, `Status_Error`, `End_Error`, `Device_Error`).

Historically and in standard SPARK verification profiles:
1. Catching arbitrary runtime I/O exceptions inside a package body often pushes engineers to mark the body `pragma SPARK_Mode (Off);`.
2. Worse, once a package body is marked `SPARK_Mode (Off)`, **`GNATprove` stops analyzing the entire body**. Any bug inside that body — an integer overflow when computing `Page_Id * Page_Size`, an off-by-one buffer slice, a path truncation, or forgetting to zero a buffer on a short read — silently escapes formal verification!

In a database engine, the I/O layer is where pages and Write-Ahead Log (WAL) frames meet the disk. Leaving the I/O body unverified creates a blind spot right at the durability boundary.

---

## 2. The concept, explained simply

The OS kernel itself (Linux / POSIX) **does not raise Ada exceptions**. Kernel system calls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`, `unlink`) are plain C functions that communicate outcomes entirely through **return values** (`int` file descriptors/status codes, or `ssize_t` byte counts):
- `open(...)` returns a non-negative file descriptor (`Fd >= 0`) on success, or `-1` on failure.
- `pread(fd, buf, count, offset)` and `pwrite(fd, buf, count, offset)` atomically seek and transfer bytes at a given 64-bit file `offset` without mutating the file descriptor's seek pointer, returning the exact number of bytes transferred (`ssize_t`) or `-1` on error.
- `fsync(fd)` and `close(fd)` return `0` on success or `-1` on error.

In **Ada 2022 / SPARK 2022**, a function that performs external I/O or mutates an `in out` buffer parameter can be declared directly in `SPARK_Mode (On)` using the `Side_Effects` aspect (`pragma SPARK_Mode (On);` + `with Side_Effects, Import => True, Convention => C`).

What does `with Side_Effects` mean in SPARK?
- Normally, SPARK requires functions to be pure mathematical functions (no side effects, no `in out` parameters).
- Marking a function `with Side_Effects` tells `GNATprove` to treat calls to that function like a **procedure call** (it may only appear on the right-hand side of a single assignment statement `Result := Syscall (...);`, cannot be nested inside expressions, and is tracked for data-flow initialization and aliasing).

By binding directly to POSIX syscalls with `Side_Effects`, **nothing in the I/O layer ever raises an Ada exception**, allowing the entire `Nhe_O.IO` body (`src/nhe_o-io.adb`) to remain in **`pragma SPARK_Mode (On);`**.

---

## 3. A concrete example

Here is how **Nhé O** (`src/nhe_o-io.ads` and `src/nhe_o-io.adb`) implements crash-safe 4096-byte positional page I/O in 100% `SPARK_Mode (On)`:

### Step 1: Reject embedded NULs and prove C-path NUL termination (`src/nhe_o-io.ads`)

POSIX `open(2)` expects a NUL-terminated C string (`char*`). If a user-supplied path contains an embedded `ASCII.NUL` byte (e.g., `"/tmp/db\0.evil"`), C will silently truncate the path at the first NUL — a classic path-truncation vulnerability.

In `Nhe_O.IO`, we guard against this with a formal precondition and a loop-invariant-verified converter:

```ada
   --  True iff Path contains an embedded ASCII.NUL character within 1 .. Path.Length
   function Has_Embedded_NUL (Path : Bounded_Text) return Boolean;

   procedure To_C_Path
     (Path   : in     Bounded_Text;
      C_Path :    out C_Path_String)
     with Pre  => Path.Length > 0 and then not Has_Embedded_NUL (Path),
          Post => C_Path (Path.Length + 1) = ASCII.NUL
                  and then (for all I in 1 .. Path.Length =>
                              C_Path (I) = Path.Data (I));
```

### Step 2: Bind atomic POSIX syscalls with `Side_Effects` (`src/nhe_o-io.adb`)

Instead of calling stateful `lseek` + `read`/`write` (which requires two syscalls and is not thread-safe on a shared file descriptor), we bind POSIX `pread` and `pwrite` over `Convention => C` byte arrays:

```ada
   function Posix_Pwrite
     (Fd     : int;
      Buf    : Page_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "pwrite";

   function Posix_Pread
     (Fd     : int;
      Buf    : in out Page_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "pread";
```

### Step 3: Verify 64-bit offset arithmetic and short-write/read handling in `SPARK_Mode (On)`

```ada
   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Offset  : constant Off_T := Off_T (Page_Id) * Off_T (Nhe_O.Page_Size);
      Written : Ssize_T;
      Sync_Rc : int;
      Close_R : int;
   begin
      if Has_Embedded_NUL (File_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_CLOEXEC, Mode_0600);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      Written := Posix_Pwrite (Fd, Buffer, size_t (Nhe_O.Page_Size), Offset);
      Sync_Rc := Posix_Fsync (Fd);
      Close_R := Posix_Close (Fd);

      Success := (Written = Ssize_T (Nhe_O.Page_Size))
                 and then (Sync_Rc = 0)
                 and then (Close_R = 0);
   end Write_Page;
```

Notice what `SPARK_Mode (On)` verifies inside `Write_Page` and `Read_Page`:
1. **No Path Truncation**: `To_C_Path` cannot be called unless `not Has_Embedded_NUL (File_Path)` holds.
2. **No Integer Overflow**: Because `Page_Id` is constrained to `Valid_Page_Id` (`0 .. 1_048_575`) and cast to 64-bit `Off_T` (`Interfaces.Integer_64`) before multiplying by `4096`, `Off_T (Page_Id) * Off_T (Nhe_O.Page_Size)` is provably free of 32-bit signed overflow.
3. **No Uninitialized Output Buffers**: In `Read_Page`, `Buffer` is zero-initialized on entry and explicitly wiped (`Buffer := [others => 0];`) if `N_Read /= 4096` or `Close_R /= 0`, ensuring partial/corrupt disk reads never leak into the engine.
4. **Explicit Durability Check**: `Success` is `True` if and only if all `4096` bytes were written, `fsync` returned `0`, and `close` returned `0`.

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to choose |
|---|---|---|---|
| **1. `Ada.Streams.Stream_IO` with `SPARK_Mode (Off)` body** | Portable across POSIX and non-POSIX OSes out of the box using standard Ada library. | Entire `Nhe_O.IO` body is invisible to `GNATprove`; requires exception handlers; no built-in `fsync` in standard Ada. | Quick prototypes where 100% `SPARK_Mode (On)` and hardware `fsync` are not required. |
| **2. Third-party `spark-file-io` wrapper crate** | Ready-made SPARK spec around standard Ada file streams. | Implementation body inside the library still relies on `SPARK_Mode (Off)` and lacks atomic `pread`/`pwrite` and `fsync` control. | General text/sequential file reading in SPARK apps. |
| **3. Contract-Bound POSIX Syscalls in `SPARK_Mode (On)` (Nhé O's choice)** | **100% `SPARK_Mode (On)`** across all specs and bodies; atomic positional `pread`/`pwrite`; explicit hardware `fsync` for ACID durability; zero exceptions. | Platform-specific to POSIX/Linux (requires a separate Win32 `ReadFile`/`WriteFile`/`FlushFileBuffers` binding if targeting native Windows). | High-assurance ACID storage engines, WAL loggers, and embedded systems requiring 100% `SPARK_Mode (On)`. |

---

## 5. Where it lives in the project

- **ADR**: [`ADR-002`](../../DECISIONS.md#L24-L28) — *100% `SPARK_Mode (On)` Mandate via Statically Bounded Memory and Contract-Bound POSIX Syscall I/O*.
- **Domain Invariant**: [`BR-001`](../../domain/business-rules.md#L9) — *100% `SPARK_Mode (On)` Verification Invariant*.
- **Architecture**: [`docs/reference/ARCHITECTURE.md`](../../reference/ARCHITECTURE.md#L9-L47) — System Overview & Contract-Bound POSIX I/O diagram.
- **Specification**: [`src/nhe_o-io.ads`](../../../src/nhe_o-io.ads) — `Valid_Page_Id`, `Page_Buffer`, `WAL_Frame_Buffer`, `Has_Embedded_NUL`, `To_C_Path`, and I/O contracts.
- **Implementation**: [`src/nhe_o-io.adb`](../../../src/nhe_o-io.adb) — `Posix_Open`, `Posix_Pwrite`, `Posix_Pread`, `Posix_Write_WAL`, `Posix_Pread_WAL`, `Posix_Fsync`, `Posix_Close`, `Posix_Unlink`.

---

## 6. Further reading

- *SPARK User's Guide — Function With Side Effects (`pragma Side_Effects` / Aspect `Side_Effects`)*, AdaCore Documentation.
- *POSIX.1-2017 (`pread`, `pwrite`, `fsync`, `open`)* — The Open Group Base Specifications Issue 7.
- *SQLite Atomic Commit and Write-Ahead Logging* — How embedded databases use `pread`/`pwrite` and `fsync` for crash-safe durability.

---

## 7. Check yourself

1. **Why does using `Ada.Streams.Stream_IO` or `Ada.Direct_IO` typically force an I/O package body to use `pragma SPARK_Mode (Off);`, and what verification guarantees do you lose when you do that?**
2. **Why does `Nhe_O.IO` use POSIX `pread` and `pwrite` instead of calling `lseek` followed by `read` or `write`?**
3. **What is the role of the `with Side_Effects` aspect in SPARK 2022, and why is it necessary when importing C functions like `pread(fd, buf, count, offset)`?**
4. **Why must `To_C_Path` have the precondition `not Has_Embedded_NUL (Path)` in addition to appending `ASCII.NUL` at `Path.Length + 1`?**
5. **Why does `Ada.Streams.Stream_IO.Flush` not suffice for the `D` (Durability) in ACID, and why does `Nhe_O.IO` call `Posix_Fsync` explicitly?**
