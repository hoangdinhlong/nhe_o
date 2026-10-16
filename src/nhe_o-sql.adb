pragma SPARK_Mode (On);

package body Nhe_O.SQL is

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

   function Starts_With_Keyword
     (Query   : Bounded_Text;
      Keyword : String) return Boolean
     with Pre => Keyword'Length > 0 and then Keyword'Length <= Max_Ident_Len
   is
      First_Pos : Natural := 0;
      K_Len     : constant Natural := Keyword'Length;
   begin
      for I in 1 .. Query.Length loop
         pragma Loop_Invariant (First_Pos = 0);
         if Query.Data (I) /= ' ' and then Query.Data (I) /= ASCII.HT
           and then Query.Data (I) /= ASCII.LF and then Query.Data (I) /= ASCII.CR
         then
            First_Pos := I;
            exit;
         end if;
      end loop;

      if First_Pos = 0 or else First_Pos + K_Len - 1 > Query.Length then
         return False;
      end if;

      for J in 0 .. K_Len - 1 loop
         if To_Lower_Char (Query.Data (First_Pos + J)) /=
            To_Lower_Char (Keyword (Keyword'First + J))
         then
            return False;
         end if;
      end loop;

      if First_Pos + K_Len <= Query.Length then
         declare
            Next_C : constant Character := Query.Data (First_Pos + K_Len);
         begin
            return Next_C = ' ' or else Next_C = ';' or else Next_C = ASCII.HT
              or else Next_C = ASCII.LF or else Next_C = ASCII.CR;
         end;
      end if;
      return True;
   end Starts_With_Keyword;

   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
   is
   begin
      Result := (others => <>);
      if Query.Length = 0 then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      if Starts_With_Keyword (Query, "CREATE") and then Contains_Substring_CI (Query, "TABLE") then
         Result.Kind := Stmt_Create_Table;
      elsif Starts_With_Keyword (Query, "INSERT") then
         Result.Kind := Stmt_Insert;
      elsif Starts_With_Keyword (Query, "SELECT") then
         Result.Kind := Stmt_Select;
      elsif Starts_With_Keyword (Query, "UPDATE") then
         Result.Kind := Stmt_Update;
      elsif Starts_With_Keyword (Query, "DELETE") then
         Result.Kind := Stmt_Delete;
      elsif Starts_With_Keyword (Query, "BEGIN") then
         Result.Kind := Stmt_Begin;
      elsif Starts_With_Keyword (Query, "COMMIT") then
         Result.Kind := Stmt_Commit;
      elsif Starts_With_Keyword (Query, "ROLLBACK") then
         Result.Kind := Stmt_Rollback;
      elsif Starts_With_Keyword (Query, "LISTEN") then
         Result.Kind := Stmt_Listen;
      elsif Starts_With_Keyword (Query, "NOTIFY") then
         Result.Kind := Stmt_Notify;
      else
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Detect PostgreSQL-specific operators and features
      Result.Has_Positional_Param :=
        Contains_Substring_CI (Query, "$1") or else Contains_Substring_CI (Query, "$2");
      Result.Has_Pg_Type_Cast := Contains_Substring_CI (Query, "::");
      Result.Has_Vector_Operator :=
        Contains_Substring_CI (Query, "<->")
        or else Contains_Substring_CI (Query, "<=>")
        or else Contains_Substring_CI (Query, "<#>");
      Result.Has_JSONB_Operator :=
        Contains_Substring_CI (Query, "->>")
        or else Contains_Substring_CI (Query, "->")
        or else Contains_Substring_CI (Query, "@>");
      Result.Has_Upsert_Conflict := Contains_Substring_CI (Query, "ON CONFLICT");
      Result.Has_Returning       := Contains_Substring_CI (Query, "RETURNING");

      Status := Status_Ok;
   end Analyze_SQL;

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
      then
         Resolved := Pg_Numeric;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BOOLEAN"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("BOOL"))
      then
         Resolved := Pg_Boolean;
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("TEXT"))
        or else Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("VARCHAR"))
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
      elsif Equal_Ident_Case_Insensitive (Type_Keyword, Make_Ident ("VECTOR")) then
         Resolved := Pg_Vector;
      else
         Valid := False;
      end if;
   end Resolve_Pg_Type;

end Nhe_O.SQL;
