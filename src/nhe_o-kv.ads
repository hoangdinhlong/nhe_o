--  Formally verified Redis-compatible Key-Value Cache Engine with TTL & LRU Eviction (BR-004)
pragma SPARK_Mode (On);

with Interfaces; use Interfaces;
with Nhe_O.Types; use Nhe_O.Types;

package Nhe_O.KV is

   Max_KV_Capacity : constant := 64;
   subtype KV_Slot_Index is Positive range 1 .. Max_KV_Capacity;
   subtype KV_Slot_Count is Natural range 0 .. Max_KV_Capacity;

   type KV_Entry is record
      Key         : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Val         : Bounded_Text  := (Length => 0, Data => [others => ' ']);
      Int_Val     : Integer_64    := 0;
      Is_Numeric  : Boolean       := False;
      Has_TTL     : Boolean       := False;
      Expires_At  : Epoch_Seconds := 0;
      Last_Access : Epoch_Seconds := 0;
      Occupied    : Boolean       := False;
   end record;

   type KV_Entry_Array is array (KV_Slot_Index) of KV_Entry;

   type KV_Store is record
      Slots : KV_Entry_Array := [others => (others => <>)];
   end record;

   --  BR-004: Predicate determining if a slot is expired at timestamp Now
   function Is_Slot_Expired
     (Slot : KV_Entry;
      Now  : Epoch_Seconds) return Boolean
   is
     (Slot.Occupied and then Slot.Has_TTL and then Now >= Slot.Expires_At);

   --  Redis `EXISTS`: True iff Key exists and has not expired at timestamp Now
   function Exists
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Boolean
     with Global => null,
          Post   => Exists'Result =
                      (for some I in KV_Slot_Index =>
                         Store.Slots (I).Occupied
                         and then not Is_Slot_Expired (Store.Slots (I), Now)
                         and then Equal_Ident (Store.Slots (I).Key, Key));

   --  Redis `SET` / `SETEX`: Store key-value pair with optional TTL; evicts expired or LRU slot if full
   procedure Set
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Val     : in     Bounded_Text;
      Now     : in     Epoch_Seconds;
      Has_TTL : in     Boolean       := False;
      TTL_Sec : in     Epoch_Seconds := 0)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0
                    and then (if Has_TTL then TTL_Sec > 0 and then Now <= Epoch_Seconds'Last - TTL_Sec),
          Post   => Exists (Store, Key, Now);

   --  Redis `GET`: Retrieve value if present and not expired; updates LRU timestamp
   procedure Get
     (Store  : in out KV_Store;
      Key    : in     Bounded_Ident;
      Now    : in     Epoch_Seconds;
      Val    :    out Bounded_Text;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates;

   --  Redis `DEL`: Remove key from store
   procedure Del
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Removed :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => not Exists (Store, Key, 0);

   --  Redis `EXPIRE`: Attach a TTL in seconds to an existing live key
   procedure Expire
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Now     : in     Epoch_Seconds;
      TTL_Sec : in     Epoch_Seconds;
      Updated :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => TTL_Sec > 0 and then Now <= Epoch_Seconds'Last - TTL_Sec;

   --  Redis `TTL`: Return remaining seconds (-2 if missing/expired, -1 if no TTL)
   function Remaining_TTL
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Integer_64
     with Global => null;

   --  Redis `INCRBY`: Atomically increment numeric value of Key by Delta_Val
   procedure Incr_By
     (Store     : in out KV_Store;
      Key       : in     Bounded_Ident;
      Delta_Val : in     Integer_64;
      Now       : in     Epoch_Seconds;
      New_Val   :    out Integer_64;
      Status    :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0;

end Nhe_O.KV;
