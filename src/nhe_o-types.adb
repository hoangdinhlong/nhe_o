pragma SPARK_Mode (On);

package body Nhe_O.Types is

   function Make_Ident (S : String) return Bounded_Ident is
      Res : Bounded_Ident;
   begin
      Res.Length := S'Length;
      for I in 1 .. S'Length loop
         pragma Loop_Invariant
           (I in 1 .. S'Length
            and then Res.Length = S'Length
            and then (for all J in 1 .. I - 1 =>
                        Res.Data (J) = S (S'First + (J - 1))));
         Res.Data (I) := S (S'First + (I - 1));
      end loop;
      return Res;
   end Make_Ident;

   function Make_Text (S : String) return Bounded_Text is
      Res : Bounded_Text;
   begin
      Res.Length := S'Length;
      for I in 1 .. S'Length loop
         pragma Loop_Invariant
           (I in 1 .. S'Length
            and then Res.Length = S'Length
            and then (for all J in 1 .. I - 1 =>
                        Res.Data (J) = S (S'First + (J - 1))));
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
         pragma Loop_Invariant
           (I in 1 .. A.Length
            and then (for all J in 1 .. I - 1 => A.Data (J) = B.Data (J)));
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
         pragma Loop_Invariant
           (I in 1 .. A.Length
            and then (for all J in 1 .. I - 1 => A.Data (J) = B.Data (J)));
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
         pragma Loop_Invariant
           (I in 1 .. A.Length
            and then (for all J in 1 .. I - 1 =>
                        To_Lower_Char (A.Data (J)) = To_Lower_Char (B.Data (J))));
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

   procedure UTF8_Lead
     (C    : in     Character;
      Need :    out UTF8_Count;
      Lo   :    out Character;
      Hi   :    out Character)
   is
      B : constant Natural := Character'Pos (C);
   begin
      Lo := Character'Val (16#80#);
      Hi := Character'Val (16#BF#);
      if B in 16#C2# .. 16#DF# then
         Need := 1;
      elsif B in 16#E0# .. 16#EF# then
         Need := 2;
         if B = 16#E0# then
            Lo := Character'Val (16#A0#);
         elsif B = 16#ED# then
            Hi := Character'Val (16#9F#);
         end if;
      elsif B in 16#F0# .. 16#F4# then
         Need := 3;
         if B = 16#F0# then
            Lo := Character'Val (16#90#);
         elsif B = 16#F4# then
            Hi := Character'Val (16#8F#);
         end if;
      else
         Need := 0;
      end if;
   end UTF8_Lead;

   function Is_Valid_UTF8 (T : Bounded_Text) return Boolean is
      Need : UTF8_Count := 0;
      Lo   : Character  := Character'Val (16#80#);
      Hi   : Character  := Character'Val (16#BF#);
   begin
      for I in 1 .. T.Length loop
         pragma Loop_Invariant
           (if (for all J in 1 .. I - 1 => T.Data (J) < Character'Val (16#80#))
            then Need = 0);
         if Need > 0 then
            if T.Data (I) not in Lo .. Hi then
               return False;
            end if;
            Need := Need - 1;
            Lo   := Character'Val (16#80#);
            Hi   := Character'Val (16#BF#);
         elsif T.Data (I) >= Character'Val (16#80#) then
            UTF8_Lead (T.Data (I), Need, Lo, Hi);
            if Need = 0 then
               return False;
            end if;
         end if;
      end loop;
      return Need = 0;
   end Is_Valid_UTF8;

end Nhe_O.Types;
