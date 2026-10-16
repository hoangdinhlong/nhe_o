pragma SPARK_Mode (On);

package body Nhe_O.SQL is

   function Is_Ident_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$');

   function Is_WS_Char (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF or else C = ASCII.CR);

   --  Return a copy of Query with single-quoted ('...') and double-quoted ("...")
   --  spans blanked to spaces so keyword and operator scanners never match inside
   --  SQL string literals or quoted identifiers.
   function Strip_Quoted_Spans (Query : Bounded_Text) return Bounded_Text is
      Clean     : Bounded_Text := Query;
      In_Single : Boolean      := False;
      In_Double : Boolean      := False;
   begin
      for I in 1 .. Query.Length loop
         pragma Loop_Invariant
           (I in 1 .. Query.Length and then Clean.Length = Query.Length);
         declare
            C : constant Character := Query.Data (I);
         begin
            if In_Single then
               Clean.Data (I) := ' ';
               if C = ''' then
                  In_Single := False;
               end if;
            elsif In_Double then
               Clean.Data (I) := ' ';
               if C = '"' then
                  In_Double := False;
               end if;
            else
               if C = ''' then
                  In_Single      := True;
                  Clean.Data (I) := ' ';
               elsif C = '"' then
                  In_Double      := True;
                  Clean.Data (I) := ' ';
               end if;
            end if;
         end;
      end loop;
      return Clean;
   end Strip_Quoted_Spans;

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
   --  with identifier boundary checks on both sides (so `returning_user` or
   --  `my_table` never falsely match `RETURNING` or `TABLE`).
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

   function Is_Create_Table_Stmt (Clean_Query : Bounded_Text) return Boolean is
   begin
      if not Starts_With_Keyword (Clean_Query, "CREATE") then
         return False;
      end if;
      --  Reject `CREATE INDEX`, `CREATE VIEW`, etc. even if table name is `my_table`
      if Contains_Keyword_CI (Clean_Query, "INDEX")
        or else Contains_Keyword_CI (Clean_Query, "VIEW")
        or else Contains_Keyword_CI (Clean_Query, "SCHEMA")
        or else Contains_Keyword_CI (Clean_Query, "SEQUENCE")
      then
         return False;
      end if;
      return Contains_Keyword_CI (Clean_Query, "TABLE");
   end Is_Create_Table_Stmt;

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

   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
   is
      Clean : Bounded_Text;
   begin
      Result := (others => <>);
      if Query.Length = 0 then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      Clean := Strip_Quoted_Spans (Query);

      if Is_Create_Table_Stmt (Clean) then
         Result.Kind := Stmt_Create_Table;
      elsif Starts_With_Keyword (Clean, "INSERT") then
         Result.Kind := Stmt_Insert;
      elsif Starts_With_Keyword (Clean, "SELECT") then
         Result.Kind := Stmt_Select;
      elsif Starts_With_Keyword (Clean, "UPDATE") then
         Result.Kind := Stmt_Update;
      elsif Starts_With_Keyword (Clean, "DELETE") then
         Result.Kind := Stmt_Delete;
      elsif Starts_With_Keyword (Clean, "BEGIN") then
         Result.Kind := Stmt_Begin;
      elsif Starts_With_Keyword (Clean, "COMMIT") then
         Result.Kind := Stmt_Commit;
      elsif Starts_With_Keyword (Clean, "ROLLBACK") then
         Result.Kind := Stmt_Rollback;
      elsif Starts_With_Keyword (Clean, "LISTEN") then
         Result.Kind := Stmt_Listen;
      elsif Starts_With_Keyword (Clean, "NOTIFY") then
         Result.Kind := Stmt_Notify;
      else
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Detect PostgreSQL-specific operators and clauses outside string literals
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
        or else Contains_Substring_CI (Clean, " ? ")
        or else Contains_Substring_CI (Clean, "?|")
        or else Contains_Substring_CI (Clean, "?&");
      Result.Has_Upsert_Conflict  := Contains_Keyword_CI (Clean, "ON CONFLICT");
      Result.Has_Returning        := Contains_Keyword_CI (Clean, "RETURNING");

      Status := Status_Ok;
   end Analyze_SQL;

   --  Check whether Type_Keyword has the form `<Prefix>(<digits>[,<digits>])`
   function Has_Parameterized_Modifier
     (Type_Keyword : Bounded_Ident;
      Prefix       : String) return Boolean
     with Pre => Prefix'Length > 0 and then Prefix'Length < Max_Ident_Len
   is
      P_Len     : constant Natural := Prefix'Length;
      Has_Digit : Boolean          := False;
      Saw_Comma : Boolean          := False;
   begin
      if Type_Keyword.Length < P_Len + 3 then
         return False;
      end if;

      for I in 1 .. P_Len loop
         if To_Lower_Char (Type_Keyword.Data (I)) /=
            To_Lower_Char (Prefix (Prefix'First + I - 1))
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
            elsif C = ',' and then Has_Digit and then not Saw_Comma then
               Saw_Comma := True;
               Has_Digit := False;
            else
               return False;
            end if;
         end;
      end loop;

      return Has_Digit;
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
        or else Has_Parameterized_Modifier (Type_Keyword, "NUMERIC")
        or else Has_Parameterized_Modifier (Type_Keyword, "DECIMAL")
      then
         Resolved := Pg_Numeric;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BOOLEAN"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BOOL"))
      then
         Resolved := Pg_Boolean;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("TEXT"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("VARCHAR"))
        or else Has_Parameterized_Modifier (Type_Keyword, "VARCHAR")
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
        or else Has_Parameterized_Modifier (Type_Keyword, "VECTOR")
      then
         Resolved := Pg_Vector;
      else
         Valid := False;
      end if;
   end Resolve_Pg_Type;

end Nhe_O.SQL;
