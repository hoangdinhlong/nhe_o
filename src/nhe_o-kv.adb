pragma SPARK_Mode (On);

package body Nhe_O.KV is

   KV_Magic_0 : constant Byte := 16#4B#; --  'K'
   KV_Magic_1 : constant Byte := 16#56#; --  'V'
   KV_Magic_2 : constant Byte := 16#4D#; --  'M'
   KV_Magic_3 : constant Byte := 16#47#; --  'G'

   function Exists
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Boolean
   is
   begin
      for I in KV_Slot_Index loop
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 =>
              not (Store.Slots (J).Occupied
                   and then not Is_Slot_Expired (Store.Slots (J), Now)
                   and then Equal_Ident (Store.Slots (J).Key, Key)));
         if Store.Slots (I).Occupied
           and then not Is_Slot_Expired (Store.Slots (I), Now)
           and then Equal_Ident (Store.Slots (I).Key, Key)
         then
            return True;
         end if;
      end loop;
      return False;
   end Exists;

   function Select_Target_Slot
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return KV_Slot_Index
   is
      First_Free    : Natural := 0;
      First_Expired : Natural := 0;
      LRU_Index     : KV_Slot_Index := 1;
      LRU_Time      : Epoch_Seconds := Store.Slots (1).Last_Access;
   begin
      for I in KV_Slot_Index loop
         pragma Loop_Invariant
           (First_Free <= Max_KV_Capacity
            and First_Expired <= Max_KV_Capacity);
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            return I;
         end if;
         if not Store.Slots (I).Occupied and then First_Free = 0 then
            First_Free := I;
         elsif Is_Slot_Expired (Store.Slots (I), Now) and then First_Expired = 0 then
            First_Expired := I;
         end if;
         if Store.Slots (I).Occupied and then Store.Slots (I).Last_Access < LRU_Time then
            LRU_Time  := Store.Slots (I).Last_Access;
            LRU_Index := I;
         end if;
      end loop;

      if First_Free in KV_Slot_Index then
         return First_Free;
      elsif First_Expired in KV_Slot_Index then
         return First_Expired;
      else
         return LRU_Index;
      end if;
   end Select_Target_Slot;

   function Format_Int64 (V : Integer_64) return Bounded_Text is
      Rev  : String (1 .. 20) := [others => '0'];
      D_Ln : Natural range 0 .. 20 := 0;
      Mag  : Unsigned_64;
      Neg  : Boolean := False;
      Res  : Bounded_Text;
      Pos  : Natural range 0 .. 21 := 0;
   begin
      if V = 0 then
         return Make_Text ("0");
      elsif V > 0 then
         Mag := Unsigned_64 (V);
      elsif V = Integer_64'First then
         Mag := Unsigned_64 (Integer_64'Last) + 1;
         Neg := True;
      else
         Mag := Unsigned_64 (-V);
         Neg := True;
      end if;

      for Step in 1 .. 20 loop
         pragma Loop_Invariant (D_Ln < Step);
         exit when Mag = 0;
         D_Ln       := D_Ln + 1;
         Rev (D_Ln) := Character'Val (Character'Pos ('0') + Natural (Mag mod 10));
         Mag        := Mag / 10;
      end loop;

      if Neg then
         Pos            := 1;
         Res.Data (Pos) := '-';
      end if;

      for I in 1 .. D_Ln loop
         pragma Loop_Invariant (Pos = (if Neg then I else I - 1));
         Pos            := Pos + 1;
         Res.Data (Pos) := Rev (D_Ln - I + 1);
      end loop;

      Res.Length := Pos;
      return Res;
   end Format_Int64;

   --  Redis `string2ll` integer syntax: an optional '-' followed by a non-empty run of
   --  decimal digits with no leading zero (the single digit "0" excepted), no '+',
   --  no "-0", no surrounding blanks, and a value inside the Integer_64 range
   procedure Try_Parse_Int64
     (Text   : in     Bounded_Text;
      Parsed :    out Integer_64;
      Is_Int :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if not Is_Int then Parsed = 0)
                    and then (if Is_Int then Text.Length in 1 .. 20)
   is
      Start_Idx : Positive := 1;
      Neg       : Boolean  := False;
      Limit     : Unsigned_64;
      Acc       : Unsigned_64 := 0;
      Digit     : Unsigned_64;
   begin
      Parsed := 0;
      Is_Int := False;

      if Text.Length = 0 or else Text.Length > 20 then
         return;
      end if;

      if Text.Data (1) = '-' then
         Neg       := True;
         Start_Idx := 2;
      end if;

      if Start_Idx > Text.Length then
         return;
      end if;

      --  "0" is the only spelling of zero; any other leading zero (or "-0") is rejected
      if Text.Data (Start_Idx) = '0' and then (Neg or else Text.Length > 1) then
         return;
      end if;

      Limit :=
        (if Neg then Unsigned_64 (Integer_64'Last) + 1
         else Unsigned_64 (Integer_64'Last));

      for I in Start_Idx .. Text.Length loop
         pragma Loop_Invariant (I in Start_Idx .. Text.Length and Acc <= Limit);
         if Text.Data (I) not in '0' .. '9' then
            return;
         end if;
         Digit := Unsigned_64 (Character'Pos (Text.Data (I)) - Character'Pos ('0'));
         if Acc > (Limit - Digit) / 10 then
            return;
         end if;
         Acc := Acc * 10 + Digit;
      end loop;

      if Neg then
         if Acc = Unsigned_64 (Integer_64'Last) + 1 then
            Parsed := Integer_64'First;
         else
            Parsed := -Integer_64 (Acc);
         end if;
      else
         Parsed := Integer_64 (Acc);
      end if;
      Is_Int := True;
   end Try_Parse_Int64;

   procedure Set
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Val     : in     Bounded_Text;
      Now     : in     Epoch_Seconds;
      Has_TTL : in     Boolean       := False;
      TTL_Sec : in     Epoch_Seconds := 0)
   is
      Target     : KV_Slot_Index;
      Parsed_Int : Integer_64;
      Numeric_Ok : Boolean;
   begin
      --  Clear any duplicate slots for Key first so Exists is deterministic
      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            Store.Slots (I).Occupied := False;
         end if;
      end loop;

      Try_Parse_Int64 (Val, Parsed_Int, Numeric_Ok);
      Target := Select_Target_Slot (Store, Key, Now);
      Store.Slots (Target) := (
         Key         => Key,
         Val         => Val,
         Int_Val     => (if Numeric_Ok then Parsed_Int else 0),
         Is_Numeric  => Numeric_Ok,
         Has_TTL     => Has_TTL,
         Expires_At  => (if Has_TTL then Now + TTL_Sec else 0),
         Last_Access => Now,
         Occupied    => True
      );
      pragma Assert
        (Store.Slots (Target).Occupied
         and then not Is_Slot_Expired (Store.Slots (Target), Now)
         and then Equal_Ident (Store.Slots (Target).Key, Key));
   end Set;

   procedure Get
     (Store  : in out KV_Store;
      Key    : in     Bounded_Ident;
      Now    : in     Epoch_Seconds;
      Val    :    out Bounded_Text;
      Status :    out Engine_Status)
   is
   begin
      Val    := (Length => 0, Data => [others => ' ']);
      Status := Status_Not_Found;

      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            if Is_Slot_Expired (Store.Slots (I), Now) then
               --  Reported, not reclaimed: reads never change the slot layout, which
               --  only logged writes may do (BR-004)
               Status := Status_Expired;
               return;
            else
               Store.Slots (I).Last_Access := Now;
               Val    := Store.Slots (I).Val;
               Status := Status_Ok;
               pragma Assert
                 (Store.Slots (I).Occupied
                  and then not Is_Slot_Expired (Store.Slots (I), Now)
                  and then Equal_Ident (Store.Slots (I).Key, Key));
               return;
            end if;
         end if;
      end loop;
   end Get;

   procedure Del
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Removed :    out Boolean)
   is
   begin
      Removed := False;
      for I in KV_Slot_Index loop
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 =>
              not (Store.Slots (J).Occupied
                   and then Equal_Ident (Store.Slots (J).Key, Key)));
         pragma Loop_Invariant
           (for all J in I .. Max_KV_Capacity =>
              Store.Slots (J) = Store'Loop_Entry.Slots (J));
         pragma Loop_Invariant
           (Removed =
              (for some J in 1 .. I - 1 =>
                 Store'Loop_Entry.Slots (J).Occupied
                 and then Equal_Ident (Store'Loop_Entry.Slots (J).Key, Key)));
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            Store.Slots (I).Occupied := False;
            Removed := True;
         end if;
      end loop;
   end Del;

   procedure Del
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Now     : in     Epoch_Seconds;
      Removed :    out Boolean)
   is
      Was_Live : constant Boolean := Exists (Store, Key, Now);
      Freed    : Boolean;
      pragma Warnings (Off, Freed);
   begin
      Del (Store, Key, Freed);
      Removed := Was_Live;
   end Del;

   procedure Expire
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Now     : in     Epoch_Seconds;
      TTL_Sec : in     Epoch_Seconds;
      Updated :    out Boolean)
   is
   begin
      Updated := False;
      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            if Is_Slot_Expired (Store.Slots (I), Now) then
               --  An expired key is absent; its slot stays as it is (see Get)
               return;
            else
               Store.Slots (I).Has_TTL     := True;
               Store.Slots (I).Expires_At  := Now + TTL_Sec;
               Store.Slots (I).Last_Access := Now;
               Updated := True;
               pragma Assert
                 (Store.Slots (I).Occupied
                  and then not Is_Slot_Expired (Store.Slots (I), Now)
                  and then Equal_Ident (Store.Slots (I).Key, Key));
               return;
            end if;
         end if;
      end loop;
   end Expire;

   function Remaining_TTL
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Integer_64
   is
   begin
      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            if Is_Slot_Expired (Store.Slots (I), Now) then
               return -2;
            elsif not Store.Slots (I).Has_TTL then
               return -1;
            else
               pragma Assert
                 (Store.Slots (I).Occupied
                  and then not Is_Slot_Expired (Store.Slots (I), Now)
                  and then Equal_Ident (Store.Slots (I).Key, Key));
               return Store.Slots (I).Expires_At - Now;
            end if;
         end if;
      end loop;
      return -2;
   end Remaining_TTL;

   procedure Incr_By
     (Store     : in out KV_Store;
      Key       : in     Bounded_Ident;
      Delta_Val : in     Integer_64;
      Now       : in     Epoch_Seconds;
      New_Val   :    out Integer_64;
      Status    :    out Engine_Status)
   is
      Target : KV_Slot_Index;
   begin
      New_Val := 0;
      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            if not Is_Slot_Expired (Store.Slots (I), Now) then
               if not Store.Slots (I).Is_Numeric then
                  Status := Status_Type_Mismatch;
                  return;
               end if;
               if (Delta_Val > 0 and then Store.Slots (I).Int_Val > Integer_64'Last - Delta_Val)
                 or else (Delta_Val < 0 and then Store.Slots (I).Int_Val < Integer_64'First - Delta_Val)
               then
                  Status := Status_Capacity_Exceeded;
                  return;
               end if;
               New_Val                     := Store.Slots (I).Int_Val + Delta_Val;
               Store.Slots (I).Int_Val     := New_Val;
               Store.Slots (I).Val         := Format_Int64 (New_Val);
               Store.Slots (I).Last_Access := Now;
               Status  := Status_Ok;
               pragma Assert
                 (Store.Slots (I).Occupied
                  and then not Is_Slot_Expired (Store.Slots (I), Now)
                  and then Equal_Ident (Store.Slots (I).Key, Key));
               return;
            end if;
            --  An expired entry counts as absent: Select_Target_Slot below returns its
            --  slot, which the new value overwrites
            exit;
         end if;
      end loop;

      Target := Select_Target_Slot (Store, Key, Now);
      Store.Slots (Target) := (
         Key         => Key,
         Val         => Format_Int64 (Delta_Val),
         Int_Val     => Delta_Val,
         Is_Numeric  => True,
         Has_TTL     => False,
         Expires_At  => 0,
         Last_Access => Now,
         Occupied    => True
      );
      pragma Assert
        (Store.Slots (Target).Occupied
         and then not Is_Slot_Expired (Store.Slots (Target), Now)
         and then Equal_Ident (Store.Slots (Target).Key, Key));
      New_Val := Delta_Val;
      Status  := Status_Ok;
   end Incr_By;

   -------------------------------------------------------------------------
   --  Optional Durable WAL Persistence & Crash Recovery for KV (Q-004)
   -------------------------------------------------------------------------

   procedure Put_U32_BE
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
   end Put_U32_BE;

   function Get_U32_BE
     (Page   : Page_Buffer;
      Offset : Page_Offset) return Unsigned_32
     with Pre => Offset <= Nhe_O.Page_Size - 3
   is
   begin
      return Shift_Left (Unsigned_32 (Page (Offset)), 24)
        or Shift_Left (Unsigned_32 (Page (Offset + 1)), 16)
        or Shift_Left (Unsigned_32 (Page (Offset + 2)), 8)
        or Unsigned_32 (Page (Offset + 3));
   end Get_U32_BE;

   procedure Encode_KV_Wal_Page
     (Op     : in     KV_Wal_Op;
      Slot   : in     KV_Entry;
      Page   :    out Page_Buffer;
      Target : in     KV_Slot_Count := 0)
   is
      Exp_U64  : constant Unsigned_64 := Unsigned_64 (Slot.Expires_At);
      Acc_U64  : constant Unsigned_64 := Unsigned_64 (Slot.Last_Access);
      Page_CRC : Unsigned_32;
   begin
      Page := [others => 0];
      Page (1) := KV_Magic_0;
      Page (2) := KV_Magic_1;
      Page (3) := KV_Magic_2;
      Page (4) := KV_Magic_3;
      Page (5) := (if Op = KV_Op_Set then 1 else 2);
      Page (6) := (if Slot.Has_TTL then 1 else 0);
      Page (7) := Byte (Slot.Key.Length);
      Page (8) := (if Op = KV_Op_Set then Byte (Target) else 0);

      Put_U32_BE (Page, 9,  Unsigned_32 (Slot.Val.Length));
      Put_U32_BE (Page, 13, Unsigned_32 (Shift_Right (Exp_U64, 32)));
      Put_U32_BE (Page, 17, Unsigned_32 (Exp_U64 and 16#FFFF_FFFF#));
      Put_U32_BE (Page, 21, Unsigned_32 (Shift_Right (Acc_U64, 32)));
      Put_U32_BE (Page, 25, Unsigned_32 (Acc_U64 and 16#FFFF_FFFF#));
      --  Bytes 29..32 reserved for page CRC32

      --  Bytes 33..96: Key (up to 64 bytes)
      for I in 1 .. Slot.Key.Length loop
         Page (32 + I) := Byte (Character'Pos (Slot.Key.Data (I)));
      end loop;

      --  Bytes 97..608: Val (up to 512 bytes)
      for I in 1 .. Slot.Val.Length loop
         Page (96 + I) := Byte (Character'Pos (Slot.Val.Data (I)));
      end loop;

      Page_CRC := Compute_CRC32 (Page);
      Put_U32_BE (Page, 29, Page_CRC);
   end Encode_KV_Wal_Page;

   procedure Decode_KV_Wal_Page
     (Page   : in     Page_Buffer;
      Op     :    out KV_Wal_Op;
      Slot   :    out KV_Entry;
      Target :    out KV_Slot_Count;
      Valid  :    out Boolean)
   is
      Zeroed_Page : Page_Buffer := Page;
      Stored_CRC  : Unsigned_32;
      Raw_Op      : Byte;
      Raw_TTL     : Byte;
      Raw_Key_Len : Natural;
      Raw_Val_Len : Unsigned_32;
      Exp_Hi      : Unsigned_32;
      Exp_Lo      : Unsigned_32;
      Acc_Hi      : Unsigned_32;
      Acc_Lo      : Unsigned_32;
      Exp_U64     : Unsigned_64;
      Acc_U64     : Unsigned_64;
      Parsed_Int  : Integer_64;
      Numeric_Ok  : Boolean;
   begin
      Op     := KV_Op_Set;
      Slot   := (others => <>);
      Target := 0;
      Valid  := False;

      if Page (1) /= KV_Magic_0
        or else Page (2) /= KV_Magic_1
        or else Page (3) /= KV_Magic_2
        or else Page (4) /= KV_Magic_3
      then
         return;
      end if;

      Stored_CRC       := Get_U32_BE (Page, 29);
      Zeroed_Page (29) := 0;
      Zeroed_Page (30) := 0;
      Zeroed_Page (31) := 0;
      Zeroed_Page (32) := 0;
      if Compute_CRC32 (Zeroed_Page) /= Stored_CRC then
         return;
      end if;

      Raw_Op      := Page (5);
      Raw_TTL     := Page (6);
      Raw_Key_Len := Natural (Page (7));
      Raw_Val_Len := Get_U32_BE (Page, 9);

      if Raw_Op not in 1 .. 2
        or else Raw_TTL > 1
        or else Raw_Key_Len = 0
        or else Raw_Key_Len > Max_Ident_Len
        or else Natural (Page (8)) > Max_KV_Capacity
        or else (Raw_Op = 2 and then Page (8) /= 0)
        or else Raw_Val_Len > Unsigned_32 (Max_Text_Len)
        or else (for some B in 609 .. Nhe_O.Page_Size => Page (B) /= 0)
      then
         return;
      end if;

      Exp_Hi  := Get_U32_BE (Page, 13);
      Exp_Lo  := Get_U32_BE (Page, 17);
      Acc_Hi  := Get_U32_BE (Page, 21);
      Acc_Lo  := Get_U32_BE (Page, 25);
      Exp_U64 := Shift_Left (Unsigned_64 (Exp_Hi), 32) or Unsigned_64 (Exp_Lo);
      Acc_U64 := Shift_Left (Unsigned_64 (Acc_Hi), 32) or Unsigned_64 (Acc_Lo);

      if Exp_U64 > Unsigned_64 (Epoch_Seconds'Last)
        or else Acc_U64 > Unsigned_64 (Epoch_Seconds'Last)
        or else (Raw_TTL = 0 and then Exp_U64 /= 0)
        or else (Raw_Op = 2
                 and then (Raw_TTL /= 0
                           or else Raw_Val_Len /= 0
                           or else Exp_U64 /= 0
                           or else Acc_U64 /= 0))
      then
         return;
      end if;

      Op := (if Raw_Op = 1 then KV_Op_Set else KV_Op_Del);

      Slot.Key.Length := Raw_Key_Len;
      for I in 1 .. Raw_Key_Len loop
         Slot.Key.Data (I) := Character'Val (Natural (Page (32 + I)));
      end loop;

      Slot.Val.Length := Natural (Raw_Val_Len);
      for I in 1 .. Slot.Val.Length loop
         Slot.Val.Data (I) := Character'Val (Natural (Page (96 + I)));
      end loop;

      Try_Parse_Int64 (Slot.Val, Parsed_Int, Numeric_Ok);
      Slot.Int_Val     := (if Numeric_Ok then Parsed_Int else 0);
      Slot.Is_Numeric  := Numeric_Ok;
      Slot.Has_TTL     := (Raw_TTL = 1);
      Slot.Expires_At  := Epoch_Seconds (Exp_U64);
      Slot.Last_Access := Epoch_Seconds (Acc_U64);
      Slot.Occupied    := (Op = KV_Op_Set);
      Target           := (if Op = KV_Op_Set then KV_Slot_Count (Page (8)) else 0);
      Valid            := True;
   end Decode_KV_Wal_Page;

   procedure Decode_KV_Wal_Page
     (Page  : in     Page_Buffer;
      Op    :    out KV_Wal_Op;
      Slot  :    out KV_Entry;
      Valid :    out Boolean)
   is
      Ignored_Target : KV_Slot_Count;
      pragma Warnings (Off, Ignored_Target);
   begin
      Decode_KV_Wal_Page (Page, Op, Slot, Ignored_Target, Valid);
   end Decode_KV_Wal_Page;

   --  Slot currently holding Key (0 when Key is not stored)
   function Key_Slot
     (Store : KV_Store;
      Key   : Bounded_Ident) return KV_Slot_Count
     with Global => null,
          Post   => (if Key_Slot'Result > 0 then
                       Store.Slots (Key_Slot'Result).Occupied
                       and then Equal_Ident (Store.Slots (Key_Slot'Result).Key, Key))
   is
   begin
      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            return I;
         end if;
      end loop;
      return 0;
   end Key_Slot;

   procedure Set_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Val      : in     Bounded_Text;
      Now      : in     Epoch_Seconds;
      Has_TTL  : in     Boolean       := False;
      TTL_Sec  : in     Epoch_Seconds := 0;
      Status   :    out Engine_Status)
   is
      Saved_Store : constant KV_Store := Store;
      Entry_Rec   : KV_Entry;
      Target      : KV_Slot_Count;
      Page        : Page_Buffer;
      Frame       : WAL_Frame_Buffer;
      CRC         : Unsigned_32;
      pragma Warnings (Off, CRC);
      WAL_Ok      : Boolean;
   begin
      Set (Store, Key, Val, Now, Has_TTL, TTL_Sec);

      --  Log the exact slot the value landed in: replay then evicts the same victim
      Target := Key_Slot (Store, Key);
      if Target > 0 then
         Entry_Rec := Store.Slots (Target);
      else
         Entry_Rec := (
            Key         => Key,
            Val         => Val,
            Int_Val     => 0,
            Is_Numeric  => False,
            Has_TTL     => Has_TTL,
            Expires_At  => (if Has_TTL then Now + TTL_Sec else 0),
            Last_Access => Now,
            Occupied    => True
         );
      end if;
      Encode_KV_Wal_Page (KV_Op_Set, Entry_Rec, Page, Target);
      Encode_WAL_Frame (Tx, 0, Page, CRC, Frame, WAL_Frame_KV);
      Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);

      if WAL_Ok then
         Status := Status_Ok;
      else
         Store  := Saved_Store;
         Status := Status_IO_Error;
      end if;
   end Set_Durable;

   procedure Append_Del_Frame
     (WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      WAL_Ok   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0
   is
      Entry_Rec : constant KV_Entry := (
         Key         => Key,
         Val         => (Length => 0, Data => [others => ' ']),
         Int_Val     => 0,
         Is_Numeric  => False,
         Has_TTL     => False,
         Expires_At  => 0,
         Last_Access => 0,
         Occupied    => False
      );
      Page      : Page_Buffer;
      Frame     : WAL_Frame_Buffer;
      CRC       : Unsigned_32;
      pragma Warnings (Off, CRC);
   begin
      Encode_KV_Wal_Page (KV_Op_Del, Entry_Rec, Page);
      Encode_WAL_Frame (Tx, 0, Page, CRC, Frame, WAL_Frame_KV);
      Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);
   end Append_Del_Frame;

   procedure Del_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Removed  :    out Boolean;
      Status   :    out Engine_Status)
   is
      Saved_Store : constant KV_Store := Store;
      WAL_Ok      : Boolean;
   begin
      Del (Store, Key, Removed);
      if not Removed then
         Status := Status_Ok;
         return;
      end if;

      Append_Del_Frame (WAL_Path, Tx, Key, WAL_Ok);
      if WAL_Ok then
         Status := Status_Ok;
      else
         Store   := Saved_Store;
         Removed := False;
         Status  := Status_IO_Error;
      end if;
   end Del_Durable;

   procedure Del_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Now      : in     Epoch_Seconds;
      Removed  :    out Boolean;
      Logged   :    out Boolean;
      Status   :    out Engine_Status)
   is
      Saved_Store : constant KV_Store := Store;
      Was_Live    : constant Boolean  := Exists (Store, Key, Now);
      Freed       : Boolean;
      WAL_Ok      : Boolean;
   begin
      Del (Store, Key, Freed);
      if not Freed then
         Removed := False;
         Logged  := False;
         Status  := Status_Ok;
         return;
      end if;

      --  Log every freed slot (live or expired) so replay reproduces the slot layout
      Append_Del_Frame (WAL_Path, Tx, Key, WAL_Ok);
      if WAL_Ok then
         Removed := Was_Live;
         Logged  := True;
         Status  := Status_Ok;
      else
         Store   := Saved_Store;
         Removed := False;
         Logged  := False;
         Status  := Status_IO_Error;
      end if;
   end Del_Durable;

   procedure Expire_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Now      : in     Epoch_Seconds;
      TTL_Sec  : in     Epoch_Seconds;
      Updated  :    out Boolean;
      Status   :    out Engine_Status)
   is
      Saved_Store : constant KV_Store := Store;
      Entry_Rec   : KV_Entry          := (others => <>);
      Target      : KV_Slot_Count;
      Page        : Page_Buffer;
      Frame       : WAL_Frame_Buffer;
      CRC         : Unsigned_32;
      pragma Warnings (Off, CRC);
      WAL_Ok      : Boolean;
   begin
      Expire (Store, Key, Now, TTL_Sec, Updated);
      if not Updated then
         Status := Status_Ok;
         return;
      end if;

      Target := Key_Slot (Store, Key);
      if Target > 0 then
         Entry_Rec := Store.Slots (Target);
      end if;

      Encode_KV_Wal_Page (KV_Op_Set, Entry_Rec, Page, Target);
      Encode_WAL_Frame (Tx, 0, Page, CRC, Frame, WAL_Frame_KV);
      Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);

      if WAL_Ok then
         Status := Status_Ok;
      else
         Store   := Saved_Store;
         Updated := False;
         Status  := Status_IO_Error;
      end if;
   end Expire_Durable;

   procedure Incr_By_Durable
     (Store     : in out KV_Store;
      WAL_Path  : in     Bounded_Text;
      Tx        : in     Valid_Tx_Id;
      Key       : in     Bounded_Ident;
      Delta_Val : in     Integer_64;
      Now       : in     Epoch_Seconds;
      New_Val   :    out Integer_64;
      Status    :    out Engine_Status)
   is
      Saved_Store : constant KV_Store := Store;
      Entry_Rec   : KV_Entry          := (others => <>);
      Target      : KV_Slot_Count;
      Page        : Page_Buffer;
      Frame       : WAL_Frame_Buffer;
      CRC         : Unsigned_32;
      pragma Warnings (Off, CRC);
      WAL_Ok      : Boolean;
   begin
      Incr_By (Store, Key, Delta_Val, Now, New_Val, Status);
      if Status /= Status_Ok then
         Store := Saved_Store;
         return;
      end if;

      Target := Key_Slot (Store, Key);
      if Target > 0 then
         Entry_Rec := Store.Slots (Target);
      end if;

      Encode_KV_Wal_Page (KV_Op_Set, Entry_Rec, Page, Target);
      Encode_WAL_Frame (Tx, 0, Page, CRC, Frame, WAL_Frame_KV);
      Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);

      if not WAL_Ok then
         Store   := Saved_Store;
         New_Val := 0;
         Status  := Status_IO_Error;
      end if;
   end Incr_By_Durable;

   procedure Recover_KV_From_WAL
     (Store        : in out KV_Store;
      WAL_Path     : in     Bounded_Text;
      Now          : in     Epoch_Seconds;
      Max_Frames   : in     Positive;
      Replayed_Ops :    out Natural;
      Status       :    out Engine_Status)
   is
      Saved_Store   : constant KV_Store := Store;
      Frame         : WAL_Frame_Buffer;
      Page          : Page_Buffer;
      Frame_Tx      : Valid_Tx_Id;
      Page_Id       : Valid_Page_Id;
      pragma Warnings (Off, Frame);
      pragma Warnings (Off, Frame_Tx);
      pragma Warnings (Off, Page_Id);
      Read_Ok       : Boolean;
      Is_EOF        : Boolean;
      Op            : KV_Wal_Op;
      Slot          : KV_Entry;
      Target        : KV_Slot_Count;
      Valid         : Boolean;
      Removed       : Boolean;
      pragma Warnings (Off, Removed);
      Legacy_Target : KV_Slot_Index;
      Effective_Now : Epoch_Seconds := Now;
      Repair_Stat   : Engine_Status;
      WAL_Exists    : Boolean;
   begin
      Replayed_Ops := 0;
      Status       := Status_Ok;

      --  A missing WAL is an empty log
      Check_File_Exists (WAL_Path, WAL_Exists);
      if not WAL_Exists then
         return;
      end if;

      --  Drop a torn trailing frame left by a crash during Append_WAL_Frame
      Repair_WAL_Tail (WAL_Path, Repair_Stat);
      if Repair_Stat /= Status_Ok then
         Status := Repair_Stat;
         return;
      end if;

      for Idx in 0 .. Max_Frames - 1 loop
         pragma Loop_Invariant (Replayed_Ops <= Idx);
         Read_WAL_Frame (WAL_Path, Idx, Frame, Read_Ok, Is_EOF);
         if not Read_Ok then
            if Is_EOF then
               return;
            else
               Store        := Saved_Store;
               Replayed_Ops := 0;
               Status       := Status_IO_Error;
               return;
            end if;
         end if;

         if not Verify_WAL_Frame (Frame) then
            Store        := Saved_Store;
            Replayed_Ops := 0;
            Status       := Status_IO_Error;
            return;
         end if;

         if Get_WAL_Frame_Kind (Frame) = WAL_Frame_KV then
            Decode_WAL_Frame (Frame, Frame_Tx, Page_Id, Page);
            Decode_KV_Wal_Page (Page, Op, Slot, Target, Valid);
            if not Valid then
               Store        := Saved_Store;
               Replayed_Ops := 0;
               Status       := Status_Invalid_Syntax;
               return;
            end if;

            if Op = KV_Op_Del then
               Del (Store, Slot.Key, Removed);
            elsif Target in KV_Slot_Index then
               --  Exact slot replay: whatever occupied Target at run time was overwritten
               --  (an LRU / expired-slot eviction), and Key lives in no other slot
               for I in KV_Slot_Index loop
                  if I /= Target
                    and then Store.Slots (I).Occupied
                    and then Equal_Ident (Store.Slots (I).Key, Slot.Key)
                  then
                     Store.Slots (I).Occupied := False;
                  end if;
               end loop;
               Store.Slots (Target) := Slot;
            else
               --  Legacy frame without a slot hint: re-select a slot at the frame's time
               if Slot.Last_Access > Effective_Now then
                  Effective_Now := Slot.Last_Access;
               end if;

               for I in KV_Slot_Index loop
                  if Is_Slot_Expired (Store.Slots (I), Effective_Now) then
                     Store.Slots (I).Occupied := False;
                  end if;
               end loop;

               if Slot.Has_TTL and then Effective_Now >= Slot.Expires_At then
                  Del (Store, Slot.Key, Removed);
               else
                  for I in KV_Slot_Index loop
                     if Store.Slots (I).Occupied
                       and then Equal_Ident (Store.Slots (I).Key, Slot.Key)
                     then
                        Store.Slots (I).Occupied := False;
                     end if;
                  end loop;
                  Legacy_Target := Select_Target_Slot (Store, Slot.Key, Effective_Now);
                  Store.Slots (Legacy_Target) := Slot;
               end if;
            end if;
            Replayed_Ops := Replayed_Ops + 1;
         end if;
      end loop;

      --  Detect WAL truncation or torn/corrupted frame at Max_Frames
      if Max_Frames < Max_Page_Id then
         Read_WAL_Frame (WAL_Path, Valid_Page_Id (Max_Frames), Frame, Read_Ok, Is_EOF);
         if Read_Ok then
            Store        := Saved_Store;
            Replayed_Ops := 0;
            Status       := (if Verify_WAL_Frame (Frame)
                             then Status_Capacity_Exceeded
                             else Status_IO_Error);
            return;
         elsif not Is_EOF then
            Store        := Saved_Store;
            Replayed_Ops := 0;
            Status       := Status_IO_Error;
            return;
         end if;
      end if;
   end Recover_KV_From_WAL;

   function Occupied_Count (Store : KV_Store) return KV_Slot_Count is
      Count : KV_Slot_Count := 0;
   begin
      for I in KV_Slot_Index loop
         pragma Loop_Invariant (Count < I);
         if Store.Slots (I).Occupied then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Occupied_Count;

   procedure Write_KV_Snapshot
     (Store     : in     KV_Store;
      WAL_Path  : in     Bounded_Text;
      First_Seq : in     Valid_Tx_Id;
      Next_Seq  :    out Valid_Tx_Id;
      Status    :    out Engine_Status)
   is
      Page   : Page_Buffer;
      Frame  : WAL_Frame_Buffer;
      CRC    : Unsigned_32;
      pragma Warnings (Off, CRC);
      WAL_Ok : Boolean;
   begin
      Next_Seq := First_Seq;
      Status   := Status_Ok;

      for I in KV_Slot_Index loop
         pragma Loop_Invariant (Next_Seq in First_Seq .. First_Seq + Tx_Id (I - 1));
         if Store.Slots (I).Occupied and then Store.Slots (I).Key.Length > 0 then
            Encode_KV_Wal_Page (KV_Op_Set, Store.Slots (I), Page, I);
            Encode_WAL_Frame (Next_Seq, 0, Page, CRC, Frame, WAL_Frame_KV);
            Append_WAL_Frame (WAL_Path, Frame, WAL_Ok);
            if not WAL_Ok then
               Status := Status_IO_Error;
               return;
            end if;
            Next_Seq := Next_Seq + 1;
         end if;
      end loop;
   end Write_KV_Snapshot;

end Nhe_O.KV;
