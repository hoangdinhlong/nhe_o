pragma SPARK_Mode (On);

package body Nhe_O.KV is

   function Exists
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Boolean
   is
   begin
      for I in KV_Slot_Index loop
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

   procedure Set
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Val     : in     Bounded_Text;
      Now     : in     Epoch_Seconds;
      Has_TTL : in     Boolean       := False;
      TTL_Sec : in     Epoch_Seconds := 0)
   is
      Target : KV_Slot_Index;
   begin
      --  Clear any duplicate slots for Key first so Exists is deterministic
      for I in KV_Slot_Index loop
         if Store.Slots (I).Occupied and then Equal_Ident (Store.Slots (I).Key, Key) then
            Store.Slots (I).Occupied := False;
         end if;
      end loop;

      Target := Select_Target_Slot (Store, Key, Now);
      Store.Slots (Target) := (
         Key         => Key,
         Val         => Val,
         Int_Val     => 0,
         Is_Numeric  => False,
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
               Store.Slots (I).Int_Val     := Store.Slots (I).Int_Val + Delta_Val;
               Store.Slots (I).Last_Access := Now;
               New_Val := Store.Slots (I).Int_Val;
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
         Val         => Make_Text ("<int64>"),
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
