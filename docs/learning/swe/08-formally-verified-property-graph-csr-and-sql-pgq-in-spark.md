# Formally Verified Property Graphs in SPARK: Bi-Directional CSR Adjacency, `SQL/PGQ MATCH` & Cycle-Safe Termination

> **Takeaway:** Upgrading an embedded multi-model engine to a full **Labeled Property Graph (LPG)** (`Nhe_O.Graph`, `ADR-008`) without violating SPARK's no-pointer / anti-aliasing / `Always_Terminates` mandates requires four deliberate architectural choices: (1) replacing Neo4j-style cyclic heap pointers with **KùzuDB-style Array-Indexed Double-Linked Adjacency Lists / Compressed Sparse Row (CSR)** over 4KB `"GRPH"` pages, (2) expressing declarative pattern queries via **ISO SQL:2023 `SQL/PGQ` (`MATCH (a)-[e:KIND*1..k]->(b)`)** paired with in-process native FFI primitives instead of full `openCypher` scripting bloat, (3) decoupling `Nhe_O.Graph` via `Nhe_O.Buffer_Pool` so non-graph workloads pay zero RAM overhead, and (4) proving termination on cyclic graphs via bounded iterative queues, `Visited` bitsets, and modular helper contracts.

**Tags:** swe, ai
**Related ADRs:** [ADR-001](../../DECISIONS.md), [ADR-006](../../DECISIONS.md), [ADR-008](../../DECISIONS.md)

---

## 1. Context — why add a full Property Graph engine to Nhé O?

Initially, `Nhe_O.RAG` supported a lightweight `1-Hop GraphRAG` link via a single `Related_Doc_Id : Optional_Doc_Id` field per document. While sufficient for `1-to-1` citation chains, real-world **Social Networks**, **Permission Graphs (ReBAC)**, **Fraud/Lineage Graphs**, and **Multi-Hop Knowledge GraphRAG** require:
- **Many-to-Many (`N-to-M`) Directed Relationships** (`Out_Edges` and `In_Edges`),
- **Edge & Vertex Labels + `JSONB_Document` Properties + `Float32` Weights**,
- **Multi-Hop (`1..k`) Traversal, Shortest Path (`BFS`/`Dijkstra`), and Mutual Neighbor Discovery ($N(u) \cap N(v)$)**.

More importantly, a native `Nhe_O.Graph` pillar acts as a **force multiplier for every existing Nhé O capability**:
1. **`Nhe_O.RAG` + `Nhe_O.HNSW`**: Turns flat 4096-D vector search into **Multi-Hop Knowledge GraphRAG** (propagating semantic similarity scores across $k$-hop entity relationships).
2. **`Nhe_O.SQL` + `Nhe_O.BTree`**: Replaces expensive recursive SQL `JOIN`s ($O(\log N)$ per hop) with $O(1)$ array-indexed adjacency hops.
3. **`Nhe_O.KV` + `Nhe_O.PubSub`**: Pairs topological graph vertices with sub-microsecond KV counters/TTL state and graph-routed `DURABLE` notifications.

---

## 2. Competitive advantages vs. Neo4j & Apache AGE

| Dimension | Neo4j | Apache AGE (PostgreSQL) | **Nhé O (`Nhe_O.Graph` in 100% SPARK)** |
|---|---|---|---|
| **Memory Safety & Formal Proof** | JVM runtime (`NullPointerException`, `OutOfMemoryError`, GC pauses) | Unverified C extension inside PostgreSQL | **100% `pragma SPARK_Mode (On);`** — mathematically proven free of buffer overflows, integer overflows, and dangling pointers (`BR-001`, `BR-008`). |
| **Termination on Cyclic Graphs (`A -> B -> A`)** | Unbounded path queries can hang or exhaust JVM heap | `WITH RECURSIVE` / Cypher loops can run indefinitely | **`Always_Terminates` proved by SMT solvers** via decreasing `Loop_Variant`s and bounded `Visited` sets. |
| **Multi-Model Fusion (Vector + Graph + JSONB + KV)** | Separate from Redis/Postgres; bolt-on vector index | Translates Cypher to nested SQL joins; separate from `pgvector` & Redis | **Single-Pass In-Process Execution**: 4096-D HNSW + $k$-hop Graph + `JSONB @>` + KV TTL in one address space. |
| **Deployment Footprint** | Multi-hundred-MB JVM server daemon | Full PostgreSQL server daemon + C extension | **Embedded single-file library (`libnhe_o.so` `< 300 KB`)**. |

---

## 3. The 4 technical challenges & their formal SPARK mitigations (`ADR-008`)

### Challenge 1: SPARK Forbids Cyclic Heap Pointers ("Index-Free Adjacency")
- **The Disadvantage**: Traditional graph databases like Neo4j represent edges as raw memory pointers between heap-allocated vertex structs. SPARK strictly forbids aliased cyclic heap pointers (`Access` types) because they make static ownership and absence-of-dangling-pointer proofs undecidable.
- **The Mitigation (Bi-Directional Array/CSR Adjacency on 4KB `"GRPH"` Pages)**:
  - Represent vertices by `Vertex_Id` (`1 .. Max_Graph_Vertices`) and edges by `Edge_Id` (`1 .. Max_Graph_Edges`), persisted on 4096-byte `"GRPH"` pages.
  - Each vertex stores `First_Out_Edge : Optional_Edge_Id` and `First_In_Edge : Optional_Edge_Id`.
  - Each directed edge `(Src_Vertex, Dst_Vertex, Label, Weight, Props)` stores `Next_Out_Edge : Optional_Edge_Id` (next edge leaving `Src_Vertex`) and `Next_In_Edge : Optional_Edge_Id` (next edge entering `Dst_Vertex`).
  - **Why this wins**: Stepping from a vertex to its outgoing or incoming neighbors is an $O(1)$ array index lookup with **zero pointer aliasing**, 100% SPARK range verification, and superior CPU L1/L2 cache locality (the same insight behind modern embedded graph engines like KùzuDB).

