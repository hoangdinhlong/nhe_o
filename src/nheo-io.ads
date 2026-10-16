--  Formal SPARK Specification for Physical Disk, WAL & Console I/O Boundary (BR-001)
--  Note: This specification is in SPARK_Mode (On); only the implementation body
--  (nheo-io.adb) uses SPARK_Mode (Off) to invoke OS/Ada I/O operations.
pragma SPARK_Mode (On);

with Interfaces;
with Nheo.Types; use Nheo.Types;

package Nheo.IO is

   subtype Byte is Interfaces.Unsigned_8;

   subtype Page_Offset is Positive range 1 .. Nheo.Page_Size;
   type Page_Buffer is array (Page_Offset) of Byte;

   --  WAL Frame: 24-byte header (Magic + Tx_Id + Page_Id + CRC32) + 4096-byte payload
   WAL_Header_Size : constant := 24;
   WAL_Frame_Size  : constant := WAL_Header_Size + Nheo.Page_Size;
   subtype WAL_Frame_Offset is Positive range 1 .. WAL_Frame_Size;
   type WAL_Frame_Buffer is array (WAL_Frame_Offset) of Byte;

   --  Write a 4096-byte slotted page to the database file at offset Page_Id * 4096
   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Natural;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
     with Pre => File_Path.Length > 0;

   --  Read a 4096-byte slotted page from the database file at offset Page_Id * 4096
   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Natural;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean)
     with Pre => File_Path.Length > 0;

   --  Append a CRC32-framed WAL record to the Write-Ahead Log and flush to disk
   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
     with Pre => WAL_Path.Length > 0;

   --  Delete a database or WAL file if present on disk
   procedure Delete_File_If_Exists
     (File_Path : in Bounded_Text)
     with Pre => File_Path.Length > 0;

   --  Console output I/O helpers so callers remain in SPARK_Mode (On)
   procedure Print_Line (Msg : in String);

   procedure Print_Blank_Line;

end Nheo.IO;
