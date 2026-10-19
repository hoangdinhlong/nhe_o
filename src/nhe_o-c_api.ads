--  Formally verified C ABI / FFI SDK Layer for Nhe_O (Epic 03 / ADR-005 / HIGH-01 / HIGH-02 / HIGH-08)
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

   --  Embedded C runtime state (KV Store, Pub/Sub Broker, Hybrid RAG Engine, and configurable paths)
   G_Initialized : Boolean       := False;
   G_Next_Tx     : Valid_Tx_Id   := 1;
   G_Next_KV_Seq : Valid_Tx_Id   := 1;
   G_DB_Path     : Bounded_Text  := (Length => 0, Data => [others => ' ']);
   G_WAL_Path    : Bounded_Text  := (Length => 0, Data => [others => ' ']);
   G_KV_Store    : KV_Store      := (others => <>);
   G_Broker      : PubSub_Broker := (others => <>);
   G_RAG_Engine  : RAG_Engine    := (others => <>);

   --  Map Engine_Status to C int status code
   function To_C_Status (S : Engine_Status) return int
     with Global => null;

   --  Return Nhe_O major version (0)
   function C_Version_Major return int
     with Global        => null,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_version_major";

   --  Return Nhe_O minor version (3 = Epic 03/04 Formal Proof & Hardened C FFI SDK)
   function C_Version_Minor return int
     with Global        => null,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_version_minor";

   --  Initialize / reset embedded Nhe_O C runtime state with default paths and Dim = 3
   procedure C_Init (Out_Status : out int)
     with Global        => (Output => (G_Initialized, G_Next_Tx, G_Next_KV_Seq, G_DB_Path,
                                       G_WAL_Path, G_KV_Store, G_Broker, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_init";

   --  Initialize embedded Nhe_O C runtime state with caller-specified DB/WAL paths
   --  and embedding dimension Dim in 1 .. 4096, recovering existing state when present (R2-CRIT-02)
   procedure C_Init_With_Paths
     (DB_Path_Buf  : in     C_Text_Buf;
      DB_Path_Len  : in     int;
      WAL_Path_Buf : in     C_Text_Buf;
      WAL_Path_Len : in     int;
      Dim          : in     int;
      Out_Status   :    out int)
     with Global        => (Output => (G_Initialized, G_Next_Tx, G_Next_KV_Seq, G_DB_Path,
                                       G_WAL_Path, G_KV_Store, G_Broker, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_init_with_paths";

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

   --  Compute N-D (1 .. 4096) L2 distance, Cosine distance, and 1-bit Hamming distance (HIGH-02)
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

   --  Redis SET / SETEX operation via C ABI (durable WAL append, rejects TTL_Sec < 0, HIGH-01/08, R2-CRIT-02)
   procedure C_KV_Set
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Val_Buf    : in     C_Text_Buf;
      Val_Len    : in     int;
      Now_Sec    : in     Integer_64;
      TTL_Sec    : in     Integer_64;
      Out_Status :    out int)
     with Global        => (Input  => (G_Initialized, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_set";

   --  Redis GET operation via C ABI (writes only 1 .. Out_Val_Len, HIGH-01)
   procedure C_KV_Get
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      Out_Val_Buf : in out C_Text_Buf;
      Out_Val_Len :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => G_Initialized,
                            In_Out => G_KV_Store),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_get";

   --  Redis DEL operation via C ABI (durable WAL append, R2-CRIT-02)
   procedure C_KV_Del
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Out_Removed :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_del";

   --  Redis EXISTS operation via C ABI (HIGH-02, HIGH-08)
   procedure C_KV_Exists
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Now_Sec    : in     Integer_64;
      Out_Exists :    out int;
      Out_Status :    out int)
     with Global        => (Input => (G_Initialized, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_exists";

   --  Redis EXPIRE operation via C ABI (HIGH-02, HIGH-08, R2-CRIT-02)
   procedure C_KV_Expire
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      TTL_Sec     : in     Integer_64;
      Out_Updated :    out int;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_expire";

   --  Redis TTL operation via C ABI (HIGH-02, HIGH-08)
   procedure C_KV_TTL
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Now_Sec    : in     Integer_64;
      Out_TTL    :    out Integer_64;
      Out_Status :    out int)
     with Global        => (Input => (G_Initialized, G_KV_Store)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_kv_ttl";

   --  Redis INCRBY operation via C ABI (R2-CRIT-02)
   procedure C_KV_Incr_By
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Delta_Val   : in     Integer_64;
      Now_Sec     : in     Integer_64;
      Out_New_Val :    out Integer_64;
      Out_Status  :    out int)
     with Global        => (Input  => (G_Initialized, G_WAL_Path),
                            In_Out => (G_Next_KV_Seq, G_KV_Store)),
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
     with Global        => (Input  => G_Initialized,
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_subscribe";

   --  Pub/Sub UNSUBSCRIBE via C ABI (HIGH-02)
   procedure C_PubSub_Unsubscribe
     (Sub_Id     : in     int;
      Out_Status :    out int)
     with Global        => (Input  => G_Initialized,
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
     with Global        => (Input  => G_Initialized,
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_publish";

   --  Pub/Sub POLL via C ABI (writes only 1 .. Out_*_Len, HIGH-01)
   procedure C_PubSub_Poll
     (Sub_Id          : in     int;
      Out_Chan_Buf    : in out C_Ident_Buf;
      Out_Chan_Len    :    out int;
      Out_Payload_Buf : in out C_Text_Buf;
      Out_Payload_Len :    out int;
      Out_Found       :    out int;
      Out_Status      :    out int)
     with Global        => (Input  => G_Initialized,
                            In_Out => G_Broker),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_pubsub_poll";

   --  Hybrid RAG Document Ingestion (3D embedding + TOAST parent chunk + WAL commit) via C ABI
   procedure C_RAG_Ingest_3D
     (Doc_Id         : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      VX, VY, VZ     : in     C_float;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
     with Global        => (Input  => (G_Initialized, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_Tx, G_Broker, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_ingest_3d";

   --  Hybrid RAG Document Ingestion for N-D vectors (1 .. 4096-D, HIGH-02)
   procedure C_RAG_Ingest_ND
     (Doc_Id         : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      Vec_Buf        : in     C_Vec_Buf;
      Dim            : in     int;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
     with Global        => (Input  => (G_Initialized, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_Tx, G_Broker, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_ingest_nd";

   --  Hybrid RAG Document Ingestion with JSONB Metadata + Full 16KB TOAST Parent Payload (R2-LOW-03)
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
     with Global        => (Input  => (G_Initialized, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_Tx, G_Broker, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_ingest_full_nd";

   --  Durable Hybrid RAG Document Deletion via C ABI (R2-HIGH-01)
   procedure C_RAG_Delete
     (Doc_Id     : in     int;
      Out_Status :    out int)
     with Global        => (Input  => (G_Initialized, G_DB_Path, G_WAL_Path),
                            In_Out => (G_Next_Tx, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_delete";

   --  Hybrid RAG Query (3D) via C ABI
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
     with Global        => (Input => (G_Initialized, G_DB_Path, G_Next_Tx, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_query_3d";

   --  Hybrid RAG Query for N-D vectors (1 .. 4096-D) returning retrieved TOAST
   --  parent text in Out_Parent_Buf (HIGH-01, HIGH-02)
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
     with Global        => (Input => (G_Initialized, G_DB_Path, G_Next_Tx, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_query_nd";

   --  Hybrid RAG Query with JSONB `@>` Filter + Full 16KB TOAST Parent Output Buffer (R2-LOW-03)
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
     with Global        => (Input => (G_Initialized, G_DB_Path, G_Next_Tx, G_RAG_Engine)),
          Always_Terminates,
          Export        => True,
          Convention    => C,
          External_Name => "nhe_o_rag_query_full_nd";

end Nhe_O.C_API;
