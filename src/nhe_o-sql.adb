pragma SPARK_Mode (On);

package body Nhe_O.SQL is

   function Is_Ident_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$');

   function Is_WS_Char (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF or else C = ASCII.CR);

   -------------------------------------------------------------------------
   --  Sanitize_SQL: Strip quoted literals, line comments (--), and block
   --  comments (/* ... */), while rejecting unclosed quotes/comments and
   --  unbalanced parentheses (HIGH-03).
   -------------------------------------------------------------------------

   procedure Sanitize_SQL
     (Query : in     Bounded_Text;
      Clean :    out Bounded_Text;
      Valid :    out Boolean)
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
               Clean.Data (I) := '_';
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

   function Find_Keyword_End
     (Clean_Query : Bounded_Text;
      Keyword     : String) return Natural
     with Pre  => Keyword'Length > 0 and then Keyword'Length <= Max_Text_Len,
          Post => Find_Keyword_End'Result <= Clean_Query.Length
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
               return Start + K_Len - 1;
            end if;
         end if;
      end loop;
      return 0;
   end Find_Keyword_End;

   --  Extract the next SQL identifier token following Keyword (e.g. FROM <table>)
   function Extract_Ident_After_Keyword
     (Clean_Query : Bounded_Text;
      Orig_Query  : Bounded_Text;
      Keyword     : String) return Bounded_Ident
     with Pre => Keyword'Length > 0
                 and then Keyword'Length <= Max_Text_Len
                 and then Clean_Query.Length = Orig_Query.Length
   is
      Kw_End : constant Natural := Find_Keyword_End (Clean_Query, Keyword);
      Pos    : Natural := Kw_End;
      Res    : Bounded_Ident := (Length => 0, Data => [others => ' ']);
   begin
      if Pos = 0 or else Pos >= Clean_Query.Length then
         return Res;
      end if;

      Pos := Pos + 1;
      while Pos <= Clean_Query.Length and then Is_WS_Char (Clean_Query.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      while Pos <= Clean_Query.Length
        and then (Is_Ident_Char (Orig_Query.Data (Pos)) or else Orig_Query.Data (Pos) = '.')
      loop
         pragma Loop_Invariant (Pos in 1 .. Clean_Query.Length);
         pragma Loop_Invariant (Res.Length <= Max_Ident_Len);
         pragma Loop_Variant (Increases => Pos);
         if Res.Length < Max_Ident_Len then
            Res.Length := Res.Length + 1;
            Res.Data (Res.Length) := Orig_Query.Data (Pos);
         end if;
         Pos := Pos + 1;
      end loop;

      return Res;
   end Extract_Ident_After_Keyword;

   function Extract_Limit_Value (Clean_Query : Bounded_Text) return Natural is
      Kw_End : constant Natural := Find_Keyword_End (Clean_Query, "LIMIT");
      Pos    : Natural := Kw_End;
      Acc    : Natural := 0;
      Digit  : Natural;
   begin
      if Pos = 0 or else Pos >= Clean_Query.Length then
         return 0;
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
         Digit := Character'Pos (Clean_Query.Data (Pos)) - Character'Pos ('0');
         if Acc <= (Natural'Last - Digit) / 10 then
            Acc := Acc * 10 + Digit;
         end if;
         Pos := Pos + 1;
      end loop;

      return Acc;
   end Extract_Limit_Value;

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
            return Is_WS_Char (Next_C) or else Next_C = ';';
         end;
      end if;
      return True;
   end Starts_With_Keyword;

   --  Verify `CREATE [TEMP|TEMPORARY|UNLOGGED] TABLE [IF NOT EXISTS] <name> (...)`
   --  without falsely rejecting column names containing `view`, `index`, `schema` (HIGH-03).
   function Is_Create_Table_Stmt (Clean_Query : Bounded_Text) return Boolean is
      Create_End : constant Natural := Find_Keyword_End (Clean_Query, "CREATE");
      Table_End  : constant Natural := Find_Keyword_End (Clean_Query, "TABLE");
      Paren_Pos  : Natural := 0;
   begin
      if not Starts_With_Keyword (Clean_Query, "CREATE") then
         return False;
      end if;
      if Create_End = 0 or else Table_End <= Create_End then
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

      --  Ensure no non-table DDL keyword appears before TABLE
      declare
         Prefix : Bounded_Text := Clean_Query;
      begin
         Prefix.Length := Table_End;
         if Contains_Keyword_CI (Prefix, "INDEX")
           or else Contains_Keyword_CI (Prefix, "VIEW")
           or else Contains_Keyword_CI (Prefix, "SCHEMA")
           or else Contains_Keyword_CI (Prefix, "SEQUENCE")
         then
            return False;
         end if;
      end;

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

   function Count_Select_Columns (Clean_Query : Bounded_Text) return Natural is
      Sel_End   : constant Natural := Find_Keyword_End (Clean_Query, "SELECT");
      From_End  : constant Natural := Find_Keyword_End (Clean_Query, "FROM");
      Stop_Pos  : Natural;
      Depth     : Natural := 0;
      Commas    : Natural := 0;
      Has_Token : Boolean := False;
   begin
      if Sel_End = 0 or else Sel_End >= Clean_Query.Length then
         return 0;
      end if;

      if From_End >= 5 and then From_End - 4 > Sel_End then
         Stop_Pos := From_End - 4;
      else
         Stop_Pos := Clean_Query.Length;
      end if;

      for I in Sel_End + 1 .. Stop_Pos loop
         pragma Loop_Invariant (Depth <= I);
         pragma Loop_Invariant (Commas <= I);
         if Clean_Query.Data (I) = '(' then
            Depth := Depth + 1;
         elsif Clean_Query.Data (I) = ')' and then Depth > 0 then
            Depth := Depth - 1;
         elsif not Is_WS_Char (Clean_Query.Data (I))
           and then Clean_Query.Data (I) /= ';'
         then
            Has_Token := True;
            if Clean_Query.Data (I) = ',' and then Depth = 0 then
               Commas := Commas + 1;
            end if;
         end if;
      end loop;

      if not Has_Token then
         return 0;
      else
         return Commas + 1;
      end if;
   end Count_Select_Columns;

   function Count_Create_Table_Columns (Clean_Query : Bounded_Text) return Natural is
      Depth     : Natural := 0;
      Commas    : Natural := 0;
      Has_Token : Boolean := False;
   begin
      for I in 1 .. Clean_Query.Length loop
         pragma Loop_Invariant (Depth <= I and then Commas <= I);
         if Clean_Query.Data (I) = '(' then
            Depth := Depth + 1;
         elsif Clean_Query.Data (I) = ')' then
            if Depth = 1 then
               exit;
            elsif Depth > 1 then
               Depth := Depth - 1;
            end if;
         elsif Depth = 1 and then not Is_WS_Char (Clean_Query.Data (I)) then
            Has_Token := True;
            if Clean_Query.Data (I) = ',' then
               Commas := Commas + 1;
            end if;
         end if;
      end loop;

      if not Has_Token then
         return 0;
      else
         return Commas + 1;
      end if;
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
            return True;
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

   --  Match JSONB `?`, `?|`, or `?&` outside quotes/comments even without surrounding spaces (HIGH-03)
   function Has_JSONB_Question_Op (Clean_Query : Bounded_Text) return Boolean is
   begin
      for I in 1 .. Clean_Query.Length loop
         if Clean_Query.Data (I) = '?' then
            return True;
         end if;
      end loop;
      return False;
   end Has_JSONB_Question_Op;

   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
   is
      Clean     : Bounded_Text;
      Lex_Valid : Boolean;
   begin
      Result := (others => <>);
      if Query.Length = 0 then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      Sanitize_SQL (Query, Clean, Lex_Valid);
      if not Lex_Valid then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      if Is_Create_Table_Stmt (Clean) then
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "TABLE");
         Result.Column_Count := Count_Create_Table_Columns (Clean);
         if Result.Table_Or_Target.Length = 0 or else Result.Column_Count = 0 then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Create_Table;
      elsif Starts_With_Keyword (Clean, "INSERT") then
         if not Contains_Keyword_CI (Clean, "INTO")
           or else (not Contains_Keyword_CI (Clean, "VALUES")
                    and then not Contains_Keyword_CI (Clean, "SELECT"))
         then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "INTO");
         if Result.Table_Or_Target.Length = 0 then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Insert;
      elsif Starts_With_Keyword (Clean, "SELECT") then
         Result.Column_Count := Count_Select_Columns (Clean);
         if Result.Column_Count = 0 then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         if Contains_Keyword_CI (Clean, "FROM") then
            Result.Table_Or_Target :=
              Extract_Ident_After_Keyword (Clean, Query, "FROM");
            if Result.Table_Or_Target.Length = 0 then
               Status := Status_Invalid_Syntax;
               return;
            end if;
         end if;
         Result.Kind := Stmt_Select;
      elsif Starts_With_Keyword (Clean, "UPDATE") then
         if not Contains_Keyword_CI (Clean, "SET") then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "UPDATE");
         if Result.Table_Or_Target.Length = 0 then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Update;
      elsif Starts_With_Keyword (Clean, "DELETE") then
         if not Contains_Keyword_CI (Clean, "FROM") then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "FROM");
         if Result.Table_Or_Target.Length = 0 then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Kind := Stmt_Delete;
      elsif Starts_With_Keyword (Clean, "BEGIN") then
         Result.Kind := Stmt_Begin;
      elsif Starts_With_Keyword (Clean, "COMMIT") then
         Result.Kind := Stmt_Commit;
      elsif Starts_With_Keyword (Clean, "ROLLBACK") then
         Result.Kind := Stmt_Rollback;
      elsif Starts_With_Keyword (Clean, "LISTEN") then
         if not Has_Token_After_Keyword (Clean, "LISTEN") then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "LISTEN");
         Result.Kind := Stmt_Listen;
      elsif Starts_With_Keyword (Clean, "NOTIFY") then
         if not Has_Token_After_Keyword (Clean, "NOTIFY") then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Result.Table_Or_Target :=
           Extract_Ident_After_Keyword (Clean, Query, "NOTIFY");
         Result.Kind := Stmt_Notify;
      else
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Populate structured clause metadata and PostgreSQL operator flags
      Result.Has_Where            := Contains_Keyword_CI (Clean, "WHERE");
      Result.Has_Order_By         := Contains_Keyword_CI (Clean, "ORDER BY");
      Result.Has_Limit            := Contains_Keyword_CI (Clean, "LIMIT");
      Result.Limit_Value          :=
        (if Result.Has_Limit then Extract_Limit_Value (Clean) else 0);
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
               if not Saw_Comma then
                  Digit := Character'Pos (C) - Character'Pos ('0');
                  if Arg1_Val <= (Natural'Last - Digit) / 10 then
                     Arg1_Val := Arg1_Val * 10 + Digit;
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

      return Has_Digit and then Arg1_Val >= 1 and then Arg1_Val <= Max_Val;
   end Has_Parameterized_Modifier;

   procedure Resolve_Pg_Type
     (Type_Keyword : in     Bounded_Ident;
      Resolved     :    out Pg_Data_Type;
      Valid        :    out Boolean)
   is
   begin
      Resolved := Pg_Text;
      Valid    := True;

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
        or else Has_Parameterized_Modifier (Type_Keyword, "NUMERIC", True, 1000)
        or else Has_Parameterized_Modifier (Type_Keyword, "DECIMAL", True, 1000)
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