### Challenge 2: Full `openCypher` Scripting Surface vs. Parser & VC Bloat
- **The Disadvantage**: Implementing 100% of Neo4j's `openCypher` language—including scripting list comprehensions (`UNWIND [x IN list | ...]`), string/date libraries, and `APOC` procedures—would turn `Nhe_O.SQL` into a massive interpreter and explode `gnatprove` verification conditions.
- **The Mitigation (`SQL/PGQ MATCH` + Native Composable FFI Primitives)**:
  - **Does trimming Cypher's scripting sugar reduce graph power? No!** Graph power comes from the **LPG data model, bi-directional $O(1)$ adjacency, and traversal/path/subgraph operators**, not Cypher's string/list helper functions.
  - For declarative queries, support **ISO SQL:2023 `SQL/PGQ` `MATCH (a:L1)-[e:T*1..k]->(b:L2)`** directly inside `Nhe_O.SQL` alongside `WHERE meta @> ...` and `ORDER BY emb <=> $1`.
  - For complex iterative algorithms, expose composable native operators (`Traverse_K_Hop_BFS`, `Shortest_Path_Dijkstra`, `Find_Mutual_Neighbors`, `Propagate_Graph_Scores`) directly over the in-process C ABI / Python SDK—executing at native Ada/C speed with zero TCP round-trip or query-parsing overhead.

### Challenge 3: Preventing Static RAM Bloat in Non-Graph Workloads
- **The Disadvantage**: Stuffing multi-edge adjacency arrays directly inside `Nhe_O.RAG.RAG_Document_Entry` would enlarge `RAG_Engine` for users who only want simple document RAG or KV caching.
- **The Mitigation (Decoupled `Nhe_O.Graph` Paged via `Nhe_O.Buffer_Pool`)**:
  - Implement `Nhe_O.Graph` as a standalone sibling package (`src/nhe_o-graph.ad[sb]`) backed by 4KB `"GRPH"` pages managed by Epic 05's Clock-Sweep `Nhe_O.Buffer_Pool`.
  - `Nhe_O.RAG` links documents to graph vertices via `Vertex_Id` / `Doc_Id` only when Multi-Hop GraphRAG is invoked.

### Challenge 4: Proving `Always_Terminates` on Cyclic Graphs Without SMT Timeouts
- **The Disadvantage**: Social and knowledge graphs naturally contain cycles (`Alice -[:FOLLOWS]-> Bob -[:FOLLOWS]-> Alice`). Naive recursion violates SPARK termination checks or causes SMT solver blowup.
- **The Mitigation (Bounded Iterative Queue + `Visited` Bitset + Modular Contracts)**:
  - Every traversal (`Traverse_K_Hop_BFS`, `Shortest_Path_BFS`, `Shortest_Path_Dijkstra`) uses a fixed-capacity ring queue (`Queue : Vertex_Queue_Array`) and a `Visited : Vertex_Visited_Array := [others => False]` guard.
  - Because a vertex is enqueued only when `not Visited (V)` (after which `Visited (V) := True`), the queue tail is strictly bounded by `Max_Graph_Vertices`, and the outer loop (`for Q_Head in 1 .. Max_Graph_Vertices loop exit when Q_Head > Q_Tail; ...`) is trivially proven to terminate by `gnatprove`!

---

## 4. Where it lives in the project

- **ADR**: [`ADR-008`](../../DECISIONS.md) — *Native Labeled Property Graph Engine (`Nhe_O.Graph`), Bi-Directional CSR Adjacency (`"GRPH"`), `SQL/PGQ MATCH` & Multi-Hop GraphRAG*.
- **Domain Rule**: [`BR-008`](../../domain/business-rules.md) in `docs/domain/business-rules.md`.
- **Epic Plan**: [`docs/epics/06-property-graph-and-multi-hop-graphrag/PROGRESS.md`](../../epics/06-property-graph-and-multi-hop-graphrag/PROGRESS.md).

---

## 5. Check yourself

1. **How does a bi-directional index-based adjacency list (`First_Out_Edge`/`Next_Out_Edge` + `First_In_Edge`/`Next_In_Edge`) achieve $O(1)$ neighbor traversal like Neo4j while remaining 100% compliant with SPARK's anti-aliasing rules?**
2. **Why does supporting ISO SQL:2023 `SQL/PGQ` `MATCH (a)-[e]->(b)` + in-process C/Python graph primitives preserve 100% of Neo4j/Apache AGE's core graph power without the parser bloat of full `openCypher`?**
3. **How do `Visited : Vertex_Visited_Array` and a bounded ring queue guarantee `Always_Terminates` on arbitrary cyclic graphs?**
