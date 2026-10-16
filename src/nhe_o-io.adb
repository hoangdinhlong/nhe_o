--  Formally Verified Physical I/O Implementation Body (BR-001 / ADR-002)
--  Operates under pragma SPARK_Mode (On) by binding directly to exception-free
--  POSIX kernel syscalls (`open`, `pread`, `pwrite`, `write`, `fsync`, `close`,
--  `unlink`) with explicit return-code verification and bounded offset arithmetic.
pragma SPARK_Mode (On);

with Ada.Text_IO;
with Interfaces.C; use Interfaces.C;

package body Nhe_O.IO is

   subtype Ssize_T is Interfaces.Integer_64;
   subtype Off_T   is Interfaces.Integer_64;

   use type Interfaces.Integer_64;

   --  POSIX open(2) flags and file mode (0600 octal = S_IRUSR | S_IWUSR)
   O_RDONLY   : constant int      := 8#0#;
   O_WRONLY   : constant int      := 8#1#;
   O_RDWR     : constant int      := 8#2#;
   O_CREAT    : constant int      := 8#100#;
   O_APPEND   : constant int      := 8#2000#;
   O_CLOEXEC  : constant int      := 8#2000000#;
   Mode_0600  : constant unsigned := 8#600#;

   --  Contract-bound POSIX kernel syscall bindings (never raise Ada exceptions)
   function Posix_Open
     (Path  : C_Path_String;
      Flags : int;
      Mode  : unsigned) return int
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "open";

   function Posix_Pwrite
     (Fd     : int;
      Buf    : Page_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "pwrite";

   function Posix_Pread
     (Fd     : int;
      Buf    : in out Page_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "pread";

   function Posix_Write_WAL
     (Fd    : int;
      Buf   : WAL_Frame_Buffer;
      Count : size_t) return Ssize_T
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "write";

   function Posix_Pread_WAL
     (Fd     : int;
      Buf    : in out WAL_Frame_Buffer;
      Count  : size_t;
      Offset : Off_T) return Ssize_T
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "pread";

   function Posix_Fsync (Fd : int) return int
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "fsync";

   function Posix_Close (Fd : int) return int
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "close";

   function Posix_Unlink (Path : C_Path_String) return int
     with Side_Effects,
          Import        => True,
          Convention    => C,
          External_Name => "unlink";

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

   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Valid_Page_Id;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Offset  : constant Off_T := Off_T (Page_Id) * Off_T (Nhe_O.Page_Size);
      Written : Ssize_T;
      Sync_Rc : int;
      Close_R : int;
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

      Written := Posix_Pwrite (Fd, Buffer, size_t (Nhe_O.Page_Size), Offset);
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
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Offset  : constant Off_T := Off_T (Page_Id) * Off_T (Nhe_O.Page_Size);
      N_Read  : Ssize_T;
      Close_R : int;
   begin
      Buffer := [others => 0];
      if Has_Embedded_NUL (File_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (File_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDONLY + O_CLOEXEC, 0);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      N_Read  := Posix_Pread (Fd, Buffer, size_t (Nhe_O.Page_Size), Offset);
      Close_R := Posix_Close (Fd);

      if N_Read = Ssize_T (Nhe_O.Page_Size) and then Close_R = 0 then
         Success := True;
      else
         Buffer  := [others => 0];
         Success := False;
      end if;
   end Read_Page;

   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Written : Ssize_T;
      Sync_Rc : int;
      Close_R : int;
   begin
      if Has_Embedded_NUL (WAL_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (WAL_Path, C_Path);
      Fd := Posix_Open (C_Path, O_WRONLY + O_CREAT + O_APPEND + O_CLOEXEC, Mode_0600);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      Written := Posix_Write_WAL (Fd, Frame, size_t (WAL_Frame_Size));
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
      Success   :    out Boolean)
   is
      C_Path  : C_Path_String;
      Fd      : int;
      Offset  : constant Off_T := Off_T (Frame_Idx) * Off_T (WAL_Frame_Size);
      N_Read  : Ssize_T;
      Close_R : int;
   begin
      Frame := [others => 0];
      if Has_Embedded_NUL (WAL_Path) then
         Success := False;
         return;
      end if;

      To_C_Path (WAL_Path, C_Path);
      Fd := Posix_Open (C_Path, O_RDONLY + O_CLOEXEC, 0);
      if Fd < 0 then
         Success := False;
         return;
      end if;

      N_Read  := Posix_Pread_WAL (Fd, Frame, size_t (WAL_Frame_Size), Offset);
      Close_R := Posix_Close (Fd);

      if N_Read = Ssize_T (WAL_Frame_Size) and then Close_R = 0 then
         Success := True;
      else
         Frame   := [others => 0];
         Success := False;
      end if;
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

end Nhe_O.IO;
