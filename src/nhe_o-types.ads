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

   --  Epoch timestamp in seconds: the caller's clock, access times and TTL deadlines of
   --  the KV store (Nhe_O.KV, Nhe_O.C_API); no SQL value uses it
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
     with Global => null,
          Pre    => S'Length <= Max_Ident_Len,
          Post   => Make_Ident'Result.Length = S'Length
                    and then (for all I in 1 .. S'Length =>
                                Make_Ident'Result.Data (I) = S (S'First + (I - 1)));

   function Make_Text (S : String) return Bounded_Text
     with Global => null,
          Pre    => S'Length <= Max_Text_Len,
          Post   => Make_Text'Result.Length = S'Length
                    and then (for all I in 1 .. S'Length =>
                                Make_Text'Result.Data (I) = S (S'First + (I - 1)));

   function Equal_Ident (A, B : Bounded_Ident) return Boolean
     with Global => null,
          Post   => Equal_Ident'Result =
                      (A.Length = B.Length
                       and then (for all I in 1 .. A.Length =>
                                   A.Data (I) = B.Data (I)));

   function Equal_Text (A, B : Bounded_Text) return Boolean
     with Global => null,
          Post   => Equal_Text'Result =
                      (A.Length = B.Length
                       and then (for all I in 1 .. A.Length =>
                                   A.Data (I) = B.Data (I)));

   function To_Lower_Char (C : Character) return Character
     with Global => null;

   function Equal_Ident_Case_Insensitive (A, B : Bounded_Ident) return Boolean
     with Global => null,
          Post   => Equal_Ident_Case_Insensitive'Result =
                      (A.Length = B.Length
                       and then (for all I in 1 .. A.Length =>
                                   To_Lower_Char (A.Data (I)) = To_Lower_Char (B.Data (I))));

   function Type_Name (T : Pg_Data_Type) return Bounded_Ident
     with Global => null,
          Post   => Type_Name'Result.Length > 0;

   --  UTF-8 (RFC 3629)
   subtype UTF8_Count is Natural range 0 .. 3;

   --  Classify a non-ASCII byte as a UTF-8 lead byte: Need is the number of
   --  continuation bytes (0 = invalid lead byte) and Lo .. Hi the range of the
   --  first continuation byte (excludes overlong forms, UTF-16 surrogates
   --  U+D800 .. U+DFFF, and code points above U+10FFFF)
   procedure UTF8_Lead
     (C    : in     Character;
      Need :    out UTF8_Count;
      Lo   :    out Character;
      Hi   :    out Character)
     with Global => null,
          Always_Terminates,
          Post   => (Need = 0) = (Character'Pos (C) not in 16#C2# .. 16#F4#)
                    and then (if Need = 1 then Character'Pos (C) in 16#C2# .. 16#DF#)
                    and then (if Need = 2 then Character'Pos (C) in 16#E0# .. 16#EF#)
                    and then (if Need = 3 then Character'Pos (C) in 16#F0# .. 16#F4#)
                    and then Lo >= Character'Val (16#80#)
                    and then Hi <= Character'Val (16#BF#);

   --  Is T.Data (1 .. T.Length) well-formed UTF-8?
   function Is_Valid_UTF8 (T : Bounded_Text) return Boolean
     with Global => null,
          Post   => (if (for all I in 1 .. T.Length => T.Data (I) < Character'Val (16#80#))
                     then Is_Valid_UTF8'Result);

end Nhe_O.Types;
