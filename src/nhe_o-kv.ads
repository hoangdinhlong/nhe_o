--  Formally verified Redis-compatible Key-Value Cache Engine with TTL, LRU Eviction,
--  and Optional WAL Persistence & Crash Recovery (ADR-007, BR-004, Q-004)
pragma SPARK_Mode (On);

with Interfaces;        use Interfaces;
with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.IO;          use Nhe_O.IO;
with Nhe_O.Transaction; use Nhe_O.Transaction;

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

   --  Redis `GET`: Retrieve value if present and not expired; updates the LRU timestamp
   --  (in memory only: read recency is not logged, see Recover_KV_From_WAL). An expired
   --  entry yields Status_Expired and stays in its slot: only logged writes (SET /
   --  INCRBY of the key, an eviction by another SET, DEL) change the slot layout, so a
   --  replayed WAL reproduces it. Timestamps are expected never to decrease.
   procedure Get
     (Store  : in out KV_Store;
      Key    : in     Bounded_Ident;
      Now    : in     Epoch_Seconds;
      Val    :    out Bounded_Text;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Post   => Status in Status_Ok | Status_Not_Found | Status_Expired
                    and then (if Status = Status_Ok then Exists (Store, Key, Now)
                              else Store = Store'Old);

   --  Remove every stored entry for Key (live or already expired); Removed is True iff
   --  at least one slot was freed. Used by WAL replay, which must be clock-free.
   procedure Del
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Removed :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => not Exists (Store, Key, 0)
                    and then Removed =
                      (for some I in KV_Slot_Index =>
                         Store'Old.Slots (I).Occupied
                         and then Equal_Ident (Store'Old.Slots (I).Key, Key));

   --  Redis `DEL` at timestamp Now: removes every stored entry for Key; Removed is True
   --  iff Key was live (present and not expired) at Now, matching Redis's reply count
   procedure Del
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Now     : in     Epoch_Seconds;
      Removed :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => not Exists (Store, Key, 0)
                    and then Removed = Exists (Store'Old, Key, Now);

   --  Redis `EXPIRE`: Attach a TTL in seconds to an existing live key (an expired or
   --  missing key is left untouched and Updated is False)
   procedure Expire
     (Store   : in out KV_Store;
      Key     : in     Bounded_Ident;
      Now     : in     Epoch_Seconds;
      TTL_Sec : in     Epoch_Seconds;
      Updated :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => TTL_Sec > 0 and then Now <= Epoch_Seconds'Last - TTL_Sec,
          Post   => (if Updated then Exists (Store, Key, Now) else Store = Store'Old);

   --  Redis `TTL`: Return remaining seconds (-2 if missing/expired, -1 if no TTL)
   function Remaining_TTL
     (Store : KV_Store;
      Key   : Bounded_Ident;
      Now   : Epoch_Seconds) return Integer_64
     with Global => null,
          Post   => Remaining_TTL'Result >= -2
                    and then (if Remaining_TTL'Result > 0 then Exists (Store, Key, Now));

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
          Pre    => Key.Length > 0,
          Post   => (if Status = Status_Ok then Exists (Store, Key, Now));

   -------------------------------------------------------------------------
   --  Optional Durable WAL Persistence & Crash Recovery for KV (Q-004)
   -------------------------------------------------------------------------

   type KV_Wal_Op is (KV_Op_Set, KV_Op_Del);

   --  Serialize a KV mutation into a 4096-byte WAL page with Magic "KVMG" + CRC32.
   --  Target is the store slot the SET landed in (1 .. Max_KV_Capacity), so replay
   --  reproduces the exact run-time slot layout, including LRU/expired-slot evictions
   --  that are never logged separately; 0 means "no slot hint" (legacy frames, DEL).
   procedure Encode_KV_Wal_Page
     (Op     : in     KV_Wal_Op;
      Slot   : in     KV_Entry;
      Page   :    out Page_Buffer;
      Target : in     KV_Slot_Count := 0)
     with Global => null,
          Always_Terminates;

   --  Deserialize and CRC32-verify a 4096-byte KV WAL page, returning its slot hint
   procedure Decode_KV_Wal_Page
     (Page   : in     Page_Buffer;
      Op     :    out KV_Wal_Op;
      Slot   :    out KV_Entry;
      Target :    out KV_Slot_Count;
      Valid  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Valid then Slot.Key.Length > 0
                     else Target = 0)
                    and then (if Valid and then Op = KV_Op_Del then Target = 0);

   --  Deserialize and CRC32-verify a 4096-byte KV WAL page
   procedure Decode_KV_Wal_Page
     (Page  : in     Page_Buffer;
      Op    :    out KV_Wal_Op;
      Slot  :    out KV_Entry;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Valid then Slot.Key.Length > 0);

   --  Durable SET / SETEX: updates in-memory KV_Store and appends a WAL_Frame_KV record
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
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0
                    and then WAL_Path.Length > 0
                    and then (if Has_TTL then TTL_Sec > 0 and then Now <= Epoch_Seconds'Last - TTL_Sec),
          Post   => (if Status = Status_Ok then Exists (Store, Key, Now)
                     else Store = Store'Old);

   --  Durable DEL: removes Key from in-memory KV_Store and appends a WAL_Frame_KV record
   --  (only when a slot was actually freed)
   procedure Del_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Removed  :    out Boolean;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0 and then WAL_Path.Length > 0,
          Post   => (if Status = Status_Ok then not Exists (Store, Key, 0)
                     else Store = Store'Old and then not Removed);

   --  Durable Redis DEL at timestamp Now: Removed is True iff Key was live at Now; a
   --  WAL_Frame_KV record is appended whenever a stored entry (live or expired) is freed
   procedure Del_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Now      : in     Epoch_Seconds;
      Removed  :    out Boolean;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0 and then WAL_Path.Length > 0,
          Post   => (if Status = Status_Ok then
                       not Exists (Store, Key, 0)
                       and then Removed = Exists (Store'Old, Key, Now)
                     else Store = Store'Old and then not Removed);

   --  Durable EXPIRE: attaches a TTL to Key and appends a WAL_Frame_KV record when updated
   procedure Expire_Durable
     (Store    : in out KV_Store;
      WAL_Path : in     Bounded_Text;
      Tx       : in     Valid_Tx_Id;
      Key      : in     Bounded_Ident;
      Now      : in     Epoch_Seconds;
      TTL_Sec  : in     Epoch_Seconds;
      Updated  :    out Boolean;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0
                    and then WAL_Path.Length > 0
                    and then TTL_Sec > 0
                    and then Now <= Epoch_Seconds'Last - TTL_Sec,
          Post   => (if Status = Status_Ok and then Updated then Exists (Store, Key, Now))
                    and then (if Status /= Status_Ok then Store = Store'Old and then not Updated);

   --  Durable INCRBY: increments numeric value of Key and appends a WAL_Frame_KV record
   procedure Incr_By_Durable
     (Store     : in out KV_Store;
      WAL_Path  : in     Bounded_Text;
      Tx        : in     Valid_Tx_Id;
      Key       : in     Bounded_Ident;
      Delta_Val : in     Integer_64;
      Now       : in     Epoch_Seconds;
      New_Val   :    out Integer_64;
      Status    :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0 and then WAL_Path.Length > 0,
          Post   => (if Status = Status_Ok then Exists (Store, Key, Now)
                     else Store = Store'Old);

   --  Replay all WAL_Frame_KV records from WAL_Path into Store (a missing WAL is an empty
   --  log). A torn trailing frame left by a crash is repaired first
   --  (Nhe_O.Transaction.Repair_WAL_Tail). Frames with a slot hint are applied to exactly
   --  that slot, so the recovered store has the pre-crash keys, values, TTLs and slot
   --  layout, including silent LRU / expired-slot evictions; legacy frames without a hint
   --  fall back to slot selection at timestamp max (Now, Last_Access). Read recency is
   --  not logged: each entry's Last_Access is the time of its last durable write (or of
   --  the last checkpoint), so LRU choices after a reopen may differ from an
   --  uninterrupted run that served GETs in between.
   procedure Recover_KV_From_WAL
     (Store        : in out KV_Store;
      WAL_Path     : in     Bounded_Text;
      Now          : in     Epoch_Seconds;
      Max_Frames   : in     Positive;
      Replayed_Ops :    out Natural;
      Status       :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0 and then Max_Frames <= Max_Page_Id,
          Post   => Replayed_Ops <= Max_Frames
                    and then (if Status /= Status_Ok then
                                Store = Store'Old and then Replayed_Ops = 0);

   --  Number of occupied slots of Store
   function Occupied_Count (Store : KV_Store) return KV_Slot_Count
     with Global => null;

   --  Checkpoint support: append one slot-hinted SET frame per occupied slot of Store to
   --  WAL_Path (a fresh file), using KV sequence numbers First_Seq .. Next_Seq - 1
   procedure Write_KV_Snapshot
     (Store     : in     KV_Store;
      WAL_Path  : in     Bounded_Text;
      First_Seq : in     Valid_Tx_Id;
      Next_Seq  :    out Valid_Tx_Id;
      Status    :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0
                    and then First_Seq <= Max_Tx_Id - Max_KV_Capacity,
          Post   => Next_Seq in First_Seq .. First_Seq + Max_KV_Capacity;

end Nhe_O.KV;
