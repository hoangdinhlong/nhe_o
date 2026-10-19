# Epic 06 — Formally Verified Property Graph Engine (`Nhe_O.Graph`), `SQL/PGQ MATCH` & Multi-Hop GraphRAG

**Goal:** Build upon Epics 01–05 by implementing a first-class, 100% formally verified **Labeled Property Graph (LPG) Engine (`Nhe_O.Graph`)** (`ADR-008`, `BR-008`) with bi-directional index-based adjacency (`Out_Edges` / `In_Edges` CSR over 4KB `"GRPH"` pages), MVCC snapshot isolation (`Xmin`/`Xmax` + `CLOG`), `JSONB_Document` vertex/edge properties, multi-hop traversal (`1..k` hops), Shortest Path (`BFS` & weighted `Dijkstra`), Mutual Neighbors / Social Graph discovery ($N(u) \cap N(v)$), ISO SQL:2023 `SQL/PGQ` `MATCH (a)-[e:KIND*1..k]->(b)` query integration in `Nhe_O.SQL`, and **Multi-Hop Knowledge GraphRAG** in `Nhe_O.RAG` — all proven at 100% SPARK Stone, Bronze, Silver (AoRTE + `Always_Terminates` even on cyclic graphs), and Gold contracts (`0 unproved`, `0 warnings`).

**Definition of done:**
1. `Nhe_O.Graph` (`src/nhe_o-graph.ads` and `src/nhe_o-graph.adb`, 100% `SPARK_Mode (On)`) implements labeled vertices and directed weighted edges with `JSONB_Document` properties, MVCC `Xmin`/`Xmax` visibility, bi-directional index-based adjacency lists (`First_Out_Edge`/`Next_Out_Edge` and `First_In_Edge`/`Next_In_Edge`), and deterministic 4096-byte `"GRPH"` page serialization with IEEE 802.3 CRC32 verification.
2. `Nhe_O.Graph` provides formally proven, guaranteed-terminating (`Always_Terminates`) graph algorithms over arbitrary cyclic graphs:
   - `Traverse_K_Hop_BFS` (`1..k` hops, outgoing `->`, incoming `<-`, or undirected `-`, filtered by vertex/edge labels and `JSONB @>` containment),
   - `Shortest_Path_BFS` and `Shortest_Path_Dijkstra` (non-negative `Float32` edge weights),
   - `Find_Mutual_Neighbors` ($N(u) \cap N(v)$ common neighbors / triangle discovery for social networks & recommendations),
   - `Compute_PageRank_Bounded` / degree centrality & multi-hop score propagation.
3. `Nhe_O.SQL` (`src/nhe_o-sql.ad[sb]`) supports ISO SQL:2023 `SQL/PGQ` `MATCH (a:Label)-[e:KIND*1..k]->(b:Label)` pattern descriptors seamlessly combined with `WHERE` (`JSONB @>`) and `ORDER BY` (`VECTOR <-> / <=>`).
4. `Nhe_O.RAG` (`src/nhe_o-rag.ad[sb]`) upgrades from single-edge `1-Hop` expansion to **Multi-Hop Knowledge GraphRAG**, propagating similarity scores from Stage-1/Stage-2 4096-D Vector hits across $k$-hop labeled graph neighborhoods.
5. `Nhe_O.C_API` (`include/nhe_o.h`, `lib/libnhe_o.so`), `bindings/python/nhe_o.py`, and `src/nhe_o_main.adb` expose precondition-free defensive C ABI and Python SDK methods (`graph_upsert_vertex`, `graph_upsert_edge`, `graph_delete_edge`, `graph_traverse_bfs`, `graph_shortest_path`, `graph_mutual_neighbors`, `rag_graph_query`) verified by a new runtime verification suite.
6. `gnatprove -P nhe_o.gpr --mode=all --level=2 -j24` proves 100% of all flow, AoRTE (Silver), termination (`Always_Terminates`), and functional contract (Gold) verification conditions (`0 unproved` checks, `0 warnings`).

Status legend: ☐ todo · ◐ in progress · ☑ done

