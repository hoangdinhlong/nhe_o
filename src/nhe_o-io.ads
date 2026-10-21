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

   --  WAL Frame: 24-byte header + 4096-byte payload. Header bytes 1..4 magic "NHEO",
   --  5..8 Tx_Id, 9..12 Page_Id, 13..16 CRC32 (over Tx_Id, Page_Id, the kind byte and
   --  the payload), 17 frame kind (data, commit or KV), 18..24 reserved zero bytes
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

   --  Is the last component of File_Path a symbolic link, dangling or not (readlink(2)
   --  succeeds)? The link is never followed; a missing path is not a link.
   procedure Check_Symbolic_Link
     (File_Path : in     Bounded_Text;
      Is_Link   :    out Boolean)
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

   --  Create File_Path as a new empty file (open with O_CREAT | O_EXCL, mode 0600) and
   --  fsync it and its directory. Fails, touching nothing, when the path already exists
   --  in any form (O_EXCL also refuses a symbolic link, dangling or not), so a file
   --  created this way can never be redirected to another file by a pre-planted link.
   procedure Create_File_Exclusive
     (File_Path : in     Bounded_Text;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0;

   --  Report the current size in bytes of an existing regular file that can be opened
   --  read-write (open O_RDWR + lseek SEEK_END): a directory, FIFO or read-only file
   --  reports failure, and so does a symbolic link as the last component of File_Path
   --  unless Follow_Link (O_NOFOLLOW otherwise)
   procedure Get_File_Size
     (File_Path   : in     Bounded_Text;
      Size        :    out File_Size;
      Success     :    out Boolean;
      Follow_Link : in     Boolean := True)
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

   --  Return the calling process identifier (getpid), used to derive the per-process
   --  scratch paths and to recognise a forked child (Nhe_O.C_API.Engine_Ready).
   --  Modelled as a constant (Global => null): the identifier changes only at fork(2),
   --  which hosts call between calls into this library (never during one, see
   --  include/nhe_o.h), and no contract relates its values across calls.
   function Get_Process_Id return Natural
     with Global => null;

   --  An exclusive advisory lock (flock LOCK_EX) held through an open descriptor
   type File_Lock is record
      Fd : Integer := -1;
   end record;

   No_Lock : constant File_Lock := (Fd => -1);

   function Is_Locked (Lock : File_Lock) return Boolean is (Lock.Fd >= 0)
     with Global => null;

   --  Open the existing file File_Path and take a non-blocking exclusive lock on it
   --  (flock LOCK_EX | LOCK_NB). Success is False when the file cannot be opened or
   --  another open file description, in any process, holds the lock. A symbolic link
   --  as the last component of File_Path is never followed: the call fails
   --  (O_NOFOLLOW). The lock lives until Unlock_File (or process exit) and follows the
   --  file, not its path: a file renamed into place keeps the lock taken on it before
   --  the rename.
   procedure Lock_File
     (File_Path : in     Bounded_Text;
      Lock      :    out File_Lock;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0,
          Post   => Success = Is_Locked (Lock);

   --  Create File_Path like Create_File_Exclusive and lock it like Lock_File through
   --  the creating descriptor, so no other open can lock (and take as its own) the new
   --  file first. Success is False, with no lock, when the path already exists in any
   --  form (nothing is created); when another open locked the new file between the
   --  open(2) and the flock(2) (the file is then left to that open); or when an fsync
   --  fails (the new file is removed again).
   procedure Create_Locked_File
     (File_Path : in     Bounded_Text;
      Lock      :    out File_Lock;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0,
          Post   => Success = Is_Locked (Lock);

   --  Release a lock taken by Lock_File (no-op for No_Lock)
   procedure Unlock_File (Lock : in out File_Lock)
     with Global => null,
          Always_Terminates,
          Post   => not Is_Locked (Lock);

   --  Canonical absolute path of the existing file Path (realpath(3): symbolic links,
   --  "." and ".." resolved), so directory fsyncs and checkpoint renames act on the
   --  real file; Success is False when it cannot be resolved or exceeds Max_Text_Len
   --  (Too_Long: the path exists but its resolved form is longer than Max_Text_Len,
   --  or longer than the PATH_MAX of 4096 bytes realpath(3) can return)
   procedure Resolve_Path
     (Path     : in     Bounded_Text;
      Resolved :    out Bounded_Text;
      Success  :    out Boolean;
      Too_Long :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Path.Length > 0,
          Post   => (if Success then Resolved.Length > 0 and then Resolved.Data (1) = '/'
                                     and then not Too_Long
                     else Resolved.Length = 0);

   --  Delete the file Path resolves to (realpath(3)), never a symbolic link on the way:
   --  undoes a creation through a link even when the resolved path is longer than
   --  Max_Text_Len. When Path cannot be resolved (a resolved form beyond PATH_MAX),
   --  Path itself is unlinked unless its last component is a symbolic link, which is
   --  kept (the file created through it then stays).
   pragma Warnings (GNATprove, Off, "subprogram ""Delete_Resolved_File"" has no effect",
                    Reason => "Unlinks OS file on disk via contract-bound POSIX unlink syscall");
   procedure Delete_Resolved_File (Path : in Bounded_Text)
     with Global => null,
          Always_Terminates,
          Pre    => Path.Length > 0;
   pragma Warnings (GNATprove, On, "subprogram ""Delete_Resolved_File"" has no effect");

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
   --  page-aligned size (best effort: if that truncation fails too, Repair_DB_Tail
   --  removes the torn page at the next recovery). The first write into an empty file
   --  also fsyncs the parent directory, so a newly created file's name is durable.
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
   --  positional pwrite + fsync (plus a directory fsync when the WAL was empty; the
   --  first frame of an empty WAL is preceded by a synced write of its first 512-byte
   --  sector, so a crash can tear it only to a prefix of that sector or after its
   --  whole header, see Nhe_O.Transaction.Repair_WAL_Tail). Success
   --  is True iff the whole frame was written and made durable. On failure the WAL is
   --  truncated back to its previous length and fsynced. That rollback is best effort:
   --  if it fails too, the complete frame may survive and be replayed by recovery, so a
   --  failed append means "outcome decided by the next recovery", never "certainly lost".
   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => WAL_Path.Length > 0;

   --  Read up to WAL_Frame_Size bytes of an existing file starting at byte Offset,
   --  whatever its size or alignment (crash-repair needs to inspect torn tails that
   --  Read_WAL_Frame refuses); Count is the number of bytes read, 0 at or past EOF.
   --  A symbolic link as the last component of File_Path fails the read unless
   --  Follow_Link (O_NOFOLLOW otherwise).
   procedure Read_File_Bytes
     (File_Path   : in     Bounded_Text;
      Offset      : in     File_Size;
      Buffer      :    out WAL_Frame_Buffer;
      Count       :    out Natural;
      Success     :    out Boolean;
      Follow_Link : in     Boolean := True)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0,
          Post   => Count <= WAL_Frame_Size and then (if not Success then Count = 0);

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

   --  Give SIGABRT back its default action. The GNAT run time installs its own handler
   --  for it when the shared library is initialized, which would turn a host's abort()
   --  or failed assert() into "raised PROGRAM_ERROR" and exit status 1; Nhe_O.C_API
   --  calls this when it is elaborated.
   pragma Warnings (GNATprove, Off, "subprogram ""Restore_Default_Abort_Signal"" has no effect",
                    Reason => "Sets the process signal disposition via signal(2)");
   procedure Restore_Default_Abort_Signal
     with Global => null,
          Always_Terminates;
   pragma Warnings (GNATprove, On, "subprogram ""Restore_Default_Abort_Signal"" has no effect");

   --  Mark process exit status as Failure (non-zero) on runtime verification failure
   pragma Warnings (GNATprove, Off, "subprogram ""Set_Exit_Failure"" has no effect",
                    Reason => "Sets OS process exit code to Failure");
   procedure Set_Exit_Failure
     with Global => null,
          Always_Terminates;
   pragma Warnings (GNATprove, On, "subprogram ""Set_Exit_Failure"" has no effect");

end Nhe_O.IO;
