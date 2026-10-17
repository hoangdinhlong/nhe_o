--  Formally verified Universal RAG & Hybrid SQL Query Executor (ADR-003 / ADR-004)
--  Unifies B+Tree PK Index, 4096-D Quantized HNSW, JSONB Filter, 4KB TOAST Parent
--  Chunks, GraphRAG 1-Hop Links, and Durable WAL-Committed Pub/Sub Notifications.
pragma SPARK_Mode (On);

with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.Vector;      use Nhe_O.Vector;
with Nhe_O.JSON;        use Nhe_O.JSON;
with Nhe_O.IO;          use Nhe_O.IO;
with Nhe_O.Transaction; use Nhe_O.Transaction;
with Nhe_O.BTree;       use Nhe_O.BTree;
with Nhe_O.HNSW;        use Nhe_O.HNSW;
with Nhe_O.PubSub;      use Nhe_O.PubSub;

package Nhe_O.RAG is

   Max_RAG_Docs : constant := 16;
   subtype RAG_Doc_Slot is Positive range 1 .. Max_RAG_Docs;
   subtype RAG_Doc_Count is Natural range 0 .. Max_RAG_Docs;
   subtype Optional_Doc_Id is Natural range 0 .. Max_RAG_Docs;

   type RAG_Document_Entry is record
      Active         : Boolean        := False;
      Doc_Id         : Positive       := 1;
      Tuple_Hdr      : MVCC_Tuple_Header := (Xmin => 1, Xmax => 0);
      Metadata       : JSONB_Document := (others => <>);
      Summary_Text   : Bounded_Text   := (Length => 0, Data => [others => ' ']);
      Toast_Ptr      : TOAST_Pointer  := (others => <>);
      Related_Doc_Id : Optional_Doc_Id := 0; --  1-hop GraphRAG entity edge
   end record;

   type RAG_Document_Table is array (RAG_Doc_Slot) of RAG_Document_Entry;

   type RAG_Engine is record
      Dim            : Vector_Dim         := 3;
      Doc_Count      : RAG_Doc_Count      := 0;
      Next_TOAST_Pg  : Valid_Page_Id      := 10;
      PK_Tree        : BTree_Index        := (others => <>);
      Vector_Graph   : HNSW_Index         := (others => <>);
      Docs           : RAG_Document_Table := [others => (others => <>)];
   end record;

   Max_RAG_Hits : constant := 8;
   subtype RAG_Hit_Index is Positive range 1 .. Max_RAG_Hits;
   subtype RAG_Hit_Count is Natural range 0 .. Max_RAG_Hits;

   type RAG_Search_Hit is record
      Doc_Id         : Positive           := 1;
      Distance       : Non_Negative_Float := 0.0;
      Keyword_Match  : Boolean            := False;
      Toast_Ptr      : TOAST_Pointer      := (others => <>);
      Summary_Text   : Bounded_Text       := (Length => 0, Data => [others => ' ']);
      Related_Doc_Id : Optional_Doc_Id    := 0;
   end record;

   type RAG_Hit_Array is array (RAG_Hit_Index) of RAG_Search_Hit;

   type RAG_Query_Result is record
      Count              : RAG_Hit_Count        := 0;
      Top_Parent_Bytes   : TOAST_Payload_Length := 0;
      Graph_Neighbor_Hit : Boolean              := False;
      Hits               : RAG_Hit_Array        := [others => (others => <>)];
   end record;

   --  Initialize a Universal RAG Engine for embedding dimension Dim (up to 4096-D)
   procedure Init_RAG_Engine
     (Engine :    out RAG_Engine;
      Dim    : in     Vector_Dim)
     with Global => null,
          Always_Terminates,
          Post   => Engine.Dim = Dim
                    and then Engine.Vector_Graph.Dim = Dim
                    and then Engine.Doc_Count = 0
                    and then Engine.PK_Tree.Node_Count = 1
                    and then Engine.PK_Tree.Root_Node = 1
                    and then Engine.Next_TOAST_Pg = 10;

   --  Case-insensitive substring check for Hybrid Lexical + Vector RAG
   function Contains_Keyword
     (Text    : Bounded_Text;
      Keyword : Bounded_Text) return Boolean
     with Global => null;

   --  Transactional Document Ingestion:
   --  1. Persists oversized parent chunk (or 16KB 4096-D payload) to 4KB TOAST chain
   --  2. Indexes Doc_Id in B+Tree (Nhe_O.BTree)
   --  3. Indexes Embedding in Multi-Layer Quantized HNSW Graph (Nhe_O.HNSW)
   --  4. Stages a DURABLE WAL notification on channel "rag.indexed" (Nhe_O.PubSub)
   procedure Ingest_Document
     (Engine         : in out RAG_Engine;
      Ctx            : in     Transaction_Context;
      DB_Path        : in     Bounded_Text;
      WAL_Path       : in     Bounded_Text;
      Staging        : in out Tx_Notification_Buffer;
      Doc_Id         : in     RAG_Doc_Slot;
      Metadata       : in     JSONB_Document;
      Summary_Text   : in     Bounded_Text;
      Embedding      : in     Vector_Value;
      Parent_Payload : in     TOAST_Payload_Buffer;
      Parent_Length  : in     Valid_TOAST_Length;
      Related_Doc_Id : in     Optional_Doc_Id;
      Layer_Hint     : in     HNSW_Layer;
      Status         :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then DB_Path.Length > 0
                    and then WAL_Path.Length > 0
                    and then Embedding.Dim = Engine.Dim
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Page_Id - Max_TOAST_Chunks,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count;

   --  Execute a Hybrid SQL + JSONB (`@>`) + Lexical + HNSW Vector + TOAST + GraphRAG query
   procedure Execute_Hybrid_RAG_Query
     (Engine            : in     RAG_Engine;
      Snapshot          : in     Valid_Tx_Id;
      DB_Path           : in     Bounded_Text;
      SQL_Query         : in     Bounded_Text;
      Query_Vec         : in     Vector_Value;
      Encoding          : in     Vector_Encoding_Kind;
      Use_Meta_Filter   : in     Boolean;
      Filter_Meta       : in     JSONB_Document;
      Use_Keyword_Boost : in     Boolean;
      Keyword           : in     Bounded_Text;
      Top_K             : in     RAG_Hit_Index;
      Result            :    out RAG_Query_Result;
      Top_Parent_Chunk  :    out TOAST_Payload_Buffer;
      Status            :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => DB_Path.Length > 0
                    and then Query_Vec.Dim = Engine.Dim
                    and then Engine.Vector_Graph.Dim = Engine.Dim,
          Post   => Result.Count <= Top_K;

end Nhe_O.RAG;
