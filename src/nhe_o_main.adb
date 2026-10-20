--  Formally Verified Entrypoint & CLI for Nhe_O Embedded DBMS (SPARK_Mode => On)
pragma SPARK_Mode (On);

with Interfaces;        use Interfaces;
with Interfaces.C;      use Interfaces.C;
with Nhe_O;
with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.Vector;      use Nhe_O.Vector;
with Nhe_O.JSON;        use Nhe_O.JSON;
with Nhe_O.IO;          use Nhe_O.IO;
with Nhe_O.Transaction; use Nhe_O.Transaction;
with Nhe_O.BTree;       use Nhe_O.BTree;
with Nhe_O.HNSW;        use Nhe_O.HNSW;
with Nhe_O.KV;          use Nhe_O.KV;
with Nhe_O.PubSub;      use Nhe_O.PubSub;
with Nhe_O.SQL;         use Nhe_O.SQL;
with Nhe_O.RAG;         use Nhe_O.RAG;
with Nhe_O.C_API;       use Nhe_O.C_API;

procedure Nhe_O_Main is

   pragma Warnings (GNATprove, Off, "is set by");
   pragma Warnings (GNATprove, Off, "statement has no effect");

   All_Passed : Boolean := True;

   procedure Check (Cond : in Boolean)
     with Global => (In_Out => All_Passed),
          Always_Terminates
   is
   begin
      if not Cond then
         All_Passed := False;
         Set_Exit_Failure;
      end if;
   end Check;

   --  Parse positive integer TTL from Bounded_Text (fallback Default_TTL on empty/invalid)
   procedure Parse_Positive_Int
     (Text    : in     Bounded_Text;
      Default : in     Integer_64;
      Result  :    out Integer_64;
      Valid   :    out Boolean)
     with Global => null,
          Always_Terminates
   is
      Acc   : Integer_64 := 0;
      Digit : Integer_64;
   begin
      if Text.Length = 0 or else Text.Length > 9 then
         Result := Default;
         Valid  := False;
         return;
      end if;
      for I in 1 .. Text.Length loop
         pragma Loop_Invariant (Acc in 0 .. 1_000_000_000);
         declare
            Ch : constant Character := Text.Data (I);
         begin
            if Ch not in '0' .. '9' then
               Result := Default;
               Valid  := False;
               return;
            end if;
            Digit := Integer_64 (Character'Pos (Ch) - Character'Pos ('0'));
            if Acc <= (1_000_000_000 - Digit) / 10 then
               Acc := Acc * 10 + Digit;
            else
               Result := Default;
               Valid  := False;
               return;
            end if;
         end;
      end loop;
      if Acc >= 1 then
         Result := Acc;
         Valid  := True;
      else
         Result := Default;
         Valid  := False;
      end if;
   end Parse_Positive_Int;

   --  Execute CLI command mode (--sql, --kv, --rag-demo)
   procedure Run_CLI_Command
     (Arg1 : in     Bounded_Text;
      Done :    out Boolean)
     with Always_Terminates
   is
      Arg2      : Bounded_Text;
      Arg3      : Bounded_Text;
      Arg4      : Bounded_Text;
      Arg5      : Bounded_Text;
      Has_Arg2  : Boolean;
      Has_Arg3  : Boolean;
      Has_Arg4  : Boolean;
      Has_Arg5  : Boolean;
      Long_Arg2 : Boolean;
      Long_Arg3 : Boolean;
      Long_Arg4 : Boolean;
      Long_Arg5 : Boolean;
      Key_Arg   : Bounded_Text;
      Val_Arg   : Bounded_Text;
      TTL_Val   : Integer_64 := 300;
      TTL_Valid : Boolean;
      Desc      : Parsed_SQL_Descriptor;
      Status    : Engine_Status;
      C_Rc      : int;
      K_Buf     : C_Ident_Buf := [others => nul];
      V_Buf     : C_Text_Buf  := [others => nul];
      Out_V_Buf : C_Text_Buf  := [others => nul];
      Out_V_Len : int;
      Hit_Cnt   : int;
      Top_Doc   : int;
      Top_Dist  : C_float;
      Par_Bytes : int;
      Graph_Hit : int;
   begin
      if Equal_Text (Arg1, Make_Text ("--sql")) then
         Read_CLI_Arg (2, Arg2, Has_Arg2, Long_Arg2);
         if Long_Arg2 then
            Print_Line ("[CLI --sql] Error: argument exceeds 512-byte Bounded_Text capacity.");
            Check (False);
            Done := True;
            return;
         end if;
         if not Has_Arg2 then
            Arg2 := Make_Text ("SELECT id FROM docs WHERE meta @> $1::jsonb ORDER BY emb <-> $2;");
         end if;
         Analyze_SQL (Arg2, Desc, Status);
         Print_Line ("[CLI --sql] Status_Ok        : " & Boolean'Image (Status = Status_Ok));
         Print_Line ("[CLI --sql] Statement_Kind   : " & SQL_Statement_Kind'Image (Desc.Kind));
         Print_Line ("[CLI --sql] Has_Vector_Op    : " & Boolean'Image (Desc.Has_Vector_Operator));
         Print_Line ("[CLI --sql] Has_JSONB_Op     : " & Boolean'Image (Desc.Has_JSONB_Operator));
         Check (Status = Status_Ok);
         Done := True;
      elsif Equal_Text (Arg1, Make_Text ("--kv")) then
         Read_CLI_Arg (2, Arg2, Has_Arg2, Long_Arg2);
         Read_CLI_Arg (3, Arg3, Has_Arg3, Long_Arg3);
         Read_CLI_Arg (4, Arg4, Has_Arg4, Long_Arg4);
         Read_CLI_Arg (5, Arg5, Has_Arg5, Long_Arg5);
         if Long_Arg2 or else Long_Arg3 or else Long_Arg4 or else Long_Arg5 then
            Print_Line ("[CLI --kv] Error: CLI argument exceeds 512-byte capacity.");
            Check (False);
            Done := True;
            return;
         end if;

         --  Support both `--kv SET <key> <val> [ttl]` and `--kv <key> <val> [ttl]`
         if Has_Arg2 and then (Equal_Text (Arg2, Make_Text ("SET")) or else Equal_Text (Arg2, Make_Text ("set"))) then
            Key_Arg := (if Has_Arg3 then Arg3 else Make_Text ("cli:default:key"));
            Val_Arg := (if Has_Arg4 then Arg4 else Make_Text ("verified_spark_value"));
            if Has_Arg5 then
               Parse_Positive_Int (Arg5, 300, TTL_Val, TTL_Valid);
               Check (TTL_Valid);
            end if;
         else
            Key_Arg := (if Has_Arg2 then Arg2 else Make_Text ("cli:default:key"));
            Val_Arg := (if Has_Arg3 then Arg3 else Make_Text ("verified_spark_value"));
            if Has_Arg4 then
               Parse_Positive_Int (Arg4, 300, TTL_Val, TTL_Valid);
               Check (TTL_Valid);
            end if;
         end if;

         if Key_Arg.Length = 0 or else Key_Arg.Length > Max_Ident_Len then
            Key_Arg := Make_Text ("cli:default:key");
         end if;
         for I in 1 .. Key_Arg.Length loop
            K_Buf (size_t (I)) := To_C (Key_Arg.Data (I));
         end loop;
         for I in 1 .. Val_Arg.Length loop
            V_Buf (size_t (I)) := To_C (Val_Arg.Data (I));
         end loop;
         C_Init (C_Rc);
         C_KV_Set (K_Buf, int (Key_Arg.Length), V_Buf, int (Val_Arg.Length), 1000, TTL_Val, C_Rc);
         C_KV_Get (K_Buf, int (Key_Arg.Length), 1010, Out_V_Buf, Out_V_Len, C_Rc);
         Print_Line ("[CLI --kv] Stored & Retrieved Length : " & int'Image (Out_V_Len));
         Check (C_Rc = C_Status_Ok and then Out_V_Len = int (Val_Arg.Length));
         Done := True;
      elsif Equal_Text (Arg1, Make_Text ("--rag-demo")) then
         C_Init (C_Rc);
         Check (C_Rc = C_Status_Ok);
         V_Buf (1) := To_C ('Q');
         V_Buf (2) := To_C ('w');
         V_Buf (3) := To_C ('e');
         V_Buf (4) := To_C ('n');
         C_RAG_Ingest_3D (1, V_Buf, 4, 1.0, 0.0, 0.0, 2, C_Rc);
         Check (C_Rc = C_Status_Ok);
         C_RAG_Ingest_3D (2, V_Buf, 4, 0.8, 0.2, 0.0, 1, C_Rc);
         Check (C_Rc = C_Status_Ok);
         C_RAG_Query_3D (1.0, 0.0, 0.0, 0, V_Buf, 4, 2, Hit_Cnt, Top_Doc, Top_Dist, Par_Bytes, Graph_Hit, C_Rc);
         Print_Line ("[CLI --rag-demo] Top_Doc_Id       : " & int'Image (Top_Doc));
         Print_Line ("[CLI --rag-demo] Hit_Count        : " & int'Image (Hit_Cnt));
         Print_Line ("[CLI --rag-demo] GraphRAG_1Hop    : " & int'Image (Graph_Hit));
         Check (C_Rc = C_Status_Ok and then Hit_Cnt = 2 and then Top_Doc = 1 and then Graph_Hit = 1);
         Done := True;
      else
         Done := False;
      end if;
   end Run_CLI_Command;

   --  CLI argument state
   CLI_Arg1     : Bounded_Text;
   Has_CLI_Arg1 : Boolean;
   Long_Arg1    : Boolean;
   CLI_Handled  : Boolean;

   --  1. PostgreSQL SQL & Type variables
   SQL_Query : constant Bounded_Text := Make_Text (
     "SELECT id, meta->>'title', embedding <-> $1::vector AS dist " &
     "FROM documents WHERE meta @> '{""lang"":""vi""}'::jsonb ORDER BY dist LIMIT 5;"
   );
   SQL_Vec_Only : constant Bounded_Text := Make_Text (
     "SELECT id FROM embeddings ORDER BY vec <-> $3 LIMIT 10;"
   );
   SQL_Quoted_Noise : constant Bounded_Text := Make_Text (
     "SELECT returning_user FROM my_table WHERE note = '$1::jsonb -> a <-> b RETURNING';"
   );
   SQL_Create_Idx : constant Bounded_Text := Make_Text (
     "CREATE INDEX idx_vec ON my_table (vec);"
   );
   SQL_Create_Tbl : constant Bounded_Text := Make_Text (
     "CREATE TABLE docs (id BIGINT, view_count INT, index_ref INT, emb VECTOR(4096));"
   );
   SQL_Tight_QMark : constant Bounded_Text := Make_Text (
     "SELECT id FROM docs WHERE meta?'title';"
   );
   SQL_Bad_Quote : constant Bounded_Text := Make_Text (
     "SELECT id FROM docs WHERE note = 'unterminated;"
   );
   SQL_Bad_Comment : constant Bounded_Text := Make_Text (
     "SELECT id /* unclosed comment FROM docs;"
   );
   SQL_No_Space_1 : constant Bounded_Text := Make_Text (
     "SELECT/*comment*/id FROM docs LIMIT 1;"
   );
   SQL_No_Space_2 : constant Bounded_Text := Make_Text (
     "SELECT'literal' FROM docs LIMIT 0;"
   );
   SQL_Multi_Stmt : constant Bounded_Text := Make_Text (
     "SELECT id FROM docs; DROP TABLE docs;"
   );
   SQL_Lead_Semi  : constant Bounded_Text := Make_Text (
     "; SELECT id FROM docs;"
   );
   SQL_Desc   : Parsed_SQL_Descriptor;
   SQL_Status : Engine_Status;
   Resolved_T : Pg_Data_Type;
   Type_Valid : Boolean;

   --  2. Vector Database & 4096-D Quantization variables
   Vec_A         : constant Vector_Value := Make_Vector_3D (1.0, 0.0, 0.0);
   Vec_B         : constant Vector_Value := Make_Vector_3D (1.0, 0.0, 0.0);
   Vec_C         : constant Vector_Value := Make_Vector_3D (0.0, 3.0, 4.0);
   Vec_Max       : constant Vector_Value := Make_Vector_3D (Max_Component, 0.0, 0.0);
   Vec_Small     : constant Vector_Value := Make_Vector_3D (1.0e-7, 0.0, 0.0);
   Vec_Zero      : constant Vector_Value := Make_Vector_3D (0.0, 0.0, 0.0);
   Vec_4096_A    : constant Vector_Value := (Dim => 4096, Elements => [1 => 1.0, 2048 => -1.0, 4096 => 0.5, others => 0.25]);
   Vec_4096_B    : constant Vector_Value := (Dim => 4096, Elements => [1 => 1.0, 2048 =>  1.0, 4096 => -0.5, others => 0.25]);
   Q_Int8_A      : Quantized_Int8_Vector;
   Q_Int8_B      : Quantized_Int8_Vector;
   Q_Int8_Sat    : Quantized_Int8_Vector;
   Deq_Vec_A     : Vector_Value;
   Deq_Vec_Sat   : Vector_Value;
   Q_Bin_A       : Quantized_Binary_Vector;
   Q_Bin_B       : Quantized_Binary_Vector;
   Ham_Dist      : Natural;
   Int8_Dist     : Natural;
   Int8_Scaled   : Non_Negative_Float;
   L2_AB         : Non_Negative_Float;
   L2_AC         : Non_Negative_Float;
   L2_Max        : Non_Negative_Float;
   Cos_AB        : Float;
   Cos_Max       : Float;
   Cos_Small     : Float;
   NIP_AC        : Float;
   Vec_Toast_Buf : TOAST_Payload_Buffer;
   Vec_Toast_Len : Valid_TOAST_Length;
   Vec_Dec_4096  : Vector_Value;
   Vec_Dec_Small : Vector_Value;
   Vec_Dec_Ok    : Boolean;

   --  3. PostgreSQL JSON / JSONB variables
   Raw_JSON     : constant Bounded_Text := Make_Text (
     "{""engine"":""Nhe_O"",""verified"":true,""dims"":[3,4096],""meta"":{""v"":0.3}}"
   );
   Scalar_True  : constant Bounded_Text := Make_Text ("true");
   Scalar_Num   : constant Bounded_Text := Make_Text ("42.5");
   Scalar_Str   : constant Bounded_Text := Make_Text ("""rfc8259_scalar""");
   Bad_JSON_1   : constant Bounded_Text := Make_Text ("{[}]{}");
   Bad_JSON_2   : constant Bounded_Text := Make_Text ("{""a"":1}{""b"":2}");
   Bad_JSON_3   : constant Bounded_Text := Make_Text ("{:}");
   Bad_JSON_4   : constant Bounded_Text := Make_Text ("{""a"":1,}");
   Bad_JSON_5   : constant Bounded_Text := Make_Text ("{""a"" ""b""}");
   Bad_JSON_6   : constant Bounded_Text := Make_Text ("{123:456}");
   Bad_JSON_7   : constant Bounded_Text := Make_Text ("{$$$}");
   Doc_Main     : JSONB_Document;
   Doc_Parsed   : JSONB_Document;
   Doc_Filter   : JSONB_Document;
   JSON_Stat    : Engine_Status;
   Field_Hit    : Boolean;
   Field_Val    : Bounded_Text;
   Field_Kind   : JSONB_Value_Kind;

   --  4 & 5. ACID Transaction, MVCC, WAL Recovery & 4KB TOAST Overflow variables
   Next_Tx       : Valid_Tx_Id := 1;
   Tx_1          : Transaction_Context;
   Tx_Uncomm     : Transaction_Context;
   Tx_Toast      : Transaction_Context;
   Tuple_1       : MVCC_Tuple_Header;
   Tuple_Uncomm  : MVCC_Tuple_Header;
   CLOG_Test     : Commit_Log := Default_CLOG;
   Slot_Page_In  : Slotted_Page;
   Slot_Page_Out : Slotted_Page;
   Slot_Buf      : Page_Buffer;
   Slot_Dec_Ok   : Boolean;
   Page_Out      : constant Page_Buffer := [1 => 16#4E#, 2 => 16#48#, 3 => 16#45#, 4 => 16#4F#, others => 0];
   Page_Uncomm   : constant Page_Buffer := [1 => 16#DE#, 2 => 16#AD#, others => 0];
   Page_In       : Page_Buffer;
   Dec_Page      : Page_Buffer;
   WAL_In        : WAL_Frame_Buffer;
   WAL_Uncomm    : WAL_Frame_Buffer;
   WAL_Crc       : Unsigned_32;
   Dec_Tx        : Valid_Tx_Id;
   Dec_Page_Id   : Valid_Page_Id;
   Dec_Kind      : WAL_Frame_Kind;
   DB_File       : constant Bounded_Text := Make_Text ("/tmp/nhe_o_verify.nhe_o");
   WAL_File      : constant Bounded_Text := Make_Text ("/tmp/nhe_o_verify.nhe_o.wal");
   KV_WAL_File   : constant Bounded_Text := Make_Text ("/tmp/nhe_o_kv.nhe_o.wal");
   NUL_Path      : Bounded_Text := Make_Text ("/tmp/nhe_o_bad");
   Tx_Status     : Engine_Status;
   Read_Ok       : Boolean;
   WAL_Read_Ok   : Boolean;
   WAL_EOF       : Boolean;
   WAL_App_Ok    : Boolean;
   NUL_Write_Ok  : Boolean;
   CRC_Before    : Unsigned_32;
   CRC_After     : Unsigned_32;
   Toast_Out     : constant TOAST_Payload_Buffer :=
     [1 => 16#51#, 4081 => 16#57#, 8161 => 16#45#, 10000 => 16#4E#, others => 16#2A#];
   Toast_In      : TOAST_Payload_Buffer;
   Toast_Len_Out : TOAST_Payload_Length;
   Toast_Ptr     : TOAST_Pointer;
   Toast_Bytes   : TOAST_Pointer_Bytes;
   Toast_Dec_Ptr : TOAST_Pointer;
   Toast_Ptr_Ok  : Boolean;
   Replayed_Cnt  : Natural;
   Max_Rec_Tx    : Tx_Id;

   --  6. Multi-Page B+Tree Index variables
   Tree_Idx      : BTree_Index;
   BTree_Stat    : Engine_Status;
   BTree_Hit     : Boolean;
   BTree_Del_Ok  : Boolean;
   BTree_Ptr     : BTree_Record_Pointer;
   BTree_Scan    : BTree_Scan_Result;
   BTree_Page    : Page_Buffer;
   BTree_Dec_Nd  : BTree_Node;
   BTree_Dec_Ok  : Boolean;
   Big_Key_Base  : constant Integer_64 := 5_000_000_000;

   --  7. Multi-Layer HNSW Graph Index variables
   Graph_Idx     : HNSW_Index;
   HNSW_Stat     : Engine_Status;
   KNN_Float_Res : HNSW_Search_Result;
   KNN_Int8_Res  : HNSW_Search_Result;
   KNN_Bin_Res   : HNSW_Search_Result;

   --  8. Redis-Compatible Key-Value Cache variables
   Cache      : KV_Store;
   Cache_Rec  : KV_Store;
   KV_Val     : Bounded_Text;
   KV_Status  : Engine_Status;
   KV_Removed : Boolean;
   Counter_V  : Integer_64;
   KV_Rec_Cnt : Natural;

   --  9 & 10. Dual-Mode Pub/Sub & Universal Local LLM RAG verification helper
   procedure Verify_RAG_And_PubSub (Next_Tx_Id : in out Valid_Tx_Id)
     with Pre => Next_Tx_Id <= Max_Tx_Id - 16,
          Always_Terminates
   is
      Broker         : PubSub_Broker;
      Sub_Exact      : Subscriber_Id;
      Sub_Wild       : Subscriber_Id;
      Sub_Durable    : Subscriber_Id;
      Sub_Stat       : Engine_Status;
      Deliv_Cnt      : Subscriber_Count;
      Total_Deliv    : Natural;
      Msg_Out        : PubSub_Message;
      Msg_Found      : Boolean;
      Tx_Notify_1    : Transaction_Context;
      Tx_Notify_2    : Transaction_Context;
      Staging_Buf    : Tx_Notification_Buffer;
      RAG_Store      : RAG_Engine;
      RAG_Recovered  : RAG_Engine;
      Tx_RAG         : Transaction_Context;
      Tx_RAG_Aborted : Transaction_Context;
      Tx_RAG_Del     : Transaction_Context;
      RAG_Staging    : Tx_Notification_Buffer;
      Meta_Doc_1     : JSONB_Document;
      Meta_Doc_2     : JSONB_Document;
      Meta_RAG_Query : JSONB_Document;
      Parent_Chunk_1 : constant TOAST_Payload_Buffer :=
        [1 => Character'Pos ('Q'), 2 => Character'Pos ('w'), 3 => Character'Pos ('e'), 4 => Character'Pos ('n'),
         5000 => Character'Pos ('!'), others => Character'Pos (' ')];
      Parent_Chunk_2 : constant TOAST_Payload_Buffer :=
        [1 => Character'Pos ('A'), 2 => Character'Pos ('d'), 3 => Character'Pos ('a'), others => Character'Pos ('.')];
      Fetched_Chunk  : TOAST_Payload_Buffer;
      RAG_Res        : RAG_Query_Result;
      RAG_Status     : Engine_Status;
      Local_Slot_Buf : Page_Buffer;
      Local_Tx_Stat  : Engine_Status;
      Local_JSON_St  : Engine_Status;
   begin
      --  9. Verify Dual-Mode Pub/Sub & WAL Commit Barrier (`ADR-004` / `BR-005`)
      Print_Line ("[9/11] Verifying Dual-Mode Pub/Sub & WAL Commit Barrier (Nhe_O.PubSub)...");
      Check (Matches_Channel (Make_Ident ("rag.*.indexed"), Make_Ident ("rag.doc1.indexed")));
      Check (Matches_Channel (Make_Ident ("*.invalidation"), Make_Ident ("cache.invalidation")));
      Check (Matches_Channel (Make_Ident ("*"), Make_Ident ("any.channel")));
      Check (not Matches_Channel (Make_Ident ("rag.*.indexed"), Make_Ident ("rag.doc1.deleted")));
      Subscribe (Broker, Make_Ident ("cache.invalidation"), Sub_Exact, Sub_Stat);
      Check (Sub_Stat = Status_Ok);
      Subscribe (Broker, Make_Ident ("cache.*"), Sub_Wild, Sub_Stat);
      Check (Sub_Stat = Status_Ok);
      Subscribe (Broker, Make_Ident ("rag.*"), Sub_Durable, Sub_Stat);
      Check (Sub_Stat = Status_Ok);

      Publish (Broker, Make_Ident ("cache.invalidation"), Make_Text ("key=session:42"), Deliv_Cnt);
      Check (Deliv_Cnt = 2);
      Poll_Message (Broker, Sub_Exact, Msg_Out, Msg_Found);
      Check (Msg_Found and then Equal_Text (Msg_Out.Payload, Make_Text ("key=session:42")));
      Poll_Message (Broker, Sub_Wild, Msg_Out, Msg_Found);
      Check (Msg_Found);

      Begin_Tx (Next_Tx_Id, Tx_Notify_1);
      Stage_Notify (Tx_Notify_1, Staging_Buf, Make_Ident ("rag.abort"), Make_Text ("phantom_doc"), Sub_Stat);
      Check (Sub_Stat = Status_Ok and then Staging_Buf.Count = 1 and then Staging_Buf.Owner_Tx = Tx_Notify_1.Id);
      --  Verify Owner_Tx mismatch is rejected and foreign Discard does not wipe Owner_Tx's buffer
      Begin_Tx (Next_Tx_Id, Tx_Notify_2);
      Stage_Notify (Tx_Notify_2, Staging_Buf, Make_Ident ("rag.hijack"), Make_Text ("bad"), Sub_Stat);
      Check (Sub_Stat = Status_Tx_Aborted);
      Rollback_Tx (Tx_Notify_2);
      Discard_Staged_Notifications (Tx_Notify_2, Staging_Buf);
      Check (Staging_Buf.Count = 1 and then Staging_Buf.Owner_Tx = Tx_Notify_1.Id);

      Poll_Message (Broker, Sub_Durable, Msg_Out, Msg_Found);
      Check (not Msg_Found);
      Rollback_Tx (Tx_Notify_1);
      Discard_Staged_Notifications (Tx_Notify_1, Staging_Buf);
      Check (Staging_Buf.Count = 0);
      Poll_Message (Broker, Sub_Durable, Msg_Out, Msg_Found);
      Check (not Msg_Found);

      Begin_Tx (Next_Tx_Id, Tx_Notify_2);
      Stage_Notify (Tx_Notify_2, Staging_Buf, Make_Ident ("rag.commit"), Make_Text ("doc_id=1"), Sub_Stat);
      Check (Sub_Stat = Status_Ok);
      Commit_Tx (Tx_Notify_2, DB_File, WAL_File, 0, Page_Out, Local_Tx_Stat);
      if Local_Tx_Stat = Status_Ok and then Tx_Notify_2.State = Tx_Committed then
         Flush_Committed_Notifications (Tx_Notify_2, Staging_Buf, Broker, Total_Deliv);
         Check (Total_Deliv = 1 and then Staging_Buf.Count = 0);
      else
         Check (False);
      end if;
      Poll_Message (Broker, Sub_Durable, Msg_Out, Msg_Found);
      Check (Msg_Found and then Equal_Text (Msg_Out.Payload, Make_Text ("doc_id=1")));
      Print_Line ("  => Passed: Immediate PUBLISH, * glob wildcards, Owner_Tx guard, and WAL-Commit-Gated NOTIFY verified.");

      --  10. Verify Universal Local LLM RAG & Hybrid SQL Query Executor (`Nhe_O.RAG`)
      Print_Line ("[10/11] Verifying Universal Local LLM RAG & Hybrid SQL Executor (Nhe_O.RAG)...");
      Delete_File_If_Exists (DB_File);
      Delete_File_If_Exists (WAL_File);
      Init_RAG_Engine (RAG_Store, Dim => 3);
      Put_Field (Meta_Doc_1, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, Local_JSON_St);
      Put_Field (Meta_Doc_1, Make_Ident ("model"), Make_Text ("qwen-3.8-35b-a3b-instruct-long-metadata-value-for-rmet"), JSONB_String, Local_JSON_St);
      Put_Field (Meta_Doc_2, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, Local_JSON_St);
      Put_Field (Meta_RAG_Query, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, Local_JSON_St);

      Begin_Tx (Next_Tx_Id, Tx_RAG);
      Ingest_Document
        (Engine         => RAG_Store,
         Ctx            => Tx_RAG,
         DB_Path        => DB_File,
         WAL_Path       => WAL_File,
         Staging        => RAG_Staging,
         Doc_Id         => 2,
         Metadata       => Meta_Doc_2,
         Summary_Text   => Make_Text ("SPARK formal verification contracts"),
         Embedding      => Make_Vector_3D (0.7, 0.7, 0.0),
         Parent_Payload => Parent_Chunk_2,
         Parent_Length  => 4_200,
         Related_Doc_Id => 0,
         Layer_Hint     => 1,
         Status         => RAG_Status);
      Check (RAG_Status = Status_Ok);

      if RAG_Store.Next_TOAST_Pg <= Max_Safe_TOAST_Page then
         Ingest_Document
           (Engine         => RAG_Store,
            Ctx            => Tx_RAG,
            DB_Path        => DB_File,
            WAL_Path       => WAL_File,
            Staging        => RAG_Staging,
            Doc_Id         => 1,
            Metadata       => Meta_Doc_1,
            Summary_Text   => Make_Text ("Qwen 3.8 35B A3B local LLM hybrid RAG guide with extended summary exceeding 79 inline bytes [TAIL_KEYWORD]"),
            Embedding      => Make_Vector_3D (1.0, 0.0, 0.0),
            Parent_Payload => Parent_Chunk_1,
            Parent_Length  => 6_000,
            Related_Doc_Id => 2,
            Layer_Hint     => 3,
            Status         => RAG_Status);
         Check (RAG_Status = Status_Ok and then RAG_Staging.Count = 2);
      else
         Check (False);
      end if;

      Build_RAG_Slotted_Page (RAG_Store, Tx_RAG.Id, Local_Slot_Buf);
      Commit_Tx (Tx_RAG, DB_File, WAL_File, 1, Local_Slot_Buf, Local_Tx_Stat);
      if Local_Tx_Stat = Status_Ok and then Tx_RAG.State = Tx_Committed then
         Set_CLOG_State (RAG_Store.CLOG, Tx_RAG.Id, Tx_Committed);
         Flush_Committed_Notifications (Tx_RAG, RAG_Staging, Broker, Total_Deliv);
         Check (Total_Deliv = 2);
      else
         Check (False);
      end if;

      --  Ingest an aborted update to Doc_Id = 1 and verify MVCC prior-version + Rollback_RAG_Tx
      Begin_Tx (Next_Tx_Id, Tx_RAG_Aborted);
      if RAG_Store.Next_TOAST_Pg <= Max_Safe_TOAST_Page then
         Ingest_Document
           (Engine         => RAG_Store,
            Ctx            => Tx_RAG_Aborted,
            DB_Path        => DB_File,
            WAL_Path       => WAL_File,
            Staging        => RAG_Staging,
            Doc_Id         => 1,
            Metadata       => Meta_Doc_1,
            Summary_Text   => Make_Text ("Uncommitted dirty update"),
            Embedding      => Make_Vector_3D (0.0, 1.0, 0.0),
            Parent_Payload => Parent_Chunk_2,
            Parent_Length  => 4_200,
            Related_Doc_Id => 2,
            Layer_Hint     => 3,
            Status         => RAG_Status);
         Check (RAG_Status = Status_Ok);
      end if;
      Rollback_Tx (Tx_RAG_Aborted);
      Rollback_RAG_Tx (RAG_Store, Tx_RAG_Aborted.Id);
      Discard_Staged_Notifications (Tx_RAG_Aborted, RAG_Staging);
      Check (Tx_RAG_Aborted.State = Tx_Aborted and then RAG_Staging.Count = 0);

      --  Query with Encoding_Int8_SQ8 to exercise Stage-2 TOAST Exact Re-Ranking (Q-003) and MVCC fallback
      Execute_Hybrid_RAG_Query
        (Engine            => RAG_Store,
         Snapshot          => Tx_RAG_Aborted.Id,
         DB_Path           => DB_File,
         SQL_Query         => SQL_Query,
         Query_Vec         => Make_Vector_3D (0.95, 0.05, 0.0),
         Encoding          => Encoding_Int8_SQ8,
         Use_Meta_Filter   => True,
         Filter_Meta       => Meta_RAG_Query,
         Use_Keyword_Boost => True,
         Keyword           => Make_Text ("Qwen"),
         Top_K             => 2,
         Result            => RAG_Res,
         Top_Parent_Chunk  => Fetched_Chunk,
         Status            => RAG_Status);
      Check (RAG_Status = Status_Ok);
      Check (RAG_Res.Count = 2);
      Check (RAG_Res.Hits (1).Doc_Id = 1);
      Check (RAG_Res.Hits (1).Keyword_Match);
      Check (RAG_Res.Top_Parent_Bytes = 6_000);
      Check (RAG_Res.Graph_Neighbor_Hit);
      Check (Fetched_Chunk (1) = Character'Pos ('Q') and then Fetched_Chunk (5000) = Character'Pos ('!'));

      --  Verify SQL LIMIT 1 and LIMIT 0 enforcement in Execute_Hybrid_RAG_Query
      Execute_Hybrid_RAG_Query
        (Engine            => RAG_Store,
         Snapshot          => Tx_RAG_Aborted.Id,
         DB_Path           => DB_File,
         SQL_Query         => SQL_No_Space_1,
         Query_Vec         => Make_Vector_3D (0.95, 0.05, 0.0),
         Encoding          => Encoding_Float32,
         Use_Meta_Filter   => False,
         Filter_Meta       => Meta_RAG_Query,
         Use_Keyword_Boost => False,
         Keyword           => Make_Text (""),
         Top_K             => 2,
         Result            => RAG_Res,
         Top_Parent_Chunk  => Fetched_Chunk,
         Status            => RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Res.Count = 1);

      Execute_Hybrid_RAG_Query
        (Engine            => RAG_Store,
         Snapshot          => Tx_RAG_Aborted.Id,
         DB_Path           => DB_File,
         SQL_Query         => SQL_No_Space_2,
         Query_Vec         => Make_Vector_3D (0.95, 0.05, 0.0),
         Encoding          => Encoding_Float32,
         Use_Meta_Filter   => False,
         Filter_Meta       => Meta_RAG_Query,
         Use_Keyword_Boost => False,
         Keyword           => Make_Text (""),
         Top_K             => 2,
         Result            => RAG_Res,
         Top_Parent_Chunk  => Fetched_Chunk,
         Status            => RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Res.Count = 0);

      --  Verify Recover_RAG_Engine from Primary Slotted Page 1 + TOAST chains + lossless "RMET" Summary/JSONB Metadata
      Recover_RAG_Engine (RAG_Recovered, 3, DB_File, WAL_File, RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Recovered.Doc_Count = 2);
      Execute_Hybrid_RAG_Query
        (Engine            => RAG_Recovered,
         Snapshot          => Tx_RAG_Aborted.Id,
         DB_Path           => DB_File,
         SQL_Query         => SQL_Query,
         Query_Vec         => Make_Vector_3D (0.95, 0.05, 0.0),
         Encoding          => Encoding_Int8_SQ8,
         Use_Meta_Filter   => True,
         Filter_Meta       => Meta_Doc_1,
         Use_Keyword_Boost => True,
         Keyword           => Make_Text ("TAIL_KEYWORD"),
         Top_K             => 2,
         Result            => RAG_Res,
         Top_Parent_Chunk  => Fetched_Chunk,
         Status            => RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Res.Count = 1
             and then RAG_Res.Hits (1).Doc_Id = 1 and then RAG_Res.Hits (1).Keyword_Match);

      --  Verify durable Delete_Document removes Doc_Id = 2 from HNSW/PK_Tree + crash recovery,
      --  while historical snapshots (Tx_RAG.Id < Tx_RAG_Del.Id) still recall and rank Doc_Id = 2 even when Top_K = 1
      Begin_Tx (Next_Tx_Id, Tx_RAG_Del);
      Delete_Document (RAG_Store, Tx_RAG_Del, DB_File, WAL_File, Doc_Id => 2, Status => RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Store.Doc_Count = 1);
      Build_RAG_Slotted_Page (RAG_Store, Tx_RAG_Del.Id, Local_Slot_Buf);
      Commit_Tx (Tx_RAG_Del, DB_File, WAL_File, 1, Local_Slot_Buf, Local_Tx_Stat);
      Check (Local_Tx_Stat = Status_Ok);
      Set_CLOG_State (RAG_Store.CLOG, Tx_RAG_Del.Id, Tx_Committed);

      Execute_Hybrid_RAG_Query
        (Engine            => RAG_Store,
         Snapshot          => Tx_RAG.Id,
         DB_Path           => DB_File,
         SQL_Query         => SQL_No_Space_1,
         Query_Vec         => Make_Vector_3D (0.7, 0.7, 0.0),
         Encoding          => Encoding_Float32,
         Use_Meta_Filter   => False,
         Filter_Meta       => Meta_RAG_Query,
         Use_Keyword_Boost => False,
         Keyword           => Make_Text (""),
         Top_K             => 1,
         Result            => RAG_Res,
         Top_Parent_Chunk  => Fetched_Chunk,
         Status            => RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Res.Count = 1 and then RAG_Res.Hits (1).Doc_Id = 2);

      Recover_RAG_Engine (RAG_Recovered, 3, DB_File, WAL_File, RAG_Status);
      Check (RAG_Status = Status_Ok and then RAG_Recovered.Doc_Count = 1);

      Unsubscribe (Broker, Sub_Exact);
      Unsubscribe (Broker, Sub_Wild);
      Unsubscribe (Broker, Sub_Durable);
      Delete_File_If_Exists (DB_File);
      Delete_File_If_Exists (WAL_File);
      Print_Line ("  => Passed: Hybrid SQL + JSONB + RMET TOAST + Stage-2 Re-Rank + Durable Delete + Recovery verified.");
   end Verify_RAG_And_PubSub;

   --  11. C ABI / FFI SDK (`Nhe_O.C_API`) verification variables
   C_Rc          : int;
   C_Stmt_Kind   : int;
   C_Has_Vec     : int;
   C_Has_JSONB   : int;
   C_L2_Dist     : C_float;
   C_Cos_Dist    : C_float;
   C_Ham_Dist    : int;
   C_Key_Buf     : constant C_Ident_Buf := [1 => To_C ('f'), 2 => To_C ('f'), 3 => To_C ('i'), others => nul];
   C_Val_Buf     : constant C_Text_Buf  := [1 => To_C ('o'), 2 => To_C ('k'), others => nul];
   C_Out_Val_Buf : C_Text_Buf           := [others => nul];
   C_Out_Val_Len : int;
   C_Hit_Cnt     : int;
   C_Top_Doc     : int;
   C_Top_Dist    : C_float;
   C_Graph_Hit   : int;
   C_Exists_Flag : int;
   C_Updated_Flg : int;
   C_Rem_TTL     : Integer_64;
   C_Vec_ND_A    : constant C_Vec_Buf := [1 => 1.0, 2 => 0.0, 3 => 0.0, 4 => 0.0, others => 0.0];
   C_Vec_ND_B    : constant C_Vec_Buf := [1 => 0.0, 2 => 3.0, 3 => 4.0, 4 => 0.0, others => 0.0];
   C_Top_Par_Buf : C_Text_Buf         := [others => nul];
   C_Top_Par_Len : int;

begin
   Read_CLI_Arg (1, CLI_Arg1, Has_CLI_Arg1, Long_Arg1);
   if Long_Arg1 then
      Set_Exit_Failure;
      return;
   end if;
   if Has_CLI_Arg1 and then not Equal_Text (CLI_Arg1, Make_Text ("--verify")) then
      Run_CLI_Command (CLI_Arg1, CLI_Handled);
      if not CLI_Handled then
         Print_Line ("[CLI] Error: unrecognized CLI flag (expected --verify, --sql, --kv, or --rag-demo).");
         Set_Exit_Failure;
      end if;
      return;
   end if;

   Print_Line ("=====================================================================");
   Print_Line ("  Nhe_O Embedded Multi-Model Database Engine (Ada 2022 / SPARK 2022)");
   Print_Line ("  Version: " & Nhe_O.Version & " | 100% SPARK_Mode (On) — Proven AoRTE & C FFI SDK");
   Print_Line ("=====================================================================");
   Print_Blank_Line;

   --  1. Verify PostgreSQL SQL Syntax & Data Type Catalog
   Print_Line ("[1/11] Verifying PostgreSQL SQL Dialect & Data Types (Nhe_O.SQL / Nhe_O.Types)...");
   Analyze_SQL (SQL_Query, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok);
   Check (SQL_Desc.Kind = Stmt_Select);
   Check (SQL_Desc.Has_Positional_Param);
   Check (SQL_Desc.Has_Pg_Type_Cast);
   Check (SQL_Desc.Has_Vector_Operator);
   Check (SQL_Desc.Has_JSONB_Operator);
   Check (SQL_Desc.Has_Where and then SQL_Desc.Has_Order_By and then SQL_Desc.Has_Limit);
   Check (SQL_Desc.Limit_Value = 5);
   Check (Equal_Ident (SQL_Desc.Table_Or_Target, Make_Ident ("documents")));

   Analyze_SQL (SQL_Vec_Only, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then not SQL_Desc.Has_JSONB_Operator);
   Check (SQL_Desc.Limit_Value = 10);

   Analyze_SQL (SQL_Quoted_Noise, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then not SQL_Desc.Has_Vector_Operator);

   Analyze_SQL (SQL_Create_Idx, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);

   Analyze_SQL (SQL_Create_Tbl, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Kind = Stmt_Create_Table);
   Check (SQL_Desc.Column_Count = 4);

   Analyze_SQL (SQL_Tight_QMark, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Has_JSONB_Operator);

   Analyze_SQL (SQL_Bad_Quote, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);

   Analyze_SQL (SQL_Bad_Comment, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);

   --  Verify whitespace-free comment/quote keywords, multi-statement rejection,
   --  clause ordering, duplicate clause rejection, empty FROM rejection, non-numeric LIMIT rejection,
   --  IF NOT EXISTS, and identifier/tx validation
   Analyze_SQL (SQL_No_Space_1, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Kind = Stmt_Select and then SQL_Desc.Limit_Value = 1);
   Analyze_SQL (SQL_No_Space_2, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Kind = Stmt_Select and then SQL_Desc.Limit_Value = 0);
   Analyze_SQL (SQL_Multi_Stmt, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (SQL_Lead_Semi, SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT , FROM docs;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM docs LIMIT 5 WHERE x = 1;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM docs WHERE x = 1 WHERE y = 2;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM docs WHERE x = 1 ORDER BY id WHERE y = 2;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM WHERE x = 1;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM docs LIMIT abc;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM 12345;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("BEGIN DROP TABLE docs;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE IF NOT EXISTS docs (id BIGINT, emb VECTOR(4096));"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Kind = Stmt_Create_Table
          and then Equal_Ident (SQL_Desc.Table_Or_Target, Make_Ident ("docs")));

   Resolve_Pg_Type (Make_Ident ("JSONB"), Resolved_T, Type_Valid);
   Check (Type_Valid and then Resolved_T = Pg_JSONB);
   Resolve_Pg_Type (Make_Ident ("VECTOR(4096)"), Resolved_T, Type_Valid);
   Check (Type_Valid and then Resolved_T = Pg_Vector);
   Resolve_Pg_Type (Make_Ident ("VECTOR(0)"), Resolved_T, Type_Valid);
   Check (not Type_Valid);
   Resolve_Pg_Type (Make_Ident ("VECTOR(9999)"), Resolved_T, Type_Valid);
   Check (not Type_Valid);
   Resolve_Pg_Type (Make_Ident ("NUMERIC(10,2)"), Resolved_T, Type_Valid);
   Check (Type_Valid and then Resolved_T = Pg_Numeric);
   Resolve_Pg_Type (Make_Ident ("NUMERIC(5,10)"), Resolved_T, Type_Valid);
   Check (not Type_Valid);
   Resolve_Pg_Type (Make_Ident ("NUMERIC(50,2)"), Resolved_T, Type_Valid);
   Check (not Type_Valid);
   Analyze_SQL (Make_Text ("CREATE BOGUS TABLE docs (id INT);"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (a, b);"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (id FOOBAR_TYPE);"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (emb VECTOR(0));"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (emb VECTOR(9999));"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (price NUMERIC(10, 2), score DOUBLE PRECISION);"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Kind = Stmt_Create_Table and then SQL_Desc.Column_Count = 2);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (id INT) DROP TABLE users;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT BOGUS INTO docs VALUES (1);"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs VALUES ;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs VALUES ();"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs VALUES 123;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs BOGUS VALUES (1);"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs VALUES (1) BOGUS;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs VALUES (1), ();"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("INSERT INTO docs VALUES (1), (2) ON CONFLICT DO NOTHING;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then SQL_Desc.Kind = Stmt_Insert and then SQL_Desc.Has_Upsert_Conflict);
   Analyze_SQL (Make_Text ("SELECT id FROM docs RETURNING id;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT id FROM docs ON CONFLICT DO NOTHING;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("UPDATE docs SET a = 1 RETURNING ;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("DELETE FROM docs WHERE id = 1 RETURNING ;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("CREATE TABLE docs (score DOUBLE PRECISION(10));"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("UPDATE BOGUS docs SET a = 1;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("UPDATE docs SET a;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("DELETE BOGUS FROM docs;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("DELETE FROM docs BOGUS;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("NOTIFY ch, 123;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Invalid_Syntax);
   Analyze_SQL (Make_Text ("SELECT col$1abc FROM docs;"), SQL_Desc, SQL_Status);
   Check (SQL_Status = Status_Ok and then not SQL_Desc.Has_Positional_Param);
   Print_Line ("  => Passed: PostgreSQL SELECT/DDL, clause grammar, and VECTOR(1..4096) verified.");

   --  2. Verify Vector Similarity & 4096-D Int8 / Binary Quantization (`ADR-003`)
   Print_Line ("[2/11] Verifying 4096-D Vector Engine & Int8/Binary Quantization (Nhe_O.Vector)...");
   L2_AB     := L2_Distance (Vec_A, Vec_B);
   L2_AC     := L2_Distance_Squared (Vec_A, Vec_C);
   L2_Max    := L2_Distance (Vec_Max, Vec_Zero);
   Cos_AB    := Cosine_Distance (Vec_A, Vec_B);
   Cos_Max   := Cosine_Distance (Vec_Max, Vec_Max);
   Cos_Small := Cosine_Distance (Vec_Small, Vec_Small);
   NIP_AC    := Negative_Inner_Product (Vec_A, Vec_C);
   Check (L2_AB < 0.001);
   Check (L2_AC >= 25.999 and then L2_AC <= 26.001);
   Check (L2_Max >= Max_Component - 1.0 and then L2_Max <= Max_Component + 1.0);
   Check (Cos_AB < 0.001 and then Cos_Max < 0.001 and then Cos_Small < 0.001);
   Check (NIP_AC >= -0.001 and then NIP_AC <= 0.001);

   --  Verify 4096-D Scalar (Int8) and Binary (1-bit Hamming) quantization
   Q_Int8_A    := Quantize_To_Int8 (Vec_4096_A);
   Q_Int8_B    := Quantize_To_Int8 (Vec_4096_B);
   Deq_Vec_A   := Dequantize_From_Int8 (Q_Int8_A);
   Int8_Dist   := Int8_L2_Distance_Squared (Q_Int8_A, Q_Int8_B);
   Int8_Scaled := Int8_L2_Distance (Q_Int8_A, Q_Int8_B);
   Check (Q_Int8_A.Dim = 4096 and then Deq_Vec_A.Dim = 4096);
   Check (Int8_Dist > 0 and then Int8_Scaled > 0.0);
   Check (Int8_Inner_Product (Q_Int8_A, Q_Int8_A) > 0);

   --  Verify saturation on extreme scale in Dequantize_From_Int8
   Q_Int8_Sat := (Dim => 3, Scale => Max_Component / 100.0, Elements => [1 => 127, 2 => -127, others => 0]);
   Deq_Vec_Sat := Dequantize_From_Int8 (Q_Int8_Sat);
   Check (Deq_Vec_Sat.Elements (1) >= Max_Component - 1.0
          and then Deq_Vec_Sat.Elements (2) <= -Max_Component + 1.0);

   --  Verify 4096-D Float32 TOAST serialization round-trip with "VTST" header & 15-tier precision (Q-003)
   Encode_Vector_TOAST (Vec_4096_A, Vec_Toast_Buf, Vec_Toast_Len);
   Check (Vec_Toast_Len = Vector_TOAST_Byte_Length (4096));
   Decode_Vector_TOAST (Vec_Toast_Buf, Vec_Toast_Len, 4096, Vec_Dec_4096, Vec_Dec_Ok);
   Check (Vec_Dec_Ok and then Vec_Dec_4096.Dim = 4096);
   Check (abs (Vec_Dec_4096.Elements (1) - 1.0) < 0.0001
          and then abs (Vec_Dec_4096.Elements (2048) - (-1.0)) < 0.0001);

   Encode_Vector_TOAST (Make_Vector_3D (1.0e-7, 1.234567e-6, -9.876543e-4), Vec_Toast_Buf, Vec_Toast_Len);
   Check (Vec_Toast_Len = Vector_TOAST_Byte_Length (3));
   Decode_Vector_TOAST (Vec_Toast_Buf, Vec_Toast_Len, 3, Vec_Dec_Small, Vec_Dec_Ok);
   Check (Vec_Dec_Ok
          and then abs (Vec_Dec_Small.Elements (1) - 1.0e-7) < 1.0e-9
          and then abs (Vec_Dec_Small.Elements (2) - 1.234567e-6) < 1.0e-11
          and then abs (Vec_Dec_Small.Elements (3) - (-9.876543e-4)) < 1.0e-8);
   Decode_Vector_TOAST (Vec_Toast_Buf, Vec_Toast_Len, 4, Vec_Dec_Small, Vec_Dec_Ok);
   Check (not Vec_Dec_Ok);

   Q_Bin_A  := Quantize_To_Binary (Vec_4096_A);
   Q_Bin_B  := Quantize_To_Binary (Vec_4096_B);
   Ham_Dist := Hamming_Distance (Q_Bin_A, Q_Bin_B);
   Check (Ham_Dist = 2);
   Check (Hamming_Distance (Q_Bin_A, Q_Bin_A) = 0);
   Print_Line ("  => Passed: 4096-D Float32, SQ8 scale-aware L2, Binary Hamming, and 15-tier Vector TOAST verified.");

   --  3. Verify PostgreSQL JSON / JSONB Engine (`->`, `->>`, `@>`, `?`)
   Print_Line ("[3/11] Verifying PostgreSQL JSON/JSONB Engine (Nhe_O.JSON)...");
   Check (Is_Valid_JSON (Raw_JSON));
   Check (Is_Valid_JSON (Scalar_True));
   Check (Is_Valid_JSON (Scalar_Num));
   Check (Is_Valid_JSON (Scalar_Str));
   Check (not Is_Valid_JSON (Bad_JSON_1));
   Check (not Is_Valid_JSON (Bad_JSON_2));
   Check (not Is_Valid_JSON (Bad_JSON_3));
   Check (not Is_Valid_JSON (Bad_JSON_4));
   Check (not Is_Valid_JSON (Bad_JSON_5));
   Check (not Is_Valid_JSON (Bad_JSON_6));
   Check (not Is_Valid_JSON (Bad_JSON_7));
   Check (not Is_Valid_JSON (Make_Text ("{""nul"":""\u0000""}")));

   Parse_JSONB (Raw_JSON, Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Ok and then Doc_Parsed.Count = 4);
   Get_Field (Doc_Parsed, Make_Ident ("engine"), Field_Hit, Field_Val, Field_Kind);
   Check (Field_Hit and then Field_Kind = JSONB_String and then Equal_Text (Field_Val, Make_Text ("""Nhe_O""")));
   Get_Field_Text (Doc_Parsed, Make_Ident ("engine"), Field_Hit, Field_Val);
   Check (Field_Hit and then Equal_Text (Field_Val, Make_Text ("Nhe_O")));

   --  Verify strict delimiter checks in Parse_JSONB
   Parse_JSONB (Make_Text ("{,""a"":1}"), Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Invalid_Syntax);
   Parse_JSONB (Make_Text ("{""a"":::1}"), Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Invalid_Syntax);
   Parse_JSONB (Make_Text ("{""a"":1,,""b"":2}"), Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Invalid_Syntax);

   --  Verify >16 duplicate keys with 1 unique key succeed, and >16-element array @> fails closed
   Parse_JSONB (Make_Text ("{""k"":1,""k"":2,""k"":3,""k"":4,""k"":5,""k"":6,""k"":7,""k"":8,""k"":9,""k"":10,""k"":11,""k"":12,""k"":13,""k"":14,""k"":15,""k"":16,""k"":17}"), Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Ok and then Doc_Parsed.Count = 1);
   Parse_JSONB (Make_Text ("{""arr"":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]}"), Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Ok);
   Parse_JSONB (Make_Text ("{""arr"":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,999]}"), Doc_Filter, JSON_Stat);
   Check (JSON_Stat = Status_Ok
          and then not Contains (Doc_Parsed, Doc_Filter)
          and then not Contains (Doc_Filter, Doc_Filter));

   --  Verify RFC 8259 escape decoding (including \uXXXX) and depth-4 nested @> containment
   Parse_JSONB (Make_Text ("{""msg"":""a\nb\u0041"", ""num"":1.0, ""sub"":{""nested"":{""leaf"":{""y"":2,""x"":1.0}}}, ""arr"":[{""k"":1.0,""m"":2}]}"), Doc_Parsed, JSON_Stat);
   Check (JSON_Stat = Status_Ok);
   Parse_JSONB (Make_Text ("{""msg"":""anbA""}"), Doc_Filter, JSON_Stat);
   Check (JSON_Stat = Status_Ok and then not Contains (Doc_Parsed, Doc_Filter));
   Parse_JSONB (Make_Text ("{""msg"":""a\nbu0041""}"), Doc_Filter, JSON_Stat);
   Check (JSON_Stat = Status_Ok and then not Contains (Doc_Parsed, Doc_Filter));
   Parse_JSONB (Make_Text ("{""msg"":""a\nbA"", ""num"":1, ""sub"":{""nested"":{""leaf"":{""x"":1}}}, ""arr"":[{""m"":2,""k"":1}]}"), Doc_Filter, JSON_Stat);
   Check (JSON_Stat = Status_Ok and then Contains (Doc_Parsed, Doc_Filter));

   Doc_Filter := (others => <>);
   Put_Field (Doc_Main, Make_Ident ("bad_num"), Make_Text ("not_a_number"), JSONB_Number, JSON_Stat);
   Check (JSON_Stat = Status_Invalid_Syntax);

   Put_Field (Doc_Main, Make_Ident ("engine"), Make_Text ("Nhe_O"), JSONB_String, JSON_Stat);
   Check (JSON_Stat = Status_Ok);
   Put_Field (Doc_Main, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);
   Check (JSON_Stat = Status_Ok);
   Put_Field (Doc_Filter, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);
   Check (JSON_Stat = Status_Ok);
   Check (Has_Key (Doc_Main, Make_Ident ("engine")));
   Get_Field (Doc_Main, Make_Ident ("engine"), Field_Hit, Field_Val, Field_Kind);
   Check (Field_Hit and then Field_Kind = JSONB_String and then Equal_Text (Field_Val, Make_Text ("""Nhe_O""")));
   Get_Field_Text (Doc_Main, Make_Ident ("engine"), Field_Hit, Field_Val);
   Check (Field_Hit and then Equal_Text (Field_Val, Make_Text ("Nhe_O")));
   Check (Contains (Doc_Main, Doc_Filter));
   Print_Line ("  => Passed: RFC 8259 JSON validator, escape decoding, and `?`, `->`, `->>`, `@>` verified.");

   --  4. Verify ACID MVCC Visibility, CLOG, Slotted Page & Disk WAL/Page Persistence
   Print_Line ("[4/11] Verifying ACID Transactions, CLOG MVCC, Slotted Page & WAL I/O...");
   Delete_File_If_Exists (DB_File);
   Delete_File_If_Exists (WAL_File);

   Begin_Tx (Next_Tx, Tx_1);
   Tuple_1 := (Xmin => Tx_1.Id, Xmax => 0);
   Check (Is_Tuple_Visible (Tuple_1, Tx_1.Snapshot));

   --  Verify CLOG rejects uncommitted/aborted tuple and supports Tx_Id > 1024 up to 8192
   Check (not Is_Tx_Committed (CLOG_Test, 2000));
   Set_CLOG_State (CLOG_Test, 2000, Tx_Committed);
   Check (Is_Tx_Committed (CLOG_Test, 2000));
   Set_CLOG_State (CLOG_Test, 2000, Tx_Idle);
   Begin_Tx (Next_Tx, Tx_Uncomm);
   Tuple_Uncomm := (Xmin => Tx_1.Id, Xmax => 0);
   Check (not Is_Tuple_Visible (Tuple_Uncomm, Tx_Uncomm.Snapshot, CLOG_Test));
   Set_CLOG_State (CLOG_Test, Tx_1.Id, Tx_Committed);
   Check (Is_Tuple_Visible (Tuple_Uncomm, Tx_Uncomm.Snapshot, CLOG_Test));

   --  Verify Slotted_Page 4KB encode/decode with CRC32
   Slot_Page_Out := (others => <>);
   Slot_Page_Out.Page_Id     := 1;
   Slot_Page_Out.Page_LSN_Tx := 1;
   Slot_Page_Out.Slot_Count  := 1;
   Slot_Page_Out.Tuples (1)  :=
     (Occupied    => True,
      Row_Id      => 42,
      Tuple_Hdr   => Tuple_1,
      Toast_Ptr   => (Root_Overflow_Page => 2, Total_Byte_Length => 4080, Chunk_Count => 1, Payload_CRC32 => 0),
      Related_Id  => 7,
      Inline_Len  => 5,
      Inline_Data => [1 => 16#4E#, 2 => 16#68#, 3 => 16#65#, 4 => 16#5F#, 5 => 16#4F#, others => 0]);
   Encode_Slotted_Page (Slot_Page_Out, Slot_Buf);
   Decode_Slotted_Page (Slot_Buf, Slot_Page_In, Slot_Dec_Ok);
   Check (Slot_Dec_Ok and then Slot_Page_In.Slot_Count = 1 and then Slot_Page_In.Tuples (1).Row_Id = 42);

   CRC_Before := Compute_CRC32 (Page_Out);
   Commit_Tx (Tx_1, DB_File, WAL_File, 0, Page_Out, Tx_Status);
   Check (Tx_Status = Status_Ok and then Tx_1.State = Tx_Committed);

   Read_Page (DB_File, 0, Page_In, Read_Ok);
   CRC_After := Compute_CRC32 (Page_In);
   Check (Read_Ok and then CRC_Before = CRC_After);

   Read_WAL_Frame (WAL_File, 0, WAL_In, WAL_Read_Ok, WAL_EOF);
   if WAL_Read_Ok and then not WAL_EOF and then Verify_WAL_Frame (WAL_In) then
      Dec_Kind := Get_WAL_Frame_Kind (WAL_In);
      Decode_WAL_Frame (WAL_In, Dec_Tx, Dec_Page_Id, Dec_Page);
      Check (Dec_Tx = Tx_1.Id and then Dec_Page_Id = 0 and then Dec_Kind = WAL_Frame_Commit);
      Check (Compute_CRC32 (Dec_Page) = CRC_Before);
   else
      Check (False);
   end if;
   WAL_In (9) := WAL_In (9) xor 16#01#;
   Check (not Verify_WAL_Frame (WAL_In));

   NUL_Path.Data (6) := ASCII.NUL;
   Write_Page (NUL_Path, 0, Page_Out, NUL_Write_Ok);
   Check (not NUL_Write_Ok);
   Print_Line ("  => Passed: 8192-entry CLOG MVCC visibility, 4KB Slotted_Page, and positional WAL I/O verified.");

   --  5. Verify 4KB TOAST Overflow Page Chains, NO-STEAL & 2-Pass Committed-Only WAL Recovery
   Print_Line ("[5/11] Verifying 4KB TOAST Overflow Page Chains, NO-STEAL & 2-Pass WAL Recovery...");
   Begin_Tx (Next_Tx, Tx_Toast);
   Write_TOAST_Chain
     (Ctx           => Tx_Toast,
      DB_Path       => DB_File,
      WAL_Path      => WAL_File,
      Start_Page_Id => 2,
      Payload       => Toast_Out,
      Length        => 10_000,
      Ptr           => Toast_Ptr,
      Status        => Tx_Status);
   Check (Tx_Status = Status_Ok);
   Check (Toast_Ptr.Root_Overflow_Page = 2);
   Check (Toast_Ptr.Total_Byte_Length = 10_000);
   Check (Toast_Ptr.Chunk_Count = 3);

   Encode_TOAST_Pointer (Toast_Ptr, Toast_Bytes);
   Decode_TOAST_Pointer (Toast_Bytes, Toast_Dec_Ptr, Toast_Ptr_Ok);
   Check (Toast_Ptr_Ok and then Toast_Dec_Ptr = Toast_Ptr);

   --  Verify Decode_TOAST_Pointer rejects inconsistent Chunk_Count
   Toast_Bytes (9) := 1;
   Decode_TOAST_Pointer (Toast_Bytes, Toast_Dec_Ptr, Toast_Ptr_Ok);
   Check (not Toast_Ptr_Ok);
   Encode_TOAST_Pointer (Toast_Ptr, Toast_Bytes);
   Decode_TOAST_Pointer (Toast_Bytes, Toast_Dec_Ptr, Toast_Ptr_Ok);
   Check (Toast_Ptr_Ok);

   --  Verify NO-STEAL: before Commit_Tx, uncommitted TOAST pages are NOT in DB_File
   Read_Page (DB_File, 2, Page_In, Read_Ok);
   Check (not Read_Ok);

   --  Commit Tx_Toast so its WAL_Frame_Data TOAST pages are flushed to DB_File after WAL_Frame_Commit
   Commit_Tx (Tx_Toast, DB_File, WAL_File, 0, Page_Out, Tx_Status);
   Check (Tx_Status = Status_Ok);

   if Toast_Dec_Ptr.Total_Byte_Length in 1 .. Max_TOAST_Payload_Bytes
     and then Toast_Dec_Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks
   then
      Read_TOAST_Chain (DB_File, Toast_Dec_Ptr, Toast_In, Toast_Len_Out, Tx_Status);
      Check (Tx_Status = Status_Ok and then Toast_Len_Out = 10_000);
      Check (Toast_In (1) = 16#51# and then Toast_In (4081) = 16#57#
             and then Toast_In (8161) = 16#45# and then Toast_In (10000) = 16#4E#);
   else
      Check (False);
   end if;

   --  Append an UNCOMMITTED WAL frame from Tx_Uncomm for Page 0 and verify 2-pass Redo skips it
   Encode_WAL_Frame (Tx_Uncomm.Id, 0, Page_Uncomm, WAL_Crc, WAL_Uncomm, WAL_Frame_Data);
   Append_WAL_Frame (WAL_File, WAL_Uncomm, WAL_App_Ok);
   Check (WAL_App_Ok);
   Rollback_Tx (Tx_Uncomm);

   --  Verify Redo_WAL_Recovery rejects identical DB_Path and WAL_Path
   Redo_WAL_Recovery (DB_File, DB_File, 16, Replayed_Cnt, Max_Rec_Tx, Tx_Status);
   Check (Tx_Status = Status_IO_Error);

   --  Simulate crash recovery by deleting DB_File and replaying only committed WAL frames
   Delete_File_If_Exists (DB_File);
   Redo_WAL_Recovery (DB_File, WAL_File, 16, Replayed_Cnt, Max_Rec_Tx, Tx_Status);
   Check (Tx_Status = Status_Ok and then Replayed_Cnt = 5);
   Check (Max_Rec_Tx = Tx_Toast.Id);

   --  Verify Page 0 has committed Page_Out, NOT uncommitted Page_Uncomm
   Read_Page (DB_File, 0, Page_In, Read_Ok);
   Check (Read_Ok and then Page_In (1) = 16#4E# and then Page_In (2) = 16#48#);

   if Toast_Dec_Ptr.Total_Byte_Length in 1 .. Max_TOAST_Payload_Bytes
     and then Toast_Dec_Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks
   then
      Read_TOAST_Chain (DB_File, Toast_Dec_Ptr, Toast_In, Toast_Len_Out, Tx_Status);
      Check (Tx_Status = Status_Ok and then Toast_Len_Out = 10_000);
      Check (Toast_In (10000) = 16#4E#);
   else
      Check (False);
   end if;
   Print_Line ("  => Passed: 16-byte TOAST pointer, NO-STEAL 3-page chain, and 2-pass committed-only WAL Redo verified.");

   --  6. Verify Multi-Page B+Tree Index with Multi-Level Splitting & Deletion (`Nhe_O.BTree`)
   Print_Line ("[6/11] Verifying Multi-Page B+Tree Index, Splitting & Deletion (Nhe_O.BTree)...");
   Init_BTree (Tree_Idx);
   for K in 1 .. 20 loop
      pragma Loop_Invariant
        (Tree_Idx.Node_Count in 1 .. Max_BTree_Nodes
         and then Tree_Idx.Root_Node in 1 .. Tree_Idx.Node_Count);
      Insert_Key
        (Tree   => Tree_Idx,
         Key    => Big_Key_Base + Integer_64 (K * 10),
         Ptr    => (Target_Page => K,
                    Target_Slot => K,
                    TOAST_Root  => K + 100),
         Status => BTree_Stat);
      Check (BTree_Stat = Status_Ok);
   end loop;
   Check (Tree_Idx.Total_Keys = 20);
   Check (Tree_Idx.Split_Count >= 5);
   Check (Tree_Idx.Nodes (Tree_Idx.Root_Node).Kind = Node_Internal);

   for K in 1 .. 20 loop
      pragma Loop_Invariant
        (Tree_Idx.Node_Count in 1 .. Max_BTree_Nodes
         and then Tree_Idx.Root_Node in 1 .. Tree_Idx.Node_Count);
      Search_Key (Tree_Idx, Big_Key_Base + Integer_64 (K * 10), BTree_Hit, BTree_Ptr);
      Check (BTree_Hit and then BTree_Ptr.Target_Page = K and then BTree_Ptr.TOAST_Root = K + 100);
   end loop;

   Range_Scan (Tree_Idx, Big_Key_Base + 30, Big_Key_Base + 120, BTree_Scan);
   Check (BTree_Scan.Count = 10);
   Check (BTree_Scan.Items (1).Key = Big_Key_Base + 30
          and then BTree_Scan.Items (10).Key = Big_Key_Base + 120);

   --  Verify Delete_Key removes key, decrements Total_Keys, and compacts underflowed leaves
   Delete_Key (Tree_Idx, Big_Key_Base + 50, BTree_Del_Ok);
   Check (BTree_Del_Ok and then Tree_Idx.Total_Keys = 19);
   Search_Key (Tree_Idx, Big_Key_Base + 50, BTree_Hit, BTree_Ptr);
   Check (not BTree_Hit);
   Delete_Key (Tree_Idx, Big_Key_Base + 60, BTree_Del_Ok);
   Check (BTree_Del_Ok and then Tree_Idx.Total_Keys = 18);
   Insert_Key
     (Tree   => Tree_Idx,
      Key    => Big_Key_Base + 50,
      Ptr    => (Target_Page => 5, Target_Slot => 5, TOAST_Root => 105),
      Status => BTree_Stat);
   Check (BTree_Stat = Status_Ok and then Tree_Idx.Total_Keys = 19);

   Encode_Node_Page (Tree_Idx.Nodes (Tree_Idx.Root_Node), BTree_Page);
   Decode_Node_Page (BTree_Page, BTree_Dec_Nd, BTree_Dec_Ok);
   Check (BTree_Dec_Ok
          and then BTree_Dec_Nd.Num_Keys = Tree_Idx.Nodes (Tree_Idx.Root_Node).Num_Keys
          and then BTree_Dec_Nd.Keys (1) = Tree_Idx.Nodes (Tree_Idx.Root_Node).Keys (1)
          and then BTree_Dec_Nd.Children (1) = Tree_Idx.Nodes (Tree_Idx.Root_Node).Children (1));
   BTree_Page (25) := BTree_Page (25) xor 16#FF#;
   Decode_Node_Page (BTree_Page, BTree_Dec_Nd, BTree_Dec_Ok);
   Check (not BTree_Dec_Ok);
   --  Verify Is_Valid_Node rejects Node_Internal with Num_Keys = 0 and non-root leaf with Num_Keys < 2
   Check (not Is_Valid_Node ((Kind => Node_Internal, Page_Id => 1, Num_Keys => 0, Next_Leaf => 0, others => <>)));
   Check (not Is_Valid_Node ((Kind => Node_Leaf, Page_Id => 2, Num_Keys => 1, Next_Leaf => 0, others => <>)));
   Print_Line ("  => Passed: 20-key multi-level B+Tree splits, Delete_Key compaction, 64-bit keys, and CRC32 page verified.");

   --  7. Verify Multi-Layer HNSW Graph Index (`Nhe_O.HNSW`)
   Print_Line ("[7/11] Verifying Multi-Layer HNSW Vector Graph Index (Nhe_O.HNSW)...");
   Init_HNSW (Graph_Idx, Dim => 3);
   Insert_Vector (Graph_Idx, Doc_Id => 1, Vec => Make_Vector_3D (10.0, 0.0, 0.0), TOAST_Root => 10, Layer_Hint => 3, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok);
   --  Verify Doc_Id deduplication updates in-place without duplicating node
   Insert_Vector (Graph_Idx, Doc_Id => 1, Vec => Make_Vector_3D (1.0, 0.0, 0.0), TOAST_Root => 10, Layer_Hint => 3, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok and then Graph_Idx.Node_Count = 1);

   Insert_Vector (Graph_Idx, Doc_Id => 2, Vec => Make_Vector_3D (0.9, 0.1, 0.0), TOAST_Root => 11, Layer_Hint => 2, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok);
   Insert_Vector (Graph_Idx, Doc_Id => 3, Vec => Make_Vector_3D (-1.0, -1.0, -1.0), TOAST_Root => 12, Layer_Hint => 1, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok);
   for D in 4 .. 10 loop
      pragma Loop_Invariant
        (Graph_Idx.Dim = 3
         and then Graph_Idx.Node_Count <= Max_HNSW_Nodes);
      Insert_Vector
        (Graph_Idx,
         Doc_Id     => D,
         Vec        => Make_Vector_3D (0.0, Float (D), Float (D)),
         TOAST_Root => Valid_Page_Id (D + 10),
         Layer_Hint => 1,
         Status     => HNSW_Stat);
      Check (HNSW_Stat = Status_Ok);
   end loop;
   Check (Graph_Idx.Node_Count = 10);

   --  Verify Remove_Vector and in-place update behind an inactive hole
   Remove_Vector (Graph_Idx, Doc_Id => 10);
   Check (Graph_Idx.Node_Count = 9 and then Has_HNSW_Capacity (Graph_Idx, 10));
   Insert_Vector (Graph_Idx, Doc_Id => 10, Vec => Make_Vector_3D (0.0, 10.0, 10.0), TOAST_Root => 20, Layer_Hint => 1, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok and then Graph_Idx.Node_Count = 10);

   --  Create an inactive hole at slot 1, update Doc_Id 10 in-place (preserving Node_Count = 10), then re-insert Doc_Id 1 into slot 1
   Remove_Vector (Graph_Idx, Doc_Id => 1);
   Check (Graph_Idx.Node_Count = 10 and then not Graph_Idx.Nodes (1).Active);
   Insert_Vector (Graph_Idx, Doc_Id => 10, Vec => Make_Vector_3D (0.0, 10.5, 10.5), TOAST_Root => 20, Layer_Hint => 2, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok and then Graph_Idx.Node_Count = 10 and then Graph_Idx.Top_Layer = 2);
   Insert_Vector (Graph_Idx, Doc_Id => 1, Vec => Make_Vector_3D (1.0, 0.0, 0.0), TOAST_Root => 10, Layer_Hint => 3, Status => HNSW_Stat);
   Check (HNSW_Stat = Status_Ok and then Graph_Idx.Node_Count = 10 and then Graph_Idx.Top_Layer = 3);

   Search_KNN (Graph_Idx, Make_Vector_3D (1.0, 0.0, 0.0), Encoding_Float32, K => 2, Results => KNN_Float_Res);
   Check (KNN_Float_Res.Count = 2 and then KNN_Float_Res.Items (1).Doc_Id = 1);

   Search_KNN (Graph_Idx, Make_Vector_3D (1.0, 0.0, 0.0), Encoding_Int8_SQ8, K => 2, Results => KNN_Int8_Res);
   Check (KNN_Int8_Res.Count = 2 and then KNN_Int8_Res.Items (1).Doc_Id = 1);

   Search_KNN (Graph_Idx, Make_Vector_3D (1.0, 0.0, 0.0), Encoding_Binary_1Bit, K => 2, Results => KNN_Bin_Res);
   Check (KNN_Bin_Res.Count = 2 and then KNN_Bin_Res.Items (1).Doc_Id in 1 .. 2);
   Print_Line ("  => Passed: 10-node HNSW graph, Remove_Vector, Doc_Id dedup, and Float32/Int8-SQ8/Binary recall verified.");

   --  8. Verify Redis-Compatible Key-Value Cache, TTL & WAL Persistence (`Q-004`)
   Print_Line ("[8/11] Verifying Redis-Compatible Key-Value Cache, TTL & WAL Recovery (Nhe_O.KV)...");
   Delete_File_If_Exists (KV_WAL_File);
   Set (Cache, Make_Ident ("session:42"), Make_Text ("user_long"), Now => 1000, Has_TTL => True, TTL_Sec => 60);
   Check (Exists (Cache, Make_Ident ("session:42"), Now => 1030));
   Check (Remaining_TTL (Cache, Make_Ident ("session:42"), Now => 1030) = 30);

   Get (Cache, Make_Ident ("session:42"), Now => 1030, Val => KV_Val, Status => KV_Status);
   Check (KV_Status = Status_Ok and then Equal_Text (KV_Val, Make_Text ("user_long")));

   Get (Cache, Make_Ident ("session:42"), Now => 1061, Val => KV_Val, Status => KV_Status);
   Check (KV_Status = Status_Expired);
   Check (not Exists (Cache, Make_Ident ("session:42"), Now => 1061));

   Incr_By (Cache, Make_Ident ("metrics:hits"), 5, Now => 1062, New_Val => Counter_V, Status => KV_Status);
   Check (KV_Status = Status_Ok and then Counter_V = 5);
   Incr_By (Cache, Make_Ident ("metrics:hits"), 10, Now => 1063, New_Val => Counter_V, Status => KV_Status);
   Check (KV_Status = Status_Ok and then Counter_V = 15);
   Del (Cache, Make_Ident ("metrics:hits"), KV_Removed);
   Check (KV_Removed);

   --  Verify optional WAL-backed KV durability, rollback on I/O error, and truncation detection (Q-004)
   Set_Durable (Cache, NUL_Path, 1, Make_Ident ("bad:wal"), Make_Text ("should_rollback"), 2000, False, 0, KV_Status);
   Check (KV_Status = Status_IO_Error and then not Exists (Cache, Make_Ident ("bad:wal"), Now => 2000));

   Set_Durable (Cache, KV_WAL_File, 1, Make_Ident ("durable:k1"), Make_Text ("v1"), 2000, True, 500, KV_Status);
   Check (KV_Status = Status_Ok);
   Set_Durable (Cache, KV_WAL_File, 2, Make_Ident ("durable:k2"), Make_Text ("v2"), 2000, False, 0, KV_Status);
   Check (KV_Status = Status_Ok);
   Del_Durable (Cache, KV_WAL_File, 3, Make_Ident ("durable:k2"), KV_Removed, KV_Status);
   Check (KV_Removed and then KV_Status = Status_Ok);
   --  Deleting a non-existent key does not append a redundant WAL frame
   Del_Durable (Cache, KV_WAL_File, 4, Make_Ident ("durable:missing"), KV_Removed, KV_Status);
   Check (not KV_Removed and then KV_Status = Status_Ok);

   Recover_KV_From_WAL (Cache_Rec, KV_WAL_File, 2100, 2, KV_Rec_Cnt, KV_Status);
   Check (KV_Status = Status_Capacity_Exceeded);

   Recover_KV_From_WAL (Cache_Rec, KV_WAL_File, 2100, 8, KV_Rec_Cnt, KV_Status);
   Check (KV_Status = Status_Ok and then KV_Rec_Cnt = 3);
   Get (Cache_Rec, Make_Ident ("durable:k1"), Now => 2100, Val => KV_Val, Status => KV_Status);
   Check (KV_Status = Status_Ok and then Equal_Text (KV_Val, Make_Text ("v1")));
   Check (not Exists (Cache_Rec, Make_Ident ("durable:k2"), Now => 2100));
   Delete_File_If_Exists (KV_WAL_File);
   Print_Line ("  => Passed: Redis SETEX, GET, DEL, TTL, INCRBY, WAL-before-Data rollback, and KV WAL recovery verified.");

   --  9 & 10. Verify Dual-Mode Pub/Sub & Universal Local LLM RAG
   Verify_RAG_And_PubSub (Next_Tx);

   --  11. Verify Formally Proven C ABI / FFI SDK (`Nhe_O.C_API`)
   Print_Line ("[11/11] Verifying C ABI / FFI SDK & Defensive Boundary Contracts (Nhe_O.C_API)...");
   Check (C_Version_Major = 0 and then C_Version_Minor = 3);
   C_Init (C_Rc);
   Check (C_Rc = C_Status_Ok);

   C_Analyze_SQL (C_Val_Buf, -5, C_Stmt_Kind, C_Has_Vec, C_Has_JSONB, C_Rc);
   Check (C_Rc = C_Status_Invalid_Arg);

   C_Vector_Distance_3D (1.0, 2.0, 2.0, 4.0, 6.0, 2.0, C_L2_Dist, C_Cos_Dist, C_Ham_Dist, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_L2_Dist >= 4.99 and then C_L2_Dist <= 5.01);

   C_Vector_Distance_ND (C_Vec_ND_A, C_Vec_ND_B, 4, C_L2_Dist, C_Cos_Dist, C_Ham_Dist, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_L2_Dist >= 5.09 and then C_L2_Dist <= 5.11);

   --  Verify negative TTL rejection
   C_KV_Set (C_Key_Buf, 3, C_Val_Buf, 2, 1000, -10, C_Rc);
   Check (C_Rc = C_Status_Invalid_Arg);

   C_KV_Set (C_Key_Buf, 3, C_Val_Buf, 2, 1000, 60, C_Rc);
   Check (C_Rc = C_Status_Ok);
   C_KV_Exists (C_Key_Buf, 3, 1020, C_Exists_Flag, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_Exists_Flag = 1);
   C_KV_TTL (C_Key_Buf, 3, 1020, C_Rem_TTL, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_Rem_TTL = 40);
   C_KV_Expire (C_Key_Buf, 3, 1020, 120, C_Updated_Flg, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_Updated_Flg = 1);
   C_KV_Get (C_Key_Buf, 3, 1020, C_Out_Val_Buf, C_Out_Val_Len, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_Out_Val_Len = 2);

   --  Verify invalid C_Init_With_Paths resets G_Initialized and subsequent calls return C_Status_Not_Initialized
   C_Init_With_Paths (C_Val_Buf, 0, C_Val_Buf, 0, 4, C_Rc);
   Check (C_Rc = C_Status_Invalid_Arg);
   C_KV_Set (C_Key_Buf, 3, C_Val_Buf, 2, 1000, 60, C_Rc);
   Check (C_Rc = C_Status_Not_Initialized);

   C_Init (C_Rc);
   Check (C_Rc = C_Status_Ok);
   C_RAG_Ingest_ND (1, C_Val_Buf, 2, C_Vec_ND_A, 3, 2, C_Rc);
   Check (C_Rc = C_Status_Ok);
   C_RAG_Ingest_ND (2, C_Val_Buf, 2, C_Vec_ND_B, 3, 1, C_Rc);
   Check (C_Rc = C_Status_Ok);
   C_RAG_Query_ND
     (C_Vec_ND_A, 3, 0, C_Val_Buf, 2, 2,
      C_Hit_Cnt, C_Top_Doc, C_Top_Dist, C_Top_Par_Buf, C_Top_Par_Len, C_Graph_Hit, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_Hit_Cnt = 2 and then C_Top_Doc = 1
          and then C_Graph_Hit = 1 and then C_Top_Par_Len = 2);

   --  Verify FFI delete: C_RAG_Delete removes Doc_Id = 2 from search results
   C_RAG_Delete (2, C_Rc);
   Check (C_Rc = C_Status_Ok);
   C_RAG_Query_ND
     (C_Vec_ND_A, 3, 0, C_Val_Buf, 2, 2,
      C_Hit_Cnt, C_Top_Doc, C_Top_Dist, C_Top_Par_Buf, C_Top_Par_Len, C_Graph_Hit, C_Rc);
   Check (C_Rc = C_Status_Ok and then C_Hit_Cnt = 1 and then C_Top_Doc = 1);
   Print_Line ("  => Passed: C ABI / FFI exports, N-D vector/RAG/Delete FFI, and defensive boundary guards verified.");

   Print_Blank_Line;
   if All_Passed then
      Print_Line ("ALL 11 Nhe_O SPARK/Ada Verification Suites (Epics 01..04) Passed Successfully.");
   else
      Print_Line ("[ERROR] One or more Nhe_O verification checks failed.");
   end if;
   pragma Warnings (GNATprove, On, "statement has no effect");
   pragma Warnings (GNATprove, On, "is set by");
end Nhe_O_Main;
