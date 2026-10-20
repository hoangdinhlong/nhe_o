--  Formally verified C ABI / FFI SDK Implementation Body for Nhe_O
--  (ADR-005 / BR-007)
pragma SPARK_Mode (On);

with Nhe_O.IO;     use Nhe_O.IO;
with Nhe_O.SQL;    use Nhe_O.SQL;
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

   --  Copy Bounded_Ident into C_Ident_Buf writing ONLY 1 .. Id.Length (+ trailing NUL if room)
   procedure From_Bounded_Ident
     (Id      : in     Bounded_Ident;
      Out_Buf : in out C_Ident_Buf;
      Out_Len :    out int)
     with Global => null,
          Always_Terminates
   is
   begin
      for I in 1 .. Id.Length loop
         Out_Buf (size_t (I)) := To_C (Id.Data (I));
      end loop;
      if Id.Length < Max_Ident_Len then
         Out_Buf (size_t (Id.Length + 1)) := nul;
      end if;
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

   --  Copy Bounded_Text into C_Text_Buf writing ONLY 1 .. Txt.Length (+ trailing NUL if room)
   procedure From_Bounded_Text
     (Txt     : in     Bounded_Text;
      Out_Buf : in out C_Text_Buf;
      Out_Len :    out int)
     with Global => null,
          Always_Terminates
   is
   begin
      for I in 1 .. Txt.Length loop
         pragma Loop_Invariant (I in 1 .. Txt.Length);
         Out_Buf (size_t (I)) := To_C (Txt.Data (I));
      end loop;
      if Txt.Length < Max_Text_Len then
         Out_Buf (size_t (Txt.Length + 1)) := nul;
      end if;
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
   begin
      G_DB_Path  := Make_Text ("/tmp/nhe_o_c_api.db");
      G_WAL_Path := Make_Text ("/tmp/nhe_o_c_api.wal");
      Delete_File_If_Exists (G_DB_Path);
      Delete_File_If_Exists (G_WAL_Path);
      G_Next_Tx     := 1;
      G_Next_KV_Seq := 1;
      G_KV_Store    := (others => <>);
      G_Broker      := (others => <>);
      Init_RAG_Engine (G_RAG_Engine, 3);
      G_Initialized := True;
      Out_Status    := C_Status_Ok;
   end C_Init;

   procedure C_Init_With_Paths
     (DB_Path_Buf  : in     C_Text_Buf;
      DB_Path_Len  : in     int;
      WAL_Path_Buf : in     C_Text_Buf;
      WAL_Path_Len : in     int;
      Dim          : in     int;
      Out_Status   :    out int)
   is
      DB_P          : Bounded_Text;
      WAL_P         : Bounded_Text;
      WAL_Exists    : Boolean;
      DB_Exists     : Boolean;
      Probe_Frame   : WAL_Frame_Buffer;
      Probe_WAL_Ok  : Boolean;
      Probe_EOF     : Boolean;
      Probe_Page    : Page_Buffer;
      Probe_DB_Ok   : Boolean;
      Probe_DB_EOF  : Boolean;
      Probe_P0_Ok   : Boolean;
      Probe_P0_EOF  : Boolean;
      Frame_Tx      : Valid_Tx_Id;
      Frame_Pg      : Valid_Page_Id;
      KV_Replayed   : Natural;
      KV_Stat       : Engine_Status;
      WAL_Replayed   : Natural;
      Max_Rec_Tx     : Tx_Id;
      Max_Seen_Tx    : Tx_Id := 0;
      Max_Seen_KV_Tx : Tx_Id := 0;
      Probe_Slot_Pg  : Slotted_Page;
      Probe_Slot_Ok  : Boolean;
      WAL_Stat       : Engine_Status;
      RAG_Stat       : Engine_Status;
      pragma Warnings (Off, Probe_Frame);
      pragma Warnings (Off, Probe_Page);
      pragma Warnings (Off, Probe_P0_Ok);
      pragma Warnings (Off, Frame_Pg);
      pragma Warnings (Off, KV_Replayed);
      pragma Warnings (Off, WAL_Replayed);
   begin
      G_Initialized := False;
      G_Next_Tx     := 1;
      G_Next_KV_Seq := 1;
      G_DB_Path     := Make_Text ("/tmp/nhe_o_c_api.db");
      G_WAL_Path    := Make_Text ("/tmp/nhe_o_c_api.wal");
      G_KV_Store    := (others => <>);
      G_Broker      := (others => <>);
      Init_RAG_Engine (G_RAG_Engine, 3);

      if DB_Path_Len <= 0 or else DB_Path_Len > int (Max_Text_Len)
        or else WAL_Path_Len <= 0 or else WAL_Path_Len > int (Max_Text_Len)
        or else Dim not in 1 .. int (Max_Vector_Dim)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      DB_P  := To_Bounded_Text (DB_Path_Buf, Text_Length (DB_Path_Len));
      WAL_P := To_Bounded_Text (WAL_Path_Buf, Text_Length (WAL_Path_Len));

      if Has_Embedded_NUL (DB_P)
        or else Has_Embedded_NUL (WAL_P)
        or else Equal_Text (DB_P, WAL_P)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      G_DB_Path  := DB_P;
      G_WAL_Path := WAL_P;
      Init_RAG_Engine (G_RAG_Engine, Vector_Dim (Dim));

      --  Recover existing WAL / DB state when files already exist on disk
      --  and propagate any torn frame/page or CRC32 failure
      Check_File_Exists (G_WAL_Path, WAL_Exists);
      if WAL_Exists then
         Read_WAL_Frame (G_WAL_Path, 0, Probe_Frame, Probe_WAL_Ok, Probe_EOF);
         if not Probe_WAL_Ok and then not Probe_EOF then
            Out_Status := C_Status_IO_Error;
            return;
         elsif Probe_WAL_Ok then
            Recover_KV_From_WAL
              (Store        => G_KV_Store,
               WAL_Path     => G_WAL_Path,
               Now          => 0,
               Max_Frames   => Max_WAL_Scan_Frames,
               Replayed_Ops => KV_Replayed,
               Status       => KV_Stat);
            if KV_Stat /= Status_Ok then
               G_KV_Store := (others => <>);
               Out_Status := To_C_Status (KV_Stat);
               return;
            end if;

            Redo_WAL_Recovery
              (DB_Path          => G_DB_Path,
               WAL_Path         => G_WAL_Path,
               Max_Frames       => Max_WAL_Scan_Frames,
               Replayed_Count   => WAL_Replayed,
               Max_Recovered_Tx => Max_Rec_Tx,
               Status           => WAL_Stat);
            if WAL_Stat /= Status_Ok then
               G_KV_Store := (others => <>);
               Out_Status := To_C_Status (WAL_Stat);
               return;
            end if;

            if Max_Rec_Tx > Max_Seen_Tx then
               Max_Seen_Tx := Max_Rec_Tx;
            end if;

            --  Scan all valid WAL frames for max transaction and KV sequence IDs
            for Idx in 0 .. Max_WAL_Scan_Frames - 1 loop
               pragma Loop_Invariant (G_WAL_Path.Length > 0);
               Read_WAL_Frame (G_WAL_Path, Idx, Probe_Frame, Probe_WAL_Ok);
               exit when not Probe_WAL_Ok;
               if Verify_WAL_Frame (Probe_Frame) then
                  Decode_WAL_Frame (Probe_Frame, Frame_Tx, Frame_Pg, Probe_Page);
                  if Get_WAL_Frame_Kind (Probe_Frame) = WAL_Frame_KV then
                     if Frame_Tx > Max_Seen_KV_Tx then
                        Max_Seen_KV_Tx := Frame_Tx;
                     end if;
                  else
                     if Frame_Tx > Max_Seen_Tx then
                        Max_Seen_Tx := Frame_Tx;
                     end if;
                  end if;
               end if;
            end loop;
         end if;
      end if;

      Check_File_Exists (G_DB_Path, DB_Exists);
      if DB_Exists then
         Read_Page (G_DB_Path, 1, Probe_Page, Probe_DB_Ok, Probe_DB_EOF);
         if not Probe_DB_Ok and then not Probe_DB_EOF then
            G_KV_Store := (others => <>);
            Out_Status := C_Status_IO_Error;
            return;
         elsif not Probe_DB_Ok and then Probe_DB_EOF then
            --  Allow a 0-byte empty placeholder .db file, but reject a truncated 1-page (4096 B) .db file
            Read_Page (G_DB_Path, 0, Probe_Page, Probe_P0_Ok, Probe_P0_EOF);
            if not Probe_P0_EOF then
               G_KV_Store := (others => <>);
               Out_Status := C_Status_IO_Error;
               return;
            end if;
         elsif Probe_DB_Ok then
            Decode_Slotted_Page (Probe_Page, Probe_Slot_Pg, Probe_Slot_Ok);
            if Probe_Slot_Ok and then Probe_Slot_Pg.Page_LSN_Tx > Max_Seen_Tx then
               Max_Seen_Tx := Probe_Slot_Pg.Page_LSN_Tx;
            end if;

            Recover_RAG_Engine
              (Engine   => G_RAG_Engine,
               Dim      => Vector_Dim (Dim),
               DB_Path  => G_DB_Path,
               WAL_Path => G_WAL_Path,
               Status   => RAG_Stat);
            if RAG_Stat /= Status_Ok then
               G_KV_Store := (others => <>);
               Init_RAG_Engine (G_RAG_Engine, 3);
               Out_Status := To_C_Status (RAG_Stat);
               return;
            end if;

            for Slot in RAG_Doc_Slot loop
               pragma Loop_Invariant (Max_Seen_Tx <= Max_Tx_Id);
               if G_RAG_Engine.Docs (Slot).Active then
                  if G_RAG_Engine.Docs (Slot).Tuple_Hdr.Xmin > Max_Seen_Tx then
                     Max_Seen_Tx := G_RAG_Engine.Docs (Slot).Tuple_Hdr.Xmin;
                  end if;
                  if G_RAG_Engine.Docs (Slot).Tuple_Hdr.Xmax > Max_Seen_Tx then
                     Max_Seen_Tx := G_RAG_Engine.Docs (Slot).Tuple_Hdr.Xmax;
                  end if;
               end if;
            end loop;
         end if;
      end if;

      if Max_Seen_Tx = Max_Tx_Id or else Max_Seen_KV_Tx = Max_Tx_Id then
         G_KV_Store := (others => <>);
         Init_RAG_Engine (G_RAG_Engine, 3);
         Out_Status := C_Status_Capacity_Exceeded;
         return;
      end if;

      pragma Assert (Max_Seen_Tx < Max_Tx_Id and then Max_Seen_KV_Tx < Max_Tx_Id);
      G_Next_Tx     := Valid_Tx_Id (Max_Seen_Tx + 1);
      G_Next_KV_Seq := Valid_Tx_Id (Max_Seen_KV_Tx + 1);
      G_Initialized := True;
      Out_Status    := C_Status_Ok;
   end C_Init_With_Paths;

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

      if L2 <= 1.0e30 then
         Out_L2_Dist := C_float (L2);
      end if;
      Out_Cos_Dist := C_float (Cos);
      Out_Hamming  := int (Ham);
      Out_Status   := C_Status_Ok;
   end C_Vector_Distance_3D;

   procedure C_Vector_Distance_ND
     (A_Buf        : in     C_Vec_Buf;
      B_Buf        : in     C_Vec_Buf;
      Dim          : in     int;
      Out_L2_Dist  :    out C_float;
      Out_Cos_Dist :    out C_float;
      Out_Hamming  :    out int;
      Out_Status   :    out int)
   is
      VA, VB : Vector_Value;
      BA, BB : Quantized_Binary_Vector;
      L2     : Non_Negative_Float;
      Cos    : Float;
      Ham    : Natural;
      D      : Vector_Dim;
   begin
      Out_L2_Dist  := 0.0;
      Out_Cos_Dist := 0.0;
      Out_Hamming  := 0;

      if Dim not in 1 .. int (Max_Vector_Dim) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      D      := Vector_Dim (Dim);
      VA.Dim := D;
      VB.Dim := D;

      for I in 1 .. D loop
         pragma Loop_Invariant (VA.Dim = D and then VB.Dim = D);
         if not (A_Buf (size_t (I)) in -1.0e6 .. 1.0e6
                 and then B_Buf (size_t (I)) in -1.0e6 .. 1.0e6)
         then
            Out_Status := C_Status_Invalid_Arg;
            return;
         end if;
         VA.Elements (I) := Float (A_Buf (size_t (I)));
         VB.Elements (I) := Float (B_Buf (size_t (I)));
      end loop;

      L2  := L2_Distance (VA, VB);
      Cos := Cosine_Distance (VA, VB);
      BA  := Quantize_To_Binary (VA);
      BB  := Quantize_To_Binary (VB);
      Ham := Hamming_Distance (BA, BB);

      if L2 <= 1.0e30 then
         Out_L2_Dist := C_float (L2);
      end if;
      Out_Cos_Dist := C_float (Cos);
      Out_Hamming  := int (Ham);
      Out_Status   := C_Status_Ok;
   end C_Vector_Distance_ND;

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
      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Val_Len < 0 or else Val_Len > int (Max_Text_Len)
        or else Now_Sec < 0
        or else TTL_Sec < 0
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

      if G_WAL_Path.Length > 0 then
         if G_Next_KV_Seq = Max_Tx_Id then
            Out_Status := C_Status_Capacity_Exceeded;
            return;
         end if;
         declare
            WAL_Stat : Engine_Status;
         begin
            Set_Durable
              (Store    => G_KV_Store,
               WAL_Path => G_WAL_Path,
               Tx       => G_Next_KV_Seq,
               Key      => Key,
               Val      => Val,
               Now      => Now_Sec,
               Has_TTL  => Has_TTL,
               TTL_Sec  => TTL_Val,
               Status   => WAL_Stat);
            if WAL_Stat = Status_Ok and then G_Next_KV_Seq < Max_Tx_Id then
               G_Next_KV_Seq := G_Next_KV_Seq + 1;
            end if;
            Out_Status := To_C_Status (WAL_Stat);
         end;
      else
         Set (G_KV_Store, Key, Val, Now_Sec, Has_TTL, TTL_Val);
         Out_Status := C_Status_Ok;
      end if;
   end C_KV_Set;

   procedure C_KV_Get
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      Out_Val_Buf : in out C_Text_Buf;
      Out_Val_Len :    out int;
      Out_Status  :    out int)
   is
      Key    : Bounded_Ident;
      Val    : Bounded_Text;
      Status : Engine_Status;
   begin
      Out_Val_Len := 0;

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

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

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      if G_WAL_Path.Length > 0 then
         if G_Next_KV_Seq = Max_Tx_Id then
            Out_Status := C_Status_Capacity_Exceeded;
            return;
         end if;
         declare
            WAL_Stat : Engine_Status;
         begin
            Del_Durable
              (Store    => G_KV_Store,
               WAL_Path => G_WAL_Path,
               Tx       => G_Next_KV_Seq,
               Key      => Key,
               Removed  => Removed,
               Status   => WAL_Stat);
            if Removed and then WAL_Stat = Status_Ok and then G_Next_KV_Seq < Max_Tx_Id then
               G_Next_KV_Seq := G_Next_KV_Seq + 1;
            end if;
            Out_Removed := (if Removed then 1 else 0);
            Out_Status  := To_C_Status (WAL_Stat);
         end;
      else
         Del (G_KV_Store, Key, Removed);
         Out_Removed := (if Removed then 1 else 0);
         Out_Status  := C_Status_Ok;
      end if;
   end C_KV_Del;

   procedure C_KV_Exists
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Now_Sec    : in     Integer_64;
      Out_Exists :    out int;
      Out_Status :    out int)
   is
      Key : Bounded_Ident;
   begin
      Out_Exists := 0;

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key        := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Out_Exists := (if Exists (G_KV_Store, Key, Now_Sec) then 1 else 0);
      Out_Status := C_Status_Ok;
   end C_KV_Exists;

   procedure C_KV_Expire
     (Key_Buf     : in     C_Ident_Buf;
      Key_Len     : in     int;
      Now_Sec     : in     Integer_64;
      TTL_Sec     : in     Integer_64;
      Out_Updated :    out int;
      Out_Status  :    out int)
   is
      Key     : Bounded_Ident;
      Updated : Boolean;
      Status  : Engine_Status;
      Tx      : Valid_Tx_Id;
   begin
      Out_Updated := 0;

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Now_Sec < 0
        or else TTL_Sec <= 0
        or else Now_Sec > Epoch_Seconds'Last - TTL_Sec
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      if G_WAL_Path.Length > 0 then
         if G_Next_KV_Seq = Max_Tx_Id then
            Out_Status := C_Status_Capacity_Exceeded;
            return;
         end if;
         Tx := G_Next_KV_Seq;
         Expire_Durable
           (Store    => G_KV_Store,
            WAL_Path => G_WAL_Path,
            Tx       => Tx,
            Key      => Key,
            Now      => Now_Sec,
            TTL_Sec  => TTL_Sec,
            Updated  => Updated,
            Status   => Status);
         if Updated and then Status = Status_Ok and then Tx < Max_Tx_Id then
            G_Next_KV_Seq := Tx + 1;
         end if;
         Out_Updated := (if Updated then 1 else 0);
         Out_Status  := To_C_Status (Status);
      else
         Expire (G_KV_Store, Key, Now_Sec, TTL_Sec, Updated);
         Out_Updated := (if Updated then 1 else 0);
         Out_Status  := C_Status_Ok;
      end if;
   end C_KV_Expire;

   procedure C_KV_TTL
     (Key_Buf    : in     C_Ident_Buf;
      Key_Len    : in     int;
      Now_Sec    : in     Integer_64;
      Out_TTL    :    out Integer_64;
      Out_Status :    out int)
   is
      Key : Bounded_Ident;
   begin
      Out_TTL := -2;

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key        := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      Out_TTL    := Remaining_TTL (G_KV_Store, Key, Now_Sec);
      Out_Status := C_Status_Ok;
   end C_KV_TTL;

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
      Tx     : Valid_Tx_Id;
   begin
      Out_New_Val := 0;

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Key_Len <= 0 or else Key_Len > int (Max_Ident_Len)
        or else Now_Sec < 0
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Key := To_Bounded_Ident (Key_Buf, Ident_Length (Key_Len));
      if G_WAL_Path.Length > 0 then
         if G_Next_KV_Seq = Max_Tx_Id then
            Out_Status := C_Status_Capacity_Exceeded;
            return;
         end if;
         Tx := G_Next_KV_Seq;
         Incr_By_Durable
           (Store     => G_KV_Store,
            WAL_Path  => G_WAL_Path,
            Tx        => Tx,
            Key       => Key,
            Delta_Val => Delta_Val,
            Now       => Now_Sec,
            New_Val   => Out_New_Val,
            Status    => Status);
         if Status = Status_Ok and then Tx < Max_Tx_Id then
            G_Next_KV_Seq := Tx + 1;
         end if;
         Out_Status := To_C_Status (Status);
      else
         Incr_By (G_KV_Store, Key, Delta_Val, Now_Sec, Out_New_Val, Status);
         Out_Status := To_C_Status (Status);
      end if;
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

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

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

   procedure C_PubSub_Unsubscribe
     (Sub_Id     : in     int;
      Out_Status :    out int)
   is
   begin
      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Sub_Id not in int (Subscriber_Id'First) .. int (Subscriber_Id'Last) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      Unsubscribe (G_Broker, Subscriber_Id (Sub_Id));
      Out_Status := C_Status_Ok;
   end C_PubSub_Unsubscribe;

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

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

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
      Out_Chan_Buf    : in out C_Ident_Buf;
      Out_Chan_Len    :    out int;
      Out_Payload_Buf : in out C_Text_Buf;
      Out_Payload_Len :    out int;
      Out_Found       :    out int;
      Out_Status      :    out int)
   is
      Msg   : PubSub_Message;
      Found : Boolean;
   begin
      Out_Chan_Len    := 0;
      Out_Payload_Len := 0;
      Out_Found       := 0;

      if not G_Initialized then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

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
      Vec_Buf : C_Vec_Buf := [others => 0.0];
   begin
      Vec_Buf (1) := VX;
      Vec_Buf (2) := VY;
      Vec_Buf (3) := VZ;
      C_RAG_Ingest_ND
        (Doc_Id         => Doc_Id,
         Summary_Buf    => Summary_Buf,
         Summary_Len    => Summary_Len,
         Vec_Buf        => Vec_Buf,
         Dim            => 3,
         Related_Doc_Id => Related_Doc_Id,
         Out_Status     => Out_Status);
   end C_RAG_Ingest_3D;

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
   is
      Tx             : Transaction_Context;
      Staging        : Tx_Notification_Buffer := (others => <>);
      Meta           : JSONB_Document         := (others => <>);
      Meta_Raw       : Bounded_Text;
      Summary        : Bounded_Text;
      Vec            : Vector_Value;
      D              : Vector_Dim;
      Parent_Payload : TOAST_Payload_Buffer   := [others => 0];
      Eff_Parent_Len : Valid_TOAST_Length     := 128;
      Commit_Page    : Page_Buffer;
      Saved_Engine   : constant RAG_Engine    := G_RAG_Engine;
      Status         : Engine_Status;
      Commit_Status  : Engine_Status;
      Flushed_Count  : Natural;
      pragma Warnings (Off, Flushed_Count);
      pragma Warnings (Off, Status);
      pragma Warnings (Off, Tx);
      pragma Warnings (Off, Staging);
   begin
      if not G_Initialized
        or else G_DB_Path.Length = 0
        or else G_WAL_Path.Length = 0
      then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Doc_Id not in int (RAG_Doc_Slot'First) .. int (RAG_Doc_Slot'Last)
        or else Meta_JSON_Len < 0 or else Meta_JSON_Len > int (Max_Text_Len)
        or else Summary_Len < 0 or else Summary_Len > int (Max_Text_Len)
        or else Parent_Len < 0 or else Parent_Len > int (Max_TOAST_Payload_Bytes)
        or else Dim not in 1 .. int (Max_Vector_Dim)
        or else Related_Doc_Id not in int (Optional_Doc_Id'First) .. int (Optional_Doc_Id'Last)
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      D := Vector_Dim (Dim);
      if G_RAG_Engine.Dim /= D or else G_RAG_Engine.Vector_Graph.Dim /= D then
         Out_Status := C_Status_Dimension_Mismatch;
         return;
      end if;

      Vec.Dim := D;
      for I in 1 .. D loop
         pragma Loop_Invariant (Vec.Dim = D);
         if not (Vec_Buf (size_t (I)) in -1.0e6 .. 1.0e6) then
            Out_Status := C_Status_Invalid_Arg;
            return;
         end if;
         Vec.Elements (I) := Float (Vec_Buf (size_t (I)));
      end loop;

      if G_Next_Tx = Max_Tx_Id
        or else G_RAG_Engine.PK_Tree.Node_Count not in 1 .. Max_BTree_Nodes
        or else G_RAG_Engine.PK_Tree.Root_Node not in 1 .. G_RAG_Engine.PK_Tree.Node_Count
        or else G_RAG_Engine.Next_TOAST_Pg > Max_Safe_TOAST_Page
      then
         Out_Status := C_Status_Capacity_Exceeded;
         return;
      end if;

      if Meta_JSON_Len > 0 then
         Meta_Raw := To_Bounded_Text (Meta_JSON_Buf, Text_Length (Meta_JSON_Len));
         Parse_JSONB (Meta_Raw, Meta, Status);
         if Status /= Status_Ok then
            Out_Status := To_C_Status (Status);
            return;
         end if;
      else
         Put_Field (Meta, Make_Ident ("source"), Make_Text ("c_api"), JSONB_String, Status);
      end if;

      Summary := To_Bounded_Text (Summary_Buf, Text_Length (Summary_Len));

      if Parent_Len > 0 then
         Eff_Parent_Len := Valid_TOAST_Length (Parent_Len);
         for I in 1 .. Eff_Parent_Len loop
            pragma Loop_Invariant (I in 1 .. Eff_Parent_Len);
            Parent_Payload (I) := Byte (Character'Pos (To_Ada (Parent_Buf (size_t (I)))));
         end loop;
      elsif Summary.Length > 0 then
         Eff_Parent_Len := Summary.Length;
         for I in 1 .. Summary.Length loop
            pragma Loop_Invariant (I in 1 .. Summary.Length);
            Parent_Payload (I) := Byte (Character'Pos (Summary.Data (I)));
         end loop;
      end if;

      Begin_Tx (G_Next_Tx, Tx);

      Ingest_Document
        (Engine         => G_RAG_Engine,
         Ctx            => Tx,
         DB_Path        => G_DB_Path,
         WAL_Path       => G_WAL_Path,
         Staging        => Staging,
         Doc_Id         => RAG_Doc_Slot (Doc_Id),
         Metadata       => Meta,
         Summary_Text   => Summary,
         Embedding      => Vec,
         Parent_Payload => Parent_Payload,
         Parent_Length  => Eff_Parent_Len,
         Related_Doc_Id => Optional_Doc_Id (Related_Doc_Id),
         Layer_Hint     => 1,
         Status         => Status);

      if Status /= Status_Ok then
         G_RAG_Engine := Saved_Engine;
         Set_CLOG_State (G_RAG_Engine.CLOG, Tx.Id, Tx_Aborted);
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Rollback_Tx (Tx);
         Discard_Staged_Notifications (Tx, Staging);
         pragma Warnings (GNATprove, On, "statement has no effect");
         Out_Status := To_C_Status (Status);
         return;
      end if;

      Build_RAG_Slotted_Page (G_RAG_Engine, Tx.Id, Commit_Page);
      Commit_Tx (Tx, G_DB_Path, G_WAL_Path, 1, Commit_Page, Commit_Status);
      if Commit_Status = Status_Ok then
         Set_CLOG_State (G_RAG_Engine.CLOG, Tx.Id, Tx_Committed);
         Flush_Committed_Notifications (Tx, Staging, G_Broker, Flushed_Count);
      else
         G_RAG_Engine := Saved_Engine;
         Set_CLOG_State (G_RAG_Engine.CLOG, Tx.Id, Tx_Aborted);
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Discard_Staged_Notifications (Tx, Staging);
         pragma Warnings (GNATprove, On, "statement has no effect");
      end if;

      Out_Status := To_C_Status (Commit_Status);
   end C_RAG_Ingest_Full_ND;

   procedure C_RAG_Ingest_ND
     (Doc_Id         : in     int;
      Summary_Buf    : in     C_Text_Buf;
      Summary_Len    : in     int;
      Vec_Buf        : in     C_Vec_Buf;
      Dim            : in     int;
      Related_Doc_Id : in     int;
      Out_Status     :    out int)
   is
      Empty_Meta : constant C_Text_Buf := [others => nul];
      Parent_Buf : C_Toast_Buf         := [others => nul];
      Copy_Len   : Natural;
   begin
      if Summary_Len > 0 and then Summary_Len <= int (Max_Text_Len) then
         Copy_Len := Natural (Summary_Len);
         for I in 1 .. Copy_Len loop
            Parent_Buf (size_t (I)) := Summary_Buf (size_t (I));
         end loop;
      else
         Copy_Len := 0;
      end if;

      C_RAG_Ingest_Full_ND
        (Doc_Id         => Doc_Id,
         Meta_JSON_Buf  => Empty_Meta,
         Meta_JSON_Len  => 0,
         Summary_Buf    => Summary_Buf,
         Summary_Len    => Summary_Len,
         Parent_Buf     => Parent_Buf,
         Parent_Len     => int (Copy_Len),
         Vec_Buf        => Vec_Buf,
         Dim            => Dim,
         Related_Doc_Id => Related_Doc_Id,
         Out_Status     => Out_Status);
   end C_RAG_Ingest_ND;

   procedure C_RAG_Delete
     (Doc_Id     : in     int;
      Out_Status :    out int)
   is
      Tx            : Transaction_Context;
      Commit_Page   : Page_Buffer;
      Saved_Engine  : constant RAG_Engine := G_RAG_Engine;
      Status        : Engine_Status;
      Commit_Status : Engine_Status;
      pragma Warnings (Off, Tx);
   begin
      if not G_Initialized
        or else G_DB_Path.Length = 0
        or else G_WAL_Path.Length = 0
      then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Doc_Id not in int (RAG_Doc_Slot'First) .. int (RAG_Doc_Slot'Last) then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      if G_Next_Tx = Max_Tx_Id
        or else not Is_Valid_RAG_Engine (G_RAG_Engine)
      then
         Out_Status := C_Status_Capacity_Exceeded;
         return;
      end if;

      Begin_Tx (G_Next_Tx, Tx);
      Delete_Document
        (Engine   => G_RAG_Engine,
         Ctx      => Tx,
         DB_Path  => G_DB_Path,
         WAL_Path => G_WAL_Path,
         Doc_Id   => RAG_Doc_Slot (Doc_Id),
         Status   => Status);

      if Status /= Status_Ok then
         G_RAG_Engine := Saved_Engine;
         Set_CLOG_State (G_RAG_Engine.CLOG, Tx.Id, Tx_Aborted);
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Rollback_Tx (Tx);
         pragma Warnings (GNATprove, On, "statement has no effect");
         Out_Status := To_C_Status (Status);
         return;
      end if;

      Build_RAG_Slotted_Page (G_RAG_Engine, Tx.Id, Commit_Page);
      Commit_Tx (Tx, G_DB_Path, G_WAL_Path, 1, Commit_Page, Commit_Status);
      if Commit_Status = Status_Ok then
         Set_CLOG_State (G_RAG_Engine.CLOG, Tx.Id, Tx_Committed);
      else
         G_RAG_Engine := Saved_Engine;
         Set_CLOG_State (G_RAG_Engine.CLOG, Tx.Id, Tx_Aborted);
      end if;

      Out_Status := To_C_Status (Commit_Status);
   end C_RAG_Delete;

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
      Q_Buf      : C_Vec_Buf  := [others => 0.0];
      Parent_Buf : C_Text_Buf := [others => nul];
      pragma Warnings (Off, Parent_Buf);
   begin
      Q_Buf (1) := QX;
      Q_Buf (2) := QY;
      Q_Buf (3) := QZ;
      C_RAG_Query_ND
        (Query_Vec_Buf    => Q_Buf,
         Dim              => 3,
         Encoding_Mode    => Encoding_Mode,
         Keyword_Buf      => Keyword_Buf,
         Keyword_Len      => Keyword_Len,
         Top_K            => Top_K,
         Out_Hit_Count    => Out_Hit_Count,
         Out_Top_Doc_Id   => Out_Top_Doc_Id,
         Out_Top_Distance => Out_Top_Distance,
         Out_Parent_Buf   => Parent_Buf,
         Out_Parent_Len   => Out_Parent_Bytes,
         Out_Graph_Hit    => Out_Graph_Hit,
         Out_Status       => Out_Status);
   end C_RAG_Query_3D;

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
   is
      SQL_Query   : constant Bounded_Text :=
        Make_Text ("SELECT id, chunk FROM rag_docs ORDER BY emb <-> $1;");
      Filter_Meta : JSONB_Document        := (others => <>);
      Filter_Raw  : Bounded_Text;
      Use_Filter  : Boolean               := False;
      Query_Vec   : Vector_Value;
      D           : Vector_Dim;
      Encoding    : Vector_Encoding_Kind;
      Keyword     : Bounded_Text;
      Use_Keyword : Boolean;
      Result      : RAG_Query_Result;
      Top_Parent  : TOAST_Payload_Buffer;
      Copy_Len    : Natural;
      Status      : Engine_Status;
   begin
      Out_Hit_Count    := 0;
      Out_Top_Doc_Id   := 0;
      Out_Top_Distance := 0.0;
      Out_Parent_Len   := 0;
      Out_Graph_Hit    := 0;

      if not G_Initialized or else G_DB_Path.Length = 0 then
         Out_Status := C_Status_Not_Initialized;
         return;
      end if;

      if Filter_JSON_Len < 0 or else Filter_JSON_Len > int (Max_Text_Len)
        or else Keyword_Len < 0 or else Keyword_Len > int (Max_Text_Len)
        or else Dim not in 1 .. int (Max_Vector_Dim)
        or else Top_K not in int (RAG_Hit_Index'First) .. int (RAG_Hit_Index'Last)
        or else Encoding_Mode not in 0 .. 2
      then
         Out_Status := C_Status_Invalid_Arg;
         return;
      end if;

      D := Vector_Dim (Dim);
      if G_RAG_Engine.Dim /= D
        or else G_RAG_Engine.Vector_Graph.Dim /= D
        or else G_RAG_Engine.PK_Tree.Node_Count not in 1 .. Max_BTree_Nodes
        or else G_RAG_Engine.PK_Tree.Root_Node not in 1 .. G_RAG_Engine.PK_Tree.Node_Count
      then
         Out_Status := C_Status_Dimension_Mismatch;
         return;
      end if;

      if Filter_JSON_Len > 0 then
         Filter_Raw := To_Bounded_Text (Filter_JSON_Buf, Text_Length (Filter_JSON_Len));
         Parse_JSONB (Filter_Raw, Filter_Meta, Status);
         if Status /= Status_Ok then
            Out_Status := To_C_Status (Status);
            return;
         end if;
         Use_Filter := True;
      end if;

      Query_Vec.Dim := D;
      for I in 1 .. D loop
         pragma Loop_Invariant (Query_Vec.Dim = D);
         if not (Query_Vec_Buf (size_t (I)) in -1.0e6 .. 1.0e6) then
            Out_Status := C_Status_Invalid_Arg;
            return;
         end if;
         Query_Vec.Elements (I) := Float (Query_Vec_Buf (size_t (I)));
      end loop;

      case Encoding_Mode is
         when 0      => Encoding := Encoding_Float32;
         when 1      => Encoding := Encoding_Int8_SQ8;
         when others => Encoding := Encoding_Binary_1Bit;
      end case;

      Keyword     := To_Bounded_Text (Keyword_Buf, Text_Length (Keyword_Len));
      Use_Keyword := Keyword.Length > 0;

      Execute_Hybrid_RAG_Query
        (Engine            => G_RAG_Engine,
         Snapshot          => G_Next_Tx,
         DB_Path           => G_DB_Path,
         SQL_Query         => SQL_Query,
         Query_Vec         => Query_Vec,
         Encoding          => Encoding,
         Use_Meta_Filter   => Use_Filter,
         Filter_Meta       => Filter_Meta,
         Use_Keyword_Boost => Use_Keyword,
         Keyword           => Keyword,
         Top_K             => RAG_Hit_Index (Top_K),
         Result            => Result,
         Top_Parent_Chunk  => Top_Parent,
         Status            => Status);

      if Status = Status_Ok then
         Out_Hit_Count  := int (Result.Count);
         Out_Parent_Len := int (Result.Top_Parent_Bytes);
         Out_Graph_Hit  := (if Result.Graph_Neighbor_Hit then 1 else 0);

         Copy_Len := Natural'Min (Max_TOAST_Payload_Bytes, Result.Top_Parent_Bytes);
         for I in 1 .. Copy_Len loop
            Out_Parent_Buf (size_t (I)) :=
              To_C (Character'Val (Natural (Top_Parent (I))));
         end loop;
         if Copy_Len < Max_TOAST_Payload_Bytes then
            Out_Parent_Buf (size_t (Copy_Len + 1)) := nul;
         end if;

         if Result.Count >= 1 then
            Out_Top_Doc_Id := int (Result.Hits (1).Doc_Id);
            if Result.Hits (1).Distance <= 1.0e30 then
               Out_Top_Distance := C_float (Result.Hits (1).Distance);
            end if;
         end if;
      end if;

      Out_Status := To_C_Status (Status);
   end C_RAG_Query_Full_ND;

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
   is
      Empty_Filter : constant C_Text_Buf := [others => nul];
      Full_Parent  : C_Toast_Buf         := [others => nul];
      Copy_Len     : Natural;
   begin
      C_RAG_Query_Full_ND
        (Query_Vec_Buf    => Query_Vec_Buf,
         Dim              => Dim,
         Encoding_Mode    => Encoding_Mode,
         Filter_JSON_Buf  => Empty_Filter,
         Filter_JSON_Len  => 0,
         Keyword_Buf      => Keyword_Buf,
         Keyword_Len      => Keyword_Len,
         Top_K            => Top_K,
         Out_Hit_Count    => Out_Hit_Count,
         Out_Top_Doc_Id   => Out_Top_Doc_Id,
         Out_Top_Distance => Out_Top_Distance,
         Out_Parent_Buf   => Full_Parent,
         Out_Parent_Len   => Out_Parent_Len,
         Out_Graph_Hit    => Out_Graph_Hit,
         Out_Status       => Out_Status);

      if Out_Status = C_Status_Ok and then Out_Parent_Len > 0 then
         Copy_Len := Natural'Min (Max_Text_Len, Natural (Out_Parent_Len));
         for I in 1 .. Copy_Len loop
            Out_Parent_Buf (size_t (I)) := Full_Parent (size_t (I));
         end loop;
         if Copy_Len < Max_Text_Len then
            Out_Parent_Buf (size_t (Copy_Len + 1)) := nul;
         end if;
      end if;
   end C_RAG_Query_ND;

end Nhe_O.C_API;