| # | Task | Status | Tests |
|---|------|--------|-------|
| 1 | Implement `Nhe_O.Graph` data model, MVCC visibility, bi-directional CSR/adjacency lists, and 4KB `"GRPH"` CRC32 page serialization (`src/nhe_o-graph.ad[sb]` in 100% `SPARK_Mode (On)`) | ☐ | — |
| 2 | Implement formally verified, cycle-safe (`Always_Terminates`) graph operators in `Nhe_O.Graph`: `Traverse_K_Hop_BFS`, `Shortest_Path_BFS`, `Shortest_Path_Dijkstra`, `Find_Mutual_Neighbors`, and `Propagate_Graph_Scores` | ☐ | — |
| 3 | Extend `Nhe_O.SQL` with ISO SQL:2023 `SQL/PGQ` `MATCH (a:L1)-[e:T*1..k]->(b:L2)` pattern parsing and integrate `Nhe_O.Graph` with `Nhe_O.RAG` for Multi-Hop Knowledge GraphRAG | ☐ | — |
| 4 | Expose `Nhe_O.Graph` and Multi-Hop GraphRAG across `Nhe_O.C_API` (`include/nhe_o.h`, `lib/libnhe_o.so`), Python SDK (`bindings/python/nhe_o.py`), and CLI verification suite (`src/nhe_o_main.adb`) | ☐ | — |
| 5 | Prove 100% SPARK Stone, Bronze (Flow), Silver (AoRTE + `Always_Terminates`), and Gold contracts across `Nhe_O.Graph`, `Nhe_O.SQL`, `Nhe_O.RAG`, and `Nhe_O.C_API` via `gnatprove -j24` (`0 unproved`, `0 warnings`) | ☐ | — |

## Technical challenges / trade-offs & formal SPARK mitigations (`ADR-008`)

1. **SPARK Anti-Aliasing Mandate vs. Heap Pointer-Chasing**:
   - *Challenge*: Neo4j uses raw cyclic heap pointers for index-free adjacency, which violates SPARK's ownership/anti-aliasing rules (`BR-001`).
   - *Mitigation*: Use KùzuDB-style **Array-Indexed Double-Linked Adjacency Lists / Compressed Sparse Row (CSR)** over 4KB `"GRPH"` pages (`First_Out_Edge`, `Next_Out_Edge`, `First_In_Edge`, `Next_In_Edge`), achieving $O(1)$ neighbor hops, superior CPU cache locality, and 100% SPARK provability.
2. **Cypher Scripting Bloat vs. `gnatprove` VC Complexity**:
   - *Challenge*: Implementing Neo4j's full scripting surface (`UNWIND` comprehensions, `APOC`, arbitrary multi-`WITH` pipelines) would bloat the parser and SMT proof obligations without adding core graph power.
   - *Mitigation*: Support declarative pattern matching via **ISO SQL:2023 `SQL/PGQ` (`MATCH (a)-[e:KIND*1..k]->(b)`)** inside `Nhe_O.SQL`, paired with zero-overhead in-process C ABI / Python SDK graph primitives.
3. **Zero Impact on Non-Graph Memory Footprints**:
   - *Challenge*: Embedding multi-edge lists directly inside `RAG_Document_Entry` would inflate `RAG_Engine` for users who only need document RAG or KV caching.
   - *Mitigation*: Keep `Nhe_O.Graph` as a decoupled module paged via `Nhe_O.Buffer_Pool`, linking to `Nhe_O.RAG` and `Nhe_O.KV` by `Vertex_Id` / `Doc_Id`.
4. **Termination & VC Modularity on Cyclic Graphs**:
   - *Challenge*: Cyclic graphs (`A -> B -> A`) can cause non-termination in recursive traversals and VC blowup in `gnatprove`.
   - *Mitigation*: Use iterative bounded queues with `Visited_Vertex_Set` boolean arrays, explicit `Loop_Variant`s (`Always_Terminates`), and modular helper contracts (`with Post => ..., Global => null`, per Lesson 07).

## Notes / sequencing
- Sequenced immediately after **Epic 05 (`05-catalog-buffer-pool-and-sql-executor`)** so `Nhe_O.Graph` can leverage `Nhe_O.Catalog` and `Nhe_O.Buffer_Pool` for 4KB `"GRPH"` page management, followed by a dedicated Grooming & Hardening Epic per `AGENTS.md`.

## Open questions
- None.
