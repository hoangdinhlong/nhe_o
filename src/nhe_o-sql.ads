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
      Has_Positional_Param : Boolean            := False; --  e.g. $1, $2
      Has_Pg_Type_Cast     : Boolean            := False; --  e.g. ::jsonb, ::vector
      Has_Vector_Operator  : Boolean            := False; --  <->, <=>, <#>
      Has_JSONB_Operator   : Boolean            := False; --  ->, ->>, @>, ?
      Has_Upsert_Conflict  : Boolean            := False; --  ON CONFLICT
      Has_Returning        : Boolean            := False; --  RETURNING
   end record;

   --  Parse and classify a PostgreSQL-dialect SQL query string in pure SPARK
   procedure Analyze_SQL
     (Query  : in     Bounded_Text;
      Result :    out Parsed_SQL_Descriptor;
      Status :    out Engine_Status)
     with Post => (if Status = Status_Ok then Result.Kind /= Stmt_Unknown
                   else Result.Kind = Stmt_Unknown);

   --  Resolve a PostgreSQL type keyword (e.g. "INT4", "JSONB", "VECTOR") to Pg_Data_Type
   procedure Resolve_Pg_Type
     (Type_Keyword : in     Bounded_Ident;
      Resolved     :    out Pg_Data_Type;
      Valid        :    out Boolean);

end Nhe_O.SQL;
