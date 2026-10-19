# Two-Stage 4096-D Vector TOAST Re-Ranking, Scale-Aware SQ8 & Distance-Pruned HNSW in SPARK

> **Takeaway:** Storing full 4096-dimensional `Float32` vectors (`16 KB` each) directly inside every in-memory HNSW graph node exhausts embedded RAM and stack frames, while relying solely on truncated prefixes or unscaled `Int8` quantization degrades retrieval accuracy. By combining **Stage-1 HNSW candidate generation** (using 64-D Matryoshka prefixes, scale-aware `Int8` SQ8, or 4096-bit Binary Hamming with distance-pruned small-world edges) with **Stage-2 Exact Re-Ranking** over full 4096-D `Float32` embeddings persisted in 4KB TOAST overflow chains (`"VTST"`), **Nhé O** achieves full-precision top-$k$ recall within a statically bounded RAM footprint in 100% `SPARK_Mode (On)`.

**Tags:** swe, ai
**Related ADRs:** [ADR-003](../../DECISIONS.md), [ADR-006](../../DECISIONS.md)

---

## 1. Context — the problem

During the post-Epic-03 adversarial review (`CRIT-06`, `CRIT-07`, `Q-003` in [`ADVERSARIAL-REVIEW.md`](../../epics/04-post-epic-03-grooming-and-hardening/ADVERSARIAL-REVIEW.md)), three subtle vector-search and RAG issues surfaced:

1. **RAM vs. Precision Trade-off for 4096-D Embeddings (`Q-003` / `CRIT-07`)**:
   - A single 4096-D `Float32` vector requires `16,384 bytes` (`16 KB`), which is $4\times$ larger than a 4096-byte database page!
   - To keep the in-memory `HNSW_Node` compact (`~1.1 KB`), each node stores a 64-D `Float32` Matryoshka prefix (`Float_Pref`), a 64-D `Int8` SQ8 prefix (`Int8_Pref`), and a full 4096-bit `Binary` signature (`Bin_Vec`).
   - However, if two documents share an identical 64-D prefix and differ only in dimensions `65..4096`, Stage-1 HNSW alone cannot distinguish them in `Float32` or `Int8` mode!
2. **Unscaled `Int8` SQ8 Distance Distortion (`CRIT-07`)**:
   - Scalar quantization (`Quantize_To_Int8`) normalizes each vector $V$ by its own dynamic range $\text{Scale}_V = \max_i |V_i| / 127$.
   - Comparing raw `Int8` integers `(A_i - B_i)^2` without multiplying by each vector's `Scale` factor computes distance in incompatible coordinate spaces whenever $\text{Scale}_A \neq \text{Scale}_B$.
3. **Chronological Neighbor Cap & Duplicate `Doc_Id` Nodes in HNSW (`CRIT-06`)**:
   - Simply connecting a new HNSW node to the first `Max_Neighbors = 4` nodes in insertion order and ignoring subsequent edges once `Degree = 4` freezes early nodes into a clique and starves later nodes.
   - Re-ingesting an existing `Doc_Id` must update its HNSW node in-place rather than allocating a duplicate graph node that pollutes top-$k$ results.

---

## 2. The concept, explained simply

### 1. Scale-Aware `Int8` SQ8 Distance (`Dequantize_Int8_Scalar`)
Each `Quantized_Int8_Vector` (and each `HNSW_Node`) stores its quantization multiplier `Scale : Non_Negative_Float`. When computing `Int8` distance between node $A$ and query $Q$, each component is reconstructed into `Vector_Component` (`[-1.0e6 .. 1.0e6]`) using `Dequantize_Int8_Scalar`:

$$\hat{A}_i = \text{clamp}(\text{Int8\_Pref}_A[i] \times \text{Scale}_A,\; -10^6, +10^6), \quad \hat{Q}_i = \text{clamp}(Q[i] \times \text{Scale}_Q,\; -10^6, +10^6)$$

This preserves the `4x` RAM savings of `Int8` storage while restoring true Euclidean scale across vectors of different magnitudes.

