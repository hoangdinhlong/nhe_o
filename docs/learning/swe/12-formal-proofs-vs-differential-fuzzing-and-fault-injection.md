# Formal Proofs vs. Differential Fuzzing and Fault Injection: Why 100% SPARK and Adversarial Oracles Are Strictly Complementary

> **Takeaway:** Formal verification proves absence of runtime errors and conformance to an abstract mathematical specification, while differential fuzzing against reference implementations and crash fault injection test specification fidelity and environmental resilience outside the abstract model.

**Tags:** swe
**Related ADRs:** [ADR-002](../../DECISIONS.md), [ADR-005](../../DECISIONS.md), [ADR-006](../../DECISIONS.md), [ADR-009](../../DECISIONS.md), [ADR-010](../../DECISIONS.md), [ADR-012](../../DECISIONS.md), [ADR-013](../../DECISIONS.md), [ADR-015](../../DECISIONS.md), [ADR-016](../../DECISIONS.md), [ADR-020](../../DECISIONS.md)

---

## 1. Context — the problem

In Round 11 of **Epic 04 (`04-post-epic-03-grooming-and-hardening`)**, **Nhé O** achieved a milestone: **100% SPARK Gold formal verification**. Across all 26 source units in `src/`, `gnatprove` proved 4,246 out of 4,246 verification conditions (VCs) with **0 unproved checks and 0 warnings**. Every array indexing operation, every arithmetic computation, every pointer dereference, and every inductive loop invariant was mathematically proved free of run-time exceptions (AoRTE), and key state machines were proved to conform to their Ada/SPARK contracts.

Yet, when the project entered **Phase 2 (Rounds 12–16)** and subjected the codebase to independent adversarial review using **differential fuzzing** (against PostgreSQL 16 and Redis 7) and **physical crash fault injection**, the reviewers uncovered **166 additional defects**:
- SQL statements could be smuggled past the single-statement validator using PostgreSQL multiline string continuations (`'abc'\n'def'`) and non-UTF-8 character sequences (`R14-SQL-01`, `R15-SQL-01`).
- Two concurrent processes opening the same database file could corrupt slotted pages because advisory locking had not been enforced at the OS level (`R14-TX-01`, `R14-CA-01`).
- A crash occurring immediately after writing a WAL commit barrier could cause recovery to replay data frames in physical WAL order rather than transactional commit order (`R12-TX-02`, `R12-TX-04`).
- Symbolic links planted at scratch file paths could trick `open()` and `close()` into modifying or unlinking foreign files (`R16-CA-01`, `R16-CA-03`).

Why did mathematically proved software exhibit real-world security and consistency flaws? Did the formal prover fail?

The answer is **no**. The formal prover proved with mathematical certainty that the source code satisfied its written specification. However, the written specification was incomplete with respect to the real-world operating environment. Formal proofs and adversarial oracles evaluate software across two orthogonal dimensions.

---

## 2. The concept, explained simply

To build high-assurance systems, engineers must distinguish between two fundamentally distinct verification questions:

```
+-----------------------------------------------------------------------------+
|                           THE TWO VERIFICATION AXES                         |
|                                                                             |
|      1. Model Verification (Internal Consistency):                          |
|         "Does the implementation strictly satisfy the formal model?"         |
|         --> Tooling: Static Analyzers, SMT Provers, SPARK GNATprove.         |
|         --> Proves: Absence of runtime crashes, contract compliance.         |
|                                                                             |
|      2. Specification Fidelity (External Validity):                          |
|         "Does the formal model accurately reflect reality and requirements?"|
|         --> Tooling: Differential Fuzzing, Reference Oracles, Fault Injection|
|         --> Proves: Semantic compatibility, POSIX/hardware crash resilience.|
+-----------------------------------------------------------------------------+
```

### Axis 1: Formal Verification (`gnatprove` & SMT Solvers)
Formal verification maps Ada source code and contracts (`Pre`, `Post`, `Loop_Invariant`, `Type_Invariant`) into First-Order Logic formulas dispatched to SMT solvers (Z3, CVC5, Alt-Ergo).
- **What it guarantees**: If the preconditions hold and the environment obeys the formal axioms, the code will *never* divide by zero, access an array out of bounds, overflow an integer, violate a type range, fail an assertion, or terminate with an unhandled exception.
- **The Blind Spot**: SMT solvers operate within a closed mathematical universe. They cannot know that PostgreSQL 16 treats vertical tabs differently than PostgreSQL 17 (`R15-SQL-02`), that the Linux kernel filesystem might reorder un-fsynced directory entries after a crash, or that `dlclose()` unmaps code while host signal handlers still point into it (`R15-CA-01`).

### Axis 2: Differential Fuzzing & Reference Oracles
Differential testing executes the system under test in parallel with an authoritative golden reference (e.g., PostgreSQL 16 for SQL/JSONB, Redis 7 for KV eviction) across millions of randomized inputs.
- **What it guarantees**: Detects semantic drift, dialect discrepancies, parser boundary mismatches, and edge-case behavior deviations from industry standards.
- **The Blind Spot**: Testing can only sample a tiny fraction of the $2^{64}$ state space. Fuzzing rarely synthesizes the exact sequence of 100 internal operations required to trigger an edge-case integer overflow.

