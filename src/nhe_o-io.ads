--  Formal SPARK Specification for Physical Disk, WAL & Console I/O (BR-001 / ADR-002)
--  Both specification (nhe_o-io.ads) and implementation body (nhe_o-io.adb) operate
--  under pragma SPARK_Mode (On) using contract-bound POSIX I/O primitives.
pragma SPARK_Mode (On);

with Interfaces;
with Nhe_O.Types; use Nhe_O.Types;

package Nhe_O.IO is

   subtype Byte is Interfaces.Unsigned_8;

   --  Maximum page index (1,048,575 pages * 4096 bytes = 4 GiB per database file)
   Max_Page_Id : constant Natural := 1_048_575;
   subtype Valid_Page_Id is Natural range 0 .. Max_Page_Id;

   subtype Page_Offset is Positive range 1 .. Nhe_O.Page_Size;
   type Page_Buffer is array (Page_Offset) of Byte
     with Convention => C;

   --  WAL Frame: 24-byte header (Magic + Tx_Id + Page_Id + CRC32) + 4096-byte payload
   WAL_Header_Size : constant := 24;
   WAL_Frame_Size  : constant := WAL_Header_Size + Nhe_O.Page_Size;
   subtype WAL_Frame_Offset is Positive range 1 .. WAL_Frame_Size;
   type WAL_Frame_Buffer is array (WAL_Frame_Offset) of Byte
     with Convention => C;

   --  NUL-terminated C path string buffer proven free of buffer overruns
   Max_C_Path_Length : constant Positive := Max_Text_Len + 1;
   subtype C_Path_Index is Positive range 1 .. Max_C_Path_Length;
   subtype C_Path_String is String (C_Path_Index);

   --  True iff Path contains an embedded ASCII.NUL character within 1 .. Path.Length
   function Has_Embedded_NUL (Path : Bounded_Text) return Boolean;

   procedure To_C_Path
     (Path   : in     Bounded_Text;
      C_Path :    out C_Path_String)
     with Pre  => Path.Length > 0 and then not Has_Embedded_NUL (Path),
          Post => C_Path (Path.Length + 1) = ASCII.NUL
                  and then (for all I in 1 .. Path.Length =>
                              C_Path (I) = Path.Data (I));

   --  Write a 4096-byte slotted page to the database file at offset Page_Id * 4096
   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
     with Pre => File_Path.Length > 0;

   --  Read a 4096-byte slotted page from the database file at offset Page_Id * 4096
   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean)
     with Pre => File_Path.Length > 0;

   --  Append a CRC32-framed WAL record to the Write-Ahead Log and fsync to disk
   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
     with Pre => WAL_Path.Length > 0;

   --  Read a WAL frame at 0-based index Frame_Idx from the Write-Ahead Log on disk
   procedure Read_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     :    out WAL_Frame_Buffer;
      Success   :    out Boolean)
     with Pre => WAL_Path.Length > 0;

   --  Delete a database or WAL file if present on disk
   procedure Delete_File_If_Exists
     (File_Path : in Bounded_Text)
     with Pre => File_Path.Length > 0;

   --  Console output I/O helpers in SPARK_Mode (On)
   procedure Print_Line (Msg : in String);

   procedure Print_Blank_Line;

end Nhe_O.IO;
