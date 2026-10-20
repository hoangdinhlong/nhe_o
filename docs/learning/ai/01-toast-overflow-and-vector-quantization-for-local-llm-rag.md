# 4KB TOAST Overflow Pages & Vector Quantization for Universal Local LLM RAG

> **Takeaway:** Pairing 4KB primary slotted pages with PostgreSQL-style TOAST overflow chains (`TOAST_Pointer` / `Root_Overflow_Page`) and vector quantization (`Float32`, `Int8`, `Binary`) allows an embedded database to support arbitrary embedding dimensions up to 4096-D and multi-kilobyte RAG parent chunks while keeping metadata filtering fast and reducing HNSW memory footprints by 4x–32x alongside local LLMs.

**Tags:** ai, swe
**Related ADRs:** [ADR-003](../../DECISIONS.md)

---

## 1. Context — the problem

When running local Large Language Models — such as **Qwen 3.8 27B** or **Qwen 3.8 35B-A3B** — on a workstation or edge server, a Retrieval-Augmented Generation (RAG) storage engine faces three competing hardware and data constraints:

1. **Wide Variation in Embedding Dimensions**:
   - Compact embedding models (e.g., `all-MiniLM-L6-v2` at `384-D`, `BAAI/bge-m3` or `Qwen3-Embedding-0.6B` at `1024-D`) take `1.5 KB` to `4 KB` per raw `Float32` vector.
   - Frontier and large local embedding models (e.g., `text-embedding-3-large` at `3072-D`, `Qwen3-Embedding-8B` at `4096-D`) require **`12 KB` to `16 KB` per raw `Float32` vector** (`4096 * 4 bytes = 16,384 bytes`).
2. **Rich RAG Payloads Exceed Fixed Page Sizes**:
   - Modern RAG architectures — **Hybrid Search** (dense vector + BM25 lexical + `JSONB` metadata filtering), **Parent-Document / Contextual RAG** (storing both small child chunks and multi-kilobyte parent passages), and **GraphRAG** — store `2 KB` to `16 KB` of text and `JSONB` metadata alongside the embedding.
   - Even if a database increased its fixed page size from `4 KB` to `16 KB`, a single `4096-D` `Float32` vector (`16 KB`) plus a `4 KB` parent text chunk (`20 KB` total) would still overflow a `16 KB` page.
3. **VRAM / System RAM Contention with the Local LLM**:
   - A 27B or 35B-A3B local LLM already consumes `16 GB` to `28 GB` of unified memory or VRAM/RAM for model weights and KV cache. If the vector index (HNSW) stores every embedding solely as uncompressed `Float32`, indexing one million `4096-D` vectors would consume `16 GB` of RAM for raw vectors alone — starving the LLM.

---

## 2. The concept, explained simply

Database engines and vector search systems solve these three problems using two complementary techniques:

### A. Primary 4KB Slotted Pages + TOAST Overflow Page Chains
Inspired by PostgreSQL's **TOAST** (*The Oversized-Attribute Storage Technique*):
- **Primary Slotted Page (`4096 bytes`)**: Stores compact relational columns, `JSONB` filter metadata, MVCC transaction headers (`Xmin`, `Xmax`), and small inline attributes (`<= 512 bytes`).
- **16-Byte Inline TOAST Pointer**: When an attribute (such as a `4096-D` `Float32` vector or an `8 KB` parent document chunk) exceeds the inline threshold, the primary tuple stores only a **16-byte descriptor** (`Root_Overflow_Page`, `Total_Byte_Length`, `Chunk_Count`, `Payload_CRC32`) instead of the multi-kilobyte payload.
- **Linked 4KB TOAST Overflow Pages**: The oversized payload is split into fixed `4096-byte` overflow pages linked via `Next_Page_Id : Valid_Page_Id` and protected by per-page CRC32 checksums.

**Why does this make Hybrid RAG so fast?**
When a RAG query filters documents by metadata (`SELECT chunk FROM docs WHERE meta @> '{"project": "nhe_o"}' ORDER BY embedding <-> $1 LIMIT 5`), the engine scans primary 4KB pages that pack dozens of rows per page. Cold 16KB vectors sitting in TOAST overflow pages are **never read from disk** for rows that fail the `JSONB` filter!

### B. Multi-Precision Vector Quantization (`Float32` · `Int8` · `Binary`)
To coexist with memory-hungry local LLMs, a vector engine supports three representations for any dimension `D in 1 .. 4096`:
1. **`Float32` (4 bytes / dim)**: Exact IEEE-754 single precision (`16 KB` at `4096-D`). Used for exact re-ranking or ground-truth storage in TOAST pages.
2. **Scalar Quantization `Int8` (`SQ8`, 1 byte / dim)**: Maps each `Float32` component in `[Min_Val .. Max_Val]` into a signed 8-bit integer `-127 .. 127` (`4 KB` at `4096-D` — **4x RAM reduction** with `>98%` recall).
3. **Binary Quantization (`BQ`, 1 bit / dim)**: Encodes the sign of each component (`1` if `x > 0.0` else `0`) into packed 64-bit words (`512 bytes` at `4096-D` — **32x RAM reduction**!) and computes distance via hardware-friendly XOR + population count (`Hamming_Distance`).

```text
+-----------------------------------------------------------------------+
| Primary 4KB Slotted Page (Fast Metadata & Hybrid Filter Scan)         |
| +-------------------------------------------------------------------+ |
| | Tuple: id=42 | Xmin=10 | meta={"lang":"vi"} | Binary_Vec (512B)   | |
| |        full_vec_ptr = [TOAST Page #105, Len=16384B, Chunks=5]     | |
| +-------------------------------------------------------------------+ |
+-----------------------------------|-----------------------------------+
                                    | (Only dereferenced for Top-K re-ranking!)
                                    v
        +-------------------+    +-------------------+    +-------------------+
        | TOAST Page #105   |--->| TOAST Page #106   |--->| TOAST Page #107.. |
        | Float32[1..1020]  |    | Float32[1021..2040|    | ...               |
        +-------------------+    +-------------------+    +-------------------+
```

