--  Formally verified Universal RAG & Hybrid SQL Query Executor
--  (ADR-003, ADR-004, ADR-006, BR-002, BR-006, Q-003)
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
   --  (Parent + Vector + Extended Metadata)
   Max_Safe_TOAST_Page : constant Valid_Page_Id :=
     Max_Page_Id - (3 * Max_TOAST_Chunks);

   --  MVCC commit sequence numbers (BR-002): every commit observed by the engine gets
   --  the next number; a snapshot is the last number taken when the snapshot starts.
   --  Versions recovered from disk (or frozen by a checkpoint) carry number 0, i.e.
   --  they committed before every snapshot.
   subtype Commit_Seq_Number is Natural range 0 .. Max_Tx_Id;
   type Commit_Seq_Log is array (CLOG_Tx_Index) of Commit_Seq_Number;

   type RAG_Document_Entry is record
      Active               : Boolean           := False;
      Doc_Id               : Positive          := 1;
      Tuple_Hdr            : MVCC_Tuple_Header := (Xmin => 1, Xmax => 0);
      Metadata             : JSONB_Document    := (others => <>);
      Summary_Text         : Bounded_Text      := (Length => 0, Data => [others => ' ']);
      Toast_Ptr            : TOAST_Pointer     := (others => <>);
      Vec_Toast_Ptr        : TOAST_Pointer     := (others => <>); --  4096-D full vector TOAST (Q-003)
      Meta_Toast_Ptr       : TOAST_Pointer     := (others => <>); --  Lossless summary+JSONB TOAST
      Related_Doc_Id       : Optional_Doc_Id   := 0;              --  1-hop GraphRAG entity edge
      Cur_HNSW_Node        : HNSW_Node         := (others => <>); --  Active HNSW snapshot
      --  Prior MVCC tuple version preserved for historical snapshots & rollback
      Has_Prior_Version    : Boolean           := False;
      Prior_Tuple_Hdr      : MVCC_Tuple_Header := (Xmin => 1, Xmax => 0);
      Prior_Metadata       : JSONB_Document    := (others => <>);
      Prior_Summary        : Bounded_Text      := (Length => 0, Data => [others => ' ']);
      Prior_Toast_Ptr      : TOAST_Pointer     := (others => <>);
      Prior_Vec_Toast_Ptr  : TOAST_Pointer     := (others => <>);
      Prior_Meta_Toast_Ptr : TOAST_Pointer     := (others => <>);
      Prior_Related_Id     : Optional_Doc_Id   := 0;
      Prior_HNSW_Node      : HNSW_Node         := (others => <>);
      --  TOAST pages Staged_Tx staged in the WAL for this slot (Staged_First ..
      --  Staged_End - 1, a hull over every version it wrote here, superseded ones
      --  included): its commit materializes all of them, so they stay reserved for
      --  other transactions while Staged_Tx is active (0: none)
      Staged_Tx            : Tx_Id             := 0;
      Staged_First         : Valid_Page_Id     := 10;
      Staged_End           : Valid_Page_Id     := 10;
   end record;

   type RAG_Document_Table is array (RAG_Doc_Slot) of RAG_Document_Entry;

   type RAG_Engine is record
      Dim             : Vector_Dim         := 3;
      Doc_Count       : RAG_Doc_Count      := 0;
      --  An upper bound of the reserved TOAST pages: one past the highest after an
      --  ingest, rollback, freeze or recovery (Recompute_TOAST_High_Water_Mark); a
      --  commit keeps it, so it can stay above the pages a transaction released by
      --  replacing its own version, until the next of those recomputes it
      Next_TOAST_Pg   : Valid_Page_Id      := 10;
      CLOG            : Commit_Log         := Default_CLOG;
      Commit_Seqs     : Commit_Seq_Log     := [others => 0];
      Last_Commit_Seq : Commit_Seq_Number  := 0;
      --  Snapshots older than Read_Horizon cannot be read: a document keeps one prior
      --  committed version, so an update over a version that already had a prior
      --  drops that prior, which snapshots older than the commit of the version kept
      --  may need (queries at such a snapshot fail with Status_Tx_Aborted)
      Read_Horizon    : Commit_Seq_Number  := 0;
      --  A commit left pages of the WAL unmaterialized in the database file (its
      --  in-place redo failed, see Commit_RAG_Tx): Freeze_RAG_Engine refuses until a
      --  later in-place redo succeeds or the engine is recovered, and a query whose
      --  candidates need those pages fails with Status_IO_Error meanwhile (Stage 2 and
      --  the parent chunk are read from the database file)
      Pages_Pending   : Boolean            := False;
      PK_Tree         : BTree_Index        := (others => <>);
      Vector_Graph    : HNSW_Index         := (others => <>);
      Docs            : RAG_Document_Table := [others => (others => <>)];
   end record;

   --  Structural invariant check for a RAG_Engine instance
   function Is_Valid_RAG_Engine (Engine : RAG_Engine) return Boolean is
     (Engine.Vector_Graph.Dim = Engine.Dim
      and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
      and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
      and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page);

   --  Snapshot for MVCC reads and writes: the commit sequence number of the latest
   --  commit the engine has observed. Commits observed later are invisible to this
   --  snapshot. A snapshot is valid until the engine is frozen (Freeze_RAG_Engine),
   --  recovered or re-initialized; reads and writes refuse one newer than every
   --  commit observed (Status_Tx_Aborted). Queries also refuse a snapshot that fell
   --  below Read_Horizon (Status_Tx_Aborted, "snapshot too old"): take a new one.
   function Take_Snapshot (Engine : RAG_Engine) return Commit_Seq_Number is
     (Engine.Last_Commit_Seq);

   --  Snapshot-isolation visibility rule (BR-002): a version is visible to Snapshot iff
   --  its creator committed at or before Snapshot and its deleter (if any) did not.
   --  Uncommitted versions are never visible, including the reader's own (NO-STEAL:
   --  their TOAST pages only exist in the WAL until Commit_Tx materializes them).
   function Is_Version_Visible
     (Engine   : RAG_Engine;
      Hdr      : MVCC_Tuple_Header;
      Snapshot : Commit_Seq_Number) return Boolean
   is
     (Is_Tx_Committed (Engine.CLOG, Hdr.Xmin)
      and then Engine.Commit_Seqs (Hdr.Xmin) <= Snapshot
      and then (Hdr.Xmax = 0
                or else not Is_Tx_Committed (Engine.CLOG, Hdr.Xmax)
                or else Engine.Commit_Seqs (Hdr.Xmax) > Snapshot));

   --  W wrote concurrently with the writer Tx whose snapshot is Snapshot: W is another
   --  transaction that is still active, or that committed after Snapshot
   function Is_Concurrent_Writer
     (Engine   : RAG_Engine;
      W        : Valid_Tx_Id;
      Tx       : Valid_Tx_Id;
      Snapshot : Commit_Seq_Number) return Boolean
   is
     (W /= Tx
      and then (Engine.CLOG (W) = Tx_Active
                or else (Engine.CLOG (W) = Tx_Committed
                         and then Engine.Commit_Seqs (W) > Snapshot)));

   --  Snapshot-isolation write conflict (BR-002): the newest version of Doc_Id was
   --  created or deleted by a concurrent writer (first updater wins, and a version
   --  committed after the writer's snapshot is never overwritten: no lost update), or
   --  another active transaction staged TOAST pages for Doc_Id
   function Has_Write_Conflict
     (Engine   : RAG_Engine;
      Doc_Id   : RAG_Doc_Slot;
      Tx       : Valid_Tx_Id;
      Snapshot : Commit_Seq_Number) return Boolean
   is
     ((Engine.Docs (Doc_Id).Staged_Tx /= 0
       and then Engine.Docs (Doc_Id).Staged_Tx /= Tx
       and then Engine.CLOG (Engine.Docs (Doc_Id).Staged_Tx) = Tx_Active)
      or else (Engine.Docs (Doc_Id).Active
               and then (Is_Concurrent_Writer
                           (Engine, Engine.Docs (Doc_Id).Tuple_Hdr.Xmin, Tx, Snapshot)
                         or else (Engine.Docs (Doc_Id).Tuple_Hdr.Xmax > 0
                                  and then Is_Concurrent_Writer
                                    (Engine, Engine.Docs (Doc_Id).Tuple_Hdr.Xmax, Tx, Snapshot)))));

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
                    and then Engine.Last_Commit_Seq = 0
                    and then (for all S in RAG_Doc_Slot => not Engine.Docs (S).Active)
                    and then Is_Valid_RAG_Engine (Engine);

   --  Case-insensitive substring check for Hybrid Lexical + Vector RAG. Case folding
   --  covers ASCII and the Latin letters of UTF-8 (Latin-1 Supplement, Latin
   --  Extended-A, the horn letters O/U of Latin Extended-B, and Latin Extended
   --  Additional), i.e. every Vietnamese letter. Returns False when Keyword.Length = 0.
   function Contains_Keyword
     (Text    : Bounded_Text;
      Keyword : Bounded_Text) return Boolean
     with Global => null,
          Post   => (if Keyword.Length = 0 then not Contains_Keyword'Result);

   --  Record that transaction Tx committed (after its Commit_Tx barrier is durable):
   --  CLOG (Tx) := Tx_Committed and Tx receives the next commit sequence number
   procedure Mark_Committed
     (Engine : in out RAG_Engine;
      Tx     : in     Valid_Tx_Id)
     with Global => null,
          Always_Terminates,
          Post   => Engine.CLOG (Tx) = Tx_Committed
                    and then Engine.Commit_Seqs (Tx) = Engine.Last_Commit_Seq
                    and then Engine.Last_Commit_Seq >= Engine.Last_Commit_Seq'Old
                    and then Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph = Engine.Vector_Graph'Old
                    and then Engine.PK_Tree = Engine.PK_Tree'Old
                    and then Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Old
                    and then Engine.Doc_Count = Engine.Doc_Count'Old
                    and then Engine.Docs = Engine.Docs'Old;

   --  MVCC logical delete of a document at transaction Ctx, whose snapshot (taken when
   --  it started, see Take_Snapshot) is Snapshot: sets Xmax := Ctx.Id and removes Doc_Id
   --  from PK_Tree and Vector_Graph. Deleting Ctx's own new version of a document that
   --  has a prior version reverts the slot to that prior version, deleted by Ctx unless
   --  a committed transaction had already deleted it (that deleter is kept), so the
   --  single prior-version slot never holds a version no snapshot can see.
   --  Status_Not_Found when Doc_Id has no live version. Status_Tx_Aborted, with the
   --  engine unchanged, on a write conflict (Has_Write_Conflict), a Snapshot newer
   --  than Last_Commit_Seq, or when Ctx was already aborted or committed.
   procedure Delete_Document
     (Engine   : in out RAG_Engine;
      Ctx      : in     Transaction_Context;
      Snapshot : in     Commit_Seq_Number;
      Doc_Id   : in     RAG_Doc_Slot;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Old
                    and then (if Has_Write_Conflict (Engine'Old, Doc_Id, Ctx.Id, Snapshot)
                              then Status = Status_Tx_Aborted);

   --  Durable WAL-staged MVCC delete (as above) that also stages the new Page 1 as a
   --  WAL data frame. If that append fails, the engine is restored and Status_IO_Error
   --  returned; a frame the append could not roll back is never replayed on its own,
   --  since Ctx's commit page (Commit_Tx) supersedes it.
   procedure Delete_Document
     (Engine   : in out RAG_Engine;
      Ctx      : in     Transaction_Context;
      Snapshot : in     Commit_Seq_Number;
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
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Old
                    and then (if Has_Write_Conflict (Engine'Old, Doc_Id, Ctx.Id, Snapshot)
                              then Status = Status_Tx_Aborted);

   --  Roll back in-memory RAG_Engine mutations (Docs, PK_Tree, Vector_Graph,
   --  CLOG, and Next_TOAST_Pg) performed by the uncommitted transaction Tx_Num.
   --  Each document's prior version is restored; a version that the rolled-back update
   --  had already displaced from the single prior-version slot cannot be resurrected.
   procedure Rollback_RAG_Tx
     (Engine : in out RAG_Engine;
      Tx_Num : in     Valid_Tx_Id)
     with Global => null,
          Always_Terminates,
          Pre    => Engine.CLOG (Tx_Num) /= Tx_Committed
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page
                    and then Engine.CLOG (Tx_Num) = Tx_Aborted;

   --  Encode the committed state of Engine.Docs plus the changes of the committing
   --  transaction LSN_Tx into a 4096-byte primary Slotted_Page (`"SLOT"`). Per slot the
   --  newest version created by a committed transaction or by LSN_Tx is persisted
   --  (falling back to the committed prior version), and a deleter that is neither
   --  committed nor LSN_Tx is not persisted, so the page never carries another active
   --  transaction's uncommitted work.
   procedure Build_RAG_Slotted_Page
     (Engine   : in     RAG_Engine;
      LSN_Tx   : in     Valid_Tx_Id;
      Raw_Page :    out Page_Buffer)
     with Global => null,
          Always_Terminates,
          Pre    => Engine.CLOG (LSN_Tx) /= Tx_Aborted;

   --  Commit transaction Ctx against Engine (BR-002 / ADR-006): builds Page 1 with
   --  Build_RAG_Slotted_Page, runs Commit_Tx, then either marks Ctx committed
   --  (Mark_Committed) and delivers its staged notifications, or rolls Engine back
   --  (Rollback_RAG_Tx) and discards them. A poisoned transaction (CLOG (Ctx.Id) =
   --  Tx_Aborted after a failed Ingest_Document whose frames could not be truncated) is
   --  rolled back without touching the WAL; a failed Delete_Document never poisons, as
   --  the commit page supersedes a Page 1 frame it could not truncate.
   --  If the commit barrier is durable but materializing pages failed, the database
   --  file is repaired in place with Redo_WAL_Recovery; Flush_Pending reports that the
   --  repair failed too (the commit stands and is replayed at the next recovery) and
   --  sets Engine.Pages_Pending, which a later successful in-place repair clears.
   procedure Commit_RAG_Tx
     (Engine        : in out RAG_Engine;
      Ctx           : in out Transaction_Context;
      DB_Path       : in     Bounded_Text;
      WAL_Path      : in     Bounded_Text;
      Staging       : in out Tx_Notification_Buffer;
      Broker        : in out PubSub_Broker;
      Delivered     :    out Natural;
      Status        :    out Engine_Status;
      Flush_Pending :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then DB_Path.Length > 0
                    and then WAL_Path.Length > 0
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page
                    and then Ctx.Id = Ctx.Id'Old
                    and then Ctx.State in Tx_Committed | Tx_Aborted
                    and then (Status = Status_Ok) = (Ctx.State = Tx_Committed)
                    and then (if Ctx.State = Tx_Committed
                              then Engine.CLOG (Ctx.Id) = Tx_Committed)
                    and then (if Ctx.State = Tx_Aborted
                                and then Engine'Old.CLOG (Ctx.Id) /= Tx_Committed
                              then Engine.CLOG (Ctx.Id) = Tx_Aborted)
                    and then (if Flush_Pending then Status = Status_Ok
                                                    and then Engine.Pages_Pending);

   --  Checkpoint support (VACUUM FREEZE): when no transaction is in flight, drop deleted
   --  documents and prior versions, re-stamp every live version as created by the
   --  frozen transaction 1 (Xmin = 1, commit sequence 0), and reset the CLOG so that
   --  transaction ids can restart at 2. Status_Tx_Aborted (engine unchanged) if any
   --  document still carries an uncommitted version; Status_IO_Error (engine unchanged)
   --  while Pages_Pending, since the WAL a checkpoint replaces would then hold the only
   --  copy of committed pages. Two obligations stay with the
   --  caller (C_Checkpoint meets both): ids may restart at 2 only once the WAL holds no
   --  frame of an earlier transaction (replace it first, as a checkpoint does: an old
   --  frame of a reused id would be replayed or would abort the new commit), and every
   --  snapshot taken before the freeze is invalid afterwards (frozen versions carry
   --  sequence 0 and are visible to every snapshot).
   procedure Freeze_RAG_Engine
     (Engine : in out RAG_Engine;
      Status :    out Engine_Status)
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
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page
                    and then Status in Status_Ok | Status_Tx_Aborted | Status_IO_Error
                    and then (if Status = Status_Ok then
                                Engine.Last_Commit_Seq = 0
                                and then Engine.Read_Horizon = 0
                                and then Engine.CLOG (1) = Tx_Committed
                                and then (for all S in RAG_Doc_Slot =>
                                            (if Engine.Docs (S).Active then
                                               Engine.Docs (S).Tuple_Hdr.Xmin = 1
                                               and then Engine.Docs (S).Tuple_Hdr.Xmax = 0
                                               and then not Engine.Docs (S).Has_Prior_Version))
                              else Engine = Engine'Old);

   --  Recover a RAG_Engine from on-disk WAL + Page 1 Slotted_Page. A missing or empty
   --  database file recovers an empty engine. Max_Seen_Tx is the largest transaction id
   --  found in the WAL (Redo_WAL_Recovery.Max_Seen_Tx), the Page 1 LSN, and any
   --  recovered tuple header: callers must seed Next_Tx above it. A document whose
   --  vector has another dimension than Dim fails with Status_Dimension_Mismatch, and
   --  any damage (Page 1, TOAST, "RMET" or vector chains, tuples, the WAL) with
   --  Status_IO_Error.
   procedure Recover_RAG_Engine
     (Engine      :    out RAG_Engine;
      Dim         : in     Vector_Dim;
      DB_Path     : in     Bounded_Text;
      WAL_Path    : in     Bounded_Text;
      Max_Seen_Tx :    out Tx_Id;
      Status      :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => DB_Path.Length > 0 and then WAL_Path.Length > 0,
          Post   => Engine.Dim = Dim
                    and then Engine.Vector_Graph.Dim = Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page
                    and then (if Status = Status_Ok then
                                (for all S in RAG_Doc_Slot =>
                                   (if Engine.Docs (S).Active then
                                      Engine.Docs (S).Tuple_Hdr.Xmin <= Max_Seen_Tx
                                      and then Engine.Docs (S).Tuple_Hdr.Xmax <= Max_Seen_Tx)));

   --  Recover_RAG_Engine for callers that track transaction ids themselves
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

   --  Transactional Document Ingestion at transaction Ctx, whose snapshot (taken when
   --  it started, see Take_Snapshot) is Snapshot:
   --  1. Persists the oversized parent chunk and the full Float32 embedding ("VTS2",
   --     for every dimension) to 4KB TOAST chains, plus an "RMET" chain when the
   --     summary or metadata does not fit inline, on the lowest free pages (pages of
   --     live and prior versions, and pages other active transactions staged, are
   --     never reused)
   --  2. Indexes Doc_Id in B+Tree (Nhe_O.BTree)
   --  3. Indexes Embedding in Multi-Layer Quantized HNSW Graph (Nhe_O.HNSW)
   --  4. Preserves prior MVCC version & persists primary Slotted_Page on Page 1
   --  5. Stages a DURABLE WAL notification on channel "rag.indexed" (Nhe_O.PubSub)
   --  The engine is unchanged after Status_Tx_Aborted (a write conflict, see
   --  Has_Write_Conflict; a Snapshot newer than Last_Commit_Seq; Ctx already aborted
   --  or committed; Staging owned by another transaction), after Status_Invalid_Syntax (Metadata is not a valid JSONB document,
   --  see Is_Valid_JSONB_Document) and after Status_Capacity_Exceeded. A failure after
   --  the first WAL frame was appended restores the engine and truncates the WAL back;
   --  if that truncation fails, Ctx is poisoned (CLOG (Ctx.Id) := Tx_Aborted) and all
   --  its versions are rolled back (Rollback_RAG_Tx): it can never commit those frames.
   procedure Ingest_Document
     (Engine         : in out RAG_Engine;
      Ctx            : in     Transaction_Context;
      Snapshot       : in     Commit_Seq_Number;
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
                    and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page
                    and then (if Has_Write_Conflict (Engine'Old, Doc_Id, Ctx.Id, Snapshot)
                              then Status = Status_Tx_Aborted);

   --  Execute a Hybrid SQL + JSONB (`@>`) + Lexical + HNSW Vector + TOAST + GraphRAG
   --  query at MVCC Snapshot (a commit sequence number, see Take_Snapshot). SQL_Query
   --  must be a valid SELECT (Status_Invalid_Syntax otherwise); of its clauses only the
   --  row window is applied: LIMIT n / FETCH FIRST n caps the hits below Top_K and
   --  OFFSET n skips the first n ranked hits. LIMIT $n / OFFSET $n are rejected
   --  (Status_Invalid_Syntax: the query vector is the only bound parameter) and so is
   --  a window ending past rank Max_RAG_Hits (Status_Capacity_Exceeded). A Snapshot
   --  newer than Engine.Last_Commit_Seq is refused with Status_Tx_Aborted, and so is
   --  one older than Engine.Read_Horizon (a version it may need was dropped). Every
   --  visible document is ranked by its Stage-2 distance; with Use_Keyword_Boost, a
   --  document whose summary contains Keyword (Contains_Keyword) ranks with half its
   --  distance and that halved distance is the hit's Distance; equal distances rank
   --  keyword matches first, then the lower Doc_Id.
   procedure Execute_Hybrid_RAG_Query
     (Engine            : in     RAG_Engine;
      Snapshot          : in     Commit_Seq_Number;
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
