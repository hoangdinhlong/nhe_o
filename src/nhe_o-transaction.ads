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

   --  MVCC Snapshot Visibility Rule (BR-002):
   --  Visible iff created at or before Snapshot and either un-deleted (Xmax = 0)
   --  or deleted strictly after Snapshot.
   function Is_Tuple_Visible
     (Tuple    : MVCC_Tuple_Header;
      Snapshot : Valid_Tx_Id) return Boolean
   is
     (Tuple.Xmin <= Snapshot and then (Tuple.Xmax = 0 or else Tuple.Xmax > Snapshot));

   --  Compute IEEE 802.3 CRC-32 checksum over a 4096-byte page in pure SPARK
   function Compute_CRC32 (Page : Page_Buffer) return Unsigned_32;

   --  Serialize a 4096-byte page + Tx_Id + Page_Id + CRC32 into a WAL frame
   procedure Encode_WAL_Frame
     (Tx       : in     Valid_Tx_Id;
      Page_Id  : in     Natural;
      Page     : in     Page_Buffer;
      Checksum :    out Unsigned_32;
      Frame    :    out WAL_Frame_Buffer);

   --  Verify the magic header and CRC32 checksum of a WAL frame
   function Verify_WAL_Frame (Frame : WAL_Frame_Buffer) return Boolean;

   --  Begin an ACID transaction with a monotonic transaction ID
   procedure Begin_Tx
     (Next_Tx : in out Valid_Tx_Id;
      Ctx     :    out Transaction_Context)
     with Pre  => Next_Tx < Max_Tx_Id,
          Post => Ctx.State = Tx_Active
                  and then Ctx.Id = Next_Tx'Old
                  and then Next_Tx = Next_Tx'Old + 1;

   --  Commit an active transaction: writes WAL frame & slotted page via Nhe_O.IO (BR-002)
   procedure Commit_Tx
     (Ctx      : in out Transaction_Context;
      DB_Path  : in     Bounded_Text;
      WAL_Path : in     Bounded_Text;
      Page_Id  : in     Natural;
      Page     : in     Page_Buffer;
      Status   :    out Engine_Status)
     with Pre  => Ctx.State = Tx_Active
                  and then DB_Path.Length > 0
                  and then WAL_Path.Length > 0,
          Post => (if Status = Status_Ok then Ctx.State = Tx_Committed
                   else Ctx.State = Tx_Aborted);

   --  Rollback an active transaction
   procedure Rollback_Tx
     (Ctx : in out Transaction_Context)
     with Pre  => Ctx.State = Tx_Active,
          Post => Ctx.State = Tx_Aborted;

end Nhe_O.Transaction;
