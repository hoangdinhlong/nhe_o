--  Isolated Physical I/O Implementation Body (BR-001 / ADR-002)
--  This is the ONLY module body in the entire repository permitted to disable
--  SPARK_Mode in order to execute physical file system and console I/O operations.
pragma SPARK_Mode (Off);

with Ada.Direct_IO;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

package body Nhe_O.IO is

   package Page_DIO is new Ada.Direct_IO (Element_Type => Page_Buffer);
   use type Page_DIO.Count;
   package SIO renames Ada.Streams.Stream_IO;

   procedure Write_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Natural;
      Buffer    : in     Page_Buffer;
      Success   :    out Boolean)
   is
      Path   : constant String := File_Path.Data (1 .. File_Path.Length);
      File   : Page_DIO.File_Type;
      Target : Page_DIO.Positive_Count;
   begin
      if Ada.Directories.Exists (Path) then
         Page_DIO.Open (File, Page_DIO.Inout_File, Path);
      else
         Page_DIO.Create (File, Page_DIO.Inout_File, Path);
      end if;

      Target := Page_DIO.Positive_Count (Page_Id + 1);
      Page_DIO.Write (File, Buffer, To => Target);
      Page_DIO.Close (File);
      Success := True;
   exception
      when others =>
         if Page_DIO.Is_Open (File) then
            begin
               Page_DIO.Close (File);
            exception
               when others => null;
            end;
         end if;
         Success := False;
   end Write_Page;

   procedure Read_Page
     (File_Path : in     Bounded_Text;
      Page_Id   : in     Natural;
      Buffer    :    out Page_Buffer;
      Success   :    out Boolean)
   is
      Path   : constant String := File_Path.Data (1 .. File_Path.Length);
      File   : Page_DIO.File_Type;
      Target : Page_DIO.Positive_Count;
   begin
      Buffer := [others => 0];
      if not Ada.Directories.Exists (Path) then
         Success := False;
         return;
      end if;

      Page_DIO.Open (File, Page_DIO.In_File, Path);
      Target := Page_DIO.Positive_Count (Page_Id + 1);
      if Target > Page_DIO.Size (File) then
         Page_DIO.Close (File);
         Success := False;
         return;
      end if;

      Page_DIO.Read (File, Buffer, From => Target);
      Page_DIO.Close (File);
      Success := True;
   exception
      when others =>
         if Page_DIO.Is_Open (File) then
            begin
               Page_DIO.Close (File);
            exception
               when others => null;
            end;
         end if;
         Buffer  := [others => 0];
         Success := False;
   end Read_Page;

   procedure Append_WAL_Frame
     (WAL_Path : in     Bounded_Text;
      Frame    : in     WAL_Frame_Buffer;
      Success  :    out Boolean)
   is
      Path : constant String := WAL_Path.Data (1 .. WAL_Path.Length);
      File : SIO.File_Type;
      Raw  : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (WAL_Frame_Size));
   begin
      for I in WAL_Frame_Offset loop
         Raw (Ada.Streams.Stream_Element_Offset (I)) :=
           Ada.Streams.Stream_Element (Frame (I));
      end loop;

      if Ada.Directories.Exists (Path) then
         SIO.Open (File, SIO.Append_File, Path);
      else
         SIO.Create (File, SIO.Out_File, Path);
      end if;

      SIO.Write (File, Raw);
      SIO.Flush (File);
      SIO.Close (File);
      Success := True;
   exception
      when others =>
         if SIO.Is_Open (File) then
            begin
               SIO.Close (File);
            exception
               when others => null;
            end;
         end if;
         Success := False;
   end Append_WAL_Frame;

   procedure Delete_File_If_Exists
     (File_Path : in Bounded_Text)
   is
      Path : constant String := File_Path.Data (1 .. File_Path.Length);
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others => null;
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