### Axis 3: Fault Injection & Crash Simulation
Physical fault injection interrupts execution at arbitrary instructions, cuts power mid-syscall (`pwrite`), truncates files mid-sector, injects OS errors (`EINTR`, `ENOSPC`, `EIO`), and executes concurrent race conditions.
- **What it guarantees**: Verifies physical durability, torn-write repair, atomic recovery, and crash consistency under hostile OS and hardware conditions.

---

## 3. Concrete examples from Nhé O

### Case A: The SQL Parser Smuggling Attack (`R14-SQL-01`)

**In the Formal Proof Model:**
In `src/nhe_o-sql.adb`, `Analyze_SQL` was proved to satisfy:
```ada
procedure Analyze_SQL
  (Raw_SQL : String;
   Stmt    : out SQL_Statement;
   Status  : out Database_Status)
with
  Pre  => Raw_SQL'Length <= Max_SQL_Len,
  Post => (if Status = Status_Ok then Stmt.Kind /= Stmt_Invalid);
```
The prover verified that character slice indices remained within `1 .. Raw_SQL'Length`, loops terminated, and `Status` was assigned deterministically.

**In the Differential Oracle:**
A differential fuzzer utilizing `pglast` (the exact PostgreSQL 16 C parser grammar) tested 40,000 fuzzed SQL inputs against Nhé O. It discovered **89 statement smugglings** via PostgreSQL multiline string continuation:
```sql
SELECT E'valid string'
'smuggled statement'; DELETE FROM documents; --
```
In PostgreSQL, two string literals separated only by whitespace and a newline are concatenated into a single literal. If the first literal is an escape string (`E'...'`), the second literal inherits the escape context! Nhé O's original lexer closed the string at the first `'` and parsed the second line as a separate, unvalidated statement.

**Resolution:**
The formal model was blind to PostgreSQL's lexical continuation quirk. The fix (`567520c`) updated the lexer to reject string continuations with `Status_Invalid_Syntax`, and a new SPARK contract was proved to prevent continuation processing.

---

### Case B: Crash Consistency and Commit-Order Redo (`R12-TX-02`, `R12-TX-04`)

**In the Formal Proof Model:**
SPARK proved that `Redo_WAL_Recovery` cleanly iterated through the 4KB slotted frame buffer without out-of-bounds indexing:
```ada
for F in 1 .. Frame_Count loop
   pragma Loop_Invariant (F in 1 .. Frame_Count);
   Apply_Frame (Buffer (F));