### 2. Distance-Pruned HNSW Small-World Edges (`Add_Edge_Pruned`) & Multi-Wave Beam Search
When inserting or updating a vector in `Nhe_O.HNSW`:
1. **`Doc_Id` Deduplication**: `Insert_Vector` first scans `1 .. Index.Node_Count`. If a node with `Nodes (I).Doc_Id = Doc_Id` already exists, it updates that node's vector representations in-place.
2. **Nearest-Neighbor Edge Selection**: For a new node at `Target_Id`, `Insert_Vector` ranks existing nodes on layer $L$ by `Node_Pair_Distance` and connects `Target_Id` to the closest neighbors.
3. **Distance-Pruned Reverse Edges (`Add_Edge_Pruned`)**: When adding a reverse edge `Src_Id -> Target_Id` on layer $L$:
   - If `Degree < Max_Neighbors (4)`, `Target_Id` is appended directly (or reclaims any deactivated neighbor slot).
   - If `Degree = Max_Neighbors`, `Add_Edge_Pruned` finds the **farthest** existing neighbor `Worst_Slot` of `Src_Id`. If `Node_Pair_Distance (Src_Id, Target_Id) < Worst_Dist`, `Target_Id` replaces `Worst_Slot`, maintaining navigable small-world connectivity.
4. **Greedy Upper-Layer Descent + 4-Wave Beam Expansion (`Search_KNN`)**: `Search_KNN` descends greedily from `Top_Layer` down to layer `2`, then performs 4 waves of neighbor expansion on layer `1` starting from the entry seed.

### 3. Two-Stage 4096-D Vector TOAST Exact Re-Ranking (`ADR-006`)
To support full 4096-D precision without blowing up HNSW RAM:
- **On `Ingest_Document`**:
  - `Encode_Vector_TOAST` serializes the full `Dim`-dimensional `Float32` embedding (`"VTST"` 4-byte magic + big-endian `Dim` + tiered scientific `Float32` words) into a `TOAST_Payload_Buffer` (`up to 16,392 bytes`) and writes it to a 4KB TOAST overflow chain (`Vec_Toast_Ptr`), persisted inside the document's primary `"SLOT"` tuple on Page 1.
- **On `Execute_Hybrid_RAG_Query`**:
  - **Stage 1 (Fast RAM Candidate Generation)**: `HNSW.Search_KNN` (plus MVCC-visible `PK_Tree`-verified document evaluation) scores candidates in RAM.
  - **Stage 2 (On-Disk TOAST Exact Re-Ranking)**: Whenever `Engine.Dim > 64` (or a historical prior tuple version is resolved) and a candidate has a valid `Vec_Toast_Ptr`, `Evaluate_Doc_Candidate` reads the `"VTST"` chain via `Read_TOAST_Chain`, decodes the full `4096-D` `Vector_Value` via `Decode_Vector_TOAST`, and recomputes exact `L2_Distance (Query_Vec, Full_Vec)` (or full-dimension `Int8_L2_Distance` / `Hamming_Distance`) before inserting the candidate into the sorted top-$k$ result list!

```text
Query Vector (4096-D)
       |
       +---> [Stage 1: In-RAM HNSW Graph (`Nhe_O.HNSW`)]
       |     64-D Prefix / Scale-Aware SQ8 / 4096-bit Binary
       |     + MVCC CLOG Visibility + JSONB `@>` Filter
       |
       +---> [Stage 2: Exact TOAST Re-Ranking (`Nhe_O.RAG`)]
             Reads `"VTST"` 4KB TOAST Chain (`Vec_Toast_Ptr`)
             Recomputes exact 4096-D `L2_Distance` / `Int8_L2_Distance` -> Final Top-K Hits
```

---

## 3. Concrete example: `"VTST"` Binary Layout & Stage-2 Re-Ranking

In [`src/nhe_o-vector.adb`](../../../src/nhe_o-vector.adb), `Encode_Vector_TOAST` packs a `Vector_Value` (`1 .. 4096` floats) into a deterministic big-endian byte buffer (`8 + Dim * 4` bytes, up to `16,392 bytes`):

| Byte Offset | Field | Description |
|---|---|---|
| `1..4` | `Magic` | ASCII `"VTST"` (`16#56#`, `16#54#`, `16#53#`, `16#54#`) |
| `5..8` | `Dim` | Big-endian `Unsigned_32` dimension (`1 .. 4096`) |
| `9 .. 8 + 4*Dim` | `Elements` | Big-endian 15-tier scientific `Float32` words (`Encode_Vector_TOAST` / `Decode_Vector_TOAST`: `Bit 31 = Sign`, `Bits 27..30 = Exp_Code 0..14` stepping by $10^1$ per tier with `14 = 0.0`, `Bits 0..26 = Mantissa 0..10^8`) |