By keeping the `512-byte` Binary Quantized (or `Int8`) vector inline inside the HNSW graph and deferring the `16 KB` `Float32` TOAST read to the final Top-K two-stage re-ranking pass, **Nhé O** achieves sub-millisecond ANN search with minimal RAM usage.

---

## 3. A concrete example

Consider a **4096-dimensional** embedding from `Qwen3-Embedding-8B`:

```ada
--  1. Storage footprint comparison for a 4096-D vector in Nhé O:
--     * Float32 (Full precision) : 4096 * 4 bytes = 16,384 bytes (5 TOAST 4KB pages)
--     * Int8    (Scalar quant.)  : 4096 * 1 byte  =  4,096 bytes (1 TOAST 4KB page)
--     * Binary  (1-bit Hamming)  : 4096 / 8 bits  =    512 bytes (Fits INLINE in 4KB page!)
```

During a **Two-Stage Matryoshka / Quantized RAG Query**:
1. **Stage 1 (Candidate Retrieval — HNSW over `Binary` or `Int8`)**:
   - The query vector is quantized to `Binary` (`512 bytes`) or `Int8`.
   - The HNSW index traverses in-memory nodes using Hamming or `Int8` distance to select the top `K_Candidates = 50` tuple IDs in microseconds.
2. **Stage 2 (Exact Re-ranking & Context Fetch — TOAST `Float32` + Parent Chunk)**:
   - Only for those `50` candidates, `Nhe_O.Transaction` follows the 16-byte `TOAST_Pointer` to read the exact `Float32` vector and parent text chunk from disk, computes exact Cosine/L2 distance (`<=>` / `<->`), and returns the top `K = 5` passages to the local Qwen LLM.

---

## 4. Trade-offs & alternatives

| Approach | Pros | Cons | When to choose |
|---|---|---|---|
| **1. Fixed 4KB pages only (`Max_Vector_Dim = 256`)** | Zero overflow-chain complexity; every row is a single `pread`. | Cannot store `768-D`, `1024-D`, `3072-D`, or `4096-D` embeddings or long RAG text chunks. | Toy demos or tiny keyword/sensor databases. |
| **2. Increase fixed page size to 16KB or 32KB (no TOAST)** | Fits a single `1536-D` or `3072-D` vector in one page without chaining. | Still fails when a `4096-D` vector (`16 KB`) is stored alongside a parent text chunk (`4 KB`); causes severe read/write amplification for small KV/SQL rows. | Dedicated single-column vector blobs with no relational/JSONB workloads. |
| **3. 4KB Primary Pages + 4KB TOAST Overflow Chains + `Float32`/`Int8`/`Binary` Quantization (Nhé O's choice)** | Supports any embedding up to `4096-D` plus large parent chunks; keeps `JSONB`/relational scans fast; cuts HNSW RAM by 4x–32x for local LLMs; matches OS 4KB page size. | Requires deterministic TOAST page allocation, chaining, and CRC32 verification across linked pages. | Universal multi-model RAG engines running alongside local LLMs (`ADR-003`). |

---

## 5. Where it lives in the project

- **ADR**: [`ADR-003`](../../DECISIONS.md) — *4KB Slotted Pages with TOAST Overflow Chains, 4096-D Vectors & Quantization for Universal RAG*.
- **Domain Invariants**:
  - [`BR-003`](../../domain/business-rules.md) — *PostgreSQL Vector, Scale-Aware Quantization & RFC 8259 JSONB Integrity*.
  - [`BR-006`](../../domain/business-rules.md) — *4KB `"SLOT"` Primary Pages, `"TOAS"` Overflow Chains, `"RMET"` Metadata & `"VTST"` Stage-2 Vector Re-Ranking*.
- **Active Epic**: [`docs/epics/02-storage-indexing-and-rag-executor/PROGRESS.md`](../../epics/02-storage-indexing-and-rag-executor/PROGRESS.md) — Tasks 1, 2, 4, and 6.
- **Code Modules**: [`src/nhe_o-vector.ads`](../../../src/nhe_o-vector.ads) and [`src/nhe_o-transaction.ads`](../../../src/nhe_o-transaction.ads).

---

## 6. Further reading

- *PostgreSQL Internals — Chapter 68.2: TOAST (The Oversized-Attribute Storage Technique)*, PostgreSQL Official Documentation.
- *pgvector (`halfvec`, `bit`, and Binary Quantization with HNSW re-ranking)*, pgvector Documentation.
- *Kusupati et al. (2022) — Matryoshka Representation Learning (MRL)*, NeurIPS 2022.

---

## 7. Check yourself

1. **Why is simply increasing the database page size from `4 KB` to `16 KB` insufficient for a `4096-D` `Float32` embedding stored alongside a parent-document RAG text chunk?**
2. **How does storing oversized vectors in TOAST overflow pages speed up Hybrid RAG queries that filter on `JSONB` metadata (`WHERE meta @> ...`)?**
3. **How much memory does a `4096-D` vector consume in `Float32`, `Int8`, and `Binary` (1-bit) encodings, and why can a `4096-D` `Binary` vector fit directly inside a primary 4KB slotted page?**
4. **How does two-stage quantized retrieval (Binary/Int8 HNSW candidate search followed by TOAST `Float32` re-ranking) preserve high recall while saving RAM for a local LLM?**
