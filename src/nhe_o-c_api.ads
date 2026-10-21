--  Formally verified C ABI / FFI SDK Layer for Nhe_O (ADR-005 / BR-007)
--  Exposes Convention => C symbols in 100% pragma SPARK_Mode (On) with zero
--  preconditions (all C inputs are defensively validated before crossing into
--  bounded SPARK types).
pragma SPARK_Mode (On);

with Interfaces;        use Interfaces;
with Interfaces.C;      use Interfaces.C;
with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.Vector;      use Nhe_O.Vector;
with Nhe_O.Transaction; use Nhe_O.Transaction;
with Nhe_O.KV;          use Nhe_O.KV;
with Nhe_O.PubSub;      use Nhe_O.PubSub;
with Nhe_O.RAG;         use Nhe_O.RAG;
with Nhe_O.IO;

package Nhe_O.C_API is

   --  C ABI Status Codes (mapped from Nhe_O.Types.Engine_Status)
   C_Status_Ok                 : constant int := 0;
   C_Status_Not_Found          : constant int := 1;
   C_Status_Expired            : constant int := 2;
   C_Status_Invalid_Syntax     : constant int := 3;
   C_Status_Type_Mismatch      : constant int := 4;
   C_Status_Dimension_Mismatch : constant int := 5;
   C_Status_Capacity_Exceeded  : constant int := 6;
   C_Status_Tx_Aborted         : constant int := 7;
   C_Status_IO_Error           : constant int := 8;
   C_Status_Invalid_Arg        : constant int := 9;
   C_Status_Not_Initialized    : constant int := 10;

   --  Fixed-capacity C buffers matching Bounded_Ident (64B), Bounded_Text (512B), and Vector (4096 floats)
   subtype C_Ident_Index is size_t range 1 .. size_t (Max_Ident_Len);
   subtype C_Ident_Buf is char_array (C_Ident_Index);

   subtype C_Text_Index is size_t range 1 .. size_t (Max_Text_Len);
   subtype C_Text_Buf is char_array (C_Text_Index);

   subtype C_Toast_Index is size_t range 1 .. size_t (Max_TOAST_Payload_Bytes);
   subtype C_Toast_Buf is char_array (C_Toast_Index);

   subtype C_Vec_Index is size_t range 1 .. size_t (Max_Vector_Dim);
   type C_Vec_Buf is array (C_Vec_Index) of C_float
     with Convention => C;

   --  Embedded C runtime state (KV Store, Pub/Sub Broker, Hybrid RAG Engine, and configurable
   --  paths). The C ABI drives ONE process-wide engine and is NOT thread-safe: callers must
   --  serialize every nhe_o_* call (the Python SDK holds a process-wide lock).
   G_Initialized    : Boolean       := False;
   --  Process that opened the engine. A forked child inherits a copy of this state but
   --  not the files: in any other process every stateful call returns
   --  C_Status_Not_Initialized, and nhe_o_close / a new open only drop that copy (no
   --  checkpoint, no file touched, the parent's locks stay with the parent).
   G_Owner_Pid      : Natural       := 0;
   G_Ephemeral      : Boolean       := False; --  scratch paths created by nhe_o_init
   G_Next_Tx        : Valid_Tx_Id   := 1;
   G_Next_KV_Seq    : Valid_Tx_Id   := 1;
   G_DB_Path        : Bounded_Text  := (Length => 0, Data => [others => ' ']);
   G_WAL_Path       : Bounded_Text  := (Length => 0, Data => [others => ' ']);
   G_KV_Store       : KV_Store      := (others => <>);
   G_Broker         : PubSub_Broker := (others => <>);
   G_RAG_Engine     : RAG_Engine    := (others => <>);
   --  Static scratch engine used by the checkpoint (keeps a RAG_Engine copy off the
   --  caller's stack)
   G_Scratch_Engine : RAG_Engine    := (others => <>);
   --  Set by an I/O failure on a durable write path (WAL append, commit materialization,
   --  checkpoint rename). Once set, every write returns C_Status_IO_Error until
   --  nhe_o_init_with_paths reopens the database and recovery re-derives the durable
   --  state from disk; reads keep serving the in-memory state.
   G_Write_Fault    : Boolean       := False;
   --  Exclusive flock(2) locks on the open database and WAL files: while they are held
   --  a second open of either file - by another process, or by this one through a
   --  second descriptor - is refused. A checkpoint locks its new WAL before renaming it
   --  over the old one, so the WAL lock never lapses.
   G_DB_Lock        : Nhe_O.IO.File_Lock := Nhe_O.IO.No_Lock;
   G_WAL_Lock       : Nhe_O.IO.File_Lock := Nhe_O.IO.No_Lock;

   --  Automatic checkpoint thresholds (see C_Checkpoint): a checkpoint runs after a
   --  durable write once the WAL holds Checkpoint_WAL_Frames frames or a transaction /
   --  KV sequence id reaches Checkpoint_Tx_Id, keeping both far below their hard caps
   --  (Max_WAL_Frames = 4096, Max_Tx_Id = 8192) and bounding per-commit WAL scans.
   Checkpoint_WAL_Frames : constant := 512;
   Checkpoint_Tx_Id      : constant := 4096;

   --  Map Engine_Status to C int status code
   function To_C_Status (S : Engine_Status) return int
     with Global => null;

   --  Return Nhe_O major version (0)
   function C_Version_Major return int
     with Global        => null,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_version_major";

   --  Return Nhe_O minor version (4 = Epic 04 crash-safe WAL repair, checkpoint & SI)
   function C_Version_Minor return int
     with Global        => null,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_version_minor";

   --  Initialize / reset the embedded runtime as a scratch database (Dim = 3) on the
   --  per-process paths /tmp/nhe_o_c_api.<pid>.db / .wal: earlier contents of those
   --  files are deleted and both are recreated with O_EXCL, so a link planted at the
   --  predictable names is refused, never followed (C_Status_IO_Error if a file cannot
   --  be removed or created); nhe_o_close removes them again
   procedure C_Init (Out_Status : out int)
     with Global        => (In_Out => (G_DB_Lock, G_WAL_Lock),
                            Output => (G_Initialized, G_Owner_Pid, G_Ephemeral, G_Next_Tx,
                                       G_Next_KV_Seq, G_DB_Path,
                                       G_WAL_Path, G_KV_Store, G_Broker, G_RAG_Engine,
                                       G_Write_Fault)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_init";

   --  Initialize embedded Nhe_O C runtime state with caller-specified DB/WAL paths
   --  and embedding dimension Dim in 1 .. 4096, recovering existing state when present
   --  (the scratch files of a previous nhe_o_init database are deleted first).
   --  Relative paths are resolved against the current directory once, here; after that
   --  resolution the WAL path must leave room for the 5-byte ".ckpt" checkpoint suffix
   --  (at most Max_Text_Len - 5 bytes). The database, the WAL and "<wal>.ckpt" must be
   --  three different files, also through links, and an existing database must not
   --  start with the WAL frame magic (swapped arguments) - C_Status_Invalid_Arg. Both
   --  files are created when missing (with their directory fsynced). Recovery repairs a
   --  torn WAL / database tail left by a crash (a WAL path naming a file that is not a
   --  WAL fails with C_Status_IO_Error and is left untouched), replays KV and committed
   --  RAG work, and finally checkpoints the WAL when it is past the automatic
   --  thresholds (or its id space was exhausted by an older version).
   procedure C_Init_With_Paths
     (DB_Path_Buf  : in     C_Text_Buf;
      DB_Path_Len  : in     int;
      WAL_Path_Buf : in     C_Text_Buf;
      WAL_Path_Len : in     int;
      Dim          : in     int;
      Out_Status   :    out int)
     with Global        => (In_Out => (G_Owner_Pid, G_Ephemeral, G_DB_Path, G_WAL_Path,
                                       G_Scratch_Engine, G_DB_Lock, G_WAL_Lock),
                            Output => (G_Initialized, G_Next_Tx, G_Next_KV_Seq, G_KV_Store,
                                       G_Broker, G_RAG_Engine, G_Write_Fault)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_init_with_paths";

   --  Release the runtime: a database opened with nhe_o_init_with_paths is first
   --  checkpointed (best effort, so the next open replays a compact WAL that also
   --  carries the current LRU recency) and its files are kept; the scratch files of an
   --  nhe_o_init database are deleted. State is cleared and G_Initialized becomes False.
   --  C_Status_IO_Error reports that a scratch file could not be removed; the runtime is
   --  released either way.
   procedure C_Close (Out_Status : out int)
     with Global        => (In_Out => (G_Initialized, G_Owner_Pid, G_Ephemeral, G_DB_Path, G_WAL_Path,
                                       G_KV_Store, G_Next_Tx, G_Next_KV_Seq, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_DB_Lock,
                                       G_WAL_Lock),
                            Output => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_close";

   --  Checkpoint the WAL: freeze every live RAG version (transaction ids restart at 2),
   --  write a fresh WAL "<wal>.ckpt" holding one slot-hinted SET frame per KV entry plus
   --  a commit frame carrying the frozen Page 1, atomically rename it over the old WAL,
   --  and fsync the directory. The rename is the commit point: a crash before it keeps
   --  the old WAL, a crash after it recovers from the new one, and both describe the
   --  same logical database. Refused (C_Status_IO_Error) while G_Write_Fault is set; a
   --  failed directory fsync after the rename sets it. Runs automatically after durable
   --  writes once Checkpoint_WAL_Frames / Checkpoint_Tx_Id is reached.
   procedure C_Checkpoint (Out_Status : out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path, G_KV_Store),
                            In_Out => (G_Next_Tx, G_Next_KV_Seq, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_checkpoint";

   --  Analyze a PostgreSQL-dialect SQL query string
   procedure C_Analyze_SQL
     (Query_Buf      : in     C_Text_Buf;
      Query_Len      : in     int;
      Out_Stmt_Kind  :    out int;
      Out_Has_Vector :    out int;
      Out_Has_JSONB  :    out int;
      Out_Status     :    out int)
     with Global        => null,
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_analyze_sql";

   --  Compute 3D L2 Euclidean distance (`<->`) and Cosine distance (`<=>`)
   procedure C_Vector_Distance_3D
     (AX, AY, AZ     : in     C_float;
      BX, BY, BZ     : in     C_float;
      Out_L2_Dist    :    out C_float;
      Out_Cos_Dist   :    out C_float;
      Out_Hamming    :    out int;
      Out_Status     :    out int)
     with Global        => null,
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_vector_distance_3d";

   --  Compute N-D (1 .. 4096) L2 distance, Cosine distance, and 1-bit Hamming distance
   procedure C_Vector_Distance_ND
     (A_Buf        : in     C_Vec_Buf;
      B_Buf        : in     C_Vec_Buf;
      Dim          : in     int;
      Out_L2_Dist  :    out C_float;
      Out_Cos_Dist :    out C_float;
      Out_Hamming  :    out int;
      Out_Status   :    out int)
     with Global        => null,
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_vector_distance_nd";

   --  Redis SET / SETEX operation via C ABI (durable WAL append, rejects TTL_Sec < 0)
   procedure C_KV_Set
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Val_Buf    : in     C_Text_Buf;
      Val_Len    : in     int;
      Now_Sec    : in     Integer_64;
      TTL_Sec    : in     Integer_64;
      Out_Status :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store, G_Next_Tx, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_set";

   --  Redis GET operation via C ABI: writes Out_Val_Buf (1 .. Out_Val_Len), plus a NUL at
   --  Out_Val_Len + 1 when the value is shorter than the buffer
   procedure C_KV_Get
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      Out_Val_Buf : in out C_Text_Buf;
      Out_Val_Len :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid),
                            In_Out => G_KV_Store),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_get";

   --  Redis DEL operation at timestamp Now_Sec via C ABI (durable WAL append);
   --  Out_Removed = 1 iff the key was live (present and not expired) at Now_Sec
   procedure C_KV_Del
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      Out_Removed :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store, G_Next_Tx, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_del";

   --  Redis EXISTS operation via C ABI
   procedure C_KV_Exists
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Now_Sec    : in     Integer_64;
      Out_Exists :    out int;
      Out_Status :    out int)
     with Global        => (Input => (G_Initialized, G_Owner_Pid, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_exists";

   --  Redis EXPIRE operation via C ABI
   procedure C_KV_Expire
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      TTL_Sec     : in     Integer_64;
      Out_Updated :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store, G_Next_Tx, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_expire";

   --  Redis TTL operation via C ABI
   procedure C_KV_TTL
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Now_Sec    : in     Integer_64;
      Out_TTL    :    out Integer_64;
      Out_Status :    out int)
     with Global        => (Input => (G_Initialized, G_Owner_Pid, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_ttl";

   --  Redis INCRBY operation via C ABI
   procedure C_KV_Incr_By
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Delta_Val   : in     Integer_64;
      Now_Sec     : in     Integer_64;
      Out_New_Val :    out Integer_64;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store, G_Next_Tx, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_incr_by";

   --  Pub/Sub SUBSCRIBE via C ABI
   procedure C_PubSub_Subscribe
     (Pattern_Buf : in     C_Ident_Buf;
      Pattern_Len : in     int;
      Out_Sub_Id  :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid),
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_subscribe";

   --  Pub/Sub UNSUBSCRIBE via C ABI
   procedure C_PubSub_Unsubscribe
     (Sub_Id     : in     int;
      Out_Status :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid),
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_unsubscribe";

   --  Pub/Sub PUBLISH via C ABI
   procedure C_PubSub_Publish
     (Chan_Buf      : in     C_Ident_Buf;
      Chan_Len      : in     int;
      Payload_Buf   : in     C_Text_Buf;
      Payload_Len   : in     int;
      Out_Delivered :    out int;
      Out_Status    :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid),
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_publish";

   --  Pub/Sub POLL via C ABI: writes 1 .. Out_*_Len of each buffer, plus a NUL after the
   --  text when it is shorter than the buffer
   procedure C_PubSub_Poll
     (Sub_Id          : in     int;
      Out_Chan_Buf    : in out C_Ident_Buf;
      Out_Chan_Len    :    out int;
      Out_Payload_Buf : in out C_Text_Buf;
      Out_Payload_Len :    out int;
      Out_Found       :    out int;
      Out_Status      :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid),
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_poll";

   --  Hybrid RAG Document Ingestion (3D embedding + TOAST parent chunk + WAL commit) via C ABI;
   --  the summary doubles as the parent chunk, so Summary_Len must be at least 1
   procedure C_RAG_Ingest_3D
     (Doc_Id         : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      VX, VY, VZ     : in     C_float;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path, G_KV_Store),
                            In_Out => (G_Next_Tx, G_Next_KV_Seq, G_Broker, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_ingest_3d";

   --  Hybrid RAG Document Ingestion for N-D vectors (1 .. 4096-D); the summary doubles as
   --  the parent chunk, so Summary_Len must be at least 1
   procedure C_RAG_Ingest_ND
     (Doc_Id         : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      Vec_Buf        : in     C_Vec_Buf;
      Dim            : in     int;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path, G_KV_Store),
                            In_Out => (G_Next_Tx, G_Next_KV_Seq, G_Broker, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_ingest_nd";

   --  Hybrid RAG Document Ingestion with JSONB Metadata + Full 16KB TOAST Parent Payload.
   --  Parent_Len = 0 stores the summary as the parent chunk; C_Status_Invalid_Arg when
   --  both Summary_Len and Parent_Len are 0. Every RAG write is one transaction: a
   --  C_Status_Ok return means its commit barrier is durable in the WAL.
   procedure C_RAG_Ingest_Full_ND
     (Doc_Id         : in     int;
      Meta_JSON_Buf  : in     C_Text_Buf;
      Meta_JSON_Len  : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      Parent_Buf     : in     C_Toast_Buf;
      Parent_Len     : in     int;
      Vec_Buf        : in     C_Vec_Buf;
      Dim            : in     int;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path, G_KV_Store),
                            In_Out => (G_Next_Tx, G_Next_KV_Seq, G_Broker, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_ingest_full_nd";

   --  Durable Hybrid RAG Document Deletion via C ABI
   procedure C_RAG_Delete
     (Doc_Id     : in     int;
      Out_Status :    out int)
     with Global        => (Input  => (G_Initialized, G_Owner_Pid, G_DB_Path, G_WAL_Path, G_KV_Store),
                            In_Out => (G_Next_Tx, G_Next_KV_Seq, G_Broker, G_RAG_Engine,
                                       G_Scratch_Engine, G_Write_Fault, G_WAL_Lock)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_delete";

   --  Hybrid RAG Query (3D) via C ABI; Out_Parent_Bytes is the full byte length of the
   --  top hit's TOAST parent chunk (no text is returned)
   procedure C_RAG_Query_3D
     (QX, QY, QZ       : in     C_float;
      Encoding_Mode    : in     int;
      Keyword_Buf      : in     C_Text_Buf;
      Keyword_Len      : in     int;
      Top_K            : in     int;
      Out_Hit_Count    :    out int;
      Out_Top_Doc_Id   :    out int;
      Out_Top_Distance :    out C_float;
      Out_Parent_Bytes :    out int;
      Out_Graph_Hit    :    out int;
      Out_Status       :    out int)
     with Global        => (Input => (G_Initialized, G_Owner_Pid, G_DB_Path, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_query_3d";

   --  Hybrid RAG Query for N-D vectors (1 .. 4096-D) returning at most the first 512
   --  bytes of the retrieved TOAST parent text in Out_Parent_Buf; Out_Parent_Len is the
   --  number of bytes written (use nhe_o_rag_query_full_nd for the full 16 KB chunk)
   procedure C_RAG_Query_ND
     (Query_Vec_Buf    : in     C_Vec_Buf;
      Dim              : in     int;
      Encoding_Mode    : in     int;
      Keyword_Buf      : in     C_Text_Buf;
      Keyword_Len      : in     int;
      Top_K            : in     int;
      Out_Hit_Count    :    out int;
      Out_Top_Doc_Id   :    out int;
      Out_Top_Distance :    out C_float;
      Out_Parent_Buf   : in out C_Text_Buf;
      Out_Parent_Len   :    out int;
      Out_Graph_Hit    :    out int;
      Out_Status       :    out int)
     with Global        => (Input => (G_Initialized, G_Owner_Pid, G_DB_Path, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_query_nd";

   --  Hybrid RAG Query with JSONB `@>` Filter + Full 16KB TOAST Parent Output Buffer
   procedure C_RAG_Query_Full_ND
     (Query_Vec_Buf    : in     C_Vec_Buf;
      Dim              : in     int;
      Encoding_Mode    : in     int;
      Filter_JSON_Buf  : in     C_Text_Buf;
      Filter_JSON_Len  : in     int;
      Keyword_Buf      : in     C_Text_Buf;
      Keyword_Len      : in     int;
      Top_K            : in     int;
      Out_Hit_Count    :    out int;
      Out_Top_Doc_Id   :    out int;
      Out_Top_Distance :    out C_float;
      Out_Parent_Buf   : in out C_Toast_Buf;
      Out_Parent_Len   :    out int;
      Out_Graph_Hit    :    out int;
      Out_Status       :    out int)
     with Global        => (Input => (G_Initialized, G_Owner_Pid, G_DB_Path, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_query_full_nd";

end Nhe_O.C_API;
