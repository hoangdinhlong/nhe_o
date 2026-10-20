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
   Max_WAL_Frames  : constant := 4096;
   subtype WAL_Frame_Offset is Positive range 1 .. WAL_Frame_Size;
   type WAL_Frame_Buffer is array (WAL_Frame_Offset) of Byte
     with Convention => C;

   --  NUL-terminated C path string buffer proven free of buffer overruns
   Max_C_Path_Length : constant Positive := Max_Text_Len + 1;
   subtype C_Path_Index is Positive range 1 .. Max_C_Path_Length;
   subtype C_Path_String is String (C_Path_Index);

   --  True iff Path contains an embedded ASCII.NUL character within 1 .. Path.Length
   function Has_Embedded_NUL (Path : Bounded_Text) return Boolean
     with Global => null;

   procedure To_C_Path
     (Path   : in     Bounded_Text;
      C_Path :    out C_Path_String)
     with Global => null,
          Always_Terminates,
          Pre    => Path.Length > 0 and then not Has_Embedded_NUL (Path),
          Post   => C_Path (Path.Length + 1) = ASCII.NUL
                    and then (for all I in 1 .. Path.Length =>
                                C_Path (I) = Path.Data (I));

   --  Check whether a path exists on disk via POSIX access(F_OK)
   procedure Check_File_Exists
     (File_Path : in     Bounded_Text;
      Exists    :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

   --  Write a 4096-byte slotted page to the database file at offset Page_Id * 4096
   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

   --  Read a 4096-byte slotted page from the database file at offset Page_Id * 4096
   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

   --  Read a 4096-byte slotted page at Page_Id, distinguishing clean EOF (0 bytes at
   --  page boundary) from torn pages or I/O errors
   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean;
      Is_EOF    :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0,
          Post   => not (Success and Is_EOF);

   --  Write a CRC32-framed WAL record at exact 0-based index Frame_Idx via positional pwrite
   procedure Write_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     : in     WAL_Frame_Buffer;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0;

   --  Append a CRC32-framed WAL record at a frame-aligned offset via positional pwrite + fsync
   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0;

   --  Read a WAL frame at 0-based index Frame_Idx from the Write-Ahead Log on disk
   procedure Read_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     :    out WAL_Frame_Buffer;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0;

   --  Read a WAL frame at 0-based index Frame_Idx, distinguishing clean EOF (0 bytes at
   --  exact frame boundary) from torn frames or I/O errors
   procedure Read_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     :    out WAL_Frame_Buffer;
      Success   :    out Boolean;
      Is_EOF    :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0,
          Post   => not (Success and Is_EOF);

   --  Delete a database or WAL file if present on disk
   pragma Warnings (GNATprove, Off, "subprogram ""Delete_File_If_Exists"" has no effect",
                    Reason => "Unlinks OS file on disk via contract-bound POSIX unlink syscall");
   procedure Delete_File_If_Exists
     (File_Path : in Bounded_Text)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;
   pragma Warnings (GNATprove, On, "subprogram ""Delete_File_If_Exists"" has no effect");

   --  Console output & CLI helpers in SPARK_Mode (On)
   procedure Print_Line (Msg : in String)
     with Always_Terminates;

   procedure Print_Blank_Line
     with Always_Terminates;

   --  Read command-line argument at 1-based position Index into Bounded_Text
   pragma Warnings (GNATprove, Off, "subprogram ""Read_CLI_Arg"" has no effect",
                    Reason => "Reads OS process argv vector");
   procedure Read_CLI_Arg
     (Index : in     Positive;
      Arg   :    out Bounded_Text;
      Found :    out Boolean)
     with Global => null,
          Always_Terminates;

   --  Read command-line argument at 1-based position Index, reporting whether an
   --  argument was present but exceeded Max_Text_Len (512 bytes)
   procedure Read_CLI_Arg
     (Index    : in     Positive;
      Arg      :    out Bounded_Text;
      Found    :    out Boolean;
      Too_Long :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => not (Found and Too_Long);
   pragma Warnings (GNATprove, On, "subprogram ""Read_CLI_Arg"" has no effect");

   --  Mark process exit status as Failure (non-zero) on runtime verification failure
   pragma Warnings (GNATprove, Off, "subprogram ""Set_Exit_Failure"" has no effect",
                    Reason => "Sets OS process exit code to Failure");
   procedure Set_Exit_Failure
     with Global => null,
          Always_Terminates;
   pragma Warnings (GNATprove, On, "subprogram ""Set_Exit_Failure"" has no effect");

end Nhe_O.IO;
