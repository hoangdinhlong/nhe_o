pragma SPARK_Mode (On);

package body Nhe_O.SQL is

   function Is_Ident_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$');

   function Is_WS_Char (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF or else C = ASCII.CR);

   -------------------------------------------------------------------------
   --  Sanitize_SQL: Strip quoted literals, line comments (--), and block
   --  comments (/* ... */), while rejecting unclosed quotes/comments and
   --  unbalanced parentheses.
   -------------------------------------------------------------------------

   procedure Sanitize_SQL
     (Query : in     Bounded_Text;
      Clean :    out Bounded_Text;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => Clean.Length = Query.Length
   is
      In_Single     : Boolean := False;
      In_Double     : Boolean := False;
      In_Line_Comm  : Boolean := False;
      In_Block_Comm : Boolean := False;
      Skip_Next     : Boolean := False;
      Paren_Depth   : Integer range 0 .. Max_Text_Len := 0;
   begin
      Clean := Query;
      Valid := False;

      for I in 1 .. Query.Length loop
         pragma Loop_Invariant
           (I in 1 .. Query.Length
            and then Clean.Length = Query.Length
            and then Paren_Depth in 0 .. I - 1);

         if Skip_Next then
            Skip_Next      := False;
            Clean.Data (I) := ' ';
         elsif In_Line_Comm then
            Clean.Data (I) := ' ';
            if Query.Data (I) = ASCII.LF or else Query.Data (I) = ASCII.CR then
               In_Line_Comm := False;
            end if;
         elsif In_Block_Comm then
            Clean.Data (I) := ' ';
            if Query.Data (I) = '*'
              and then I < Query.Length
              and then Query.Data (I + 1) = '/'
            then
               In_Block_Comm := False;
               Skip_Next     := True;
            end if;
         elsif In_Single then
            --  Preserve placeholder 'x' inside quotes so SELECT 'a' knows a token existed
            Clean.Data (I) := ' ';
            if Query.Data (I) = ''' then
               if I < Query.Length and then Query.Data (I + 1) = ''' then
                  Skip_Next := True;
               else
                  In_Single := False;
               end if;
            end if;
         elsif In_Double then
            Clean.Data (I) := 'x';
            if Query.Data (I) = '"' then
               if I < Query.Length and then Query.Data (I + 1) = '"' then
                  Skip_Next := True;
               else
                  In_Double      := False;
                  Clean.Data (I) := ' ';
               end if;
            end if;
         else
            if Query.Data (I) = '-'
              and then I < Query.Length
              and then Query.Data (I + 1) = '-'
            then
               In_Line_Comm   := True;
               Clean.Data (I) := ' ';
               Skip_Next      := True;
            elsif Query.Data (I) = '/'
              and then I < Query.Length
              and then Query.Data (I + 1) = '*'
            then
               In_Block_Comm  := True;
               Clean.Data (I) := ' ';
               Skip_Next      := True;
            elsif Query.Data (I) = ''' then
               In_Single      := True;
               Clean.Data (I) := ''';
            elsif Query.Data (I) = '"' then
               In_Double      := True;
               Clean.Data (I) := ' ';
            elsif Query.Data (I) = '(' then
               Paren_Depth := Paren_Depth + 1;
            elsif Query.Data (I) = ')' then
               if Paren_Depth = 0 then
                  return;
               end if;
               Paren_Depth := Paren_Depth - 1;
            end if;
         end if;
      end loop;

      Valid :=
        (not In_Single)
        and then (not In_Double)
        and then (not In_Block_Comm)
        and then (Paren_Depth = 0);
   end Sanitize_SQL;

   function Contains_Substring_CI
     (Haystack : Bounded_Text;
      Needle   : String) return Boolean
     with Pre => Needle'Length > 0 and then Needle'Length <= Max_Text_Len
   is
      N_Len : constant Natural := Needle'Length;
      Match : Boolean;
   begin
      if Haystack.Length < N_Len then
         return False;
      end if;

      for Start in 1 .. (Haystack.Length - N_Len + 1) loop
         pragma Loop_Invariant (Start in 1 .. (Haystack.Length - N_Len + 1));
         Match := True;
         for Offset in 0 .. N_Len - 1 loop
            if To_Lower_Char (Haystack.Data (Start + Offset)) /=
               To_Lower_Char (Needle (Needle'First + Offset))
            then
               Match := False;
               exit;
            end if;
         end loop;
         if Match then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Substring_CI;

   --  Match a whole SQL keyword or multi-word keyword phrase outside quotes
   --  with identifier boundary checks on both sides.
   function Contains_Keyword_CI
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Boolean
     with Pre => Keyword'Length > 0 and then Keyword'Length <= Max_Text_Len
   is
      K_Len : constant Natural := Keyword'Length;
      Match : Boolean;
   begin
      if Clean_Query.Length < K_Len then
         return False;
      end if;

      for Start in 1 .. (Clean_Query.Length - K_Len + 1) loop
         pragma Loop_Invariant (Start in 1 .. (Clean_Query.Length - K_Len + 1));
         if (Start = 1 or else not Is_Ident_Char (Clean_Query.Data (Start - 1)))
           and then (Start + K_Len - 1 = Clean_Query.Length
                     or else not Is_Ident_Char (Clean_Query.Data (Start + K_Len)))
         then
            Match := True;
            for Offset in 0 .. K_Len - 1 loop
               if To_Lower_Char (Clean_Query.Data (Start + Offset)) /=
                  To_Lower_Char (Keyword (Keyword'First + Offset))
               then
                  Match := False;
                  exit;
               end if;
            end loop;
            if Match then
               return True;
            end if;
         end if;
      end loop;
      return False;
   end Contains_Keyword_CI;

   function Is_Ident_Start_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '_');

   function Find_Keyword_Start
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Natural
     with Pre  => Keyword'Length > 0 and then Keyword'Length <= Max_Text_Len,
          Post => Find_Keyword_Start'Result <= Clean_Query.Length
   is
      K_Len : constant Natural := Keyword'Length;
      Match : Boolean;
   begin
      if Clean_Query.Length < K_Len then
         return 0;
      end if;

      for Start in 1 .. (Clean_Query.Length - K_Len + 1) loop
         pragma Loop_Invariant (Start in 1 .. (Clean_Query.Length - K_Len + 1));
         if (Start = 1 or else not Is_Ident_Char (Clean_Query.Data (Start - 1)))
           and then (Start + K_Len - 1 = Clean_Query.Length
                     or else not Is_Ident_Char (Clean_Query.Data (Start + K_Len)))
         then
            Match := True;
            for Offset in 0 .. K_Len - 1 loop
               if To_Lower_Char (Clean_Query.Data (Start + Offset)) /=
                  To_Lower_Char (Keyword (Keyword'First + Offset))
               then
                  Match := False;
                  exit;
               end if;
            end loop;
            if Match then
               return Start;
            end if;
         end if;
      end loop;
      return 0;
   end Find_Keyword_Start;

   function Find_Keyword_End
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Natural
     with Pre  => Keyword'Length > 0 and then Keyword'Length <= Max_Text_Len,
          Post => Find_Keyword_End'Result <= Clean_Query.Length
   is
      K_Len : constant Natural := Keyword'Length;
      Start : constant Natural := Find_Keyword_Start (Clean_Query, Keyword);
   begin
      if Start = 0 or else Start + K_Len - 1 > Clean_Query.Length then
         return 0;
      else
         return Start + K_Len - 1;
      end if;
   end Find_Keyword_End;

   function Count_Keyword_Occurrences
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Natural
     with Pre  => Keyword'Length > 0 and then Keyword'Length <= Max_Text_Len,
          Post => Count_Keyword_Occurrences'Result <= Clean_Query.Length
   is
      K_Len : constant Natural := Keyword'Length;
      Match : Boolean;
      Count : Natural := 0;
   begin
      if Clean_Query.Length < K_Len then
         return 0;
      end if;

      for Start in 1 .. (Clean_Query.Length - K_Len + 1) loop
         pragma Loop_Invariant (Start in 1 .. (Clean_Query.Length - K_Len + 1));
         pragma Loop_Invariant (Count < Start);
         if (Start = 1 or else not Is_Ident_Char (Clean_Query.Data (Start - 1)))
           and then (Start + K_Len - 1 = Clean_Query.Length
                     or else not Is_Ident_Char (Clean_Query.Data (Start + K_Len)))
         then
            Match := True;
            for Offset in 0 .. K_Len - 1 loop
               if To_Lower_Char (Clean_Query.Data (Start + Offset)) /=
                  To_Lower_Char (Keyword (Keyword'First + Offset))
               then
                  Match := False;
                  exit;
               end if;
            end loop;
            if Match then
               Count := Count + 1;
            end if;
         end if;
      end loop;
      return Count;
   end Count_Keyword_Occurrences;

   function Is_Reserved_Clause_Ident (Tok : Bounded_Ident) return Boolean is
     (Equal_Ident_Case_Insensitive (Tok, Make_Ident ("SELECT"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("FROM"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("WHERE"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("ORDER"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("BY"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("LIMIT"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("SET"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("INTO"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("VALUES"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("CREATE"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("TABLE"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("INSERT"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("UPDATE"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("DELETE"))
      or else Equal_Ident_Case_Insensitive (Tok, Make_Ident ("DROP")));

   function Has_Non_WS_Range
     (Clean_Query : Bounded_Text;
      First_Idx   : Positive;
      Last_Idx    : Natural) return Boolean
     with Pre => Last_Idx <= Clean_Query.Length
   is
   begin
      if First_Idx > Last_Idx then
         return False;
      end if;
      for I in First_Idx .. Last_Idx loop
         if not Is_WS_Char (Clean_Query.Data (I))
           and then Clean_Query.Data (I) /= ';'
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Non_WS_Range;

   --  Extract the next valid SQL identifier token following Keyword (e.g. FROM <table>)
   --  Rejects identifiers starting with digits/'$'/'.', consecutive dots, or trailing dots.
   function Extract_Ident_After_Keyword
     (Clean_Query : Bounded_Text;
      Orig_Query  : Bounded_Text;
      Keyword     : String) return Bounded_Ident
     with Pre => Keyword'Length > 0
                 and then Keyword'Length <= Max_Text_Len
                 and then Clean_Query.Length = Orig_Query.Length
   is
      Kw_End         : constant Natural := Find_Keyword_End (Clean_Query, Keyword);
      Pos            : Natural          := Kw_End;
      Res            : Bounded_Ident    := (Length => 0, Data => [others => ' ']);
      Empty_Res      : constant Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Need_Seg_Start : Boolean          := True;
      Saw_Dot        : Boolean          := False;
      Ch             : Character;
   begin
      if Pos = 0 or else Pos >= Clean_Query.Length then
         return Empty_Res;
      end if;

      Pos := Pos + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos > Clean_Query.Length then
         return Empty_Res;
      end if;

      while Pos <= Clean_Query.Length
        and then (Is_Ident_Char (Orig_Query.Data (Pos)) or else Orig_Query.Data (Pos) = '.')
      loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Invariant (Res.Length <= Max_Ident_Len);
         pragma Loop_Variant (Increases => Pos);
         Ch := Orig_Query.Data (Pos);
         if Ch = '.' then
            if Need_Seg_Start or else Saw_Dot then
               return Empty_Res;
            end if;
            Saw_Dot        := True;
            Need_Seg_Start := True;
         else
            if Need_Seg_Start and then not Is_Ident_Start_Char (Ch) then
               return Empty_Res;
            end if;
            Need_Seg_Start := False;
         end if;

         if Res.Length = Max_Ident_Len then
            return Empty_Res;
         end if;
         Res.Length            := Res.Length + 1;
         Res.Data (Res.Length) := Ch;
         Pos                   := Pos + 1;
      end loop;

      if Need_Seg_Start or else Res.Length = 0 then
         return Empty_Res;
      end if;

      return Res;
   end Extract_Ident_After_Keyword;

   --  Extract table name from CREATE TABLE [IF NOT EXISTS] <name> (...)
   function Extract_Create_Table_Name
     (Clean_Query : Bounded_Text;
      Orig_Query  : Bounded_Text) return Bounded_Ident
     with Pre => Clean_Query.Length = Orig_Query.Length
   is
      Empty_Res  : constant Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Table_End  : constant Natural       := Find_Keyword_End (Clean_Query, "TABLE");
      INE_Start  : constant Natural       := Find_Keyword_Start (Clean_Query, "IF NOT EXISTS");
      INE_End    : constant Natural       := Find_Keyword_End (Clean_Query, "IF NOT EXISTS");
      First_Tok  : Bounded_Ident;
      Target_Tok : Bounded_Ident;
      Scan_Start : Natural;
      Pos        : Natural;
   begin
      if Table_End = 0 or else Table_End >= Clean_Query.Length then
         return Empty_Res;
      end if;

      First_Tok := Extract_Ident_After_Keyword (Clean_Query, Orig_Query, "TABLE");
      if Equal_Ident_Case_Insensitive (First_Tok, Make_Ident ("IF")) then
         if INE_Start = 0 or else INE_Start <= Table_End or else INE_End = 0 then
            return Empty_Res;
         end if;
         Target_Tok := Extract_Ident_After_Keyword (Clean_Query, Orig_Query, "IF NOT EXISTS");
         Scan_Start := INE_End;
      else
         Target_Tok := First_Tok;
         Scan_Start := Table_End;
      end if;

      if Target_Tok.Length = 0 or else Scan_Start >= Clean_Query.Length then
         return Empty_Res;
      end if;

      --  Verify that only whitespace separates the table name from '('
      Pos := Scan_Start + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length
        and then (Is_Ident_Char (Orig_Query.Data (Pos)) or else Orig_Query.Data (Pos) = '.')
      loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos > Clean_Query.Length or else Clean_Query.Data (Pos) /= '(' then
         return Empty_Res;
      end if;

      return Target_Tok;
   end Extract_Create_Table_Name;

   procedure Parse_Limit_Clause
     (Clean_Query : in     Bounded_Text;
      Limit_Val   :    out Natural;
      Valid       :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if not Valid then Limit_Val = 0)
   is
      Kw_End    : constant Natural := Find_Keyword_End (Clean_Query, "LIMIT");
      Pos       : Natural          := Kw_End;
      Acc       : Natural          := 0;
      Has_Digit : Boolean          := False;
      Digit     : Natural;
   begin
      Limit_Val := 0;
      Valid     := False;

      if Pos = 0 or else Pos >= Clean_Query.Length then
         return;
      end if;

      Pos := Pos + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length and then Clean_Query.Data (Pos) in '0' .. '9' loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Has_Digit := True;
         Digit     := Character'Pos (Clean_Query.Data (Pos)) - Character'Pos ('0');
         if Acc <= (Natural'Last - Digit) / 10 then
            Acc := Acc * 10 + Digit;
         else
            return;
         end if;
         Pos := Pos + 1;
      end loop;

      if not Has_Digit then
         return;
      end if;

      while Pos <= Clean_Query.Length loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         if not Is_WS_Char (Clean_Query.Data (Pos))
           and then Clean_Query.Data (Pos) /= ';'
         then
            return;
         end if;
         Pos := Pos + 1;
      end loop;

      Limit_Val := Acc;
      Valid     := True;
   end Parse_Limit_Clause;

   function Starts_With_Keyword
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Boolean
     with Pre => Keyword'Length > 0 and then Keyword'Length <= Max_Ident_Len
   is
      First_Pos : Natural := 0;
      K_Len     : constant Natural := Keyword'Length;
   begin
      for I in 1 .. Clean_Query.Length loop
         pragma Loop_Invariant (First_Pos = 0);
         if not Is_WS_Char (Clean_Query.Data (I)) then
            First_Pos := I;
            exit;
         end if;
      end loop;

      if First_Pos = 0 or else First_Pos + K_Len - 1 > Clean_Query.Length then
         return False;
      end if;

      for J in 0 .. K_Len - 1 loop
         if To_Lower_Char (Clean_Query.Data (First_Pos + J)) /=
            To_Lower_Char (Keyword (Keyword'First + J))
         then
            return False;
         end if;
      end loop;

      if First_Pos + K_Len <= Clean_Query.Length then
         declare
            Next_C : constant Character := Clean_Query.Data (First_Pos + K_Len);
         begin
            return not Is_Ident_Char (Next_C);
         end;
      end if;
      return True;
   end Starts_With_Keyword;

   --  Verify `CREATE [TEMP|TEMPORARY|UNLOGGED] TABLE [IF NOT EXISTS] <name> (...)`
   --  without falsely rejecting column names containing `view`, `index`, `schema`.
   function Is_Create_Table_Stmt (Clean_Query : Bounded_Text) return Boolean is
      Create_End  : constant Natural := Find_Keyword_End (Clean_Query, "CREATE");
      Table_Start : constant Natural := Find_Keyword_Start (Clean_Query, "TABLE");
      Table_End   : constant Natural := Find_Keyword_End (Clean_Query, "TABLE");
      Paren_Pos   : Natural := 0;
      Pos         : Natural;
      Mod_Tok     : Bounded_Ident := (Length => 0, Data => [others => ' ']);
   begin
      if not Starts_With_Keyword (Clean_Query, "CREATE") then
         return False;
      end if;
      if Create_End = 0 or else Table_Start <= Create_End or else Table_End <= Create_End then
         return False;
      end if;

      --  Find the first '(' of the column definition list
      for I in 1 .. Clean_Query.Length loop
         if Clean_Query.Data (I) = '(' then
            Paren_Pos := I;
            exit;
         end if;
      end loop;

      --  TABLE must appear strictly before the '(' of the column list, and
      --  there must be a table identifier between TABLE and '('
      if Paren_Pos = 0 or else Table_End >= Paren_Pos then
         return False;
      end if;

      --  Between CREATE and TABLE, allow only whitespace or a single
      --  TEMP / TEMPORARY / UNLOGGED modifier keyword.
      Pos := Create_End + 1;
      while Pos < Table_Start and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Table_Start);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos < Table_Start then
         while Pos < Table_Start and then Is_Ident_Char (Clean_Query.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Table_Start);
            pragma Loop_Invariant (Mod_Tok.Length <= Max_Ident_Len);
            pragma Loop_Variant (Increases => Pos);
            if Mod_Tok.Length = Max_Ident_Len then
               return False;
            end if;
            Mod_Tok.Length := Mod_Tok.Length + 1;
            Mod_Tok.Data (Mod_Tok.Length) := Clean_Query.Data (Pos);
            Pos := Pos + 1;
         end loop;

         while Pos < Table_Start and then Is_WS_Char (Clean_Query.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Table_Start);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos /= Table_Start
           or else (not Equal_Ident_Case_Insensitive (Mod_Tok, Make_Ident ("TEMP"))
                    and then not Equal_Ident_Case_Insensitive (Mod_Tok, Make_Ident ("TEMPORARY"))
                    and then not Equal_Ident_Case_Insensitive (Mod_Tok, Make_Ident ("UNLOGGED")))
         then
            return False;
         end if;
      end if;

      return True;
   end Is_Create_Table_Stmt;

   function Has_Token_After_Keyword
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Boolean
     with Pre => Keyword'Length > 0 and then Keyword'Length <= Max_Ident_Len
   is
      Kw_End : constant Natural := Find_Keyword_End (Clean_Query, Keyword);
   begin
      if Kw_End = 0 or else Kw_End >= Clean_Query.Length then
         return False;
      end if;
      for I in Kw_End + 1 .. Clean_Query.Length loop
         if not Is_WS_Char (Clean_Query.Data (I))
           and then Clean_Query.Data (I) /= ';'
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Token_After_Keyword;

   --  Validate BEGIN / COMMIT / ROLLBACK [TRANSACTION | WORK] [;]
   function Is_Valid_Tx_Control_Stmt
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Boolean
     with Pre => Keyword'Length > 0 and then Keyword'Length <= Max_Ident_Len
   is
      Kw_End : constant Natural := Find_Keyword_End (Clean_Query, Keyword);
      Pos    : Natural;
      Tok    : Bounded_Ident;
   begin
      if Kw_End = 0 then
         return False;
      end if;
      if not Has_Token_After_Keyword (Clean_Query, Keyword) then
         return True;
      end if;

      Tok := Extract_Ident_After_Keyword (Clean_Query, Clean_Query, Keyword);
      if not Equal_Ident_Case_Insensitive (Tok, Make_Ident ("TRANSACTION"))
        and then not Equal_Ident_Case_Insensitive (Tok, Make_Ident ("WORK"))
      then
         return False;
      end if;

      Pos := Kw_End + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length and then Is_Ident_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         if not Is_WS_Char (Clean_Query.Data (Pos))
           and then Clean_Query.Data (Pos) /= ';'
         then
            return False;
         end if;
         Pos := Pos + 1;
      end loop;

      return True;
   end Is_Valid_Tx_Control_Stmt;

   --  Validate single-identifier statement tails for LISTEN <channel> [;]
   function Has_Only_Single_Ident_After_Keyword
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Boolean
     with Pre => Keyword'Length > 0 and then Keyword'Length <= Max_Ident_Len
   is
      Kw_End : constant Natural := Find_Keyword_End (Clean_Query, Keyword);
      Pos    : Natural;
   begin
      if Kw_End = 0 or else Kw_End >= Clean_Query.Length then
         return False;
      end if;

      Pos := Kw_End + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length
        and then (Is_Ident_Char (Clean_Query.Data (Pos)) or else Clean_Query.Data (Pos) = '.')
      loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         if not Is_WS_Char (Clean_Query.Data (Pos))
           and then Clean_Query.Data (Pos) /= ';'
         then
            return False;
         end if;
         Pos := Pos + 1;
      end loop;

      return True;
   end Has_Only_Single_Ident_After_Keyword;

   --  Validate NOTIFY <channel> [ , '<payload>' ] [;]
   function Is_Valid_Notify_Stmt (Clean_Query : Bounded_Text) return Boolean is
      Kw_End : constant Natural := Find_Keyword_End (Clean_Query, "NOTIFY");
      Pos    : Natural;
   begin
      if Kw_End = 0 or else Kw_End >= Clean_Query.Length then
         return False;
      end if;

      Pos := Kw_End + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length
        and then (Is_Ident_Char (Clean_Query.Data (Pos)) or else Clean_Query.Data (Pos) = '.')
      loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos <= Clean_Query.Length and then Clean_Query.Data (Pos) = ',' then
         Pos := Pos + 1;
         while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;
         if Pos > Clean_Query.Length or else Clean_Query.Data (Pos) /= ''' then
            return False;
         end if;
         Pos := Pos + 1;
      end if;

      while Pos <= Clean_Query.Length loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         if not Is_WS_Char (Clean_Query.Data (Pos))
           and then Clean_Query.Data (Pos) /= ';'
         then
            return False;
         end if;
         Pos := Pos + 1;
      end loop;

      return True;
   end Is_Valid_Notify_Stmt;

   --  Validate SELECT / UPDATE / DELETE clause ordering, non-duplicate clauses, and non-empty clause bodies
   function Validate_Clause_Structure
     (Clean_Query : Bounded_Text;
      Kind        : SQL_Statement_Kind) return Boolean
   is
      From_Start  : constant Natural := Find_Keyword_Start (Clean_Query, "FROM");
      From_End    : constant Natural := Find_Keyword_End (Clean_Query, "FROM");
      Where_Start : constant Natural := Find_Keyword_Start (Clean_Query, "WHERE");
      Where_End   : constant Natural := Find_Keyword_End (Clean_Query, "WHERE");
      Order_Start : constant Natural := Find_Keyword_Start (Clean_Query, "ORDER BY");
      Order_End   : constant Natural := Find_Keyword_End (Clean_Query, "ORDER BY");
      Limit_Start : constant Natural := Find_Keyword_Start (Clean_Query, "LIMIT");
      Set_Start   : constant Natural := Find_Keyword_Start (Clean_Query, "SET");
      Set_End     : constant Natural := Find_Keyword_End (Clean_Query, "SET");
      OC_Start    : constant Natural := Find_Keyword_Start (Clean_Query, "ON CONFLICT");
      OC_End      : constant Natural := Find_Keyword_End (Clean_Query, "ON CONFLICT");
      Ret_Start   : constant Natural := Find_Keyword_Start (Clean_Query, "RETURNING");
      Ret_End     : constant Natural := Find_Keyword_End (Clean_Query, "RETURNING");
      Body_End    : Natural;
   begin
      if Count_Keyword_Occurrences (Clean_Query, "FROM") > 1
        or else Count_Keyword_Occurrences (Clean_Query, "WHERE") > 1
        or else Count_Keyword_Occurrences (Clean_Query, "ORDER BY") > 1
        or else Count_Keyword_Occurrences (Clean_Query, "LIMIT") > 1
        or else Count_Keyword_Occurrences (Clean_Query, "SET") > 1
        or else Count_Keyword_Occurrences (Clean_Query, "ON CONFLICT") > 1
        or else Count_Keyword_Occurrences (Clean_Query, "RETURNING") > 1
      then
         return False;
      end if;

      if OC_Start > 0 then
         if Kind /= Stmt_Insert
           or else OC_End = 0
           or else OC_End >= Clean_Query.Length
         then
            return False;
         end if;
         Body_End := (if Ret_Start > OC_End then Ret_Start - 1 else Clean_Query.Length);
         if OC_End >= Body_End
           or else not Has_Non_WS_Range (Clean_Query, OC_End + 1, Body_End)
         then
            return False;
         end if;
      end if;

      if Ret_Start > 0 then
         if Kind not in Stmt_Insert | Stmt_Update | Stmt_Delete
           or else Ret_End = 0
           or else Ret_End >= Clean_Query.Length
           or else not Has_Non_WS_Range (Clean_Query, Ret_End + 1, Clean_Query.Length)
         then
            return False;
         end if;
         if (Where_End > 0 and then Where_End >= Ret_Start)
           or else (OC_End > 0 and then OC_End >= Ret_Start)
         then
            return False;
         end if;
      end if;

      if Kind = Stmt_Select then
         if Set_Start > 0 then
            return False;
         end if;
         if From_Start = 0
           and then (Where_Start > 0 or else Order_Start > 0 or else Limit_Start > 0)
         then
            return False;
         end if;
      end if;

      if From_End > 0 then
         if (Where_Start > 0 and then From_End >= Where_Start)
           or else (Order_Start > 0 and then From_End >= Order_Start)
           or else (Limit_Start > 0 and then From_End >= Limit_Start)
         then
            return False;
         end if;
         Body_End :=
           (if Where_Start > 0 then Where_Start - 1
            elsif Order_Start > 0 then Order_Start - 1
            elsif Limit_Start > 0 then Limit_Start - 1
            elsif Ret_Start > 0 then Ret_Start - 1
            else Clean_Query.Length);
         if From_End >= Body_End
           or else not Has_Non_WS_Range (Clean_Query, From_End + 1, Body_End)
         then
            return False;
         end if;
      end if;

      if Kind = Stmt_Update then
         if Set_Start = 0 or else Set_End = 0 then
            return False;
         end if;
         if Where_Start > 0 and then Set_End >= Where_Start then
            return False;
         end if;
         Body_End :=
           (if Where_Start > 0 then Where_Start - 1
            elsif Ret_Start > 0 then Ret_Start - 1
            else Clean_Query.Length);
         if Set_End >= Body_End
           or else not Has_Non_WS_Range (Clean_Query, Set_End + 1, Body_End)
         then
            return False;
         end if;
      end if;

      if Where_End > 0 then
         if Kind not in Stmt_Select | Stmt_Update | Stmt_Delete then
            return False;
         end if;
         if (Order_Start > 0 and then Where_End >= Order_Start)
           or else (Limit_Start > 0 and then Where_End >= Limit_Start)
         then
            return False;
         end if;
         Body_End :=
           (if Order_Start > 0 then Order_Start - 1
            elsif Limit_Start > 0 then Limit_Start - 1
            elsif Ret_Start > 0 then Ret_Start - 1
            else Clean_Query.Length);
         if Where_End >= Body_End
           or else not Has_Non_WS_Range (Clean_Query, Where_End + 1, Body_End)
         then
            return False;
         end if;
      end if;

      if Order_End > 0 then
         if Kind /= Stmt_Select then
            return False;
         end if;
         if Limit_Start > 0 and then Order_End >= Limit_Start then
            return False;
         end if;
         Body_End := (if Limit_Start > 0 then Limit_Start - 1 else Clean_Query.Length);
         if Order_End >= Body_End
           or else not Has_Non_WS_Range (Clean_Query, Order_End + 1, Body_End)
         then
            return False;
         end if;
      end if;

      if Limit_Start > 0 and then Kind /= Stmt_Select then
         return False;
      end if;

      return True;
   end Validate_Clause_Structure;

   function Count_Select_Columns (Clean_Query : Bounded_Text) return Natural
     with Global => null,
          Post   => Count_Select_Columns'Result <= Clean_Query.Length + 1
   is
      Sel_End       : constant Natural := Find_Keyword_End (Clean_Query, "SELECT");
      From_Start    : constant Natural := Find_Keyword_Start (Clean_Query, "FROM");
      Where_Start   : constant Natural := Find_Keyword_Start (Clean_Query, "WHERE");
      Order_Start   : constant Natural := Find_Keyword_Start (Clean_Query, "ORDER BY");
      Limit_Start   : constant Natural := Find_Keyword_Start (Clean_Query, "LIMIT");
      Stop_Pos      : Natural;
      Depth         : Natural := 0;
      Commas        : Natural := 0;
      Seg_Has_Token : Boolean := False;
   begin
      if Sel_End = 0 or else Sel_End >= Clean_Query.Length then
         return 0;
      end if;

      if From_Start > Sel_End then
         Stop_Pos := From_Start - 1;
      elsif Where_Start > Sel_End then
         Stop_Pos := Where_Start - 1;
      elsif Order_Start > Sel_End then
         Stop_Pos := Order_Start - 1;
      elsif Limit_Start > Sel_End then
         Stop_Pos := Limit_Start - 1;
      else
         Stop_Pos := Clean_Query.Length;
      end if;

      for I in Sel_End + 1 .. Stop_Pos loop
         pragma Loop_Invariant (Depth <= I);
         pragma Loop_Invariant (Commas <= I);
         if Clean_Query.Data (I) = '(' then
            Depth         := Depth + 1;
            Seg_Has_Token := True;
         elsif Clean_Query.Data (I) = ')' and then Depth > 0 then
            Depth         := Depth - 1;
            Seg_Has_Token := True;
         elsif not Is_WS_Char (Clean_Query.Data (I))
           and then Clean_Query.Data (I) /= ';'
         then
            if Clean_Query.Data (I) = ',' and then Depth = 0 then
               if not Seg_Has_Token then
                  return 0;
               end if;
               Commas        := Commas + 1;
               Seg_Has_Token := False;
            else
               Seg_Has_Token := True;
            end if;
         end if;
      end loop;

      if not Seg_Has_Token then
         return 0;
      else
         return Commas + 1;
      end if;
   end Count_Select_Columns;

   --  Validate `<col_ident> <pg_type> [...]` inside a single CREATE TABLE column slice
   function Is_Valid_Column_Def_Slice
     (Clean_Query : Bounded_Text;
      First_Idx   : Positive;
      Last_Idx    : Natural) return Boolean
     with Pre => Last_Idx <= Clean_Query.Length
   is
      Pos        : Natural       := First_Idx;
      Col_Tok    : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Type_Tok   : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Second_W   : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Sub_Depth  : Natural       := 0;
      Resolved_T : Pg_Data_Type;
      pragma Warnings (Off, Resolved_T);
      Type_Valid : Boolean;
   begin
      if First_Idx > Last_Idx then
         return False;
      end if;

      while Pos <= Last_Idx and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos > Last_Idx or else not Is_Ident_Start_Char (Clean_Query.Data (Pos)) then
         return False;
      end if;

      while Pos <= Last_Idx and then Is_Ident_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
         pragma Loop_Invariant (Col_Tok.Length <= Max_Ident_Len);
         pragma Loop_Variant (Increases => Pos);
         if Col_Tok.Length = Max_Ident_Len then
            return False;
         end if;
         Col_Tok.Length := Col_Tok.Length + 1;
         Col_Tok.Data (Col_Tok.Length) := Clean_Query.Data (Pos);
         Pos := Pos + 1;
      end loop;

      if Pos > Last_Idx
        or else not Is_WS_Char (Clean_Query.Data (Pos))
        or else Is_Reserved_Clause_Ident (Col_Tok)
      then
         return False;
      end if;

      while Pos <= Last_Idx and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos > Last_Idx or else not Is_Ident_Start_Char (Clean_Query.Data (Pos)) then
         return False;
      end if;

      while Pos <= Last_Idx and then Is_Ident_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
         pragma Loop_Invariant (Type_Tok.Length <= Max_Ident_Len);
         pragma Loop_Variant (Increases => Pos);
         if Type_Tok.Length = Max_Ident_Len then
            return False;
         end if;
         Type_Tok.Length := Type_Tok.Length + 1;
         Type_Tok.Data (Type_Tok.Length) := Clean_Query.Data (Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Last_Idx and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Equal_Ident_Case_Insensitive (Type_Tok, Make_Ident ("DOUBLE")) then
         while Pos <= Last_Idx and then Is_Ident_Char (Clean_Query.Data (Pos)) loop
            pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
            pragma Loop_Invariant (Second_W.Length <= Max_Ident_Len);
            pragma Loop_Variant (Increases => Pos);
            if Second_W.Length = Max_Ident_Len then
               return False;
            end if;
            Second_W.Length := Second_W.Length + 1;
            Second_W.Data (Second_W.Length) := Clean_Query.Data (Pos);
            Pos := Pos + 1;
         end loop;
         if not Equal_Ident_Case_Insensitive (Second_W, Make_Ident ("PRECISION")) then
            return False;
         end if;
         while Pos <= Last_Idx and then Is_WS_Char (Clean_Query.Data (Pos)) loop
            pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;
         if Pos <= Last_Idx and then Clean_Query.Data (Pos) = '(' then
            return False;
         end if;
         Type_Tok := Make_Ident ("DOUBLE PRECISION");
      elsif Pos <= Last_Idx and then Clean_Query.Data (Pos) = '(' then
         while Pos <= Last_Idx loop
            pragma Loop_Invariant (Pos in First_Idx .. Last_Idx);
            pragma Loop_Invariant (Type_Tok.Length <= Max_Ident_Len);
            pragma Loop_Invariant (Sub_Depth <= Pos);
            pragma Loop_Variant (Increases => Pos);
            if Clean_Query.Data (Pos) = '(' then
               Sub_Depth := Sub_Depth + 1;
            elsif Clean_Query.Data (Pos) = ')' then
               if Sub_Depth = 0 then
                  return False;
               end if;
               Sub_Depth := Sub_Depth - 1;
            end if;

            if not Is_WS_Char (Clean_Query.Data (Pos)) then
               if Type_Tok.Length = Max_Ident_Len then
                  return False;
               end if;
               Type_Tok.Length := Type_Tok.Length + 1;
               Type_Tok.Data (Type_Tok.Length) := Clean_Query.Data (Pos);
            end if;
            Pos := Pos + 1;
            exit when Sub_Depth = 0;
         end loop;

         if Sub_Depth /= 0 then
            return False;
         end if;
      end if;

      pragma Warnings (GNATprove, Off, "is set by ""Resolve_Pg_Type"" but not used after the call");
      Resolve_Pg_Type (Type_Tok, Resolved_T, Type_Valid);
      pragma Warnings (GNATprove, On, "is set by ""Resolve_Pg_Type"" but not used after the call");
      return Type_Valid;
   end Is_Valid_Column_Def_Slice;

   function Count_Create_Table_Columns (Clean_Query : Bounded_Text) return Natural
     with Global => null,
          Post   => Count_Create_Table_Columns'Result <= Clean_Query.Length + 1
   is
      Depth        : Natural := 0;
      Commas       : Natural := 0;
      Seg_Start    : Positive := 1;
      Close_Pos    : Natural := 0;
      Found_Paren  : Boolean := False;
      Closed_Paren : Boolean := False;
   begin
      for I in 1 .. Clean_Query.Length loop
         pragma Loop_Invariant
           (Depth <= I
            and then Commas <= I
            and then Seg_Start in 1 .. Clean_Query.Length + 1
            and then Close_Pos <= Clean_Query.Length);
         if Clean_Query.Data (I) = '(' then
            Depth := Depth + 1;
            if Depth = 1 then
               Found_Paren := True;
               Seg_Start   := I + 1;
            end if;
         elsif Clean_Query.Data (I) = ')' then
            if Depth = 1 then
               Closed_Paren := True;
               Close_Pos    := I;
               exit;
            elsif Depth > 1 then
               Depth := Depth - 1;
            end if;
         elsif Depth = 1 and then Clean_Query.Data (I) = ',' then
            if I <= Seg_Start
              or else not Is_Valid_Column_Def_Slice (Clean_Query, Seg_Start, I - 1)
            then
               return 0;
            end if;
            Commas    := Commas + 1;
            Seg_Start := I + 1;
         end if;
      end loop;

      if not Found_Paren
        or else not Closed_Paren
        or else Close_Pos <= Seg_Start
        or else not Is_Valid_Column_Def_Slice (Clean_Query, Seg_Start, Close_Pos - 1)
      then
         return 0;
      end if;

      --  Reject trailing non-whitespace/non-semicolon tokens after the closing ')'
      if Close_Pos < Clean_Query.Length then
         for J in Close_Pos + 1 .. Clean_Query.Length loop
            if not Is_WS_Char (Clean_Query.Data (J))
              and then Clean_Query.Data (J) /= ';'
            then
               return 0;
            end if;
         end loop;
      end if;

      return Commas + 1;
   end Count_Create_Table_Columns;

   function Has_Positional_Parameter (Clean_Query : Bounded_Text) return Boolean is
   begin
      if Clean_Query.Length < 2 then
         return False;
      end if;
      for I in 1 .. Clean_Query.Length - 1 loop
         pragma Loop_Invariant (I in 1 .. Clean_Query.Length - 1);
         if Clean_Query.Data (I) = '$'
           and then Clean_Query.Data (I + 1) in '1' .. '9'
           and then (I = 1 or else not Is_Ident_Char (Clean_Query.Data (I - 1)))
         then
            declare
               End_Dig : Positive := I + 1;
            begin
               while End_Dig < Clean_Query.Length
                 and then Clean_Query.Data (End_Dig + 1) in '0' .. '9'
               loop
                  pragma Loop_Invariant (End_Dig in I + 1 .. Clean_Query.Length - 1);
                  pragma Loop_Variant (Increases => End_Dig);
                  End_Dig := End_Dig + 1;
               end loop;
               if End_Dig = Clean_Query.Length
                 or else not Is_Ident_Char (Clean_Query.Data (End_Dig + 1))
               then
                  return True;
               end if;
            end;
         end if;
      end loop;
      return False;
   end Has_Positional_Parameter;

   --  Match standalone JSON/JSONB `->` or `->>` outside quotes without matching `<->` or `-->`
   function Has_JSONB_Arrow (Clean_Query : Bounded_Text) return Boolean is
   begin
      if Clean_Query.Length < 2 then
         return False;
      end if;
      for I in 1 .. Clean_Query.Length - 1 loop
         pragma Loop_Invariant (I in 1 .. Clean_Query.Length - 1);
         if Clean_Query.Data (I) = '-' and then Clean_Query.Data (I + 1) = '>' then
            if I = 1
              or else (Clean_Query.Data (I - 1) /= '<' and then Clean_Query.Data (I - 1) /= '-')
            then
               return True;
            end if;
         end if;
      end loop;
      return False;
   end Has_JSONB_Arrow;

   --  Match JSONB `?`, `?|`, or `?&` outside quotes/comments even without surrounding spaces
   function Has_JSONB_Question_Op (Clean_Query : Bounded_Text) return Boolean is
   begin
      for I in 1 .. Clean_Query.Length loop
         if Clean_Query.Data (I) = '?' then
            return True;
         end if;
      end loop;
      return False;
   end Has_JSONB_Question_Op;

   --  Reject empty semicolon statements or multi-statement tails after ';'
   function Has_Multi_Statement_Tail (Clean_Query : Bounded_Text) return Boolean is
      Seen_Token     : Boolean := False;
      Seen_Semicolon : Boolean := False;
   begin
      for I in 1 .. Clean_Query.Length loop
         if Clean_Query.Data (I) = ';' then
            if not Seen_Token or else Seen_Semicolon then
               return True;
            end if;
            Seen_Semicolon := True;
         elsif not Is_WS_Char (Clean_Query.Data (I)) then
            if Seen_Semicolon then
               return True;
            end if;
            Seen_Token := True;
         end if;
      end loop;
      return False;
   end Has_Multi_Statement_Tail;

   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
   is
      Clean       : Bounded_Text;
      Lex_Valid   : Boolean;
      Limit_Val   : Natural;
      Limit_Valid : Boolean;
   begin
      Result := (others => <>);
      if Query.Length = 0 then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      Sanitize_SQL (Query, Clean, Lex_Valid);
      if not Lex_Valid or else Has_Multi_Statement_Tail (Clean) then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      if Is_Create_Table_Stmt (Clean) then
         Result.Table_Or_Target := Extract_Create_Table_Name (Clean, Query);
         Result.Column_Count    := Count_Create_Table_Columns (Clean);
         if Result.Table_Or_Target.Length = 0 or else Result.Column_Count = 0 then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Create_Table;
      elsif Starts_With_Keyword (Clean, "INSERT") then
         declare
            Ins_End    : constant Natural := Find_Keyword_End (Clean, "INSERT");
            Into_Start : constant Natural := Find_Keyword_Start (Clean, "INTO");
            Into_End   : constant Natural := Find_Keyword_End (Clean, "INTO");
            Val_Start  : constant Natural := Find_Keyword_Start (Clean, "VALUES");
            Val_End    : constant Natural := Find_Keyword_End (Clean, "VALUES");
            Sel_Start  : constant Natural := Find_Keyword_Start (Clean, "SELECT");
            Sel_End    : constant Natural := Find_Keyword_End (Clean, "SELECT");
            Pos        : Natural;
            P_Depth    : Natural;
            Col_Token  : Boolean := False;
            Val_Token  : Boolean;
            Has_Body   : Boolean := False;
         begin
            if Ins_End = 0
              or else Into_Start <= Ins_End
              or else Into_End = 0
              or else Into_End >= Clean.Length
              or else Has_Non_WS_Range (Clean, Ins_End + 1, Into_Start - 1)
            then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;

            --  Skip whitespace and target identifier after INTO
            Pos := Into_End + 1;
            while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            while Pos <= Clean.Length
              and then (Is_Ident_Char (Query.Data (Pos)) or else Query.Data (Pos) = '.')
            loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            --  Optional parenthesized column list (<cols>) before VALUES / SELECT
            if Pos <= Clean.Length and then Clean.Data (Pos) = '(' then
               P_Depth := 1;
               Pos     := Pos + 1;
               while Pos <= Clean.Length and then P_Depth > 0 loop
                  pragma Loop_Invariant (Pos in 1 .. Clean.Length and then P_Depth <= Pos);
                  pragma Loop_Variant (Increases => Pos);
                  if Clean.Data (Pos) = '(' then
                     P_Depth := P_Depth + 1;
                  elsif Clean.Data (Pos) = ')' then
                     P_Depth := P_Depth - 1;
                  elsif not Is_WS_Char (Clean.Data (Pos))
                    and then Clean.Data (Pos) /= ','
                  then
                     Col_Token := True;
                  end if;
                  Pos := Pos + 1;
               end loop;

               if P_Depth /= 0 or else not Col_Token then
                  Result := (others => <>);
                  Status := Status_Invalid_Syntax;
                  return;
               end if;

               while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
                  pragma Loop_Invariant (Pos in 1 .. Clean.Length);
                  pragma Loop_Variant (Increases => Pos);
                  Pos := Pos + 1;
               end loop;
            end if;

            if Pos = Val_Start and then Val_End > 0 and then Val_End < Clean.Length then
               Pos := Val_End + 1;
               while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
                  pragma Loop_Invariant (Pos in 1 .. Clean.Length);
                  pragma Loop_Variant (Increases => Pos);
                  Pos := Pos + 1;
               end loop;

               if Pos <= Clean.Length and then Clean.Data (Pos) = '(' then
                  Has_Body := True;
                  for Tuple_Step in 1 .. Max_Text_Len loop
                     exit when Pos > Clean.Length or else Clean.Data (Pos) /= '(';
                     pragma Loop_Invariant (Pos in 1 .. Clean.Length);
                     P_Depth   := 1;
                     Val_Token := False;
                     Pos       := Pos + 1;
                     while Pos <= Clean.Length and then P_Depth > 0 loop
                        pragma Loop_Invariant (Pos in 1 .. Clean.Length and then P_Depth <= Pos);
                        pragma Loop_Variant (Increases => Pos);
                        if Clean.Data (Pos) = '(' then
                           P_Depth := P_Depth + 1;
                        elsif Clean.Data (Pos) = ')' then
                           P_Depth := P_Depth - 1;
                        elsif not Is_WS_Char (Clean.Data (Pos))
                          and then Clean.Data (Pos) /= ','
                        then
                           Val_Token := True;
                        end if;
                        Pos := Pos + 1;
                     end loop;

                     if P_Depth /= 0 or else not Val_Token then
                        Has_Body := False;
                        exit;
                     end if;

                     while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
                        pragma Loop_Invariant (Pos in 1 .. Clean.Length);
                        pragma Loop_Variant (Increases => Pos);
                        Pos := Pos + 1;
                     end loop;

                     if Pos <= Clean.Length and then Clean.Data (Pos) = ',' then
                        Pos := Pos + 1;
                        while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
                           pragma Loop_Invariant (Pos in 1 .. Clean.Length);
                           pragma Loop_Variant (Increases => Pos);
                           Pos := Pos + 1;
                        end loop;
                        if Pos > Clean.Length or else Clean.Data (Pos) /= '(' then
                           Has_Body := False;
                           exit;
                        end if;
                     else
                        exit;
                     end if;
                  end loop;

                  if Has_Body and then Pos <= Clean.Length and then Clean.Data (Pos) = '(' then
                     Has_Body := False;
                  end if;

                  if Has_Body then
                     while Pos <= Clean.Length
                       and then (Is_WS_Char (Clean.Data (Pos)) or else Clean.Data (Pos) = ';')
                     loop
                        pragma Loop_Invariant (Pos in 1 .. Clean.Length);
                        pragma Loop_Variant (Increases => Pos);
                        Pos := Pos + 1;
                     end loop;

                     if Pos <= Clean.Length then
                        declare
                           OC_Start  : constant Natural := Find_Keyword_Start (Clean, "ON CONFLICT");
                           OC_End    : constant Natural := Find_Keyword_End (Clean, "ON CONFLICT");
                           Ret_Start : constant Natural := Find_Keyword_Start (Clean, "RETURNING");
                           Ret_End   : constant Natural := Find_Keyword_End (Clean, "RETURNING");
                        begin
                           if OC_Start > 0
                             and then Pos = OC_Start
                             and then OC_End > 0
                             and then OC_End < Clean.Length
                             and then Has_Non_WS_Range (Clean, OC_End + 1, Clean.Length)
                           then
                              null;
                           elsif OC_Start = 0
                             and then Ret_Start > 0
                             and then Pos = Ret_Start
                             and then Ret_End > 0
                             and then Ret_End < Clean.Length
                             and then Has_Non_WS_Range (Clean, Ret_End + 1, Clean.Length)
                           then
                              null;
                           else
                              Has_Body := False;
                           end if;
                        end;
                     end if;
                  end if;
               end if;
            elsif Pos = Sel_Start and then Sel_End > 0 and then Sel_End < Clean.Length then
               Has_Body := Has_Non_WS_Range (Clean, Sel_End + 1, Clean.Length);
            end if;

            if not Has_Body then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
         end;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "INTO");
         if Result.Table_Or_Target.Length = 0 then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Insert;
      elsif Starts_With_Keyword (Clean, "SELECT") then
         Result.Column_Count := Count_Select_Columns (Clean);
         if Result.Column_Count = 0 then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         if Contains_Keyword_CI (Clean, "FROM") then
            Result.Table_Or_Target :=
              Extract_Ident_After_Keyword (Clean, Query, "FROM");
            if Result.Table_Or_Target.Length = 0 then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
         end if;
         Result.Kind := Stmt_Select;
      elsif Starts_With_Keyword (Clean, "UPDATE") then
         if not Contains_Keyword_CI (Clean, "SET") then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         declare
            Upd_End     : constant Natural := Find_Keyword_End (Clean, "UPDATE");
            Set_Start   : constant Natural := Find_Keyword_Start (Clean, "SET");
            Set_End     : constant Natural := Find_Keyword_End (Clean, "SET");
            Where_Start : constant Natural := Find_Keyword_Start (Clean, "WHERE");
            Ret_Start   : constant Natural := Find_Keyword_Start (Clean, "RETURNING");
            Body_End    : Natural;
            Pos         : Natural;
            Has_Lhs     : Boolean := False;
            Saw_Eq      : Boolean := False;
            Has_Rhs     : Boolean := False;
         begin
            if Upd_End = 0 or else Set_Start <= Upd_End or else Set_End = 0 then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;

            Pos := Upd_End + 1;
            while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            while Pos <= Clean.Length
              and then (Is_Ident_Char (Query.Data (Pos)) or else Query.Data (Pos) = '.')
            loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            if Pos /= Set_Start then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;

            Body_End :=
              (if Where_Start > Set_End then Where_Start - 1
               elsif Ret_Start > Set_End then Ret_Start - 1
               else Clean.Length);
            if Set_End < Body_End then
               for I in Set_End + 1 .. Body_End loop
                  if Clean.Data (I) = '=' then
                     if Has_Lhs then
                        Saw_Eq := True;
                     end if;
                  elsif not Is_WS_Char (Clean.Data (I))
                    and then Clean.Data (I) /= ';'
                  then
                     if not Saw_Eq then
                        Has_Lhs := True;
                     else
                        Has_Rhs := True;
                     end if;
                  end if;
               end loop;
            end if;

            if not (Has_Lhs and then Saw_Eq and then Has_Rhs) then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
         end;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "UPDATE");
         if Result.Table_Or_Target.Length = 0 then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Update;
      elsif Starts_With_Keyword (Clean, "DELETE") then
         declare
            Del_End     : constant Natural := Find_Keyword_End (Clean, "DELETE");
            From_Start  : constant Natural := Find_Keyword_Start (Clean, "FROM");
            From_End    : constant Natural := Find_Keyword_End (Clean, "FROM");
            Where_Start : constant Natural := Find_Keyword_Start (Clean, "WHERE");
            Ret_Start   : constant Natural := Find_Keyword_Start (Clean, "RETURNING");
            Pos         : Natural;
         begin
            if Del_End = 0
              or else From_Start <= Del_End
              or else From_End = 0
              or else From_End >= Clean.Length
              or else Has_Non_WS_Range (Clean, Del_End + 1, From_Start - 1)
            then
               Result := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;

            Pos := From_End + 1;
            while Pos <= Clean.Length and then Is_WS_Char (Clean.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            while Pos <= Clean.Length
              and then (Is_Ident_Char (Query.Data (Pos)) or else Query.Data (Pos) = '.')
            loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            while Pos <= Clean.Length
              and then (Is_WS_Char (Clean.Data (Pos)) or else Clean.Data (Pos) = ';')
            loop
               pragma Loop_Invariant (Pos in 1 .. Clean.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            if Where_Start > 0 then
               if Pos /= Where_Start then
                  Result := (others => <>);
                  Status := Status_Invalid_Syntax;
                  return;
               end if;
            elsif Ret_Start > 0 then
               if Pos /= Ret_Start then
                  Result := (others => <>);
                  Status := Status_Invalid_Syntax;
                  return;
               end if;
            else
               if Pos <= Clean.Length then
                  Result := (others => <>);
                  Status := Status_Invalid_Syntax;
                  return;
               end if;
            end if;
         end;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "FROM");
         if Result.Table_Or_Target.Length = 0 then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Delete;
      elsif Starts_With_Keyword (Clean, "BEGIN") then
         if not Is_Valid_Tx_Control_Stmt (Clean, "BEGIN") then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Begin;
      elsif Starts_With_Keyword (Clean, "COMMIT") then
         if not Is_Valid_Tx_Control_Stmt (Clean, "COMMIT") then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Commit;
      elsif Starts_With_Keyword (Clean, "ROLLBACK") then
         if not Is_Valid_Tx_Control_Stmt (Clean, "ROLLBACK") then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Rollback;
      elsif Starts_With_Keyword (Clean, "LISTEN") then
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "LISTEN");
         if Result.Table_Or_Target.Length = 0
           or else not Has_Only_Single_Ident_After_Keyword (Clean, "LISTEN")
         then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Listen;
      elsif Starts_With_Keyword (Clean, "NOTIFY") then
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "NOTIFY");
         if Result.Table_Or_Target.Length = 0
           or else not Is_Valid_Notify_Stmt (Clean)
         then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Notify;
      else
         Result := (others => <>);
         Status := Status_Invalid_Syntax;
         return;
      end if;

      if Is_Reserved_Clause_Ident (Result.Table_Or_Target)
        or else not Validate_Clause_Structure (Clean, Result.Kind)
      then
         Result := (others => <>);
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Populate structured clause metadata and PostgreSQL operator flags
      Result.Has_Where    := Contains_Keyword_CI (Clean, "WHERE");
      Result.Has_Order_By := Contains_Keyword_CI (Clean, "ORDER BY");
      Result.Has_Limit    := Contains_Keyword_CI (Clean, "LIMIT");
      if Result.Has_Limit then
         Parse_Limit_Clause (Clean, Limit_Val, Limit_Valid);
         if not Limit_Valid then
            Result := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Limit_Value := Limit_Val;
      else
         Result.Limit_Value := 0;
      end if;

      Result.Has_Positional_Param := Has_Positional_Parameter (Clean);
      Result.Has_Pg_Type_Cast     := Contains_Substring_CI (Clean, "::");
      Result.Has_Vector_Operator  :=
        Contains_Substring_CI (Clean, "<->")
        or else Contains_Substring_CI (Clean, "<=>")
        or else Contains_Substring_CI (Clean, "<#>");
      Result.Has_JSONB_Operator   :=
        Has_JSONB_Arrow (Clean)
        or else Contains_Substring_CI (Clean, "@>")
        or else Contains_Substring_CI (Clean, "<@")
        or else Has_JSONB_Question_Op (Clean);
      Result.Has_Upsert_Conflict  := Contains_Keyword_CI (Clean, "ON CONFLICT");
      Result.Has_Returning        := Contains_Keyword_CI (Clean, "RETURNING");

      Status := Status_Ok;
   end Analyze_SQL;

   --  Check whether Type_Keyword has the form `<Prefix>(<digits>[,<digits>])`
   function Has_Parameterized_Modifier
     (Type_Keyword : Bounded_Ident;
      Prefix       : String;
      Allow_Scale  : Boolean;
      Max_Val      : Positive) return Boolean
     with Pre => Prefix'Length > 0 and then Prefix'Length < Max_Ident_Len
   is
      P_Len     : constant Natural := Prefix'Length;
      Has_Digit : Boolean          := False;
      Saw_Comma : Boolean          := False;
      Arg1_Val  : Natural          := 0;
      Arg2_Val  : Natural          := 0;
      Digit     : Natural;
   begin
      if Type_Keyword.Length < P_Len + 3 then
         return False;
      end if;

      for I in 1 .. P_Len loop
         if To_Lower_Char (Type_Keyword.Data (I)) /=
            To_Lower_Char (Prefix (Prefix'First + (I - 1)))
         then
            return False;
         end if;
      end loop;

      if Type_Keyword.Data (P_Len + 1) /= '('
        or else Type_Keyword.Data (Type_Keyword.Length) /= ')'
      then
         return False;
      end if;

      for I in P_Len + 2 .. Type_Keyword.Length - 1 loop
         pragma Loop_Invariant (I in P_Len + 2 .. Type_Keyword.Length - 1);
         declare
            C : constant Character := Type_Keyword.Data (I);
         begin
            if C in '0' .. '9' then
               Has_Digit := True;
               Digit     := Character'Pos (C) - Character'Pos ('0');
               if not Saw_Comma then
                  if Arg1_Val <= (Natural'Last - Digit) / 10 then
                     Arg1_Val := Arg1_Val * 10 + Digit;
                  else
                     return False;
                  end if;
               else
                  if Arg2_Val <= (Natural'Last - Digit) / 10 then
                     Arg2_Val := Arg2_Val * 10 + Digit;
                  else
                     return False;
                  end if;
               end if;
            elsif C = ',' and then Allow_Scale and then Has_Digit and then not Saw_Comma then
               Saw_Comma := True;
               Has_Digit := False;
            else
               return False;
            end if;
         end;
      end loop;

      return
        Has_Digit
        and then Arg1_Val >= 1
        and then Arg1_Val <= Max_Val
        and then (not Saw_Comma or else Arg2_Val <= Arg1_Val);
   end Has_Parameterized_Modifier;

   procedure Resolve_Pg_Type
     (Type_Keyword : in     Bounded_Ident;
      Resolved     :    out Pg_Data_Type;
      Valid        :    out Boolean)
   is
   begin
      Resolved := Pg_Text;
      if Type_Keyword.Length = 0 then
         Valid := False;
         return;
      end if;
      Valid := True;

      if Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("SMALLINT"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("INT2"))
      then
         Resolved := Pg_Smallint;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("INTEGER"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("INT4"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("INT"))
      then
         Resolved := Pg_Integer;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BIGINT"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("INT8"))
      then
         Resolved := Pg_Bigint;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("REAL"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("FLOAT4"))
      then
         Resolved := Pg_Real;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("DOUBLE PRECISION"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("FLOAT8"))
      then
         Resolved := Pg_Double_Precision;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("NUMERIC"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("DECIMAL"))
        or else Has_Parameterized_Modifier (Type_Keyword, "NUMERIC", True, 38)
        or else Has_Parameterized_Modifier (Type_Keyword, "DECIMAL", True, 38)
      then
         Resolved := Pg_Numeric;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BOOLEAN"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BOOL"))
      then
         Resolved := Pg_Boolean;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("TEXT"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("VARCHAR"))
        or else Has_Parameterized_Modifier (Type_Keyword, "VARCHAR", False, 1_048_576)
      then
         Resolved := Pg_Text;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BYTEA")) then
         Resolved := Pg_Bytea;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("UUID")) then
         Resolved := Pg_UUID;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("TIMESTAMPTZ"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("TIMESTAMP"))
      then
         Resolved := Pg_Timestamptz;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("JSON")) then
         Resolved := Pg_JSON;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("JSONB")) then
         Resolved := Pg_JSONB;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("VECTOR"))
        or else Has_Parameterized_Modifier (Type_Keyword, "VECTOR", False, 4096)
      then
         Resolved := Pg_Vector;
      else
         Valid := False;
      end if;
   end Resolve_Pg_Type;

end Nhe_O.SQL;