end loop;
```

**In the Crash Fault Injector:**
An automated crash oracle simulated thousands of power failures at every disk write. It identified two severe failure modes:
1. **Physical vs. Commit Order**: If Transaction 1 staged frames at frames 1..5 and Transaction 2 staged frames at frames 6..8, but Transaction 2 committed *before* Transaction 1, physically replaying frames 1..8 in WAL order replayed Transaction 1 after Transaction 2, resurrecting stale versions!
2. **Phantom Commits**: If a crash happened right after `pwrite` of the `WAL_Frame_Commit` barrier, but before the subsequent data pages were flushed to `.db`, the application observed an error, yet recovery replayed the transaction as committed.

**Resolution (`ADR-009`):**
1. Re-architected WAL recovery into a 2-pass algorithm: Pass 1 discovers committed transaction sequence numbers; Pass 2 replays only committed frames in strict commit-barrier sequence order.
2. Formally proved in SPARK that uncommitted or aborted frames are skipped (`BR-002`).

---

### Case C: Atomic File Locking and Symlink Safety (`R14-TX-01`, `R16-CA-01`)

**In the Formal Proof Model:**
SPARK treats filenames as static strings:
```ada
subtype File_Path_String is String (1 .. 512);
```
From the prover's perspective, reading or writing to a path is an uninterpreted pure operation.

**In the Linux OS Environment:**
Adversarial security review demonstrated that:
1. Two Python processes initializing the same database simultaneously could overwrite each other's slotted pages.
2. A malicious actor could plant a symlink at the reserved scratch path `/tmp/nhe_o_<pid>.wal.ckpt` pointing to `/etc/passwd`. When Nhé O called `nhe_o_close`, calling `unlink` or `open` on the path would truncate or delete the target file!
3. Calling `open(O_CREAT)` followed by `flock()` had an atomic race window where another process could unlink the file between creation and lock acquisition.

**Resolution (`ADR-020`, `ace0b89`, `d4640e4`):**
1. Contract-bound POSIX I/O (`src/nhe_o-io.adb`) was extended with `O_NOFOLLOW` and atomic `Create_Locked_File` acquiring `flock` directly on the `O_EXCL` descriptor.
2. `Check_Symbolic_Link` (`readlink(2)`) was implemented in 100% `SPARK_Mode (On)` to refuse symlinks without following them.

---

## 4. Trade-offs & alternatives

| Approach | Strengths | Weaknesses | When to Use |
|---|---|---|---|
| **Formal Verification Alone** | Mathematical certainty; 100% AoRTE; explores $2^{64}$ states; eliminates whole bug classes (overflows, memory corruption). | Blind to specification errors, environment quirks, OS races, and library bugs outside the model. | High-integrity kernels, safety-critical aerospace/rail, cryptographic primitives. |
| **Differential Fuzzing Alone** | Discovers subtle dialect discrepancies; validates real-world fidelity against golden standards. | Shallow state exploration; cannot prove absence of bugs; struggles with multi-step transaction paths. | Compilers, SQL parsers, protocol decoders, web browsers. |
| **Fault Injection Alone** | Tests real OS kernel interactions, hardware crashes, torn writes, and POSIX edge cases. | Slow execution; nondeterministic; difficult to achieve comprehensive branch coverage. | Filesystems, database storage engines, distributed consensus (Raft, Paxos). |
| **The Synthesis (Nhé O Approach)** | **Unbeatable defense-in-depth**: SPARK proves internal correctness; differential fuzzers and crash oracles prove external reality. | High engineering discipline required: fixes must satisfy both external oracles and formal proofs. | Mission-critical databases, embedded engines, financial ledgers. |

---

## 5. Where it lives in the project

- **Formal Proof Contracts & SPARK Core**:
  - `src/nhe_o-io.ad[sb]`: Contract-bound POSIX syscalls (`open`, `pread`, `pwrite`, `flock`, `readlink`, `fsync`).
  - `src/nhe_o-transaction.ad[sb]`: 2-pass commit-order WAL recovery, `NO-STEAL` staging, and CLOG MVCC.
  - `src/nhe_o-sql.ad[sb]`: Lexer, sanitizer, and fail-closed SQL descriptor validator.
- **Adversarial Audit & Remediation Log**:
  - `docs/epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md`: Detailed logs of Rounds 1–16 recording all 250 findings (84 in `v0.3.0` + 166 in `v0.4.0`).
- **Architectural Decisions**:
  - `ADR-002`: 100% `SPARK_Mode (On)` mandate.
  - `ADR-009`: Crash-consistent WAL protocol v2 (commit-order redo & torn-tail repair).
  - `ADR-010`: MVCC snapshot isolation by commit sequence numbers.
  - `ADR-015`: PostgreSQL-exact JSONB containment (`@>`).
  - `ADR-016`: PostgreSQL-faithful token-level SQL validation.
  - `ADR-020`: Multi-process database locking (`flock`) & symlink isolation.

---

## 6. Further reading

1. **Hoare, C. A. R.** (1969). *An Axiomatic Basis for Computer Programming*. Communications of the ACM, 12(10), 576–580.
2. **McKeeman, W. M.** (1998). *Differential Testing for Software*. Digital Technical Journal, 10(1), 100–107.
3. **Zheng, M., Tucek, J., Huang, D., Qin, F., Lillibridge, M., Yang, S., Rao, J., & Mount, M.** (2014). *Torturing Databases for Fun and Profit*. In 11th USENIX Symposium on Operating Systems Design and Implementation (OSDI '14).
4. **Barnes, J.** (2012). *SPARK: The Proven Approach to High Integrity and Security*. Altran Praxis.
5. **PostgreSQL Global Development Group**. *PostgreSQL 16 Documentation: Chapter 4 (SQL Syntax) and Chapter 8 (JSON Types)*.

---

## 7. Check yourself

1. **Why does 100% SPARK Gold formal verification not prevent SQL injection via string continuation?**
   *Answer:* Formal verification proves that the implementation adheres to its written contracts and never crashes. If the formal contract specifies that any unparsed character sequence results in a valid AST, the prover proves that contract. The prover does not know that PostgreSQL parses `'a'\n'b'` as `'ab'`, unless that grammar rule is explicitly formalized in the contract.

2. **What is the difference between physical WAL order and transaction commit order during crash recovery?**
   *Answer:* Under concurrent execution, Transaction A may append its data frames to the WAL first, followed by Transaction B's data frames. If Transaction B appends its commit barrier before Transaction A commits, Transaction B committed first. Replaying frames in physical WAL order would replay Transaction A's uncommitted or later-committed changes after Transaction B, violating serializability.

3. **Why can atomic file creation and locking not be modeled purely with standard `open()` in high-assurance systems?**
   *Answer:* Calling `open(O_CREAT)` followed by a separate `flock()` call leaves a time-of-check to time-of-use (TOCTOU) race window where an adversary or concurrent process can unlink or replace the file before the lock is acquired. True security requires atomic creation and locking (`O_EXCL` descriptor locking) and symlink refusal (`O_NOFOLLOW`).

4. **How do differential fuzzing and formal verification assist each other during a grooming epic?**
   *Answer:* Differential fuzzing quickly finds semantic omissions and corner-case behavioral discrepancies against golden reference systems without requiring formal models. Once a defect is identified, engineers patch the code and write a formal SPARK contract to prevent that defect class from ever returning. Formal proofs then guarantee that the patch did not introduce any runtime errors (AoRTE) across the entire system.
