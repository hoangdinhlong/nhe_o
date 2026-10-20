--  Formally Verified Physical I/O Implementation Body (BR-001 / ADR-002)
--  Operates under pragma SPARK_Mode (On) by binding directly to exception-free
--  POSIX kernel syscalls (`open`, `pread`, `pwrite`, `lseek`, `fsync`, `close`,
--  `unlink`, `access`) with explicit return-code verification and bounded offset arithmetic.
pragma SPARK_Mode (On);

with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C; use Interfaces.C;

package body Nhe_O.IO is

   subtype Ssize_T is Interfaces.Integer_64;
   subtype Off_T   is Interfaces.Integer_64;

   use type Interfaces.Integer_64;

   --  POSIX open(2) / lseek(2) flags for x86_64-linux-gnu target (0600 octal = S_IRUSR | S_IWUSR)
   O_RDONLY       : constant int      := 8#0#;
   O_RDWR         : constant int      := 8#2#;
   O_CREAT        : constant int      := 8#100#;
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
         pragma Loop_Invariant (I in 1 .. Path.Length);
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
      Close_R : int;
      pragma Warnings (Off, Close_R);
   begin
      if Has_Embedded_NUL (File_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_CLOEXEC, Mode_0600);
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
      Close_R := Posix_Close (Fd);

      Success := (Written = Ssize_T (Nhe_O.Page_Size))
                 and then (Sync_Rc = 0)
                 and then (Close_R = 0);
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
      Fd := Posix_Open (C_Path, O_RDONLY + O_CLOEXEC, 0);
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

   procedure Write_WAL_Frame
     (WAL_Path  : in     Bounded_Text;
      Frame_Idx : in     Valid_Page_Id;
      Frame     : in     WAL_Frame_Buffer;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      End_Pos : Off_T;
      Offset  : constant Off_T := Off_T (Frame_Idx) * Off_T (WAL_Frame_Size);
      Written : Ssize_T;
      Sync_Rc : int;
      Close_R : int;
      pragma Warnings (Off, Close_R);
   begin
      if Has_Embedded_NUL (WAL_Path) or else Frame_Idx >= Max_WAL_Frames then
         Success := False;
         return;
      end if;

      To_C_Path (WAL_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_CLOEXEC, Mode_0600);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      --  Reject WAL files with torn/unaligned frame tails, > Max_WAL_Frames, or sparse gaps
      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      if End_Pos < 0
        or else End_Pos mod Off_T (WAL_Frame_Size) /= 0
        or else End_Pos / Off_T (WAL_Frame_Size) > Off_T (Max_WAL_Frames)
        or else Off_T (Frame_Idx) > End_Pos / Off_T (WAL_Frame_Size)
      then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         Success := False;
         return;
      end if;

      for Attempt in 1 .. Max_IO_Retries loop
         Written := Posix_Pwrite_WAL (Fd, Frame, size_t (WAL_Frame_Size), Offset);
         exit when Written = Ssize_T (WAL_Frame_Size);
      end loop;

      Sync_Rc := Posix_Fsync (Fd);
      Close_R := Posix_Close (Fd);

      Success := (Written = Ssize_T (WAL_Frame_Size))
                 and then (Sync_Rc = 0)
                 and then (Close_R = 0);
   end Write_WAL_Frame;

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
      Close_R        : int;
      pragma Warnings (Off, Close_R);
   begin
      if Has_Embedded_NUL (WAL_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (WAL_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDWR + O_CREAT + O_CLOEXEC, Mode_0600);
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
      Close_R := Posix_Close (Fd);

      Success := (Written = Ssize_T (WAL_Frame_Size))
                 and then (Sync_Rc = 0)
                 and then (Close_R = 0);
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
      Fd := Posix_Open (C_Path, O_RDONLY + O_CLOEXEC, 0);
      if Fd < 0 then
         return;
      end if;

      --  Reject WAL files with torn/unaligned frame tails
      End_Pos := Posix_Lseek (Fd, 0, SEEK_END);
      if End_Pos < 0 or else End_Pos mod Off_T (WAL_Frame_Size) /= 0 then
         pragma Warnings (GNATprove, Off, "statement has no effect");
         Close_R := Posix_Close (Fd);
         pragma Warnings (GNATprove, On, "statement has no effect");
         return;
      end if;

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