During `Decode_Vector_TOAST`, `Magic = "VTST"` and `Raw_Dim = Expected_Dim` are verified first, and each restored `Float32` word is bounded by construction to `Vector_Component` (`-1.0e6 .. 1.0e6`) while preserving 8 decimal digits of precision across `[1.0e-7, 1.0e6]`, allowing `gnatprove` to prove 100% of all run-time and functional contract checks (`Post => (if Valid then V.Dim = Expected_Dim)`) without `Ada.Unchecked_Conversion`.

---

## 4. Trade-offs & alternatives

| Design Choice | RAM per 32-Node Graph | 4096-D Tail Precision (`dims 65..4096`) | Disk I/O During Query |
|---|---|---|---|
| **1. Full 4096-D `Float32` in HNSW RAM** | `> 550 KB` (exceeds stack frame budget) | Exact | 0 page reads |
| **2. 64-D Prefix Only in HNSW RAM** | `~36 KB` | Blind to dimensions `65..4096` in `Float32`/`Int8` mode | 0 page reads |
| **3. Two-Stage HNSW RAM + `"VTST"` TOAST Re-Ranking (Nhé O's choice)** | `~36 KB` | **Exact 4096-D L2 / SQ8** | Reads `"VTST"` TOAST chain only for filtered candidates |

---

## 5. Where it lives in the project

- **ADR**: [`ADR-006`](../../DECISIONS.md) — *Two-Stage 4096-D Hybrid RAG (HNSW RAM Stage-1 + TOAST Full-Vector Stage-2 Exact Re-Ranking) & Primary 4KB `"SLOT"` Pages*.
- **Domain Specification**: [`docs/domain/storage-and-wal-format.md`](../../domain/storage-and-wal-format.md) (Section 3.3 `"VTST"` Vector TOAST Payload).
- **Code Modules**:
  - [`src/nhe_o-vector.ads`](../../../src/nhe_o-vector.ads) & [`src/nhe_o-vector.adb`](../../../src/nhe_o-vector.adb) (`Int8_L2_Distance`, `Encode_Vector_TOAST`, `Decode_Vector_TOAST`).
  - [`src/nhe_o-hnsw.ads`](../../../src/nhe_o-hnsw.ads) & [`src/nhe_o-hnsw.adb`](../../../src/nhe_o-hnsw.adb) (`Dequantize_Int8_Scalar`, `Node_Distance`, `Node_Pair_Distance`, `Add_Edge_Pruned`, `Insert_Vector`, `Search_KNN`).
  - [`src/nhe_o-rag.ads`](../../../src/nhe_o-rag.ads) & [`src/nhe_o-rag.adb`](../../../src/nhe_o-rag.adb) (`Ingest_Document`, `Evaluate_Doc_Candidate`, `Execute_Hybrid_RAG_Query`).

---

## 6. Further reading

- *Malkov & Yashunin (2018) — Efficient and robust approximate nearest neighbor search using Hierarchical Navigable Small World graphs (IEEE TPAMI)*.
- *Kusupati et al. (2022) — Matryoshka Representation Learning (NeurIPS)*.
- *PostgreSQL Internals — TOAST (The Oversized-Attribute Storage Technique)*.

---

## 7. Check yourself

1. **Why does comparing raw `Int8` quantized components `(A_i - B_i)^2` without using each vector's `Scale` factor distort Euclidean distances?**
2. **How does `Add_Edge_Pruned` preserve small-world graph navigability when a node's neighbor list reaches `Max_Neighbors = 4`?**
3. **Why does Nhé O store the full `>64-D` `Float32` embedding in a `"VTST"` 4KB TOAST chain while keeping only a 64-D prefix + 4096-bit binary vector inside `HNSW_Node`?**
4. **How does `Decode_Vector_TOAST` guarantee to `gnatprove` that arbitrary bytes read from a disk TOAST chain will never produce a `Constraint_Error` on `Vector_Component` (`-1.0e6 .. 1.0e6`)?**
