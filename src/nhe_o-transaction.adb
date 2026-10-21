pragma SPARK_Mode (On);

package body Nhe_O.Transaction is

   --  Magic bytes "NHEO" (0x4E, 0x48, 0x45, 0x4F)
   Magic_0 : constant Byte := 16#4E#;
   Magic_1 : constant Byte := 16#48#;
   Magic_2 : constant Byte := 16#45#;
   Magic_3 : constant Byte := 16#4F#;

   --  Slotted Page Magic "SLOT" (0x53, 0x4C, 0x4F, 0x54)
   Slot_Magic_0 : constant Byte := 16#53#;
   Slot_Magic_1 : constant Byte := 16#4C#;
   Slot_Magic_2 : constant Byte := 16#4F#;
   Slot_Magic_3 : constant Byte := 16#54#;

   procedure Set_CLOG_State
     (CLOG  : in out Commit_Log;
      Id    : in     Valid_Tx_Id;
      State : in     Tx_State)
   is
   begin
      CLOG (Id) := State;
   end Set_CLOG_State;

   procedure Put_U32_BE
     (Buf    : in out WAL_Frame_Buffer;
      Offset : in     WAL_Frame_Offset;
      Val    : in     Unsigned_32)
     with Pre => Offset <= WAL_Frame_Size - 3
   is
   begin
      Buf (Offset)     := Byte (Shift_Right (Val, 24) and 16#FF#);
      Buf (Offset + 1) := Byte (Shift_Right (Val, 16) and 16#FF#);
      Buf (Offset + 2) := Byte (Shift_Right (Val, 8)  and 16#FF#);
      Buf (Offset + 3) := Byte (Val and 16#FF#);
   end Put_U32_BE;

   function Get_U32_BE
     (Buf    : WAL_Frame_Buffer;
      Offset : WAL_Frame_Offset) return Unsigned_32
     with Pre => Offset <= WAL_Frame_Size - 3
   is
   begin
      return Shift_Left (Unsigned_32 (Buf (Offset)), 24)
        or Shift_Left (Unsigned_32 (Buf (Offset + 1)), 16)
        or Shift_Left (Unsigned_32 (Buf (Offset + 2)), 8)
        or Unsigned_32 (Buf (Offset + 3));
   end Get_U32_BE;

   function Update_CRC32_Byte
     (CRC : Unsigned_32;
      B   : Byte) return Unsigned_32
     with Global => null
   is
      C : Unsigned_32 := CRC xor Unsigned_32 (B);
   begin
      for Bit in 1 .. 8 loop
         if (C and 1) /= 0 then
            C := Shift_Right (C, 1) xor 16#EDB8_8320#;
         else
            C := Shift_Right (C, 1);
         end if;
      end loop;
      return C;
   end Update_CRC32_Byte;

   function Update_CRC32_U32
     (CRC : Unsigned_32;
      Val : Unsigned_32) return Unsigned_32
     with Global => null
   is
      C : Unsigned_32 := CRC;
   begin
      C := Update_CRC32_Byte (C, Byte (Shift_Right (Val, 24) and 16#FF#));
      C := Update_CRC32_Byte (C, Byte (Shift_Right (Val, 16) and 16#FF#));
      C := Update_CRC32_Byte (C, Byte (Shift_Right (Val, 8)  and 16#FF#));
      C := Update_CRC32_Byte (C, Byte (Val and 16#FF#));
      return C;
   end Update_CRC32_U32;

   function Compute_CRC32 (Page : Page_Buffer) return Unsigned_32 is
      CRC : Unsigned_32 := 16#FFFF_FFFF#;
   begin
      for I in Page_Offset loop
         CRC := Update_CRC32_Byte (CRC, Page (I));
      end loop;
      return not CRC;
   end Compute_CRC32;

   function Kind_To_Byte (Kind : WAL_Frame_Kind) return Byte is
   begin
      case Kind is
         when WAL_Frame_Data   => return 0;
         when WAL_Frame_Commit => return 1;
         when WAL_Frame_KV     => return 2;
      end case;
   end Kind_To_Byte;

   function Compute_WAL_CRC32
     (Tx_U32    : Unsigned_32;
      Page_U32  : Unsigned_32;
      Kind_Byte : Byte;
      Page      : Page_Buffer) return Unsigned_32
     with Global => null
   is
      CRC : Unsigned_32 := 16#FFFF_FFFF#;
   begin
      CRC := Update_CRC32_U32 (CRC, Tx_U32);
      CRC := Update_CRC32_U32 (CRC, Page_U32);
      CRC := Update_CRC32_Byte (CRC, Kind_Byte);
      for I in Page_Offset loop
         CRC := Update_CRC32_Byte (CRC, Page (I));
      end loop;
      return not CRC;
   end Compute_WAL_CRC32;

   procedure Encode_WAL_Frame
     (Tx       : in     Valid_Tx_Id;
      Page_Id  : in     Valid_Page_Id;
      Page     : in     Page_Buffer;
      Checksum :    out Unsigned_32;
      Frame    :    out WAL_Frame_Buffer;
      Kind     : in     WAL_Frame_Kind := WAL_Frame_Data)
   is
      Bounded_Tx_Id   : constant Unsigned_32 := Unsigned_32 (Tx);
      Bounded_Page_Id : constant Unsigned_32 := Unsigned_32 (Page_Id);
      Kind_B          : constant Byte        := Kind_To_Byte (Kind);
   begin
      Frame    := [others => 0];
      Checksum := Compute_WAL_CRC32 (Bounded_Tx_Id, Bounded_Page_Id, Kind_B, Page);

      --  Bytes 1..4: Magic "NHEO"
      Frame (1) := Magic_0;
      Frame (2) := Magic_1;
      Frame (3) := Magic_2;
      Frame (4) := Magic_3;

      --  Bytes 5..8: Tx_Id
      Put_U32_BE (Frame, 5, Bounded_Tx_Id);

      --  Bytes 9..12: Page_Id
      Put_U32_BE (Frame, 9, Bounded_Page_Id);

      --  Bytes 13..16: CRC32 Checksum (covers Tx_Id + Page_Id + Kind + 4KB Page)
      Put_U32_BE (Frame, 13, Checksum);

      --  Byte 17: WAL_Frame_Kind (0 = Data, 1 = Commit, 2 = KV); Bytes 18..24 = 0
      Frame (17) := Kind_B;

      --  Bytes 25..4120: 4096-byte Slotted Page Payload
      for I in Page_Offset loop
         Frame (WAL_Header_Size + I) := Page (I);
      end loop;
   end Encode_WAL_Frame;

   function Verify_WAL_Frame (Frame : WAL_Frame_Buffer) return Boolean is
      Extracted_Page : Page_Buffer;
      Raw_Tx         : Unsigned_32;
      Raw_Page       : Unsigned_32;
      Stored_CRC     : Unsigned_32;
      Calculated_CRC : Unsigned_32;
   begin
      if Frame (1) /= Magic_0
        or else Frame (2) /= Magic_1
        or else Frame (3) /= Magic_2
        or else Frame (4) /= Magic_3
      then
         return False;
      end if;

      Raw_Tx   := Get_U32_BE (Frame, 5);
      Raw_Page := Get_U32_BE (Frame, 9);
      if Raw_Tx = 0
        or else Raw_Tx > Unsigned_32 (Max_Tx_Id)
        or else Raw_Page > Unsigned_32 (Max_Page_Id)
        or else Frame (17) > 2
      then
         return False;
      end if;

      for I in 18 .. WAL_Header_Size loop
         if Frame (I) /= 0 then
            return False;
         end if;
      end loop;

      Stored_CRC := Get_U32_BE (Frame, 13);
      for I in Page_Offset loop
         Extracted_Page (I) := Frame (WAL_Header_Size + I);
      end loop;

      Calculated_CRC := Compute_WAL_CRC32 (Raw_Tx, Raw_Page, Frame (17), Extracted_Page);
      return Stored_CRC = Calculated_CRC;
   end Verify_WAL_Frame;

   function Get_WAL_Frame_Kind (Frame : WAL_Frame_Buffer) return WAL_Frame_Kind is
   begin
      case Frame (17) is
         when 1      => return WAL_Frame_Commit;
         when 2      => return WAL_Frame_KV;
         when others => return WAL_Frame_Data;
      end case;
   end Get_WAL_Frame_Kind;

   procedure Decode_WAL_Frame
     (Frame   : in     WAL_Frame_Buffer;
      Tx      :    out Valid_Tx_Id;
      Page_Id :    out Valid_Page_Id;
      Page    :    out Page_Buffer)
   is
      Raw_Tx   : constant Unsigned_32 := Get_U32_BE (Frame, 5);
      Raw_Page : constant Unsigned_32 := Get_U32_BE (Frame, 9);
   begin
      if Raw_Tx in 1 .. Unsigned_32 (Max_Tx_Id) then
         Tx := Valid_Tx_Id (Raw_Tx);
      else
         Tx := 1;
      end if;

      if Raw_Page <= Unsigned_32 (Max_Page_Id) then
         Page_Id := Valid_Page_Id (Raw_Page);
      else
         Page_Id := 0;
      end if;

      for I in Page_Offset loop
         Page (I) := Frame (WAL_Header_Size + I);
      end loop;
   end Decode_WAL_Frame;

   procedure Begin_Tx
     (Next_Tx : in out Valid_Tx_Id;
      Ctx     :    out Transaction_Context)
   is
   begin
      Ctx := (
         Id       => Next_Tx,
         Snapshot => Next_Tx,
         State    => Tx_Active
      );
      Next_Tx := Next_Tx + 1;
   end Begin_Tx;

   procedure Commit_Tx
     (Ctx           : in out Transaction_Context;
      DB_Path       : in     Bounded_Text;
      WAL_Path      : in     Bounded_Text;
      Page_Id       : in     Valid_Page_Id;
      Page          : in     Page_Buffer;
      Status        :    out Engine_Status;
      Flush_Pending :    out Boolean)
   is
      Checksum     : Unsigned_32;
      pragma Warnings (Off, Checksum);
      Frame        : WAL_Frame_Buffer;
      Scan_Frame   : WAL_Frame_Buffer;
      Scan_Page    : Page_Buffer;
      Scan_Tx      : Valid_Tx_Id;
      Scan_Pg      : Valid_Page_Id;
      WAL_Exists   : Boolean;
      WAL_Ok       : Boolean;
      Page_Ok      : Boolean;
      Scan_Ok      : Boolean;
      Scan_EOF     : Boolean;
      Hit_EOF      : Boolean := False;
      Total_Frames : Natural := 0;
      Seen_Commits : Commit_Log := [others => Tx_Idle];
      Scan_Kind    : WAL_Frame_Kind;
   begin
      Flush_Pending := False;

      if Equal_Text (DB_Path, WAL_Path) then
         Ctx.State := Tx_Aborted;
         Status    := Status_IO_Error;
         return;
      end if;

      if Has_Embedded_NUL (DB_Path) or else Has_Embedded_NUL (WAL_Path) then
         Ctx.State := Tx_Aborted;
         Status    := Status_IO_Error;
         return;
      end if;

      Encode_WAL_Frame (Ctx.Id, Page_Id, Page, Checksum, Frame, WAL_Frame_Commit);
      if not Verify_WAL_Frame (Frame) then
         Ctx.State := Tx_Aborted;
         Status    := Status_Tx_Aborted;
         return;
      end if;

      --  0. Pre-commit WAL scan: verify all existing frames & ensure EOF is reached
      --     within Max_WAL_Scan_Frames before writing the commit barrier
      Check_File_Exists (WAL_Path, WAL_Exists);
      if WAL_Exists then
         for Step in 1 .. Max_WAL_Scan_Frames - 1 loop
            pragma Loop_Invariant (Total_Frames = Step - 1);
            Read_WAL_Frame
              (WAL_Path, Valid_Page_Id (Step - 1), Scan_Frame, Scan_Ok, Scan_EOF);
            if not Scan_Ok then
               if Scan_EOF then
                  Hit_EOF := True;
                  exit;
               else
                  Ctx.State := Tx_Aborted;
                  Status    := Status_IO_Error;
                  return;
               end if;
            end if;

            if not Verify_WAL_Frame (Scan_Frame) then
               Ctx.State := Tx_Aborted;
               Status    := Status_IO_Error;
               return;
            end if;

            Scan_Kind := Get_WAL_Frame_Kind (Scan_Frame);
            if Scan_Kind = WAL_Frame_Commit then
               pragma Warnings (GNATprove, Off, "is set by");
               Decode_WAL_Frame (Scan_Frame, Scan_Tx, Scan_Pg, Scan_Page);
               pragma Warnings (GNATprove, On, "is set by");
               if Scan_Tx = Ctx.Id then
                  --  Ctx.Id already committed: a reused transaction id is rejected
                  Ctx.State := Tx_Aborted;
                  Status    := Status_Tx_Aborted;
                  return;
               elsif Is_Tx_Committed (Seen_Commits, Scan_Tx) then
                  --  Two commit barriers for one transaction id is corruption
                  Ctx.State := Tx_Aborted;
                  Status    := Status_IO_Error;
                  return;
               end if;
               Set_CLOG_State (Seen_Commits, Scan_Tx, Tx_Committed);
            end if;
            --  A data frame staged after its transaction's barrier (reused id) is
            --  ignored: recovery never replays it, so it cannot affect this commit

            Total_Frames := Step;
         end loop;

         if not Hit_EOF then
            pragma Warnings (GNATprove, Off, "is set by");
            Read_WAL_Frame
              (WAL_Path, Valid_Page_Id (Max_WAL_Scan_Frames - 1),
               Scan_Frame, Scan_Ok, Scan_EOF);
            pragma Warnings (GNATprove, On, "is set by");
            if Scan_Ok then
               Ctx.State := Tx_Aborted;
               Status    := (if Verify_WAL_Frame (Scan_Frame)
                             then Status_Capacity_Exceeded
                             else Status_IO_Error);
               return;
            elsif not Scan_EOF then
               Ctx.State := Tx_Aborted;
               Status    := Status_IO_Error;
               return;
            end if;
         end if;
      end if;

      --  1. Write-Ahead Log commit barrier frame first (WAL protocol). A failed append
      --     leaves the WAL unchanged (Append_WAL_Frame truncates any partial frame).
      Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);
      if not WAL_Ok then
         Ctx.State := Tx_Aborted;
         Status    := Status_IO_Error;
         return;
      end if;

      --  Commit point: the barrier is durable, so recovery will replay this transaction.
      --  Nothing below may report an abort.
      Ctx.State := Tx_Committed;
      Status    := Status_Ok;

      --  2. NO-STEAL materialization: flush all WAL_Frame_Data pages staged by Ctx.Id
      --     to DB_Path now that the commit barrier frame is durable on disk
      for Step in 1 .. Total_Frames loop
         pragma Loop_Invariant
           (Total_Frames < Max_WAL_Scan_Frames
            and then Ctx.State = Tx_Committed
            and then Status = Status_Ok
            and then not Flush_Pending);
         Read_WAL_Frame
           (WAL_Path, Valid_Page_Id (Step - 1), Scan_Frame, Scan_Ok);
         if not Scan_Ok or else not Verify_WAL_Frame (Scan_Frame) then
            Flush_Pending := True;
            return;
         end if;

         if Get_WAL_Frame_Kind (Scan_Frame) = WAL_Frame_Data then
            Decode_WAL_Frame (Scan_Frame, Scan_Tx, Scan_Pg, Scan_Page);
            if Scan_Tx = Ctx.Id then
               Write_Page (DB_Path, Scan_Pg, Scan_Page, Page_Ok);
               if not Page_Ok then
                  Flush_Pending := True;
                  return;
               end if;
            end if;
         end if;
      end loop;

      --  3. Persist the final commit slotted/data page to database file
      Write_Page (DB_Path, Page_Id, Page, Page_Ok);
      if not Page_Ok then
         Flush_Pending := True;
      end if;
   end Commit_Tx;

   procedure Commit_Tx
     (Ctx      : in out Transaction_Context;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Page_Id  : in     Valid_Page_Id;
      Page     : in     Page_Buffer;
      Status   :    out Engine_Status)
   is
      Ignored_Flush : Boolean;
      pragma Warnings (Off, Ignored_Flush);
   begin
      Commit_Tx (Ctx, DB_Path, WAL_Path, Page_Id, Page, Status, Ignored_Flush);
   end Commit_Tx;

   procedure Rollback_Tx
     (Ctx : in out Transaction_Context)
   is
   begin
      Ctx.State := Tx_Aborted;
   end Rollback_Tx;

   -------------------------------------------------------------------------
   --  PostgreSQL-Style 4KB TOAST Overflow Page Chains (ADR-003 / BR-006)
   -------------------------------------------------------------------------

   --  TOAST Page Magic "TOAS" (0x54, 0x4F, 0x41, 0x53)
   TOAST_Magic_0 : constant Byte := 16#54#;
   TOAST_Magic_1 : constant Byte := 16#4F#;
   TOAST_Magic_2 : constant Byte := 16#41#;
   TOAST_Magic_3 : constant Byte := 16#53#;

   procedure Put_Page_U32_BE
     (Page   : in out Page_Buffer;
      Offset : in     Page_Offset;
      Val    : in     Unsigned_32)
     with Pre => Offset <= Nhe_O.Page_Size - 3
   is
   begin
      Page (Offset)     := Byte (Shift_Right (Val, 24) and 16#FF#);
      Page (Offset + 1) := Byte (Shift_Right (Val, 16) and 16#FF#);
      Page (Offset + 2) := Byte (Shift_Right (Val, 8)  and 16#FF#);
      Page (Offset + 3) := Byte (Val and 16#FF#);
   end Put_Page_U32_BE;

   function Get_Page_U32_BE
     (Page   : Page_Buffer;
      Offset : Page_Offset) return Unsigned_32
     with Pre => Offset <= Nhe_O.Page_Size - 3
   is
   begin
      return Shift_Left (Unsigned_32 (Page (Offset)), 24)
        or Shift_Left (Unsigned_32 (Page (Offset + 1)), 16)
        or Shift_Left (Unsigned_32 (Page (Offset + 2)), 8)
        or Unsigned_32 (Page (Offset + 3));
   end Get_Page_U32_BE;

   procedure Encode_TOAST_Pointer
     (Ptr   : in     TOAST_Pointer;
      Bytes :    out TOAST_Pointer_Bytes)
   is
      Root_U32  : constant Unsigned_32 := Unsigned_32 (Ptr.Root_Overflow_Page);
      Len_U32   : constant Unsigned_32 := Unsigned_32 (Ptr.Total_Byte_Length);
      Chunk_U32 : constant Unsigned_32 := Unsigned_32 (Ptr.Chunk_Count);
      CRC_U32   : constant Unsigned_32 := Ptr.Payload_CRC32;
   begin
      Bytes := [others => 0];
      Bytes (1)  := Byte (Shift_Right (Root_U32, 24) and 16#FF#);
      Bytes (2)  := Byte (Shift_Right (Root_U32, 16) and 16#FF#);
      Bytes (3)  := Byte (Shift_Right (Root_U32, 8)  and 16#FF#);
      Bytes (4)  := Byte (Root_U32 and 16#FF#);

      Bytes (5)  := Byte (Shift_Right (Len_U32, 24) and 16#FF#);
      Bytes (6)  := Byte (Shift_Right (Len_U32, 16) and 16#FF#);
      Bytes (7)  := Byte (Shift_Right (Len_U32, 8)  and 16#FF#);
      Bytes (8)  := Byte (Len_U32 and 16#FF#);

      Bytes (9)  := Byte (Shift_Right (Chunk_U32, 24) and 16#FF#);
      Bytes (10) := Byte (Shift_Right (Chunk_U32, 16) and 16#FF#);
      Bytes (11) := Byte (Shift_Right (Chunk_U32, 8)  and 16#FF#);
      Bytes (12) := Byte (Chunk_U32 and 16#FF#);

      Bytes (13) := Byte (Shift_Right (CRC_U32, 24) and 16#FF#);
      Bytes (14) := Byte (Shift_Right (CRC_U32, 16) and 16#FF#);
      Bytes (15) := Byte (Shift_Right (CRC_U32, 8)  and 16#FF#);
      Bytes (16) := Byte (CRC_U32 and 16#FF#);
   end Encode_TOAST_Pointer;

   procedure Decode_TOAST_Pointer
     (Bytes : in     TOAST_Pointer_Bytes;
      Ptr   :    out TOAST_Pointer;
      Valid :    out Boolean)
   is
      Root_U32  : constant Unsigned_32 :=
        Shift_Left (Unsigned_32 (Bytes (1)), 24)
        or Shift_Left (Unsigned_32 (Bytes (2)), 16)
        or Shift_Left (Unsigned_32 (Bytes (3)), 8)
        or Unsigned_32 (Bytes (4));
      Len_U32   : constant Unsigned_32 :=
        Shift_Left (Unsigned_32 (Bytes (5)), 24)
        or Shift_Left (Unsigned_32 (Bytes (6)), 16)
        or Shift_Left (Unsigned_32 (Bytes (7)), 8)
        or Unsigned_32 (Bytes (8));
      Chunk_U32 : constant Unsigned_32 :=
        Shift_Left (Unsigned_32 (Bytes (9)), 24)
        or Shift_Left (Unsigned_32 (Bytes (10)), 16)
        or Shift_Left (Unsigned_32 (Bytes (11)), 8)
        or Unsigned_32 (Bytes (12));
      CRC_U32   : constant Unsigned_32 :=
        Shift_Left (Unsigned_32 (Bytes (13)), 24)
        or Shift_Left (Unsigned_32 (Bytes (14)), 16)
        or Shift_Left (Unsigned_32 (Bytes (15)), 8)
        or Unsigned_32 (Bytes (16));
   begin
      if Root_U32 <= Unsigned_32 (Max_Page_Id)
        and then Len_U32 in 1 .. Unsigned_32 (Max_TOAST_Payload_Bytes)
        and then Chunk_U32 in 1 .. Unsigned_32 (Max_TOAST_Chunks)
        and then Natural (Chunk_U32) =
          ((Natural (Len_U32) - 1) / TOAST_Chunk_Max_Bytes) + 1
        and then Valid_Page_Id (Root_U32) <= Max_Page_Id - Natural (Chunk_U32) + 1
      then
         Ptr := (
            Root_Overflow_Page => Valid_Page_Id (Root_U32),
            Total_Byte_Length  => TOAST_Payload_Length (Len_U32),
            Chunk_Count        => TOAST_Chunk_Count (Chunk_U32),
            Payload_CRC32      => CRC_U32
         );
         Valid := True;
      else
         Ptr   := (others => <>);
         Valid := False;
      end if;
   end Decode_TOAST_Pointer;

   function Compute_Payload_CRC32
     (Payload : TOAST_Payload_Buffer;
      Length  : Valid_TOAST_Length) return Unsigned_32
   is
      CRC : Unsigned_32 := 16#FFFF_FFFF#;
   begin
      for I in 1 .. Length loop
         CRC := Update_CRC32_Byte (CRC, Payload (I));
      end loop;
      return not CRC;
   end Compute_Payload_CRC32;

   function Compute_Chunk_Data_CRC32
     (Page      : Page_Buffer;
      Chunk_Len : Positive) return Unsigned_32
     with Pre => Chunk_Len <= TOAST_Chunk_Max_Bytes
   is
      CRC : Unsigned_32 := 16#FFFF_FFFF#;
   begin
      for I in 1 .. Chunk_Len loop
         CRC := Update_CRC32_Byte (CRC, Page (TOAST_Header_Size + I));
      end loop;
      return not CRC;
   end Compute_Chunk_Data_CRC32;

   procedure Write_TOAST_Chain
     (Ctx           : in     Transaction_Context;
      DB_Path       : in     Bounded_Text;
      WAL_Path      : in     Bounded_Text;
      Start_Page_Id : in     Valid_Page_Id;
      Payload       : in     TOAST_Payload_Buffer;
      Length        : in     Valid_TOAST_Length;
      Ptr           :    out TOAST_Pointer;
      Status        :    out Engine_Status)
   is
      Needed_Chunks : constant Positive :=
        ((Length - 1) / TOAST_Chunk_Max_Bytes) + 1;
      Remaining     : Positive;
      Src_Pos       : Positive;
      Page          : Page_Buffer;
      Frame         : WAL_Frame_Buffer;
      WAL_CRC       : Unsigned_32;
      pragma Warnings (Off, WAL_CRC);
      Chunk_CRC     : Unsigned_32;
      Cur_Page_Id   : Valid_Page_Id;
      Next_Page_U32 : Unsigned_32;
      Chunk_Bytes   : Positive;
      WAL_Ok        : Boolean;
   begin
      if Equal_Text (DB_Path, WAL_Path) then
         Ptr    := (others => <>);
         Status := Status_IO_Error;
         return;
      end if;

      if Nhe_O.IO.Has_Embedded_NUL (DB_Path)
        or else Nhe_O.IO.Has_Embedded_NUL (WAL_Path)
      then
         Ptr    := (others => <>);
         Status := Status_IO_Error;
         return;
      end if;

      Ptr := (
         Root_Overflow_Page => Start_Page_Id,
         Total_Byte_Length  => Length,
         Chunk_Count        => Needed_Chunks,
         Payload_CRC32      => Compute_Payload_CRC32 (Payload, Length)
      );

      for Chunk_Idx in 1 .. Needed_Chunks loop
         pragma Loop_Invariant (Needed_Chunks <= Max_TOAST_Chunks);

         Src_Pos     := (Chunk_Idx - 1) * TOAST_Chunk_Max_Bytes + 1;
         Remaining   := Length - (Chunk_Idx - 1) * TOAST_Chunk_Max_Bytes;
         Cur_Page_Id := Start_Page_Id + (Chunk_Idx - 1);

         if Remaining > TOAST_Chunk_Max_Bytes then
            Chunk_Bytes := TOAST_Chunk_Max_Bytes;
         else
            Chunk_Bytes := Remaining;
         end if;

         if Chunk_Idx < Needed_Chunks then
            Next_Page_U32 := Unsigned_32 (Cur_Page_Id + 1);
         else
            Next_Page_U32 := 0;
         end if;

         Page := [others => 0];
         for B_Idx in 1 .. Chunk_Bytes loop
            Page (TOAST_Header_Size + B_Idx) := Payload (Src_Pos + B_Idx - 1);
         end loop;

         Chunk_CRC := Compute_Chunk_Data_CRC32 (Page, Chunk_Bytes);

         --  16-byte TOAST Page Header
         Page (1) := TOAST_Magic_0;
         Page (2) := TOAST_Magic_1;
         Page (3) := TOAST_Magic_2;
         Page (4) := TOAST_Magic_3;
         Put_Page_U32_BE (Page, 5, Next_Page_U32);
         Put_Page_U32_BE (Page, 9, Unsigned_32 (Chunk_Bytes));
         Put_Page_U32_BE (Page, 13, Chunk_CRC);

         --  NO-STEAL: stage 4KB TOAST overflow page exclusively in WAL_Path
         --  during Tx_Active; Commit_Tx flushes it to DB_Path after the
         --  WAL_Frame_Commit barrier frame is durable.
         Encode_WAL_Frame (Ctx.Id, Cur_Page_Id, Page, WAL_CRC, Frame, WAL_Frame_Data);
         Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);
         if not WAL_Ok then
            Status := Status_IO_Error;
            return;
         end if;
      end loop;

      Status := Status_Ok;
   end Write_TOAST_Chain;

   procedure Read_TOAST_Chain
     (DB_Path : in     Bounded_Text;
      Ptr     : in     TOAST_Pointer;
      Payload :    out TOAST_Payload_Buffer;
      Length  :    out TOAST_Payload_Length;
      Status  :    out Engine_Status)
   is
      Cur_Page_Id : Valid_Page_Id := Ptr.Root_Overflow_Page;
      Dst_Pos     : Natural := 0;
      Page        : Page_Buffer;
      Read_Ok     : Boolean;
      Next_U32    : Unsigned_32;
      Chunk_U32   : Unsigned_32;
      Stored_CRC  : Unsigned_32;
      Calc_CRC    : Unsigned_32;
      Chunk_Bytes : Positive;
   begin
      Payload := [others => 0];

      for Chunk_Idx in 1 .. Ptr.Chunk_Count loop
         pragma Loop_Invariant (Dst_Pos <= Max_TOAST_Payload_Bytes);

         Read_Page (DB_Path, Cur_Page_Id, Page, Read_Ok);
         if not Read_Ok then
            Payload := [others => 0];
            Length  := 0;
            Status  := Status_IO_Error;
            return;
         end if;

         if Page (1) /= TOAST_Magic_0
           or else Page (2) /= TOAST_Magic_1
           or else Page (3) /= TOAST_Magic_2
           or else Page (4) /= TOAST_Magic_3
         then
            Payload := [others => 0];
            Length  := 0;
            Status  := Status_Invalid_Syntax;
            return;
         end if;

         Next_U32   := Get_Page_U32_BE (Page, 5);
         Chunk_U32  := Get_Page_U32_BE (Page, 9);
         Stored_CRC := Get_Page_U32_BE (Page, 13);

         if Chunk_U32 = 0
           or else Chunk_U32 > Unsigned_32 (TOAST_Chunk_Max_Bytes)
         then
            Payload := [others => 0];
            Length  := 0;
            Status  := Status_Invalid_Syntax;
            return;
         end if;

         Chunk_Bytes := Positive (Chunk_U32);
         if Dst_Pos + Chunk_Bytes > Ptr.Total_Byte_Length then
            Payload := [others => 0];
            Length  := 0;
            Status  := Status_Invalid_Syntax;
            return;
         end if;

         Calc_CRC := Compute_Chunk_Data_CRC32 (Page, Chunk_Bytes);
         if Calc_CRC /= Stored_CRC then
            Payload := [others => 0];
            Length  := 0;
            Status  := Status_IO_Error;
            return;
         end if;

         for B_Idx in 1 .. Chunk_Bytes loop
            Payload (Dst_Pos + B_Idx) := Page (TOAST_Header_Size + B_Idx);
         end loop;
         Dst_Pos := Dst_Pos + Chunk_Bytes;

         if (for some B in TOAST_Header_Size + Chunk_Bytes + 1 .. Nhe_O.Page_Size =>
               Page (B) /= 0)
         then
            Payload := [others => 0];
            Length  := 0;
            Status  := Status_Invalid_Syntax;
            return;
         end if;

         if Chunk_Idx < Ptr.Chunk_Count then
            if Chunk_Bytes /= TOAST_Chunk_Max_Bytes
              or else Next_U32 /= Unsigned_32 (Cur_Page_Id + 1)
              or else Next_U32 > Unsigned_32 (Max_Page_Id)
            then
               Payload := [others => 0];
               Length  := 0;
               Status  := Status_Invalid_Syntax;
               return;
            end if;
            Cur_Page_Id := Valid_Page_Id (Next_U32);
         else
            if Next_U32 /= 0 then
               Payload := [others => 0];
               Length  := 0;
               Status  := Status_Invalid_Syntax;
               return;
            end if;
         end if;
      end loop;

      if Dst_Pos /= Ptr.Total_Byte_Length then
         Payload := [others => 0];
         Length  := 0;
         Status  := Status_Invalid_Syntax;
         return;
      end if;

      if Compute_Payload_CRC32 (Payload, Ptr.Total_Byte_Length) /= Ptr.Payload_CRC32 then
         Payload := [others => 0];
         Length  := 0;
         Status  := Status_IO_Error;
         return;
      end if;

      Length := Ptr.Total_Byte_Length;
      Status := Status_Ok;
   end Read_TOAST_Chain;

   -------------------------------------------------------------------------
   --  Primary 4096-Byte Slotted Page Layout (`"SLOT"` / BR-006)
   -------------------------------------------------------------------------

   procedure Encode_Slotted_Page
     (Page_Rec : in     Slotted_Page;
      Raw_Page :    out Page_Buffer)
   is
      Dir_Base     : Page_Offset;
      Tup_Base     : Page_Offset;
      Toast_B      : TOAST_Pointer_Bytes;
      Page_CRC     : Unsigned_32;
      Occupied_Cnt : Page_Slot_Count := 0;
      Free_Low     : constant Unsigned_32 := 24 + Unsigned_32 (Max_Page_Slots * 8);
      Free_High    : Unsigned_32;
      Tup          : Slotted_Tuple;
   begin
      Raw_Page := [others => 0];

      --  The header Slot_Count always equals the number of occupied slots
      for Slot in Page_Slot_Index loop
         pragma Loop_Invariant (Occupied_Cnt < Slot);
         if Page_Rec.Tuples (Slot).Occupied then
            Occupied_Cnt := Occupied_Cnt + 1;
         end if;
      end loop;
      Free_High := 153 + Unsigned_32 (Occupied_Cnt) * 240;

      --  24-Byte Slotted Page Header
      Raw_Page (1) := Slot_Magic_0;
      Raw_Page (2) := Slot_Magic_1;
      Raw_Page (3) := Slot_Magic_2;
      Raw_Page (4) := Slot_Magic_3;
      Put_Page_U32_BE (Raw_Page, 5, Unsigned_32 (Page_Rec.Page_Id));
      Put_Page_U32_BE (Raw_Page, 9, Unsigned_32 (Occupied_Cnt));
      Put_Page_U32_BE (Raw_Page, 13, Shift_Left (Free_Low, 16) or Free_High);
      Put_Page_U32_BE (Raw_Page, 17, Unsigned_32 (Page_Rec.Page_LSN_Tx));

      --  16-Slot Line Pointer Directory (Bytes 25..152) + Tuple Area (Bytes 153..3992)
      for Slot in Page_Slot_Index loop
         Dir_Base := 25 + (Slot - 1) * 8;
         Tup_Base := 153 + (Slot - 1) * 240;
         pragma Loop_Invariant
           (Dir_Base = 25 + (Slot - 1) * 8
            and then Tup_Base = 153 + (Slot - 1) * 240);

         --  Unoccupied slots are always written in their canonical default form
         Tup := (if Page_Rec.Tuples (Slot).Occupied
                 then Page_Rec.Tuples (Slot)
                 else Slotted_Tuple'(others => <>));

         Put_Page_U32_BE (Raw_Page, Dir_Base, Unsigned_32 (Tup_Base));
         Raw_Page (Dir_Base + 4) := (if Tup.Occupied then 1 else 0);
         Raw_Page (Dir_Base + 5) := Byte (Tup.Inline_Len);
         Raw_Page (Dir_Base + 6) := 0;
         Raw_Page (Dir_Base + 7) := 0;

         Put_Page_U32_BE (Raw_Page, Tup_Base, Unsigned_32 (Tup.Row_Id));
         Put_Page_U32_BE (Raw_Page, Tup_Base + 4, Unsigned_32 (Tup.Tuple_Hdr.Xmin));
         Put_Page_U32_BE (Raw_Page, Tup_Base + 8, Unsigned_32 (Tup.Tuple_Hdr.Xmax));
         Put_Page_U32_BE (Raw_Page, Tup_Base + 12, Unsigned_32 (Tup.Related_Id));

         Encode_TOAST_Pointer (Tup.Toast_Ptr, Toast_B);
         for B in TOAST_Pointer_Index loop
            Raw_Page (Tup_Base + 15 + B) := Toast_B (B);
         end loop;

         for B in Inline_Tuple_Index loop
            Raw_Page (Tup_Base + 31 + B) := Tup.Inline_Data (B);
         end loop;
      end loop;

      --  Bytes 21..24: IEEE 802.3 CRC32 over the page with bytes 21..24 zeroed
      Page_CRC := Compute_CRC32 (Raw_Page);
      Put_Page_U32_BE (Raw_Page, 21, Page_CRC);
   end Encode_Slotted_Page;

   procedure Decode_Slotted_Page
     (Raw_Page : in     Page_Buffer;
      Page_Rec :    out Slotted_Page;
      Valid    :    out Boolean)
   is
      Zeroed_Page : Page_Buffer := Raw_Page;
      Stored_CRC  : Unsigned_32;
      Raw_Page_Id : Unsigned_32;
      Raw_Slots   : Unsigned_32;
      Raw_Free    : Unsigned_32;
      Exp_Free    : Unsigned_32;
      Raw_LSN     : Unsigned_32;
      Dir_Base    : Page_Offset;
      Tup_Base    : Page_Offset;
      Raw_Tup_Off : Unsigned_32;
      Raw_Row_Id  : Unsigned_32;
      Raw_Xmin    : Unsigned_32;
      Raw_Xmax    : Unsigned_32;
      Raw_Rel_Id  : Unsigned_32;
      Toast_B     : TOAST_Pointer_Bytes;
      Toast_P     : TOAST_Pointer;
      Toast_Valid : Boolean;
      Active_Cnt  : Natural := 0;
   begin
      Page_Rec := (others => <>);
      Valid    := False;

      if Raw_Page (1) /= Slot_Magic_0
        or else Raw_Page (2) /= Slot_Magic_1
        or else Raw_Page (3) /= Slot_Magic_2
        or else Raw_Page (4) /= Slot_Magic_3
      then
         return;
      end if;

      Stored_CRC       := Get_Page_U32_BE (Raw_Page, 21);
      Zeroed_Page (21) := 0;
      Zeroed_Page (22) := 0;
      Zeroed_Page (23) := 0;
      Zeroed_Page (24) := 0;
      if Compute_CRC32 (Zeroed_Page) /= Stored_CRC then
         return;
      end if;

      Raw_Page_Id := Get_Page_U32_BE (Raw_Page, 5);
      Raw_Slots   := Get_Page_U32_BE (Raw_Page, 9);
      Raw_Free    := Get_Page_U32_BE (Raw_Page, 13);
      Raw_LSN     := Get_Page_U32_BE (Raw_Page, 17);

      if Raw_Page_Id > Unsigned_32 (Max_Page_Id)
        or else Raw_Slots > Unsigned_32 (Max_Page_Slots)
        or else Raw_LSN = 0
        or else Raw_LSN > Unsigned_32 (Max_Tx_Id)
      then
         return;
      end if;

      Exp_Free :=
        Shift_Left (24 + Unsigned_32 (Max_Page_Slots * 8), 16)
        or (153 + Raw_Slots * 240);
      if Raw_Free /= Exp_Free
        or else (for some B in 3993 .. Nhe_O.Page_Size => Raw_Page (B) /= 0)
      then
         return;
      end if;

      Page_Rec.Page_Id     := Valid_Page_Id (Raw_Page_Id);
      Page_Rec.Slot_Count  := Page_Slot_Count (Raw_Slots);
      Page_Rec.Page_LSN_Tx := Valid_Tx_Id (Raw_LSN);

      for Slot in Page_Slot_Index loop
         pragma Loop_Invariant
           (Page_Rec.Page_Id = Valid_Page_Id (Raw_Page_Id)
            and then Page_Rec.Slot_Count = Page_Slot_Count (Raw_Slots)
            and then Page_Rec.Page_LSN_Tx = Valid_Tx_Id (Raw_LSN)
            and then Active_Cnt < Slot);
         Dir_Base    := 25 + (Slot - 1) * 8;
         Tup_Base    := 153 + (Slot - 1) * 240;
         Raw_Tup_Off := Get_Page_U32_BE (Raw_Page, Dir_Base);

         if Raw_Tup_Off /= Unsigned_32 (Tup_Base)
           or else Raw_Page (Dir_Base + 4) > 1
           or else Natural (Raw_Page (Dir_Base + 5)) > Max_Inline_Tuple_Bytes
           or else Raw_Page (Dir_Base + 6) /= 0
           or else Raw_Page (Dir_Base + 7) /= 0
         then
            Page_Rec := (others => <>);
            return;
         end if;

         Raw_Row_Id := Get_Page_U32_BE (Raw_Page, Tup_Base);
         Raw_Xmin   := Get_Page_U32_BE (Raw_Page, Tup_Base + 4);
         Raw_Xmax   := Get_Page_U32_BE (Raw_Page, Tup_Base + 8);
         Raw_Rel_Id := Get_Page_U32_BE (Raw_Page, Tup_Base + 12);

         if Raw_Row_Id = 0
           or else Raw_Row_Id > Unsigned_32 (Positive'Last)
           or else Raw_Xmin = 0
           or else Raw_Xmin > Unsigned_32 (Max_Tx_Id)
           or else Raw_Xmax > Unsigned_32 (Max_Tx_Id)
           or else Raw_Rel_Id > Unsigned_32 (Natural'Last)
         then
            Page_Rec := (others => <>);
            return;
         end if;

         for B in TOAST_Pointer_Index loop
            Toast_B (B) := Raw_Page (Tup_Base + 15 + B);
         end loop;

         if Raw_Page (Dir_Base + 4) = 1 then
            Active_Cnt := Active_Cnt + 1;
            if (for some B in TOAST_Pointer_Index => Toast_B (B) /= 0) then
               Decode_TOAST_Pointer (Toast_B, Toast_P, Toast_Valid);
               if not Toast_Valid then
                  Page_Rec := (others => <>);
                  return;
               end if;
            else
               Toast_P := (others => <>);
            end if;
         else
            if Raw_Page (Dir_Base + 5) /= 0
              or else Raw_Row_Id /= 1
              or else Raw_Xmin /= 1
              or else Raw_Xmax /= 0
              or else Raw_Rel_Id /= 0
              or else (for some B in TOAST_Pointer_Index => Toast_B (B) /= 0)
              or else (for some B in Inline_Tuple_Index => Raw_Page (Tup_Base + 31 + B) /= 0)
            then
               Page_Rec := (others => <>);
               return;
            end if;
            Toast_P := (others => <>);
         end if;

         Page_Rec.Tuples (Slot).Occupied   := (Raw_Page (Dir_Base + 4) = 1);
         Page_Rec.Tuples (Slot).Row_Id     := Positive (Raw_Row_Id);
         Page_Rec.Tuples (Slot).Tuple_Hdr  := (Xmin => Valid_Tx_Id (Raw_Xmin),
                                               Xmax => Tx_Id (Raw_Xmax));
         Page_Rec.Tuples (Slot).Toast_Ptr  := Toast_P;
         Page_Rec.Tuples (Slot).Related_Id := Natural (Raw_Rel_Id);
         Page_Rec.Tuples (Slot).Inline_Len := Inline_Tuple_Length (Raw_Page (Dir_Base + 5));

         for B in Inline_Tuple_Index loop
            Page_Rec.Tuples (Slot).Inline_Data (B) := Raw_Page (Tup_Base + 31 + B);
         end loop;
      end loop;

      if Active_Cnt /= Page_Rec.Slot_Count then
         Page_Rec := (others => <>);
         return;
      end if;

      Valid := True;
   end Decode_Slotted_Page;

   function Has_WAL_Magic (Frame : WAL_Frame_Buffer) return Boolean is
     (Frame (1) = Magic_0 and then Frame (2) = Magic_1
      and then Frame (3) = Magic_2 and then Frame (4) = Magic_3);

   --  True iff the first Len bytes of Frame can be what a crash left of the very first
   --  append to an empty WAL: a whole frame header that a valid frame could carry (the
   --  "NHEO" magic, a valid transaction id, page id and frame kind, zero reserved bytes)
   --  followed by any payload bytes; fewer than WAL_Header_Size bytes that begin such a
   --  header (Append_WAL_Frame syncs the first sector of a first frame before the rest,
   --  so a tear inside the header leaves only a prefix of it); or zero bytes up to the
   --  end of the first 4096-byte block (an extension whose data never reached the disk)
   function Is_Torn_First_Frame
     (Frame : WAL_Frame_Buffer;
      Len   : WAL_Frame_Offset) return Boolean
   is
     ((Len >= WAL_Header_Size
       and then Has_WAL_Magic (Frame)
       and then Get_U32_BE (Frame, 5) in 1 .. Unsigned_32 (Max_Tx_Id)
       and then Get_U32_BE (Frame, 9) <= Unsigned_32 (Max_Page_Id)
       and then Frame (17) <= 2
       and then (for all I in 18 .. WAL_Header_Size => Frame (I) = 0))
      or else
      (Len < WAL_Header_Size
       and then Frame (1) = Magic_0
       and then (Len < 2 or else Frame (2) = Magic_1)
       and then (Len < 3 or else Frame (3) = Magic_2)
       and then (Len < 4 or else Frame (4) = Magic_3)
       --  Tx_Id in 1 .. Max_Tx_Id = 16#2000#, Page_Id <= Max_Page_Id = 16#F_FFFF#
       and then (Len < 5 or else Frame (5) = 0)
       and then (Len < 6 or else Frame (6) = 0)
       and then (Len < 7 or else Frame (7) <= 16#20#)
       and then (Len < 8 or else Get_U32_BE (Frame, 5) in 1 .. Unsigned_32 (Max_Tx_Id))
       and then (Len < 9 or else Frame (9) = 0)
       and then (Len < 10 or else Frame (10) <= 16#0F#)
       and then (Len < 17 or else Frame (17) <= 2)
       and then (for all I in 18 .. Len => Frame (I) = 0))
      or else (for all I in 1 .. Natural'Min (Len, Nhe_O.Page_Size) => Frame (I) = 0))
     with Global => null;

   --  Classify the WAL at WAL_Path before anything is truncated: Status_Ok when it is
   --  missing or a WAL whose only damage is a torn tail, with Cut telling whether
   --  New_Size must replace its size; Status_IO_Error for mid-log corruption or a file
   --  that is not a WAL (see Repair_WAL_Tail)
   procedure Classify_WAL
     (WAL_Path : in     Bounded_Text;
      Cut      :    out Boolean;
      New_Size :    out File_Size;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0,
          Post   => Status in Status_Ok | Status_IO_Error
                    and then (if Cut then Status = Status_Ok)
   is
      Exists    : Boolean;
      Size      : File_Size;
      Size_Ok   : Boolean;
      Full      : Integer_64;
      Rem_Bytes : Integer_64;
      Frame     : WAL_Frame_Buffer;
      Got       : Natural;
      Read_Ok   : Boolean;
      Last_Torn : Boolean := False;
   begin
      Status   := Status_Ok;
      Cut      := False;
      New_Size := 0;

      Check_File_Exists (WAL_Path, Exists);
      if not Exists then
         return;
      end if;

      Get_File_Size (WAL_Path, Size, Size_Ok);
      if not Size_Ok then
         Status := Status_IO_Error;
         return;
      end if;

      Full      := Size / Integer_64 (WAL_Frame_Size);
      Rem_Bytes := Size mod Integer_64 (WAL_Frame_Size);

      --  The engine never appends past Max_WAL_Frames: an over-full WAL is foreign
      if Full > Integer_64 (Max_WAL_Frames)
        or else (Full = Integer_64 (Max_WAL_Frames) and then Rem_Bytes /= 0)
      then
         Status := Status_IO_Error;
         return;
      end if;

      --  1. Appends are sequential and fsynced, so a crash can only tear the LAST
      --     frame: every complete frame must verify, except a final complete frame
      --     with no partial frame after it (and, when it is the only frame, only if it
      --     can be a torn first append).
      for Idx in 0 .. Natural (Full) - 1 loop
         pragma Loop_Invariant (Status = Status_Ok and then not Last_Torn and then not Cut);
         Read_File_Bytes
           (WAL_Path, Integer_64 (Idx) * Integer_64 (WAL_Frame_Size), Frame, Got, Read_Ok);
         if not Read_Ok or else Got /= WAL_Frame_Size then
            Status := Status_IO_Error;
            return;
         elsif not Verify_WAL_Frame (Frame) then
            --  A lone bad frame is only a torn first append if it looks like one
            if Idx = Natural (Full) - 1
              and then Rem_Bytes = 0
              and then (Idx > 0 or else Is_Torn_First_Frame (Frame, WAL_Frame_Size))
            then
               Last_Torn := True;
            else
               Status := Status_IO_Error;
               return;
            end if;
         end if;
      end loop;

      --  2. Without any complete frame, the partial bytes must look like the start of a
      --     first append; anything else is a foreign file
      if Full = 0 and then Rem_Bytes > 0 then
         Read_File_Bytes (WAL_Path, 0, Frame, Got, Read_Ok);
         if not Read_Ok
           or else Integer_64 (Got) /= Rem_Bytes
           or else not Is_Torn_First_Frame (Frame, Got)
         then
            Status := Status_IO_Error;
            return;
         end if;
      end if;

      --  3. The torn tail to drop: the partial frame, or the unverifiable final frame
      if Last_Torn then
         Cut      := True;
         New_Size := (Full - 1) * Integer_64 (WAL_Frame_Size);
      elsif Rem_Bytes /= 0 then
         Cut      := True;
         New_Size := Full * Integer_64 (WAL_Frame_Size);
      end if;
   end Classify_WAL;

   procedure Repair_WAL_Tail
     (WAL_Path : in     Bounded_Text;
      Status   :    out Engine_Status)
   is
      Cut      : Boolean;
      New_Size : File_Size;
      Trunc_Ok : Boolean;
   begin
      Classify_WAL (WAL_Path, Cut, New_Size, Status);
      if Cut then
         Truncate_File (WAL_Path, New_Size, Trunc_Ok);
         if not Trunc_Ok then
            Status := Status_IO_Error;
         end if;
      end if;
   end Repair_WAL_Tail;

   procedure Check_WAL_File
     (WAL_Path : in     Bounded_Text;
      Is_WAL   :    out Boolean)
   is
      Cut      : Boolean;
      New_Size : File_Size;
      Status   : Engine_Status;
      pragma Warnings (Off, Cut);
      pragma Warnings (Off, New_Size);
   begin
      Classify_WAL (WAL_Path, Cut, New_Size, Status);
      Is_WAL := Status = Status_Ok;
   end Check_WAL_File;

   procedure Repair_DB_Tail
     (DB_Path : in     Bounded_Text;
      Status  :    out Engine_Status)
   is
      Exists    : Boolean;
      Size      : File_Size;
      Size_Ok   : Boolean;
      Rem_Bytes : Integer_64;
      Trunc_Ok  : Boolean;
   begin
      Status := Status_Ok;

      Check_File_Exists (DB_Path, Exists);
      if not Exists then
         return;
      end if;

      Get_File_Size (DB_Path, Size, Size_Ok);
      if not Size_Ok then
         Status := Status_IO_Error;
         return;
      end if;

      Rem_Bytes := Size mod Integer_64 (Nhe_O.Page_Size);
      if Rem_Bytes /= 0 then
         Truncate_File (DB_Path, Size - Rem_Bytes, Trunc_Ok);
         if not Trunc_Ok then
            Status := Status_IO_Error;
         end if;
      end if;
   end Repair_DB_Tail;

   procedure Redo_WAL_Recovery
     (DB_Path          : in     Bounded_Text;
      WAL_Path         : in     Bounded_Text;
      Max_Frames       : in     Positive;
      Replayed_Count   :    out Natural;
      Max_Recovered_Tx :    out Tx_Id;
      Max_Seen_Tx      :    out Tx_Id;
      Status           :    out Engine_Status)
   is
      subtype Scan_Index is Natural range 0 .. Max_WAL_Frames - 1;
      type Frame_Kind_Map is array (Scan_Index) of WAL_Frame_Kind;
      type Frame_Tx_Map is array (Scan_Index) of Valid_Tx_Id;

      Scan_Limit   : constant Positive := Positive'Min (Max_Frames, Max_WAL_Frames);
      Kinds        : Frame_Kind_Map := [others => WAL_Frame_KV];
      Txs          : Frame_Tx_Map   := [others => 1];
      Frame        : WAL_Frame_Buffer;
      Page         : Page_Buffer;
      Frame_Tx     : Valid_Tx_Id;
      Frame_Pg     : Valid_Page_Id;
      Kind         : WAL_Frame_Kind;
      Read_Ok      : Boolean;
      Is_EOF       : Boolean;
      Replay_Ok    : Boolean;
      Total_Frames : Natural := 0;
      Hit_EOF      : Boolean := False;
      CLOG         : Commit_Log := [others => Tx_Idle];
      Commit_Id    : Valid_Tx_Id;
      Sub_Stat     : Engine_Status;
      pragma Warnings (Off, Frame_Pg);
      pragma Warnings (Off, Page);

      --  Re-read, re-verify and materialize WAL frame Idx into DB_Path
      procedure Replay_Frame
        (Idx : in     Scan_Index;
         Ok  :    out Boolean)
        with Pre => DB_Path.Length > 0 and then WAL_Path.Length > 0
      is
         Fr     : WAL_Frame_Buffer;
         Pg_Buf : Page_Buffer;
         Fr_Tx  : Valid_Tx_Id;
         Pg_Id  : Valid_Page_Id;
         R_Ok   : Boolean;
         pragma Warnings (Off, Fr_Tx);
      begin
         Read_WAL_Frame (WAL_Path, Idx, Fr, R_Ok);
         if not R_Ok or else not Verify_WAL_Frame (Fr) then
            Ok := False;
            return;
         end if;
         Decode_WAL_Frame (Fr, Fr_Tx, Pg_Id, Pg_Buf);
         Write_Page (DB_Path, Pg_Id, Pg_Buf, Ok);
      end Replay_Frame;

   begin
      Replayed_Count   := 0;
      Max_Recovered_Tx := 0;
      Max_Seen_Tx      := 0;
      Status           := Status_Ok;

      if Equal_Text (DB_Path, WAL_Path) then
         Status := Status_IO_Error;
         return;
      end if;

      --  0. Repair torn tails left by a crash during an append or a page write
      Repair_WAL_Tail (WAL_Path, Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Status := Sub_Stat;
         return;
      end if;
      Repair_DB_Tail (DB_Path, Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Status := Sub_Stat;
         return;
      end if;

      --  Pass 1: Analysis & Commit-Marker Discovery (identify all WAL_Frame_Commit transactions)
      for Step in 1 .. Scan_Limit loop
         pragma Loop_Invariant
           (Total_Frames = Step - 1
            and then Max_Recovered_Tx = 0
            and then Replayed_Count = 0
            and then (for all I in 0 .. Step - 2 =>
                        (if Kinds (I) /= WAL_Frame_KV then Txs (I) <= Max_Seen_Tx)));
         Read_WAL_Frame (WAL_Path, Step - 1, Frame, Read_Ok, Is_EOF);
         if not Read_Ok then
            if Is_EOF then
               Hit_EOF := True;
               exit;
            else
               Status := Status_IO_Error;
               return;
            end if;
         end if;

         if not Verify_WAL_Frame (Frame) then
            Status := Status_IO_Error;
            return;
         end if;

         Decode_WAL_Frame (Frame, Frame_Tx, Frame_Pg, Page);
         Kind              := Get_WAL_Frame_Kind (Frame);
         Kinds (Step - 1)  := Kind;
         Txs (Step - 1)    := Frame_Tx;
         if Kind /= WAL_Frame_KV and then Frame_Tx > Max_Seen_Tx then
            Max_Seen_Tx := Frame_Tx;
         end if;

         if Kind = WAL_Frame_Commit then
            if Is_Tx_Committed (CLOG, Frame_Tx) then
               --  Two commit barriers for one transaction id is corruption
               Status := Status_IO_Error;
               return;
            end if;
            Set_CLOG_State (CLOG, Frame_Tx, Tx_Committed);
         end if;
         Total_Frames := Step;
      end loop;

      --  Detect WAL overflow or torn/corrupted frame if Max_Frames was reached before EOF
      if not Hit_EOF and then Scan_Limit < Max_WAL_Frames then
         Read_WAL_Frame (WAL_Path, Scan_Limit, Frame, Read_Ok, Is_EOF);
         if Read_Ok then
            Status := (if Verify_WAL_Frame (Frame)
                       then Status_Capacity_Exceeded
                       else Status_IO_Error);
            return;
         elsif not Is_EOF then
            Status := Status_IO_Error;
            return;
         end if;
      end if;

      --  Pass 2: Redo in commit order. For each commit barrier (in WAL order), replay the
      --  data frames its transaction staged before the barrier, then the barrier page.
      for C in 0 .. Total_Frames - 1 loop
         pragma Loop_Invariant
           (Total_Frames <= Scan_Limit
            and then Replayed_Count <= Total_Frames
            and then Max_Recovered_Tx <= Max_Seen_Tx
            and then (for all I in 0 .. Total_Frames - 1 =>
                        (if Kinds (I) /= WAL_Frame_KV then Txs (I) <= Max_Seen_Tx)));
         if Kinds (C) = WAL_Frame_Commit then
            Commit_Id := Txs (C);
            for F in 0 .. C - 1 loop
               pragma Loop_Invariant
                 (Replayed_Count <= Total_Frames
                  and then Max_Recovered_Tx <= Max_Seen_Tx);
               if Kinds (F) = WAL_Frame_Data and then Txs (F) = Commit_Id then
                  Replay_Frame (F, Replay_Ok);
                  if not Replay_Ok then
                     Status := Status_IO_Error;
                     return;
                  end if;
                  if Replayed_Count < Total_Frames then
                     Replayed_Count := Replayed_Count + 1;
                  end if;
               end if;
            end loop;

            Replay_Frame (C, Replay_Ok);
            if not Replay_Ok then
               Status := Status_IO_Error;
               return;
            end if;
            if Replayed_Count < Total_Frames then
               Replayed_Count := Replayed_Count + 1;
            end if;
            if Commit_Id > Max_Recovered_Tx then
               Max_Recovered_Tx := Commit_Id;
            end if;
         end if;
      end loop;
   end Redo_WAL_Recovery;

end Nhe_O.Transaction;

