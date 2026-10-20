--  Formally verified PostgreSQL SQL Dialect Classifier and Feature Analyzer
pragma SPARK_Mode (On);

with Nhe_O.Types; use Nhe_O.Types;

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

   type Parsed_SQL_Descriptor is record
      Kind                 : SQL_Statement_Kind := Stmt_Unknown;
      Table_Or_Target      : Bounded_Ident      := (Length => 0, Data => [others => ' ']);
      Column_Count         : Natural            := 0;
      Has_Where            : Boolean            := False;
      Has_Order_By         : Boolean            := False;
      Has_Limit            : Boolean            := False;
      Limit_Value          : Natural            := 0;
      Has_Positional_Param : Boolean            := False; --  e.g. $1, $2
      Has_Pg_Type_Cast     : Boolean            := False; --  e.g. ::jsonb, ::vector
      Has_Vector_Operator  : Boolean            := False; --  <->, <=>, <#>
      Has_JSONB_Operator   : Boolean            := False; --  ->, ->>, @>, <@, ?, ?|, ?&
      Has_Upsert_Conflict  : Boolean            := False; --  ON CONFLICT
      Has_Returning        : Boolean            := False; --  RETURNING
   end record;

   --  Parse, validate, and classify a PostgreSQL-dialect SQL query string in pure SPARK
   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Post   => (if Status = Status_Ok then Result.Kind /= Stmt_Unknown
                     else Result.Kind = Stmt_Unknown);

   --  Resolve a PostgreSQL type keyword (e.g. "INT4", "JSONB", "VECTOR(1536)") to Pg_Data_Type
   procedure Resolve_Pg_Type
     (Type_Keyword : in     Bounded_Ident;
      Resolved     :    out Pg_Data_Type;
      Valid        :    out Boolean)
     with Global => null,
          Always_Terminates;

end Nhe_O.SQL;
