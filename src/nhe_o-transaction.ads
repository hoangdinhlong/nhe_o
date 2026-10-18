--  Formally verified ACID Transaction, MVCC Visibility, and WAL/Page Framing (BR-002)
pragma SPARK_Mode (On);

with Interfaces; use Interfaces;
with Nhe_O.Types; use Nhe_O.Types;
with Nhe_O.IO;    use Nhe_O.IO;

package Nhe_O.Transaction is

   Max_Tx_Id : constant := 1_000_000_000;
   type Tx_Id is range 0 .. Max_Tx_Id;
   subtype Valid_Tx_Id is Tx_Id range 1 .. Max_Tx_Id;

   type Tx_State is (Tx_Idle, Tx_Active, Tx_Committed, Tx_Aborted);

   --  PostgreSQL-style MVCC tuple header (`xmin` = inserting tx, `xmax` = deleting tx or 0)
   type MVCC_Tuple_Header is record
      Xmin : Valid_Tx_Id := 1;
      Xmax : Tx_Id       := 0;
   end record;

   type Transaction_Context is record
      Id       : Valid_Tx_Id := 1;
      Snapshot : Valid_Tx_Id := 1;
      State    : Tx_State    := Tx_Idle;
   end record;

   --  Bounded Commit Log (CLOG) for MVCC Snapshot Isolation (CRIT-04 / R2-CRIT-01 / BR-002)
   Max_CLOG_Entries : constant := 1024;
   subtype CLOG_Tx_Index is Valid_Tx_Id range 1 .. Max_CLOG_Entries;
   type Commit_Log is array (CLOG_Tx_Index) of Tx_State;
   Default_CLOG : constant Commit_Log := [others => Tx_Idle];

   --  Record a transaction state transition in the bounded Commit Log
   procedure Set_CLOG_State
     (CLOG  : in out Commit_Log;
      Id    : in     Valid_Tx_Id;
      State : in     Tx_State)
     with Global => null,
          Always_Terminates;

   --  True iff transaction Id has committed according to CLOG (R2-CRIT-01)
   function Is_Tx_Committed
     (CLOG : Commit_Log;
      Id   : Tx_Id) return Boolean
   is
     (if Id in 1 .. Max_CLOG_Entries then CLOG (Id) = Tx_Committed
      else False);

   --  MVCC Snapshot Visibility Rule (BR-002):
   --  Visible iff created at or before Snapshot and either un-deleted (Xmax = 0)
   --  or deleted strictly after Snapshot.
   function Is_Tuple_Visible
     (Tuple    : MVCC_Tuple_Header;
      Snapshot : Valid_Tx_Id) return Boolean
   is
     (Tuple.Xmin <= Snapshot and then (Tuple.Xmax = 0 or else Tuple.Xmax > Snapshot));

   --  CLOG-Verified MVCC Snapshot Visibility Rule (CRIT-04 / BR-002):
   --  Visible iff inserting tx (Xmin) is committed and <= Snapshot, and either Xmax = 0,
   --  Xmax aborted/uncommitted in CLOG, or Xmax > Snapshot.
   function Is_Tuple_Visible
     (Tuple    : MVCC_Tuple_Header;
      Snapshot : Valid_Tx_Id;
      CLOG     : Commit_Log) return Boolean
   is
     (Is_Tx_Committed (CLOG, Tuple.Xmin)
      and then Tuple.Xmin <= Snapshot
      and then (Tuple.Xmax = 0
                or else not Is_Tx_Committed (CLOG, Tuple.Xmax)
                or else Tuple.Xmax > Snapshot));

   --  WAL Frame Classification (CRIT-05 / Q-004):
   --  WAL_Frame_Data   = intermediate transaction page write (TOAST / data page)
   --  WAL_Frame_Commit = transaction commit barrier frame written by Commit_Tx
   --  WAL_Frame_KV     = durable Key-Value mutation frame (Q-004)
   type WAL_Frame_Kind is (WAL_Frame_Data, WAL_Frame_Commit, WAL_Frame_KV);

   --  Compute IEEE 802.3 CRC-32 checksum over a 4096-byte page in pure SPARK
   function Compute_CRC32 (Page : Page_Buffer) return Unsigned_32
     with Global => null;

   --  Serialize a 4096-byte page + Tx_Id + Page_Id + WAL_Frame_Kind + CRC32 into a WAL frame
   procedure Encode_WAL_Frame
     (Tx       : in     Valid_Tx_Id;
      Page_Id  : in     Valid_Page_Id;
      Page     : in     Page_Buffer;
      Checksum :    out Unsigned_32;
      Frame    :    out WAL_Frame_Buffer;
      Kind     : in     WAL_Frame_Kind := WAL_Frame_Data)
     with Global => null,
          Always_Terminates;

   --  Verify the magic header, frame kind, and CRC32 checksum of a WAL frame
   function Verify_WAL_Frame (Frame : WAL_Frame_Buffer) return Boolean
     with Global => null;

   --  Return the WAL_Frame_Kind encoded in a verified WAL frame
   function Get_WAL_Frame_Kind (Frame : WAL_Frame_Buffer) return WAL_Frame_Kind
     with Global => null,
          Pre    => Verify_WAL_Frame (Frame);

   --  Extract Tx_Id, Page_Id, and 4096-byte Page payload from a verified WAL frame
   procedure Decode_WAL_Frame
     (Frame   : in     WAL_Frame_Buffer;
      Tx      :    out Valid_Tx_Id;
      Page_Id :    out Valid_Page_Id;
      Page    :    out Page_Buffer)
     with Global => null,
          Always_Terminates,
          Pre    => Verify_WAL_Frame (Frame);

   --  Begin an ACID transaction with a monotonic transaction ID
   procedure Begin_Tx
     (Next_Tx : in out Valid_Tx_Id;
      Ctx     :    out Transaction_Context)
     with Global => null,
          Always_Terminates,
          Pre    => Next_Tx < Max_Tx_Id,
          Post   => Ctx.State = Tx_Active
                    and then Ctx.Id = Next_Tx'Old
                    and then Next_Tx = Next_Tx'Old + 1;

   --  Commit an active transaction: writes WAL commit frame & slotted page via Nhe_O.IO (BR-002)
   procedure Commit_Tx
     (Ctx      : in out Transaction_Context;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Page_Id  : in     Valid_Page_Id;
      Page     : in     Page_Buffer;
      Status   :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then DB_Path.Length > 0
                    and then WAL_Path.Length > 0,
          Post   => (if Status = Status_Ok then Ctx.State = Tx_Committed
                     else Ctx.State = Tx_Aborted);

   --  Rollback an active transaction
   procedure Rollback_Tx
     (Ctx : in out Transaction_Context)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active,
          Post   => Ctx.State = Tx_Aborted;

   -------------------------------------------------------------------------
   --  PostgreSQL-Style 4KB TOAST Overflow Page Chains (ADR-003 / BR-006)
   -------------------------------------------------------------------------

   TOAST_Header_Size       : constant := 16;
   TOAST_Chunk_Max_Bytes   : constant := Nhe_O.Page_Size - TOAST_Header_Size; --  4080 bytes
   Max_TOAST_Payload_Bytes : constant := 16_392; --  8B "VTST" header + 4096 * 4B Float32 (R2-HIGH-02)
   Max_TOAST_Chunks        : constant := 5;      --  5 * 4080 = 20,400 >= 16,392 bytes

   subtype TOAST_Payload_Index is Positive range 1 .. Max_TOAST_Payload_Bytes;
   subtype TOAST_Payload_Length is Natural range 0 .. Max_TOAST_Payload_Bytes;
   subtype Valid_TOAST_Length is Positive range 1 .. Max_TOAST_Payload_Bytes;
   subtype TOAST_Chunk_Count is Natural range 0 .. Max_TOAST_Chunks;

   type TOAST_Payload_Buffer is array (TOAST_Payload_Index) of Byte;

   --  16-byte Inline TOAST Pointer stored inside primary 4KB slotted pages (BR-006)
   type TOAST_Pointer is record
      Root_Overflow_Page : Valid_Page_Id        := 0;
      Total_Byte_Length  : TOAST_Payload_Length := 0;
      Chunk_Count        : TOAST_Chunk_Count    := 0;
      Payload_CRC32      : Unsigned_32          := 0;
   end record;

   subtype TOAST_Pointer_Index is Positive range 1 .. 16;
   type TOAST_Pointer_Bytes is array (TOAST_Pointer_Index) of Byte;

   --  Serialize a 16-byte inline TOAST pointer into raw bytes
   procedure Encode_TOAST_Pointer
     (Ptr   : in     TOAST_Pointer;
      Bytes :    out TOAST_Pointer_Bytes)
     with Global => null,
          Always_Terminates;

   --  Deserialize and validate a 16-byte inline TOAST pointer from raw bytes (LOW-01)
   procedure Decode_TOAST_Pointer
     (Bytes : in     TOAST_Pointer_Bytes;
      Ptr   :    out TOAST_Pointer;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Valid then
                       Ptr.Total_Byte_Length in 1 .. Max_TOAST_Payload_Bytes
                       and then Ptr.Chunk_Count =
                         ((Ptr.Total_Byte_Length - 1) / TOAST_Chunk_Max_Bytes) + 1);

   --  Compute IEEE 802.3 CRC-32 checksum over a variable-length TOAST payload
   function Compute_Payload_CRC32
     (Payload : TOAST_Payload_Buffer;
      Length  : Valid_TOAST_Length) return Unsigned_32
     with Global => null;

   --  Persist an oversized attribute (up to 16KB) across linked 4KB TOAST overflow pages
   --  with WAL logging and per-page + full-payload CRC32 protection (ADR-003 / BR-006)
   procedure Write_TOAST_Chain
     (Ctx           : in     Transaction_Context;
      DB_Path       : in     Bounded_Text;
      WAL_Path      : in     Bounded_Text;
      Start_Page_Id : in     Valid_Page_Id;
      Payload       : in     TOAST_Payload_Buffer;
      Length        : in     Valid_TOAST_Length;
      Ptr           :    out TOAST_Pointer;
      Status        :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active
                    and then DB_Path.Length > 0
                    and then WAL_Path.Length > 0
                    and then Start_Page_Id <= Max_Page_Id - Max_TOAST_Chunks,
          Post   => (if Status = Status_Ok then
                       Ptr.Root_Overflow_Page = Start_Page_Id
                       and then Ptr.Total_Byte_Length = Length
                       and then Ptr.Chunk_Count =
                         ((Length - 1) / TOAST_Chunk_Max_Bytes) + 1
                       and then Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks);

   --  Read and reassemble a multi-page TOAST payload, verifying every page link and CRC32
   procedure Read_TOAST_Chain
     (DB_Path : in     Bounded_Text;
      Ptr     : in     TOAST_Pointer;
      Payload :    out TOAST_Payload_Buffer;
      Length  :    out TOAST_Payload_Length;
      Status  :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => DB_Path.Length > 0
                    and then Ptr.Total_Byte_Length in 1 .. Max_TOAST_Payload_Bytes
                    and then Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks,
          Post   => (if Status = Status_Ok then Length = Ptr.Total_Byte_Length
                     else Length = 0);

   -------------------------------------------------------------------------
   --  Primary 4096-Byte Slotted Page Layout (`"SLOT"`, CRIT-01 / BR-006)
   -------------------------------------------------------------------------

   Max_Page_Slots         : constant := 16;
   Max_Inline_Tuple_Bytes : constant := 208;
   subtype Page_Slot_Index is Positive range 1 .. Max_Page_Slots;
   subtype Page_Slot_Count is Natural range 0 .. Max_Page_Slots;
   subtype Inline_Tuple_Length is Natural range 0 .. Max_Inline_Tuple_Bytes;
   subtype Inline_Tuple_Index is Positive range 1 .. Max_Inline_Tuple_Bytes;
   type Inline_Tuple_Buffer is array (Inline_Tuple_Index) of Byte;

   type Slotted_Tuple is record
      Occupied    : Boolean             := False;
      Row_Id      : Positive            := 1;
      Tuple_Hdr   : MVCC_Tuple_Header   := (Xmin => 1, Xmax => 0);
      Toast_Ptr   : TOAST_Pointer       := (others => <>);
      Related_Id  : Natural             := 0;
      Inline_Len  : Inline_Tuple_Length := 0;
      Inline_Data : Inline_Tuple_Buffer := [others => 0];
   end record;

   type Slotted_Tuple_Array is array (Page_Slot_Index) of Slotted_Tuple;

   type Slotted_Page is record
      Page_Id     : Valid_Page_Id       := 0;
      Page_LSN_Tx : Valid_Tx_Id         := 1;
      Slot_Count  : Page_Slot_Count     := 0;
      Tuples      : Slotted_Tuple_Array := [others => (others => <>)];
   end record;

   --  Serialize a Slotted_Page (24B header + 16x8B line pointer directory + 16x240B
   --  MVCC/TOAST/inline tuples + IEEE 802.3 CRC32) into a 4096-byte Page_Buffer
   procedure Encode_Slotted_Page
     (Page_Rec : in     Slotted_Page;
      Raw_Page :    out Page_Buffer)
     with Global => null,
          Always_Terminates;

   --  Deserialize and CRC32-verify a 4096-byte Page_Buffer into a Slotted_Page
   procedure Decode_Slotted_Page
     (Raw_Page : in     Page_Buffer;
      Page_Rec :    out Slotted_Page;
      Valid    :    out Boolean)
     with Global => null,
          Always_Terminates;

   --  Crash-recovery WAL Redo Pass: scan WAL frames, verify CRC32, identify committed
   --  transactions (WAL_Frame_Commit), and replay only committed frames to DB (CRIT-05)
   procedure Redo_WAL_Recovery
     (DB_Path          : in     Bounded_Text;
      WAL_Path         : in     Bounded_Text;
      Max_Frames       : in     Positive;
      Replayed_Count   :    out Natural;
      Max_Recovered_Tx :    out Tx_Id;
      Status           :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => DB_Path.Length > 0
                    and then WAL_Path.Length > 0
                    and then Max_Frames <= Max_Page_Id,
          Post   => Replayed_Count <= Max_Frames;

end Nhe_O.Transaction;

