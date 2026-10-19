--  Formally verified Universal RAG & Hybrid SQL Query Executor
--  (ADR-003, ADR-004, CRIT-01, CRIT-04, CRIT-07, HIGH-05, HIGH-09, MED-03, Q-003)
--  Unifies B+Tree PK Index, 4096-D Quantized HNSW, JSONB Filter, 4KB TOAST Parent
--  & Vector Overflow Chains, Slotted Page Persistence, MVCC CLOG + Prior Version
--  Chains, GraphRAG 1-Hop Links, and Durable WAL-Committed Pub/Sub Notifications.
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

   --  Upper bound on Next_TOAST_Pg guaranteeing room for 3 full TOAST chains
   --  (Parent + Vector + Extended Metadata, HIGH-09 / R3-HIGH-04)
   Max_Safe_TOAST_Page : constant Valid_Page_Id :=
     Max_Page_Id - (3 * Max_TOAST_Chunks);

   type RAG_Document_Entry is record
      Active               : Boolean           := False;
      Doc_Id               : Positive          := 1;
      Tuple_Hdr            : MVCC_Tuple_Header := (Xmin => 1, Xmax => 0);
      Metadata             : JSONB_Document    := (others => <>);
      Summary_Text         : Bounded_Text      := (Length => 0, Data => [others => ' ']);
      Toast_Ptr            : TOAST_Pointer     := (others => <>);
      Vec_Toast_Ptr        : TOAST_Pointer     := (others => <>); --  4096-D full vector TOAST (Q-003)
      Meta_Toast_Ptr       : TOAST_Pointer     := (others => <>); --  Lossless summary+JSONB TOAST (R3-HIGH-04)
      Related_Doc_Id       : Optional_Doc_Id   := 0;              --  1-hop GraphRAG entity edge
      Cur_HNSW_Node        : HNSW_Node         := (others => <>); --  Active HNSW snapshot (R3-HIGH-02)
      --  Prior MVCC tuple version preserved for historical snapshots & rollback (CRIT-04, R3-HIGH-02)
      Has_Prior_Version    : Boolean           := False;
      Prior_Tuple_Hdr      : MVCC_Tuple_Header := (Xmin => 1, Xmax => 0);
      Prior_Metadata       : JSONB_Document    := (others => <>);
      Prior_Summary        : Bounded_Text      := (Length => 0, Data => [others => ' ']);
      Prior_Toast_Ptr      : TOAST_Pointer     := (others => <>);
      Prior_Vec_Toast_Ptr  : TOAST_Pointer     := (others => <>);
      Prior_Meta_Toast_Ptr : TOAST_Pointer     := (others => <>);
      Prior_Related_Id     : Optional_Doc_Id   := 0;
      Prior_HNSW_Node      : HNSW_Node         := (others => <>);
   end record;

   type RAG_Document_Table is array (RAG_Doc_Slot) of RAG_Document_Entry;

   type RAG_Engine is record
      Dim           : Vector_Dim         := 3;
      Doc_Count     : RAG_Doc_Count      := 0;
      Next_TOAST_Pg : Valid_Page_Id      := 10;
      CLOG          : Commit_Log         := Default_CLOG;
      PK_Tree       : BTree_Index        := (others => <>);
      Vector_Graph  : HNSW_Index         := (others => <>);
      Docs          : RAG_Document_Table := [others => (others => <>)];
   end record;

   --  Structural invariant check for a RAG_Engine instance (MED-03)
   function Is_Valid_RAG_Engine (Engine : RAG_Engine) return Boolean is
     (Engine.Vector_Graph.Dim = Engine.Dim
      and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
      and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
      and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page);

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
                    and then Engine.Next_TOAST_Pg = 10
                    and then Is_Valid_RAG_Engine (Engine);

   --  Case-insensitive substring check for Hybrid Lexical + Vector RAG.
   --  Returns False when Keyword.Length = 0 (HIGH-05).
   function Contains_Keyword
     (Text    : Bounded_Text;
      Keyword : Bounded_Text) return Boolean
     with Global => null,
          Post   => (if Keyword.Length = 0 then not Contains_Keyword'Result);

   --  MVCC logical delete of a document at transaction Ctx (sets Xmax := Ctx.Id
   --  and removes Doc_Id from PK_Tree and Vector_Graph, CRIT-04 / R3-HIGH-02)
   procedure Delete_Document
     (Engine : in out RAG_Engine;
      Ctx    : in     Transaction_Context;
      Doc_Id : in     RAG_Doc_Slot;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.Vector_Graph.Node_Count <= Max_HNSW_Nodes
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Old;

   --  Durable WAL-staged MVCC delete of a document at transaction Ctx (R2-HIGH-01, R3-HIGH-02)
   procedure Delete_Document
     (Engine   : in out RAG_Engine;
      Ctx      : in     Transaction_Context;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Doc_Id   : in     RAG_Doc_Slot;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then DB_Path.Length > 0
                    and then WAL_Path.Length > 0
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.Vector_Graph.Node_Count <= Max_HNSW_Nodes
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Old;

   --  Roll back in-memory RAG_Engine mutations (Docs, PK_Tree, Vector_Graph,
   --  CLOG, and Next_TOAST_Pg) performed by transaction Tx_Num (R2-CRIT-01)
   procedure Rollback_RAG_Tx
     (Engine : in out RAG_Engine;
      Tx_Num : in     Valid_Tx_Id)
     with Global => null,
          Always_Terminates,
          Pre    => Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page;

   --  Encode Engine.Docs into a 4096-byte primary Slotted_Page (`"SLOT"`, CRIT-01)
   procedure Build_RAG_Slotted_Page
     (Engine   : in     RAG_Engine;
      LSN_Tx   : in     Valid_Tx_Id;
      Raw_Page :    out Page_Buffer)
     with Global => null,
          Always_Terminates;

   --  Recover a RAG_Engine from on-disk WAL + Page 1 Slotted_Page (CRIT-01, CRIT-05)
   procedure Recover_RAG_Engine
     (Engine   :    out RAG_Engine;
      Dim      : in     Vector_Dim;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => DB_Path.Length > 0 and then WAL_Path.Length > 0,
          Post   => Engine.Dim = Dim
                    and then Engine.Vector_Graph.Dim = Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page;

   --  Transactional Document Ingestion:
   --  1. Persists oversized parent chunk (and full >64-D vector when Dim > 64) to 4KB TOAST chains
   --  2. Indexes Doc_Id in B+Tree (Nhe_O.BTree)
   --  3. Indexes Embedding in Multi-Layer Quantized HNSW Graph (Nhe_O.HNSW)
   --  4. Preserves prior MVCC version & persists primary Slotted_Page on Page 1 (CRIT-01, CRIT-04)
   --  5. Stages a DURABLE WAL notification on channel "rag.indexed" (Nhe_O.PubSub)
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
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page;

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
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post   => Result.Count <= Top_K;

end Nhe_O.RAG;
