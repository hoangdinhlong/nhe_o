pragma SPARK_Mode (On);

with Interfaces; use Interfaces;
with Nhe_O.SQL;  use Nhe_O.SQL;

package body Nhe_O.RAG is

   --  Library-level default document table: assigning it copies static data instead of
   --  building a document-table aggregate on the caller's stack
   Empty_Docs : constant RAG_Document_Table := [others => (others => <>)];

   procedure Init_RAG_Engine
     (Engine :    out RAG_Engine;
      Dim    : in     Vector_Dim)
   is
   begin
      Engine.Dim             := Dim;
      Engine.Doc_Count       := 0;
      Engine.Next_TOAST_Pg   := 10;
      Engine.CLOG            := Default_CLOG;
      Engine.Commit_Seqs     := [others => 0];
      Engine.Last_Commit_Seq := 0;
      Engine.Read_Horizon    := 0;
      Engine.Pages_Pending   := False;
      Engine.Docs            := Empty_Docs;
      Init_BTree (Engine.PK_Tree);
      Init_HNSW (Engine.Vector_Graph, Dim);
   end Init_RAG_Engine;

   --  Simple case folding for the Latin code points used by Vietnamese and the other
   --  Latin-script languages: ASCII, Latin-1 Supplement, Latin Extended-A, the
   --  Vietnamese horn letters of Latin Extended-B (U+01A0/U+01A1 and U+01AF/U+01B0) and
   --  Latin Extended Additional. Every other code point maps to itself.
   function Fold_Latin (Code : Natural) return Natural is
     (if Code in 16#41# .. 16#5A# then Code + 32
      elsif Code in 16#C0# .. 16#DE# and then Code /= 16#D7# then Code + 32
      elsif Code = 16#178# then 16#FF#
      elsif Code = 16#17F# then 16#73#
      elsif Code = 16#1A0# or else Code = 16#1AF# then Code + 1
      elsif (Code in 16#100# .. 16#12F# or else Code in 16#132# .. 16#137#
             or else Code in 16#14A# .. 16#177#)
        and then Code mod 2 = 0
      then Code + 1
      elsif (Code in 16#139# .. 16#148# or else Code in 16#179# .. 16#17E#)
        and then Code mod 2 = 1
      then Code + 1
      elsif (Code in 16#1E00# .. 16#1E95# or else Code in 16#1EA0# .. 16#1EFF#)
        and then Code mod 2 = 0
      then Code + 1
      elsif Code = 16#1E9B# then 16#1E61#
      elsif Code = 16#1E9E# then 16#DF#
      else Code)
     with Pre => Code <= 16#10FFFF#;

   --  Decode the UTF-8 sequence starting at Pos of S and case-fold it. Malformed bytes
   --  (including overlong forms and encoded surrogates) and 4-byte sequences are
   --  compared byte-wise through codes above 16#10FFFF#.
   procedure Decode_Folded
     (S    : in     Bounded_Text;
      Pos  : in     Text_Index;
      Code :    out Natural;
      Len  :    out Positive)
     with Global => null,
          Always_Terminates,
          Pre    => Pos <= S.Length,
          Post   => Len in 1 .. 3 and then Pos + Len - 1 <= S.Length
   is
      B0 : constant Natural := Character'Pos (S.Data (Pos));
      B1 : Natural;
      B2 : Natural;
   begin
      if B0 < 16#80# then
         Code := Fold_Latin (B0);
         Len  := 1;
         return;
      elsif B0 in 16#C2# .. 16#DF# and then Pos < S.Length then
         B1 := Character'Pos (S.Data (Pos + 1));
         if B1 in 16#80# .. 16#BF# then
            Code := Fold_Latin ((B0 - 16#C0#) * 64 + (B1 - 16#80#));
            Len  := 2;
            return;
         end if;
      elsif B0 in 16#E0# .. 16#EF# and then Pos + 1 < S.Length then
         B1 := Character'Pos (S.Data (Pos + 1));
         B2 := Character'Pos (S.Data (Pos + 2));
         --  E0 needs A0 .. BF (no overlong form), ED needs 80 .. 9F (no surrogate)
         if B1 in (if B0 = 16#E0# then 16#A0# else 16#80#)
                  .. (if B0 = 16#ED# then 16#9F# else 16#BF#)
           and then B2 in 16#80# .. 16#BF#
         then
            Code := Fold_Latin ((B0 - 16#E0#) * 4096 + (B1 - 16#80#) * 64 + (B2 - 16#80#));
            Len  := 3;
            return;
         end if;
      end if;
      Code := 16#110000# + B0;
      Len  := 1;
   end Decode_Folded;

   function Contains_Keyword
     (Text    : Bounded_Text;
      Keyword : Bounded_Text) return Boolean
   is
      Match  : Boolean;
      T_Pos  : Positive;
      K_Pos  : Positive;
      T_Code : Natural;
      K_Code : Natural;
      T_Len  : Positive;
      K_Len  : Positive;
   begin
      --  Empty keyword never matches a lexical boost
      if Keyword.Length = 0 or else Text.Length = 0 then
         return False;
      end if;

      for Start_Pos in 1 .. Text.Length loop
         Match := True;
         T_Pos := Start_Pos;
         K_Pos := 1;
         --  Every step consumes at least one keyword byte, so Keyword.Length steps suffice
         for Step in 1 .. Keyword.Length loop
            pragma Loop_Invariant
              (K_Pos in Step .. Keyword.Length + 1
               and then T_Pos in Start_Pos .. Text.Length + 1);
            exit when K_Pos > Keyword.Length;
            if T_Pos > Text.Length then
               Match := False;
               exit;
            end if;
            Decode_Folded (Text, T_Pos, T_Code, T_Len);
            Decode_Folded (Keyword, K_Pos, K_Code, K_Len);
            if T_Code /= K_Code then
               Match := False;
               exit;
            end if;
            T_Pos := T_Pos + T_Len;
            K_Pos := K_Pos + K_Len;
         end loop;
         if Match and then K_Pos > Keyword.Length then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Keyword;

   procedure Mark_Committed
     (Engine : in out RAG_Engine;
      Tx     : in     Valid_Tx_Id)
   is
   begin
      Set_CLOG_State (Engine.CLOG, Tx, Tx_Committed);
      if Engine.Last_Commit_Seq < Commit_Seq_Number'Last then
         Engine.Last_Commit_Seq := Engine.Last_Commit_Seq + 1;
      end if;
      Engine.Commit_Seqs (Tx) := Engine.Last_Commit_Seq;
   end Mark_Committed;

   procedure Capture_Doc_HNSW_Node
     (Graph  : in     HNSW_Index;
      Doc_Id : in     RAG_Doc_Slot;
      Snap   :    out HNSW_Node)
     with Global => null
   is
   begin
      Snap := (others => <>);
      for I in 1 .. Graph.Node_Count loop
         if Graph.Nodes (I).Active and then Graph.Nodes (I).Doc_Id = Doc_Id then
            Snap := Graph.Nodes (I);
            return;
         end if;
      end loop;
   end Capture_Doc_HNSW_Node;

   --  Mark the live version of Doc_Id deleted by Tx and drop Doc_Id from PK_Tree and
   --  Vector_Graph. When that version is Tx's own and replaced a prior version, the slot
   --  reverts to the prior version, deleted by Tx (or still by its committed deleter):
   --  keeping Tx's version, which no snapshot can see, would push the prior version out
   --  of the single prior-version slot at the next update.
   procedure Apply_Delete
     (Engine : in out RAG_Engine;
      Tx     : in     Valid_Tx_Id;
      Doc_Id : in     RAG_Doc_Slot)
     with Global => null,
          Always_Terminates,
          Pre    => Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post   => Engine.Dim = Engine.Dim'Old
                    and then Engine.Vector_Graph.Dim = Engine.Dim
                    and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                    and then Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Old
                    and then Engine.CLOG (Tx) = Tx_Active
   is
      Prior_Hdr : constant MVCC_Tuple_Header := Engine.Docs (Doc_Id).Prior_Tuple_Hdr;
      Removed   : Boolean;
      HNSW_Snap : HNSW_Node;
      pragma Warnings (Off, Removed);
   begin
      if Engine.Docs (Doc_Id).Tuple_Hdr.Xmin = Tx
        and then Engine.Docs (Doc_Id).Has_Prior_Version
      then
         Engine.Docs (Doc_Id).Tuple_Hdr :=
           (Xmin => Prior_Hdr.Xmin,
            Xmax => (if Prior_Hdr.Xmax = 0 then Tx else Prior_Hdr.Xmax));
         Engine.Docs (Doc_Id).Metadata             := Engine.Docs (Doc_Id).Prior_Metadata;
         Engine.Docs (Doc_Id).Summary_Text         := Engine.Docs (Doc_Id).Prior_Summary;
         Engine.Docs (Doc_Id).Toast_Ptr            := Engine.Docs (Doc_Id).Prior_Toast_Ptr;
         Engine.Docs (Doc_Id).Vec_Toast_Ptr        := Engine.Docs (Doc_Id).Prior_Vec_Toast_Ptr;
         Engine.Docs (Doc_Id).Meta_Toast_Ptr       := Engine.Docs (Doc_Id).Prior_Meta_Toast_Ptr;
         Engine.Docs (Doc_Id).Related_Doc_Id       := Engine.Docs (Doc_Id).Prior_Related_Id;
         Engine.Docs (Doc_Id).Cur_HNSW_Node        := Engine.Docs (Doc_Id).Prior_HNSW_Node;
         Engine.Docs (Doc_Id).Has_Prior_Version    := False;
         Engine.Docs (Doc_Id).Prior_Tuple_Hdr      := (Xmin => 1, Xmax => 0);
         Engine.Docs (Doc_Id).Prior_Metadata       := (others => <>);
         Engine.Docs (Doc_Id).Prior_Summary        := (Length => 0, Data => [others => ' ']);
         Engine.Docs (Doc_Id).Prior_Toast_Ptr      := (others => <>);
         Engine.Docs (Doc_Id).Prior_Vec_Toast_Ptr  := (others => <>);
         Engine.Docs (Doc_Id).Prior_Meta_Toast_Ptr := (others => <>);
         Engine.Docs (Doc_Id).Prior_Related_Id     := 0;
         Engine.Docs (Doc_Id).Prior_HNSW_Node      := (others => <>);
      else
         Capture_Doc_HNSW_Node (Engine.Vector_Graph, Doc_Id, HNSW_Snap);
         if HNSW_Snap.Active then
            Engine.Docs (Doc_Id).Cur_HNSW_Node := HNSW_Snap;
         end if;
         Engine.Docs (Doc_Id).Tuple_Hdr.Xmax := Tx;
      end if;

      Set_CLOG_State (Engine.CLOG, Tx, Tx_Active);
      if Engine.Doc_Count > 0 then
         Engine.Doc_Count := Engine.Doc_Count - 1;
      end if;

      --  Synchronize PK_Tree and Vector_Graph on delete
      Delete_Key (Engine.PK_Tree, Integer_64 (Doc_Id), Removed);
      Remove_Vector (Engine.Vector_Graph, Doc_Id);
   end Apply_Delete;

   procedure Delete_Document
     (Engine   : in out RAG_Engine;
      Ctx      : in     Transaction_Context;
      Snapshot : in     Commit_Seq_Number;
      Doc_Id   : in     RAG_Doc_Slot;
      Status   :    out Engine_Status)
   is
   begin
      if Has_Write_Conflict (Engine, Doc_Id, Ctx.Id, Snapshot)
        or else Snapshot > Engine.Last_Commit_Seq
        or else Engine.CLOG (Ctx.Id) in Tx_Aborted | Tx_Committed
      then
         Status := Status_Tx_Aborted;
         return;
      end if;

      if not Engine.Docs (Doc_Id).Active
        or else Engine.Docs (Doc_Id).Tuple_Hdr.Xmax > 0
      then
         Status := Status_Not_Found;
         return;
      end if;

      Apply_Delete (Engine, Ctx.Id, Doc_Id);
      Status := Status_Ok;
   end Delete_Document;

   -------------------------------------------------------------------------
   --  Lossless Extended Summary + JSONB Metadata TOAST ("RMET")
   -------------------------------------------------------------------------

   RMET_Magic_0 : constant Byte := 16#52#; --  'R'
   RMET_Magic_1 : constant Byte := 16#4D#; --  'M'
   RMET_Magic_2 : constant Byte := 16#45#; --  'E'
   RMET_Magic_3 : constant Byte := 16#54#; --  'T'

   Max_Inline_Summary_Bytes : constant := 63;

   function Needs_Meta_TOAST
     (Summary : Bounded_Text;
      Meta    : JSONB_Document) return Boolean
     with Global => null
   is
      Cur_Off : Positive := 98;
      Key_Len : Natural;
      Val_Len : Natural;
   begin
      if Summary.Length > Max_Inline_Summary_Bytes then
         return True;
      end if;

      for F_Idx in 1 .. Meta.Count loop
         pragma Loop_Invariant (Cur_Off in 98 .. Max_Inline_Tuple_Bytes + 1);
         if Meta.Fields (F_Idx).Active then
            Key_Len := Meta.Fields (F_Idx).Key.Length;
            Val_Len := Meta.Fields (F_Idx).Val.Length;
            if Key_Len = 0
              or else Val_Len > 108
              or else Cur_Off + 2 + Key_Len + Val_Len > Max_Inline_Tuple_Bytes
            then
               return True;
            end if;
            Cur_Off := Cur_Off + 3 + Key_Len + Val_Len;
         end if;
      end loop;

      return False;
   end Needs_Meta_TOAST;

   procedure Encode_Meta_TOAST
     (Summary : in     Bounded_Text;
      Meta    : in     JSONB_Document;
      Payload :    out TOAST_Payload_Buffer;
      Length  :    out Valid_TOAST_Length)
     with Global => null
   is
      Sum_Len      : constant Natural := Summary.Length;
      Active_Count : Natural          := 0;
      Pos          : Positive         := 7 + Sum_Len;
      K_Len        : Natural;
      V_Len        : Natural;
   begin
      Payload     := [others => 0];
      Payload (1) := RMET_Magic_0;
      Payload (2) := RMET_Magic_1;
      Payload (3) := RMET_Magic_2;
      Payload (4) := RMET_Magic_3;
      Payload (5) := Byte ((Sum_Len / 256) mod 256);
      Payload (6) := Byte (Sum_Len mod 256);

      for I in 1 .. Sum_Len loop
         Payload (6 + I) := Byte (Character'Pos (Summary.Data (I)));
      end loop;

      --  Byte at Pos reserves Active_Count
      Pos := Pos + 1;

      for F_Idx in 1 .. Meta.Count loop
         pragma Loop_Invariant (Active_Count < F_Idx);
         pragma Loop_Invariant (Pos in 8 + Sum_Len .. 8 + Sum_Len + (F_Idx - 1) * 580);
         if Meta.Fields (F_Idx).Active and then Meta.Fields (F_Idx).Key.Length > 0 then
            K_Len := Meta.Fields (F_Idx).Key.Length;
            V_Len := Meta.Fields (F_Idx).Val.Length;

            Payload (Pos)     := Byte (K_Len);
            Payload (Pos + 1) := Byte ((V_Len / 256) mod 256);
            Payload (Pos + 2) := Byte (V_Len mod 256);
            Payload (Pos + 3) :=
              Byte (JSONB_Value_Kind'Pos (Meta.Fields (F_Idx).Kind));

            for I in 1 .. K_Len loop
               Payload (Pos + 3 + I) :=
                 Byte (Character'Pos (Meta.Fields (F_Idx).Key.Data (I)));
            end loop;

            for I in 1 .. V_Len loop
               Payload (Pos + 3 + K_Len + I) :=
                 Byte (Character'Pos (Meta.Fields (F_Idx).Val.Data (I)));
            end loop;

            Pos          := Pos + 4 + K_Len + V_Len;
            Active_Count := Active_Count + 1;
         end if;
      end loop;

      Payload (7 + Sum_Len) := Byte (Active_Count);
      Length                := Pos - 1;
   end Encode_Meta_TOAST;

   procedure Decode_Meta_TOAST
     (Payload : in     TOAST_Payload_Buffer;
      Length  : in     Valid_TOAST_Length;
      Summary :    out Bounded_Text;
      Meta    :    out JSONB_Document;
      Valid   :    out Boolean)
     with Global => null
   is
      Sum_Len      : Natural;
      Active_Count : Natural;
      Pos          : Positive;
      K_Len        : Natural;
      V_Len        : Natural;
      Kind_Raw     : Natural;
      Meta_Key     : Bounded_Ident;
      Meta_Val     : Bounded_Text;
      Meta_Kind    : JSONB_Value_Kind;
      Sub_Stat     : Engine_Status;
   begin
      Summary := (Length => 0, Data => [others => ' ']);
      Meta    := (others => <>);
      Valid   := False;

      if Length < 7
        or else Payload (1) /= RMET_Magic_0
        or else Payload (2) /= RMET_Magic_1
        or else Payload (3) /= RMET_Magic_2
        or else Payload (4) /= RMET_Magic_3
      then
         return;
      end if;

      Sum_Len := Natural (Payload (5)) * 256 + Natural (Payload (6));
      if Sum_Len > Max_Text_Len or else 7 + Sum_Len > Length then
         return;
      end if;

      Summary.Length := Sum_Len;
      for I in 1 .. Sum_Len loop
         Summary.Data (I) := Character'Val (Natural (Payload (6 + I)));
      end loop;

      Active_Count := Natural (Payload (7 + Sum_Len));
      if Active_Count > Max_JSON_Fields then
         Summary := (Length => 0, Data => [others => ' ']);
         return;
      end if;

      Pos := 8 + Sum_Len;
      for F_Idx in 1 .. Active_Count loop
         pragma Loop_Invariant (Pos in 8 .. Max_TOAST_Payload_Bytes + 1);
         if Pos + 3 > Length then
            Summary := (Length => 0, Data => [others => ' ']);
            Meta    := (others => <>);
            return;
         end if;

         K_Len    := Natural (Payload (Pos));
         V_Len    := Natural (Payload (Pos + 1)) * 256 + Natural (Payload (Pos + 2));
         Kind_Raw := Natural (Payload (Pos + 3));

         if K_Len not in 1 .. Max_Ident_Len
           or else V_Len > Max_Text_Len
           or else Kind_Raw > JSONB_Value_Kind'Pos (JSONB_Array)
           or else Pos + 3 + K_Len + V_Len > Length
         then
            Summary := (Length => 0, Data => [others => ' ']);
            Meta    := (others => <>);
            return;
         end if;

         Meta_Key  := (Length => K_Len, Data => [others => ' ']);
         Meta_Val  := (Length => V_Len, Data => [others => ' ']);
         Meta_Kind := JSONB_Value_Kind'Val (Kind_Raw);

         for I in 1 .. K_Len loop
            Meta_Key.Data (I) := Character'Val (Natural (Payload (Pos + 3 + I)));
         end loop;
         for I in 1 .. V_Len loop
            Meta_Val.Data (I) :=
              Character'Val (Natural (Payload (Pos + 3 + K_Len + I)));
         end loop;

         Put_Field (Meta, Meta_Key, Meta_Val, Meta_Kind, Sub_Stat);
         if Sub_Stat /= Status_Ok then
            Summary := (Length => 0, Data => [others => ' ']);
            Meta    := (others => <>);
            return;
         end if;
         Pos := Pos + 4 + K_Len + V_Len;
      end loop;

      if Pos - 1 /= Length then
         Summary := (Length => 0, Data => [others => ' ']);
         Meta    := (others => <>);
         return;
      end if;

      Valid := True;
   end Decode_Meta_TOAST;

   -------------------------------------------------------------------------
   --  Build_RAG_Slotted_Page & Recover_RAG_Engine
   -------------------------------------------------------------------------

   --  Pack one document version into a "SLOT" tuple (inline layout of section 2.1 of
   --  docs/domain/storage-and-wal-format.md)
   procedure Pack_RAG_Tuple
     (Doc_Id    : in     RAG_Doc_Slot;
      Hdr       : in     MVCC_Tuple_Header;
      Meta      : in     JSONB_Document;
      Summary   : in     Bounded_Text;
      Toast_P   : in     TOAST_Pointer;
      Vec_P     : in     TOAST_Pointer;
      Meta_P    : in     TOAST_Pointer;
      Rel_Id    : in     Optional_Doc_Id;
      Tuple_Rec :    out Slotted_Tuple)
     with Global => null,
          Always_Terminates,
          Post   => Tuple_Rec.Occupied
                    and then Tuple_Rec.Row_Id = Doc_Id
                    and then Tuple_Rec.Tuple_Hdr = Hdr
   is
      Vec_B         : TOAST_Pointer_Bytes;
      Meta_B        : TOAST_Pointer_Bytes;
      Sum_Len       : Natural;
      Key_Len       : Natural;
      Val_Len       : Natural;
      Cur_Off       : Positive;
      Stored_Fields : Natural;
      Inl_Data      : Inline_Tuple_Buffer := [others => 0];
   begin
      Encode_TOAST_Pointer (Vec_P, Vec_B);
      for B in TOAST_Pointer_Index loop
         Inl_Data (B) := Vec_B (B);
      end loop;

      --  Bytes 17..80: Summary_Text inline fast-path (1B length <= 63 + up to 63B payload)
      Sum_Len := Natural'Min (Max_Inline_Summary_Bytes, Summary.Length);
      Inl_Data (17) := Byte (Sum_Len);
      for I in 1 .. Sum_Len loop
         Inl_Data (17 + I) := Byte (Character'Pos (Summary.Data (I)));
      end loop;

      --  Bytes 81..96: Meta_Toast_Ptr for lossless 512B Summary + 16-field JSONB
      Encode_TOAST_Pointer (Meta_P, Meta_B);
      for B in TOAST_Pointer_Index loop
         Inl_Data (80 + B) := Meta_B (B);
      end loop;

      --  Bytes 97..208: Multi-field JSONB Metadata inline fast-path
      --  Byte 97 = Stored_Fields count; Bytes 98..208 = packed entries
      --  (Key_Len: 1B <= 64, Val_Len: 1B <= 108, Kind: 1B, Key_Bytes, Val_Bytes)
      Stored_Fields := 0;
      Cur_Off       := 98;
      for F_Idx in 1 .. Meta.Count loop
         pragma Loop_Invariant (Stored_Fields < F_Idx);
         pragma Loop_Invariant (Cur_Off in 98 .. Max_Inline_Tuple_Bytes + 1);
         if Meta.Fields (F_Idx).Active then
            Key_Len := Meta.Fields (F_Idx).Key.Length;
            Val_Len := Meta.Fields (F_Idx).Val.Length;
            if Key_Len > 0
              and then Val_Len <= 108
              and then Cur_Off + 2 + Key_Len + Val_Len <= Max_Inline_Tuple_Bytes
            then
               Inl_Data (Cur_Off)     := Byte (Key_Len);
               Inl_Data (Cur_Off + 1) := Byte (Val_Len);
               Inl_Data (Cur_Off + 2) :=
                 Byte (JSONB_Value_Kind'Pos (Meta.Fields (F_Idx).Kind));
               for I in 1 .. Key_Len loop
                  Inl_Data (Cur_Off + 2 + I) :=
                    Byte (Character'Pos (Meta.Fields (F_Idx).Key.Data (I)));
               end loop;
               for I in 1 .. Val_Len loop
                  Inl_Data (Cur_Off + 2 + Key_Len + I) :=
                    Byte (Character'Pos (Meta.Fields (F_Idx).Val.Data (I)));
               end loop;
               Cur_Off       := Cur_Off + 3 + Key_Len + Val_Len;
               Stored_Fields := Stored_Fields + 1;
            end if;
         end if;
      end loop;
      Inl_Data (97) := Byte (Stored_Fields);

      Tuple_Rec := (
         Occupied    => True,
         Row_Id      => Doc_Id,
         Tuple_Hdr   => Hdr,
         Toast_Ptr   => Toast_P,
         Related_Id  => Rel_Id,
         Inline_Len  => Max_Inline_Tuple_Bytes,
         Inline_Data => Inl_Data
      );
   end Pack_RAG_Tuple;

   procedure Build_RAG_Slotted_Page
     (Engine   : in     RAG_Engine;
      LSN_Tx   : in     Valid_Tx_Id;
      Raw_Page :    out Page_Buffer)
   is
      Page_Rec : Slotted_Page;

      --  A version or deletion may be persisted iff it is committed or belongs to the
      --  committing transaction itself
      function Persistable (Tx : Tx_Id) return Boolean is
        (Tx = LSN_Tx or else Is_Tx_Committed (Engine.CLOG, Tx));

      --  Never persist another active transaction's uncommitted deletion
      function Persisted_Hdr (Hdr : MVCC_Tuple_Header) return MVCC_Tuple_Header is
        (Xmin => Hdr.Xmin,
         Xmax => (if Hdr.Xmax = 0 or else Persistable (Hdr.Xmax) then Hdr.Xmax else 0));
   begin
      Page_Rec.Page_Id     := 1;
      Page_Rec.Page_LSN_Tx := LSN_Tx;

      for Slot in RAG_Doc_Slot loop
         Page_Rec.Tuples (Slot) := (others => <>);
         if Engine.Docs (Slot).Active then
            if Persistable (Engine.Docs (Slot).Tuple_Hdr.Xmin) then
               Pack_RAG_Tuple
                 (Doc_Id    => Slot,
                  Hdr       => Persisted_Hdr (Engine.Docs (Slot).Tuple_Hdr),
                  Meta      => Engine.Docs (Slot).Metadata,
                  Summary   => Engine.Docs (Slot).Summary_Text,
                  Toast_P   => Engine.Docs (Slot).Toast_Ptr,
                  Vec_P     => Engine.Docs (Slot).Vec_Toast_Ptr,
                  Meta_P    => Engine.Docs (Slot).Meta_Toast_Ptr,
                  Rel_Id    => Engine.Docs (Slot).Related_Doc_Id,
                  Tuple_Rec => Page_Rec.Tuples (Slot));
            elsif Engine.Docs (Slot).Has_Prior_Version
              and then Persistable (Engine.Docs (Slot).Prior_Tuple_Hdr.Xmin)
            then
               --  The current version is another transaction's uncommitted work:
               --  persist the committed version it replaced
               Pack_RAG_Tuple
                 (Doc_Id    => Slot,
                  Hdr       => Persisted_Hdr (Engine.Docs (Slot).Prior_Tuple_Hdr),
                  Meta      => Engine.Docs (Slot).Prior_Metadata,
                  Summary   => Engine.Docs (Slot).Prior_Summary,
                  Toast_P   => Engine.Docs (Slot).Prior_Toast_Ptr,
                  Vec_P     => Engine.Docs (Slot).Prior_Vec_Toast_Ptr,
                  Meta_P    => Engine.Docs (Slot).Prior_Meta_Toast_Ptr,
                  Rel_Id    => Engine.Docs (Slot).Prior_Related_Id,
                  Tuple_Rec => Page_Rec.Tuples (Slot));
            end if;
         end if;
      end loop;

      --  Encode_Slotted_Page derives Slot_Count from the occupied tuples
      Encode_Slotted_Page (Page_Rec, Raw_Page);
   end Build_RAG_Slotted_Page;

   procedure Delete_Document
     (Engine   : in out RAG_Engine;
      Ctx      : in     Transaction_Context;
      Snapshot : in     Commit_Seq_Number;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Doc_Id   : in     RAG_Doc_Slot;
      Status   :    out Engine_Status)
   is
      Old_Entry       : constant RAG_Document_Entry := Engine.Docs (Doc_Id);
      Saved_Doc_Count : constant RAG_Doc_Count      := Engine.Doc_Count;
      Saved_Tx_State  : constant Tx_State           := Engine.CLOG (Ctx.Id);
      Saved_PK_Tree   : constant BTree_Index        := Engine.PK_Tree;
      Saved_Graph     : constant HNSW_Index         := Engine.Vector_Graph;
      Slot_Page       : Page_Buffer;
      Slot_WAL        : WAL_Frame_Buffer;
      Slot_CRC        : Unsigned_32;
      pragma Warnings (Off, Slot_CRC);
      WAL_Ok          : Boolean;
   begin
      if Has_Write_Conflict (Engine, Doc_Id, Ctx.Id, Snapshot)
        or else Snapshot > Engine.Last_Commit_Seq
        or else Engine.CLOG (Ctx.Id) in Tx_Aborted | Tx_Committed
      then
         Status := Status_Tx_Aborted;
         return;
      end if;

      if Equal_Text (DB_Path, WAL_Path) then
         Status := Status_IO_Error;
         return;
      end if;

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

      Apply_Delete (Engine, Ctx.Id, Doc_Id);

      --  Stage updated Slotted_Page in WAL (NO-STEAL; Commit_Tx flushes to DB_Path).
      --  After a failed append only memory is restored: a Page 1 frame the append could
      --  not roll back is superseded by Ctx's commit page and never replayed alone.
      Build_RAG_Slotted_Page (Engine, Ctx.Id, Slot_Page);
      Encode_WAL_Frame (Ctx.Id, 1, Slot_Page, Slot_CRC, Slot_WAL, WAL_Frame_Data);
      Append_WAL_Frame (WAL_Path, Slot_WAL, WAL_Ok);
      if not WAL_Ok then
         Engine.Docs (Doc_Id)          := Old_Entry;
         Engine.Doc_Count              := Saved_Doc_Count;
         Engine.PK_Tree                := Saved_PK_Tree;
         Engine.Vector_Graph           := Saved_Graph;
         Engine.CLOG (Ctx.Id)          := Saved_Tx_State;
         Status := Status_IO_Error;
         return;
      end if;

      Status := Status_Ok;
   end Delete_Document;

   -------------------------------------------------------------------------
   --  Recompute_TOAST_High_Water_Mark & Rollback_RAG_Tx
   -------------------------------------------------------------------------

   --  End page (exclusive) of the chain P, 0 for an empty pointer
   function Chain_End (P : TOAST_Pointer) return Natural is
     (if P.Chunk_Count > 0 then P.Root_Overflow_Page + P.Chunk_Count else 0);

   --  The pages Staged_Tx staged for Engine.Docs (S) are still reserved
   function Has_Reserved_Staging (Engine : RAG_Engine; S : RAG_Doc_Slot) return Boolean is
     (Engine.Docs (S).Staged_Tx /= 0
      and then Engine.CLOG (Engine.Docs (S).Staged_Tx) = Tx_Active
      and then Engine.Docs (S).Staged_End > Engine.Docs (S).Staged_First);

   --  Next_TOAST_Pg := one past the highest page of any live or prior chain and of any
   --  page range staged by a transaction that is still active (run after an ingest, a
   --  rollback, a freeze and a recovery; a commit keeps the value, an upper bound)
   procedure Recompute_TOAST_High_Water_Mark
     (Engine : in out RAG_Engine)
     with Pre  => Engine.Vector_Graph.Dim = Engine.Dim
                  and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                  and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count,
          Post => Engine = (Engine'Old with delta Next_TOAST_Pg => Engine.Next_TOAST_Pg)
                  and then Engine.Next_TOAST_Pg in 10 .. Max_Safe_TOAST_Page
   is
      HWM : Valid_Page_Id := 10;

      procedure Include (End_Page : Natural)
        with Pre  => HWM in 10 .. Max_Safe_TOAST_Page,
             Post => HWM in 10 .. Max_Safe_TOAST_Page
      is
      begin
         if End_Page > HWM and then End_Page <= Max_Safe_TOAST_Page then
            HWM := End_Page;
         end if;
      end Include;
   begin
      for S in RAG_Doc_Slot loop
         pragma Loop_Invariant (HWM in 10 .. Max_Safe_TOAST_Page);
         if Engine.Docs (S).Active then
            Include (Chain_End (Engine.Docs (S).Toast_Ptr));
            Include (Chain_End (Engine.Docs (S).Vec_Toast_Ptr));
            Include (Chain_End (Engine.Docs (S).Meta_Toast_Ptr));
            if Engine.Docs (S).Has_Prior_Version then
               Include (Chain_End (Engine.Docs (S).Prior_Toast_Ptr));
               Include (Chain_End (Engine.Docs (S).Prior_Vec_Toast_Ptr));
               Include (Chain_End (Engine.Docs (S).Prior_Meta_Toast_Ptr));
            end if;
         end if;
         if Has_Reserved_Staging (Engine, S) then
            Include (Engine.Docs (S).Staged_End);
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
         pragma Loop_Invariant (Engine.CLOG (Tx_Num) = Tx_Aborted);
         pragma Loop_Invariant (Engine.Next_TOAST_Pg = Engine.Next_TOAST_Pg'Loop_Entry);

         if Engine.Docs (Slot).Active then
            if Engine.Docs (Slot).Tuple_Hdr.Xmin = Tx_Num then
               if Engine.Docs (Slot).Has_Prior_Version then
                  Prior_Was_Deleted :=
                    Engine.Docs (Slot).Prior_Tuple_Hdr.Xmax > 0
                    and then Engine.Docs (Slot).Prior_Tuple_Hdr.Xmax /= Tx_Num;

                  Engine.Docs (Slot) := (
                     Active               => True,
                     Doc_Id               => Slot,
                     Tuple_Hdr            =>
                       (Xmin => Engine.Docs (Slot).Prior_Tuple_Hdr.Xmin,
                        Xmax => (if Prior_Was_Deleted
                                 then Engine.Docs (Slot).Prior_Tuple_Hdr.Xmax
                                 else 0)),
                     Metadata             => Engine.Docs (Slot).Prior_Metadata,
                     Summary_Text         => Engine.Docs (Slot).Prior_Summary,
                     Toast_Ptr            => Engine.Docs (Slot).Prior_Toast_Ptr,
                     Vec_Toast_Ptr        => Engine.Docs (Slot).Prior_Vec_Toast_Ptr,
                     Meta_Toast_Ptr       => Engine.Docs (Slot).Prior_Meta_Toast_Ptr,
                     Related_Doc_Id       => Engine.Docs (Slot).Prior_Related_Id,
                     Cur_HNSW_Node        => Engine.Docs (Slot).Prior_HNSW_Node,
                     Has_Prior_Version    => False,
                     Prior_Tuple_Hdr      => (Xmin => 1, Xmax => 0),
                     Prior_Metadata       => (others => <>),
                     Prior_Summary        => (Length => 0, Data => [others => ' ']),
                     Prior_Toast_Ptr      => (others => <>),
                     Prior_Vec_Toast_Ptr  => (others => <>),
                     Prior_Meta_Toast_Ptr => (others => <>),
                     Prior_Related_Id     => 0,
                     Prior_HNSW_Node      => (others => <>),
                     Staged_Tx            => 0,
                     Staged_First         => 10,
                     Staged_End           => 10
                  );

                  if Prior_Was_Deleted then
                     Delete_Key (Engine.PK_Tree, Integer_64 (Slot), Removed);
                     Remove_Vector (Engine.Vector_Graph, Slot);
                  else
                     Insert_Key
                       (Tree   => Engine.PK_Tree,
                        Key    => Integer_64 (Slot),
                        Ptr    => (Target_Page => 1,
                                   Target_Slot => Slot,
                                   TOAST_Root  => Engine.Docs (Slot).Toast_Ptr.Root_Overflow_Page),
                        Status => Sub_Stat);
                     if Engine.Docs (Slot).Cur_HNSW_Node.Active
                       and then Engine.Docs (Slot).Cur_HNSW_Node.Bin_Vec.Dim = Engine.Dim
                     then
                        Restore_Vector_Node
                          (Engine.Vector_Graph, Slot, Engine.Docs (Slot).Cur_HNSW_Node);
                     end if;
                  end if;
               else
                  Engine.Docs (Slot) := (others => <>);
                  Delete_Key (Engine.PK_Tree, Integer_64 (Slot), Removed);
                  Remove_Vector (Engine.Vector_Graph, Slot);
               end if;
            elsif Engine.Docs (Slot).Tuple_Hdr.Xmax = Tx_Num then
               Engine.Docs (Slot).Tuple_Hdr.Xmax := 0;
               Insert_Key
                 (Tree   => Engine.PK_Tree,
                  Key    => Integer_64 (Slot),
                  Ptr    => (Target_Page => 1,
                             Target_Slot => Slot,
                             TOAST_Root  => Engine.Docs (Slot).Toast_Ptr.Root_Overflow_Page),
                  Status => Sub_Stat);
               if Engine.Docs (Slot).Cur_HNSW_Node.Active
                 and then Engine.Docs (Slot).Cur_HNSW_Node.Bin_Vec.Dim = Engine.Dim
               then
                  Restore_Vector_Node
                    (Engine.Vector_Graph, Slot, Engine.Docs (Slot).Cur_HNSW_Node);
               end if;
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

      Recompute_TOAST_High_Water_Mark (Engine);
   end Rollback_RAG_Tx;

   -------------------------------------------------------------------------
   --  TOAST Range Overlap Helpers
   -------------------------------------------------------------------------

   function Ranges_Overlap
     (Start_A : Valid_Page_Id;
      Count_A : Natural;
      Start_B : Valid_Page_Id;
      Count_B : Natural) return Boolean
   is
     (Count_A > 0
      and then Count_B > 0
      and then Start_A >= 10
      and then Start_B >= 10
      and then Integer_64 (Start_A) < Integer_64 (Start_B) + Integer_64 (Count_B)
      and then Integer_64 (Start_B) < Integer_64 (Start_A) + Integer_64 (Count_A));

   function Ptr_Overlaps_Range
     (P          : TOAST_Pointer;
      Cand_Start : Valid_Page_Id;
      Cand_Count : Positive) return Boolean
   is
     (Ranges_Overlap
        (P.Root_Overflow_Page, P.Chunk_Count, Cand_Start, Cand_Count));

   function Is_TOAST_Range_Free
     (Engine          : RAG_Engine;
      Updating_Slot   : RAG_Doc_Slot;
      Keep_Prior      : Boolean;
      Retained_Toast  : TOAST_Pointer;
      Retained_Vec_P  : TOAST_Pointer;
      Retained_Meta_P : TOAST_Pointer;
      Cand_Start      : Valid_Page_Id;
      Cand_Count      : Positive) return Boolean
   is
   begin
      if Keep_Prior then
         if Ptr_Overlaps_Range (Retained_Toast, Cand_Start, Cand_Count)
           or else Ptr_Overlaps_Range (Retained_Vec_P, Cand_Start, Cand_Count)
           or else Ptr_Overlaps_Range (Retained_Meta_P, Cand_Start, Cand_Count)
         then
            return False;
         end if;
      end if;

      for S in RAG_Doc_Slot loop
         if S /= Updating_Slot and then Engine.Docs (S).Active then
            if Ptr_Overlaps_Range (Engine.Docs (S).Toast_Ptr, Cand_Start, Cand_Count)
              or else Ptr_Overlaps_Range (Engine.Docs (S).Vec_Toast_Ptr, Cand_Start, Cand_Count)
              or else Ptr_Overlaps_Range (Engine.Docs (S).Meta_Toast_Ptr, Cand_Start, Cand_Count)
            then
               return False;
            end if;
            if Engine.Docs (S).Has_Prior_Version then
               if Ptr_Overlaps_Range (Engine.Docs (S).Prior_Toast_Ptr, Cand_Start, Cand_Count)
                 or else Ptr_Overlaps_Range (Engine.Docs (S).Prior_Vec_Toast_Ptr, Cand_Start, Cand_Count)
                 or else Ptr_Overlaps_Range (Engine.Docs (S).Prior_Meta_Toast_Ptr, Cand_Start, Cand_Count)
               then
                  return False;
               end if;
            end if;
         end if;
      end loop;

      return True;
   end Is_TOAST_Range_Free;

   subtype TOAST_Run is Positive range 1 .. Max_TOAST_Chunks;

   --  May the writer Tx use pages Cand_Start .. Cand_Start + Cand_Count - 1 for a new
   --  version of Updating_Slot? Reserved are the live and prior chains of every other
   --  slot (Is_TOAST_Range_Free), the chains Updating_Slot keeps as its prior
   --  (Keep_Prior), the ranges Used_A / Used_B already chosen for this version, and the
   --  pages staged by any other transaction that is still active: its commit
   --  materializes every frame it staged, those of versions it has since superseded
   --  included. Tx may reuse pages it staged itself: its later frames overwrite them in
   --  WAL order, both at commit and in redo.
   function Is_TOAST_Range_Available
     (Engine          : RAG_Engine;
      Tx              : Valid_Tx_Id;
      Updating_Slot   : RAG_Doc_Slot;
      Keep_Prior      : Boolean;
      Retained_Toast  : TOAST_Pointer;
      Retained_Vec_P  : TOAST_Pointer;
      Retained_Meta_P : TOAST_Pointer;
      Used_A_Start    : Valid_Page_Id;
      Used_A_Count    : TOAST_Chunk_Count;
      Used_B_Start    : Valid_Page_Id;
      Used_B_Count    : TOAST_Chunk_Count;
      Cand_Start      : Valid_Page_Id;
      Cand_Count      : TOAST_Run) return Boolean
   is
   begin
      if Ranges_Overlap (Used_A_Start, Used_A_Count, Cand_Start, Cand_Count)
        or else Ranges_Overlap (Used_B_Start, Used_B_Count, Cand_Start, Cand_Count)
        or else not Is_TOAST_Range_Free
          (Engine, Updating_Slot, Keep_Prior, Retained_Toast, Retained_Vec_P,
           Retained_Meta_P, Cand_Start, Cand_Count)
      then
         return False;
      end if;

      for S in RAG_Doc_Slot loop
         if Has_Reserved_Staging (Engine, S)
           and then Engine.Docs (S).Staged_Tx /= Tx
           and then Ranges_Overlap
             (Engine.Docs (S).Staged_First,
              Engine.Docs (S).Staged_End - Engine.Docs (S).Staged_First,
              Cand_Start, Cand_Count)
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_TOAST_Range_Available;

   --  Lowest Start in 10 .. Max_Safe_TOAST_Page - Count from which Count pages are
   --  available (Is_TOAST_Range_Available); Found is False when there is none. The
   --  lowest available start is page 10 or the end of a reserved range, so only those
   --  candidates are tried (first fit: pages freed below the high-water mark are reused).
   procedure Find_TOAST_Range
     (Engine          : in     RAG_Engine;
      Tx              : in     Valid_Tx_Id;
      Updating_Slot   : in     RAG_Doc_Slot;
      Keep_Prior      : in     Boolean;
      Retained_Toast  : in     TOAST_Pointer;
      Retained_Vec_P  : in     TOAST_Pointer;
      Retained_Meta_P : in     TOAST_Pointer;
      Used_A_Start    : in     Valid_Page_Id;
      Used_A_Count    : in     TOAST_Chunk_Count;
      Used_B_Start    : in     Valid_Page_Id;
      Used_B_Count    : in     TOAST_Chunk_Count;
      Count           : in     TOAST_Run;
      Start           :    out Valid_Page_Id;
      Found           :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Found then Start in 10 .. Max_Safe_TOAST_Page - Count)
   is
      procedure Try (Cand : Natural)
        with Pre  => (if Found then Start in 10 .. Max_Safe_TOAST_Page - Count),
             Post => (if Found then Start in 10 .. Max_Safe_TOAST_Page - Count)
      is
      begin
         if Cand in 10 .. Max_Safe_TOAST_Page - Count
           and then (not Found or else Cand < Start)
           and then Is_TOAST_Range_Available
             (Engine, Tx, Updating_Slot, Keep_Prior, Retained_Toast, Retained_Vec_P,
              Retained_Meta_P, Used_A_Start, Used_A_Count, Used_B_Start, Used_B_Count,
              Cand, Count)
         then
            Start := Cand;
            Found := True;
         end if;
      end Try;
   begin
      Start := 10;
      Found := False;
      Try (10);
      for S in RAG_Doc_Slot loop
         pragma Loop_Invariant (if Found then Start in 10 .. Max_Safe_TOAST_Page - Count);
         Try (Chain_End (Engine.Docs (S).Toast_Ptr));
         Try (Chain_End (Engine.Docs (S).Vec_Toast_Ptr));
         Try (Chain_End (Engine.Docs (S).Meta_Toast_Ptr));
         Try (Chain_End (Engine.Docs (S).Prior_Toast_Ptr));
         Try (Chain_End (Engine.Docs (S).Prior_Vec_Toast_Ptr));
         Try (Chain_End (Engine.Docs (S).Prior_Meta_Toast_Ptr));
         Try (Engine.Docs (S).Staged_End);
      end loop;
      Try (Chain_End (Retained_Toast));
      Try (Chain_End (Retained_Vec_P));
      Try (Chain_End (Retained_Meta_P));
      Try (Used_A_Start + Used_A_Count);
      Try (Used_B_Start + Used_B_Count);
   end Find_TOAST_Range;

   procedure Recover_RAG_Engine
     (Engine      :    out RAG_Engine;
      Dim         : in     Vector_Dim;
      DB_Path     : in     Bounded_Text;
      WAL_Path    : in     Bounded_Text;
      Max_Seen_Tx :    out Tx_Id;
      Status      :    out Engine_Status)
   is
      WAL_Exists     : Boolean;
      DB_Exists      : Boolean;
      Replayed       : Natural;
      Max_Rec_Tx     : Tx_Id;
      Redo_Seen_Tx   : Tx_Id;
      Sub_Stat       : Engine_Status;
      Raw_Page       : Page_Buffer;
      Read_Ok        : Boolean;
      Read_EOF       : Boolean;
      P0_Ok          : Boolean;
      P0_EOF         : Boolean;
      Page_Rec       : Slotted_Page;
      Page_Valid     : Boolean;
      Vec_B          : TOAST_Pointer_Bytes;
      Vec_Ptr        : TOAST_Pointer;
      Vec_Valid      : Boolean;
      Meta_B         : TOAST_Pointer_Bytes;
      Meta_Ptr       : TOAST_Pointer;
      Meta_Valid     : Boolean;
      Vec_Payload    : TOAST_Payload_Buffer;
      Vec_Len        : TOAST_Payload_Length;
      Doc_Payload    : TOAST_Payload_Buffer;
      Doc_Len        : TOAST_Payload_Length;
      Meta_Payload   : TOAST_Payload_Buffer;
      Meta_Len       : TOAST_Payload_Length;
      Rec_Vec        : Vector_Value;
      Rec_Sum        : Bounded_Text;
      Rec_Meta       : JSONB_Document;
      Dec_Valid      : Boolean;
      Meta_Dec_Valid : Boolean;
      Sum_Len        : Natural;
      Stored_Fields  : Natural;
      Cur_Off        : Positive;
      Key_Len        : Natural;
      Val_Len        : Natural;
      Kind_Raw       : Natural;
      Meta_Key       : Bounded_Ident;
      Meta_Val       : Bounded_Text;
      Meta_Kind      : JSONB_Value_Kind;
      End_Page       : Natural;
      HNSW_Snap      : HNSW_Node;
      Expected_VLen  : constant Valid_TOAST_Length := Vector_TOAST_Byte_Length (Dim);
      pragma Warnings (Off, Replayed);
      pragma Warnings (Off, Max_Rec_Tx);
      pragma Warnings (Off, Doc_Payload);
   begin
      Init_RAG_Engine (Engine, Dim);
      Max_Seen_Tx := 0;

      if Equal_Text (DB_Path, WAL_Path) then
         Status := Status_IO_Error;
         return;
      end if;

      --  1. Run committed-only WAL Redo Recovery (with torn-tail repair) when WAL_Path exists
      Check_File_Exists (WAL_Path, WAL_Exists);
      if WAL_Exists then
         Redo_WAL_Recovery
           (DB_Path          => DB_Path,
            WAL_Path         => WAL_Path,
            Max_Frames       => Max_WAL_Scan_Frames,
            Replayed_Count   => Replayed,
            Max_Recovered_Tx => Max_Rec_Tx,
            Max_Seen_Tx      => Redo_Seen_Tx,
            Status           => Sub_Stat);
         if Sub_Stat /= Status_Ok then
            Status := Sub_Stat;
            return;
         end if;
         Max_Seen_Tx := Redo_Seen_Tx;
      end if;

      --  2. A missing or empty database file recovers an empty engine
      Check_File_Exists (DB_Path, DB_Exists);
      if not DB_Exists then
         Status := Status_Ok;
         return;
      end if;

      --  3. Read and CRC32-verify primary Slotted_Page at Page_Id = 1
      Read_Page (DB_Path, 1, Raw_Page, Read_Ok, Read_EOF);
      if not Read_Ok then
         if Read_EOF then
            --  Page 1 is past EOF: only a completely empty file is a valid empty database
            Read_Page (DB_Path, 0, Raw_Page, P0_Ok, P0_EOF);
            Status := (if P0_EOF then Status_Ok else Status_IO_Error);
         else
            Status := Status_IO_Error;
         end if;
         return;
      end if;

      --  A damaged Page 1 (CRC, magic or page id) is corruption like any other
      Decode_Slotted_Page (Raw_Page, Page_Rec, Page_Valid);
      if not Page_Valid or else Page_Rec.Page_Id /= 1 then
         Status := Status_IO_Error;
         return;
      end if;
      if Page_Rec.Page_LSN_Tx > Max_Seen_Tx then
         Max_Seen_Tx := Page_Rec.Page_LSN_Tx;
      end if;

      --  4. Reconstruct documents, CLOG, B+Tree PK index, and HNSW vector graph
      for Slot in RAG_Doc_Slot loop
         pragma Loop_Invariant (Engine.Dim = Dim);
         pragma Loop_Invariant (Engine.Vector_Graph.Dim = Dim);
         pragma Loop_Invariant (Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes);
         pragma Loop_Invariant (Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count);
         pragma Loop_Invariant (Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page);
         pragma Loop_Invariant
           (for all S in RAG_Doc_Slot =>
              (if Engine.Docs (S).Active then
                 Engine.Docs (S).Tuple_Hdr.Xmin <= Max_Seen_Tx
                 and then Engine.Docs (S).Tuple_Hdr.Xmax <= Max_Seen_Tx));

         if Page_Rec.Tuples (Slot).Occupied then
            if Page_Rec.Tuples (Slot).Row_Id /= Slot
              or else Page_Rec.Tuples (Slot).Related_Id > Max_RAG_Docs
              or else Page_Rec.Tuples (Slot).Inline_Len /= Max_Inline_Tuple_Bytes
              or else Page_Rec.Tuples (Slot).Toast_Ptr.Total_Byte_Length not in 1 .. Max_TOAST_Payload_Bytes
              or else Page_Rec.Tuples (Slot).Toast_Ptr.Chunk_Count not in 1 .. Max_TOAST_Chunks
              or else Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page < 10
            then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            for B in TOAST_Pointer_Index loop
               Vec_B (B)  := Page_Rec.Tuples (Slot).Inline_Data (B);
               Meta_B (B) := Page_Rec.Tuples (Slot).Inline_Data (80 + B);
            end loop;
            Decode_TOAST_Pointer (Vec_B, Vec_Ptr, Vec_Valid);
            Decode_TOAST_Pointer (Meta_B, Meta_Ptr, Meta_Valid);
            --  The CRC-verified page holds the vector length of another dimension: the
            --  database was opened with the wrong Dim, it is not damaged
            if Vec_Valid
              and then Vec_Ptr.Total_Byte_Length /= Expected_VLen
              and then Vec_Ptr.Total_Byte_Length > Vector_TOAST_Header_Size
              and then (Vec_Ptr.Total_Byte_Length - Vector_TOAST_Header_Size) mod 4 = 0
            then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_Dimension_Mismatch;
               return;
            end if;
            if not Vec_Valid
              or else Vec_Ptr.Total_Byte_Length /= Expected_VLen
              or else Vec_Ptr.Chunk_Count not in 1 .. Max_TOAST_Chunks
              or else Vec_Ptr.Root_Overflow_Page < 10
              or else (not Meta_Valid
                       and then Meta_B /= TOAST_Pointer_Bytes'[others => 0])
            then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            --  Verify pairwise non-overlapping TOAST chains within slot and across slots
            if Ranges_Overlap
                 (Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page,
                  Page_Rec.Tuples (Slot).Toast_Ptr.Chunk_Count,
                  Vec_Ptr.Root_Overflow_Page,
                  Vec_Ptr.Chunk_Count)
              or else not Is_TOAST_Range_Free
                (Engine, Slot, False, (others => <>), (others => <>), (others => <>),
                 Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page,
                 Page_Rec.Tuples (Slot).Toast_Ptr.Chunk_Count)
              or else not Is_TOAST_Range_Free
                (Engine, Slot, False, (others => <>), (others => <>), (others => <>),
                 Vec_Ptr.Root_Overflow_Page,
                 Vec_Ptr.Chunk_Count)
            then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            if Natural (Page_Rec.Tuples (Slot).Inline_Data (17)) > Max_Inline_Summary_Bytes
              or else Natural (Page_Rec.Tuples (Slot).Inline_Data (97)) > Max_JSON_Fields
            then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            Sum_Len := Natural (Page_Rec.Tuples (Slot).Inline_Data (17));
            Engine.Docs (Slot).Summary_Text := (Length => Sum_Len, Data => [others => ' ']);
            for I in 1 .. Sum_Len loop
               Engine.Docs (Slot).Summary_Text.Data (I) :=
                 Character'Val (Natural (Page_Rec.Tuples (Slot).Inline_Data (17 + I)));
            end loop;

            Engine.Docs (Slot).Metadata := (others => <>);
            Stored_Fields := Natural (Page_Rec.Tuples (Slot).Inline_Data (97));
            Cur_Off := 98;
            for F_Idx in 1 .. Stored_Fields loop
               pragma Loop_Invariant (Cur_Off in 98 .. Max_Inline_Tuple_Bytes + 1);
               if Cur_Off + 2 > Max_Inline_Tuple_Bytes then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;
               Key_Len  := Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off));
               Val_Len  := Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off + 1));
               Kind_Raw := Natural (Page_Rec.Tuples (Slot).Inline_Data (Cur_Off + 2));
               if Key_Len not in 1 .. Max_Ident_Len
                 or else Val_Len > 108
                 or else Kind_Raw > JSONB_Value_Kind'Pos (JSONB_Array)
                 or else Cur_Off + 2 + Key_Len + Val_Len > Max_Inline_Tuple_Bytes
               then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;

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
               if Sub_Stat /= Status_Ok then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;
               Cur_Off := Cur_Off + 3 + Key_Len + Val_Len;
            end loop;

            --  If lossless extended metadata + summary TOAST ("RMET") is present, restore full payload
            if Meta_Ptr.Total_Byte_Length > 0 then
               if Meta_Ptr.Total_Byte_Length not in 7 .. Max_TOAST_Payload_Bytes
                 or else Meta_Ptr.Chunk_Count not in 1 .. Max_TOAST_Chunks
                 or else Meta_Ptr.Root_Overflow_Page < 10
                 or else Ranges_Overlap
                   (Meta_Ptr.Root_Overflow_Page, Meta_Ptr.Chunk_Count,
                    Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page,
                    Page_Rec.Tuples (Slot).Toast_Ptr.Chunk_Count)
                 or else Ranges_Overlap
                   (Meta_Ptr.Root_Overflow_Page, Meta_Ptr.Chunk_Count,
                    Vec_Ptr.Root_Overflow_Page, Vec_Ptr.Chunk_Count)
                 or else not Is_TOAST_Range_Free
                   (Engine, Slot, False, (others => <>), (others => <>), (others => <>),
                    Meta_Ptr.Root_Overflow_Page, Meta_Ptr.Chunk_Count)
               then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;
               Read_TOAST_Chain (DB_Path, Meta_Ptr, Meta_Payload, Meta_Len, Sub_Stat);
               if Sub_Stat /= Status_Ok
                 or else Meta_Len /= Meta_Ptr.Total_Byte_Length
               then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;
               Decode_Meta_TOAST
                 (Meta_Payload, Meta_Len, Rec_Sum, Rec_Meta, Meta_Dec_Valid);
               if not Meta_Dec_Valid then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;
               Engine.Docs (Slot).Summary_Text := Rec_Sum;
               Engine.Docs (Slot).Metadata     := Rec_Meta;
            end if;

            if Page_Rec.Tuples (Slot).Tuple_Hdr.Xmin > Max_Seen_Tx then
               Max_Seen_Tx := Page_Rec.Tuples (Slot).Tuple_Hdr.Xmin;
            end if;
            if Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax > Max_Seen_Tx then
               Max_Seen_Tx := Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax;
            end if;

            Engine.Docs (Slot).Active         := True;
            Engine.Docs (Slot).Doc_Id         := Slot;
            Engine.Docs (Slot).Tuple_Hdr      := Page_Rec.Tuples (Slot).Tuple_Hdr;
            Engine.Docs (Slot).Toast_Ptr      := Page_Rec.Tuples (Slot).Toast_Ptr;
            Engine.Docs (Slot).Vec_Toast_Ptr  := Vec_Ptr;
            Engine.Docs (Slot).Meta_Toast_Ptr := Meta_Ptr;
            Engine.Docs (Slot).Related_Doc_Id := Page_Rec.Tuples (Slot).Related_Id;

            --  Mark recovered tuple's Xmin (and Xmax if deleted) as committed in CLOG
            Set_CLOG_State
              (Engine.CLOG, Page_Rec.Tuples (Slot).Tuple_Hdr.Xmin, Tx_Committed);
            if Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax > 0 then
               Set_CLOG_State
                 (Engine.CLOG, Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax, Tx_Committed);
            elsif Engine.Doc_Count < Max_RAG_Docs then
               Engine.Doc_Count := Engine.Doc_Count + 1;
            end if;

            --  Advance Next_TOAST_Pg past recovered TOAST chains (rejecting out-of-range page bounds)
            End_Page :=
              Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page +
              Page_Rec.Tuples (Slot).Toast_Ptr.Chunk_Count;
            if End_Page > Max_Safe_TOAST_Page then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            elsif End_Page > Engine.Next_TOAST_Pg then
               Engine.Next_TOAST_Pg := End_Page;
            end if;

            End_Page := Vec_Ptr.Root_Overflow_Page + Vec_Ptr.Chunk_Count;
            if End_Page > Max_Safe_TOAST_Page then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            elsif End_Page > Engine.Next_TOAST_Pg then
               Engine.Next_TOAST_Pg := End_Page;
            end if;

            if Meta_Ptr.Total_Byte_Length > 0 then
               End_Page := Meta_Ptr.Root_Overflow_Page + Meta_Ptr.Chunk_Count;
               if End_Page > Max_Safe_TOAST_Page then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               elsif End_Page > Engine.Next_TOAST_Pg then
                  Engine.Next_TOAST_Pg := End_Page;
               end if;
            end if;

            --  Verify parent chunk and vector TOAST chains for all occupied tuples
            Read_TOAST_Chain
              (DB_Path, Page_Rec.Tuples (Slot).Toast_Ptr, Doc_Payload, Doc_Len, Sub_Stat);
            if Sub_Stat /= Status_Ok
              or else Doc_Len /= Page_Rec.Tuples (Slot).Toast_Ptr.Total_Byte_Length
            then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            Read_TOAST_Chain (DB_Path, Vec_Ptr, Vec_Payload, Vec_Len, Sub_Stat);
            if Sub_Stat /= Status_Ok or else Vec_Len /= Expected_VLen then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;
            Decode_Vector_TOAST (Vec_Payload, Vec_Len, Dim, Rec_Vec, Dec_Valid);
            if not Dec_Valid then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            if not Has_HNSW_Capacity (Engine.Vector_Graph, Slot) then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;

            Insert_Vector
              (Index      => Engine.Vector_Graph,
               Doc_Id     => Slot,
               Vec        => Rec_Vec,
               TOAST_Root => Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page,
               Layer_Hint => 1,
               Status     => Sub_Stat);
            if Sub_Stat /= Status_Ok then
               Init_RAG_Engine (Engine, Dim);
               Status := Status_IO_Error;
               return;
            end if;
            Capture_Doc_HNSW_Node (Engine.Vector_Graph, Slot, HNSW_Snap);
            Engine.Docs (Slot).Cur_HNSW_Node := HNSW_Snap;

            --  Only index non-deleted tuples (Xmax = 0) in PK_Tree and Vector_Graph
            if Page_Rec.Tuples (Slot).Tuple_Hdr.Xmax = 0 then
               Insert_Key
                 (Tree   => Engine.PK_Tree,
                  Key    => Integer_64 (Slot),
                  Ptr    => (Target_Page => 1,
                             Target_Slot => Slot,
                             TOAST_Root  => Page_Rec.Tuples (Slot).Toast_Ptr.Root_Overflow_Page),
                  Status => Sub_Stat);
               if Sub_Stat /= Status_Ok then
                  Init_RAG_Engine (Engine, Dim);
                  Status := Status_IO_Error;
                  return;
               end if;
            else
               Remove_Vector (Engine.Vector_Graph, Slot);
            end if;
         end if;
      end loop;

      Status := Status_Ok;
   end Recover_RAG_Engine;

   procedure Recover_RAG_Engine
     (Engine   :    out RAG_Engine;
      Dim      : in     Vector_Dim;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Status   :    out Engine_Status)
   is
      Ignored_Seen : Tx_Id;
      pragma Warnings (Off, Ignored_Seen);
   begin
      Recover_RAG_Engine (Engine, Dim, DB_Path, WAL_Path, Ignored_Seen, Status);
   end Recover_RAG_Engine;

   -------------------------------------------------------------------------
   --  Commit_RAG_Tx & Freeze_RAG_Engine
   -------------------------------------------------------------------------

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
   is
      Commit_Page : Page_Buffer;
      Replayed    : Natural;
      Max_Rec_Tx  : Tx_Id;
      Max_Seen    : Tx_Id;
      Redo_Stat   : Engine_Status;
      pragma Warnings (Off, Replayed);
      pragma Warnings (Off, Max_Rec_Tx);
      pragma Warnings (Off, Max_Seen);
   begin
      Delivered     := 0;
      Flush_Pending := False;

      --  A transaction id that the engine already knows as committed can never commit
      --  again (reused id); nothing of the engine is touched
      if Engine.CLOG (Ctx.Id) = Tx_Committed then
         Rollback_Tx (Ctx);
         Discard_Staged_Notifications (Ctx, Staging);
         Status := Status_Tx_Aborted;
         return;
      end if;

      --  A poisoned transaction (a failed Ingest_Document whose orphan WAL frames could
      --  not be truncated) must not reach Commit_Tx, which would materialize them
      if Engine.CLOG (Ctx.Id) = Tx_Aborted then
         Rollback_RAG_Tx (Engine, Ctx.Id);
         Rollback_Tx (Ctx);
         Discard_Staged_Notifications (Ctx, Staging);
         Status := Status_Tx_Aborted;
         return;
      end if;

      Build_RAG_Slotted_Page (Engine, Ctx.Id, Commit_Page);
      Commit_Tx (Ctx, DB_Path, WAL_Path, 1, Commit_Page, Status, Flush_Pending);

      if Ctx.State = Tx_Committed then
         Mark_Committed (Engine, Ctx.Id);
         Flush_Committed_Notifications (Ctx, Staging, Broker, Delivered);
         if Flush_Pending then
            --  The barrier is durable but DB_Path is stale: re-materialize it now
            Redo_WAL_Recovery
              (DB_Path          => DB_Path,
               WAL_Path         => WAL_Path,
               Max_Frames       => Max_WAL_Scan_Frames,
               Replayed_Count   => Replayed,
               Max_Recovered_Tx => Max_Rec_Tx,
               Max_Seen_Tx      => Max_Seen,
               Status           => Redo_Stat);
            Flush_Pending := (Redo_Stat /= Status_Ok);
            --  A successful redo materialized every committed frame of the WAL
            Engine.Pages_Pending := Flush_Pending;
         end if;
      else
         Rollback_RAG_Tx (Engine, Ctx.Id);
         Discard_Staged_Notifications (Ctx, Staging);
      end if;
   end Commit_RAG_Tx;

   procedure Freeze_RAG_Engine
     (Engine : in out RAG_Engine;
      Status :    out Engine_Status)
   is
   begin
      --  The WAL a checkpoint replaces would hold the only copy of committed pages
      if Engine.Pages_Pending then
         Status := Status_IO_Error;
         return;
      end if;

      --  Refuse while any transaction is in flight
      for T in CLOG_Tx_Index loop
         if Engine.CLOG (T) = Tx_Active then
            Status := Status_Tx_Aborted;
            return;
         end if;
      end loop;

      for S in RAG_Doc_Slot loop
         if Engine.Docs (S).Active
           and then (not Is_Tx_Committed (Engine.CLOG, Engine.Docs (S).Tuple_Hdr.Xmin)
                     or else (Engine.Docs (S).Tuple_Hdr.Xmax > 0
                              and then not Is_Tx_Committed
                                (Engine.CLOG, Engine.Docs (S).Tuple_Hdr.Xmax)))
         then
            Status := Status_Tx_Aborted;
            return;
         end if;
      end loop;

      for S in RAG_Doc_Slot loop
         pragma Loop_Invariant (Engine.Dim = Engine.Dim'Loop_Entry);
         pragma Loop_Invariant (Engine.Vector_Graph = Engine.Vector_Graph'Loop_Entry);
         pragma Loop_Invariant (Engine.PK_Tree = Engine.PK_Tree'Loop_Entry);
         pragma Loop_Invariant
           (for all P in 1 .. S - 1 =>
              (if Engine.Docs (P).Active then
                 Engine.Docs (P).Tuple_Hdr.Xmin = 1
                 and then Engine.Docs (P).Tuple_Hdr.Xmax = 0
                 and then not Engine.Docs (P).Has_Prior_Version));
         --  No transaction is active, so no staged page stays reserved
         Engine.Docs (S).Staged_Tx    := 0;
         Engine.Docs (S).Staged_First := 10;
         Engine.Docs (S).Staged_End   := 10;
         if Engine.Docs (S).Active then
            if Engine.Docs (S).Tuple_Hdr.Xmax > 0 then
               --  Committed delete: no snapshot can see this document any more (its
               --  PK_Tree / Vector_Graph entries were already removed by the delete)
               Engine.Docs (S) := (others => <>);
            else
               Engine.Docs (S).Tuple_Hdr            := (Xmin => 1, Xmax => 0);
               Engine.Docs (S).Has_Prior_Version    := False;
               Engine.Docs (S).Prior_Tuple_Hdr      := (Xmin => 1, Xmax => 0);
               Engine.Docs (S).Prior_Metadata       := (others => <>);
               Engine.Docs (S).Prior_Summary        := (Length => 0, Data => [others => ' ']);
               Engine.Docs (S).Prior_Toast_Ptr      := (others => <>);
               Engine.Docs (S).Prior_Vec_Toast_Ptr  := (others => <>);
               Engine.Docs (S).Prior_Meta_Toast_Ptr := (others => <>);
               Engine.Docs (S).Prior_Related_Id     := 0;
               Engine.Docs (S).Prior_HNSW_Node      := (others => <>);
            end if;
         end if;
      end loop;

      Engine.CLOG            := Default_CLOG;
      Engine.CLOG (1)        := Tx_Committed;
      Engine.Commit_Seqs     := [others => 0];
      Engine.Last_Commit_Seq := 0;
      Engine.Read_Horizon    := 0;

      Engine.Doc_Count := 0;
      for S in RAG_Doc_Slot loop
         pragma Loop_Invariant (Engine.Doc_Count < S);
         if Engine.Docs (S).Active then
            Engine.Doc_Count := Engine.Doc_Count + 1;
         end if;
      end loop;

      Recompute_TOAST_High_Water_Mark (Engine);
      Status := Status_Ok;
   end Freeze_RAG_Engine;

   -------------------------------------------------------------------------
   --  Ingest_Document
   -------------------------------------------------------------------------

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
   is
      Old_Entry          : constant RAG_Document_Entry := Engine.Docs (Doc_Id);
      Saved_Next_TOAST   : constant Valid_Page_Id      := Engine.Next_TOAST_Pg;
      Saved_Doc_Count    : constant RAG_Doc_Count      := Engine.Doc_Count;
      Saved_Tx_State     : constant Tx_State           := Engine.CLOG (Ctx.Id);
      Saved_PK_Tree      : constant BTree_Index        := Engine.PK_Tree;
      Saved_Graph        : constant HNSW_Index         := Engine.Vector_Graph;
      Saved_Horizon      : constant Commit_Seq_Number  := Engine.Read_Horizon;
      Old_Xmin_Comm      : constant Boolean            :=
        Old_Entry.Active
        and then Is_Tx_Committed (Engine.CLOG, Old_Entry.Tuple_Hdr.Xmin);
      Old_Xmax_Comm      : constant Boolean            :=
        Old_Entry.Active
        and then Old_Entry.Tuple_Hdr.Xmax > 0
        and then Is_Tx_Committed (Engine.CLOG, Old_Entry.Tuple_Hdr.Xmax);
      Keep_Prior         : constant Boolean            :=
        (Old_Entry.Active and then Old_Xmin_Comm)
        or else (Old_Entry.Active and then Old_Entry.Has_Prior_Version);
      Retained_Hdr       : constant MVCC_Tuple_Header  :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then (Xmin => Old_Entry.Tuple_Hdr.Xmin,
               Xmax => (if Old_Xmax_Comm then Old_Entry.Tuple_Hdr.Xmax else Ctx.Id))
         elsif Old_Entry.Active and then Old_Entry.Has_Prior_Version
         then Old_Entry.Prior_Tuple_Hdr
         else (Xmin => 1, Xmax => 0));
      Retained_Meta      : constant JSONB_Document     :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Metadata else Old_Entry.Prior_Metadata);
      Retained_Sum       : constant Bounded_Text       :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Summary_Text else Old_Entry.Prior_Summary);
      Retained_Toast     : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Toast_Ptr else Old_Entry.Prior_Toast_Ptr);
      Retained_Vec_P     : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Vec_Toast_Ptr else Old_Entry.Prior_Vec_Toast_Ptr);
      Retained_Meta_P    : constant TOAST_Pointer      :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Meta_Toast_Ptr else Old_Entry.Prior_Meta_Toast_Ptr);
      Retained_Rel       : constant Optional_Doc_Id    :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Related_Doc_Id else Old_Entry.Prior_Related_Id);
      Retained_HNSW      : constant HNSW_Node          :=
        (if Old_Entry.Active and then Old_Xmin_Comm
         then Old_Entry.Cur_HNSW_Node else Old_Entry.Prior_HNSW_Node);
      Needed_Doc_Chunks  : constant TOAST_Run          :=
        ((Parent_Length - 1) / TOAST_Chunk_Max_Bytes) + 1;
      Use_Meta_Chain     : constant Boolean            :=
        Needs_Meta_TOAST (Summary_Text, Metadata);
      Ptr                : TOAST_Pointer;
      Vec_Ptr            : TOAST_Pointer;
      Meta_Ptr           : TOAST_Pointer               := (others => <>);
      Vec_Payload        : TOAST_Payload_Buffer;
      Vec_Byte_Len       : Valid_TOAST_Length;
      Needed_Vec_Chunks  : TOAST_Run;
      Meta_Payload       : TOAST_Payload_Buffer        := [others => 0];
      Meta_Byte_Len      : Valid_TOAST_Length          := 1;
      Needed_Meta_Chunks : TOAST_Run                   := 1;
      Start_Pg           : Valid_Page_Id;
      Vec_Start_Pg       : Valid_Page_Id;
      Meta_Start_Pg      : Valid_Page_Id               := 10;
      Found              : Boolean;
      Staged_First       : Valid_Page_Id;
      Staged_End         : Valid_Page_Id;
      New_HNSW_Node      : HNSW_Node;
      Sub_Stat           : Engine_Status;
      Slot_Page          : Page_Buffer;
      Slot_WAL           : WAL_Frame_Buffer;
      Slot_CRC           : Unsigned_32;
      pragma Warnings (Off, Slot_CRC);
      WAL_Ok             : Boolean;
      WAL_Exists         : Boolean;
      WAL_Start          : File_Size                   := 0;
      Size_Ok            : Boolean;
      WAL_Touched        : Boolean                     := False;
      Notify_Ch          : constant Bounded_Ident      := Make_Ident ("rag.indexed");

      --  Undo every in-memory mutation of this call. When WAL frames were already
      --  appended, truncate the WAL back to its size at entry; if that is impossible
      --  the transaction is poisoned and all its versions are rolled back at once
      --  (Rollback_RAG_Tx), so its orphan frames can never be committed and no other
      --  transaction builds on, or deletes, a version that can never commit.
      procedure Restore_State
        with Pre  => WAL_Path.Length > 0
                     and then Saved_Graph.Dim = Engine.Dim
                     and then Saved_PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                     and then Saved_PK_Tree.Root_Node in 1 .. Saved_PK_Tree.Node_Count
                     and then Saved_Next_TOAST <= Max_Safe_TOAST_Page
                     and then Saved_Tx_State /= Tx_Committed,
             Post => Engine.Dim = Engine.Dim'Old
                     and then Engine.Vector_Graph.Dim = Engine.Dim
                     and then Engine.PK_Tree.Node_Count in 1 .. Max_BTree_Nodes
                     and then Engine.PK_Tree.Root_Node in 1 .. Engine.PK_Tree.Node_Count
                     and then Engine.Next_TOAST_Pg <= Max_Safe_TOAST_Page
      is
         Trunc_Ok   : Boolean;
         Exists_Now : Boolean;
      begin
         Engine.Docs (Doc_Id) := Old_Entry;
         Engine.Doc_Count     := Saved_Doc_Count;
         Engine.Next_TOAST_Pg := Saved_Next_TOAST;
         Engine.PK_Tree       := Saved_PK_Tree;
         Engine.Vector_Graph  := Saved_Graph;
         Engine.CLOG (Ctx.Id) := Saved_Tx_State;
         Engine.Read_Horizon  := Saved_Horizon;
         if WAL_Touched then
            Check_File_Exists (WAL_Path, Exists_Now);
            if Exists_Now then
               Truncate_File (WAL_Path, WAL_Start, Trunc_Ok);
            else
               Trunc_Ok := (WAL_Start = 0);
            end if;
            if not Trunc_Ok then
               Rollback_RAG_Tx (Engine, Ctx.Id);
            end if;
         end if;
      end Restore_State;
   begin
      --  Snapshot-isolation conflict detection and poisoned / finished transaction guard
      if Has_Write_Conflict (Engine, Doc_Id, Ctx.Id, Snapshot)
        or else Snapshot > Engine.Last_Commit_Seq
        or else Engine.CLOG (Ctx.Id) in Tx_Aborted | Tx_Committed
      then
         Status := Status_Tx_Aborted;
         return;
      end if;

      --  Recovery re-inserts every stored metadata field with Put_Field: refuse a
      --  document it would reject before anything is written
      if not Is_Valid_JSONB_Document (Metadata) then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Pre-check path hygiene and notification staging before any WAL I/O
      if Equal_Text (DB_Path, WAL_Path) then
         Status := Status_IO_Error;
         return;
      end if;

      if Has_Embedded_NUL (DB_Path) or else Has_Embedded_NUL (WAL_Path) then
         Status := Status_IO_Error;
         return;
      end if;

      if Staging.Count > 0 and then Staging.Owner_Tx /= Ctx.Id then
         Status := Status_Tx_Aborted;
         return;
      elsif Staging.Count = Max_Staged_Notifications then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      if not Has_HNSW_Capacity (Engine.Vector_Graph, Doc_Id) then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      --  1-3. Lowest free TOAST pages (first fit) for the parent chunk, the full Float32
      --  embedding and, when needed, the extended summary / JSONB metadata ("RMET")
      Find_TOAST_Range
        (Engine, Ctx.Id, Doc_Id, Keep_Prior, Retained_Toast, Retained_Vec_P, Retained_Meta_P,
         10, 0, 10, 0, Needed_Doc_Chunks, Start_Pg, Found);
      if not Found then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      Encode_Vector_TOAST (Embedding, Vec_Payload, Vec_Byte_Len);
      Needed_Vec_Chunks := ((Vec_Byte_Len - 1) / TOAST_Chunk_Max_Bytes) + 1;
      Find_TOAST_Range
        (Engine, Ctx.Id, Doc_Id, Keep_Prior, Retained_Toast, Retained_Vec_P, Retained_Meta_P,
         Start_Pg, Needed_Doc_Chunks, 10, 0, Needed_Vec_Chunks, Vec_Start_Pg, Found);
      if not Found then
         Status := Status_Capacity_Exceeded;
         return;
      end if;
      Staged_First := Natural'Min (Start_Pg, Vec_Start_Pg);
      Staged_End   := Natural'Max (Start_Pg + Needed_Doc_Chunks, Vec_Start_Pg + Needed_Vec_Chunks);

      if Use_Meta_Chain then
         Encode_Meta_TOAST (Summary_Text, Metadata, Meta_Payload, Meta_Byte_Len);
         Needed_Meta_Chunks := ((Meta_Byte_Len - 1) / TOAST_Chunk_Max_Bytes) + 1;
         Find_TOAST_Range
           (Engine, Ctx.Id, Doc_Id, Keep_Prior, Retained_Toast, Retained_Vec_P, Retained_Meta_P,
            Start_Pg, Needed_Doc_Chunks, Vec_Start_Pg, Needed_Vec_Chunks, Needed_Meta_Chunks,
            Meta_Start_Pg, Found);
         if not Found then
            Status := Status_Capacity_Exceeded;
            return;
         end if;
         Staged_First := Natural'Min (Staged_First, Meta_Start_Pg);
         Staged_End   := Natural'Max (Staged_End, Meta_Start_Pg + Needed_Meta_Chunks);
      end if;

      --  The staged hull also keeps what Ctx staged here before (superseded versions)
      if Old_Entry.Staged_Tx = Ctx.Id
        and then Old_Entry.Staged_End > Old_Entry.Staged_First
      then
         Staged_First := Natural'Min (Staged_First, Old_Entry.Staged_First);
         Staged_End   := Natural'Max (Staged_End, Old_Entry.Staged_End);
      end if;

      --  4. Perform in-memory B+Tree and HNSW updates BEFORE writing WAL frames
      --     so capacity failures never leave orphan frames in .wal
      Insert_Key
        (Tree   => Engine.PK_Tree,
         Key    => Integer_64 (Doc_Id),
         Ptr    => (Target_Page => 1,
                    Target_Slot => Doc_Id,
                    TOAST_Root  => Start_Pg),
         Status => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Restore_State;
         Status := Sub_Stat;
         return;
      end if;

      Insert_Vector
        (Index      => Engine.Vector_Graph,
         Doc_Id     => Doc_Id,
         Vec        => Embedding,
         TOAST_Root => Start_Pg,
         Layer_Hint => Layer_Hint,
         Status     => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Restore_State;
         Status := Sub_Stat;
         return;
      end if;

      Capture_Doc_HNSW_Node (Engine.Vector_Graph, Doc_Id, New_HNSW_Node);

      --  Remember the WAL length so a failure below can drop this call's frames
      Check_File_Exists (WAL_Path, WAL_Exists);
      if WAL_Exists then
         Get_File_Size (WAL_Path, WAL_Start, Size_Ok);
         if not Size_Ok then
            Restore_State;
            Status := Status_IO_Error;
            return;
         end if;
      end if;
      WAL_Touched := True;

      --  5a. Stage parent chunk into 4KB TOAST overflow chain in WAL (NO-STEAL)
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
         Restore_State;
         Status := Sub_Stat;
         return;
      end if;

      --  5b. Stage full Float32 Embedding into TOAST chain for Stage-2 Re-Ranking (Q-003)
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
         Restore_State;
         Status := Sub_Stat;
         return;
      end if;

      --  5c. Stage extended Summary_Text + JSONB Metadata into TOAST chain when needed
      if Use_Meta_Chain then
         Write_TOAST_Chain
           (Ctx           => Ctx,
            DB_Path       => DB_Path,
            WAL_Path      => WAL_Path,
            Start_Page_Id => Meta_Start_Pg,
            Payload       => Meta_Payload,
            Length        => Meta_Byte_Len,
            Ptr           => Meta_Ptr,
            Status        => Sub_Stat);
         if Sub_Stat /= Status_Ok then
            Restore_State;
            Status := Sub_Stat;
            return;
         end if;
      end if;

      --  6. Store MVCC document entry, preserving committed prior version on update
      if (not Old_Entry.Active or else Old_Entry.Tuple_Hdr.Xmax > 0)
        and then Engine.Doc_Count < Max_RAG_Docs
      then
         Engine.Doc_Count := Engine.Doc_Count + 1;
      end if;

      --  Keep transaction Tx_Active in CLOG until Commit_Tx succeeds
      Set_CLOG_State (Engine.CLOG, Ctx.Id, Tx_Active);

      --  Replacing a committed version that already has a prior drops that prior:
      --  snapshots older than the commit of the version kept may have needed it
      if Old_Entry.Active and then Old_Xmin_Comm and then Old_Entry.Has_Prior_Version
        and then Engine.Commit_Seqs (Old_Entry.Tuple_Hdr.Xmin) > Engine.Read_Horizon
      then
         Engine.Read_Horizon := Engine.Commit_Seqs (Old_Entry.Tuple_Hdr.Xmin);
      end if;

      Engine.Docs (Doc_Id) := (
         Active               => True,
         Doc_Id               => Doc_Id,
         Tuple_Hdr            => (Xmin => Ctx.Id, Xmax => 0),
         Metadata             => Metadata,
         Summary_Text         => Summary_Text,
         Toast_Ptr            => Ptr,
         Vec_Toast_Ptr        => Vec_Ptr,
         Meta_Toast_Ptr       => Meta_Ptr,
         Related_Doc_Id       => Related_Doc_Id,
         Cur_HNSW_Node        => New_HNSW_Node,
         Has_Prior_Version    => Keep_Prior,
         Prior_Tuple_Hdr      => Retained_Hdr,
         Prior_Metadata       => Retained_Meta,
         Prior_Summary        => Retained_Sum,
         Prior_Toast_Ptr      => Retained_Toast,
         Prior_Vec_Toast_Ptr  => Retained_Vec_P,
         Prior_Meta_Toast_Ptr => Retained_Meta_P,
         Prior_Related_Id     => Retained_Rel,
         Prior_HNSW_Node      => Retained_HNSW,
         Staged_Tx            => Ctx.Id,
         Staged_First         => Staged_First,
         Staged_End           => Staged_End
      );

      Recompute_TOAST_High_Water_Mark (Engine);

      --  7. Stage primary 4096-byte Slotted_Page in WAL on Page_Id = 1 (NO-STEAL)
      Build_RAG_Slotted_Page (Engine, Ctx.Id, Slot_Page);
      Encode_WAL_Frame (Ctx.Id, 1, Slot_Page, Slot_CRC, Slot_WAL, WAL_Frame_Data);
      Append_WAL_Frame (WAL_Path, Slot_WAL, WAL_Ok);
      if not WAL_Ok then
         Restore_State;
         Status := Status_IO_Error;
         return;
      end if;

      --  8. Stage DURABLE notification (held until WAL Commit Barrier in Commit_Tx)
      Stage_Notify
        (Ctx     => Ctx,
         Staging => Staging,
         Channel => Notify_Ch,
         Payload => Summary_Text,
         Status  => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Restore_State;
         Status := Sub_Stat;
         return;
      end if;

      Status := Status_Ok;
   end Ingest_Document;

   -------------------------------------------------------------------------
   --  Insert_Hit_Sorted (Distance + Tie-Breaking Keyword Boost at Dist = 0.0)
   -------------------------------------------------------------------------

   --  Total order on hits: smaller distance, then keyword match, then smaller Doc_Id,
   --  so equal-distance results are identical before and after recovery
   function Is_Better_Hit (Candidate, Existing : RAG_Search_Hit) return Boolean is
     (Candidate.Distance < Existing.Distance
      or else (Candidate.Distance = Existing.Distance
               and then ((Candidate.Keyword_Match and then not Existing.Keyword_Match)
                         or else (Candidate.Keyword_Match = Existing.Keyword_Match
                                  and then Candidate.Doc_Id < Existing.Doc_Id))));

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
   --  Resolve_Visible_Doc (MVCC Snapshot + CLOG + Prior Version Chain)
   -------------------------------------------------------------------------

   procedure Resolve_Visible_Doc
     (Engine    : in     RAG_Engine;
      Entry_Rec : in     RAG_Document_Entry;
      Snapshot  : in     Commit_Seq_Number;
      Visible   :    out Boolean;
      Meta      :    out JSONB_Document;
      Summary   :    out Bounded_Text;
      Toast_P   :    out TOAST_Pointer;
      Vec_P     :    out TOAST_Pointer;
      Rel_Id    :    out Optional_Doc_Id)
     with Global => null,
          Always_Terminates,
          Post   => (if not Entry_Rec.Active then not Visible)
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

      if Is_Version_Visible (Engine, Entry_Rec.Tuple_Hdr, Snapshot) then
         Visible := True;
         Meta    := Entry_Rec.Metadata;
         Summary := Entry_Rec.Summary_Text;
         Toast_P := Entry_Rec.Toast_Ptr;
         Vec_P   := Entry_Rec.Vec_Toast_Ptr;
         Rel_Id  := Entry_Rec.Related_Doc_Id;
      elsif Entry_Rec.Has_Prior_Version
        and then Is_Version_Visible (Engine, Entry_Rec.Prior_Tuple_Hdr, Snapshot)
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
      Snapshot          : in     Commit_Seq_Number;
      DB_Path           : in     Bounded_Text;
      Doc_Id            : in     RAG_Doc_Slot;
      Query_Vec         : in     Vector_Value;
      Encoding          : in     Vector_Encoding_Kind;
      Use_Meta_Filter   : in     Boolean;
      Filter_Meta       : in     JSONB_Document;
      Use_Keyword_Boost : in     Boolean;
      Keyword           : in     Bounded_Text;
      Top_K             : in     RAG_Hit_Index;
      Result            : in out RAG_Query_Result;
      IO_Err            :    out Boolean)
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
      Adj_Dist      : Non_Negative_Float;
      Vec_Buf       : TOAST_Payload_Buffer;
      Vec_Len       : TOAST_Payload_Length;
      Vec_Stat      : Engine_Status;
      Full_Vec      : Vector_Value;
      Vec_Valid     : Boolean;
      Expected_VLen : constant Valid_TOAST_Length :=
        Vector_TOAST_Byte_Length (Engine.Dim);
   begin
      IO_Err := False;

      --  Verify primary key existence in Engine.PK_Tree, or allow a deleted/updated tuple
      --  whose prior or pre-delete state is visible to an older MVCC snapshot
      Search_Key (Engine.PK_Tree, Integer_64 (Doc_Id), PK_Found, PK_Ptr);
      if not PK_Found
        and then not (Engine.Docs (Doc_Id).Active
                      and then (Engine.Docs (Doc_Id).Tuple_Hdr.Xmax > 0
                                or else Engine.Docs (Doc_Id).Has_Prior_Version))
      then
         return;
      end if;

      Resolve_Visible_Doc
        (Engine    => Engine,
         Entry_Rec => Engine.Docs (Doc_Id),
         Snapshot  => Snapshot,
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
      --  Fail closed with IO_Err if the vector TOAST chain is missing or corrupted
      if Doc_Vec_Ptr.Total_Byte_Length /= Expected_VLen
        or else Doc_Vec_Ptr.Chunk_Count not in 1 .. Max_TOAST_Chunks
        or else Doc_Vec_Ptr.Root_Overflow_Page < 10
      then
         IO_Err := True;
         return;
      end if;

      Read_TOAST_Chain (DB_Path, Doc_Vec_Ptr, Vec_Buf, Vec_Len, Vec_Stat);
      if Vec_Stat /= Status_Ok or else Vec_Len /= Expected_VLen then
         IO_Err := True;
         return;
      end if;

      Decode_Vector_TOAST (Vec_Buf, Vec_Len, Engine.Dim, Full_Vec, Vec_Valid);
      if not Vec_Valid then
         IO_Err := True;
         return;
      end if;

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
   is
      SQL_Desc     : Parsed_SQL_Descriptor;
      SQL_Stat     : Engine_Status;
      Effective_K  : RAG_Hit_Index := Top_K;
      Skip_Count   : RAG_Hit_Count := 0;
      Window_K     : RAG_Hit_Index;
      KNN_Res      : HNSW_Search_Result;
      Cand_Id      : Positive;
      Cand_IO_Err  : Boolean;
      Toast_Stat   : Engine_Status;
      Toast_Len    : TOAST_Payload_Length;
      Rel_Id       : Optional_Doc_Id;
      Rel_PK_Found : Boolean;
      Rel_PK_Ptr   : BTree_Record_Pointer;
      pragma Warnings (Off, Rel_PK_Ptr);
      Rel_Vis      : Boolean;
      Rel_Meta     : JSONB_Document;
      Rel_Sum      : Bounded_Text;
      Rel_Toast    : TOAST_Pointer;
      Rel_Vec_P    : TOAST_Pointer;
      Rel_Next     : Optional_Doc_Id;
      pragma Warnings (Off, Rel_Meta);
      pragma Warnings (Off, Rel_Sum);
      pragma Warnings (Off, Rel_Toast);
      pragma Warnings (Off, Rel_Vec_P);
      pragma Warnings (Off, Rel_Next);
      Found_Node   : Boolean;
   begin
      Result           := (others => <>);
      Top_Parent_Chunk := [others => 0];

      --  A snapshot newer than every commit the engine observed is not one of its
      --  snapshots (or predates a freeze or recovery that reset the sequence); one
      --  older than Read_Horizon may need a version that was dropped
      if Snapshot > Engine.Last_Commit_Seq or else Snapshot < Engine.Read_Horizon then
         Status := Status_Tx_Aborted;
         return;
      end if;

      --  1. Parse & validate PostgreSQL RAG SQL query
      Analyze_SQL (SQL_Query, SQL_Desc, SQL_Stat);
      if SQL_Stat /= Status_Ok or else SQL_Desc.Kind /= Stmt_Select then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Honor the SQL row window: LIMIT n / FETCH FIRST n caps the hits and OFFSET n
      --  skips the first n ranked hits. LIMIT $n / OFFSET $n cannot be bound (the
      --  only parameter of this executor is the query vector) and are rejected, as is
      --  a window reaching past the Max_RAG_Hits ranking depth.
      if SQL_Desc.Has_Param_Limit or else SQL_Desc.Has_Param_Offset then
         Status := Status_Invalid_Syntax;
         return;
      end if;
      if SQL_Desc.Has_Limit then
         if SQL_Desc.Limit_Value = 0 then
            Status := Status_Ok;
            return;
         elsif SQL_Desc.Limit_Value < Effective_K then
            Effective_K := RAG_Hit_Index (SQL_Desc.Limit_Value);
         end if;
      end if;
      if SQL_Desc.Offset_Value > Max_RAG_Hits - Effective_K then
         Status := Status_Capacity_Exceeded;
         return;
      end if;
      Skip_Count := SQL_Desc.Offset_Value;
      Window_K   := Effective_K + Skip_Count;

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
         pragma Loop_Invariant (Result.Count <= Window_K);
         pragma Loop_Invariant (Window_K = Effective_K + Skip_Count);
         Cand_Id := KNN_Res.Items (I).Doc_Id;
         if Cand_Id <= Max_RAG_Docs then
            Evaluate_Doc_Candidate
              (Engine            => Engine,
               Snapshot          => Snapshot,
               DB_Path           => DB_Path,
               Doc_Id            => Cand_Id,
               Query_Vec         => Query_Vec,
               Encoding          => Encoding,
               Use_Meta_Filter   => Use_Meta_Filter,
               Filter_Meta       => Filter_Meta,
               Use_Keyword_Boost => Use_Keyword_Boost,
               Keyword           => Keyword,
               Top_K             => Window_K,
               Result            => Result,
               IO_Err            => Cand_IO_Err);
            if Cand_IO_Err then
               Result           := (others => <>);
               Top_Parent_Chunk := [others => 0];
               Status           := Status_IO_Error;
               return;
            end if;
         end if;
      end loop;

      --  Evaluate any remaining PK_Tree-indexed documents or MVCC snapshot-visible
      --  concurrently deleted / historical docs via Cur_HNSW_Node / Prior_HNSW_Node
      --  so top-K ranking is exact across all visible snapshots
      for Slot in RAG_Doc_Slot loop
         pragma Loop_Invariant (Result.Count <= Window_K);
         pragma Loop_Invariant (Window_K = Effective_K + Skip_Count);
         if Engine.Docs (Slot).Active then
            Found_Node := False;
            for N_Idx in 1 .. Engine.Vector_Graph.Node_Count loop
               if Engine.Vector_Graph.Nodes (N_Idx).Active
                 and then Engine.Vector_Graph.Nodes (N_Idx).Doc_Id = Slot
                 and then Engine.Vector_Graph.Nodes (N_Idx).Bin_Vec.Dim = Query_Vec.Dim
               then
                  Found_Node := True;
                  exit;
               end if;
            end loop;

            if not Found_Node
              and then Engine.Docs (Slot).Cur_HNSW_Node.Active
              and then Engine.Docs (Slot).Cur_HNSW_Node.Bin_Vec.Dim = Query_Vec.Dim
            then
               Found_Node := True;
            end if;

            if not Found_Node
              and then Engine.Docs (Slot).Prior_HNSW_Node.Active
              and then Engine.Docs (Slot).Prior_HNSW_Node.Bin_Vec.Dim = Query_Vec.Dim
            then
               Found_Node := True;
            end if;

            if Found_Node then
               Evaluate_Doc_Candidate
                 (Engine            => Engine,
                  Snapshot          => Snapshot,
                  DB_Path           => DB_Path,
                  Doc_Id            => Slot,
                  Query_Vec         => Query_Vec,
                  Encoding          => Encoding,
                  Use_Meta_Filter   => Use_Meta_Filter,
                  Filter_Meta       => Filter_Meta,
                  Use_Keyword_Boost => Use_Keyword_Boost,
                  Keyword           => Keyword,
                  Top_K             => Window_K,
                  Result            => Result,
                  IO_Err            => Cand_IO_Err);
               if Cand_IO_Err then
                  Result           := (others => <>);
                  Top_Parent_Chunk := [others => 0];
                  Status           := Status_IO_Error;
                  return;
               end if;
            end if;
         end if;
      end loop;

      --  Drop the OFFSET hits: the window keeps ranks Skip_Count + 1 .. Window_K
      if Skip_Count > 0 then
         if Result.Count <= Skip_Count then
            Result := (others => <>);
         else
            for I in 1 .. Result.Count - Skip_Count loop
               pragma Loop_Invariant (Result.Count in Skip_Count + 1 .. Window_K);
               Result.Hits (I) := Result.Hits (I + Skip_Count);
            end loop;
            Result.Count := Result.Count - Skip_Count;
         end if;
      end if;
      pragma Assert (Result.Count <= Effective_K);

      --  4. Stage 3: Fetch full Parent-Document Chunk from 4KB TOAST Overflow Pages
      --     and check 1-hop GraphRAG neighbor for the #1 hit of the window
      if Result.Count > 0 then
         if Result.Hits (1).Toast_Ptr.Total_Byte_Length not in 1 .. Max_TOAST_Payload_Bytes
           or else Result.Hits (1).Toast_Ptr.Chunk_Count not in 1 .. Max_TOAST_Chunks
           or else Result.Hits (1).Toast_Ptr.Root_Overflow_Page < 10
         then
            Result           := (others => <>);
            Top_Parent_Chunk := [others => 0];
            Status           := Status_IO_Error;
            return;
         end if;

         Read_TOAST_Chain
           (DB_Path => DB_Path,
            Ptr     => Result.Hits (1).Toast_Ptr,
            Payload => Top_Parent_Chunk,
            Length  => Toast_Len,
            Status  => Toast_Stat);
         if Toast_Stat /= Status_Ok
           or else Toast_Len /= Result.Hits (1).Toast_Ptr.Total_Byte_Length
         then
            Result           := (others => <>);
            Top_Parent_Chunk := [others => 0];
            Status           := Status_IO_Error;
            return;
         end if;
         Result.Top_Parent_Bytes := Toast_Len;

         Rel_Id := Result.Hits (1).Related_Doc_Id;
         --  Reject self-loops (Rel_Id = Result.Hits (1).Doc_Id) and require PK_Tree
         --  or MVCC snapshot visibility for 1-hop GraphRAG neighbor
         if Rel_Id in RAG_Doc_Slot and then Rel_Id /= Result.Hits (1).Doc_Id then
            Search_Key (Engine.PK_Tree, Integer_64 (Rel_Id), Rel_PK_Found, Rel_PK_Ptr);
            if Rel_PK_Found
              or else (Engine.Docs (Rel_Id).Active
                       and then (Engine.Docs (Rel_Id).Tuple_Hdr.Xmax > 0
                                 or else Engine.Docs (Rel_Id).Has_Prior_Version))
            then
               Resolve_Visible_Doc
                 (Engine    => Engine,
                  Entry_Rec => Engine.Docs (Rel_Id),
                  Snapshot  => Snapshot,
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
      end if;

      Status := Status_Ok;
   end Execute_Hybrid_RAG_Query;

end Nhe_O.RAG;
