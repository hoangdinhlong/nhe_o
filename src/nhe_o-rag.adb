pragma SPARK_Mode (On);

with Interfaces; use Interfaces;
with Nhe_O.SQL;  use Nhe_O.SQL;

package body Nhe_O.RAG is

   procedure Init_RAG_Engine
     (Engine :    out RAG_Engine;
      Dim    : in     Vector_Dim)
   is
   begin
      Engine.Dim           := Dim;
      Engine.Doc_Count     := 0;
      Engine.Next_TOAST_Pg := 10;
      Engine.CLOG          := Default_CLOG;
      Engine.Docs          := [others => (others => <>)];
      Init_BTree (Engine.PK_Tree);
      Init_HNSW (Engine.Vector_Graph, Dim);
   end Init_RAG_Engine;

   function Contains_Keyword
     (Text    : Bounded_Text;
      Keyword : Bounded_Text) return Boolean
   is
      Match : Boolean;
   begin
      --  Empty keyword never matches a lexical boost (HIGH-05)
      if Keyword.Length = 0 or else Text.Length < Keyword.Length then
         return False;
      end if;

      for Start_Pos in 1 .. Text.Length - Keyword.Length + 1 loop
         Match := True;
         for Offset in 1 .. Keyword.Length loop
            if To_Lower_Char (Text.Data (Start_Pos + Offset - 1)) /=
               To_Lower_Char (Keyword.Data (Offset))
            then
               Match := False;
               exit;
            end if;
         end loop;
         if Match then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Keyword;

   procedure Delete_Document
     (Engine : in out RAG_Engine;
      Ctx    : in     Transaction_Context;
      Doc_Id : in     RAG_Doc_Slot;
      Status :    out Engine_Status)
   is
   begin
      if not Engine.Docs (Doc_Id).Active
        or else Engine.Docs (Doc_Id).Tuple_Hdr.Xmax > 0
      then
         Status := Status_Not_Found;
         return;
      end if;

      Set_CLOG_State (Engine.CLOG, Ctx.Id, Tx_Active);
      Engine.Docs (Doc_Id).Tuple_Hdr.Xmax := Ctx.Id;
      if Engine.Doc_Count > 0 then
         Engine.Doc_Count := Engine.Doc_Count - 1;
      end if;
      Status := Status_Ok;
   end Delete_Document;

   -------------------------------------------------------------------------
   --  Build_RAG_Slotted_Page & Recover_RAG_Engine (CRIT-01, CRIT-05, R2-HIGH-03)
   -------------------------------------------------------------------------

   procedure Build_RAG_Slotted_Page
     (Engine   : in     RAG_Engine;
      LSN_Tx   : in     Valid_Tx_Id;
      Raw_Page :    out Page_Buffer)
   is
      Page_Rec      : Slotted_Page;
      Vec_B         : TOAST_Pointer_Bytes;
      Sum_Len       : Natural;
      Key_Len       : Natural;
      Val_Len       : Natural;
      Cur_Off       : Positive;
      Stored_Fields : Natural;
      Inl_Data      : Inline_Tuple_Buffer;
   begin
      Page_Rec.Page_Id     := 1;
      Page_Rec.Page_LSN_Tx := LSN_Tx;
      Page_Rec.Slot_Count  := Engine.Doc_Count;

      for Slot in RAG_Doc_Slot loop
         Inl_Data := [others => 0];
         Encode_TOAST_Pointer (Engine.Docs (Slot).Vec_Toast_Ptr, Vec_B);
         for B in TOAST_Pointer_Index loop
            Inl_Data (B) := Vec_B (B);
         end loop;

         --  Bytes 17..96: Summary_Text (1B length <= 79 + up to 79B payload)
         Sum_Len := Natural'Min (79, Engine.Docs (Slot).Summary_Text.Length);
         Inl_Data (17) := Byte (Sum_Len);
         for I in 1 .. Sum_Len loop
            Inl_Data (17 + I) :=
              Byte (Character'Pos (Engine.Docs (Slot).Summary_Text.Data (I)));
         end loop;

         --  Bytes 97..208: Multi-field JSONB Metadata (R2-HIGH-03)
         --  Byte 97 = Stored_Fields count; Bytes 98..208 = packed entries
         --  (Key_Len: 1B, Val_Len: 1B, Kind: 1B, Key_Bytes, Val_Bytes)
         Stored_Fields := 0;
         Cur_Off       := 98;
         for F_Idx in 1 .. Engine.Docs (Slot).Metadata.Count loop
            pragma Loop_Invariant (Stored_Fields < F_Idx);
            pragma Loop_Invariant (Cur_Off in 98 .. Max_Inline_Tuple_Bytes + 1);
            if Engine.Docs (Slot).Metadata.Fields (F_Idx).Active then
               Key_Len :=
                 Natural'Min (24, Engine.Docs (Slot).Metadata.Fields (F_Idx).Key.Length);
               Val_Len :=
                 Natural'Min (32, Engine.Docs (Slot).Metadata.Fields (F_Idx).Val.Length);
               if Key_Len > 0
                 and then Cur_Off + 2 + Key_Len + Val_Len <= Max_Inline_Tuple_Bytes
               then
                  Inl_Data (Cur_Off)     := Byte (Key_Len);
                  Inl_Data (Cur_Off + 1) := Byte (Val_Len);
                  Inl_Data (Cur_Off + 2) :=
                    Byte (JSONB_Value_Kind'Pos
                      (Engine.Docs (Slot).Metadata.Fields (F_Idx).Kind));
                  for I in 1 .. Key_Len loop
                     Inl_Data (Cur_Off + 2 + I) :=
                       Byte (Character'Pos
                         (Engine.Docs (Slot).Metadata.Fields (F_Idx).Key.Data (I)));
                  end loop;
                  for I in 1 .. Val_Len loop
                     Inl_Data (Cur_Off + 2 + Key_Len + I) :=
                       Byte (Character'Pos
                         (Engine.Docs (Slot).Metadata.Fields (F_Idx).Val.Data (I)));
                  end loop;
                  Cur_Off       := Cur_Off + 3 + Key_Len + Val_Len;
                  Stored_Fields := Stored_Fields + 1;
               end if;
            end if;
         end loop;
         Inl_Data (97) := Byte (Stored_Fields);

         Page_Rec.Tuples (Slot) := (
            Occupied    => Engine.Docs (Slot).Active,
            Row_Id      => Engine.Docs (Slot).Doc_Id,
            Tuple_Hdr   => Engine.Docs (Slot).Tuple_Hdr,
            Toast_Ptr   => Engine.Docs (Slot).Toast_Ptr,
            Related_Id  => Engine.Docs (Slot).Related_Doc_Id,
            Inline_Len  => Max_Inline_Tuple_Bytes,
            Inline_Data => Inl_Data
         );
      end loop;

      Encode_Slotted_Page (Page_Rec, Raw_Page);
   end Build_RAG_Slotted_Page;

   procedure Delete_Document
     (Engine   : in out RAG_Engine;
      Ctx      : in     Transaction_Context;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Doc_Id   : in     RAG_Doc_Slot;
      Status   :    out Engine_Status)
   is
      Saved_Engine : constant RAG_Engine := Engine;
      Slot_Page    : Page_Buffer;
      Slot_WAL     : WAL_Frame_Buffer;
      Slot_CRC     : Unsigned_32;
      pragma Warnings (Off, Slot_CRC);
      WAL_Ok       : Boolean;
   begin
      if Has_Embedded_NUL (DB_Path) or else Has_Embedded_NUL (WAL_Path) then
         Status := Status_IO_Error;
         return;
      end if;

      if not Engine.Docs (Doc_Id).Active
        or else Engine.Docs (Doc_Id).Tuple_Hdr.Xmax > 0
      then
         Status := Status_Not_Found;
         return;
      end if;

      Set_CLOG_State (Engine.CLOG, Ctx.Id, Tx_Active);
      Engine.Docs (Doc_Id).Tuple_Hdr.Xmax := Ctx.Id;
      if Engine.Doc_Count > 0 then
         Engine.Doc_Count := Engine.Doc_Count - 1;
      end if;

      --  Stage updated Slotted_Page in WAL (NO-STEAL; Commit_Tx flushes to DB_Path)
      Build_RAG_Slotted_Page (Engine, Ctx.Id, Slot_Page);
      Encode_WAL_Frame (Ctx.Id, 1, Slot_Page, Slot_CRC, Slot_WAL, WAL_Frame_Data);
      Append_WAL_Frame (WAL_Path, Slot_WAL, WAL_Ok);
      if not WAL_Ok then
         Engine := Saved_Engine;
         Status := Status_IO_Error;
         return;
      end if;

      Status := Status_Ok;
   end Delete_Document;

   -------------------------------------------------------------------------
   --  Recompute_TOAST_High_Water_Mark & Rollback_RAG_Tx (R2-CRIT-01, R2-MED-03)
   -------------------------------------------------------------------------

   procedure Recompute_TOAST_High_Water_Mark
     (Engine        : in out RAG_Engine;
      Updating_Slot : in     Optional_Doc_Id)
     with Pre  => Engine.Vector_Graph.Dim = Engine.Dim
                  and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                  and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post => Engine.Dim = Engine.Dim'Old
                  and then Engine.Vector_Graph.Dim = Engine.Dim
                  and then Engine.PK_Tree.Node_Count = Engine.PK_Tree.Node_Count'Old
                  and then Engine.PK_Tree.Root_Node = Engine.PK_Tree.Root_Node'Old
                  and then Engine.Next_TOAST_Pg in 10 .. Max_Safe_TOAST_Page
   is
      HWM      : Valid_Page_Id := 10;
      End_Page : Natural;
   begin
      for S in RAG_Doc_Slot loop
         pragma Loop_Invariant (HWM in 10 .. Max_Safe_TOAST_Page);
         if Engine.Docs (S).Active then
            if S /= Updating_Slot
              or else Is_Tx_Committed (Engine.CLOG, Engine.Docs (S).Tuple_Hdr.Xmin)
            then
               End_Page :=
                 Engine.Docs (S).Toast_Ptr.Root_Overflow_Page +
                 Engine.Docs (S).Toast_Ptr.Chunk_Count;
               if End_Page > HWM and then End_Page <= Max_Safe_TOAST_Page then
                  HWM := End_Page;
               end if;

               End_Page :=
                 Engine.Docs (S).Vec_Toast_Ptr.Root_Overflow_Page +
                 Engine.Docs (S).Vec_Toast_Ptr.Chunk_Count;
               if End_Page > HWM and then End_Page <= Max_Safe_TOAST_Page then
                  HWM := End_Page;
               end if;
            end if;

            if Engine.Docs (S).Has_Prior_Version
              and then (S /= Updating_Slot
                        or else not Is_Tx_Committed
                          (Engine.CLOG, Engine.Docs (S).Tuple_Hdr.Xmin))
            then
               End_Page :=
                 Engine.Docs (S).Prior_Toast_Ptr.Root_Overflow_Page +
                 Engine.Docs (S).Prior_Toast_Ptr.Chunk_Count;
               if End_Page > HWM and then End_Page <= Max_Safe_TOAST_Page then
                  HWM := End_Page;
               end if;

               End_Page :=
                 Engine.Docs (S).Prior_Vec_Toast_Ptr.Root_Overflow_Page +
                 Engine.Docs (S).Prior_Vec_Toast_Ptr.Chunk_Count;
               if End_Page > HWM and then End_Page <= Max_Safe_TOAST_Page then
                  HWM := End_Page;
               end if;
            end if;
         end if;
      end loop;

      Engine.Next_TOAST_Pg := HWM;
   end Recompute_TOAST_High_Water_Mark;

   procedure Rollback_RAG_Tx
     (Engine : in out RAG_Engine;
      Tx_Num : in     Valid_Tx_Id)
   is
      Removed           : Boolean;
      Sub_Stat          : Engine_Status;
      Prior_Was_Deleted : Boolean;
      pragma Warnings (Off, Removed);
      pragma Warnings (Off, Sub_Stat);
   begin
      Set_CLOG_State (Engine.CLOG, Tx_Num, Tx_Aborted);

      for Slot in RAG_Doc_Slot loop
         pragma Loop_Invariant (Engine.Dim = Engine.Dim'Loop_Entry);
         pragma Loop_Invariant (Engine.Vector_Graph.Dim = Engine.Dim);
         pragma Loop_Invariant (Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes);
         pragma Loop_Invariant (Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count);

         if Engine.Docs (Slot).Active then
            if Engine.Docs (Slot).Tuple_Hdr.Xmin = Tx_Num then
               if Engine.Docs (Slot).Has_Prior_Version then
                  Prior_Was_Deleted :=
                    Engine.Docs (Slot).Prior_Tuple_Hdr.Xmax > 0
                    and then Engine.Docs (Slot).Prior_Tuple_Hdr.Xmax /= Tx_Num;

                  Engine.Docs (Slot) := (
                     Active              => True,
                     Doc_Id              => Slot,
                     Tuple_Hdr           =>
                       (Xmin => Engine.Docs (Slot).Prior_Tuple_Hdr.Xmin,
                        Xmax => (if Prior_Was_Deleted
                                 then Engine.Docs (Slot).Prior_Tuple_Hdr.Xmax
                                 else 0)),
                     Metadata            => Engine.Docs (Slot).Prior_Metadata,
                     Summary_Text        => Engine.Docs (Slot).Prior_Summary,
                     Toast_Ptr           => Engine.Docs (Slot).Prior_Toast_Ptr,
                     Vec_Toast_Ptr       => Engine.Docs (Slot).Prior_Vec_Toast_Ptr,
                     Related_Doc_Id      => Engine.Docs (Slot).Prior_Related_Id,
                     Has_Prior_Version   => False,
                     Prior_Tuple_Hdr     => (Xmin => 1, Xmax => 0),
                     Prior_Metadata      => (others => <>),
                     Prior_Summary       => (Length => 0, Data => [others => ' ']),
                     Prior_Toast_Ptr     => (others => <>),
                     Prior_Vec_Toast_Ptr => (others => <>),
                     Prior_Related_Id    => 0
                  );
                  Insert_Key
                    (Tree   => Engine.PK_Tree,
                     Key    => Integer_64 (Slot),
                     Ptr    => (Target_Page => 1,
                                Target_Slot => Slot,
                                TOAST_Root  => Engine.Docs (Slot).Toast_Ptr.Root_Overflow_Page),
                     Status => Sub_Stat);
               else
                  Engine.Docs (Slot) := (others => <>);
                  Delete_Key (Engine.PK_Tree, Integer_64 (Slot), Removed);
                  for N_Idx in 1 .. Engine.Vector_Graph.Node_Count loop
                     if Engine.Vector_Graph.Nodes (N_Idx).Active
                       and then Engine.Vector_Graph.Nodes (N_Idx).Doc_Id = Slot
                     then
                        Engine.Vector_Graph.Nodes (N_Idx).Active := False;
                     end if;
                  end loop;
               end if;
            elsif Engine.Docs (Slot).Tuple_Hdr.Xmax = Tx_Num then
               Engine.Docs (Slot).Tuple_Hdr.Xmax := 0;
            end if;
         end if;
      end loop;

      Engine.Doc_Count := 0;
      for S in RAG_Doc_Slot loop
         pragma Loop_Invariant (Engine.Doc_Count < S);
         if Engine.Docs (S).Active and then Engine.Docs (S).Tuple_Hdr.Xmax = 0 then
            Engine.Doc_Count := Engine.Doc_Count + 1;
         end if;
      end loop;

      Recompute_TOAST_High_Water_Mark (Engine, 0);
   end Rollback_RAG_Tx;

   procedure Recover_RAG_Engine
     (Engine   :    out RAG_Engine;
      Dim      : in     Vector_Dim;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Status   :    out Engine_Status)
   is
      Replayed      : Natural;
      Max_Rec_Tx    : Tx_Id;
      Sub_Stat      : Engine_Status;
      Raw_Page      : Page_Buffer;
      Read_Ok       : Boolean;
      Page_Rec      : Slotted_Page;
      Page_Valid    : Boolean;
      Vec_B         : TOAST_Pointer_Bytes;
      Vec_Ptr       : TOAST_Pointer;
      Vec_Valid     : Boolean;
      Vec_Payload   : TOAST_Payload_Buffer;
      Vec_Len       : TOAST_Payload_Length;
      Rec_Vec       : Vector_Value;
      Dec_Valid     : Boolean;
      Sum_Len       : Natural;
      Stored_Fields : Natural;
      Cur_Off       : Positive;
      Key_Len       : Natural;
      Val_Len       : Natural;
      Kind_Raw      : Natural;
      Meta_Key      : Bounded_Ident;
      Meta_Val      : Bounded_Text;
      Meta_Kind     : JSONB_Value_Kind;
      End_Page      : Natural;
      Expected_VLen : constant Valid_TOAST_Length := Vector_TOAST_Byte_Length (Dim);
      pragma Warnings (Off, Replayed);
      pragma Warnings (Off, Max_Rec_Tx);
      pragma Warnings (Off, Sub_Stat);
      pragma Warnings (Off, Dec_Valid);
   begin
      Init_RAG_Engine (Engine, Dim);

      --  1. Run 2-pass committed-only WAL Redo Recovery
      Redo_WAL_Recovery
        (DB_Path          => DB_Path,
         WAL_Path         => WAL_Path,
         Max_Frames       => 256,
         Replayed_Count   => Replayed,
         Max_Recovered_Tx => Max_Rec_Tx,
         Status           => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Status := Sub_Stat;
         return;
      end if;

      --  2. Read and CRC32-verify primary Slotted_Page at Page_Id = 1
      Read_Page (DB_Path, 1, Raw_Page, Read_Ok);
      if not Read_Ok then
         Status := Status_IO_Error;
         return;
      end if;

      Decode_Slotted_Page (Raw_Page, Page_Rec, Page_Valid);
      if not Page_Valid then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  3. Reconstruct documents, CLOG, B+Tree PK index, and HNSW vector graph
      for Slot in RAG_Doc_Slot loop
         pragma Loop_Invariant (Engine.Dim = Dim);
         pragma Loop_Invariant (Engine.Vector_Graph.Dim = Dim);
         pragma Loop_Invariant (Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes);
         pragma Loop_Invariant (Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count);
         pragma Loop_Invariant (Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page);

         if Page_Rec.Tuples (Slot).Occupied then
            for B in TOAST_Pointer_Index loop
               Vec_B (B) := Page_Rec.Tuples (Slot).Inline_Data (B);
            end loop;
            Decode_TOAST_Pointer (Vec_B, Vec_Ptr, Vec_Valid);
            if not Vec_Valid then
               Vec_Ptr := (others => <>);
            end if;

            Sum_Len := Natural'Min (79, Natural (Page_Rec.Tuples (Slot).Inline_Data (17)));
            Engine.Docs (Slot).Summary_Text := (Length => Sum_Len, Data => [others => ' ']);
            for I in 1 .. Sum_Len loop
               Engine.Docs (Slot).Summary_Text.Data (I) :=
                 Character'Val (Natural (Page_Rec.Tuples (Slot).Inline_Data (17 + I)));
            end loop;

            Engine.Docs (Slot).Metadata := (others => <>);
            Stored_Fields :=
              Natural'Min (Max_JSON_Fields, Natural (Page_Rec.Tuples (Slot).Inline_Data (97)));
            Cur_Off := 98;
            for F_Idx in 1 .. Stored_Fields loop
               pragma Loop_Invariant (Cur_Off in 98 .. Max_Inline_Tuple_Bytes + 1);
               exit when Cur_Off + 2 > Max_Inline_Tuple_Bytes;
               Key_Len  := Natural'Min (24, Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off)));
               Val_Len  := Natural'Min (32, Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off + 1)));
               Kind_Raw := Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off + 2));
               exit when Key_Len = 0
                 or else Kind_Raw > JSONB_Value_Kind'Pos (JSONB_Array)
                 or else Cur_Off + 2 + Key_Len + Val_Len > Max_Inline_Tuple_Bytes;

               Meta_Key  := (Length => Key_Len, Data => [others => ' ']);
               Meta_Val  := (Length => Val_Len, Data => [others => ' ']);
               Meta_Kind := JSONB_Value_Kind'Val (Kind_Raw);
               for I in 1 .. Key_Len loop
                  Meta_Key.Data (I) :=
                    Character'Val (Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off + 2 + I)));
               end loop;
               for I in 1 .. Val_Len loop
                  Meta_Val.Data (I) :=
                    Character'Val (Natural
                      (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off + 2 + Key_Len + I)));
               end loop;
               Put_Field (Engine.Docs (Slot).Metadata, Meta_Key, Meta_Val, Meta_Kind, Sub_Stat);
               Cur_Off := Cur_Off + 3 + Key_Len + Val_Len;
            end loop;

            Engine.Docs (Slot).Active         := True;
            Engine.Docs (Slot).Doc_Id         := Slot;
            Engine.Docs (Slot).Tuple_Hdr      := Page_Rec.Tuples (Slot).Tuple_Hdr;
            Engine.Docs (Slot).Toast_Ptr      := Page_Rec.Tuples (Slot).Toast_Ptr;
            Engine.Docs (Slot).Vec_Toast_Ptr  := Vec_Ptr;
            Engine.Docs (Slot).Related_Doc_Id :=
              (if Page_Rec.Tuples (Slot).Related_Id <= Max_RAG_Docs
               then Page_Rec.Tuples (Slot).Related_Id else 0);

            --  Mark recovered tuple's Xmin (and Xmax if deleted) as committed in CLOG
            Set_CLOG_State
              (Engine.CLOG, Page_Rec.Tuples (Slot).Tuple_Hdr.Xmin, Tx_Committed);
            if Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax > 0 then
               Set_CLOG_State
                 (Engine.CLOG, Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax, Tx_Committed);
            elsif Engine.Doc_Count < Max_RAG_Docs then
               Engine.Doc_Count := Engine.Doc_Count + 1;
            end if;

            --  Advance Next_TOAST_Pg past recovered TOAST chains
            End_Page :=
              Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page +
              Page_Rec.Tuples (Slot).Toast_Ptr.Chunk_Count;
            if End_Page > Engine.Next_TOAST_Pg and then End_Page <= Max_Safe_TOAST_Page then
               Engine.Next_TOAST_Pg := End_Page;
            end if;

            End_Page := Vec_Ptr.Root_Overflow_Page + Vec_Ptr.Chunk_Count;
            if End_Page > Engine.Next_TOAST_Pg and then End_Page <= Max_Safe_TOAST_Page then
               Engine.Next_TOAST_Pg := End_Page;
            end if;

            Insert_Key
              (Tree   => Engine.PK_Tree,
               Key    => Integer_64 (Slot),
               Ptr    => (Target_Page => 1,
                          Target_Slot => Slot,
                          TOAST_Root  => Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page),
               Status => Sub_Stat);

            Rec_Vec := (Dim => Dim, Elements => [others => 0.0]);
            if Vec_Valid
              and then Vec_Ptr.Total_Byte_Length = Expected_VLen
              and then Vec_Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks
            then
               Read_TOAST_Chain (DB_Path, Vec_Ptr, Vec_Payload, Vec_Len, Sub_Stat);
               if Sub_Stat = Status_Ok and then Vec_Len = Expected_VLen then
                  Decode_Vector_TOAST (Vec_Payload, Vec_Len, Dim, Rec_Vec, Dec_Valid);
               end if;
            end if;

            if Engine.Vector_Graph.Node_Count < Max_HNSW_Nodes then
               Insert_Vector
                 (Index      => Engine.Vector_Graph,
                  Doc_Id     => Slot,
                  Vec        => Rec_Vec,
                  TOAST_Root => Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page,
                  Layer_Hint => 1,
                  Status     => Sub_Stat);
            end if;
         end if;
      end loop;

      Status := Status_Ok;
   end Recover_RAG_Engine;

   -------------------------------------------------------------------------
   --  Ingest_Document
   -------------------------------------------------------------------------

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
   is
      Saved_Engine      : constant RAG_Engine         := Engine;
      Old_Entry         : constant RAG_Document_Entry := Engine.Docs (Doc_Id);
      Old_Xmin_Comm     : constant Boolean            :=
        Old_Entry.Active
        and then Is_Tx_Committed (Engine.CLOG, Old_Entry.Tuple_Hdr.Xmin);
      Old_Xmax_Comm     : constant Boolean            :=
        Old_Entry.Active
        and then Old_Entry.Tuple_Hdr.Xmax > 0
        and then Is_Tx_Committed (Engine.CLOG, Old_Entry.Tuple_Hdr.Xmax);
      Keep_Prior        : constant Boolean            :=
        (Old_Entry.Active and then Old_Xmin_Comm)
        or else (Old_Entry.Active and then Old_Entry.Has_Prior_Version);
      Retained_Hdr      : constant MVCC_Tuple_Header  :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then (Xmin => Old_Entry.Tuple_Hdr.Xmin,
               Xmax => (if Old_Xmax_Comm then Old_Entry.Tuple_Hdr.Xmax else Ctx.Id))
         elsif Old_Entry.Active and then Old_Entry.Has_Prior_Version
         then Old_Entry.Prior_Tuple_Hdr
         else (Xmin => 1, Xmax => 0));
      Retained_Meta     : constant JSONB_Document     :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Metadata else Old_Entry.Prior_Metadata);
      Retained_Sum      : constant Bounded_Text       :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Summary_Text else Old_Entry.Prior_Summary);
      Retained_Toast    : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Toast_Ptr else Old_Entry.Prior_Toast_Ptr);
      Retained_Vec_P    : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Vec_Toast_Ptr else Old_Entry.Prior_Vec_Toast_Ptr);
      Retained_Rel      : constant Optional_Doc_Id    :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Related_Doc_Id else Old_Entry.Prior_Related_Id);
      Retired_Doc_Ptr   : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm and then Old_Entry.Has_Prior_Version
         then Old_Entry.Prior_Toast_Ptr
         elsif Old_Entry.Active and then not Old_Xmin_Comm
         then Old_Entry.Toast_Ptr
         else (others => <>));
      Retired_Vec_Ptr   : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm and then Old_Entry.Has_Prior_Version
         then Old_Entry.Prior_Vec_Toast_Ptr
         elsif Old_Entry.Active and then not Old_Xmin_Comm
         then Old_Entry.Vec_Toast_Ptr
         else (others => <>));
      Needed_Doc_Chunks : constant Positive           :=
        ((Parent_Length - 1) / TOAST_Chunk_Max_Bytes) + 1;
      Ptr               : TOAST_Pointer;
      Vec_Ptr           : TOAST_Pointer;
      Vec_Payload       : TOAST_Payload_Buffer;
      Vec_Byte_Len      : Valid_TOAST_Length;
      Needed_Vec_Chunks : Positive;
      Start_Pg          : Valid_Page_Id;
      Vec_Start_Pg      : Valid_Page_Id;
      Reused_Doc_Place  : Boolean                     := False;
      Reused_Vec_Place  : Boolean                     := False;
      Sub_Stat          : Engine_Status;
      Slot_Page         : Page_Buffer;
      Slot_WAL          : WAL_Frame_Buffer;
      Slot_CRC          : Unsigned_32;
      pragma Warnings (Off, Slot_CRC);
      WAL_Ok            : Boolean;
      Notify_Ch         : constant Bounded_Ident      := Make_Ident ("rag.indexed");
   begin
      if not Old_Entry.Active and then Engine.Vector_Graph.Node_Count = Max_HNSW_Nodes then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      --  Reclaim tail TOAST pages from retired versions before allocating (R2-MED-03)
      Recompute_TOAST_High_Water_Mark
        (Engine        => Engine,
         Updating_Slot => (if Old_Entry.Active then Doc_Id else 0));

      --  Determine starting TOAST page for parent payload (reuse retired range if it fits)
      if Old_Entry.Active
        and then Retired_Doc_Ptr.Root_Overflow_Page in 10 .. Max_Safe_TOAST_Page
        and then Needed_Doc_Chunks <= Retired_Doc_Ptr.Chunk_Count
      then
         Start_Pg         := Retired_Doc_Ptr.Root_Overflow_Page;
         Reused_Doc_Place := True;
      elsif Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page - Needed_Doc_Chunks then
         Start_Pg := Engine.Next_TOAST_Pg;
      else
         Engine := Saved_Engine;
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      --  1a. Stage parent chunk into 4KB TOAST overflow chain in WAL (NO-STEAL)
      Write_TOAST_Chain
        (Ctx           => Ctx,
         DB_Path       => DB_Path,
         WAL_Path      => WAL_Path,
         Start_Page_Id => Start_Pg,
         Payload       => Parent_Payload,
         Length        => Parent_Length,
         Ptr           => Ptr,
         Status        => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Engine := Saved_Engine;
         Status := Sub_Stat;
         return;
      end if;

      if not Reused_Doc_Place
        and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page - Ptr.Chunk_Count
      then
         Engine.Next_TOAST_Pg := Engine.Next_TOAST_Pg + Ptr.Chunk_Count;
      end if;

      --  1b. Stage full Float32 Embedding into TOAST chain for Stage-2 Re-Ranking (Q-003, R2-HIGH-02)
      Encode_Vector_TOAST (Embedding, Vec_Payload, Vec_Byte_Len);
      Needed_Vec_Chunks := ((Vec_Byte_Len - 1) / TOAST_Chunk_Max_Bytes) + 1;

      if Old_Entry.Active
        and then Retired_Vec_Ptr.Root_Overflow_Page in 10 .. Max_Safe_TOAST_Page
        and then Needed_Vec_Chunks <= Retired_Vec_Ptr.Chunk_Count
      then
         Vec_Start_Pg     := Retired_Vec_Ptr.Root_Overflow_Page;
         Reused_Vec_Place := True;
      elsif Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page - Needed_Vec_Chunks then
         Vec_Start_Pg := Engine.Next_TOAST_Pg;
      else
         Engine := Saved_Engine;
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      Write_TOAST_Chain
        (Ctx           => Ctx,
         DB_Path       => DB_Path,
         WAL_Path      => WAL_Path,
         Start_Page_Id => Vec_Start_Pg,
         Payload       => Vec_Payload,
         Length        => Vec_Byte_Len,
         Ptr           => Vec_Ptr,
         Status        => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Engine := Saved_Engine;
         Status := Sub_Stat;
         return;
      end if;

      if not Reused_Vec_Place
        and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page - Vec_Ptr.Chunk_Count
      then
         Engine.Next_TOAST_Pg := Engine.Next_TOAST_Pg + Vec_Ptr.Chunk_Count;
      end if;

      --  2. Index primary key in multi-page B+Tree
      Insert_Key
        (Tree   => Engine.PK_Tree,
         Key    => Integer_64 (Doc_Id),
         Ptr    => (Target_Page => 1,
                    Target_Slot => Doc_Id,
                    TOAST_Root  => Ptr.Root_Overflow_Page),
         Status => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Engine := Saved_Engine;
         Status := Sub_Stat;
         return;
      end if;

      --  3. Index embedding in multi-layer quantized HNSW graph
      Insert_Vector
        (Index      => Engine.Vector_Graph,
         Doc_Id     => Doc_Id,
         Vec        => Embedding,
         TOAST_Root => Ptr.Root_Overflow_Page,
         Layer_Hint => Layer_Hint,
         Status     => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Engine := Saved_Engine;
         Status := Sub_Stat;
         return;
      end if;

      --  4. Store MVCC document entry, preserving committed prior version on update (R2-CRIT-01)
      if (not Old_Entry.Active or else Old_Entry.Tuple_Hdr.Xmax > 0)
        and then Engine.Doc_Count < Max_RAG_Docs
      then
         Engine.Doc_Count := Engine.Doc_Count + 1;
      end if;

      --  Keep transaction Tx_Active in CLOG until Commit_Tx succeeds (R2-CRIT-01)
      Set_CLOG_State (Engine.CLOG, Ctx.Id, Tx_Active);

      Engine.Docs (Doc_Id) := (
         Active              => True,
         Doc_Id              => Doc_Id,
         Tuple_Hdr           => (Xmin => Ctx.Id, Xmax => 0),
         Metadata            => Metadata,
         Summary_Text        => Summary_Text,
         Toast_Ptr           => Ptr,
         Vec_Toast_Ptr       => Vec_Ptr,
         Related_Doc_Id      => Related_Doc_Id,
         Has_Prior_Version   => Keep_Prior,
         Prior_Tuple_Hdr     => Retained_Hdr,
         Prior_Metadata      => Retained_Meta,
         Prior_Summary       => Retained_Sum,
         Prior_Toast_Ptr     => Retained_Toast,
         Prior_Vec_Toast_Ptr => Retained_Vec_P,
         Prior_Related_Id    => Retained_Rel
      );

      --  5. Stage primary 4096-byte Slotted_Page in WAL on Page_Id = 1 (NO-STEAL, R2-CRIT-01)
      Build_RAG_Slotted_Page (Engine, Ctx.Id, Slot_Page);
      Encode_WAL_Frame (Ctx.Id, 1, Slot_Page, Slot_CRC, Slot_WAL, WAL_Frame_Data);
      Append_WAL_Frame (WAL_Path, Slot_WAL, WAL_Ok);
      if not WAL_Ok then
         Engine := Saved_Engine;
         Status := Status_IO_Error;
         return;
      end if;

      --  6. Stage DURABLE notification (held until WAL Commit Barrier in Commit_Tx)
      Stage_Notify
        (Ctx     => Ctx,
         Staging => Staging,
         Channel => Notify_Ch,
         Payload => Summary_Text,
         Status  => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Engine := Saved_Engine;
         Status := Sub_Stat;
         return;
      end if;

      Status := Status_Ok;
   end Ingest_Document;

   -------------------------------------------------------------------------
   --  Insert_Hit_Sorted (Distance + Tie-Breaking Keyword Boost at Dist = 0.0)
   -------------------------------------------------------------------------

   function Is_Better_Hit (Candidate, Existing : RAG_Search_Hit) return Boolean is
     (Candidate.Distance < Existing.Distance
      or else (Candidate.Distance = Existing.Distance
               and then Candidate.Keyword_Match
               and then not Existing.Keyword_Match));

   procedure Insert_Hit_Sorted
     (Result : in out RAG_Query_Result;
      Max_K  : in     RAG_Hit_Index;
      Hit    : in     RAG_Search_Hit)
     with Pre  => Result.Count <= Max_K,
          Post => Result.Count <= Max_K
   is
      Pos : RAG_Hit_Index;
   begin
      --  Avoid duplicate Doc_Id in Result
      for I in 1 .. Result.Count loop
         if Result.Hits (I).Doc_Id = Hit.Doc_Id then
            return;
         end if;
      end loop;

      if Result.Count = Max_K
        and then not Is_Better_Hit (Hit, Result.Hits (Result.Count))
      then
         return;
      end if;

      if Result.Count < Max_K then
         Result.Count := Result.Count + 1;
      end if;

      Pos := Result.Count;
      for I in 1 .. Result.Count - 1 loop
         if Is_Better_Hit (Hit, Result.Hits (I)) then
            Pos := I;
            exit;
         end if;
      end loop;

      for I in reverse Pos .. Result.Count - 1 loop
         pragma Loop_Invariant (Result.Count <= Max_K);
         Result.Hits (I + 1) := Result.Hits (I);
      end loop;

      Result.Hits (Pos) := Hit;
   end Insert_Hit_Sorted;

   -------------------------------------------------------------------------
   --  Resolve_Visible_Doc (MVCC Snapshot + CLOG + Prior Version Chain, CRIT-04)
   -------------------------------------------------------------------------

   procedure Resolve_Visible_Doc
     (Entry_Rec : in     RAG_Document_Entry;
      Snapshot  : in     Valid_Tx_Id;
      CLOG      : in     Commit_Log;
      Visible   :    out Boolean;
      Meta      :    out JSONB_Document;
      Summary   :    out Bounded_Text;
      Toast_P   :    out TOAST_Pointer;
      Vec_P     :    out TOAST_Pointer;
      Rel_Id    :    out Optional_Doc_Id)
     with Global => null,
          Always_Terminates,
          Post   => True
   is
   begin
      Visible := False;
      Meta    := (others => <>);
      Summary := (Length => 0, Data => [others => ' ']);
      Toast_P := (others => <>);
      Vec_P   := (others => <>);
      Rel_Id  := 0;

      if not Entry_Rec.Active then
         return;
      end if;

      if Is_Tuple_Visible (Entry_Rec.Tuple_Hdr, Snapshot, CLOG) then
         Visible := True;
         Meta    := Entry_Rec.Metadata;
         Summary := Entry_Rec.Summary_Text;
         Toast_P := Entry_Rec.Toast_Ptr;
         Vec_P   := Entry_Rec.Vec_Toast_Ptr;
         Rel_Id  := Entry_Rec.Related_Doc_Id;
      elsif Entry_Rec.Has_Prior_Version
        and then Is_Tuple_Visible (Entry_Rec.Prior_Tuple_Hdr, Snapshot, CLOG)
      then
         Visible := True;
         Meta    := Entry_Rec.Prior_Metadata;
         Summary := Entry_Rec.Prior_Summary;
         Toast_P := Entry_Rec.Prior_Toast_Ptr;
         Vec_P   := Entry_Rec.Prior_Vec_Toast_Ptr;
         Rel_Id  := Entry_Rec.Prior_Related_Id;
      end if;
   end Resolve_Visible_Doc;

   -------------------------------------------------------------------------
   --  Execute_Hybrid_RAG_Query
   -------------------------------------------------------------------------

   procedure Evaluate_Doc_Candidate
     (Engine            : in     RAG_Engine;
      Snapshot          : in     Valid_Tx_Id;
      DB_Path           : in     Bounded_Text;
      Doc_Id            : in     RAG_Doc_Slot;
      Approx_Dist       : in     Non_Negative_Float;
      Query_Vec         : in     Vector_Value;
      Encoding          : in     Vector_Encoding_Kind;
      Use_Meta_Filter   : in     Boolean;
      Filter_Meta       : in     JSONB_Document;
      Use_Keyword_Boost : in     Boolean;
      Keyword           : in     Bounded_Text;
      Top_K             : in     RAG_Hit_Index;
      Result            : in out RAG_Query_Result)
     with Pre  => DB_Path.Length > 0
                  and then Query_Vec.Dim = Engine.Dim
                  and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                  and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                  and then Result.Count <= Top_K,
          Post => Result.Count <= Top_K
   is
      PK_Found      : Boolean;
      PK_Ptr        : BTree_Record_Pointer;
      pragma Warnings (Off, PK_Ptr);
      Vis           : Boolean;
      Doc_Meta      : JSONB_Document;
      Doc_Summary   : Bounded_Text;
      Doc_Toast     : TOAST_Pointer;
      Doc_Vec_Ptr   : TOAST_Pointer;
      Doc_Rel       : Optional_Doc_Id;
      Meta_Ok       : Boolean;
      Kw_Hit        : Boolean;
      Adj_Dist      : Non_Negative_Float := Approx_Dist;
      Vec_Buf       : TOAST_Payload_Buffer;
      Vec_Len       : TOAST_Payload_Length;
      Vec_Stat      : Engine_Status;
      Full_Vec      : Vector_Value;
      Vec_Valid     : Boolean;
      Expected_VLen : constant Valid_TOAST_Length :=
        Vector_TOAST_Byte_Length (Engine.Dim);
   begin
      --  Verify primary key existence in Engine.PK_Tree (HIGH-05)
      Search_Key (Engine.PK_Tree, Integer_64 (Doc_Id), PK_Found, PK_Ptr);
      if not PK_Found then
         return;
      end if;

      Resolve_Visible_Doc
        (Entry_Rec => Engine.Docs (Doc_Id),
         Snapshot  => Snapshot,
         CLOG      => Engine.CLOG,
         Visible   => Vis,
         Meta      => Doc_Meta,
         Summary   => Doc_Summary,
         Toast_P   => Doc_Toast,
         Vec_P     => Doc_Vec_Ptr,
         Rel_Id    => Doc_Rel);
      if not Vis then
         return;
      end if;

      if Use_Meta_Filter then
         Meta_Ok := Contains (Doc_Meta, Filter_Meta);
      else
         Meta_Ok := True;
      end if;
      if not Meta_Ok then
         return;
      end if;

      --  Stage-2 Exact Full-Vector Re-Ranking from the MVCC-resolved TOAST chain
      --  (Q-003, R2-CRIT-01, R2-HIGH-02)
      if Doc_Vec_Ptr.Total_Byte_Length = Expected_VLen
        and then Doc_Vec_Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks
      then
         Read_TOAST_Chain (DB_Path, Doc_Vec_Ptr, Vec_Buf, Vec_Len, Vec_Stat);
         if Vec_Stat = Status_Ok and then Vec_Len = Expected_VLen then
            Decode_Vector_TOAST (Vec_Buf, Vec_Len, Engine.Dim, Full_Vec, Vec_Valid);
            if Vec_Valid then
               case Encoding is
                  when Encoding_Float32 =>
                     Adj_Dist := L2_Distance (Query_Vec, Full_Vec);
                  when Encoding_Int8_SQ8 =>
                     Adj_Dist :=
                       Int8_L2_Distance
                         (Quantize_To_Int8 (Query_Vec),
                          Quantize_To_Int8 (Full_Vec));
                  when Encoding_Binary_1Bit =>
                     Adj_Dist :=
                       Non_Negative_Float
                         (Float
                            (Hamming_Distance
                               (Quantize_To_Binary (Query_Vec),
                                Quantize_To_Binary (Full_Vec))));
               end case;
            end if;
         end if;
      end if;

      Kw_Hit :=
        (if Use_Keyword_Boost then Contains_Keyword (Doc_Summary, Keyword)
         else False);

      if Use_Keyword_Boost and then Kw_Hit then
         Adj_Dist := Adj_Dist * 0.5;
      end if;

      Insert_Hit_Sorted
        (Result => Result,
         Max_K  => Top_K,
         Hit    => (Doc_Id         => Doc_Id,
                    Distance       => Adj_Dist,
                    Keyword_Match  => Kw_Hit,
                    Toast_Ptr      => Doc_Toast,
                    Summary_Text   => Doc_Summary,
                    Related_Doc_Id => Doc_Rel));
   end Evaluate_Doc_Candidate;

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
   is
      SQL_Desc    : Parsed_SQL_Descriptor;
      SQL_Stat    : Engine_Status;
      Effective_K : RAG_Hit_Index := Top_K;
      KNN_Res     : HNSW_Search_Result;
      Q_Int8      : constant Quantized_Int8_Vector   := Quantize_To_Int8 (Query_Vec);
      Q_Binary    : constant Quantized_Binary_Vector := Quantize_To_Binary (Query_Vec);
      Cand_Id     : Positive;
      Toast_Stat  : Engine_Status;
      Toast_Len   : TOAST_Payload_Length;
      Rel_Id      : Optional_Doc_Id;
      Rel_Vis     : Boolean;
      Rel_Meta    : JSONB_Document;
      Rel_Sum     : Bounded_Text;
      Rel_Toast   : TOAST_Pointer;
      Rel_Vec_P   : TOAST_Pointer;
      Rel_Next    : Optional_Doc_Id;
      pragma Warnings (Off, Rel_Meta);
      pragma Warnings (Off, Rel_Sum);
      pragma Warnings (Off, Rel_Toast);
      pragma Warnings (Off, Rel_Vec_P);
      pragma Warnings (Off, Rel_Next);
      Fallback_D  : Non_Negative_Float;
      Found_Node  : Boolean;
   begin
      Result           := (others => <>);
      Top_Parent_Chunk := [others => 0];

      --  1. Parse & validate PostgreSQL RAG SQL query
      Analyze_SQL (SQL_Query, SQL_Desc, SQL_Stat);
      if SQL_Stat /= Status_Ok or else SQL_Desc.Kind /= Stmt_Select then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Honor SQL LIMIT clause when present (R2-HIGH-04)
      if SQL_Desc.Has_Limit then
         if SQL_Desc.Limit_Value = 0 then
            Status := Status_Ok;
            return;
         elsif SQL_Desc.Limit_Value < Effective_K then
            Effective_K := RAG_Hit_Index (SQL_Desc.Limit_Value);
         end if;
      end if;

      --  2. Stage 1: HNSW ANN candidate retrieval in requested quantization mode
      Search_KNN
        (Index    => Engine.Vector_Graph,
         Query    => Query_Vec,
         Encoding => Encoding,
         K        => Max_KNN_Results,
         Results  => KNN_Res);

      --  3. Stage 2: Apply PK_Tree check, MVCC Snapshot + CLOG visibility,
      --     JSONB `@>` filter, Stage-2 TOAST Exact Re-Ranking, and Keyword Boost
      for I in 1 .. KNN_Res.Count loop
         pragma Loop_Invariant (Result.Count <= Effective_K);
         pragma Loop_Invariant (Effective_K <= Top_K);
         Cand_Id := KNN_Res.Items (I).Doc_Id;
         if Cand_Id <= Max_RAG_Docs then
            Evaluate_Doc_Candidate
              (Engine            => Engine,
               Snapshot          => Snapshot,
               DB_Path           => DB_Path,
               Doc_Id            => Cand_Id,
               Approx_Dist       => KNN_Res.Items (I).Distance,
               Query_Vec         => Query_Vec,
               Encoding          => Encoding,
               Use_Meta_Filter   => Use_Meta_Filter,
               Filter_Meta       => Filter_Meta,
               Use_Keyword_Boost => Use_Keyword_Boost,
               Keyword           => Keyword,
               Top_K             => Effective_K,
               Result            => Result);
         end if;
      end loop;

      --  If selective metadata or MVCC filtering yielded fewer than Effective_K hits,
      --  evaluate any remaining PK_Tree-indexed documents that exist in Vector_Graph (HIGH-05, R2-HIGH-04)
      if Result.Count < Effective_K then
         for Slot in RAG_Doc_Slot loop
            pragma Loop_Invariant (Result.Count <= Effective_K);
            pragma Loop_Invariant (Effective_K <= Top_K);
            if Engine.Docs (Slot).Active then
               Fallback_D := Float'Last;
               Found_Node := False;
               for N_Idx in 1 .. Engine.Vector_Graph.Node_Count loop
                  if Engine.Vector_Graph.Nodes (N_Idx).Active
                    and then Engine.Vector_Graph.Nodes (N_Idx).Doc_Id = Slot
                    and then Engine.Vector_Graph.Nodes (N_Idx).Bin_Vec.Dim = Query_Vec.Dim
                  then
                     Fallback_D :=
                       Node_Distance
                         (Engine.Vector_Graph.Nodes (N_Idx),
                          Query_Vec,
                          Q_Int8,
                          Q_Binary,
                          Encoding);
                     Found_Node := True;
                     exit;
                  end if;
               end loop;

               if Found_Node then
                  Evaluate_Doc_Candidate
                    (Engine            => Engine,
                     Snapshot          => Snapshot,
                     DB_Path           => DB_Path,
                     Doc_Id            => Slot,
                     Approx_Dist       => Fallback_D,
                     Query_Vec         => Query_Vec,
                     Encoding          => Encoding,
                     Use_Meta_Filter   => Use_Meta_Filter,
                     Filter_Meta       => Filter_Meta,
                     Use_Keyword_Boost => Use_Keyword_Boost,
                     Keyword           => Keyword,
                     Top_K             => Effective_K,
                     Result            => Result);
               end if;
            end if;
         end loop;
      end if;

      --  4. Stage 3: Fetch full Parent-Document Chunk from 4KB TOAST Overflow Pages
      --     and check 1-hop GraphRAG neighbor for the #1 ranked hit
      if Result.Count > 0
        and then Result.Hits (1).Toast_Ptr.Total_Byte_Length in 1 .. Max_TOAST_Payload_Bytes
        and then Result.Hits (1).Toast_Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks
      then
         Read_TOAST_Chain
           (DB_Path => DB_Path,
            Ptr     => Result.Hits (1).Toast_Ptr,
            Payload => Top_Parent_Chunk,
            Length  => Toast_Len,
            Status  => Toast_Stat);
         if Toast_Stat /= Status_Ok then
            Status := Toast_Stat;
            return;
         end if;
         Result.Top_Parent_Bytes := Toast_Len;

         Rel_Id := Result.Hits (1).Related_Doc_Id;
         if Rel_Id in RAG_Doc_Slot then
            Resolve_Visible_Doc
              (Entry_Rec => Engine.Docs (Rel_Id),
               Snapshot  => Snapshot,
               CLOG      => Engine.CLOG,
               Visible   => Rel_Vis,
               Meta      => Rel_Meta,
               Summary   => Rel_Sum,
               Toast_P   => Rel_Toast,
               Vec_P     => Rel_Vec_P,
               Rel_Id    => Rel_Next);
            if Rel_Vis then
               Result.Graph_Neighbor_Hit := True;
            end if;
         end if;
      end if;

      Status := Status_Ok;
   end Execute_Hybrid_RAG_Query;

end Nhe_O.RAG;
