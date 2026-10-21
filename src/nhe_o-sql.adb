pragma SPARK_Mode (On);

--  Nhe_O.SQL body: a PostgreSQL-faithful lexer (Tokenize) feeding a token-level
--  validator.  Every helper works on token indices of one Token_List, checks its
--  own index bounds defensively, and returns 0 / False / OK = False on anything
--  outside the documented dialect (see the package specification), so the
--  analyzer fails closed.
package body Nhe_O.SQL is

   Empty_Ident : constant Bounded_Ident := (Length => 0, Data => [others => ' ']);

   -------------------------------------------------------------------------
   --  Character classes (PostgreSQL src/backend/parser/scan.l)
   -------------------------------------------------------------------------

   --  space: [ \t\n\r\f] (PostgreSQL 16; a vertical tab is whitespace only from
   --  PostgreSQL 17 on, so it is rejected here)
   function Is_WS_Char (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.FF or else C = ASCII.CR);

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   --  ident_start: [A-Za-z\200-\377_]
   function Is_Ident_Start_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '_' or else Character'Pos (C) >= 128);

   --  ident_cont: [A-Za-z\200-\377_0-9\$]
   function Is_Ident_Char (C : Character) return Boolean is
     (Is_Ident_Start_Char (C) or else Is_Digit (C) or else C = '$');

   --  op_chars: [\~\!\@\#\^\&\|\`\?\+\-\*\/\%\<\>\=]
   function Is_Op_Char (C : Character) return Boolean is
     (C in '~' | '!' | '@' | '#' | '^' | '&' | '|' | '`' | '?'
         | '+' | '-' | '*' | '/' | '%' | '<' | '>' | '=');

   --  "--" or "/*" starts a comment at I
   function Starts_Comment (Q : Bounded_Text; I : Positive) return Boolean is
     (I < Q.Length
      and then ((Q.Data (I) = '-' and then Q.Data (I + 1) = '-')
                or else (Q.Data (I) = '/' and then Q.Data (I + 1) = '*')));

   --  Case-insensitive comparison of Q.Data (First .. Last) with S
   function Equal_CI
     (Q     : Bounded_Text;
      First : Positive;
      Last  : Positive;
      S     : String) return Boolean
     with Global => null,
          Pre    => First <= Last and then Last <= Q.Length,
          Post   => (if Equal_CI'Result then S'Length = Last - First + 1)
   is
   begin
      if S'Length /= Last - First + 1 then
         return False;
      end if;
      for K in 0 .. S'Length - 1 loop
         if To_Lower_Char (Q.Data (First + K)) /= To_Lower_Char (S (S'First + K)) then
            return False;
         end if;
      end loop;
      return True;
   end Equal_CI;

   -------------------------------------------------------------------------
   --  Key words
   -------------------------------------------------------------------------

   type Keyword_Id is
     (Kw_None,
      --  PostgreSQL reserved key words plus the classifier's historical reserved
      --  names (BY, DELETE, DROP, INSERT, SET, UPDATE, VALUES): never valid as
      --  unquoted table, column, alias, or channel names
      Kw_All, Kw_Analyse, Kw_Analyze, Kw_And, Kw_Any, Kw_Array, Kw_As, Kw_Asc,
      Kw_Asymmetric, Kw_Authorization, Kw_Binary, Kw_Both, Kw_By, Kw_Case, Kw_Cast,
      Kw_Check, Kw_Collate, Kw_Collation, Kw_Column, Kw_Concurrently, Kw_Constraint,
      Kw_Create, Kw_Cross, Kw_Current_Catalog, Kw_Current_Date, Kw_Current_Role,
      Kw_Current_Schema, Kw_Current_Time, Kw_Current_Timestamp, Kw_Current_User,
      Kw_Default, Kw_Deferrable, Kw_Delete, Kw_Desc, Kw_Distinct, Kw_Do, Kw_Drop, Kw_Else,
      Kw_End, Kw_Except, Kw_False, Kw_Fetch, Kw_For, Kw_Foreign, Kw_Freeze, Kw_From,
      Kw_Full, Kw_Grant, Kw_Group, Kw_Having, Kw_Ilike, Kw_In, Kw_Initially, Kw_Inner,
      Kw_Insert, Kw_Intersect, Kw_Into, Kw_Is, Kw_Isnull, Kw_Join, Kw_Lateral, Kw_Leading,
      Kw_Left, Kw_Like, Kw_Limit, Kw_Localtime, Kw_Localtimestamp, Kw_Natural, Kw_Not,
      Kw_Notnull, Kw_Null, Kw_Offset, Kw_On, Kw_Only, Kw_Or, Kw_Order, Kw_Outer,
      Kw_Overlaps, Kw_Placing, Kw_Primary, Kw_References, Kw_Returning, Kw_Right,
      Kw_Select, Kw_Session_User, Kw_Set, Kw_Similar, Kw_Some, Kw_Symmetric,
      Kw_System_User, Kw_Table, Kw_Tablesample, Kw_Then, Kw_To, Kw_Trailing, Kw_True,
      Kw_Union, Kw_Unique, Kw_Update, Kw_User, Kw_Using, Kw_Values, Kw_Variadic,
      Kw_Verbose, Kw_When, Kw_Where, Kw_Window, Kw_With,
      --  Non-reserved key words recognised by the grammar (valid identifiers)
      Kw_Action, Kw_Always, Kw_Begin, Kw_Cascade, Kw_Commit, Kw_Conflict, Kw_Exists,
      Kw_First, Kw_Generated, Kw_Identity, Kw_If, Kw_Key, Kw_Listen, Kw_Locked,
      Kw_Materialized, Kw_Next, Kw_No, Kw_Nothing, Kw_Notify, Kw_Nowait, Kw_Of,
      Kw_Recursive, Kw_Restrict, Kw_Rollback, Kw_Row, Kw_Rows, Kw_Share, Kw_Skip,
      Kw_Stored, Kw_Temp, Kw_Temporary, Kw_Transaction, Kw_Unlogged, Kw_Within, Kw_Work);

   subtype Known_Keyword    is Keyword_Id range Kw_All .. Kw_Work;
   subtype Reserved_Keyword is Keyword_Id range Kw_All .. Kw_With;

   function Keyword_Text (K : Known_Keyword) return String is
     (case K is
         when Kw_All                 => "ALL",
         when Kw_Analyse             => "ANALYSE",
         when Kw_Analyze             => "ANALYZE",
         when Kw_And                 => "AND",
         when Kw_Any                 => "ANY",
         when Kw_Array               => "ARRAY",
         when Kw_As                  => "AS",
         when Kw_Asc                 => "ASC",
         when Kw_Asymmetric          => "ASYMMETRIC",
         when Kw_Authorization       => "AUTHORIZATION",
         when Kw_Binary              => "BINARY",
         when Kw_Both                => "BOTH",
         when Kw_By                  => "BY",
         when Kw_Case                => "CASE",
         when Kw_Cast                => "CAST",
         when Kw_Check               => "CHECK",
         when Kw_Collate             => "COLLATE",
         when Kw_Collation           => "COLLATION",
         when Kw_Column              => "COLUMN",
         when Kw_Concurrently        => "CONCURRENTLY",
         when Kw_Constraint          => "CONSTRAINT",
         when Kw_Create              => "CREATE",
         when Kw_Cross               => "CROSS",
         when Kw_Current_Catalog     => "CURRENT_CATALOG",
         when Kw_Current_Date        => "CURRENT_DATE",
         when Kw_Current_Role        => "CURRENT_ROLE",
         when Kw_Current_Schema      => "CURRENT_SCHEMA",
         when Kw_Current_Time        => "CURRENT_TIME",
         when Kw_Current_Timestamp   => "CURRENT_TIMESTAMP",
         when Kw_Current_User        => "CURRENT_USER",
         when Kw_Default             => "DEFAULT",
         when Kw_Deferrable          => "DEFERRABLE",
         when Kw_Delete              => "DELETE",
         when Kw_Desc                => "DESC",
         when Kw_Distinct            => "DISTINCT",
         when Kw_Do                  => "DO",
         when Kw_Drop                => "DROP",
         when Kw_Else                => "ELSE",
         when Kw_End                 => "END",
         when Kw_Except              => "EXCEPT",
         when Kw_False               => "FALSE",
         when Kw_Fetch               => "FETCH",
         when Kw_For                 => "FOR",
         when Kw_Foreign             => "FOREIGN",
         when Kw_Freeze              => "FREEZE",
         when Kw_From                => "FROM",
         when Kw_Full                => "FULL",
         when Kw_Grant               => "GRANT",
         when Kw_Group               => "GROUP",
         when Kw_Having              => "HAVING",
         when Kw_Ilike               => "ILIKE",
         when Kw_In                  => "IN",
         when Kw_Initially           => "INITIALLY",
         when Kw_Inner               => "INNER",
         when Kw_Insert              => "INSERT",
         when Kw_Intersect           => "INTERSECT",
         when Kw_Into                => "INTO",
         when Kw_Is                  => "IS",
         when Kw_Isnull              => "ISNULL",
         when Kw_Join                => "JOIN",
         when Kw_Lateral             => "LATERAL",
         when Kw_Leading             => "LEADING",
         when Kw_Left                => "LEFT",
         when Kw_Like                => "LIKE",
         when Kw_Limit               => "LIMIT",
         when Kw_Localtime           => "LOCALTIME",
         when Kw_Localtimestamp      => "LOCALTIMESTAMP",
         when Kw_Natural             => "NATURAL",
         when Kw_Not                 => "NOT",
         when Kw_Notnull             => "NOTNULL",
         when Kw_Null                => "NULL",
         when Kw_Offset              => "OFFSET",
         when Kw_On                  => "ON",
         when Kw_Only                => "ONLY",
         when Kw_Or                  => "OR",
         when Kw_Order               => "ORDER",
         when Kw_Outer               => "OUTER",
         when Kw_Overlaps            => "OVERLAPS",
         when Kw_Placing             => "PLACING",
         when Kw_Primary             => "PRIMARY",
         when Kw_References          => "REFERENCES",
         when Kw_Returning           => "RETURNING",
         when Kw_Right               => "RIGHT",
         when Kw_Select              => "SELECT",
         when Kw_Session_User        => "SESSION_USER",
         when Kw_Set                 => "SET",
         when Kw_Similar             => "SIMILAR",
         when Kw_Some                => "SOME",
         when Kw_Symmetric           => "SYMMETRIC",
         when Kw_System_User         => "SYSTEM_USER",
         when Kw_Table               => "TABLE",
         when Kw_Tablesample         => "TABLESAMPLE",
         when Kw_Then                => "THEN",
         when Kw_To                  => "TO",
         when Kw_Trailing            => "TRAILING",
         when Kw_True                => "TRUE",
         when Kw_Union               => "UNION",
         when Kw_Unique              => "UNIQUE",
         when Kw_Update              => "UPDATE",
         when Kw_User                => "USER",
         when Kw_Using               => "USING",
         when Kw_Values              => "VALUES",
         when Kw_Variadic            => "VARIADIC",
         when Kw_Verbose             => "VERBOSE",
         when Kw_When                => "WHEN",
         when Kw_Where               => "WHERE",
         when Kw_Window              => "WINDOW",
         when Kw_With                => "WITH",
         when Kw_Action              => "ACTION",
         when Kw_Always              => "ALWAYS",
         when Kw_Begin               => "BEGIN",
         when Kw_Cascade             => "CASCADE",
         when Kw_Commit              => "COMMIT",
         when Kw_Conflict            => "CONFLICT",
         when Kw_Exists              => "EXISTS",
         when Kw_First               => "FIRST",
         when Kw_Generated           => "GENERATED",
         when Kw_Identity            => "IDENTITY",
         when Kw_If                  => "IF",
         when Kw_Key                 => "KEY",
         when Kw_Listen              => "LISTEN",
         when Kw_Locked              => "LOCKED",
         when Kw_Materialized        => "MATERIALIZED",
         when Kw_Next                => "NEXT",
         when Kw_No                  => "NO",
         when Kw_Nothing             => "NOTHING",
         when Kw_Notify              => "NOTIFY",
         when Kw_Nowait              => "NOWAIT",
         when Kw_Of                  => "OF",
         when Kw_Recursive           => "RECURSIVE",
         when Kw_Restrict            => "RESTRICT",
         when Kw_Rollback            => "ROLLBACK",
         when Kw_Row                 => "ROW",
         when Kw_Rows                => "ROWS",
         when Kw_Share               => "SHARE",
         when Kw_Skip                => "SKIP",
         when Kw_Stored              => "STORED",
         when Kw_Temp                => "TEMP",
         when Kw_Temporary           => "TEMPORARY",
         when Kw_Transaction         => "TRANSACTION",
         when Kw_Unlogged            => "UNLOGGED",
         when Kw_Within              => "WITHIN",
         when Kw_Work                => "WORK");

   --  Key word spelled by Q.Data (First .. Last), Kw_None for other identifiers
   function Lookup_Keyword
     (Q     : Bounded_Text;
      First : Positive;
      Last  : Positive) return Keyword_Id
     with Global => null,
          Pre    => First <= Last and then Last <= Q.Length,
          Post   => (if Lookup_Keyword'Result /= Kw_None then Last - First < 20)
   is
   begin
      if Last - First >= 20 then
         return Kw_None;
      end if;
      for K in Known_Keyword loop
         if Equal_CI (Q, First, Last, Keyword_Text (K)) then
            return K;
         end if;
      end loop;
      return Kw_None;
   end Lookup_Keyword;

   -------------------------------------------------------------------------
   --  Operators
   -------------------------------------------------------------------------

   type Op_Kind is
     (Op_Other, Op_Equal,
      Op_L2_Distance, Op_Cosine_Distance, Op_Inner_Product,   --  <->  <=>  <#>
      Op_Arrow, Op_Arrow_Text, Op_Path, Op_Path_Text,         --  ->   ->>  #>   #>>
      Op_Contains, Op_Contained, Op_Key_Exists,               --  @>   <@   ?
      Op_Any_Key_Exists, Op_All_Keys_Exist, Op_Path_Exists,   --  ?|   ?&   @?
      Op_Delete_Path);                                        --  #-

   subtype Vector_Op is Op_Kind range Op_L2_Distance .. Op_Inner_Product;
   subtype JSONB_Op  is Op_Kind range Op_Arrow .. Op_Delete_Path;

   function Classify_Op (Q : Bounded_Text; First, Last : Positive) return Op_Kind is
     (if    Equal_CI (Q, First, Last, "=")   then Op_Equal
      elsif Equal_CI (Q, First, Last, "<->") then Op_L2_Distance
      elsif Equal_CI (Q, First, Last, "<=>") then Op_Cosine_Distance
      elsif Equal_CI (Q, First, Last, "<#>") then Op_Inner_Product
      elsif Equal_CI (Q, First, Last, "->")  then Op_Arrow
      elsif Equal_CI (Q, First, Last, "->>") then Op_Arrow_Text
      elsif Equal_CI (Q, First, Last, "#>")  then Op_Path
      elsif Equal_CI (Q, First, Last, "#>>") then Op_Path_Text
      elsif Equal_CI (Q, First, Last, "@>")  then Op_Contains
      elsif Equal_CI (Q, First, Last, "<@")  then Op_Contained
      elsif Equal_CI (Q, First, Last, "?")   then Op_Key_Exists
      elsif Equal_CI (Q, First, Last, "?|")  then Op_Any_Key_Exists
      elsif Equal_CI (Q, First, Last, "?&")  then Op_All_Keys_Exist
      elsif Equal_CI (Q, First, Last, "@?")  then Op_Path_Exists
      elsif Equal_CI (Q, First, Last, "#-")  then Op_Delete_Path
      else  Op_Other)
     with Pre => First <= Last and then Last <= Q.Length;

   -------------------------------------------------------------------------
   --  Tokens
   -------------------------------------------------------------------------

   type Tok_Kind is
     (Tk_Word,           --  unquoted identifier or key word
      Tk_Quoted,         --  "..." delimited identifier
      Tk_Number,         --  numeric literal
      Tk_String,         --  '...' or N'...'
      Tk_E_String,       --  E'...' (backslash escapes)
      Tk_Dollar_String,  --  $tag$ ... $tag$
      Tk_Bit_String,     --  B'...' or X'...'
      Tk_Param,          --  $n (n >= 1)
      Tk_Op,             --  operator
      Tk_Cast,           --  ::
      Tk_LParen, Tk_RParen, Tk_LBracket, Tk_RBracket,
      Tk_Comma, Tk_Semicolon, Tk_Dot, Tk_Colon);

   subtype Tok_Count is Natural range 0 .. Max_Text_Len;

   type Token is record
      Kind   : Tok_Kind   := Tk_Word;
      Kw     : Keyword_Id := Kw_None;   --  Tk_Word only
      Op     : Op_Kind    := Op_Other;  --  Tk_Op only
      First  : Text_Index := 1;         --  first character in the query
      Last   : Text_Index := 1;         --  last character in the query
      Depth  : Tok_Count  := 0;         --  ( / [ nesting depth outside the token
      Match  : Tok_Count  := 0;         --  index of the matching bracket token
      Is_Int : Boolean    := False;     --  digits-only Tk_Number / Tk_Param fitting Natural
      Value  : Natural    := 0;         --  value when Is_Int
   end record;

   type Token_Array is array (Text_Index) of Token;

   type Token_List is record
      Count : Tok_Count := 0;
      Items : Token_Array;
   end record;

   -------------------------------------------------------------------------
   --  Lexer
   -------------------------------------------------------------------------

   --  Index just past a "--" comment starting at Start (the newline is kept)
   function Line_Comment_End (Q : Bounded_Text; Start : Positive) return Positive
     with Global => null,
          Pre    => Start < Q.Length,
          Post   => Line_Comment_End'Result in Start + 2 .. Q.Length + 1
   is
      I : Positive := Start + 2;
   begin
      while I <= Q.Length
        and then Q.Data (I) /= ASCII.LF
        and then Q.Data (I) /= ASCII.CR
      loop
         pragma Loop_Invariant (I in Start + 2 .. Q.Length);
         pragma Loop_Variant (Increases => I);
         I := I + 1;
      end loop;
      return I;
   end Line_Comment_End;

   --  Index just past the nested "/* ... */" comment starting at Start, or 0
   --  when it is unterminated (PostgreSQL block comments nest)
   function Block_Comment_End (Q : Bounded_Text; Start : Positive) return Natural
     with Global => null,
          Pre    => Start < Q.Length
                    and then Q.Data (Start) = '/'
                    and then Q.Data (Start + 1) = '*',
          Post   => Block_Comment_End'Result = 0
                    or else Block_Comment_End'Result in Start + 4 .. Q.Length + 1
   is
      Depth : Positive := 1;
      I     : Positive := Start + 2;
   begin
      while I < Q.Length loop
         pragma Loop_Invariant (I in Start + 2 .. Q.Length - 1);
         pragma Loop_Invariant (Depth <= I);
         pragma Loop_Variant (Increases => I);
         if Q.Data (I) = '*' and then Q.Data (I + 1) = '/' then
            if Depth = 1 then
               return I + 2;
            end if;
            Depth := Depth - 1;
            I     := I + 2;
         elsif Q.Data (I) = '/' and then Q.Data (I + 1) = '*' then
            Depth := Depth + 1;
            I     := I + 2;
         else
            I := I + 1;
         end if;
      end loop;
      return 0;
   end Block_Comment_End;

   --  Index of the quote closing the literal opened at Open (the quote character
   --  is Q.Data (Open)).  A doubled quote belongs to the body and, when
   --  Backslash is set (E'...' strings), a backslash escapes the next character.
   --  Returns 0 when the literal is unterminated.
   function Quote_End
     (Q         : Bounded_Text;
      Open      : Positive;
      Backslash : Boolean) return Natural
     with Global => null,
          Pre    => Open <= Q.Length,
          Post   => Quote_End'Result = 0
                    or else (Quote_End'Result in Open + 1 .. Q.Length
                             and then Q.Data (Quote_End'Result) = Q.Data (Open))
   is
      Quote : constant Character := Q.Data (Open);
      I     : Positive := Open + 1;
   begin
      while I <= Q.Length loop
         pragma Loop_Invariant (I in Open + 1 .. Q.Length);
         pragma Loop_Variant (Increases => I);
         if Backslash and then Q.Data (I) = '\' then
            I := I + 2;
         elsif Q.Data (I) = Quote then
            if I < Q.Length and then Q.Data (I + 1) = Quote then
               I := I + 2;
            else
               return I;
            end if;
         else
            I := I + 1;
         end if;
      end loop;
      return 0;
   end Quote_End;

   --  Length of the dollar-quote delimiter "$" [tag] "$" starting at Pos, with
   --  tag = [A-Za-z\200-\377_][A-Za-z\200-\377_0-9]*; 0 when none starts there
   function Dollar_Delim_Len (Q : Bounded_Text; Pos : Positive) return Natural
     with Global => null,
          Pre    => Pos <= Q.Length,
          Post   => Dollar_Delim_Len'Result = 0
                    or else (Dollar_Delim_Len'Result >= 2
                             and then Pos + Dollar_Delim_Len'Result - 1 <= Q.Length
                             and then Q.Data (Pos + Dollar_Delim_Len'Result - 1) = '$')
   is
      I : Positive := Pos + 1;
   begin
      if Q.Data (Pos) /= '$' then
         return 0;
      end if;
      if I <= Q.Length and then Is_Ident_Start_Char (Q.Data (I)) then
         while I < Q.Length
           and then (Is_Ident_Start_Char (Q.Data (I + 1)) or else Is_Digit (Q.Data (I + 1)))
         loop
            pragma Loop_Invariant (I in Pos + 1 .. Q.Length - 1);
            pragma Loop_Variant (Increases => I);
            I := I + 1;
         end loop;
         I := I + 1;
      end if;
      if I <= Q.Length and then Q.Data (I) = '$' then
         return I - Pos + 1;
      end if;
      return 0;
   end Dollar_Delim_Len;

   --  Start index of the first repetition of the Len-character delimiter
   --  Q.Data (Open .. Open + Len - 1) after it, or 0 when the body is unterminated
   function Dollar_Close
     (Q    : Bounded_Text;
      Open : Positive;
      Len  : Positive) return Natural
     with Global => null,
          Pre    => Len >= 2 and then Len <= Q.Length and then Open <= Q.Length - Len + 1,
          Post   => Dollar_Close'Result = 0
                    or else (Dollar_Close'Result >= Open + Len
                             and then Dollar_Close'Result <= Q.Length - Len + 1)
   is
      Same : Boolean;
   begin
      for J in Open + Len .. Q.Length - Len + 1 loop
         Same := True;
         for K in 0 .. Len - 1 loop
            if Q.Data (J + K) /= Q.Data (Open + K) then
               Same := False;
               exit;
            end if;
         end loop;
         if Same then
            return J;
         end if;
      end loop;
      return 0;
   end Dollar_Close;

   --  Scan a numeric literal starting at Pos: digits [. digits] [e [+-] digits]
   --  (or . digits ...).  Is_Int is set for a digits-only literal whose value
   --  fits Natural.  Trailing identifier characters ("123abc", "1e") are
   --  rejected, as in PostgreSQL 15+, so PostgreSQL 16's "0x2A" / "0o52" /
   --  "0b1" integers and "1_000" separators, outside the dialect, fail too.
   procedure Scan_Number
     (Q      : in     Bounded_Text;
      Pos    : in     Positive;
      Last   :    out Positive;
      Is_Int :    out Boolean;
      Value  :    out Natural;
      OK     :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Pos <= Q.Length,
          Post   => Last in Pos .. Q.Length
                    and then (if not OK then not Is_Int)
                    and then (if not Is_Int then Value = 0)
   is
      E     : Natural := Pos - 1;
      Digit : Natural;
   begin
      Last   := Pos;
      Is_Int := True;
      Value  := 0;
      OK     := False;

      while E < Q.Length and then Is_Digit (Q.Data (E + 1)) loop
         pragma Loop_Invariant (E in Pos - 1 .. Q.Length - 1);
         pragma Loop_Invariant (if not Is_Int then Value = 0);
         pragma Loop_Variant (Increases => E);
         E := E + 1;
         if Is_Int then
            Digit := Character'Pos (Q.Data (E)) - Character'Pos ('0');
            if Value <= (Natural'Last - Digit) / 10 then
               Value := Value * 10 + Digit;
            else
               Is_Int := False;
               Value  := 0;
            end if;
         end if;
      end loop;

      --  Fraction (a second '.' starts a separate token)
      if E < Q.Length
        and then Q.Data (E + 1) = '.'
        and then not (E + 1 < Q.Length and then Q.Data (E + 2) = '.')
      then
         Is_Int := False;
         Value  := 0;
         E      := E + 1;
         while E < Q.Length and then Is_Digit (Q.Data (E + 1)) loop
            pragma Loop_Invariant (E in Pos .. Q.Length - 1);
            pragma Loop_Variant (Increases => E);
            E := E + 1;
         end loop;
      end if;

      if E < Pos then
         Is_Int := False;
         Value  := 0;
         return;
      end if;

      --  Exponent
      if E < Q.Length and then Q.Data (E + 1) in 'e' | 'E' then
         if E + 1 < Q.Length and then Is_Digit (Q.Data (E + 2)) then
            E := E + 1;
         elsif E + 2 < Q.Length
           and then Q.Data (E + 2) in '+' | '-'
           and then Is_Digit (Q.Data (E + 3))
         then
            E := E + 2;
         else
            Is_Int := False;
            Value  := 0;
            return;
         end if;
         Is_Int := False;
         Value  := 0;
         while E < Q.Length and then Is_Digit (Q.Data (E + 1)) loop
            pragma Loop_Invariant (E in Pos .. Q.Length - 1);
            pragma Loop_Variant (Increases => E);
            E := E + 1;
         end loop;
      end if;

      if E < Q.Length and then Is_Ident_Start_Char (Q.Data (E + 1)) then
         Is_Int := False;
         Value  := 0;
         return;
      end if;

      Last := E;
      OK   := True;
   end Scan_Number;

   --  Last index of the operator starting at Pos: the maximal op_chars run, cut
   --  before any "--" or "/*", and without trailing '+' / '-' unless the run
   --  contains one of ~ ! @ # % ^ & | ` ? (PostgreSQL operator lexing rule)
   function Op_End (Q : Bounded_Text; Pos : Positive) return Positive
     with Global => null,
          Pre    => Pos <= Q.Length,
          Post   => Op_End'Result in Pos .. Q.Length
   is
      E       : Positive := Pos;
      Special : Boolean  := False;
   begin
      while E < Q.Length
        and then Is_Op_Char (Q.Data (E + 1))
        and then not Starts_Comment (Q, E + 1)
      loop
         pragma Loop_Invariant (E in Pos .. Q.Length - 1);
         pragma Loop_Variant (Increases => E);
         E := E + 1;
      end loop;

      if E > Pos and then Q.Data (E) in '+' | '-' then
         for I in Pos .. E - 1 loop
            if Q.Data (I) in '~' | '!' | '@' | '#' | '^' | '&' | '|' | '`' | '?' | '%' then
               Special := True;
            end if;
         end loop;
         if not Special then
            while E > Pos and then Q.Data (E) in '+' | '-' loop
               pragma Loop_Invariant (E in Pos + 1 .. Q.Length);
               pragma Loop_Variant (Decreases => E);
               E := E - 1;
            end loop;
         end if;
      end if;
      return E;
   end Op_End;

   --  Scan the single token starting at Pos (not whitespace, not a comment)
   procedure Scan_Token
     (Q   : in     Bounded_Text;
      Pos : in     Positive;
      Tok :    out Token;
      OK  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => Pos <= Q.Length,
          Post   => Tok.First = Pos
                    and then Tok.Last in Pos .. Q.Length
                    and then Tok.Depth = 0
                    and then Tok.Match = 0
   is
      C      : constant Character := Q.Data (Pos);
      E      : Natural;
      Last   : Positive;
      Is_Int : Boolean;
      Value  : Natural;
      Num_OK : Boolean;
      D_Len  : Natural;
   begin
      Tok := (Kind   => Tk_Op,
              Kw     => Kw_None,
              Op     => Op_Other,
              First  => Pos,
              Last   => Pos,
              Depth  => 0,
              Match  => 0,
              Is_Int => False,
              Value  => 0);
      OK := False;

      if C = '"' or else C = ''' then
         E := Quote_End (Q, Pos, Backslash => False);
         if E = 0 or else (C = '"' and then E = Pos + 1) then
            return;  --  unterminated literal or zero-length delimited identifier
         end if;
         Tok.Kind := (if C = '"' then Tk_Quoted else Tk_String);
         Tok.Last := E;
      elsif Is_Ident_Start_Char (C) then
         E := Pos;
         while E < Q.Length and then Is_Ident_Char (Q.Data (E + 1)) loop
            pragma Loop_Invariant (E in Pos .. Q.Length - 1);
            pragma Loop_Variant (Increases => E);
            E := E + 1;
         end loop;
         if E = Pos
           and then E < Q.Length
           and then Q.Data (E + 1) = '''
           and then C in 'E' | 'e' | 'B' | 'b' | 'X' | 'x' | 'N' | 'n'
         then
            --  E'...' escape string, B'...' / X'...' bit string, N'...' string
            E := Quote_End (Q, Pos + 1, Backslash => C in 'E' | 'e');
            if E = 0 then
               return;
            end if;
            Tok.Kind :=
              (if C in 'E' | 'e' then Tk_E_String
               elsif C in 'N' | 'n' then Tk_String
               else Tk_Bit_String);
            Tok.Last := E;
         else
            Tok.Kind := Tk_Word;
            Tok.Last := E;
            Tok.Kw   := Lookup_Keyword (Q, Pos, E);
         end if;
      elsif Is_Digit (C)
        or else (C = '.' and then Pos < Q.Length and then Is_Digit (Q.Data (Pos + 1)))
      then
         Scan_Number (Q, Pos, Last, Is_Int, Value, Num_OK);
         if not Num_OK then
            return;
         end if;
         Tok.Kind   := Tk_Number;
         Tok.Last   := Last;
         Tok.Is_Int := Is_Int;
         Tok.Value  := Value;
      elsif C = '$' then
         if Pos < Q.Length and then Is_Digit (Q.Data (Pos + 1)) then
            --  Positional parameter $n: n >= 1, no fraction/exponent/junk
            Scan_Number (Q, Pos + 1, Last, Is_Int, Value, Num_OK);
            if not Num_OK or else not Is_Int or else Value = 0 then
               return;
            end if;
            Tok.Kind   := Tk_Param;
            Tok.Last   := Last;
            Tok.Is_Int := True;
            Tok.Value  := Value;
         else
            D_Len := Dollar_Delim_Len (Q, Pos);
            if D_Len = 0 then
               return;  --  stray '$'
            end if;
            E := Dollar_Close (Q, Pos, D_Len);
            if E = 0 then
               return;  --  unterminated dollar-quoted string
            end if;
            Tok.Kind := Tk_Dollar_String;
            Tok.Last := E + D_Len - 1;
         end if;
      elsif Is_Op_Char (C) then
         E        := Op_End (Q, Pos);
         Tok.Kind := Tk_Op;
         Tok.Last := E;
         Tok.Op   := Classify_Op (Q, Pos, E);
      elsif C = ':' then
         Tok.Kind := Tk_Colon;
         if Pos < Q.Length and then Q.Data (Pos + 1) = ':' then
            Tok.Kind := Tk_Cast;
            Tok.Last := Pos + 1;
         end if;
      elsif C = '(' then
         Tok.Kind := Tk_LParen;
      elsif C = ')' then
         Tok.Kind := Tk_RParen;
      elsif C = '[' then
         Tok.Kind := Tk_LBracket;
      elsif C = ']' then
         Tok.Kind := Tk_RBracket;
      elsif C = ',' then
         Tok.Kind := Tk_Comma;
      elsif C = ';' then
         Tok.Kind := Tk_Semicolon;
      elsif C = '.' then
         Tok.Kind := Tk_Dot;
      else
         return;  --  character outside the SQL lexical grammar
      end if;
      OK := True;
   end Scan_Token;

   --  Does the text from Pos (just after a string literal's closing quote) continue
   --  that literal the way PostgreSQL's scan.l does ("quotecontinue": whitespace
   --  and "--" comments holding at least one newline, then a quote)?  The scanner
   --  then keeps the literal's escape mode, so an E'...' literal continued that way
   --  can hide a statement separator from a lexer that restarts a plain string.
   function Starts_String_Continuation (Q : Bounded_Text; Pos : Positive) return Boolean
     with Global => null
   is
      P       : Positive := Pos;
      Newline : Boolean  := False;
   begin
      while P <= Q.Length loop
         pragma Loop_Invariant (P in Pos .. Q.Length);
         pragma Loop_Variant (Increases => P);
         if Q.Data (P) = ASCII.LF or else Q.Data (P) = ASCII.CR then
            Newline := True;
            P := P + 1;
         elsif Is_WS_Char (Q.Data (P)) then
            P := P + 1;
         elsif Starts_Comment (Q, P) and then Q.Data (P) = '-' then
            P := Line_Comment_End (Q, P);
         else
            return Newline and then Q.Data (P) = ''';
         end if;
      end loop;
      return False;
   end Starts_String_Continuation;

   --  Split Query into tokens, skipping whitespace and (nested) comments, and
   --  pair every ( / [ with its ) / ].  Valid is False on any lexical error,
   --  unterminated literal/comment, or unbalanced / mismatched bracket.
   procedure Tokenize
     (Query : in     Bounded_Text;
      Toks  :    out Token_List;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => Toks.Count <= Query.Length
   is
      type Open_Stack is array (Text_Index) of Tok_Count;

      Stack  : Open_Stack := [others => 0];
      Top    : Tok_Count  := 0;
      Pos    : Positive   := 1;
      Tok    : Token;
      Tok_OK : Boolean;
      Open   : Tok_Count;
      E      : Natural;
   begin
      Toks  := (Count => 0, Items => [others => (others => <>)]);
      Valid := False;

      --  A NUL byte never reaches a PostgreSQL server (queries are C strings),
      --  so a server would parse a truncated text: reject NUL anywhere, even
      --  inside literals and comments
      for I in 1 .. Query.Length loop
         if Query.Data (I) = ASCII.NUL then
            return;
         end if;
      end loop;

      --  The lexer works on bytes, which is sound only for UTF-8 (no byte of a
      --  multi-byte character is ASCII). In client encodings such as SJIS, BIG5,
      --  GBK or GB18030 a backslash byte can be the second half of a character, so
      --  the server would end an E'' literal elsewhere: other text is rejected
      if not Is_Valid_UTF8 (Query) then
         return;
      end if;

      while Pos <= Query.Length loop
         pragma Loop_Invariant (Toks.Count < Pos);
         pragma Loop_Invariant (Top <= Toks.Count);
         pragma Loop_Variant (Increases => Pos);

         if Is_WS_Char (Query.Data (Pos)) then
            Pos := Pos + 1;
         elsif Starts_Comment (Query, Pos) and then Query.Data (Pos) = '-' then
            Pos := Line_Comment_End (Query, Pos);
         elsif Starts_Comment (Query, Pos) then
            E := Block_Comment_End (Query, Pos);
            if E = 0 then
               return;
            end if;
            Pos := E;
         else
            Scan_Token (Query, Pos, Tok, Tok_OK);
            if not Tok_OK then
               return;
            end if;
            if Tok.Kind in Tk_LParen | Tk_LBracket then
               Tok.Depth   := Top;
               Top         := Top + 1;
               Stack (Top) := Toks.Count + 1;
            elsif Tok.Kind in Tk_RParen | Tk_RBracket then
               if Top = 0 then
                  return;
               end if;
               Open := Stack (Top);
               if Open not in 1 .. Toks.Count
                 or else (Tok.Kind = Tk_RParen and then Toks.Items (Open).Kind /= Tk_LParen)
                 or else (Tok.Kind = Tk_RBracket and then Toks.Items (Open).Kind /= Tk_LBracket)
               then
                  return;
               end if;
               Top       := Top - 1;
               Tok.Depth := Top;
               Tok.Match := Open;
               Toks.Items (Open).Match := Toks.Count + 1;
            else
               Tok.Depth := Top;
            end if;
            Toks.Count := Toks.Count + 1;
            Toks.Items (Toks.Count) := Tok;
            Pos := Tok.Last + 1;

            --  A literal continued on a later line is outside the dialect
            if Tok.Kind in Tk_String | Tk_E_String | Tk_Bit_String
              and then Starts_String_Continuation (Query, Pos)
            then
               return;
            end if;
         end if;
      end loop;

      Valid := Top = 0;
   end Tokenize;

   -------------------------------------------------------------------------
   --  Token queries.  A token range is First .. Last with Last <= T.Count; a
   --  "unit" is one token or one complete bracketed group ( ... ) / [ ... ].
   -------------------------------------------------------------------------

   function Kw_At (T : Token_List; I : Natural; K : Keyword_Id) return Boolean is
     (I in 1 .. T.Count and then T.Items (I).Kind = Tk_Word and then T.Items (I).Kw = K);

   --  Key word K at token I, which must lie inside a range ending at L
   function Kw_In (T : Token_List; I : Natural; L : Natural; K : Keyword_Id) return Boolean is
     (I <= L and then Kw_At (T, I, K));

   function Kind_In (T : Token_List; I : Natural; L : Natural; K : Tok_Kind) return Boolean is
     (I <= L and then I in 1 .. T.Count and then T.Items (I).Kind = K);

   --  Name token: delimited identifier, or unquoted word that is not reserved
   function Name_In (T : Token_List; I : Natural; L : Natural) return Boolean is
     (I <= L
      and then I in 1 .. T.Count
      and then (T.Items (I).Kind = Tk_Quoted
                or else (T.Items (I).Kind = Tk_Word
                         and then T.Items (I).Kw not in Reserved_Keyword)));

   --  Matching ) of the ( at I when the whole group lies inside .. L, else 0
   function Paren_Close (T : Token_List; I : Natural; L : Natural) return Natural is
     (if I in 1 .. T.Count
         and then L <= T.Count
         and then T.Items (I).Kind = Tk_LParen
         and then T.Items (I).Match in I + 1 .. L
      then T.Items (I).Match
      else 0);

   --  Matching ] of the [ at I when the whole group lies inside .. L, else 0
   function Bracket_Close (T : Token_List; I : Natural; L : Natural) return Natural is
     (if I in 1 .. T.Count
         and then L <= T.Count
         and then T.Items (I).Kind = Tk_LBracket
         and then T.Items (I).Match in I + 1 .. L
      then T.Items (I).Match
      else 0);

   --  Index of the unit following the unit that starts at I, or 0 when the unit
   --  is a closing bracket or a group extending beyond L
   function Next_Unit (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => I <= L and then L <= T.Count,
          Post   => Next_Unit'Result = 0 or else Next_Unit'Result in I + 1 .. L + 1
   is
   begin
      case T.Items (I).Kind is
         when Tk_LParen | Tk_LBracket =>
            if T.Items (I).Match in I + 1 .. L then
               return T.Items (I).Match + 1;
            end if;
            return 0;
         when Tk_RParen | Tk_RBracket =>
            return 0;
         when others =>
            return I + 1;
      end case;
   end Next_Unit;

   --  The FROM at I is the operator part of "IS [NOT] DISTINCT FROM"
   function Is_Distinct_From (T : Token_List; I : Positive) return Boolean is
     (I >= 3
      and then Kw_At (T, I, Kw_From)
      and then Kw_At (T, I - 1, Kw_Distinct)
      and then (Kw_At (T, I - 2, Kw_Is)
                or else (I >= 4
                         and then Kw_At (T, I - 2, Kw_Not)
                         and then Kw_At (T, I - 3, Kw_Is))));

   --  Query block start: SELECT, WITH or VALUES at F (F <= L)
   function Starts_Query (T : Token_List; F : Natural; L : Natural) return Boolean is
     (F <= L
      and then (Kw_At (T, F, Kw_Select)
                or else Kw_At (T, F, Kw_With)
                or else Kw_At (T, F, Kw_Values)));

   --  Reserved words that structure statements and therefore never occur inside
   --  an expression at the expression's own nesting level.  Exceptions: FROM of
   --  IS [NOT] DISTINCT FROM, WITHIN GROUP (...), the LEFT(...) / RIGHT(...)
   --  functions, and USING inside ORDER BY lists (Allow_Using).
   function Is_Expr_Forbidden
     (T           : Token_List;
      I           : Positive;
      Allow_Using : Boolean) return Boolean
   is
     (I <= T.Count
      and then T.Items (I).Kind = Tk_Word
      and then
        (case T.Items (I).Kw is
            when Kw_From            => not Is_Distinct_From (T, I),
            when Kw_Group           =>
              not (Kw_At (T, I - 1, Kw_Within) and then Kind_In (T, I + 1, T.Count, Tk_LParen)),
            when Kw_Left | Kw_Right => not Kind_In (T, I + 1, T.Count, Tk_LParen),
            when Kw_Using           => not Allow_Using,
            when Kw_By | Kw_Check | Kw_Constraint | Kw_Create | Kw_Cross | Kw_Delete
               | Kw_Do | Kw_Except | Kw_Fetch | Kw_For | Kw_Foreign | Kw_Full | Kw_Grant
               | Kw_Having | Kw_Inner | Kw_Insert | Kw_Intersect | Kw_Into | Kw_Join
               | Kw_Lateral | Kw_Limit | Kw_Natural | Kw_Offset | Kw_On | Kw_Only
               | Kw_Order | Kw_Outer | Kw_Primary | Kw_References | Kw_Returning
               | Kw_Select | Kw_Set | Kw_Table | Kw_Union | Kw_Unique | Kw_Update
               | Kw_Values | Kw_Where | Kw_Window =>
              True,
            when others             => False));

   --  One expression: a non-empty sequence of units in F .. L containing no
   --  comma, semicolon, or structure word at its own level (group contents are
   --  opaque here; nested query blocks are validated separately)
   function Check_Expr
     (T           : Token_List;
      F           : Positive;
      L           : Natural;
      Allow_Using : Boolean) return Boolean
     with Global => null,
          Pre    => L <= T.Count,
          Post   => (if Check_Expr'Result then F <= L)
   is
      I   : Positive := F;
      Nxt : Natural;
   begin
      if F > L then
         return False;
      end if;
      while I <= L loop
         pragma Loop_Invariant (I in F .. L);
         pragma Loop_Variant (Increases => I);
         if T.Items (I).Kind in Tk_Comma | Tk_Semicolon
           or else Is_Expr_Forbidden (T, I, Allow_Using)
         then
            return False;
         end if;
         Nxt := Next_Unit (T, I, L);
         if Nxt = 0 then
            return False;
         end if;
         I := Nxt;
      end loop;
      return True;
   end Check_Expr;

   --  Comma-separated list of expressions in F .. L: number of items, or 0 when
   --  the list is empty or has an empty / invalid item
   function Check_Expr_List
     (T           : Token_List;
      F           : Positive;
      L           : Natural;
      Allow_Using : Boolean) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => (if Check_Expr_List'Result > 0
                     then F <= L and then Check_Expr_List'Result <= L - F + 1)
   is
      I         : Positive := F;
      Items     : Natural  := 0;
      Seg_Empty : Boolean  := True;
      Nxt       : Natural;
   begin
      if F > L then
         return 0;
      end if;
      while I <= L loop
         pragma Loop_Invariant (I in F .. L);
         pragma Loop_Invariant (Items <= I - F);
         pragma Loop_Invariant (if not Seg_Empty then Items < I - F);
         pragma Loop_Variant (Increases => I);
         if T.Items (I).Kind = Tk_Comma then
            if Seg_Empty then
               return 0;
            end if;
            Items     := Items + 1;
            Seg_Empty := True;
            I         := I + 1;
         else
            if T.Items (I).Kind = Tk_Semicolon
              or else Is_Expr_Forbidden (T, I, Allow_Using)
            then
               return 0;
            end if;
            Nxt := Next_Unit (T, I, L);
            if Nxt = 0 then
               return 0;
            end if;
            Seg_Empty := False;
            I         := Nxt;
         end if;
      end loop;
      if Seg_Empty then
         return 0;
      end if;
      return Items + 1;
   end Check_Expr_List;

   --  Unit-level probes for Find_Unit
   type Unit_Probe is (Probe_Comma, Probe_Equal, Probe_Keywords);

   function Unit_Hits
     (T          : Token_List;
      I          : Positive;
      Probe      : Unit_Probe;
      K1, K2, K3 : Keyword_Id) return Boolean
   is
     (I <= T.Count
      and then
        (case Probe is
            when Probe_Comma    => T.Items (I).Kind = Tk_Comma,
            when Probe_Equal    =>
              T.Items (I).Kind = Tk_Op and then T.Items (I).Op = Op_Equal,
            when Probe_Keywords =>
              T.Items (I).Kind = Tk_Word
              and then T.Items (I).Kw /= Kw_None
              and then (T.Items (I).Kw = K1 or else T.Items (I).Kw = K2
                        or else T.Items (I).Kw = K3)
              and then not Is_Distinct_From (T, I)));

   --  First unit in From .. L hit by Probe (for Probe_Keywords: one of the key
   --  words K1 .. K3, never the FROM of IS DISTINCT FROM); L + 1 when no unit
   --  hits; 0 when From .. L is not a sequence of complete units
   function Find_Unit
     (T     : Token_List;
      From  : Positive;
      L     : Natural;
      Probe : Unit_Probe;
      K1    : Keyword_Id := Kw_None;
      K2    : Keyword_Id := Kw_None;
      K3    : Keyword_Id := Kw_None) return Natural
     with Global => null,
          Pre    => L <= T.Count and then From <= L + 1,
          Post   => Find_Unit'Result = 0 or else Find_Unit'Result in From .. L + 1
   is
      I   : Positive := From;
      Nxt : Natural;
   begin
      while I <= L loop
         pragma Loop_Invariant (I in From .. L);
         pragma Loop_Variant (Increases => I);
         if Unit_Hits (T, I, Probe, K1, K2, K3) then
            return I;
         end if;
         Nxt := Next_Unit (T, I, L);
         if Nxt = 0 then
            return 0;
         end if;
         I := Nxt;
      end loop;
      return I;
   end Find_Unit;

   --  End (index after) of the name [. name ...] at I with at most Max_Parts
   --  parts, or 0 when no name starts at I or it has too many parts
   function Qualified_Name_End
     (T         : Token_List;
      I         : Positive;
      L         : Natural;
      Max_Parts : Positive) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => Qualified_Name_End'Result = 0
                    or else Qualified_Name_End'Result in I + 1 .. L + 1
   is
      J     : Positive := I + 1;
      Parts : Positive := 1;
   begin
      if not Name_In (T, I, L) then
         return 0;
      end if;
      while J < L and then Kind_In (T, J, L, Tk_Dot) and then Name_In (T, J + 1, L) loop
         pragma Loop_Invariant (J in I + 1 .. L - 1);
         pragma Loop_Invariant (Parts <= J - I);
         pragma Loop_Variant (Increases => J);
         if Parts = Max_Parts then
            return 0;
         end if;
         Parts := Parts + 1;
         J     := J + 2;
      end loop;
      return J;
   end Qualified_Name_End;

   --  End (index after) of "qualified_name {, qualified_name}" starting at I
   function Name_List_End
     (T         : Token_List;
      I         : Positive;
      L         : Natural;
      Max_Parts : Positive) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => Name_List_End'Result = 0 or else Name_List_End'Result in I + 1 .. L + 1
   is
      K : Positive := I;
      J : Natural  := Qualified_Name_End (T, I, L, Max_Parts);
   begin
      while J /= 0 and then Kind_In (T, J, L, Tk_Comma) loop
         pragma Loop_Invariant (K in I .. L);
         pragma Loop_Invariant (J in K + 1 .. L);
         pragma Loop_Variant (Increases => K);
         K := J + 1;
         J := Qualified_Name_End (T, K, L, Max_Parts);
      end loop;
      return J;
   end Name_List_End;

   --  F .. L is exactly "name {, name}" (unqualified names)
   function Is_Name_List (T : Token_List; F : Positive; L : Natural) return Boolean is
     (L <= T.Count and then F <= L and then Name_List_End (T, F, L, 1) = L + 1);

   --  Append the unquoted text of the name token Tok ("" un-doubled) to Res
   procedure Append_Name
     (Q   : in     Bounded_Text;
      Tok : in     Token;
      Res : in out Bounded_Ident;
      OK  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if OK then Res.Length > Res.Length'Old
                              and then Tok.Kind in Tk_Word | Tk_Quoted)
   is
      Start_Len : constant Ident_Length := Res.Length;
      I         : Positive;
   begin
      OK := False;
      if Tok.First > Tok.Last or else Tok.Last > Q.Length then
         return;
      end if;
      if Tok.Kind = Tk_Word then
         for J in Tok.First .. Tok.Last loop
            if Res.Length = Max_Ident_Len then
               return;
            end if;
            Res.Length := Res.Length + 1;
            Res.Data (Res.Length) := Q.Data (J);
         end loop;
      elsif Tok.Kind = Tk_Quoted and then Tok.Last - Tok.First >= 2 then
         I := Tok.First + 1;
         while I < Tok.Last loop
            pragma Loop_Invariant (I in Tok.First + 1 .. Tok.Last - 1);
            pragma Loop_Variant (Increases => I);
            if Res.Length = Max_Ident_Len then
               return;
            end if;
            Res.Length := Res.Length + 1;
            Res.Data (Res.Length) := Q.Data (I);
            I := (if Q.Data (I) = '"' then I + 2 else I + 1);
         end loop;
      else
         return;
      end if;
      OK := Res.Length > Start_Len;
   end Append_Name;

   --  Parse "name [. name ...]" (at most Max_Parts parts) at I into its unquoted,
   --  dot-joined text (at most Max_Ident_Len characters).  Next is the index
   --  after the name, or 0 when no valid name starts at I.
   procedure Parse_Qualified_Name
     (Q         : in     Bounded_Text;
      T         : in     Token_List;
      I         : in     Positive;
      L         : in     Natural;
      Max_Parts : in     Positive;
      Name      :    out Bounded_Ident;
      Next      :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if Next /= 0 then Next in I + 1 .. L + 1 and then Name.Length > 0)
   is
      J       : Positive := I + 1;
      Parts   : Positive := 1;
      Part_OK : Boolean;
   begin
      Name := Empty_Ident;
      Next := 0;
      if not Name_In (T, I, L) then
         return;
      end if;
      Append_Name (Q, T.Items (I), Name, Part_OK);
      if not Part_OK then
         return;
      end if;
      while J < L and then Kind_In (T, J, L, Tk_Dot) and then Name_In (T, J + 1, L) loop
         pragma Loop_Invariant (J in I + 1 .. L - 1);
         pragma Loop_Invariant (Parts <= J - I);
         pragma Loop_Invariant (Name.Length > 0);
         pragma Loop_Variant (Increases => J);
         if Parts = Max_Parts or else Name.Length = Max_Ident_Len then
            return;
         end if;
         Name.Length := Name.Length + 1;
         Name.Data (Name.Length) := '.';
         Append_Name (Q, T.Items (J + 1), Name, Part_OK);
         if not Part_OK then
            return;
         end if;
         Parts := Parts + 1;
         J     := J + 2;
      end loop;
      Next := J;
   end Parse_Qualified_Name;

   -------------------------------------------------------------------------
   --  Queries (SELECT / WITH / VALUES)
   -------------------------------------------------------------------------

   type Query_Info is record
      Column_Count     : Natural       := 0;
      Target           : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Has_Limit        : Boolean       := False;
      Limit_Value      : Natural       := 0;
      Has_Param_Limit  : Boolean       := False;
      Has_Offset       : Boolean       := False;
      Offset_Value     : Natural       := 0;
      Has_Param_Offset : Boolean       := False;
   end record;

   --  Consistency of the row-limit fields (mirrored in Analyze_SQL's Post)
   function Limit_Info_OK (Info : Query_Info) return Boolean is
     ((if not Info.Has_Limit then Info.Limit_Value = 0)
      and then not (Info.Has_Limit and then Info.Has_Param_Limit)
      and then (if not Info.Has_Offset
                then Info.Offset_Value = 0 and then not Info.Has_Param_Offset));

   --  LIMIT { n | ALL | $n }  or  FETCH { FIRST | NEXT } [ n | $n ] { ROW | ROWS } ONLY
   procedure Parse_Limit_Part
     (T    : in     Token_List;
      I    : in     Positive;
      L    : in     Natural;
      Info : in out Query_Info;
      Next :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count and then I <= L and then Limit_Info_OK (Info),
          Post   => Limit_Info_OK (Info)
                    and then Info.Column_Count = Info.Column_Count'Old
                    and then (Next = 0 or else Next in I + 2 .. L + 1)
   is
      J        : Positive := I + 1;
      Count    : Natural  := 1;
      Is_Param : Boolean  := False;
   begin
      Next := 0;
      if Kw_At (T, I, Kw_Limit) then
         if Kind_In (T, J, L, Tk_Number) and then T.Items (J).Is_Int then
            Info.Has_Limit       := True;
            Info.Limit_Value     := T.Items (J).Value;
            Info.Has_Param_Limit := False;
         elsif Kind_In (T, J, L, Tk_Param) then
            Info.Has_Limit       := False;
            Info.Limit_Value     := 0;
            Info.Has_Param_Limit := True;
         elsif Kw_In (T, J, L, Kw_All) then
            Info.Has_Limit       := False;
            Info.Limit_Value     := 0;
            Info.Has_Param_Limit := False;
         else
            return;
         end if;
         Next := J + 1;
      elsif Kw_At (T, I, Kw_Fetch) then
         if not (Kw_In (T, J, L, Kw_First) or else Kw_In (T, J, L, Kw_Next)) then
            return;
         end if;
         J := J + 1;
         if Kind_In (T, J, L, Tk_Number) and then T.Items (J).Is_Int then
            Count := T.Items (J).Value;
            J     := J + 1;
         elsif Kind_In (T, J, L, Tk_Param) then
            Is_Param := True;
            J        := J + 1;
         end if;
         if not (Kw_In (T, J, L, Kw_Row) or else Kw_In (T, J, L, Kw_Rows))
           or else not Kw_In (T, J + 1, L, Kw_Only)
         then
            return;
         end if;
         Info.Has_Limit       := not Is_Param;
         Info.Limit_Value     := (if Is_Param then 0 else Count);
         Info.Has_Param_Limit := Is_Param;
         Next := J + 2;
      end if;
   end Parse_Limit_Part;

   --  OFFSET { n | $n } [ ROW | ROWS ]
   procedure Parse_Offset_Part
     (T    : in     Token_List;
      I    : in     Positive;
      L    : in     Natural;
      Info : in out Query_Info;
      Next :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count and then I <= L and then Limit_Info_OK (Info),
          Post   => Limit_Info_OK (Info)
                    and then Info.Column_Count = Info.Column_Count'Old
                    and then (Next = 0 or else Next in I + 2 .. L + 1)
   is
      J : constant Positive := I + 1;
   begin
      Next := 0;
      if not Kw_At (T, I, Kw_Offset) then
         return;
      end if;
      if Kind_In (T, J, L, Tk_Number) and then T.Items (J).Is_Int then
         Info.Has_Offset       := True;
         Info.Offset_Value     := T.Items (J).Value;
         Info.Has_Param_Offset := False;
      elsif Kind_In (T, J, L, Tk_Param) then
         Info.Has_Offset       := True;
         Info.Offset_Value     := 0;
         Info.Has_Param_Offset := True;
      else
         return;
      end if;
      if Kw_In (T, J + 1, L, Kw_Row) or else Kw_In (T, J + 1, L, Kw_Rows) then
         Next := J + 2;
      else
         Next := J + 1;
      end if;
   end Parse_Offset_Part;

   --  FOR { UPDATE | NO KEY UPDATE | SHARE | KEY SHARE } [ OF name {, name} ]
   --  [ NOWAIT | SKIP LOCKED ], repeated; index after the last locking clause
   function Locking_End (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => Locking_End'Result = 0 or else Locking_End'Result in I + 2 .. L + 1
   is
      J : Positive := I;
      N : Natural;
   begin
      if not Kw_In (T, I, L, Kw_For) then
         return 0;
      end if;
      while Kw_In (T, J, L, Kw_For) loop
         pragma Loop_Invariant (J in I .. L);
         pragma Loop_Invariant (if J /= I then J >= I + 2);
         pragma Loop_Variant (Increases => J);
         if Kw_In (T, J + 1, L, Kw_Update) or else Kw_In (T, J + 1, L, Kw_Share) then
            J := J + 2;
         elsif Kw_In (T, J + 1, L, Kw_No)
           and then Kw_In (T, J + 2, L, Kw_Key)
           and then Kw_In (T, J + 3, L, Kw_Update)
         then
            J := J + 4;
         elsif Kw_In (T, J + 1, L, Kw_Key) and then Kw_In (T, J + 2, L, Kw_Share) then
            J := J + 3;
         else
            return 0;
         end if;
         if Kw_In (T, J, L, Kw_Of) then
            N := Name_List_End (T, J + 1, L, 2);
            if N = 0 then
               return 0;
            end if;
            J := N;
         end if;
         if Kw_In (T, J, L, Kw_Nowait) then
            J := J + 1;
         elsif Kw_In (T, J, L, Kw_Skip) and then Kw_In (T, J + 1, L, Kw_Locked) then
            J := J + 2;
         end if;
      end loop;
      return J;
   end Locking_End;

   --  Statement tail after ORDER BY: [limit_block] [locking] | [locking] [limit_block]
   --  where limit_block = limit [offset] | offset [limit]; must consume F .. L
   procedure Parse_Tail
     (T    : in     Token_List;
      F    : in     Positive;
      L    : in     Natural;
      Info : in out Query_Info;
      OK   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count and then Limit_Info_OK (Info),
          Post   => Limit_Info_OK (Info)
                    and then Info.Column_Count = Info.Column_Count'Old
   is
      I          : Natural := F;
      Nxt        : Natural;
      Lock_First : Boolean := False;
   begin
      OK := False;
      if Kw_In (T, I, L, Kw_For) then
         Nxt := Locking_End (T, I, L);
         if Nxt = 0 then
            return;
         end if;
         I          := Nxt;
         Lock_First := True;
      end if;
      if Kw_In (T, I, L, Kw_Limit) or else Kw_In (T, I, L, Kw_Fetch) then
         Parse_Limit_Part (T, I, L, Info, Nxt);
         if Nxt = 0 then
            return;
         end if;
         I := Nxt;
         if Kw_In (T, I, L, Kw_Offset) then
            Parse_Offset_Part (T, I, L, Info, Nxt);
            if Nxt = 0 then
               return;
            end if;
            I := Nxt;
         end if;
      elsif Kw_In (T, I, L, Kw_Offset) then
         Parse_Offset_Part (T, I, L, Info, Nxt);
         if Nxt = 0 then
            return;
         end if;
         I := Nxt;
         if Kw_In (T, I, L, Kw_Limit) or else Kw_In (T, I, L, Kw_Fetch) then
            Parse_Limit_Part (T, I, L, Info, Nxt);
            if Nxt = 0 then
               return;
            end if;
            I := Nxt;
         end if;
      end if;
      if not Lock_First and then Kw_In (T, I, L, Kw_For) then
         Nxt := Locking_End (T, I, L);
         if Nxt = 0 then
            return;
         end if;
         I := Nxt;
      end if;
      OK := I > L;
   end Parse_Tail;

   --  FROM item: [ONLY] relation | function (...) | [LATERAL] (query) |
   --  LATERAL function (...), then [ [AS] alias [(column aliases)] ].
   --  Rel is the relation name for a plain relation, empty otherwise.
   procedure Parse_Table_Primary
     (Q    : in     Bounded_Text;
      T    : in     Token_List;
      I    : in     Positive;
      L    : in     Natural;
      Rel  :    out Bounded_Ident;
      Next :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if Next /= 0 then Next in I + 1 .. L + 1)
   is
      J         : Positive := I;
      Close     : Natural;
      N         : Natural;
      Name      : Bounded_Ident;
      Has_Alias : Boolean  := False;
   begin
      Rel  := Empty_Ident;
      Next := 0;
      if Kw_In (T, I, L, Kw_Lateral) then
         J := I + 1;
         if Kind_In (T, J, L, Tk_LParen) then
            Close := Paren_Close (T, J, L);
            if Close = 0 or else not Starts_Query (T, J + 1, Close - 1) then
               return;
            end if;
         else
            N := Qualified_Name_End (T, J, L, 2);
            if N = 0 then
               return;
            end if;
            Close := Paren_Close (T, N, L);
            if Close = 0 then
               return;
            end if;
         end if;
         J := Close + 1;
      elsif Kind_In (T, I, L, Tk_LParen) then
         Close := Paren_Close (T, I, L);
         if Close = 0 or else not Starts_Query (T, I + 1, Close - 1) then
            return;  --  parenthesized joins are outside the dialect
         end if;
         J := Close + 1;
      else
         if Kw_In (T, I, L, Kw_Only) then
            J := I + 1;
         end if;
         Parse_Qualified_Name (Q, T, J, L, 2, Name, N);
         if N = 0 then
            return;
         end if;
         if Kind_In (T, N, L, Tk_LParen) then
            if J /= I then
               return;  --  ONLY applies to relations, not functions
            end if;
            Close := Paren_Close (T, N, L);
            if Close = 0 then
               return;
            end if;
            J := Close + 1;
         else
            Rel := Name;
            J   := N;
         end if;
      end if;

      if Kw_In (T, J, L, Kw_As) then
         if not Name_In (T, J + 1, L) then
            return;
         end if;
         J         := J + 2;
         Has_Alias := True;
      elsif Name_In (T, J, L) then
         J         := J + 1;
         Has_Alias := True;
      end if;
      if Has_Alias and then Kind_In (T, J, L, Tk_LParen) then
         Close := Paren_Close (T, J, L);
         if Close = 0 or else not Is_Name_List (T, J + 1, Close - 1) then
            return;
         end if;
         J := Close + 1;
      end if;
      Next := J;
   end Parse_Table_Primary;

   --  A join operator starts at I (LEFT / RIGHT followed by "(" are functions)
   function Is_Join_Start (T : Token_List; I : Natural; L : Natural) return Boolean is
     (Kw_In (T, I, L, Kw_Join) or else Kw_In (T, I, L, Kw_Cross)
      or else Kw_In (T, I, L, Kw_Natural) or else Kw_In (T, I, L, Kw_Inner)
      or else Kw_In (T, I, L, Kw_Full)
      or else ((Kw_In (T, I, L, Kw_Left) or else Kw_In (T, I, L, Kw_Right))
               and then not Kind_In (T, I + 1, L, Tk_LParen)));

   --  CROSS JOIN item | NATURAL [type] JOIN item | [type] JOIN item {ON expr | USING (names)}
   --  with type = INNER | { LEFT | RIGHT | FULL } [OUTER]
   procedure Parse_Join
     (Q    : in     Bounded_Text;
      T    : in     Token_List;
      I    : in     Positive;
      L    : in     Natural;
      Next :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if Next /= 0 then Next in I + 2 .. L + 1)
   is
      J         : Positive := I;
      Qualified : Boolean  := True;
      Rel       : Bounded_Ident;
      pragma Warnings (Off, Rel);
      N         : Natural;
      E         : Positive;
      Close     : Natural;
   begin
      Next := 0;
      if Kw_In (T, J, L, Kw_Cross) then
         Qualified := False;
         J         := J + 1;
      else
         if Kw_In (T, J, L, Kw_Natural) then
            Qualified := False;
            J         := J + 1;
         end if;
         if Kw_In (T, J, L, Kw_Inner) then
            J := J + 1;
         elsif Kw_In (T, J, L, Kw_Left)
           or else Kw_In (T, J, L, Kw_Right)
           or else Kw_In (T, J, L, Kw_Full)
         then
            J := J + 1;
            if Kw_In (T, J, L, Kw_Outer) then
               J := J + 1;
            end if;
         end if;
      end if;
      if not Kw_In (T, J, L, Kw_Join) then
         return;
      end if;
      pragma Warnings (GNATprove, Off, "is set by ""Parse_Table_Primary"" but not used after the call");
      Parse_Table_Primary (Q, T, J + 1, L, Rel, N);
      pragma Warnings (GNATprove, On, "is set by ""Parse_Table_Primary"" but not used after the call");
      if N = 0 then
         return;
      end if;
      J := N;
      if Qualified then
         if Kw_In (T, J, L, Kw_On) then
            E := J + 1;
            while E <= L
              and then not Kind_In (T, E, L, Tk_Comma)
              and then not Is_Join_Start (T, E, L)
            loop
               pragma Loop_Invariant (E in J + 1 .. L);
               pragma Loop_Variant (Increases => E);
               N := Next_Unit (T, E, L);
               if N = 0 then
                  return;
               end if;
               E := N;
            end loop;
            if not Check_Expr (T, J + 1, E - 1, Allow_Using => False) then
               return;
            end if;
            J := E;
         elsif Kw_In (T, J, L, Kw_Using) then
            Close := Paren_Close (T, J + 1, L);
            if Close = 0 or else not Is_Name_List (T, J + 2, Close - 1) then
               return;
            end if;
            J := Close + 1;
         else
            return;
         end if;
      end if;
      Next := J;
   end Parse_Join;

   --  from_list = item {join} {, item {join}} covering F .. L exactly; Target is
   --  the first item's relation name (empty for subqueries and functions)
   procedure Check_From_List
     (Q      : in     Bounded_Text;
      T      : in     Token_List;
      F      : in     Positive;
      L      : in     Natural;
      Target :    out Bounded_Ident;
      OK     :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if OK then F <= L)
   is
      I     : Positive := F;
      N     : Natural;
      N2    : Natural;
      Rel   : Bounded_Ident;
      First : Boolean  := True;
   begin
      Target := Empty_Ident;
      OK     := False;
      while I <= L loop
         pragma Loop_Invariant (I in F .. L);
         pragma Loop_Variant (Increases => I);
         Parse_Table_Primary (Q, T, I, L, Rel, N);
         if N = 0 then
            return;
         end if;
         if First then
            Target := Rel;
            First  := False;
         end if;
         while N <= L and then Is_Join_Start (T, N, L) loop
            pragma Loop_Invariant (N in I + 1 .. L);
            pragma Loop_Variant (Increases => N);
            Parse_Join (Q, T, N, L, N2);
            if N2 = 0 then
               return;
            end if;
            N := N2;
         end loop;
         if N > L then
            OK := True;
            return;
         end if;
         if not Kind_In (T, N, L, Tk_Comma) or else N = L then
            return;
         end if;
         I := N + 1;
      end loop;
   end Check_From_List;

   --  Index of the first select-list token after SELECT (I is just after the
   --  SELECT key word): skips ALL | DISTINCT [ON (expr_list)]
   function Select_List_Start (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count and then I <= L + 1,
          Post   => Select_List_Start'Result = 0
                    or else Select_List_Start'Result in I .. L + 1
   is
      Close : Natural;
   begin
      if Kw_In (T, I, L, Kw_All) then
         return I + 1;
      elsif Kw_In (T, I, L, Kw_Distinct) then
         if Kw_In (T, I + 1, L, Kw_On) then
            Close := Paren_Close (T, I + 2, L);
            if Close = 0 or else Check_Expr_List (T, I + 3, Close - 1, False) = 0 then
               return 0;
            end if;
            return Close + 1;
         end if;
         return I + 1;
      end if;
      return I;
   end Select_List_Start;

   type Select_Clause is
     (Cl_Target, Cl_From, Cl_Where, Cl_Group, Cl_Having, Cl_Window, Cl_Order);

   --  Validate the body F .. L of one SELECT clause.  The select list of the
   --  first SELECT block sets Column_Count; later blocks (set operations) must
   --  have the same width; the first block's FROM sets Target.
   procedure Check_Select_Clause
     (Q    : in     Bounded_Text;
      T    : in     Token_List;
      Cl   : in     Select_Clause;
      F    : in     Positive;
      L    : in     Natural;
      Core : in     Positive;
      Info : in out Query_Info;
      OK   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count and then Limit_Info_OK (Info),
          Post   => Limit_Info_OK (Info)
                    and then (if Cl /= Cl_Target or else Core > 1
                              then Info.Column_Count = Info.Column_Count'Old)
                    and then (if OK and then Cl = Cl_Target then Info.Column_Count > 0)
   is
      N      : Natural;
      Target : Bounded_Ident;
   begin
      OK := False;
      case Cl is
         when Cl_Target =>
            N := Check_Expr_List (T, F, L, Allow_Using => False);
            if N = 0 then
               return;
            end if;
            if Core = 1 then
               Info.Column_Count := N;
            elsif N /= Info.Column_Count then
               return;
            end if;
         when Cl_From =>
            Check_From_List (Q, T, F, L, Target, OK);
            if not OK then
               return;
            end if;
            if Core = 1 then
               Info.Target := Target;
            end if;
         when Cl_Where | Cl_Having =>
            if not Check_Expr (T, F, L, Allow_Using => False) then
               return;
            end if;
         when Cl_Group | Cl_Window | Cl_Order =>
            if Check_Expr_List (T, F, L, Allow_Using => Cl = Cl_Order) = 0 then
               return;
            end if;
      end case;
      OK := True;
   end Check_Select_Clause;

   --  SELECT statement F .. L (F is SELECT):
   --    core { set_op core } [ORDER BY list] [tail]
   --    core   = SELECT [ALL | DISTINCT [ON (...)]] list [FROM from_list]
   --             [WHERE expr] [GROUP BY list] [HAVING expr] [WINDOW list]
   --    set_op = { UNION | INTERSECT | EXCEPT } [ALL | DISTINCT]
   --  Clause key words count only at the statement's own nesting level.
   procedure Check_Select
     (Q    : in     Bounded_Text;
      T    : in     Token_List;
      F    : in     Positive;
      L    : in     Natural;
      Info :    out Query_Info;
      OK   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => Limit_Info_OK (Info) and then (if OK then Info.Column_Count > 0)
   is
      Cur        : Select_Clause := Cl_Target;
      Core       : Positive      := 1;
      Body_Start : Natural;
      I          : Positive;
      Nxt        : Natural;
      New_Cl     : Select_Clause;
      Kw_Len     : Positive;
      Is_Clause  : Boolean;
      Is_Set_Op  : Boolean;
      Tail_Start : Natural       := 0;
      Cl_OK      : Boolean;
   begin
      Info := (others => <>);
      OK   := False;
      if not Kw_In (T, F, L, Kw_Select) then
         return;
      end if;
      Body_Start := Select_List_Start (T, F + 1, L);
      if Body_Start = 0 then
         return;
      end if;
      I := Body_Start;

      while I <= L loop
         pragma Loop_Invariant (I in F + 1 .. L);
         pragma Loop_Invariant (Body_Start in F + 1 .. I);
         pragma Loop_Invariant (Core <= I);
         pragma Loop_Invariant (Tail_Start = 0);
         pragma Loop_Invariant (Limit_Info_OK (Info));
         pragma Loop_Invariant (if Cur /= Cl_Target or else Core > 1
                                then Info.Column_Count > 0);
         pragma Loop_Variant (Increases => I);

         Is_Clause := False;
         Is_Set_Op := False;
         New_Cl    := Cur;
         Kw_Len    := 1;
         if T.Items (I).Kind = Tk_Word then
            case T.Items (I).Kw is
               when Kw_From =>
                  Is_Clause := not Is_Distinct_From (T, I);
                  New_Cl    := Cl_From;
               when Kw_Where =>
                  Is_Clause := True;
                  New_Cl    := Cl_Where;
               when Kw_Group =>
                  if Kw_In (T, I + 1, L, Kw_By) then
                     Is_Clause := True;
                     New_Cl    := Cl_Group;
                     Kw_Len    := 2;
                  end if;
               when Kw_Having =>
                  Is_Clause := True;
                  New_Cl    := Cl_Having;
               when Kw_Window =>
                  Is_Clause := True;
                  New_Cl    := Cl_Window;
               when Kw_Order =>
                  if not Kw_In (T, I + 1, L, Kw_By) then
                     return;
                  end if;
                  Is_Clause := True;
                  New_Cl    := Cl_Order;
                  Kw_Len    := 2;
               when Kw_Union | Kw_Intersect | Kw_Except =>
                  Is_Set_Op := True;
               when Kw_Limit | Kw_Offset | Kw_Fetch | Kw_For =>
                  Tail_Start := I;
               when others =>
                  null;
            end case;
         end if;

         exit when Tail_Start /= 0;

         if Is_Set_Op or else Is_Clause then
            Check_Select_Clause (Q, T, Cur, Body_Start, I - 1, Core, Info, Cl_OK);
            if not Cl_OK then
               return;
            end if;
         end if;

         if Is_Set_Op then
            if Cur = Cl_Order then
               return;
            end if;
            Nxt := I + 1;
            if Kw_In (T, Nxt, L, Kw_All) or else Kw_In (T, Nxt, L, Kw_Distinct) then
               Nxt := Nxt + 1;
            end if;
            if not Kw_In (T, Nxt, L, Kw_Select) then
               return;
            end if;
            Nxt := Select_List_Start (T, Nxt + 1, L);
            if Nxt = 0 then
               return;
            end if;
            Core       := Core + 1;
            Cur        := Cl_Target;
            Body_Start := Nxt;
            I          := Nxt;
         elsif Is_Clause then
            if New_Cl <= Cur then
               return;  --  duplicate or out-of-order clause
            end if;
            Cur        := New_Cl;
            Body_Start := I + Kw_Len;
            I          := I + Kw_Len;
         else
            Nxt := Next_Unit (T, I, L);
            if Nxt = 0 then
               return;
            end if;
            I := Nxt;
         end if;
      end loop;

      Check_Select_Clause
        (Q, T, Cur, Body_Start, (if Tail_Start /= 0 then Tail_Start - 1 else L),
         Core, Info, Cl_OK);
      if not Cl_OK then
         return;
      end if;
      if Tail_Start /= 0 then
         Parse_Tail (T, Tail_Start, L, Info, Cl_OK);
         if not Cl_OK then
            return;
         end if;
      end if;
      OK := True;
   end Check_Select;

   --  VALUES (expr_list) {, (expr_list)} starting at F (the VALUES key word);
   --  index after the last row
   function Values_Rows_End (T : Token_List; F : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => Values_Rows_End'Result = 0 or else Values_Rows_End'Result in F + 2 .. L + 1
   is
      I     : Positive := F + 1;
      Close : Natural;
   begin
      if not Kw_In (T, F, L, Kw_Values) then
         return 0;
      end if;
      loop
         pragma Loop_Invariant (I in F + 1 .. L + 1);
         pragma Loop_Variant (Increases => I);
         Close := Paren_Close (T, I, L);
         if Close = 0 or else Check_Expr_List (T, I + 1, Close - 1, False) = 0 then
            return 0;
         end if;
         if not Kind_In (T, Close + 1, L, Tk_Comma) then
            return Close + 1;
         end if;
         I := Close + 2;
      end loop;
   end Values_Rows_End;

   --  WITH [RECURSIVE] cte {, cte} with cte = name [(names)] AS [[NOT] MATERIALIZED]
   --  ( query ), where query starts with SELECT, WITH or VALUES (data-modifying
   --  CTEs are outside the dialect).  Returns the index of the main statement.
   function With_Clause_End (T : Token_List; F : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => With_Clause_End'Result = 0 or else With_Clause_End'Result in F + 1 .. L
   is
      I     : Positive := F + 1;
      Close : Natural;
   begin
      if not Kw_In (T, F, L, Kw_With) then
         return 0;
      end if;
      if Kw_In (T, I, L, Kw_Recursive) then
         I := I + 1;
      end if;
      loop
         pragma Loop_Invariant (I in F + 1 .. L + 1);
         pragma Loop_Variant (Increases => I);
         if not Name_In (T, I, L) then
            return 0;
         end if;
         I := I + 1;
         if Kind_In (T, I, L, Tk_LParen) then
            Close := Paren_Close (T, I, L);
            if Close = 0 or else not Is_Name_List (T, I + 1, Close - 1) then
               return 0;
            end if;
            I := Close + 1;
         end if;
         if not Kw_In (T, I, L, Kw_As) then
            return 0;
         end if;
         I := I + 1;
         if Kw_In (T, I, L, Kw_Not) then
            if not Kw_In (T, I + 1, L, Kw_Materialized) then
               return 0;
            end if;
            I := I + 2;
         elsif Kw_In (T, I, L, Kw_Materialized) then
            I := I + 1;
         end if;
         Close := Paren_Close (T, I, L);
         if Close = 0 or else not Starts_Query (T, I + 1, Close - 1) then
            return 0;
         end if;
         I := Close + 1;
         exit when not Kind_In (T, I, L, Tk_Comma);
         I := I + 1;
      end loop;
      if I > L then
         return 0;
      end if;
      return I;
   end With_Clause_End;

   --  [WITH ...] SELECT ... covering F .. L
   procedure Check_Query
     (Q    : in     Bounded_Text;
      T    : in     Token_List;
      F    : in     Positive;
      L    : in     Natural;
      Info :    out Query_Info;
      OK   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => Limit_Info_OK (Info) and then (if OK then Info.Column_Count > 0)
   is
      S : Natural := F;
   begin
      Info := (others => <>);
      OK   := False;
      if Kw_In (T, F, L, Kw_With) then
         S := With_Clause_End (T, F, L);
         if S = 0 then
            return;
         end if;
      end if;
      Check_Select (Q, T, S, L, Info, OK);
   end Check_Query;

   -------------------------------------------------------------------------
   --  INSERT / UPDATE / DELETE
   -------------------------------------------------------------------------

   --  target = expr {, target = expr} covering F .. L, where target starts with
   --  a column name or a parenthesized column list
   function Check_Assignments (T : Token_List; F : Positive; L : Natural) return Boolean
     with Global => null,
          Pre    => L <= T.Count,
          Post   => (if Check_Assignments'Result then F <= L)
   is
      S  : Positive := F;
      E  : Natural;
      Eq : Natural;
   begin
      if F > L then
         return False;
      end if;
      loop
         pragma Loop_Invariant (S in F .. L);
         pragma Loop_Variant (Increases => S);
         E := Find_Unit (T, S, L, Probe_Comma);
         if E = 0 then
            return False;
         end if;
         Eq := Find_Unit (T, S, E - 1, Probe_Equal);
         if Eq = 0 or else Eq >= E then
            return False;  --  item without "="
         end if;
         if not (Name_In (T, S, Eq - 1) or else Kind_In (T, S, Eq - 1, Tk_LParen))
           or else not Check_Expr (T, S, Eq - 1, Allow_Using => False)
           or else not Check_Expr (T, Eq + 1, E - 1, Allow_Using => False)
         then
            return False;
         end if;
         if E > L then
            return True;
         end if;
         if E = L then
            return False;  --  trailing comma
         end if;
         S := E + 1;
      end loop;
   end Check_Assignments;

   --  ON CONFLICT starts at I
   function Is_On_Conflict_At (T : Token_List; I : Natural; L : Natural) return Boolean is
     (Kw_In (T, I, L, Kw_On)
      and then Kw_In (T, I + 1, L, Kw_Conflict)
      and then (Kind_In (T, I + 2, L, Tk_LParen)
                or else Kw_In (T, I + 2, L, Kw_Do)
                or else Kw_In (T, I + 2, L, Kw_On)));

   --  ON CONFLICT [ (expr_list) [WHERE expr] | ON CONSTRAINT name ]
   --    DO { NOTHING | UPDATE SET assignments [WHERE expr] }
   --  (DO UPDATE requires a conflict target); index after the clause
   function On_Conflict_End (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => On_Conflict_End'Result = 0 or else On_Conflict_End'Result in I + 4 .. L + 1
   is
      J          : Positive := I + 2;
      Close      : Natural;
      E          : Natural;
      Has_Target : Boolean  := False;
   begin
      if not Is_On_Conflict_At (T, I, L) then
         return 0;
      end if;
      if Kind_In (T, J, L, Tk_LParen) then
         Close := Paren_Close (T, J, L);
         if Close = 0 or else Check_Expr_List (T, J + 1, Close - 1, False) = 0 then
            return 0;
         end if;
         J          := Close + 1;
         Has_Target := True;
         if Kw_In (T, J, L, Kw_Where) then
            E := Find_Unit (T, J + 1, L, Probe_Keywords, Kw_Do);
            if E = 0 or else not Check_Expr (T, J + 1, E - 1, Allow_Using => False) then
               return 0;
            end if;
            J := E;
         end if;
      elsif Kw_In (T, J, L, Kw_On) then
         if not Kw_In (T, J + 1, L, Kw_Constraint) or else not Name_In (T, J + 2, L) then
            return 0;
         end if;
         J          := J + 3;
         Has_Target := True;
      end if;
      if not Kw_In (T, J, L, Kw_Do) then
         return 0;
      end if;
      if Kw_In (T, J + 1, L, Kw_Nothing) then
         return J + 2;
      end if;
      if not Has_Target
        or else not Kw_In (T, J + 1, L, Kw_Update)
        or else not Kw_In (T, J + 2, L, Kw_Set)
      then
         return 0;
      end if;
      J := J + 3;
      E := Find_Unit (T, J, L, Probe_Keywords, Kw_Where, Kw_Returning);
      if E = 0 or else not Check_Assignments (T, J, E - 1) then
         return 0;
      end if;
      J := E;
      if Kw_In (T, J, L, Kw_Where) then
         E := Find_Unit (T, J + 1, L, Probe_Keywords, Kw_Returning);
         if E = 0 or else not Check_Expr (T, J + 1, E - 1, Allow_Using => False) then
            return 0;
         end if;
         J := E;
      end if;
      return J;
   end On_Conflict_End;

   --  End of an INSERT ... SELECT source: the first unit from I that starts
   --  ON CONFLICT or RETURNING, or L + 1
   function Insert_Source_End (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count and then I <= L,
          Post   => Insert_Source_End'Result = 0
                    or else Insert_Source_End'Result in I .. L + 1
   is
      J   : Positive := I;
      Nxt : Natural;
   begin
      while J <= L loop
         pragma Loop_Invariant (J in I .. L);
         pragma Loop_Variant (Increases => J);
         if Is_On_Conflict_At (T, J, L) or else Kw_At (T, J, Kw_Returning) then
            return J;
         end if;
         Nxt := Next_Unit (T, J, L);
         if Nxt = 0 then
            return 0;
         end if;
         J := Nxt;
      end loop;
      return J;
   end Insert_Source_End;

   --  INSERT INTO name [AS alias] [(names)]
   --    { DEFAULT VALUES | VALUES rows | [WITH ...] SELECT ... }
   --    [on_conflict] [RETURNING list]
   procedure Check_Insert
     (Q        : in     Bounded_Text;
      T        : in     Token_List;
      F        : in     Positive;
      L        : in     Natural;
      Info     :    out Query_Info;
      Conflict :    out Boolean;
      Ret      :    out Boolean;
      OK       :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => Limit_Info_OK (Info) and then (if OK then Info.Target.Length > 0)
   is
      Name  : Bounded_Ident;
      I     : Natural;
      Close : Natural;
      E     : Natural;
      Q_OK  : Boolean;
   begin
      Info     := (others => <>);
      Conflict := False;
      Ret      := False;
      OK       := False;
      if not Kw_In (T, F, L, Kw_Insert) or else not Kw_In (T, F + 1, L, Kw_Into) then
         return;
      end if;
      Parse_Qualified_Name (Q, T, F + 2, L, 2, Name, I);
      if I = 0 then
         return;
      end if;
      if Kw_In (T, I, L, Kw_As) then
         if not Name_In (T, I + 1, L) then
            return;
         end if;
         I := I + 2;
      end if;
      if Kind_In (T, I, L, Tk_LParen) then
         Close := Paren_Close (T, I, L);
         if Close = 0 or else not Is_Name_List (T, I + 1, Close - 1) then
            return;
         end if;
         I := Close + 1;
      end if;

      if Kw_In (T, I, L, Kw_Default) then
         if not Kw_In (T, I + 1, L, Kw_Values) then
            return;
         end if;
         I := I + 2;
      elsif Kw_In (T, I, L, Kw_Values) then
         I := Values_Rows_End (T, I, L);
         if I = 0 then
            return;
         end if;
      elsif Kw_In (T, I, L, Kw_Select) or else Kw_In (T, I, L, Kw_With) then
         E := Insert_Source_End (T, I, L);
         if E = 0 then
            return;
         end if;
         Check_Query (Q, T, I, E - 1, Info, Q_OK);
         if not Q_OK then
            return;
         end if;
         I := E;
      else
         return;
      end if;

      if Is_On_Conflict_At (T, I, L) then
         I := On_Conflict_End (T, I, L);
         if I = 0 then
            return;
         end if;
         Conflict := True;
      end if;
      if Kw_In (T, I, L, Kw_Returning) then
         if Check_Expr_List (T, I + 1, L, False) = 0 then
            return;
         end if;
         Ret := True;
         I   := L + 1;
      end if;
      if I <= L then
         return;
      end if;
      Info.Target       := Name;
      Info.Column_Count := 0;
      OK := True;
   end Check_Insert;

   --  UPDATE [ONLY] name [AS alias] SET assignments [FROM from_list]
   --    [WHERE expr] [RETURNING list]
   procedure Check_Update
     (Q      : in     Bounded_Text;
      T      : in     Token_List;
      F      : in     Positive;
      L      : in     Natural;
      Target :    out Bounded_Ident;
      Ret    :    out Boolean;
      OK     :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if OK then Target.Length > 0)
   is
      I     : Positive := F + 1;
      E     : Natural;
      Dummy : Bounded_Ident;
      pragma Warnings (Off, Dummy);
      F_OK  : Boolean;
   begin
      Target := Empty_Ident;
      Ret    := False;
      OK     := False;
      if not Kw_In (T, F, L, Kw_Update) then
         return;
      end if;
      if Kw_In (T, I, L, Kw_Only) then
         I := I + 1;
      end if;
      Parse_Qualified_Name (Q, T, I, L, 2, Target, E);
      if E = 0 then
         return;
      end if;
      I := E;
      if Kw_In (T, I, L, Kw_As) then
         if not Name_In (T, I + 1, L) then
            return;
         end if;
         I := I + 2;
      end if;
      if not Kw_In (T, I, L, Kw_Set) then
         return;
      end if;
      E := Find_Unit (T, I + 1, L, Probe_Keywords, Kw_From, Kw_Where, Kw_Returning);
      if E = 0 or else not Check_Assignments (T, I + 1, E - 1) then
         return;
      end if;
      I := E;
      if Kw_In (T, I, L, Kw_From) then
         E := Find_Unit (T, I + 1, L, Probe_Keywords, Kw_Where, Kw_Returning);
         if E = 0 then
            return;
         end if;
         pragma Warnings (GNATprove, Off, "is set by ""Check_From_List"" but not used after the call");
         Check_From_List (Q, T, I + 1, E - 1, Dummy, F_OK);
         pragma Warnings (GNATprove, On, "is set by ""Check_From_List"" but not used after the call");
         if not F_OK then
            return;
         end if;
         I := E;
      end if;
      if Kw_In (T, I, L, Kw_Where) then
         E := Find_Unit (T, I + 1, L, Probe_Keywords, Kw_Returning);
         if E = 0 or else not Check_Expr (T, I + 1, E - 1, Allow_Using => False) then
            return;
         end if;
         I := E;
      end if;
      if Kw_In (T, I, L, Kw_Returning) then
         if Check_Expr_List (T, I + 1, L, False) = 0 then
            return;
         end if;
         Ret := True;
         I   := L + 1;
      end if;
      OK := I > L;
   end Check_Update;

   --  DELETE FROM [ONLY] name [AS alias] [USING from_list] [WHERE expr]
   --    [RETURNING list]
   procedure Check_Delete
     (Q      : in     Bounded_Text;
      T      : in     Token_List;
      F      : in     Positive;
      L      : in     Natural;
      Target :    out Bounded_Ident;
      Ret    :    out Boolean;
      OK     :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if OK then Target.Length > 0)
   is
      I     : Positive := F + 2;
      E     : Natural;
      Dummy : Bounded_Ident;
      pragma Warnings (Off, Dummy);
      F_OK  : Boolean;
   begin
      Target := Empty_Ident;
      Ret    := False;
      OK     := False;
      if not Kw_In (T, F, L, Kw_Delete) or else not Kw_In (T, F + 1, L, Kw_From) then
         return;
      end if;
      if Kw_In (T, I, L, Kw_Only) then
         I := I + 1;
      end if;
      Parse_Qualified_Name (Q, T, I, L, 2, Target, E);
      if E = 0 then
         return;
      end if;
      I := E;
      if Kw_In (T, I, L, Kw_As) then
         if not Name_In (T, I + 1, L) then
            return;
         end if;
         I := I + 2;
      end if;
      if Kw_In (T, I, L, Kw_Using) then
         E := Find_Unit (T, I + 1, L, Probe_Keywords, Kw_Where, Kw_Returning);
         if E = 0 then
            return;
         end if;
         pragma Warnings (GNATprove, Off, "is set by ""Check_From_List"" but not used after the call");
         Check_From_List (Q, T, I + 1, E - 1, Dummy, F_OK);
         pragma Warnings (GNATprove, On, "is set by ""Check_From_List"" but not used after the call");
         if not F_OK then
            return;
         end if;
         I := E;
      end if;
      if Kw_In (T, I, L, Kw_Where) then
         E := Find_Unit (T, I + 1, L, Probe_Keywords, Kw_Returning);
         if E = 0 or else not Check_Expr (T, I + 1, E - 1, Allow_Using => False) then
            return;
         end if;
         I := E;
      end if;
      if Kw_In (T, I, L, Kw_Returning) then
         if Check_Expr_List (T, I + 1, L, False) = 0 then
            return;
         end if;
         Ret := True;
         I   := L + 1;
      end if;
      OK := I > L;
   end Check_Delete;

   -------------------------------------------------------------------------
   --  CREATE TABLE
   -------------------------------------------------------------------------

   procedure Append_Char
     (Res : in out Bounded_Ident;
      C   : in     Character;
      OK  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if OK then Res.Length = Res.Length'Old + 1)
   is
   begin
      OK := Res.Length < Max_Ident_Len;
      if OK then
         Res.Length := Res.Length + 1;
         Res.Data (Res.Length) := C;
      end if;
   end Append_Char;

   --  Append the raw source text of Tok to Res
   procedure Append_Raw
     (Q   : in     Bounded_Text;
      Tok : in     Token;
      Res : in out Bounded_Ident;
      OK  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if OK then Res.Length > Res.Length'Old)
   is
      Start_Len : constant Ident_Length := Res.Length;
   begin
      OK := False;
      if Tok.First > Tok.Last or else Tok.Last > Q.Length then
         return;
      end if;
      for J in Tok.First .. Tok.Last loop
         if Res.Length = Max_Ident_Len then
            return;
         end if;
         Res.Length := Res.Length + 1;
         Res.Data (Res.Length) := Q.Data (J);
      end loop;
      OK := Res.Length > Start_Len;
   end Append_Raw;

   --  Key words that start a column constraint
   function Is_Constraint_Start (K : Keyword_Id) return Boolean is
     (K in Kw_Constraint | Kw_Not | Kw_Null | Kw_Primary | Kw_Unique | Kw_Default
         | Kw_Check | Kw_References | Kw_Collate | Kw_Generated);

   --  Render the column type starting at I as canonical text for
   --  Resolve_Pg_Type: words joined by single spaces, an optional "(...)"
   --  modifier of numbers / commas / signs attached to the preceding word,
   --  then optional array suffixes "[]" / "[n]" (validated, not rendered).
   --  Next is the index after the type, or 0 when no valid type starts at I.
   procedure Render_Type
     (Q        : in     Bounded_Text;
      T        : in     Token_List;
      I        : in     Positive;
      L        : in     Natural;
      Type_Txt :    out Bounded_Ident;
      Next     :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if Next /= 0 then Next in I + 1 .. L + 1 and then Type_Txt.Length > 0)
   is
      J       : Positive := I;
      Close   : Natural;
      Has_Mod : Boolean  := False;
      Part_OK : Boolean;
   begin
      Type_Txt := Empty_Ident;
      Next     := 0;
      while J <= L loop
         pragma Loop_Invariant (J in I .. L);
         pragma Loop_Invariant ((J > I) = (Type_Txt.Length > 0));
         pragma Loop_Variant (Increases => J);
         if T.Items (J).Kind = Tk_Word and then not Is_Constraint_Start (T.Items (J).Kw) then
            if Type_Txt.Length > 0 then
               Append_Char (Type_Txt, ' ', Part_OK);
               if not Part_OK then
                  return;
               end if;
            end if;
            Append_Raw (Q, T.Items (J), Type_Txt, Part_OK);
            if not Part_OK then
               return;
            end if;
            J := J + 1;
         elsif T.Items (J).Kind = Tk_LParen and then not Has_Mod and then J > I then
            Close := Paren_Close (T, J, L);
            if Close = 0 then
               return;
            end if;
            Append_Char (Type_Txt, '(', Part_OK);
            if not Part_OK then
               return;
            end if;
            for K in J + 1 .. Close - 1 loop
               pragma Loop_Invariant (Type_Txt.Length > 0);
               if T.Items (K).Kind not in Tk_Number | Tk_Comma | Tk_Op then
                  return;
               end if;
               Append_Raw (Q, T.Items (K), Type_Txt, Part_OK);
               if not Part_OK then
                  return;
               end if;
            end loop;
            Append_Char (Type_Txt, ')', Part_OK);
            if not Part_OK then
               return;
            end if;
            Has_Mod := True;
            J       := Close + 1;
         else
            exit;
         end if;
      end loop;
      if J = I then
         return;
      end if;

      while J <= L and then T.Items (J).Kind = Tk_LBracket loop
         pragma Loop_Invariant (J in I + 1 .. L);
         pragma Loop_Invariant (Type_Txt.Length > 0);
         pragma Loop_Variant (Increases => J);
         Close := Bracket_Close (T, J, L);
         if Close = 0
           or else (Close /= J + 1
                    and then not (Close = J + 2
                                  and then T.Items (J + 1).Kind = Tk_Number
                                  and then T.Items (J + 1).Is_Int))
         then
            return;
         end if;
         J := Close + 1;
      end loop;
      Next := J;
   end Render_Type;

   --  NO ACTION | RESTRICT | CASCADE | SET NULL | SET DEFAULT at I
   function Ref_Action_End (T : Token_List; I : Natural; L : Natural) return Natural is
     (if Kw_In (T, I, L, Kw_No) and then Kw_In (T, I + 1, L, Kw_Action) then I + 2
      elsif Kw_In (T, I, L, Kw_Restrict) or else Kw_In (T, I, L, Kw_Cascade) then I + 1
      elsif Kw_In (T, I, L, Kw_Set)
        and then (Kw_In (T, I + 1, L, Kw_Null) or else Kw_In (T, I + 1, L, Kw_Default))
      then I + 2
      else 0);

   --  qualified_name [(names)] [ON DELETE action] [ON UPDATE action] (either
   --  order, each at most once) starting at I, after the REFERENCES key word
   function References_End (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => References_End'Result = 0 or else References_End'Result in I + 1 .. L + 1
   is
      N        : Natural := Qualified_Name_End (T, I, L, 2);
      Close    : Natural;
      A        : Natural;
      Seen_Del : Boolean := False;
      Seen_Upd : Boolean := False;
   begin
      if N = 0 then
         return 0;
      end if;
      if Kind_In (T, N, L, Tk_LParen) then
         Close := Paren_Close (T, N, L);
         if Close = 0 or else not Is_Name_List (T, N + 1, Close - 1) then
            return 0;
         end if;
         N := Close + 1;
      end if;
      for Step in 1 .. 2 loop
         pragma Loop_Invariant (N in I + 1 .. L + 1);
         exit when not Kw_In (T, N, L, Kw_On);
         if Kw_In (T, N + 1, L, Kw_Delete) and then not Seen_Del then
            Seen_Del := True;
         elsif Kw_In (T, N + 1, L, Kw_Update) and then not Seen_Upd then
            Seen_Upd := True;
         else
            return 0;
         end if;
         A := Ref_Action_End (T, N + 2, L);
         if A = 0 then
            return 0;
         end if;
         N := A;
      end loop;
      return N;
   end References_End;

   --  End of the column constraint starting at I:
   --    [CONSTRAINT name] { NOT NULL | NULL | PRIMARY KEY | UNIQUE | DEFAULT expr
   --    | CHECK (expr) | REFERENCES ... | COLLATE name
   --    | GENERATED ALWAYS AS (expr) STORED
   --    | GENERATED { ALWAYS | BY DEFAULT } AS IDENTITY }
   function Column_Constraint_End (T : Token_List; I : Positive; L : Natural) return Natural
     with Global => null,
          Pre    => L <= T.Count,
          Post   => Column_Constraint_End'Result = 0
                    or else Column_Constraint_End'Result in I + 1 .. L + 1
   is
      J     : Positive := I;
      Close : Natural;
      E     : Natural;
      N     : Natural;
   begin
      if Kw_In (T, I, L, Kw_Constraint) then
         if not Name_In (T, I + 1, L) then
            return 0;
         end if;
         J := I + 2;
      end if;
      if J > L or else T.Items (J).Kind /= Tk_Word then
         return 0;
      end if;
      case T.Items (J).Kw is
         when Kw_Not =>
            return (if Kw_In (T, J + 1, L, Kw_Null) then J + 2 else 0);
         when Kw_Null | Kw_Unique =>
            return J + 1;
         when Kw_Primary =>
            return (if Kw_In (T, J + 1, L, Kw_Key) then J + 2 else 0);
         when Kw_Default =>
            --  b_expr: the first unit is always part of it (DEFAULT NULL), and it
            --  stops before the next column-constraint key word
            if J + 1 > L then
               return 0;
            end if;
            E := Next_Unit (T, J + 1, L);
            if E = 0 then
               return 0;
            end if;
            while E <= L
              and then not (T.Items (E).Kind = Tk_Word
                            and then Is_Constraint_Start (T.Items (E).Kw))
            loop
               pragma Loop_Invariant (E in J + 2 .. L);
               pragma Loop_Variant (Increases => E);
               N := Next_Unit (T, E, L);
               if N = 0 then
                  return 0;
               end if;
               E := N;
            end loop;
            if not Check_Expr (T, J + 1, E - 1, Allow_Using => False) then
               return 0;
            end if;
            return E;
         when Kw_Check =>
            Close := Paren_Close (T, J + 1, L);
            if Close = 0 or else not Check_Expr (T, J + 2, Close - 1, Allow_Using => False) then
               return 0;
            end if;
            return Close + 1;
         when Kw_References =>
            return (if J < L then References_End (T, J + 1, L) else 0);
         when Kw_Collate =>
            return (if J < L then Qualified_Name_End (T, J + 1, L, 2) else 0);
         when Kw_Generated =>
            if Kw_In (T, J + 1, L, Kw_Always) and then Kw_In (T, J + 2, L, Kw_As) then
               if Kw_In (T, J + 3, L, Kw_Identity) then
                  return J + 4;
               end if;
               Close := Paren_Close (T, J + 3, L);
               if Close = 0
                 or else not Check_Expr (T, J + 4, Close - 1, Allow_Using => False)
                 or else not Kw_In (T, Close + 1, L, Kw_Stored)
               then
                  return 0;
               end if;
               return Close + 2;
            elsif Kw_In (T, J + 1, L, Kw_By)
              and then Kw_In (T, J + 2, L, Kw_Default)
              and then Kw_In (T, J + 3, L, Kw_As)
              and then Kw_In (T, J + 4, L, Kw_Identity)
            then
               return J + 5;
            end if;
            return 0;
         when others =>
            return 0;
      end case;
   end Column_Constraint_End;

   --  Table constraint covering exactly F .. L:
   --    [CONSTRAINT name] { PRIMARY KEY (names) | UNIQUE (names) | CHECK (expr)
   --    | FOREIGN KEY (names) REFERENCES ... }
   function Is_Table_Constraint (T : Token_List; F : Positive; L : Natural) return Boolean
     with Global => null,
          Pre    => L <= T.Count,
          Post   => (if Is_Table_Constraint'Result then F < L)
   is
      J     : Positive := F;
      Close : Natural;
      E     : Natural;
   begin
      if Kw_In (T, F, L, Kw_Constraint) then
         if not Name_In (T, F + 1, L) then
            return False;
         end if;
         J := F + 2;
      end if;
      if Kw_In (T, J, L, Kw_Primary) and then Kw_In (T, J + 1, L, Kw_Key) then
         Close := Paren_Close (T, J + 2, L);
         if Close = 0 or else not Is_Name_List (T, J + 3, Close - 1) then
            return False;
         end if;
         E := Close + 1;
      elsif Kw_In (T, J, L, Kw_Unique) then
         Close := Paren_Close (T, J + 1, L);
         if Close = 0 or else not Is_Name_List (T, J + 2, Close - 1) then
            return False;
         end if;
         E := Close + 1;
      elsif Kw_In (T, J, L, Kw_Check) then
         Close := Paren_Close (T, J + 1, L);
         if Close = 0 or else not Check_Expr (T, J + 2, Close - 1, Allow_Using => False) then
            return False;
         end if;
         E := Close + 1;
      elsif Kw_In (T, J, L, Kw_Foreign) and then Kw_In (T, J + 1, L, Kw_Key) then
         Close := Paren_Close (T, J + 2, L);
         if Close = 0
           or else not Is_Name_List (T, J + 3, Close - 1)
           or else not Kw_In (T, Close + 1, L, Kw_References)
           or else Close + 1 >= L
         then
            return False;
         end if;
         E := References_End (T, Close + 2, L);
      else
         return False;
      end if;
      return E = L + 1;
   end Is_Table_Constraint;

   --  Column definition covering exactly F .. L: name type {column_constraint}
   function Is_Column_Def
     (Q : Bounded_Text;
      T : Token_List;
      F : Positive;
      L : Natural) return Boolean
     with Global => null,
          Pre    => L <= T.Count,
          Post   => (if Is_Column_Def'Result then F < L)
   is
      Col_Name : Bounded_Ident := Empty_Ident;
      Type_Txt : Bounded_Ident;
      Next     : Natural;
      J        : Positive;
      N        : Natural;
      Name_OK  : Boolean;
      Resolved : Pg_Data_Type;
      pragma Warnings (Off, Resolved);
      Valid    : Boolean;
   begin
      if not Name_In (T, F, L) then
         return False;
      end if;
      --  Only the length check matters: names over Max_Ident_Len are rejected
      pragma Warnings (GNATprove, Off, "is set by ""Append_Name"" but not used after the call");
      Append_Name (Q, T.Items (F), Col_Name, Name_OK);
      pragma Warnings (GNATprove, On, "is set by ""Append_Name"" but not used after the call");
      if not Name_OK then
         return False;
      end if;
      Render_Type (Q, T, F + 1, L, Type_Txt, Next);
      if Next = 0 then
         return False;
      end if;
      pragma Warnings (GNATprove, Off, "is set by ""Resolve_Pg_Type"" but not used after the call");
      Resolve_Pg_Type (Type_Txt, Resolved, Valid);
      pragma Warnings (GNATprove, On, "is set by ""Resolve_Pg_Type"" but not used after the call");
      if not Valid then
         return False;
      end if;
      J := Next;
      while J <= L loop
         pragma Loop_Invariant (J in F + 2 .. L);
         pragma Loop_Variant (Increases => J);
         N := Column_Constraint_End (T, J, L);
         if N = 0 then
            return False;
         end if;
         J := N;
      end loop;
      return True;
   end Is_Column_Def;

   --  CREATE [TEMP | TEMPORARY | UNLOGGED] TABLE [IF NOT EXISTS] name
   --    ( element {, element} ) covering 1 .. L, element = column_def |
   --  table_constraint, with at least one column definition
   procedure Check_Create_Table
     (Q       : in     Bounded_Text;
      T       : in     Token_List;
      L       : in     Natural;
      Name    :    out Bounded_Ident;
      Columns :    out Natural;
      OK      :    out Boolean)
     with Global => null,
          Always_Terminates,
          Pre    => L <= T.Count,
          Post   => (if OK then Name.Length > 0 and then Columns > 0)
   is
      I     : Positive := 2;
      E     : Natural;
      Close : Natural;
      S     : Positive;
      Sep   : Natural;
   begin
      Name    := Empty_Ident;
      Columns := 0;
      OK      := False;
      if not Kw_In (T, 1, L, Kw_Create) then
         return;
      end if;
      if Kw_In (T, I, L, Kw_Temp)
        or else Kw_In (T, I, L, Kw_Temporary)
        or else Kw_In (T, I, L, Kw_Unlogged)
      then
         I := I + 1;
      end if;
      if not Kw_In (T, I, L, Kw_Table) then
         return;
      end if;
      I := I + 1;
      if Kw_In (T, I, L, Kw_If)
        and then Kw_In (T, I + 1, L, Kw_Not)
        and then Kw_In (T, I + 2, L, Kw_Exists)
      then
         I := I + 3;
      end if;
      Parse_Qualified_Name (Q, T, I, L, 2, Name, E);
      if E = 0 then
         return;
      end if;
      Close := Paren_Close (T, E, L);
      if Close /= L or else Close <= E + 1 then
         return;  --  the element list must be non-empty and end the statement
      end if;
      S := E + 1;
      loop
         pragma Loop_Invariant (S in E + 1 .. Close - 1);
         pragma Loop_Invariant (Columns < S);
         pragma Loop_Variant (Increases => S);
         Sep := Find_Unit (T, S, Close - 1, Probe_Comma);
         if Sep = 0 or else Sep = S then
            return;
         end if;
         if Kw_At (T, S, Kw_Constraint)
           or else Kw_At (T, S, Kw_Primary)
           or else Kw_At (T, S, Kw_Unique)
           or else Kw_At (T, S, Kw_Check)
           or else Kw_At (T, S, Kw_Foreign)
         then
            if not Is_Table_Constraint (T, S, Sep - 1) then
               return;
            end if;
         else
            if not Is_Column_Def (Q, T, S, Sep - 1) then
               return;
            end if;
            Columns := Columns + 1;
         end if;
         exit when Sep >= Close;
         if Sep + 1 >= Close then
            return;  --  trailing comma
         end if;
         S := Sep + 1;
      end loop;
      OK := Columns > 0;
   end Check_Create_Table;

   -------------------------------------------------------------------------
   --  Statement-level checks and descriptor flags
   -------------------------------------------------------------------------

   --  BEGIN | COMMIT | ROLLBACK [TRANSACTION | WORK] covering 1 .. L
   function Is_Tx_Control (T : Token_List; L : Natural) return Boolean is
     ((Kw_At (T, 1, Kw_Begin) or else Kw_At (T, 1, Kw_Commit) or else Kw_At (T, 1, Kw_Rollback))
      and then (L = 1
                or else (L = 2
                         and then (Kw_At (T, 2, Kw_Transaction) or else Kw_At (T, 2, Kw_Work)))));

   --  A "(" directly followed by INSERT / UPDATE / DELETE at token I
   function Paren_Before_DML (T : Token_List; I : Natural) return Boolean is
     (I in 1 .. T.Count - 1
      and then T.Items (I).Kind = Tk_LParen
      and then T.Items (I + 1).Kind = Tk_Word
      and then T.Items (I + 1).Kw in Kw_Insert | Kw_Update | Kw_Delete);

   --  Validate every parenthesized query block "( SELECT | WITH | VALUES ... )"
   --  (subqueries, derived tables, CTE bodies) at its own nesting level, and
   --  reject data-modifying statements inside parentheses
   function Nested_Queries_Valid (Q : Bounded_Text; T : Token_List) return Boolean
     with Global => null,
          Post   => (if Nested_Queries_Valid'Result
                     then (for all J in 1 .. T.Count => not Paren_Before_DML (T, J)))
   is
      Info  : Query_Info;
      pragma Warnings (Off, Info);
      OK    : Boolean;
      Close : Natural;
   begin
      for I in 1 .. T.Count loop
         pragma Loop_Invariant (for all J in 1 .. I - 1 => not Paren_Before_DML (T, J));
         if Paren_Before_DML (T, I) then
            return False;
         end if;
         if T.Items (I).Kind = Tk_LParen and then Starts_Query (T, I + 1, T.Count) then
            Close := Paren_Close (T, I, T.Count);
            if Close <= I + 1 then
               return False;
            end if;
            if Kw_At (T, I + 1, Kw_Values) then
               if Values_Rows_End (T, I + 1, Close - 1) /= Close then
                  return False;
               end if;
            else
               pragma Warnings (GNATprove, Off, "is set by ""Check_Query"" but not used after the call");
               Check_Query (Q, T, I + 1, Close - 1, Info, OK);
               pragma Warnings (GNATprove, On, "is set by ""Check_Query"" but not used after the call");
               if not OK then
                  return False;
               end if;
            end if;
         end if;
      end loop;
      return True;
   end Nested_Queries_Valid;

   --  Some token in 1 .. Last has kind K
   function Has_Kind (T : Token_List; K : Tok_Kind; Last : Natural) return Boolean
     with Global => null,
          Pre    => Last <= T.Count,
          Post   => Has_Kind'Result = (for some J in 1 .. Last => T.Items (J).Kind = K)
   is
   begin
      for I in 1 .. Last loop
         pragma Loop_Invariant (for all J in 1 .. I - 1 => T.Items (J).Kind /= K);
         if T.Items (I).Kind = K then
            return True;
         end if;
      end loop;
      return False;
   end Has_Kind;

   --  Some operator token is classified in Lo .. Hi
   function Has_Op (T : Token_List; Lo, Hi : Op_Kind) return Boolean
     with Global => null,
          Post   => Has_Op'Result =
                      (for some J in 1 .. T.Count =>
                         T.Items (J).Kind = Tk_Op and then T.Items (J).Op in Lo .. Hi)
   is
   begin
      for I in 1 .. T.Count loop
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 =>
              not (T.Items (J).Kind = Tk_Op and then T.Items (J).Op in Lo .. Hi));
         if T.Items (I).Kind = Tk_Op and then T.Items (I).Op in Lo .. Hi then
            return True;
         end if;
      end loop;
      return False;
   end Has_Op;

   --  Key word K occurs outside all parentheses / brackets
   function Has_Top_Keyword (T : Token_List; K : Keyword_Id) return Boolean
     with Global => null,
          Post   => Has_Top_Keyword'Result =
                      (for some J in 1 .. T.Count =>
                         T.Items (J).Kind = Tk_Word
                         and then T.Items (J).Kw = K
                         and then T.Items (J).Depth = 0)
   is
   begin
      for I in 1 .. T.Count loop
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 =>
              not (T.Items (J).Kind = Tk_Word
                   and then T.Items (J).Kw = K
                   and then T.Items (J).Depth = 0));
         if T.Items (I).Kind = Tk_Word
           and then T.Items (I).Kw = K
           and then T.Items (I).Depth = 0
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Top_Keyword;

   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
   is
      T        : Token_List;
      Lex_OK   : Boolean;
      Last     : Natural;
      Start    : Natural := 1;
      Info     : Query_Info := (others => <>);
      OK       : Boolean := False;
      Conflict : Boolean := False;
      Ret      : Boolean := False;
      Name     : Bounded_Ident;
      Columns  : Natural;
      Next     : Natural;
      Kind     : SQL_Statement_Kind := Stmt_Unknown;
   begin
      Result := (others => <>);
      Status := Status_Invalid_Syntax;
      if Query.Length = 0 then
         return;
      end if;

      Tokenize (Query, T, Lex_OK);
      if not Lex_OK or else T.Count = 0 then
         return;
      end if;

      --  Exactly one statement: a ';' may only be the final token
      Last := T.Count;
      if T.Items (Last).Kind = Tk_Semicolon then
         Last := Last - 1;
      end if;
      if Last = 0 or else Has_Kind (T, Tk_Semicolon, Last) then
         return;
      end if;

      if Kw_At (T, 1, Kw_With) then
         Start := With_Clause_End (T, 1, Last);
         if Start = 0 then
            return;
         end if;
      end if;

      if Kw_At (T, Start, Kw_Select) then
         Check_Select (Query, T, Start, Last, Info, OK);
         Kind := Stmt_Select;
      elsif Kw_At (T, Start, Kw_Insert) then
         Check_Insert (Query, T, Start, Last, Info, Conflict, Ret, OK);
         Kind := Stmt_Insert;
      elsif Kw_At (T, Start, Kw_Update) then
         Check_Update (Query, T, Start, Last, Info.Target, Ret, OK);
         Kind := Stmt_Update;
      elsif Kw_At (T, Start, Kw_Delete) then
         Check_Delete (Query, T, Start, Last, Info.Target, Ret, OK);
         Kind := Stmt_Delete;
      elsif Start /= 1 then
         return;  --  WITH must introduce SELECT / INSERT / UPDATE / DELETE
      elsif Kw_At (T, 1, Kw_Create) then
         Check_Create_Table (Query, T, Last, Name, Columns, OK);
         Info.Target       := Name;
         Info.Column_Count := Columns;
         Kind := Stmt_Create_Table;
      elsif Is_Tx_Control (T, Last) then
         OK   := True;
         Kind := (if Kw_At (T, 1, Kw_Begin) then Stmt_Begin
                  elsif Kw_At (T, 1, Kw_Commit) then Stmt_Commit
                  else Stmt_Rollback);
      elsif Kw_At (T, 1, Kw_Listen) or else Kw_At (T, 1, Kw_Notify) then
         Parse_Qualified_Name (Query, T, 2, Last, 2, Info.Target, Next);
         if Kw_At (T, 1, Kw_Listen) then
            OK   := Next = Last + 1;
            Kind := Stmt_Listen;
         else
            OK   := Next /= 0
                    and then (Next = Last + 1
                              or else (Next + 1 = Last
                                       and then T.Items (Next).Kind = Tk_Comma
                                       and then T.Items (Last).Kind in
                                                  Tk_String | Tk_E_String | Tk_Dollar_String));
            Kind := Stmt_Notify;
         end if;
      else
         return;
      end if;

      if not OK or else not Nested_Queries_Valid (Query, T) then
         return;
      end if;

      Result.Kind                 := Kind;
      Result.Table_Or_Target      := Info.Target;
      Result.Column_Count         := Info.Column_Count;
      Result.Has_Where            := Has_Top_Keyword (T, Kw_Where);
      Result.Has_Order_By         := Has_Top_Keyword (T, Kw_Order);
      Result.Has_Limit            := Info.Has_Limit;
      Result.Limit_Value          := Info.Limit_Value;
      Result.Has_Param_Limit      := Info.Has_Param_Limit;
      Result.Has_Offset           := Info.Has_Offset;
      Result.Offset_Value         := Info.Offset_Value;
      Result.Has_Param_Offset     := Info.Has_Param_Offset;
      Result.Has_Positional_Param := Has_Kind (T, Tk_Param, T.Count);
      Result.Has_Pg_Type_Cast     := Has_Kind (T, Tk_Cast, T.Count);
      Result.Has_Vector_Operator  := Has_Op (T, Vector_Op'First, Vector_Op'Last);
      Result.Has_JSONB_Operator   := Has_Op (T, JSONB_Op'First, JSONB_Op'Last);
      Result.Has_Upsert_Conflict  := Conflict;
      Result.Has_Returning        := Ret;
      Status := Status_Ok;
   end Analyze_SQL;

   -------------------------------------------------------------------------
   --  Type resolution
   -------------------------------------------------------------------------

   type Word_Firsts is array (1 .. 4) of Ident_Index;
   type Word_Lens   is array (1 .. 4) of Ident_Length;

   --  A type name split into up to four words and one "(n [, m])" modifier
   type Type_Shape is record
      N_Words   : Natural range 0 .. 4 := 0;
      First     : Word_Firsts          := [others => 1];
      Len       : Word_Lens            := [others => 0];
      Mod_After : Natural range 0 .. 4 := 0;   --  word followed by the modifier
      N_Args    : Natural range 0 .. 2 := 0;
      Arg1      : Natural              := 0;
      Arg2      : Natural              := 0;
   end record;

   --  Unsigned decimal integer at I (after optional whitespace); Next is the
   --  index after it and any following whitespace, 0 when none or on overflow
   procedure Scan_Type_Arg
     (S     : in     Bounded_Ident;
      I     : in     Positive;
      Value :    out Natural;
      Next  :    out Natural)
     with Global => null,
          Always_Terminates,
          Post   => (if Next /= 0 then Next in I + 1 .. S.Length + 1)
   is
      J     : Positive := I;
      Seen  : Boolean  := False;
      Digit : Natural;
   begin
      Value := 0;
      Next  := 0;
      while J <= S.Length and then Is_WS_Char (S.Data (J)) loop
         pragma Loop_Invariant (J in I .. S.Length);
         pragma Loop_Variant (Increases => J);
         J := J + 1;
      end loop;
      while J <= S.Length and then Is_Digit (S.Data (J)) loop
         pragma Loop_Invariant (J in I .. S.Length);
         pragma Loop_Invariant (if Seen then J > I);
         pragma Loop_Variant (Increases => J);
         Digit := Character'Pos (S.Data (J)) - Character'Pos ('0');
         if Value > (Natural'Last - Digit) / 10 then
            Value := 0;
            return;
         end if;
         Value := Value * 10 + Digit;
         Seen  := True;
         J     := J + 1;
      end loop;
      if not Seen then
         Value := 0;
         return;
      end if;
      while J <= S.Length and then Is_WS_Char (S.Data (J)) loop
         pragma Loop_Invariant (J in I + 1 .. S.Length);
         pragma Loop_Variant (Increases => J);
         J := J + 1;
      end loop;
      Next := J;
   end Scan_Type_Arg;

   --  Split S into words ([A-Za-z][A-Za-z0-9_]*, separated by whitespace) and
   --  at most one modifier "( n [, m] )" that follows a word
   procedure Split_Type
     (S     : in     Bounded_Ident;
      Shape :    out Type_Shape;
      OK    :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if OK then Shape.N_Words >= 1
                              and then Shape.Mod_After <= Shape.N_Words
                              and then (Shape.Mod_After = 0) = (Shape.N_Args = 0))
   is
      I    : Positive := 1;
      J    : Positive;
      N    : Natural;
      Arg  : Natural;
   begin
      Shape := (others => <>);
      OK    := False;
      while I <= S.Length loop
         pragma Loop_Invariant (I in 1 .. S.Length);
         pragma Loop_Invariant (Shape.Mod_After <= Shape.N_Words);
         pragma Loop_Invariant ((Shape.Mod_After = 0) = (Shape.N_Args = 0));
         pragma Loop_Variant (Increases => I);
         if Is_WS_Char (S.Data (I)) then
            I := I + 1;
         elsif S.Data (I) in 'a' .. 'z' | 'A' .. 'Z' then
            if Shape.N_Words = 4 then
               return;
            end if;
            J := I;
            while J < S.Length
              and then S.Data (J + 1) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'
            loop
               pragma Loop_Invariant (J in I .. S.Length - 1);
               pragma Loop_Variant (Increases => J);
               J := J + 1;
            end loop;
            Shape.N_Words := Shape.N_Words + 1;
            Shape.First (Shape.N_Words) := I;
            Shape.Len (Shape.N_Words)   := J - I + 1;
            I := J + 1;
         elsif S.Data (I) = '(' and then Shape.N_Words > 0 and then Shape.Mod_After = 0 then
            Scan_Type_Arg (S, I + 1, Arg, N);
            if N = 0 then
               return;
            end if;
            Shape.Arg1   := Arg;
            Shape.N_Args := 1;
            if N <= S.Length and then S.Data (N) = ',' then
               Scan_Type_Arg (S, N + 1, Arg, N);
               if N = 0 then
                  return;
               end if;
               Shape.Arg2   := Arg;
               Shape.N_Args := 2;
            end if;
            if N > S.Length or else S.Data (N) /= ')' then
               return;
            end if;
            Shape.Mod_After := Shape.N_Words;
            I := N + 1;
         else
            return;
         end if;
      end loop;
      OK := Shape.N_Words >= 1;
   end Split_Type;

   --  Word K of Shape equals Word (case-insensitive)
   function Word_Is
     (S     : Bounded_Ident;
      Shape : Type_Shape;
      K     : Positive;
      Word  : String) return Boolean
     with Global => null,
          Post   => (if Word_Is'Result then K <= Shape.N_Words)
   is
      F : Natural;
      N : Natural;
   begin
      if K > Shape.N_Words then
         return False;
      end if;
      F := Shape.First (K);
      N := Shape.Len (K);
      if N = 0 or else N /= Word'Length or else F > S.Length or else N > S.Length - F + 1 then
         return False;
      end if;
      for J in 0 .. N - 1 loop
         if To_Lower_Char (S.Data (F + J)) /= To_Lower_Char (Word (Word'First + J)) then
            return False;
         end if;
      end loop;
      return True;
   end Word_Is;

   procedure Resolve_Pg_Type
     (Type_Keyword : in     Bounded_Ident;
      Resolved     :    out Pg_Data_Type;
      Valid        :    out Boolean)
   is
      S     : Bounded_Ident renames Type_Keyword;
      Shape : Type_Shape;
      OK    : Boolean;
   begin
      Resolved := Pg_Text;
      Valid    := False;
      if Type_Keyword.Length = 0 then
         return;
      end if;
      Split_Type (S, Shape, OK);
      if not OK then
         return;
      end if;

      if Shape.N_Words = 1 and then Shape.Mod_After = 0 then
         Valid := True;
         if Word_Is (S, Shape, 1, "SMALLINT") or else Word_Is (S, Shape, 1, "INT2") then
            Resolved := Pg_Smallint;
         elsif Word_Is (S, Shape, 1, "INTEGER")
           or else Word_Is (S, Shape, 1, "INT4")
           or else Word_Is (S, Shape, 1, "INT")
         then
            Resolved := Pg_Integer;
         elsif Word_Is (S, Shape, 1, "BIGINT") or else Word_Is (S, Shape, 1, "INT8") then
            Resolved := Pg_Bigint;
         elsif Word_Is (S, Shape, 1, "REAL") or else Word_Is (S, Shape, 1, "FLOAT4") then
            Resolved := Pg_Real;
         elsif Word_Is (S, Shape, 1, "FLOAT8") or else Word_Is (S, Shape, 1, "FLOAT") then
            Resolved := Pg_Double_Precision;
         elsif Word_Is (S, Shape, 1, "NUMERIC") or else Word_Is (S, Shape, 1, "DECIMAL") then
            Resolved := Pg_Numeric;
         elsif Word_Is (S, Shape, 1, "BOOLEAN") or else Word_Is (S, Shape, 1, "BOOL") then
            Resolved := Pg_Boolean;
         elsif Word_Is (S, Shape, 1, "TEXT") or else Word_Is (S, Shape, 1, "VARCHAR") then
            Resolved := Pg_Text;
         elsif Word_Is (S, Shape, 1, "BYTEA") then
            Resolved := Pg_Bytea;
         elsif Word_Is (S, Shape, 1, "UUID") then
            Resolved := Pg_UUID;
         elsif Word_Is (S, Shape, 1, "TIMESTAMPTZ") or else Word_Is (S, Shape, 1, "TIMESTAMP") then
            Resolved := Pg_Timestamptz;
         elsif Word_Is (S, Shape, 1, "JSON") then
            Resolved := Pg_JSON;
         elsif Word_Is (S, Shape, 1, "JSONB") then
            Resolved := Pg_JSONB;
         elsif Word_Is (S, Shape, 1, "VECTOR") then
            Resolved := Pg_Vector;
         else
            Valid := False;
         end if;

      elsif Shape.N_Words = 1 then
         --  Modifier after the single word
         if (Word_Is (S, Shape, 1, "NUMERIC") or else Word_Is (S, Shape, 1, "DECIMAL"))
           and then Shape.Arg1 in 1 .. 38
           and then (Shape.N_Args = 1 or else Shape.Arg2 <= Shape.Arg1)
         then
            Resolved := Pg_Numeric;
            Valid    := True;
         elsif Shape.N_Args /= 1 then
            null;
         elsif Word_Is (S, Shape, 1, "VARCHAR") and then Shape.Arg1 in 1 .. 10_485_760 then
            Resolved := Pg_Text;
            Valid    := True;
         elsif Word_Is (S, Shape, 1, "VECTOR") and then Shape.Arg1 in 1 .. 4096 then
            Resolved := Pg_Vector;
            Valid    := True;
         elsif Word_Is (S, Shape, 1, "FLOAT") and then Shape.Arg1 in 1 .. 24 then
            Resolved := Pg_Real;
            Valid    := True;
         elsif Word_Is (S, Shape, 1, "FLOAT") and then Shape.Arg1 in 25 .. 53 then
            Resolved := Pg_Double_Precision;
            Valid    := True;
         elsif (Word_Is (S, Shape, 1, "TIMESTAMP") or else Word_Is (S, Shape, 1, "TIMESTAMPTZ"))
           and then Shape.Arg1 <= 6
         then
            Resolved := Pg_Timestamptz;
            Valid    := True;
         end if;

      elsif Shape.N_Words = 2 then
         if Word_Is (S, Shape, 1, "DOUBLE")
           and then Word_Is (S, Shape, 2, "PRECISION")
           and then Shape.Mod_After = 0
         then
            Resolved := Pg_Double_Precision;
            Valid    := True;
         elsif (Word_Is (S, Shape, 1, "CHARACTER") or else Word_Is (S, Shape, 1, "CHAR"))
           and then Word_Is (S, Shape, 2, "VARYING")
           and then (Shape.Mod_After = 0
                     or else (Shape.Mod_After = 2
                              and then Shape.N_Args = 1
                              and then Shape.Arg1 in 1 .. 10_485_760))
         then
            Resolved := Pg_Text;
            Valid    := True;
         end if;

      elsif Shape.N_Words = 4 then
         if Word_Is (S, Shape, 1, "TIMESTAMP")
           and then (Word_Is (S, Shape, 2, "WITH") or else Word_Is (S, Shape, 2, "WITHOUT"))
           and then Word_Is (S, Shape, 3, "TIME")
           and then Word_Is (S, Shape, 4, "ZONE")
           and then (Shape.Mod_After = 0
                     or else (Shape.Mod_After = 1
                              and then Shape.N_Args = 1
                              and then Shape.Arg1 <= 6))
         then
            Resolved := Pg_Timestamptz;
            Valid    := True;
         end if;
      end if;

      if not Valid then
         Resolved := Pg_Text;
      end if;
   end Resolve_Pg_Type;

end Nhe_O.SQL;
