pragma SPARK_Mode (On);

package body Nhe_O.KV is

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

   procedure Try_Parse_Int64
     (Text   : in     Bounded_Text;
      Parsed :    out Integer_64;
      Is_Int :    out Boolean)
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
      elsif Text.Data (1) = '+' then
         Start_Idx := 2;
      end if;

      if Start_Idx > Text.Length then
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
               --  Lazy TTL reclamation (BR-004)
               Store.Slots (I).Occupied := False;
               Status := Status_Expired;
               return;
            else
               Store.Slots (I).Last_Access := Now;
               Val    := Store.Slots (I).Val;
               Status := Status_Ok;
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
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            Store.Slots (I).Occupied := False;
            Removed := True;
         end if;
      end loop;
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
               Store.Slots (I).Occupied := False;
               return;
            else
               Store.Slots (I).Has_TTL     := True;
               Store.Slots (I).Expires_At  := Now + TTL_Sec;
               Store.Slots (I).Last_Access := Now;
               Updated := True;
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
               return;
            else
               Store.Slots (I).Occupied := False;
            end if;
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
      New_Val := Delta_Val;
      Status  := Status_Ok;
   end Incr_By;

end Nhe_O.KV;
