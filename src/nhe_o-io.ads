--  Formal SPARK Specification for Physical Disk, WAL & Console I/O (BR-001 / ADR-002)
--  Both specification (nhe_o-io.ads) and implementation body (nhe_o-io.adb) operate
--  under pragma SPARK_Mode (On) using contract-bound POSIX I/O primitives.
pragma SPARK_Mode (On);

with Interfaces;
with Nhe_O.Types; use Nhe_O.Types;

package Nhe_O.IO is

   use type Interfaces.Integer_64;

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

   --  Size of a database or WAL file in bytes
   subtype File_Size is Interfaces.Integer_64 range 0 .. Interfaces.Integer_64'Last;

   --  NUL-terminated C path string buffer proven free of buffer overruns
   Max_C_Path_Length : constant Positive := Max_Text_Len + 1;
   subtype C_Path_Index is Positive range 1 .. Max_C_Path_Length;
   subtype C_Path_String is String (C_Path_Index);

   --  True iff Path contains an embedded ASCII.NUL character within 1 .. Path.Length
   function Has_Embedded_NUL (Path : Bounded_Text) return Boolean
     with Global => null,
          Post   => Has_Embedded_NUL'Result =
                      (for some I in 1 .. Path.Length => Path.Data (I) = ASCII.NUL);

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

   --  Create File_Path as an empty regular file when it does not exist yet (an existing
   --  file is left untouched), fsync it and its directory. Success is True iff the path
   --  could be opened read-write (so it is not a directory) and every fsync succeeded.
   procedure Create_File_If_Missing
     (File_Path : in     Bounded_Text;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

   --  Report the current size in bytes of an existing file (open + lseek SEEK_END)
   procedure Get_File_Size
     (File_Path : in     Bounded_Text;
      Size      :    out File_Size;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0,
          Post   => (if not Success then Size = 0);

   --  Shrink an existing file to New_Size bytes and fsync it. Used by crash recovery
   --  to drop a torn trailing WAL frame or a partially written trailing page.
   procedure Truncate_File
     (File_Path : in     Bounded_Text;
      New_Size  : in     File_Size;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

   --  Atomically replace Dst_Path with Src_Path via rename(2), then fsync the parent
   --  directory of Dst_Path so the replacement survives a crash
   procedure Replace_File
     (Src_Path : in     Bounded_Text;
      Dst_Path : in     Bounded_Text;
      Success  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Src_Path.Length > 0 and then Dst_Path.Length > 0;

   --  Same is True iff both paths exist and resolve (following symbolic links)
   --  to the same file, i.e. stat(2) reports identical st_dev and st_ino
   procedure Check_Same_File
     (Path_A : in     Bounded_Text;
      Path_B : in     Bounded_Text;
      Same   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Path_A.Length > 0 and then Path_B.Length > 0;

   --  Return the calling process identifier (getpid), used to derive
   --  per-process default database paths
   function Get_Process_Id return Natural
     with Global => null;

   --  Prefix a relative Path with the current working directory (getcwd) so later
   --  calls are immune to chdir(2); absolute paths are returned unchanged
   procedure Make_Absolute_Path
     (Path     : in     Bounded_Text;
      Abs_Path :    out Bounded_Text;
      Success  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Path.Length > 0,
          Post   => (if Success then Abs_Path.Length >= Path.Length
                                     and then Abs_Path.Data (1) = '/'
                     else Abs_Path.Length = 0);

   --  Write a 4096-byte slotted page to the database file at offset Page_Id * 4096.
   --  A failed write that was extending the file truncates it back to its previous
   --  page-aligned size, so a failure never leaves a torn trailing page behind.
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

   --  Read a 4096-byte slotted page at Page_Id, distinguishing clean EOF (Page_Id at or
   --  past the end of a page-aligned file) from I/O errors; a file whose size is not a
   --  multiple of 4096 bytes fails closed for every Page_Id (see Repair_DB_Tail)
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

   --  Append a CRC32-framed WAL record at the frame-aligned end of the WAL via
   --  positional pwrite + fsync. Success is True iff the whole frame was written and
   --  fsynced. On any failure the WAL is truncated back to its previous length, so a
   --  frame reported as not appended is never replayed by recovery.
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

   --  Read a WAL frame at 0-based index Frame_Idx, distinguishing clean EOF (Frame_Idx at
   --  or past the last frame of a frame-aligned WAL) from I/O errors. A WAL whose size is
   --  not a multiple of 4120 bytes, or that holds more than Max_WAL_Frames frames, fails
   --  closed for every Frame_Idx (see Nhe_O.Transaction.Repair_WAL_Tail).
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

   --  Delete a database or WAL file if present on disk (best effort)
   pragma Warnings (GNATprove, Off, "subprogram ""Delete_File_If_Exists"" has no effect",
                    Reason => "Unlinks OS file on disk via contract-bound POSIX unlink syscall");
   procedure Delete_File_If_Exists
     (File_Path : in Bounded_Text)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;
   pragma Warnings (GNATprove, On, "subprogram ""Delete_File_If_Exists"" has no effect");

   --  Delete a database or WAL file if present; Removed is True iff the path no
   --  longer exists afterwards
   procedure Delete_File_If_Exists
     (File_Path : in     Bounded_Text;
      Removed   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

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
