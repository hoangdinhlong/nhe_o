pragma SPARK_Mode (On);

package body Nhe_O.Types is

   function Make_Ident (S : String) return Bounded_Ident is
      Res : Bounded_Ident;
   begin
      Res.Length := S'Length;
      for I in 1 .. S'Length loop
         pragma Loop_Invariant (I in 1 .. S'Length);
         Res.Data (I) := S (S'First + (I - 1));
      end loop;
      return Res;
   end Make_Ident;

   function Make_Text (S : String) return Bounded_Text is
      Res : Bounded_Text;
   begin
      Res.Length := S'Length;
      for I in 1 .. S'Length loop
         pragma Loop_Invariant (I in 1 .. S'Length);
         Res.Data (I) := S (S'First + (I - 1));
      end loop;
      return Res;
   end Make_Text;

   function Equal_Ident (A, B : Bounded_Ident) return Boolean is
   begin
      if A.Length /= B.Length then
         return False;
      end if;
      for I in 1 .. A.Length loop
         pragma Loop_Invariant (I in 1 .. A.Length);
         if A.Data (I) /= B.Data (I) then
            return False;
         end if;
      end loop;
      return True;
   end Equal_Ident;

   function Equal_Text (A, B : Bounded_Text) return Boolean is
   begin
      if A.Length /= B.Length then
         return False;
      end if;
      for I in 1 .. A.Length loop
         pragma Loop_Invariant (I in 1 .. A.Length);
         if A.Data (I) /= B.Data (I) then
            return False;
         end if;
      end loop;
      return True;
   end Equal_Text;

   function To_Lower_Char (C : Character) return Character is
   begin
      if C in 'A' .. 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      else
         return C;
      end if;
   end To_Lower_Char;

   function Equal_Ident_Case_Insensitive (A, B : Bounded_Ident) return Boolean is
   begin
      if A.Length /= B.Length then
         return False;
      end if;
      for I in 1 .. A.Length loop
         pragma Loop_Invariant (I in 1 .. A.Length);
         if To_Lower_Char (A.Data (I)) /= To_Lower_Char (B.Data (I)) then
            return False;
         end if;
      end loop;
      return True;
   end Equal_Ident_Case_Insensitive;

   function Type_Name (T : Pg_Data_Type) return Bounded_Ident is
   begin
      case T is
         when Pg_Smallint         => return Make_Ident ("SMALLINT");
         when Pg_Integer          => return Make_Ident ("INTEGER");
         when Pg_Bigint           => return Make_Ident ("BIGINT");
         when Pg_Real             => return Make_Ident ("REAL");
         when Pg_Double_Precision => return Make_Ident ("DOUBLE PRECISION");
         when Pg_Numeric          => return Make_Ident ("NUMERIC");
         when Pg_Boolean          => return Make_Ident ("BOOLEAN");
         when Pg_Text             => return Make_Ident ("TEXT");
         when Pg_Bytea            => return Make_Ident ("BYTEA");
         when Pg_UUID             => return Make_Ident ("UUID");
         when Pg_Timestamptz      => return Make_Ident ("TIMESTAMPTZ");
         when Pg_JSON             => return Make_Ident ("JSON");
         when Pg_JSONB            => return Make_Ident ("JSONB");
         when Pg_Vector           => return Make_Ident ("VECTOR");
      end case;
   end Type_Name;

end Nhe_O.Types;
