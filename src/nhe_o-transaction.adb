pragma SPARK_Mode (On);

package body Nhe_O.Transaction is

   --  Magic bytes "NHEO" (0x4E, 0x48, 0x45, 0x4F)
   Magic_0 : constant Byte := 16#4E#;
   Magic_1 : constant Byte := 16#48#;
   Magic_2 : constant Byte := 16#45#;
   Magic_3 : constant Byte := 16#4F#;

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

   function Compute_WAL_CRC32
     (Tx_U32   : Unsigned_32;
      Page_U32 : Unsigned_32;
      Page     : Page_Buffer) return Unsigned_32
   is
      CRC : Unsigned_32 := 16#FFFF_FFFF#;
   begin
      CRC := Update_CRC32_U32 (CRC, Tx_U32);
      CRC := Update_CRC32_U32 (CRC, Page_U32);
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
      Frame    :    out WAL_Frame_Buffer)
   is
      Bounded_Tx_Id   : constant Unsigned_32 := Unsigned_32 (Tx);
      Bounded_Page_Id : constant Unsigned_32 := Unsigned_32 (Page_Id);
   begin
      Frame    := [others => 0];
      Checksum := Compute_WAL_CRC32 (Bounded_Tx_Id, Bounded_Page_Id, Page);

      --  Bytes 1..4: Magic "NHEO"
      Frame (1) := Magic_0;
      Frame (2) := Magic_1;
      Frame (3) := Magic_2;
      Frame (4) := Magic_3;

      --  Bytes 5..8: Tx_Id
      Put_U32_BE (Frame, 5, Bounded_Tx_Id);

      --  Bytes 9..12: Page_Id
      Put_U32_BE (Frame, 9, Bounded_Page_Id);

      --  Bytes 13..16: CRC32 Checksum (covers Tx_Id + Page_Id + 4KB Page)
      Put_U32_BE (Frame, 13, Checksum);

      --  Bytes 25..4120: 4096-byte Slotted Page Payload
      for I in Page_Offset loop
         Frame (WAL_Header_Size + I) := Page (I);
      end loop;
   end Encode_WAL_Frame;

   function Verify_WAL_Frame (Frame : WAL_Frame_Buffer) return Boolean is
      Extracted_Page : Page_Buffer := [others => 0];
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
      then
         return False;
      end if;

      for I in 17 .. WAL_Header_Size loop
         if Frame (I) /= 0 then
            return False;
         end if;
      end loop;

      Stored_CRC := Get_U32_BE (Frame, 13);
      for I in Page_Offset loop
         Extracted_Page (I) := Frame (WAL_Header_Size + I);
      end loop;

      Calculated_CRC := Compute_WAL_CRC32 (Raw_Tx, Raw_Page, Extracted_Page);
      return Stored_CRC = Calculated_CRC;
   end Verify_WAL_Frame;

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
     (Ctx      : in out Transaction_Context;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Page_Id  : in     Valid_Page_Id;
      Page     : in     Page_Buffer;
      Status   :    out Engine_Status)
   is
      Checksum : Unsigned_32;
      Frame    : WAL_Frame_Buffer;
      WAL_Ok   : Boolean;
      Page_Ok  : Boolean;
   begin
      Encode_WAL_Frame (Ctx.Id, Page_Id, Page, Checksum, Frame);
      if not Verify_WAL_Frame (Frame) then
         Ctx.State := Tx_Aborted;
         Status    := Status_Tx_Aborted;
         return;
      end if;

      --  1. Write-Ahead Log first (WAL protocol)
      Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);
      if not WAL_Ok then
         Ctx.State := Tx_Aborted;
         Status    := Status_IO_Error;
         return;
      end if;

      --  2. Persist slotted page to database file
      Write_Page (DB_Path, Page_Id, Page, Page_Ok);
      if not Page_Ok then
         Ctx.State := Tx_Aborted;
         Status    := Status_IO_Error;
         return;
      end if;

      Ctx.State := Tx_Committed;
      Status    := Status_Ok;
   end Commit_Tx;

   procedure Rollback_Tx
     (Ctx : in out Transaction_Context)
   is
   begin
      Ctx.State := Tx_Aborted;
   end Rollback_Tx;

end Nhe_O.Transaction;
