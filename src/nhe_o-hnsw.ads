--  Formally verified Hierarchical Navigable Small World (HNSW) Vector Graph Index
--  Supports Float32, Int8 (SQ8), and 4096-D Binary (1-bit Hamming) ANN Search
--  (ADR-003, ADR-006, BR-003)
pragma SPARK_Mode (On);

with Nhe_O.Types;  use Nhe_O.Types;
with Nhe_O.Vector; use Nhe_O.Vector;
with Nhe_O.IO;     use Nhe_O.IO;

package Nhe_O.HNSW is

   Max_Layers : constant := 3;
   subtype HNSW_Layer is Positive range 1 .. Max_Layers;

   Max_Neighbors : constant := 4;
   subtype Neighbor_Slot is Positive range 1 .. Max_Neighbors;
   subtype Neighbor_Count is Natural range 0 .. Max_Neighbors;

   Max_HNSW_Nodes : constant := 32;
   subtype HNSW_Node_Id is Positive range 1 .. Max_HNSW_Nodes;
   subtype HNSW_Node_Count is Natural range 0 .. Max_HNSW_Nodes;

   --  Inline Matryoshka prefix dimension for fast Float32 / Int8 HNSW routing
   Matryoshka_Dim : constant := 64;
   subtype Matryoshka_Index is Positive range 1 .. Matryoshka_Dim;
   type Matryoshka_Float_Array is array (Matryoshka_Index) of Vector_Component;
   type Matryoshka_Int8_Array is array (Matryoshka_Index) of Int8_Component;

   type Neighbor_List is array (Neighbor_Slot) of HNSW_Node_Id;

   type Layer_Adjacency is record
      Degree    : Neighbor_Count := 0;
      Neighbors : Neighbor_List  := [others => 1];
   end record;

   type Node_Layer_Array is array (HNSW_Layer) of Layer_Adjacency;

   type HNSW_Node is record
      Active      : Boolean                 := False;
      Doc_Id      : Positive                := 1;
      TOAST_Root  : Valid_Page_Id           := 0;
      Top_Level   : HNSW_Layer              := 1;
      Prefix_Len  : Matryoshka_Index        := 1;
      Int8_Scale  : Non_Negative_Float      := 1.0;
      Float_Pref  : Matryoshka_Float_Array  := [others => 0.0];
      Int8_Pref   : Matryoshka_Int8_Array   := [others => 0];
      Bin_Vec     : Quantized_Binary_Vector := (others => <>);
      Layers      : Node_Layer_Array        := [others => (others => <>)];
   end record;

   type HNSW_Node_Pool is array (HNSW_Node_Id) of HNSW_Node;

   type HNSW_Index is record
      Dim        : Vector_Dim      := 3;
      Node_Count : HNSW_Node_Count := 0;
      Entry_Node : HNSW_Node_Id    := 1;
      Top_Layer  : HNSW_Layer      := 1;
      Nodes      : HNSW_Node_Pool  := [others => (others => <>)];
   end record;

   --  Structural invariant check for an HNSW_Index
   function Is_Valid_HNSW (Index : HNSW_Index) return Boolean is
     (if Index.Node_Count > 0 then Index.Entry_Node <= Index.Node_Count else True);

   Max_KNN_Results : constant := 16;
   subtype KNN_Result_Index is Positive range 1 .. Max_KNN_Results;
   subtype KNN_Result_Count is Natural range 0 .. Max_KNN_Results;

   type HNSW_Candidate is record
      Node_Id    : HNSW_Node_Id       := 1;
      Doc_Id     : Positive           := 1;
      TOAST_Root : Valid_Page_Id      := 0;
      Distance   : Non_Negative_Float := 0.0;
   end record;

   type HNSW_Candidate_Array is array (KNN_Result_Index) of HNSW_Candidate;

   type HNSW_Search_Result is record
      Count         : KNN_Result_Count     := 0;
      Visited_Nodes : Natural              := 0;
      Items         : HNSW_Candidate_Array := [others => (others => <>)];
   end record;

   --  Initialize an empty HNSW multi-layer graph index for dimension Dim (up to 4096-D)
   procedure Init_HNSW
     (Index :    out HNSW_Index;
      Dim   : in     Vector_Dim)
     with Global => null,
          Always_Terminates,
          Post   => Index.Dim = Dim
                    and then Index.Node_Count = 0
                    and then Index.Entry_Node = 1
                    and then Is_Valid_HNSW (Index);

   --  True iff Insert_Vector for Doc_Id can succeed without exceeding Max_HNSW_Nodes
   --  (either via in-place update, inactive slot reuse, or growing Node_Count)
   function Has_HNSW_Capacity
     (Index  : HNSW_Index;
      Doc_Id : Positive) return Boolean
   is
     (Index.Node_Count < Max_HNSW_Nodes
      or else (for some I in 1 .. Index.Node_Count =>
                 not Index.Nodes (I).Active
                 or else Index.Nodes (I).Doc_Id = Doc_Id));

   --  Deactivate a document's vector node, scrub incoming neighbor edges, trim
   --  trailing inactive nodes, and recompute Entry_Node / Top_Layer
   procedure Remove_Vector
     (Index  : in out HNSW_Index;
      Doc_Id : in     Positive)
     with Global => null,
          Always_Terminates,
          Post   => Index.Dim = Index.Dim'Old
                    and then Index.Node_Count <= Index.Node_Count'Old
                    and then Is_Valid_HNSW (Index);

   --  Restore a saved HNSW_Node snapshot into Index on MVCC rollback (BR-002).
   --  Any current node of Doc_Id is removed first; an inactive snapshot only
   --  removes. Status_Ok iff the snapshot state was restored (for an active
   --  snapshot: an active node of Doc_Id is present afterwards);
   --  Status_Capacity_Exceeded iff all Max_HNSW_Nodes slots hold other
   --  active documents, in which case Doc_Id has no node.
   procedure Restore_Vector_Node
     (Index     : in out HNSW_Index;
      Doc_Id    : in     Positive;
      Node_Snap : in     HNSW_Node;
      Status    :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Node_Snap.Bin_Vec.Dim = Index.Dim,
          Post   => Index.Dim = Index.Dim'Old
                    and then Is_Valid_HNSW (Index)
                    and then Status in Status_Ok | Status_Capacity_Exceeded
                    and then (if not Node_Snap.Active then Status = Status_Ok)
                    and then (if Status = Status_Ok and then Node_Snap.Active then
                                (for some I in 1 .. Index.Node_Count =>
                                   Index.Nodes (I).Active
                                   and then Index.Nodes (I).Doc_Id = Doc_Id))
                    and then (if Status = Status_Capacity_Exceeded then
                                Index.Node_Count = Max_HNSW_Nodes
                                and then (for all I in HNSW_Node_Id =>
                                            Index.Nodes (I).Active
                                            and then Index.Nodes (I).Doc_Id /= Doc_Id));

   --  Restore_Vector_Node without a status (a full index leaves Doc_Id absent;
   --  use the overload above to detect that case)
   procedure Restore_Vector_Node
     (Index     : in out HNSW_Index;
      Doc_Id    : in     Positive;
      Node_Snap : in     HNSW_Node)
     with Global => null,
          Always_Terminates,
          Pre    => Node_Snap.Bin_Vec.Dim = Index.Dim,
          Post   => Index.Dim = Index.Dim'Old
                    and then Is_Valid_HNSW (Index);

   --  Insert or update a vector in the HNSW graph, computing Binary (1-bit),
   --  scale-preserving Int8 (SQ8), and Matryoshka Float32 representations and
   --  linking distance-pruned small-world edges
   procedure Insert_Vector
     (Index      : in out HNSW_Index;
      Doc_Id     : in     Positive;
      Vec        : in     Vector_Value;
      TOAST_Root : in     Valid_Page_Id;
      Layer_Hint : in     HNSW_Layer;
      Status     :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Vec.Dim = Index.Dim,
          Post   => Index.Dim = Index.Dim'Old
                    and then (if Status = Status_Ok then
                                Index.Node_Count >= 1
                                and then Index.Node_Count >= Index.Node_Count'Old
                                and then (if Index.Node_Count'Old < Max_HNSW_Nodes then
                                            Index.Node_Count <= Index.Node_Count'Old + 1
                                          else
                                            Index.Node_Count = Max_HNSW_Nodes)
                                and then Index.Entry_Node in 1 .. Index.Node_Count);

   --  Compute metric distance between a query vector and an HNSW node using the
   --  selected encoding mode: Float32 L2 or scale-aware Int8 SQ8 L2 over the first
   --  Prefix_Len = min (Dim, Matryoshka_Dim) components (the node keeps only that
   --  prefix), or 1-bit Hamming over all Dim bits
   function Node_Distance
     (Node     : HNSW_Node;
      Q_Float  : Vector_Value;
      Q_Int8   : Quantized_Int8_Vector;
      Q_Binary : Quantized_Binary_Vector;
      Encoding : Vector_Encoding_Kind) return Non_Negative_Float
     with Global => null,
          Pre    => Node.Bin_Vec.Dim = Q_Binary.Dim
                    and then Q_Float.Dim = Q_Binary.Dim
                    and then Q_Int8.Dim = Q_Binary.Dim;

   --  Hierarchical k-NN search: greedy upper-layer descent (Top_Layer .. 2),
   --  layer-1 greedy descent and multi-wave beam expansion seed the candidate
   --  distances; a final exhaustive pass then evaluates every node the graph
   --  walk did not reach (graph edges may be pruned or removed, so a live node
   --  can be unreachable), and the result is the exact top-K of all active
   --  nodes of matching dimension by Node_Distance (ties: lower Node_Id first; a
   --  Matryoshka-prefix distance for Float32 / Int8 above Matryoshka_Dim dimensions),
   --  sorted by non-decreasing Distance, without duplicate nodes. Each node's
   --  distance is computed at most once per search. Visited_Nodes counts the
   --  distinct nodes evaluated.
   procedure Search_KNN
     (Index    : in     HNSW_Index;
      Query    : in     Vector_Value;
      Encoding : in     Vector_Encoding_Kind;
      K        : in     KNN_Result_Index;
      Results  :    out HNSW_Search_Result)
     with Global => null,
          Always_Terminates,
          Pre    => Query.Dim = Index.Dim,
          Post   => Results.Count <= K
                    and then Results.Count <= Index.Node_Count
                    and then (for all I in 1 .. Results.Count =>
                                Results.Items (I).Node_Id <= Index.Node_Count
                                and then Index.Nodes (Results.Items (I).Node_Id).Active
                                and then Index.Nodes (Results.Items (I).Node_Id).Bin_Vec.Dim
                                           = Query.Dim
                                and then Index.Nodes (Results.Items (I).Node_Id).Doc_Id
                                           = Results.Items (I).Doc_Id
                                and then Index.Nodes (Results.Items (I).Node_Id).TOAST_Root
                                           = Results.Items (I).TOAST_Root)
                    and then (for all I in 2 .. Results.Count =>
                                Results.Items (I - 1).Distance <= Results.Items (I).Distance)
                    and then (for all I in 1 .. Results.Count =>
                                (for all J in 1 .. I - 1 =>
                                   Results.Items (J).Node_Id /= Results.Items (I).Node_Id));

end Nhe_O.HNSW;
