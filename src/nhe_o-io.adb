--  Formally Verified Physical I/O Implementation Body (BR-001 / ADR-002)
--  Operates under pragma SPARK_Mode (On) by binding directly to exception-free
--  POSIX kernel syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `ftruncate`,
--  `close`, `rename`, `stat`, `unlink`, `access`, `getcwd`, `getpid`) with explicit
--  return-code verification and bounded offset arithmetic.
pragma SPARK_Mode (On);

with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C; use Interfaces.C;

package body Nhe_O.IO is

   subtype Ssize_T is Interfaces.Integer_64;
   subtype Off_T   is Interfaces.Integer_64;

   use type Interfaces.Unsigned_8;

   --  POSIX open(2) / lseek(2) flags for Linux (x86_64 and aarch64 share these values;
   --  0600 octal = S_IRUSR | S_IWUSR). O_NONBLOCK keeps open(2) on a FIFO from
   --  blocking forever; the following lseek(2) then fails closed with ESPIPE.
   O_RDONLY       : constant int      := 8#0#;
   O_RDWR         : constant int      := 8#2#;
   O_CREAT        : constant int      := 8#100#;
   O_NONBLOCK     : constant int      := 8#4000#;
   O_CLOEXEC      : constant int      := 8#2000000#;
   Mode_0600      : constant unsigned := 8#600#;
   SEEK_END       : constant int      := 2;
   Max_IO_Retries : constant Positive := 3;

   --  Contract-bound POSIX kernel syscall bindings (never raise Ada exceptions)
   function Posix_Open
     (Path  : C_Path_String;
      Flags : int;
      Mode  : unsigned) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "open";

   function Posix_Pwrite
     (Fd     : int;
      Buf    : Page_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "pwrite";

   function Posix_Pread
     (Fd     : int;
      Buf    : in out Page_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "pread";

   function Posix_Pwrite_WAL
     (Fd     : int;
      Buf    : WAL_Frame_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "pwrite";

   function Posix_Pread_WAL
     (Fd     : int;
      Buf    : in out WAL_Frame_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "pread";

   function Posix_Lseek
     (Fd     : int;
      Offset : Off_T;
      Whence : int) return Off_T
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "lseek";

   function Posix_Fsync (Fd : int) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "fsync";

   function Posix_Ftruncate
     (Fd     : int;
      Length : Off_T) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "ftruncate";

   function Posix_Close (Fd : int) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "close";

   function Posix_Unlink (Path : C_Path_String) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "unlink";

   function Posix_Rename
     (Old_Path : C_Path_String;
      New_Path : C_Path_String) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "rename";

   --  Opaque `struct stat` buffer: st_dev occupies bytes 1 .. 8 and st_ino bytes
   --  9 .. 16 on both x86_64 and aarch64 Linux; 256 bytes covers either layout
   subtype Stat_Index is Positive range 1 .. 256;
   type Stat_Buffer is array (Stat_Index) of Byte
     with Convention => C;

   function Posix_Stat
     (Path : C_Path_String;
      Buf  : in out Stat_Buffer) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "stat";

   --  getcwd(3) returns a char * (NULL on failure); on LP64 Linux it is bound as a
   --  pointer-sized unsigned integer and only compared against 0
   function Posix_Getcwd
     (Buf  : in out C_Path_String;
      Size : size_t) return size_t
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "getcwd";

   function Posix_Getpid return int
     with Global        => null,
          Import        => True,
          Convention    => C,
          External_Name => "getpid";

   F_OK : constant int := 0;

   function Posix_Access
     (Path : C_Path_String;
      Mode : int) return int
     with Side_Effects,
          Global        => null,
          Always_Terminates,
          Import        => True,
          Convention    => C,
          External_Name => "access";

   function Has_Embedded_NUL (Path : Bounded_Text) return Boolean is
   begin
      for I in 1 .. Path.Length loop
         pragma Loop_Invariant
           (I in 1 .. Path.Length
            and then (for all J in 1 .. I - 1 => Path.Data (J) /= ASCII.NUL));
         if Path.Data (I) = ASCII.NUL then
            return True;
         end if;
      end loop;
      return False;
   end Has_Embedded_NUL;

   procedure To_C_Path
     (Path   : in     Bounded_Text;
      C_Path :    out C_Path_String)
   is
   begin
      C_Path := [others => ASCII.NUL];
      for I in 1 .. Path.Length loop
         pragma Loop_Invariant
           (I in 1 .. Path.Length
            and then (for all J in 1 .. I - 1 => C_Path (J) = Path.Data (J)));
         C_Path (I) := Path.Data (I);
      end loop;
      C_Path (Path.Length + 1) := ASCII.NUL;
   end To_C_Path;

   procedure Check_File_Exists
     (File_Path : in     Bounded_Text;
      Exists    :    out Boolean)
   is
      C_Path : C_Path_String;
      Rc     : int;
   begin
      if Has_Embedded_NUL (File_Path) then
         Exists := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Rc     := Posix_Access (C_Path, F_OK);
      Exists := (Rc = 0);
   end Check_File_Exists;

   procedure Get_File_Size
     (File_Path : in     Bounded_Text;
      Size      :    out File_Size;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      End_Pos : Off_T;
      Close_R : int;
   begin
      Size    := 0;
      Success := False;

      if Has_Embedded_NUL (File_Path) then
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDONLY + O_NONBLOCK + O_CLOEXEC, 0);
      if Fd < 0 then
         return;
      end if;

      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      Close_R := Posix_Close (Fd);
      if End_Pos >= 0 and then Close_R = 0 then
         Size    := End_Pos;
         Success := True;
      end if;
   end Get_File_Size;

   procedure Truncate_File
     (File_Path : in     Bounded_Text;
      New_Size  : in     File_Size;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Trunc_R : int;
      Sync_Rc : int;
      Close_R : int;
      pragma Warnings (Off, Close_R);
   begin
      if Has_Embedded_NUL (File_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_NONBLOCK + O_CLOEXEC, 0);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      Trunc_R := Posix_Ftruncate (Fd, New_Size);
      Sync_Rc := Posix_Fsync (Fd);
      Close_R := Posix_Close (Fd);
      Success := (Trunc_R = 0) and then (Sync_Rc = 0);
   end Truncate_File;

   --  fsync the directory containing File_Path so that a rename(2) or file creation
   --  inside it is durable
   procedure Sync_Parent_Directory
     (File_Path : in     Bounded_Text;
      Success   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => File_Path.Length > 0
   is
      Dir_Path   : Bounded_Text := (Length => 0, Data => [others => ' ']);
      Last_Slash : Natural      := 0;
      C_Path     : C_Path_String;
      Fd         : int;
      Sync_Rc    : int;
      Close_R    : int;
      pragma Warnings (Off, Close_R);
   begin
      for I in 1 .. File_Path.Length loop
         pragma Loop_Invariant (Last_Slash < I);
         if File_Path.Data (I) = '/' then
            Last_Slash := I;
         end if;
      end loop;

      if Last_Slash = 0 then
         Dir_Path := Make_Text (".");
      elsif Last_Slash = 1 then
         Dir_Path := Make_Text ("/");
      else
         Dir_Path.Length := Last_Slash - 1;
         for I in 1 .. Last_Slash - 1 loop
            pragma Loop_Invariant (Dir_Path.Length = Last_Slash - 1);
            Dir_Path.Data (I) := File_Path.Data (I);
         end loop;
      end if;

      if Has_Embedded_NUL (Dir_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (Dir_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDONLY + O_NONBLOCK + O_CLOEXEC, 0);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      Sync_Rc := Posix_Fsync (Fd);
      Close_R := Posix_Close (Fd);
      Success := (Sync_Rc = 0);
   end Sync_Parent_Directory;

   procedure Create_File_If_Missing
     (File_Path : in     Bounded_Text;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Sync_Rc : int;
      Close_R : int;
      Dir_Ok  : Boolean;
   begin
      if Has_Embedded_NUL (File_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_NONBLOCK + O_CLOEXEC, Mode_0600);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      Sync_Rc := Posix_Fsync (Fd);
      Close_R := Posix_Close (Fd);
      Sync_Parent_Directory (File_Path, Dir_Ok);
      Success := Sync_Rc = 0 and then Close_R = 0 and then Dir_Ok;
   end Create_File_If_Missing;

   procedure Replace_File
     (Src_Path : in     Bounded_Text;
      Dst_Path : in     Bounded_Text;
      Success  :    out Boolean)
   is
      C_Src : C_Path_String;
      C_Dst : C_Path_String;
      Rc    : int;
   begin
      if Has_Embedded_NUL (Src_Path) or else Has_Embedded_NUL (Dst_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (Src_Path, C_Src);
      To_C_Path (Dst_Path, C_Dst);
      Rc := Posix_Rename (C_Src, C_Dst);
      if Rc /= 0 then
         Success := False;
         return;
      end if;

      Sync_Parent_Directory (Dst_Path, Success);
   end Replace_File;

   procedure Check_Same_File
     (Path_A : in     Bounded_Text;
      Path_B : in     Bounded_Text;
      Same   :    out Boolean)
   is
      C_A   : C_Path_String;
      C_B   : C_Path_String;
      Buf_A : Stat_Buffer := [others => 0];
      Buf_B : Stat_Buffer := [others => 0];
      Rc_A  : int;
      Rc_B  : int;
   begin
      Same := False;
      if Has_Embedded_NUL (Path_A) or else Has_Embedded_NUL (Path_B) then
         return;
      end if;

      To_C_Path (Path_A, C_A);
      To_C_Path (Path_B, C_B);
      Rc_A := Posix_Stat (C_A, Buf_A);
      Rc_B := Posix_Stat (C_B, Buf_B);
      if Rc_A = 0 and then Rc_B = 0 then
         Same := (for all I in 1 .. 16 => Buf_A (I) = Buf_B (I));
      end if;
   end Check_Same_File;

   function Get_Process_Id return Natural is
      Pid : constant int := Posix_Getpid;
   begin
      if Pid > 0 then
         return Natural (Pid);
      else
         return 0;
      end if;
   end Get_Process_Id;

   procedure Make_Absolute_Path
     (Path     : in     Bounded_Text;
      Abs_Path :    out Bounded_Text;
      Success  :    out Boolean)
   is
      Cwd     : C_Path_String := [others => ASCII.NUL];
      Cwd_Ptr : size_t;
      Cwd_Len : Natural := 0;
      Sep_Len : Natural;
   begin
      if Path.Data (1) = '/' then
         Abs_Path := Path;
         Success  := True;
         return;
      end if;

      Abs_Path := (Length => 0, Data => [others => ' ']);
      Success  := False;

      Cwd_Ptr := Posix_Getcwd (Cwd, size_t (Max_C_Path_Length));
      if Cwd_Ptr = 0 or else Cwd (1) /= '/' then
         return;
      end if;

      --  Length of the NUL-terminated working directory string
      for I in C_Path_Index loop
         pragma Loop_Invariant (Cwd_Len = I - 1);
         exit when Cwd (I) = ASCII.NUL;
         Cwd_Len := I;
      end loop;

      if Cwd_Len = 0 or else Cwd_Len > Max_Text_Len then
         return;
      end if;

      Sep_Len := (if Cwd (Cwd_Len) = '/' then 0 else 1);
      if Cwd_Len + Sep_Len + Path.Length > Max_Text_Len then
         return;
      end if;

      Abs_Path.Length := Cwd_Len + Sep_Len + Path.Length;
      for I in 1 .. Cwd_Len loop
         pragma Loop_Invariant (Abs_Path.Length = Cwd_Len + Sep_Len + Path.Length);
         Abs_Path.Data (I) := Cwd (I);
      end loop;
      if Sep_Len = 1 then
         Abs_Path.Data (Cwd_Len + 1) := '/';
      end if;
      for I in 1 .. Path.Length loop
         pragma Loop_Invariant
           (Abs_Path.Length = Cwd_Len + Sep_Len + Path.Length
            and then Abs_Path.Data (1) = '/');
         Abs_Path.Data (Cwd_Len + Sep_Len + I) := Path.Data (I);
      end loop;
      Success := True;
   end Make_Absolute_Path;

   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      End_Pos : Off_T;
      Offset  : constant Off_T := Off_T (Page_Id) * Off_T (Nhe_O.Page_Size);
      Written : Ssize_T;
      Sync_Rc : int;
      Trunc_R : int;
      Close_R : int;
      pragma Warnings (Off, Trunc_R);
      pragma Warnings (Off, Close_R);
   begin
      if Has_Embedded_NUL (File_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_NONBLOCK + O_CLOEXEC, Mode_0600);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      --  Reject database files with torn/unaligned page tails
      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      if End_Pos < 0 or else End_Pos mod Off_T (Nhe_O.Page_Size) /= 0 then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         Success := False;
         return;
      end if;

      for Attempt in 1 .. Max_IO_Retries loop
         Written := Posix_Pwrite (Fd, Buffer, size_t (Nhe_O.Page_Size), Offset);
         exit when Written = Ssize_T (Nhe_O.Page_Size);
      end loop;

      Sync_Rc := Posix_Fsync (Fd);
      Success := (Written = Ssize_T (Nhe_O.Page_Size)) and then (Sync_Rc = 0);

      --  Undo a failed file extension so the database stays page-aligned
      if not Success and then Offset >= End_Pos then
         Trunc_R := Posix_Ftruncate (Fd, End_Pos);
         Sync_Rc := Posix_Fsync (Fd);
      end if;

      Close_R := Posix_Close (Fd);
   end Write_Page;

   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean;
      Is_EOF    :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      End_Pos : Off_T;
      Offset  : constant Off_T := Off_T (Page_Id) * Off_T (Nhe_O.Page_Size);
      N_Read  : Ssize_T;
      Close_R : int;
      pragma Warnings (Off, Close_R);
   begin
      Buffer  := [others => 0];
      Success := False;
      Is_EOF  := False;

      if Has_Embedded_NUL (File_Path) then
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDONLY + O_NONBLOCK + O_CLOEXEC, 0);
      if Fd < 0 then
         return;
      end if;

      --  Reject database files with torn/unaligned page tails
      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      if End_Pos < 0 or else End_Pos mod Off_T (Nhe_O.Page_Size) /= 0 then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         return;
      end if;

      for Attempt in 1 .. Max_IO_Retries loop
         N_Read := Posix_Pread (Fd, Buffer, size_t (Nhe_O.Page_Size), Offset);
         exit when N_Read = Ssize_T (Nhe_O.Page_Size) or else N_Read = 0;
      end loop;

      Close_R := Posix_Close (Fd);

      if N_Read = Ssize_T (Nhe_O.Page_Size) and then Close_R = 0 then
         Success := True;
         Is_EOF  := False;
      elsif N_Read = 0 and then Close_R = 0 then
         Buffer  := [others => 0];
         Success := False;
         Is_EOF  := True;
      else
         Buffer  := [others => 0];
         Success := False;
         Is_EOF  := False;
      end if;
   end Read_Page;

   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean)
   is
      Ignored_EOF : Boolean;
      pragma Warnings (Off, Ignored_EOF);
   begin
      Read_Page (File_Path, Page_Id, Buffer, Success, Ignored_EOF);
   end Read_Page;

   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
   is
      C_Path         : C_Path_String;
      Fd             : int;
      End_Pos        : Off_T;
      Frame_Count    : Off_T;
      Aligned_Offset : Off_T;
      Written        : Ssize_T;
      Sync_Rc        : int;
      Trunc_R        : int;
      Close_R        : int;
      pragma Warnings (Off, Trunc_R);
      pragma Warnings (Off, Close_R);
   begin
      if Has_Embedded_NUL (WAL_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (WAL_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_NONBLOCK + O_CLOEXEC, Mode_0600);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      --  Reject torn/unaligned WAL tails instead of overwriting them
      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      if End_Pos < 0 or else End_Pos mod Off_T (WAL_Frame_Size) /= 0 then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         Success := False;
         return;
      end if;

      Frame_Count := End_Pos / Off_T (WAL_Frame_Size);
      if Frame_Count >= Off_T (Max_WAL_Frames) then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         Success := False;
         return;
      end if;

      Aligned_Offset := Frame_Count * Off_T (WAL_Frame_Size);
      for Attempt in 1 .. Max_IO_Retries loop
         Written := Posix_Pwrite_WAL (Fd, Frame, size_t (WAL_Frame_Size), Aligned_Offset);
         exit when Written = Ssize_T (WAL_Frame_Size);
      end loop;

      Sync_Rc := Posix_Fsync (Fd);
      Success := (Written = Ssize_T (WAL_Frame_Size)) and then (Sync_Rc = 0);

      --  A frame that was not durably appended must not survive in the WAL: drop any
      --  partial or unsynced bytes so recovery can never replay a failed append
      if not Success then
         Trunc_R := Posix_Ftruncate (Fd, Aligned_Offset);
         Sync_Rc := Posix_Fsync (Fd);
      end if;

      Close_R := Posix_Close (Fd);
   end Append_WAL_Frame;

   procedure Read_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     :    out WAL_Frame_Buffer;
      Success   :    out Boolean;
      Is_EOF    :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      End_Pos : Off_T;
      Offset  : constant Off_T := Off_T (Frame_Idx) * Off_T (WAL_Frame_Size);
      N_Read  : Ssize_T;
      Close_R : int;
      pragma Warnings (Off, Close_R);
   begin
      Frame   := [others => 0];
      Success := False;
      Is_EOF  := False;

      if Has_Embedded_NUL (WAL_Path) then
         return;
      end if;

      To_C_Path (WAL_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDONLY + O_NONBLOCK + O_CLOEXEC, 0);
      if Fd < 0 then
         return;
      end if;

      --  Reject WAL files with torn/unaligned frame tails or more than Max_WAL_Frames frames
      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      if End_Pos < 0
        or else End_Pos mod Off_T (WAL_Frame_Size) /= 0
        or else End_Pos / Off_T (WAL_Frame_Size) > Off_T (Max_WAL_Frames)
      then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         return;
      end if;

      --  No frame can exist at or beyond the Max_WAL_Frames cap of a bounded WAL
      if Frame_Idx >= Max_WAL_Frames then
         Close_R := Posix_Close (Fd);
         Is_EOF  := (Close_R = 0);
         return;
      end if;

      for Attempt in 1 .. Max_IO_Retries loop
         N_Read := Posix_Pread_WAL (Fd, Frame, size_t (WAL_Frame_Size), Offset);
         exit when N_Read = Ssize_T (WAL_Frame_Size) or else N_Read = 0;
      end loop;

      Close_R := Posix_Close (Fd);

      if N_Read = Ssize_T (WAL_Frame_Size) and then Close_R = 0 then
         Success := True;
         Is_EOF  := False;
      elsif N_Read = 0 and then Close_R = 0 then
         Frame   := [others => 0];
         Success := False;
         Is_EOF  := True;
      else
         Frame   := [others => 0];
         Success := False;
         Is_EOF  := False;
      end if;
   end Read_WAL_Frame;

   procedure Read_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     :    out WAL_Frame_Buffer;
      Success   :    out Boolean)
   is
      Ignored_EOF : Boolean;
      pragma Warnings (Off, Ignored_EOF);
   begin
      Read_WAL_Frame (WAL_Path, Frame_Idx, Frame, Success, Ignored_EOF);
   end Read_WAL_Frame;

   procedure Delete_File_If_Exists
     (File_Path : in Bounded_Text)
   is
      C_Path : C_Path_String;
      Rc     : int;
      pragma Unreferenced (Rc);
   begin
      if Has_Embedded_NUL (File_Path) then
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Rc := Posix_Unlink (C_Path);
   end Delete_File_If_Exists;

   procedure Delete_File_If_Exists
     (File_Path : in     Bounded_Text;
      Removed   :    out Boolean)
   is
      C_Path : C_Path_String;
      Rc     : int;
      Still  : Boolean;
      pragma Unreferenced (Rc);
   begin
      if Has_Embedded_NUL (File_Path) then
         Removed := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Rc := Posix_Unlink (C_Path);
      Check_File_Exists (File_Path, Still);
      Removed := not Still;
   end Delete_File_If_Exists;

   procedure Print_Line (Msg : in String) is
   begin
      Ada.Text_IO.Put_Line (Msg);
   end Print_Line;

   procedure Print_Blank_Line is
   begin
      Ada.Text_IO.New_Line;
   end Print_Blank_Line;

   pragma Warnings (GNATprove, Off, "no Global contract available",
                    Reason => "Ada.Command_Line is read-only over OS process argv");
   pragma Warnings (GNATprove, Off, "no Always_Terminates aspect available",
                    Reason => "Ada.Command_Line.Set_Exit_Status always terminates");
   procedure Read_CLI_Arg
     (Index    : in     Positive;
      Arg      :    out Bounded_Text;
      Found    :    out Boolean;
      Too_Long :    out Boolean)
   is
      Count : constant Natural := Ada.Command_Line.Argument_Count;
   begin
      Arg      := (Length => 0, Data => [others => ' ']);
      Found    := False;
      Too_Long := False;
      if Index <= Count then
         declare
            Raw : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Raw'Length <= Max_Text_Len then
               Arg   := Make_Text (Raw);
               Found := True;
            else
               Too_Long := True;
            end if;
         end;
      end if;
   end Read_CLI_Arg;

   procedure Read_CLI_Arg
     (Index : in     Positive;
      Arg   :    out Bounded_Text;
      Found :    out Boolean)
   is
      Ignored_Too_Long : Boolean;
      pragma Warnings (Off, Ignored_Too_Long);
   begin
      Read_CLI_Arg (Index, Arg, Found, Ignored_Too_Long);
   end Read_CLI_Arg;

   procedure Set_Exit_Failure is
   begin
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Set_Exit_Failure;
   pragma Warnings (GNATprove, On, "no Always_Terminates aspect available");
   pragma Warnings (GNATprove, On, "no Global contract available");

end Nhe_O.IO;
