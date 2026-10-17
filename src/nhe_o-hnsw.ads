--  Formally verified Hierarchical Navigable Small World (HNSW) Vector Graph Index
--  Supports Float32, Int8 (SQ8), and 4096-D Binary (1-bit Hamming) ANN Search (ADR-003)
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
                    and then Index.Entry_Node = 1;

   --  Insert a vector into the HNSW graph, automatically computing Binary (1-bit),
   --  Int8 (SQ8), and Matryoshka Float32 representations and linking small-world edges
   procedure Insert_Vector
     (Index      : in out HNSW_Index;
      Doc_Id     : in     Positive;
      Vec        : in     Vector_Value;
      TOAST_Root : in     Valid_Page_Id;
      Layer_Hint : in     HNSW_Layer;
      Status     :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Vec.Dim = Index.Dim
                    and then Index.Node_Count <= Max_HNSW_Nodes,
          Post   => Index.Dim = Index.Dim'Old
                    and then (if Status = Status_Ok then
                                Index.Node_Count = Index.Node_Count'Old + 1
                                and then Index.Entry_Node in 1 .. Index.Node_Count);

   --  Compute distance between a query vector and an HNSW node using the selected
   --  encoding mode (Float32, Int8 SQ8, or 4096-D 1-bit Binary Hamming)
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

   --  Hierarchical ANN search: greedy upper-layer descent (Top_Layer .. 2) followed by
   --  layer-1 small-world beam expansion and sorted Top-K candidate selection
   procedure Search_KNN
     (Index    : in     HNSW_Index;
      Query    : in     Vector_Value;
      Encoding : in     Vector_Encoding_Kind;
      K        : in     KNN_Result_Index;
      Results  :    out HNSW_Search_Result)
     with Global => null,
          Always_Terminates,
          Pre    => Query.Dim = Index.Dim
                    and then Index.Node_Count <= Max_HNSW_Nodes,
          Post   => Results.Count <= K
                    and then Results.Count <= Index.Node_Count;

end Nhe_O.HNSW;
