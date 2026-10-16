--  PostgreSQL-compatible data types and bounded primitives for Nhe_O
pragma SPARK_Mode (On);

with Interfaces;

package Nhe_O.Types is

   --  PostgreSQL Data Type catalog
   type Pg_Data_Type is (
      Pg_Smallint,          --  INT2 (16-bit signed integer)
      Pg_Integer,           --  INT4 (32-bit signed integer)
      Pg_Bigint,            --  INT8 (64-bit signed integer)
      Pg_Real,              --  FLOAT4 (single-precision float)
      Pg_Double_Precision,  --  FLOAT8 (double-precision float)
      Pg_Numeric,           --  NUMERIC / DECIMAL (exact fixed-point)
      Pg_Boolean,           --  BOOLEAN
      Pg_Text,              --  TEXT / VARCHAR
      Pg_Bytea,             --  BYTEA (binary byte array)
      Pg_UUID,              --  UUID (128-bit identifier)
      Pg_Timestamptz,       --  TIMESTAMP WITH TIME ZONE (epoch microseconds)
      Pg_JSON,              --  JSON (validated text JSON)
      Pg_JSONB,             --  JSONB (decomposed binary JSON)
      Pg_Vector             --  VECTOR(d) (pgvector float embedding)
   );

   --  Bounded identifier (table, column, key, channel names)
   Max_Ident_Len : constant := 64;
   subtype Ident_Index is Positive range 1 .. Max_Ident_Len;
   subtype Ident_Length is Natural range 0 .. Max_Ident_Len;

   type Bounded_Ident is record
      Length : Ident_Length := 0;
      Data   : String (Ident_Index) := [others => ' '];
   end record;

   --  Bounded text payload (SQL literals, JSON strings, KV values)
   Max_Text_Len : constant := 512;
   subtype Text_Index is Positive range 1 .. Max_Text_Len;
   subtype Text_Length is Natural range 0 .. Max_Text_Len;

   type Bounded_Text is record
      Length : Text_Length := 0;
      Data   : String (Text_Index) := [others => ' '];
   end record;

   --  Epoch timestamp in seconds (used for TIMESTAMPTZ and Redis KV TTL)
   subtype Epoch_Seconds is Interfaces.Integer_64 range 0 .. Interfaces.Integer_64'Last;

   --  Engine operation status
   type Engine_Status is (
      Status_Ok,
      Status_Not_Found,
      Status_Expired,
      Status_Invalid_Syntax,
      Status_Type_Mismatch,
      Status_Dimension_Mismatch,
      Status_Capacity_Exceeded,
      Status_Tx_Aborted,
      Status_IO_Error
   );

   function Make_Ident (S : String) return Bounded_Ident
     with Pre  => S'Length <= Max_Ident_Len,
          Post => Make_Ident'Result.Length = S'Length;

   function Make_Text (S : String) return Bounded_Text
     with Pre  => S'Length <= Max_Text_Len,
          Post => Make_Text'Result.Length = S'Length;

   function Equal_Ident (A, B : Bounded_Ident) return Boolean;

   function Equal_Text (A, B : Bounded_Text) return Boolean;

   function To_Lower_Char (C : Character) return Character;

   function Equal_Ident_Case_Insensitive (A, B : Bounded_Ident) return Boolean;

   function Type_Name (T : Pg_Data_Type) return Bounded_Ident;

end Nhe_O.Types;
