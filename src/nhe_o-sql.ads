--  Formally verified PostgreSQL SQL Dialect Classifier and Feature Analyzer
pragma SPARK_Mode (On);

with Nhe_O.Types; use Nhe_O.Types;

--  Supported dialect (anything else is rejected with Status_Invalid_Syntax):
--
--  Lexical (PostgreSQL scan.l, standard_conforming_strings = on):
--    * whitespace: space, HT, LF, VT, FF, CR; comments "--" to end of line and
--      nested "/* ... */"; unterminated comments / literals are rejected
--    * '...' ('' doubles), E'...' (backslash escapes the next character, '' also
--      doubles), N'...', B'...' / X'...', $tag$ ... $tag$ with an optional tag
--      [A-Za-z\200-\377_][A-Za-z\200-\377_0-9]* closed only by the same tag
--    * "..." delimited identifiers ("" doubles; "" is rejected), unquoted
--      identifiers [A-Za-z\200-\377_][A-Za-z\200-\377_0-9$]*
--    * $n positional parameters with n >= 1 ($01 = $1); $0, a stray '$' and
--      trailing junk after numbers / parameters ("1abc", "$1x") are rejected
--    * ( ) and [ ] must nest properly; one optional final ';' (multiple
--      statements are always rejected)
--  Structure (clause key words count only outside all parentheses/brackets of
--  their own statement; every "( SELECT | WITH | VALUES ...)" block is validated
--  as a query; "(" directly followed by INSERT / UPDATE / DELETE is rejected):
--    [WITH [RECURSIVE] name [(cols)] AS [[NOT] MATERIALIZED] (query) {, ...}]
--      followed by SELECT, INSERT, UPDATE or DELETE (CTE bodies must start with
--      SELECT, WITH or VALUES: data-modifying CTEs are rejected)
--    SELECT [ALL | DISTINCT [ON (...)]] list [FROM from_list] [WHERE e]
--      [GROUP BY l] [HAVING e] [WINDOW l] {UNION | INTERSECT | EXCEPT [ALL |
--      DISTINCT] SELECT ...} [ORDER BY l] [tail]; SELECT ... INTO is rejected;
--      tail = [limit_block] [locking] | [locking] [limit_block],
--      limit_block = limit [OFFSET {n | $n} [ROW | ROWS]] | OFFSET ... [limit],
--      limit = LIMIT {n | ALL | $n} | FETCH {FIRST | NEXT} [n | $n] {ROW | ROWS} ONLY,
--      locking = FOR {UPDATE | NO KEY UPDATE | SHARE | KEY SHARE} [OF names]
--      [NOWAIT | SKIP LOCKED] {...}; n is a decimal literal <= Natural'Last
--    from_list item = [ONLY] name [[AS] alias [(cols)]] | func (...) [alias] |
--      [LATERAL] (query) [alias] | LATERAL func (...) [alias], joined by commas
--      or [NATURAL | CROSS] [INNER | {LEFT | RIGHT | FULL} [OUTER]] JOIN item
--      [ON e | USING (cols)]
--    INSERT INTO name [AS alias] [(cols)] {DEFAULT VALUES | VALUES (...) {, (...)}
--      | [WITH ...] SELECT ...} [ON CONFLICT [(...) [WHERE e] | ON CONSTRAINT n]
--      DO {NOTHING | UPDATE SET a = e {, ...} [WHERE e]}] [RETURNING l]
--    UPDATE [ONLY] name [AS alias] SET a = e {, ...} [FROM from_list] [WHERE e]
--      [RETURNING l]
--    DELETE FROM [ONLY] name [AS alias] [USING from_list] [WHERE e] [RETURNING l]
--    CREATE [TEMP | TEMPORARY | UNLOGGED] TABLE [IF NOT EXISTS] name
--      (element {, element}) with at least one column; element =
--      col type [[] | [n]]... {column_constraint} | table_constraint;
--      type must satisfy Resolve_Pg_Type; column_constraint = [CONSTRAINT n]
--      {NOT NULL | NULL | PRIMARY KEY | UNIQUE | DEFAULT e | CHECK (e) |
--      REFERENCES t [(c)] [ON DELETE a] [ON UPDATE a] | COLLATE n |
--      GENERATED ALWAYS AS (e) STORED | GENERATED {ALWAYS | BY DEFAULT} AS
--      IDENTITY}; table_constraint = [CONSTRAINT n] {PRIMARY KEY (cols) |
--      UNIQUE (cols) | CHECK (e) | FOREIGN KEY (cols) REFERENCES t [(cols)]
--      [ON DELETE a] [ON UPDATE a]}; a = NO ACTION | RESTRICT | CASCADE |
--      SET NULL | SET DEFAULT
--    BEGIN | COMMIT | ROLLBACK [TRANSACTION | WORK];  LISTEN channel;
--    NOTIFY channel [, '...' | E'...' | $$...$$]
--  Names (tables, columns, aliases, channels) are delimited identifiers or
--  unquoted words that are not PostgreSQL reserved key words (nor BY, DELETE,
--  DROP, INSERT, SET, UPDATE, VALUES); qualified names have at most two parts
--  (schema.table; channel names may be dotted the same way).  Expressions are
--  checked lexically, for bracket balance, for nested query blocks, and for
--  the absence of statement-structure key words at their own level.
package Nhe_O.SQL is

   type SQL_Statement_Kind is (
      Stmt_Unknown,
      Stmt_Create_Table,
      Stmt_Insert,
      Stmt_Select,
      Stmt_Update,
      Stmt_Delete,
      Stmt_Begin,
      Stmt_Commit,
      Stmt_Rollback,
      Stmt_Listen,
      Stmt_Notify
   );

   --  Descriptor of a statement accepted by Analyze_SQL.  Clause flags describe
   --  the statement's own clauses, i.e. those outside all parentheses (CTE
   --  bodies, subqueries, and window definitions do not count).
   type Parsed_SQL_Descriptor is record
      Kind                 : SQL_Statement_Kind := Stmt_Unknown;
      --  Unquoted ("" un-doubled, case preserved) name of: the first FROM item
      --  of a SELECT when it is a plain relation (empty when there is no FROM
      --  clause or the item is a subquery / function call), the INSERT / UPDATE
      --  / DELETE / CREATE TABLE target, or the LISTEN / NOTIFY channel; a
      --  qualified name is joined with '.'
      Table_Or_Target      : Bounded_Ident      := (Length => 0, Data => [others => ' ']);
      --  SELECT: width of the select list; CREATE TABLE: number of columns
      --  (table constraints excluded); otherwise 0
      Column_Count         : Natural            := 0;
      Has_Where            : Boolean            := False;
      Has_Order_By         : Boolean            := False;
      --  True only for a literal row cap: LIMIT n or FETCH FIRST [n] ROWS ONLY
      --  (also from an INSERT ... SELECT source); LIMIT ALL and LIMIT $n leave
      --  it False (no static cap)
      Has_Limit            : Boolean            := False;
      Limit_Value          : Natural            := 0;      --  0 when not Has_Limit
      Has_Positional_Param : Boolean            := False;  --  e.g. $1, $2
      Has_Pg_Type_Cast     : Boolean            := False;  --  e.g. ::jsonb, ::vector
      Has_Vector_Operator  : Boolean            := False;  --  <->, <=>, <#>
      --  ->, ->>, #>, #>>, @>, <@, ?, ?|, ?&, @?, #-
      Has_JSONB_Operator   : Boolean            := False;
      Has_Upsert_Conflict  : Boolean            := False;  --  ON CONFLICT
      Has_Returning        : Boolean            := False;  --  RETURNING
      Has_Param_Limit      : Boolean            := False;  --  LIMIT $n / FETCH FIRST $n
      Has_Offset           : Boolean            := False;  --  OFFSET n or OFFSET $n
      Offset_Value         : Natural            := 0;      --  literal OFFSET value, else 0
      Has_Param_Offset     : Boolean            := False;  --  OFFSET $n
   end record;

   --  Parse, validate, and classify a PostgreSQL-dialect SQL query string in pure SPARK
   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Post   => (if Status = Status_Ok then Result.Kind /= Stmt_Unknown
                     else Result.Kind = Stmt_Unknown)
                    and then (if Query.Length = 0 then Status = Status_Invalid_Syntax)
                    and then Status in Status_Ok | Status_Invalid_Syntax
                    and then (if not Result.Has_Limit then Result.Limit_Value = 0)
                    and then not (Result.Has_Limit and then Result.Has_Param_Limit)
                    and then (if not Result.Has_Offset
                              then Result.Offset_Value = 0
                                   and then not Result.Has_Param_Offset);

   --  Resolve a PostgreSQL type name to Pg_Data_Type.  Words are separated by
   --  any whitespace and matched case-insensitively; a modifier "( n [, m] )"
   --  may contain whitespace:
   --    SMALLINT | INT2; INTEGER | INT | INT4; BIGINT | INT8; REAL | FLOAT4 |
   --    FLOAT(1..24); DOUBLE PRECISION | FLOAT8 | FLOAT | FLOAT(25..53);
   --    NUMERIC | DECIMAL [(1..38 [, 0..p])]; BOOLEAN | BOOL; TEXT |
   --    VARCHAR [(1..10485760)] | CHARACTER VARYING | CHAR VARYING [(1..10485760)];
   --    BYTEA; UUID; TIMESTAMPTZ [(0..6)];
   --    TIMESTAMP [(0..6)] [WITH TIME ZONE | WITHOUT TIME ZONE] (all map to
   --    Pg_Timestamptz, as bare TIMESTAMP always did); JSON; JSONB;
   --    VECTOR [(1..4096)].  Array suffixes are not types here: CREATE TABLE
   --    validates "[]" / "[n]" itself and resolves the element type.
   procedure Resolve_Pg_Type
     (Type_Keyword : in     Bounded_Ident;
      Resolved     :    out Pg_Data_Type;
      Valid        :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Type_Keyword.Length = 0 then not Valid)
                    and then (if not Valid then Resolved = Pg_Text);

end Nhe_O.SQL;
