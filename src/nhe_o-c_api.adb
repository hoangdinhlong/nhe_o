--  Formally verified C ABI / FFI SDK Implementation Body for Nhe_O (Epic 03 / ADR-005)
pragma SPARK_Mode (On);

with Nhe_O.IO;     use Nhe_O.IO;
with Nhe_O.SQL;    use Nhe_O.SQL;
with Nhe_O.Vector; use Nhe_O.Vector;
with Nhe_O.JSON;   use Nhe_O.JSON;
with Nhe_O.BTree;  use Nhe_O.BTree;
with Nhe_O.HNSW;   use Nhe_O.HNSW;

package body Nhe_O.C_API is

   --  Convert C_Ident_Buf + Validated Len into Bounded_Ident
   function To_Bounded_Ident
     (Buf : C_Ident_Buf;
      Len : Ident_Length) return Bounded_Ident
     with Global => null,
          Post   => To_Bounded_Ident'Result.Length = Len
   is
      Res : Bounded_Ident := (Length => Len, Data => [others => ' ']);
   begin
      for I in 1 .. Len loop
         pragma Loop_Invariant (Res.Length = Len);
         Res.Data (I) := To_Ada (Buf (size_t (I)));
      end loop;
      return Res;
   end To_Bounded_Ident;

   --  Convert Bounded_Ident into C_Ident_Buf
   procedure From_Bounded_Ident
     (Id      : in     Bounded_Ident;
      Out_Buf :    out C_Ident_Buf;
      Out_Len :    out int)
     with Global => null,
          Always_Terminates
   is
   begin
      Out_Buf := [others => nul];
      for I in 1 .. Id.Length loop
         Res_Loop : declare
         begin
            Out_Buf (size_t (I)) := To_C (Id.Data (I));
         end Res_Loop;
      end loop;
      Out_Len := int (Id.Length);
   end From_Bounded_Ident;

   --  Convert C_Text_Buf + Validated Len into Bounded_Text
   function To_Bounded_Text
     (Buf : C_Text_Buf;
      Len : Text_Length) return Bounded_Text
     with Global => null,
          Post   => To_Bounded_Text'Result.Length = Len
   is
      Res : Bounded_Text := (Length => Len, Data => [others => ' ']);
   begin
      for I in 1 .. Len loop
         pragma Loop_Invariant (Res.Length = Len);
         Res.Data (I) := To_Ada (Buf (size_t (I)));
      end loop;
      return Res;
   end To_Bounded_Text;

   --  Convert Bounded_Text into C_Text_Buf
   procedure From_Bounded_Text
     (Txt     : in     Bounded_Text;
      Out_Buf :    out C_Text_Buf;
      Out_Len :    out int)
     with Global => null,
          Always_Terminates
   is
   begin
      Out_Buf := [others => nul];
      for I in 1 .. Txt.Length loop
         pragma Loop_Invariant (I in 1 .. Txt.Length);
         Out_Buf (size_t (I)) := To_C (Txt.Data (I));
      end loop;
      Out_Len := int (Txt.Length);
   end From_Bounded_Text;

   function To_C_Status (S : Engine_Status) return int is
   begin
      case S is
         when Status_Ok                 => return C_Status_Ok;
         when Status_Not_Found          => return C_Status_Not_Found;
         when Status_Expired            => return C_Status_Expired;
         when Status_Invalid_Syntax     => return C_Status_Invalid_Syntax;
         when Status_Type_Mismatch      => return C_Status_Type_Mismatch;
         when Status_Dimension_Mismatch => return C_Status_Dimension_Mismatch;
         when Status_Capacity_Exceeded  => return C_Status_Capacity_Exceeded;
         when Status_Tx_Aborted         => return C_Status_Tx_Aborted;
         when Status_IO_Error           => return C_Status_IO_Error;
      end case;
   end To_C_Status;

   function C_Version_Major return int is (0);

   function C_Version_Minor return int is (3);

   procedure C_Init (Out_Status : out int) is
      DB_Path  : constant Bounded_Text := Make_Text ("/tmp/nhe_o_c_api.db");
      WAL_Path : constant Bounded_Text := Make_Text ("/tmp/nhe_o_c_api.wal");
   begin
      Delete_File_If_Exists (DB_Path);
      Delete_File_If_Exists (WAL_Path);
      G_Next_Tx     := 1;
      G_KV_Store    := (others => <>);
      G_Broker      := (others => <>);
      Init_RAG_Engine (G_RAG_Engine, 3);
      G_Initialized := True;
      Out_Status    := C_Status_Ok;
   end C_Init;

   procedure C_Analyze_SQL
     (Query_Buf      : in     C_Text_Buf;
      Query_Len      : in     int;
      Out_Stmt_Kind  :    out int;
      Out_Has_Vector :    out int;
      Out_Has_JSONB  :    out int;
      Out_Status     :    out int)
   is
      Query  : Bounded_Text;
      Desc   : Parsed_SQL_Descriptor;
      Status : Engine_Status;
   begin
      Out_Stmt_Kind  := 0;
      Out_Has_Vector := 0;
      Out_Has_JSONB  := 0;

      if Query_Len < 0 or else Query_Len > int (Max_Text_Len) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Query := To_Bounded_Text (Query_Buf, Text_Length (Query_Len));
      Analyze_SQL (Query, Desc, Status);

      Out_Stmt_Kind  := int (SQL_Statement_Kind'Pos (Desc.Kind));
      Out_Has_Vector := (if Desc.Has_Vector_Operator then 1 else 0);
      Out_Has_JSONB  := (if Desc.Has_JSONB_Operator then 1 else 0);
      Out_Status     := To_C_Status (Status);
   end C_Analyze_SQL;

   procedure C_Vector_Distance_3D
     (AX, AY, AZ     : in     C_float;
      BX, BY, BZ     : in     C_float;
      Out_L2_Dist    :    out C_float;
      Out_Cos_Dist   :    out C_float;
      Out_Hamming    :    out int;
      Out_Status     :    out int)
   is
      VA, VB : Vector_Value;
      BA, BB : Quantized_Binary_Vector;
      L2     : Non_Negative_Float;
      Cos    : Float;
      Ham    : Natural;
   begin
      Out_L2_Dist  := 0.0;
      Out_Cos_Dist := 0.0;
      Out_Hamming  := 0;

      if not (AX in -1.0e6 .. 1.0e6
              and then AY in -1.0e6 .. 1.0e6
              and then AZ in -1.0e6 .. 1.0e6
              and then BX in -1.0e6 .. 1.0e6
              and then BY in -1.0e6 .. 1.0e6
              and then BZ in -1.0e6 .. 1.0e6)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      VA := Make_Vector_3D (Float (AX), Float (AY), Float (AZ));
      VB := Make_Vector_3D (Float (BX), Float (BY), Float (BZ));

      L2  := L2_Distance (VA, VB);
      Cos := Cosine_Distance (VA, VB);
      BA  := Quantize_To_Binary (VA);
      BB  := Quantize_To_Binary (VB);
      Ham := Hamming_Distance (BA, BB);

      Out_L2_Dist  := C_float (L2);
      Out_Cos_Dist := C_float (Cos);
      Out_Hamming  := int (Ham);
      Out_Status   := C_Status_Ok;
   end C_Vector_Distance_3D;

   procedure C_KV_Set
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Val_Buf    : in     C_Text_Buf;
      Val_Len    : in     int;
      Now_Sec    : in     Integer_64;
      TTL_Sec    : in     Integer_64;
      Out_Status :    out int)
   is
      Key     : Bounded_Ident;
      Val     : Bounded_Text;
      Has_TTL : Boolean;
      TTL_Val : Epoch_Seconds;
   begin
      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Val_Len < 0 or else Val_Len > int (Max_Text_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      if TTL_Sec > 0 then
         if Now_Sec > Epoch_Seconds'Last - TTL_Sec then
            Out_Status := C_Status_Invalid_Arg;
            return;
         end if;
         Has_TTL := True;
         TTL_Val := TTL_Sec;
      else
         Has_TTL := False;
         TTL_Val := 0;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Val := To_Bounded_Text (Val_Buf, Text_Length (Val_Len));

      Set (G_KV_Store, Key, Val, Now_Sec, Has_TTL, TTL_Val);
      Out_Status := C_Status_Ok;
   end C_KV_Set;

   procedure C_KV_Get
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      Out_Val_Buf :    out C_Text_Buf;
      Out_Val_Len :    out int;
      Out_Status  :    out int)
   is
      Key    : Bounded_Ident;
      Val    : Bounded_Text;
      Status : Engine_Status;
   begin
      Out_Val_Buf := [others => nul];
      Out_Val_Len := 0;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Get (G_KV_Store, Key, Now_Sec, Val, Status);

      if Status = Status_Ok then
         From_Bounded_Text (Val, Out_Val_Buf, Out_Val_Len);
      end if;
      Out_Status := To_C_Status (Status);
   end C_KV_Get;

   procedure C_KV_Del
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Out_Removed :    out int;
      Out_Status  :    out int)
   is
      Key     : Bounded_Ident;
      Removed : Boolean;
   begin
      Out_Removed := 0;
      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Del (G_KV_Store, Key, Removed);
      Out_Removed := (if Removed then 1 else 0);
      Out_Status  := C_Status_Ok;
   end C_KV_Del;

   procedure C_KV_Incr_By
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Delta_Val   : in     Integer_64;
      Now_Sec     : in     Integer_64;
      Out_New_Val :    out Integer_64;
      Out_Status  :    out int)
   is
      Key    : Bounded_Ident;
      Status : Engine_Status;
   begin
      Out_New_Val := 0;
      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Incr_By (G_KV_Store, Key, Delta_Val, Now_Sec, Out_New_Val, Status);
      Out_Status := To_C_Status (Status);
   end C_KV_Incr_By;

   procedure C_PubSub_Subscribe
     (Pattern_Buf : in     C_Ident_Buf;
      Pattern_Len : in     int;
      Out_Sub_Id  :    out int;
      Out_Status  :    out int)
   is
      Pattern : Bounded_Ident;
      Sub_Id  : Subscriber_Id;
      Status  : Engine_Status;
   begin
      Out_Sub_Id := 0;
      if Pattern_Len <= 0 or else Pattern_Len > int (Max_Ident_Len) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Pattern := To_Bounded_Ident (Pattern_Buf, Ident_Length (Pattern_Len));
      Subscribe (G_Broker, Pattern, Sub_Id, Status);
      if Status = Status_Ok then
         Out_Sub_Id := int (Sub_Id);
      end if;
      Out_Status := To_C_Status (Status);
   end C_PubSub_Subscribe;

   procedure C_PubSub_Publish
     (Chan_Buf      : in     C_Ident_Buf;
      Chan_Len      : in     int;
      Payload_Buf   : in     C_Text_Buf;
      Payload_Len   : in     int;
      Out_Delivered :    out int;
      Out_Status    :    out int)
   is
      Channel   : Bounded_Ident;
      Payload   : Bounded_Text;
      Delivered : Subscriber_Count;
   begin
      Out_Delivered := 0;
      if Chan_Len <= 0 or else Chan_Len > int (Max_Ident_Len)
        or else Payload_Len < 0 or else Payload_Len > int (Max_Text_Len)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Channel := To_Bounded_Ident (Chan_Buf, Ident_Length (Chan_Len));
      Payload := To_Bounded_Text (Payload_Buf, Text_Length (Payload_Len));
      Publish (G_Broker, Channel, Payload, Delivered);
      Out_Delivered := int (Delivered);
      Out_Status    := C_Status_Ok;
   end C_PubSub_Publish;

   procedure C_PubSub_Poll
     (Sub_Id          : in     int;
      Out_Chan_Buf    :    out C_Ident_Buf;
      Out_Chan_Len    :    out int;
      Out_Payload_Buf :    out C_Text_Buf;
      Out_Payload_Len :    out int;
      Out_Found       :    out int;
      Out_Status      :    out int)
   is
      Msg   : PubSub_Message;
      Found : Boolean;
   begin
      Out_Chan_Buf    := [others => nul];
      Out_Chan_Len    := 0;
      Out_Payload_Buf := [others => nul];
      Out_Payload_Len := 0;
      Out_Found       := 0;

      if Sub_Id not in int (Subscriber_Id'First) .. int (Subscriber_Id'Last) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Poll_Message (G_Broker, Subscriber_Id (Sub_Id), Msg, Found);
      if Found then
         From_Bounded_Ident (Msg.Channel, Out_Chan_Buf, Out_Chan_Len);
         From_Bounded_Text (Msg.Payload, Out_Payload_Buf, Out_Payload_Len);
         Out_Found  := 1;
         Out_Status := C_Status_Ok;
      else
         Out_Found  := 0;
         Out_Status := C_Status_Not_Found;
      end if;
   end C_PubSub_Poll;

   procedure C_RAG_Ingest_3D
     (Doc_Id         : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      VX, VY, VZ     : in     C_float;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
   is
      DB_Path        : constant Bounded_Text := Make_Text ("/tmp/nhe_o_c_api.db");
      WAL_Path       : constant Bounded_Text := Make_Text ("/tmp/nhe_o_c_api.wal");
      Tx             : Transaction_Context;
      Staging        : Tx_Notification_Buffer := (others => <>);
      Meta           : JSONB_Document         := (others => <>);
      Summary        : Bounded_Text;
      Vec            : Vector_Value;
      Parent_Payload : TOAST_Payload_Buffer   := [others => 0];
      Parent_Len     : Valid_TOAST_Length     := 128;
      Commit_Page    : constant Page_Buffer   := [others => 0];
      Status         : Engine_Status;
      Commit_Status  : Engine_Status;
      Flushed_Count  : Natural;
      pragma Warnings (Off, Flushed_Count);
   begin
      if Doc_Id not in int (RAG_Doc_Slot'First) .. int (RAG_Doc_Slot'Last)
        or else Summary_Len < 0 or else Summary_Len > int (Max_Text_Len)
        or else Related_Doc_Id not in int (Optional_Doc_Id'First) .. int (Optional_Doc_Id'Last)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      if not (VX in -1.0e6 .. 1.0e6
              and then VY in -1.0e6 .. 1.0e6
              and then VZ in -1.0e6 .. 1.0e6)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      --  Ensure RAG engine and transaction sequence satisfy preconditions
      if G_Next_Tx = Max_Tx_Id
        or else G_RAG_Engine.Dim /= 3
        or else G_RAG_Engine.Vector_Graph.Dim /= 3
        or else G_RAG_Engine.PK_Tree.Node_Count not in 1 .. Max_BTree_Nodes
        or else G_RAG_Engine.PK_Tree.Root_Node not in 1 .. G_RAG_Engine.PK_Tree.Node_Count
        or else G_RAG_Engine.Next_TOAST_Pg > Max_Page_Id - Max_TOAST_Chunks
      then
         Out_Status := C_Status_Capacity_Exceeded;
         return;
      end if;

      Summary := To_Bounded_Text (Summary_Buf, Text_Length (Summary_Len));
      Vec     := Make_Vector_3D (Float (VX), Float (VY), Float (VZ));

      if Summary.Length > 0 then
         Parent_Len := Summary.Length;
         for I in 1 .. Summary.Length loop
            pragma Loop_Invariant (I in 1 .. Summary.Length);
            Parent_Payload (I) := Byte (Character'Pos (Summary.Data (I)));
         end loop;
      end if;

      Put_Field (Meta, Make_Ident ("source"), Make_Text ("c_api"), JSONB_String, Status);
      Begin_Tx (G_Next_Tx, Tx);

      Ingest_Document
        (Engine         => G_RAG_Engine,
         Ctx            => Tx,
         DB_Path        => DB_Path,
         WAL_Path       => WAL_Path,
         Staging        => Staging,
         Doc_Id         => RAG_Doc_Slot (Doc_Id),
         Metadata       => Meta,
         Summary_Text   => Summary,
         Embedding      => Vec,
         Parent_Payload => Parent_Payload,
         Parent_Length  => Parent_Len,
         Related_Doc_Id => Optional_Doc_Id (Related_Doc_Id),
         Layer_Hint     => 1,
         Status         => Status);

      if Status /= Status_Ok then
         Rollback_Tx (Tx);
         Discard_Staged_Notifications (Tx, Staging);
         Out_Status := To_C_Status (Status);
         return;
      end if;

      Commit_Tx (Tx, DB_Path, WAL_Path, 1, Commit_Page, Commit_Status);
      if Commit_Status = Status_Ok then
         Flush_Committed_Notifications (Tx, Staging, G_Broker, Flushed_Count);
      else
         Discard_Staged_Notifications (Tx, Staging);
      end if;

      Out_Status := To_C_Status (Commit_Status);
   end C_RAG_Ingest_3D;

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
   is
      DB_Path     : constant Bounded_Text  := Make_Text ("/tmp/nhe_o_c_api.db");
      SQL_Query   : constant Bounded_Text  :=
        Make_Text ("SELECT id, chunk FROM rag_docs ORDER BY emb <-> $1;");
      Empty_Meta  : constant JSONB_Document := (others => <>);
      Query_Vec   : Vector_Value;
      Encoding    : Vector_Encoding_Kind;
      Keyword     : Bounded_Text;
      Use_Keyword : Boolean;
      Result      : RAG_Query_Result;
      Top_Parent  : TOAST_Payload_Buffer;
      pragma Warnings (Off, Top_Parent);
      Status      : Engine_Status;
   begin
      Out_Hit_Count    := 0;
      Out_Top_Doc_Id   := 0;
      Out_Top_Distance := 0.0;
      Out_Parent_Bytes := 0;
      Out_Graph_Hit    := 0;

      if Keyword_Len < 0 or else Keyword_Len > int (Max_Text_Len)
        or else Top_K not in int (RAG_Hit_Index'First) .. int (RAG_Hit_Index'Last)
        or else Encoding_Mode not in 0 .. 2
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      if not (QX in -1.0e6 .. 1.0e6
              and then QY in -1.0e6 .. 1.0e6
              and then QZ in -1.0e6 .. 1.0e6)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      if G_RAG_Engine.Dim /= 3 or else G_RAG_Engine.Vector_Graph.Dim /= 3 then
         Out_Status := C_Status_Dimension_Mismatch;
         return;
      end if;

      case Encoding_Mode is
         when 0      => Encoding := Encoding_Float32;
         when 1      => Encoding := Encoding_Int8_SQ8;
         when others => Encoding := Encoding_Binary_1Bit;
      end case;

      Query_Vec   := Make_Vector_3D (Float (QX), Float (QY), Float (QZ));
      Keyword     := To_Bounded_Text (Keyword_Buf, Text_Length (Keyword_Len));
      Use_Keyword := Keyword.Length > 0;

      Execute_Hybrid_RAG_Query
        (Engine            => G_RAG_Engine,
         Snapshot          => G_Next_Tx,
         DB_Path           => DB_Path,
         SQL_Query         => SQL_Query,
         Query_Vec         => Query_Vec,
         Encoding          => Encoding,
         Use_Meta_Filter   => False,
         Filter_Meta       => Empty_Meta,
         Use_Keyword_Boost => Use_Keyword,
         Keyword           => Keyword,
         Top_K             => RAG_Hit_Index (Top_K),
         Result            => Result,
         Top_Parent_Chunk  => Top_Parent,
         Status            => Status);

      if Status = Status_Ok then
         Out_Hit_Count    := int (Result.Count);
         Out_Parent_Bytes := int (Result.Top_Parent_Bytes);
         Out_Graph_Hit    := (if Result.Graph_Neighbor_Hit then 1 else 0);
         if Result.Count >= 1 then
            Out_Top_Doc_Id   := int (Result.Hits (1).Doc_Id);
            if Result.Hits (1).Distance <= 1.0e30 then
               Out_Top_Distance := C_float (Result.Hits (1).Distance);
            end if;
         end if;
      end if;

      Out_Status := To_C_Status (Status);
   end C_RAG_Query_3D;

end Nhe_O.C_API;
