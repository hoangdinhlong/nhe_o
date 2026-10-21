pragma SPARK_Mode (On);

package body Nhe_O.JSON is

   -------------------------------------------------------------------------
   --  Character classification
   -------------------------------------------------------------------------

   function Is_Whitespace (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF or else C = ASCII.CR);

   --  Characters that terminate a scalar literal inside a container
   function Is_Delimiter (C : Character) return Boolean is
     (Is_Whitespace (C) or else C = ',' or else C = ':' or else C = ']' or else C = '}');

   --  Value of a hexadecimal digit, or -1 if C is not one
   function Hex_Value (C : Character) return Integer is
     (case C is
         when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
         when others     => -1)
     with Post => Hex_Value'Result in -1 .. 15;

   --  Value of the four hexadecimal digits T.Data (P .. P + 3), or -1
   function Hex4 (T : Bounded_Text; P : Positive) return Integer is
     (if Hex_Value (T.Data (P)) < 0
        or else Hex_Value (T.Data (P + 1)) < 0
        or else Hex_Value (T.Data (P + 2)) < 0
        or else Hex_Value (T.Data (P + 3)) < 0
      then -1
      else Hex_Value (T.Data (P)) * 16#1000# + Hex_Value (T.Data (P + 1)) * 16#100#
           + Hex_Value (T.Data (P + 2)) * 16#10# + Hex_Value (T.Data (P + 3)))
     with Pre  => P + 3 <= T.Length,
          Post => Hex4'Result in -1 .. 16#FFFF#;

   --  JSON value kind announced by the first character of a validated value
   function Kind_Of (C : Character) return JSONB_Value_Kind is
     (case C is
         when '{'       => JSONB_Object,
         when '['       => JSONB_Array,
         when '"'       => JSONB_String,
         when 't' | 'f' => JSONB_Boolean,
         when 'n'       => JSONB_Null,
         when others    => JSONB_Number);

   function Decode_Escape_Char (C : Character) return Character is
     (case C is
         when 'n'    => ASCII.LF,
         when 'r'    => ASCII.CR,
         when 't'    => ASCII.HT,
         when 'b'    => ASCII.BS,
         when 'f'    => ASCII.FF,
         when others => C);

   function Is_Simple_Escape (C : Character) return Boolean is
     (C = '"' or else C = '\' or else C = '/' or else C = 'b' or else C = 'f'
      or else C = 'n' or else C = 'r' or else C = 't');

   -------------------------------------------------------------------------
   --  UTF-8 (RFC 3629)
   -------------------------------------------------------------------------

   subtype UTF8_Count is Natural range 0 .. 3;

   --  Number of UTF-8 bytes encoding a Unicode scalar value
   function UTF8_Length (Code : Natural) return Positive is
     (if Code < 16#80# then 1
      elsif Code < 16#800# then 2
      elsif Code < 16#1_0000# then 3
      else 4);

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
                    and then Hi <= Character'Val (16#BF#)
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

   --  Is T.Data (1 .. T.Length) well-formed UTF-8?
   function Is_Valid_UTF8 (T : Bounded_Text) return Boolean
     with Global => null,
          Post   => (if (for all I in 1 .. T.Length => T.Data (I) < Character'Val (16#80#))
                     then Is_Valid_UTF8'Result)
   is
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

   function Is_Valid_JSONB_Key (Key : Bounded_Ident) return Boolean is
      T : Bounded_Text := (Length => Key.Length, Data => [others => ' ']);
   begin
      if Key.Length = 0 then
         return False;
      end if;
      for I in 1 .. Key.Length loop
         pragma Loop_Invariant (T.Length = Key.Length);
         if Key.Data (I) = ASCII.NUL then
            return False;
         end if;
         T.Data (I) := Key.Data (I);
      end loop;
      return Is_Valid_UTF8 (T);
   end Is_Valid_JSONB_Key;

   --  Append the UTF-8 encoding of Code to Dst
   procedure Append_Code_Point
     (Dst  : in out Bounded_Text;
      Code : in     Natural)
     with Global => null,
          Always_Terminates,
          Pre    => Code in 1 .. 16#10_FFFF#
                    and then Dst.Length <= Max_Text_Len - UTF8_Length (Code),
          Post   => Dst.Length = Dst.Length'Old + UTF8_Length (Code)
   is
      L : constant Text_Length := Dst.Length;
   begin
      if Code < 16#80# then
         Dst.Data (L + 1) := Character'Val (Code);
      elsif Code < 16#800# then
         Dst.Data (L + 1) := Character'Val (16#C0# + Code / 16#40#);
         Dst.Data (L + 2) := Character'Val (16#80# + Code mod 16#40#);
      elsif Code < 16#1_0000# then
         Dst.Data (L + 1) := Character'Val (16#E0# + Code / 16#1000#);
         Dst.Data (L + 2) := Character'Val (16#80# + (Code / 16#40#) mod 16#40#);
         Dst.Data (L + 3) := Character'Val (16#80# + Code mod 16#40#);
      else
         Dst.Data (L + 1) := Character'Val (16#F0# + Code / 16#4_0000#);
         Dst.Data (L + 2) := Character'Val (16#80# + (Code / 16#1000#) mod 16#40#);
         Dst.Data (L + 3) := Character'Val (16#80# + (Code / 16#40#) mod 16#40#);
         Dst.Data (L + 4) := Character'Val (16#80# + Code mod 16#40#);
      end if;
      Dst.Length := L + UTF8_Length (Code);
   end Append_Code_Point;

   -------------------------------------------------------------------------
   --  JSON numbers: PostgreSQL numeric range and exact canonical form
   -------------------------------------------------------------------------

   --  PostgreSQL numeric_in limits ("value overflows numeric format")
   PG_Max_Exponent : constant := 1_073_741_823;  --  |exponent| <= PG_INT32_MAX / 2
   PG_Max_Dscale   : constant := 16_383;         --  NUMERIC_DSCALE_MAX
   PG_Max_Msd_Exp  : constant := 131_071;        --  NBASE weight <= 32767 (int16)

   --  Exact canonical form, kept as positions into the token (no digit copy):
   --  the Sig_Count significant digits start at T.Data (Sig_First) (a '.' may
   --  sit between them; leading and trailing zeros excluded) and E_Msd is the
   --  decimal exponent of the most significant digit
   type Number_Form is record
      In_Range  : Boolean  := False;
      Is_Zero   : Boolean  := True;
      Is_Neg    : Boolean  := False;
      E_Msd     : Integer  := 0;
      Sig_First : Positive := 1;
      Sig_Count : Natural  := 0;
   end record;

   --  Canonicalize the JSON number token starting at T.Data (P). In_Range is
   --  False if the token is malformed or PostgreSQL numeric would reject it:
   --  exponent magnitude > 1073741823, display scale max (0, fraction digits -
   --  exponent) > 16383, or a nonzero value of magnitude >= 10**131072.
   function Canonical_Number (T : Bounded_Text; P : Positive) return Number_Form
     with Global => null,
          Pre    => P <= T.Length,
          Post   => (if Canonical_Number'Result.In_Range then
                       (T.Data (P) = '-' or else T.Data (P) in '0' .. '9')
                       and then
                       (if Canonical_Number'Result.Is_Zero then
                          Canonical_Number'Result.Sig_Count = 0
                          and then not Canonical_Number'Result.Is_Neg
                        else
                          Canonical_Number'Result.Sig_Count > 0
                          and then Canonical_Number'Result.Sig_First in P .. T.Length
                          and then Canonical_Number'Result.E_Msd
                                     in -PG_Max_Dscale .. PG_Max_Msd_Exp))
   is
      F           : Number_Form;
      Pos         : Positive := P;
      Neg         : Boolean  := False;
      Seen_NZ     : Boolean  := False;
      Int_Digits  : Natural  := 0;
      Frac_Digits : Natural  := 0;
      Run         : Natural  := 0;  --  digits seen since the most significant one
      Msd_Base    : Integer  := 0;
      Exp_Neg     : Boolean  := False;
      Exp_Acc     : Natural  := 0;
      Lit_Exp     : Integer;
      Digit       : Natural;
   begin
      if T.Data (Pos) = '-' then
         if Pos = T.Length then
            return F;
         end if;
         Neg := True;
         Pos := Pos + 1;
      end if;

      --  Integer part: significant digits start at the first nonzero digit
      while Pos <= T.Length and then T.Data (Pos) in '0' .. '9' loop
         pragma Loop_Invariant (Pos in P .. T.Length);
         pragma Loop_Invariant
           (Pos = P + Int_Digits + (if T.Data (P) = '-' then 1 else 0)
            and then Run <= Int_Digits and then F.Sig_Count <= Run);
         pragma Loop_Invariant
           (if Int_Digits > 0 then T.Data (P) = '-' or else T.Data (P) in '0' .. '9');
         pragma Loop_Invariant
           (if Seen_NZ then F.Sig_First in P .. Pos - 1 and then F.Sig_Count >= 1
            else Run = 0 and then F.Sig_Count = 0);
         pragma Loop_Variant (Increases => Pos);
         Int_Digits := Int_Digits + 1;
         if not Seen_NZ and then T.Data (Pos) /= '0' then
            Seen_NZ     := True;
            F.Sig_First := Pos;
         end if;
         if Seen_NZ then
            Run := Run + 1;
            if T.Data (Pos) /= '0' then
               F.Sig_Count := Run;
            end if;
         end if;
         Pos := Pos + 1;
      end loop;

      if Int_Digits = 0 then
         return F;
      end if;
      if Seen_NZ then
         Msd_Base := Run - 1;
      end if;

      --  Fraction part
      if Pos <= T.Length and then T.Data (Pos) = '.' then
         Pos := Pos + 1;
         while Pos <= T.Length and then T.Data (Pos) in '0' .. '9' loop
            pragma Loop_Invariant (Pos in P + 1 .. T.Length);
            pragma Loop_Invariant
              (Frac_Digits <= Pos - P and then Run <= Pos - P and then F.Sig_Count <= Run);
            pragma Loop_Invariant
              (if Seen_NZ then
                 F.Sig_First in P .. Pos - 1 and then F.Sig_Count >= 1
                 and then Msd_Base in -Frac_Digits .. Max_Text_Len
               else Run = 0 and then F.Sig_Count = 0);
            pragma Loop_Variant (Increases => Pos);
            Frac_Digits := Frac_Digits + 1;
            if not Seen_NZ and then T.Data (Pos) /= '0' then
               Seen_NZ     := True;
               F.Sig_First := Pos;
               Msd_Base    := -Frac_Digits;
            end if;
            if Seen_NZ then
               Run := Run + 1;
               if T.Data (Pos) /= '0' then
                  F.Sig_Count := Run;
               end if;
            end if;
            Pos := Pos + 1;
         end loop;
      end if;

      --  Exponent part (leading zeros allowed; magnitude capped like numeric_in)
      if Pos <= T.Length and then (T.Data (Pos) = 'e' or else T.Data (Pos) = 'E') then
         if Pos = T.Length then
            return F;
         end if;
         Pos := Pos + 1;
         if T.Data (Pos) = '+' or else T.Data (Pos) = '-' then
            Exp_Neg := T.Data (Pos) = '-';
            if Pos = T.Length then
               return F;
            end if;
            Pos := Pos + 1;
         end if;
         if T.Data (Pos) not in '0' .. '9' then
            return F;
         end if;
         while Pos <= T.Length and then T.Data (Pos) in '0' .. '9' loop
            pragma Loop_Invariant (Pos in P + 1 .. T.Length and then Exp_Acc <= PG_Max_Exponent);
            pragma Loop_Variant (Increases => Pos);
            Digit := Character'Pos (T.Data (Pos)) - Character'Pos ('0');
            if Exp_Acc > (PG_Max_Exponent - Digit) / 10 then
               return F;
            end if;
            Exp_Acc := Exp_Acc * 10 + Digit;
            Pos := Pos + 1;
         end loop;
      end if;

      Lit_Exp := (if Exp_Neg then -Exp_Acc else Exp_Acc);
      if Frac_Digits - Lit_Exp > PG_Max_Dscale then
         return F;
      end if;

      if not Seen_NZ then
         F.In_Range := True;
         return F;
      end if;

      if Msd_Base + Lit_Exp > PG_Max_Msd_Exp then
         return F;
      end if;

      F.In_Range := True;
      F.Is_Zero  := False;
      F.Is_Neg   := Neg;
      F.E_Msd    := Msd_Base + Lit_Exp;
      return F;
   end Canonical_Number;

   function Number_In_PG_Range (T : Bounded_Text; P : Positive) return Boolean is
     (Canonical_Number (T, P).In_Range)
     with Pre => P <= T.Length;

   --  Exact numeric equality of two number tokens (-0 = 0, 1.0 = 1 = 10e-1)
   function Equal_Number_Tokens
     (A  : Bounded_Text;
      AP : Positive;
      B  : Bounded_Text;
      BP : Positive) return Boolean
     with Global => null,
          Pre    => AP <= A.Length and then BP <= B.Length,
          Post   => (if Equal_Number_Tokens'Result then
                       (A.Data (AP) = '-' or else A.Data (AP) in '0' .. '9')
                       and then (B.Data (BP) = '-' or else B.Data (BP) in '0' .. '9'))
   is
      FA : constant Number_Form := Canonical_Number (A, AP);
      FB : constant Number_Form := Canonical_Number (B, BP);
      I  : Positive;
      J  : Positive;
   begin
      if not FA.In_Range or else not FB.In_Range then
         return False;
      elsif FA.Is_Zero or else FB.Is_Zero then
         return FA.Is_Zero and then FB.Is_Zero;
      elsif FA.Is_Neg /= FB.Is_Neg
        or else FA.E_Msd /= FB.E_Msd
        or else FA.Sig_Count /= FB.Sig_Count
      then
         return False;
      end if;

      --  Same sign, magnitude and digit count: compare the significant digits
      I := FA.Sig_First;
      J := FB.Sig_First;
      for N in 1 .. FA.Sig_Count loop
         if I <= A.Length and then A.Data (I) = '.' then
            I := I + 1;
         end if;
         if J <= B.Length and then B.Data (J) = '.' then
            J := J + 1;
         end if;
         if I > A.Length or else J > B.Length or else A.Data (I) /= B.Data (J) then
            return False;
         end if;
         I := I + 1;
         J := J + 1;
      end loop;
      return True;
   end Equal_Number_Tokens;

   -------------------------------------------------------------------------
   --  Check_JSON_Text: RFC 8259 validator with optional JSONB ingest rules
   -------------------------------------------------------------------------

   --  Status_Ok, Status_Invalid_Syntax or Status_Capacity_Exceeded. With JSONB,
   --  an empty object key is Invalid_Syntax, and with JSONB and Limits also: keys
   --  longer than Max_Ident_Len decoded bytes and numbers outside the PostgreSQL
   --  numeric range are Capacity_Exceeded. Nesting deeper than Max_Depth
   --  containers is Capacity_Exceeded.
   function Check_JSON_Text
     (Raw       : Bounded_Text;
      JSONB     : Boolean;
      Max_Depth : Positive;
      Limits    : Boolean := True) return Engine_Status
     with Global => null,
          Pre    => Max_Depth <= Max_Text_Len,
          Post   => Check_JSON_Text'Result
                      in Status_Ok | Status_Invalid_Syntax | Status_Capacity_Exceeded
                    and then (if Check_JSON_Text'Result = Status_Ok then Raw.Length > 0)
   is
      type Expect_State is
        (St_Root,
         St_Obj_Key_Or_End,
         St_Obj_Key,
         St_Obj_Colon,
         St_Arr_Val_Or_End,
         St_Val,
         St_After_Val);

      type Lex_Mode is
        (Lex_None,
         Lex_String,
         Lex_Num_After_Minus,
         Lex_Num_Zero,
         Lex_Num_Need_Digit,
         Lex_Num_Has_Digit,
         Lex_Num_Exp_Sign,
         Lex_True_R,
         Lex_True_U,
         Lex_True_E,
         Lex_False_A,
         Lex_False_L,
         Lex_False_S,
         Lex_False_E,
         Lex_Null_U,
         Lex_Null_L1,
         Lex_Null_L2);

      Stack         : String (1 .. Max_Text_Len) := [others => ' '];
      Depth         : Natural range 0 .. Max_Text_Len := 0;
      State         : Expect_State := St_Root;
      Lex           : Lex_Mode     := Lex_None;
      Escaped       : Boolean      := False;
      Hex_Needed    : Natural range 0 .. 4 := 0;
      Hex_Code      : Natural range 0 .. 16#FFFF# := 0;
      Need_Low      : Boolean      := False;
      U8_Need       : UTF8_Count   := 0;
      U8_Lo         : Character    := Character'Val (16#80#);
      U8_Hi         : Character    := Character'Val (16#BF#);
      Str_Len       : Natural range 0 .. Max_Ident_Len + 1 := 0;
      String_Is_Key : Boolean      := False;
      Num_Has_Dot   : Boolean      := False;
      Num_Has_Exp   : Boolean      := False;
      Num_Start     : Positive     := 1;
      Consumed      : Boolean;
   begin
      if Raw.Length < 1 then
         return Status_Invalid_Syntax;
      end if;

      for I in 1 .. Raw.Length loop
         pragma Loop_Invariant (Num_Start <= Raw.Length and then Depth <= Max_Depth);
         declare
            C     : constant Character := Raw.Data (I);
            Is_WS : constant Boolean   := Is_Whitespace (C);
         begin
            Consumed := True;

            --  1. Handle active lexical token modes first
            if Lex = Lex_String then
               if Character'Pos (C) < 32 then
                  return Status_Invalid_Syntax;
               elsif U8_Need > 0 then
                  --  UTF-8 continuation byte
                  if C not in U8_Lo .. U8_Hi then
                     return Status_Invalid_Syntax;
                  end if;
                  U8_Need := U8_Need - 1;
                  U8_Lo   := Character'Val (16#80#);
                  U8_Hi   := Character'Val (16#BF#);
                  Str_Len := Natural'Min (Str_Len + 1, Max_Ident_Len + 1);
               elsif Hex_Needed > 0 then
                  if Hex_Value (C) < 0 then
                     return Status_Invalid_Syntax;
                  end if;
                  --  Hex_Code < 16#1000# before the fourth digit: mod only bounds it
                  Hex_Code   := (Hex_Code mod 16#1000#) * 16 + Hex_Value (C);
                  Hex_Needed := Hex_Needed - 1;
                  if Hex_Needed = 0 then
                     if Need_Low then
                        --  A high surrogate must be followed by a low surrogate
                        if Hex_Code not in 16#DC00# .. 16#DFFF# then
                           return Status_Invalid_Syntax;
                        end if;
                        Need_Low := False;
                        Str_Len  := Natural'Min (Str_Len + 4, Max_Ident_Len + 1);
                     elsif Hex_Code in 16#D800# .. 16#DBFF# then
                        Need_Low := True;
                     elsif Hex_Code = 0 or else Hex_Code in 16#DC00# .. 16#DFFF# then
                        --  U+0000 or a lone low surrogate
                        return Status_Invalid_Syntax;
                     else
                        Str_Len := Natural'Min (Str_Len + UTF8_Length (Hex_Code), Max_Ident_Len + 1);
                     end if;
                  end if;
               elsif Escaped then
                  Escaped := False;
                  if C = 'u' then
                     Hex_Needed := 4;
                     Hex_Code   := 0;
                  elsif Need_Low or else not Is_Simple_Escape (C) then
                     return Status_Invalid_Syntax;
                  else
                     Str_Len := Natural'Min (Str_Len + 1, Max_Ident_Len + 1);
                  end if;
               elsif C = '\' then
                  Escaped := True;
               elsif Need_Low then
                  return Status_Invalid_Syntax;
               elsif C = '"' then
                  if JSONB and then String_Is_Key then
                     if Str_Len = 0 then
                        return Status_Invalid_Syntax;
                     elsif Limits and then Str_Len > Max_Ident_Len then
                        return Status_Capacity_Exceeded;
                     end if;
                  end if;
                  Lex   := Lex_None;
                  State := (if String_Is_Key then St_Obj_Colon else St_After_Val);
               else
                  if C >= Character'Val (16#80#) then
                     UTF8_Lead (C, U8_Need, U8_Lo, U8_Hi);
                     if U8_Need = 0 then
                        return Status_Invalid_Syntax;
                     end if;
                  end if;
                  Str_Len := Natural'Min (Str_Len + 1, Max_Ident_Len + 1);
               end if;
            elsif Lex = Lex_True_R then
               if C = 'r' then Lex := Lex_True_U; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_True_U then
               if C = 'u' then Lex := Lex_True_E; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_True_E then
               if C = 'e' then
                  Lex := Lex_None; State := St_After_Val;
               else
                  return Status_Invalid_Syntax;
               end if;
            elsif Lex = Lex_False_A then
               if C = 'a' then Lex := Lex_False_L; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_False_L then
               if C = 'l' then Lex := Lex_False_S; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_False_S then
               if C = 's' then Lex := Lex_False_E; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_False_E then
               if C = 'e' then
                  Lex := Lex_None; State := St_After_Val;
               else
                  return Status_Invalid_Syntax;
               end if;
            elsif Lex = Lex_Null_U then
               if C = 'u' then Lex := Lex_Null_L1; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_Null_L1 then
               if C = 'l' then Lex := Lex_Null_L2; else return Status_Invalid_Syntax; end if;
            elsif Lex = Lex_Null_L2 then
               if C = 'l' then
                  Lex := Lex_None; State := St_After_Val;
               else
                  return Status_Invalid_Syntax;
               end if;
            elsif Lex = Lex_Num_After_Minus then
               if C = '0' then
                  Lex := Lex_Num_Zero;
               elsif C in '1' .. '9' then
                  Lex := Lex_Num_Has_Digit;
               else
                  return Status_Invalid_Syntax;
               end if;
            elsif Lex = Lex_Num_Zero then
               if C in '0' .. '9' then
                  return Status_Invalid_Syntax;
               elsif C = '.' then
                  Num_Has_Dot := True;
                  Lex         := Lex_Num_Need_Digit;
               elsif C = 'e' or else C = 'E' then
                  Num_Has_Exp := True;
                  Lex         := Lex_Num_Exp_Sign;
               else
                  if JSONB and then Limits and then not Number_In_PG_Range (Raw, Num_Start) then
                     return Status_Capacity_Exceeded;
                  end if;
                  Lex      := Lex_None;
                  State    := St_After_Val;
                  Consumed := False;
               end if;
            elsif Lex = Lex_Num_Need_Digit then
               if C in '0' .. '9' then
                  Lex := Lex_Num_Has_Digit;
               else
                  return Status_Invalid_Syntax;
               end if;
            elsif Lex = Lex_Num_Exp_Sign then
               if C = '+' or else C = '-' then
                  Lex := Lex_Num_Need_Digit;
               elsif C in '0' .. '9' then
                  Lex := Lex_Num_Has_Digit;
               else
                  return Status_Invalid_Syntax;
               end if;
            elsif Lex = Lex_Num_Has_Digit then
               if C in '0' .. '9' then
                  null;
               elsif C = '.' and then not Num_Has_Dot and then not Num_Has_Exp then
                  Num_Has_Dot := True;
                  Lex         := Lex_Num_Need_Digit;
               elsif (C = 'e' or else C = 'E') and then not Num_Has_Exp then
                  Num_Has_Exp := True;
                  Lex         := Lex_Num_Exp_Sign;
               else
                  if JSONB and then Limits and then not Number_In_PG_Range (Raw, Num_Start) then
                     return Status_Capacity_Exceeded;
                  end if;
                  Lex      := Lex_None;
                  State    := St_After_Val;
                  Consumed := False;
               end if;
            else
               Consumed := False;
            end if;

            --  2. Outside lexical tokens: skip whitespace and advance grammar state
            if not Consumed and then not Is_WS then
               case State is
                  when St_Root | St_Arr_Val_Or_End | St_Val =>
                     if State = St_Arr_Val_Or_End and then C = ']' then
                        if Depth = 0 or else Stack (Depth) /= '[' then
                           return Status_Invalid_Syntax;
                        end if;
                        Depth := Depth - 1;
                        State := St_After_Val;
                     elsif C = '"' then
                        String_Is_Key := False;
                        Escaped       := False;
                        Hex_Needed    := 0;
                        Need_Low      := False;
                        U8_Need       := 0;
                        Str_Len       := 0;
                        Lex           := Lex_String;
                     elsif C = '{' or else C = '[' then
                        if Depth >= Max_Depth then
                           return Status_Capacity_Exceeded;
                        end if;
                        Depth         := Depth + 1;
                        Stack (Depth) := C;
                        State         := (if C = '{' then St_Obj_Key_Or_End else St_Arr_Val_Or_End);
                     elsif C = '-' or else C in '0' .. '9' then
                        Num_Has_Dot := False;
                        Num_Has_Exp := False;
                        Num_Start   := I;
                        Lex         := (if C = '-' then Lex_Num_After_Minus
                                        elsif C = '0' then Lex_Num_Zero
                                        else Lex_Num_Has_Digit);
                     elsif C = 't' then
                        Lex := Lex_True_R;
                     elsif C = 'f' then
                        Lex := Lex_False_A;
                     elsif C = 'n' then
                        Lex := Lex_Null_U;
                     else
                        return Status_Invalid_Syntax;
                     end if;

                  when St_Obj_Key_Or_End | St_Obj_Key =>
                     if State = St_Obj_Key_Or_End and then C = '}' then
                        if Depth = 0 or else Stack (Depth) /= '{' then
                           return Status_Invalid_Syntax;
                        end if;
                        Depth := Depth - 1;
                        State := St_After_Val;
                     elsif C = '"' then
                        String_Is_Key := True;
                        Escaped       := False;
                        Hex_Needed    := 0;
                        Need_Low      := False;
                        U8_Need       := 0;
                        Str_Len       := 0;
                        Lex           := Lex_String;
                     else
                        return Status_Invalid_Syntax;
                     end if;

                  when St_Obj_Colon =>
                     if C = ':' then
                        State := St_Val;
                     else
                        return Status_Invalid_Syntax;
                     end if;

                  when St_After_Val =>
                     if Depth = 0 then
                        --  Root value/container already closed: reject trailing tokens
                        return Status_Invalid_Syntax;
                     elsif C = ',' then
                        State := (if Stack (Depth) = '{' then St_Obj_Key else St_Val);
                     elsif C = '}' or else C = ']' then
                        if Stack (Depth) /= (if C = '}' then '{' else '[') then
                           return Status_Invalid_Syntax;
                        end if;
                        Depth := Depth - 1;
                     else
                        return Status_Invalid_Syntax;
                     end if;
               end case;
            end if;
         end;
      end loop;

      --  If a root scalar number ended at EOF, finalize it
      if Depth = 0
        and then (Lex = Lex_Num_Zero or else Lex = Lex_Num_Has_Digit)
      then
         if JSONB and then Limits and then not Number_In_PG_Range (Raw, Num_Start) then
            return Status_Capacity_Exceeded;
         end if;
         Lex   := Lex_None;
         State := St_After_Val;
      end if;

      if State = St_After_Val
        and then Lex = Lex_None
        and then Depth = 0
        and then not Escaped
        and then Hex_Needed = 0
        and then not Need_Low
        and then U8_Need = 0
      then
         return Status_Ok;
      else
         return Status_Invalid_Syntax;
      end if;
   end Check_JSON_Text;

   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean is
     (Check_JSON_Text (Raw, JSONB => False, Max_Depth => Max_Text_Len) = Status_Ok);

   -------------------------------------------------------------------------
   --  Lexical scanners over (validated) raw JSON text
   -------------------------------------------------------------------------

   --  First position >= P holding a non-whitespace character (T.Length + 1 if none)
   function Skip_WS (T : Bounded_Text; P : Positive) return Positive
     with Global => null,
          Pre    => P <= T.Length + 1,
          Post   => Skip_WS'Result in P .. T.Length + 1
                    and then (if Skip_WS'Result <= T.Length then
                                not Is_Whitespace (T.Data (Skip_WS'Result)))
   is
      Q : Positive := P;
   begin
      while Q <= T.Length and then Is_Whitespace (T.Data (Q)) loop
         pragma Loop_Invariant (Q in P .. T.Length);
         pragma Loop_Variant (Increases => Q);
         Q := Q + 1;
      end loop;
      return Q;
   end Skip_WS;

   --  T.Data (P) = '"': position just after the closing quote (0 if unterminated)
   function String_End (T : Bounded_Text; P : Positive) return Natural
     with Global => null,
          Pre    => P <= T.Length,
          Post   => String_End'Result = 0
                    or else (T.Data (P) = '"' and then String_End'Result in P + 2 .. T.Length + 1)
   is
      Esc : Boolean := False;
   begin
      if T.Data (P) /= '"' then
         return 0;
      end if;
      for Q in P + 1 .. T.Length loop
         if Esc then
            Esc := False;
         elsif T.Data (Q) = '\' then
            Esc := True;
         elsif T.Data (Q) = '"' then
            return Q + 1;
         end if;
      end loop;
      return 0;
   end String_End;

   --  T.Data (P) starts a JSON value: position just after it (0 if malformed)
   function Value_End (T : Bounded_Text; P : Positive) return Natural
     with Global => null,
          Pre    => P <= T.Length,
          Post   => Value_End'Result = 0 or else Value_End'Result in P + 1 .. T.Length + 1
   is
      C      : constant Character := T.Data (P);
      Depth  : Natural := 0;
      In_Str : Boolean := False;
      Esc    : Boolean := False;
   begin
      if C = '"' then
         return String_End (T, P);
      elsif C = '{' or else C = '[' then
         for Q in P .. T.Length loop
            pragma Loop_Invariant (Depth <= Q - P);
            if In_Str then
               if Esc then
                  Esc := False;
               elsif T.Data (Q) = '\' then
                  Esc := True;
               elsif T.Data (Q) = '"' then
                  In_Str := False;
               end if;
            elsif T.Data (Q) = '"' then
               In_Str := True;
            elsif T.Data (Q) = '{' or else T.Data (Q) = '[' then
               Depth := Depth + 1;
            elsif T.Data (Q) = '}' or else T.Data (Q) = ']' then
               if Depth <= 1 then
                  return (if Depth = 1 then Q + 1 else 0);
               end if;
               Depth := Depth - 1;
            end if;
         end loop;
         return 0;
      elsif Is_Delimiter (C) then
         return 0;
      else
         for Q in P + 1 .. T.Length loop
            if Is_Delimiter (T.Data (Q)) then
               return Q;
            end if;
         end loop;
         return T.Length + 1;
      end if;
   end Value_End;

   --  Outcome of one scanning step
   type Step_Kind is (Step_Item, Step_Close, Step_Error);

   --  Position of the next item of an object or array
   type Item_Step is record
      Kind : Step_Kind := Step_Error;
      Pos  : Positive  := 1;
   end record;

   --  One decoded unit of a JSON string token
   type Code_Step is record
      Kind : Step_Kind := Step_Error;
      Code : Natural   := 0;
      Next : Positive  := 1;
   end record;

   --  T.Data (Q) = '\': Unicode scalar value of the escape starting there. A
   --  `\uXXXX` high surrogate must be followed by a `\uXXXX` low surrogate (the
   --  pair yields one code point); U+0000 and lone surrogates are malformed.
   function Escape_Code (T : Bounded_Text; Q : Positive) return Code_Step
     with Global => null,
          Pre    => Q <= T.Length,
          Post   => (if Escape_Code'Result.Kind /= Step_Error then
                       Escape_Code'Result.Kind = Step_Item
                       and then Escape_Code'Result.Code in 1 .. 16#10_FFFF#
                       and then Escape_Code'Result.Next in Q + 2 .. T.Length + 1
                       and then UTF8_Length (Escape_Code'Result.Code)
                                  <= Escape_Code'Result.Next - Q)
   is
      Code : Integer;
      Low  : Integer;
   begin
      if Q = T.Length or else T.Data (Q) /= '\' then
         return (others => <>);
      elsif T.Data (Q + 1) /= 'u' then
         if not Is_Simple_Escape (T.Data (Q + 1)) then
            return (others => <>);
         end if;
         return (Kind => Step_Item,
                 Code => Character'Pos (Decode_Escape_Char (T.Data (Q + 1))),
                 Next => Q + 2);
      elsif T.Length - Q < 5 then
         return (others => <>);
      end if;

      Code := Hex4 (T, Q + 2);
      if Code in 16#D800# .. 16#DBFF# then
         if T.Length - Q < 11
           or else T.Data (Q + 6) /= '\'
           or else T.Data (Q + 7) /= 'u'
         then
            return (others => <>);
         end if;
         Low := Hex4 (T, Q + 8);
         if Low not in 16#DC00# .. 16#DFFF# then
            return (others => <>);
         end if;
         return (Kind => Step_Item,
                 Code => 16#1_0000# + (Code - 16#D800#) * 16#400# + (Low - 16#DC00#),
                 Next => Q + 12);
      elsif Code < 1 or else Code in 16#DC00# .. 16#DFFF# then
         --  Invalid hex digits, U+0000, or a lone low surrogate
         return (others => <>);
      end if;
      return (Kind => Step_Item, Code => Code, Next => Q + 6);
   end Escape_Code;

   --  Unit of a JSON string token at T.Data (Q) (inside the quotes): Step_Item
   --  with the Unicode scalar value of an escape or raw UTF-8 sequence,
   --  Step_Close at the closing quote, Step_Error if malformed
   function Next_Code (T : Bounded_Text; Q : Positive) return Code_Step
     with Global => null,
          Pre    => Q <= T.Length,
          Post   => (if Next_Code'Result.Kind = Step_Item then
                       Next_Code'Result.Next in Q + 1 .. T.Length + 1)
   is
      C    : constant Character := T.Data (Q);
      Need : UTF8_Count;
      Lo   : Character;
      Hi   : Character;
      Code : Natural;
   begin
      if C = '"' then
         return (Kind => Step_Close, Code => 0, Next => Q);
      elsif C = '\' then
         return Escape_Code (T, Q);
      elsif C < Character'Val (16#80#) then
         return (Kind => Step_Item, Code => Character'Pos (C), Next => Q + 1);
      end if;

      UTF8_Lead (C, Need, Lo, Hi);
      if Need = 0 or else T.Length - Q < Need or else T.Data (Q + 1) not in Lo .. Hi then
         return (others => <>);
      end if;
      Code := Character'Pos (C) - (if Need = 1 then 16#C0# elsif Need = 2 then 16#E0# else 16#F0#);
      Code := Code * 16#40# + (Character'Pos (T.Data (Q + 1)) - 16#80#);
      if Need >= 2 then
         if T.Data (Q + 2) not in Character'Val (16#80#) .. Character'Val (16#BF#) then
            return (others => <>);
         end if;
         Code := Code * 16#40# + (Character'Pos (T.Data (Q + 2)) - 16#80#);
      end if;
      if Need = 3 then
         if T.Data (Q + 3) not in Character'Val (16#80#) .. Character'Val (16#BF#) then
            return (others => <>);
         end if;
         Code := Code * 16#40# + (Character'Pos (T.Data (Q + 3)) - 16#80#);
      end if;
      return (Kind => Step_Item, Code => Code, Next => Q + 1 + Need);
   end Next_Code;

   --  Decoded JSON string token (escapes resolved, surrogate pairs combined
   --  into one 4-byte UTF-8 sequence); Next follows the closing quote
   type Decoded_String is record
      Ok   : Boolean      := False;
      Text : Bounded_Text := (Length => 0, Data => [others => ' ']);
      Next : Positive     := 1;
   end record;

   function Decode_String (T : Bounded_Text; P : Positive) return Decoded_String
     with Global => null,
          Pre    => P <= T.Length,
          Post   => (if Decode_String'Result.Ok then
                       T.Data (P) = '"'
                       and then Decode_String'Result.Next in P + 2 .. T.Length + 1
                       and then Decode_String'Result.Text.Length
                                  <= Decode_String'Result.Next - P - 2)
   is
      Res  : Decoded_String;
      Q    : Positive := P + 1;
      Step : Code_Step;
   begin
      if T.Data (P) /= '"' then
         return Res;
      end if;

      while Q <= T.Length loop
         pragma Loop_Invariant (Q in P + 1 .. T.Length);
         pragma Loop_Invariant (Res.Text.Length <= Q - P - 1 and then not Res.Ok);
         pragma Loop_Variant (Increases => Q);
         if T.Data (Q) = '"' then
            Res.Ok   := True;
            Res.Next := Q + 1;
            return Res;
         elsif T.Data (Q) /= '\' then
            --  Raw bytes are copied (UTF-8 well-formedness is checked at ingest)
            Res.Text.Length := Res.Text.Length + 1;
            Res.Text.Data (Res.Text.Length) := T.Data (Q);
            Q := Q + 1;
         else
            Step := Escape_Code (T, Q);
            if Step.Kind = Step_Error then
               return Res;
            end if;
            Append_Code_Point (Res.Text, Step.Code);
            Q := Step.Next;
         end if;
      end loop;
      return Res;
   end Decode_String;

   --  Equality of two JSON string tokens after escape decoding, compared one
   --  code point at a time (no buffers, so the recursive `@>` frame stays small)
   function Equal_String_Tokens
     (A  : Bounded_Text;
      AP : Positive;
      B  : Bounded_Text;
      BP : Positive) return Boolean
     with Global => null,
          Pre    => AP <= A.Length and then BP <= B.Length,
          Post   => (if Equal_String_Tokens'Result then A.Data (AP) = '"' and then B.Data (BP) = '"')
   is
      QA : Positive := AP + 1;
      QB : Positive := BP + 1;
      SA : Code_Step;
      SB : Code_Step;
   begin
      if A.Data (AP) /= '"' or else B.Data (BP) /= '"' then
         return False;
      end if;
      while QA <= A.Length and then QB <= B.Length loop
         pragma Loop_Invariant (QA in AP + 1 .. A.Length and then QB in BP + 1 .. B.Length);
         pragma Loop_Variant (Increases => QA);
         SA := Next_Code (A, QA);
         SB := Next_Code (B, QB);
         if SA.Kind /= SB.Kind or else SA.Kind = Step_Error then
            return False;
         elsif SA.Kind = Step_Close then
            return True;
         elsif SA.Code /= SB.Code then
            return False;
         end if;
         QA := SA.Next;
         QB := SB.Next;
      end loop;
      return False;
   end Equal_String_Tokens;

   --  T.Data (Q) = '"' starts an object member `"key" : value`: position of the
   --  value's first character (0 if malformed)
   function Member_Value (T : Bounded_Text; Q : Positive) return Natural
     with Global => null,
          Pre    => Q <= T.Length,
          Post   => Member_Value'Result = 0 or else Member_Value'Result in Q + 3 .. T.Length
   is
      K_End : constant Natural := String_End (T, Q);
      Colon : Positive;
      V     : Positive;
   begin
      if K_End = 0 then
         return 0;
      end if;
      Colon := Skip_WS (T, K_End);
      if Colon > T.Length or else T.Data (Colon) /= ':' then
         return 0;
      end if;
      V := Skip_WS (T, Colon + 1);
      if V > T.Length then
         return 0;
      end if;
      return V;
   end Member_Value;

   --  T.Data (Open) is '{' or '[': first item, or Step_Close if empty
   function First_Item
     (T     : Bounded_Text;
      Open  : Positive;
      Close : Character) return Item_Step
     with Global => null,
          Pre    => Open <= T.Length,
          Post   => (if First_Item'Result.Kind = Step_Item then
                       First_Item'Result.Pos in Open + 1 .. T.Length)
   is
      Q : constant Positive := Skip_WS (T, Open + 1);
   begin
      if Q > T.Length then
         return (Kind => Step_Error, Pos => 1);
      elsif T.Data (Q) = Close then
         return (Kind => Step_Close, Pos => Q);
      else
         return (Kind => Step_Item, Pos => Q);
      end if;
   end First_Item;

   --  From follows an item: next item after ',', or Step_Close at Close
   function Next_Item
     (T     : Bounded_Text;
      From  : Positive;
      Close : Character) return Item_Step
     with Global => null,
          Pre    => From <= T.Length + 1,
          Post   => (if Next_Item'Result.Kind = Step_Item then
                       Next_Item'Result.Pos in From + 1 .. T.Length)
   is
      C : constant Positive := Skip_WS (T, From);
      Q : Positive;
   begin
      if C > T.Length then
         return (Kind => Step_Error, Pos => 1);
      elsif T.Data (C) = Close then
         return (Kind => Step_Close, Pos => C);
      elsif T.Data (C) /= ',' then
         return (Kind => Step_Error, Pos => 1);
      end if;
      Q := Skip_WS (T, C + 1);
      if Q > T.Length then
         return (Kind => Step_Error, Pos => 1);
      end if;
      return (Kind => Step_Item, Pos => Q);
   end Next_Item;

   --  Copy of T.Data (From .. To)
   function Slice (T : Bounded_Text; From, To : Positive) return Bounded_Text
     with Global => null,
          Pre    => From <= To and then To <= T.Length,
          Post   => Slice'Result.Length = To - From + 1
   is
      Res : Bounded_Text := (Length => To - From + 1, Data => [others => ' ']);
   begin
      for I in 1 .. To - From + 1 loop
         pragma Loop_Invariant (Res.Length = To - From + 1);
         Res.Data (I) := T.Data (From + I - 1);
      end loop;
      return Res;
   end Slice;

   -------------------------------------------------------------------------
   --  Is_Valid_Field_Value
   -------------------------------------------------------------------------

   function Is_Valid_Field_Value
     (Val  : Bounded_Text;
      Kind : JSONB_Value_Kind) return Boolean
   is
      First : constant Positive := Skip_WS (Val, 1);
   begin
      case Kind is
         when JSONB_String =>
            --  Decoded bytes (escapes already resolved by Parse_JSONB)
            return (for all I in 1 .. Val.Length => Val.Data (I) /= ASCII.NUL)
              and then Is_Valid_UTF8 (Val)
              and then JSON_Quoted_Length (Val) <= Max_Text_Len;

         when JSONB_Null =>
            return Val.Length = 0 or else Equal_Text (Val, Make_Text ("null"));

         when JSONB_Boolean =>
            return Equal_Text (Val, Make_Text ("true"))
              or else Equal_Text (Val, Make_Text ("false"));

         when JSONB_Number =>
            return First <= Val.Length
              and then (Val.Data (First) = '-' or else Val.Data (First) in '0' .. '9')
              and then Check_JSON_Text (Val, True, Max_JSONB_Depth - 1) = Status_Ok;

         when JSONB_Object =>
            return First <= Val.Length
              and then Val.Data (First) = '{'
              and then Check_JSON_Text (Val, True, Max_JSONB_Depth - 1) = Status_Ok;

         when JSONB_Array =>
            return First <= Val.Length
              and then Val.Data (First) = '['
              and then Check_JSON_Text (Val, True, Max_JSONB_Depth - 1) = Status_Ok;
      end case;
   end Is_Valid_Field_Value;

   -------------------------------------------------------------------------
   --  Has_Key, Find_Field & Put_Field
   -------------------------------------------------------------------------

   function Has_Key
     (Doc : JSONB_Document;
      Key : Bounded_Ident) return Boolean
   is
   begin
      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant
           (I in 1 .. Doc.Count
            and then (for all J in 1 .. I - 1 =>
                        not (Doc.Fields (J).Active
                             and then Equal_Ident (Doc.Fields (J).Key, Key))));
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Key;

   function Find_Field
     (Doc : JSONB_Document;
      Key : Bounded_Ident) return Field_Count
   is
   begin
      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 =>
              not (Doc.Fields (J).Active
                   and then Equal_Ident (Doc.Fields (J).Key, Key)));
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Field;

   procedure Put_Field
     (Doc    : in out JSONB_Document;
      Key    : in     Bounded_Ident;
      Val    : in     Bounded_Text;
      Kind   : in     JSONB_Value_Kind;
      Status :    out Engine_Status)
   is
      Norm_Val : Bounded_Text := Val;
   begin
      if not Is_Valid_JSONB_Key (Key) or else not Is_Valid_Field_Value (Val, Kind) then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      if Kind = JSONB_Null and then Norm_Val.Length = 0 then
         Norm_Val := Make_Text ("null");
      end if;

      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant (I in 1 .. Doc.Count);
         pragma Loop_Invariant (Doc.Count = Doc.Count'Loop_Entry);
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            Doc.Fields (I).Val  := Norm_Val;
            Doc.Fields (I).Kind := Kind;
            pragma Assert
              (Doc.Fields (I).Active
               and then Equal_Ident (Doc.Fields (I).Key, Key));
            Status := Status_Ok;
            return;
         end if;
      end loop;

      if Doc.Count < Max_JSON_Fields then
         Doc.Count := Doc.Count + 1;
         Doc.Fields (Doc.Count) := (
            Key    => Key,
            Val    => Norm_Val,
            Kind   => Kind,
            Active => True
         );
         pragma Assert
           (Doc.Fields (Doc.Count).Active
            and then Equal_Ident (Doc.Fields (Doc.Count).Key, Key));
         Status := Status_Ok;
      else
         Status := Status_Capacity_Exceeded;
      end if;
   end Put_Field;

   -------------------------------------------------------------------------
   --  Parse_JSONB (Decompose JSON object string into JSONB_Document)
   -------------------------------------------------------------------------

   procedure Parse_JSONB
     (Raw    : in     Bounded_Text;
      Doc    :    out JSONB_Document;
      Status :    out Engine_Status)
   is
      Open     : Positive;
      Step     : Item_Step;
      Key_Dec  : Decoded_String;
      Val_Dec  : Decoded_String;
      Key_Id   : Bounded_Ident;
      Val_Text : Bounded_Text;
      Val_Kind : JSONB_Value_Kind;
      Colon    : Positive;
      Val_Pos  : Positive;
      Val_End  : Natural;
   begin
      Doc := (others => <>);

      --  Every Status_Invalid_Syntax rule wins over the ingest limits, whatever
      --  their order in the text: syntax, then an object root, then empty keys
      if not Is_Valid_JSON (Raw) then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      Open := Skip_WS (Raw, 1);
      if Open > Raw.Length or else Raw.Data (Open) /= '{' then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      if Check_JSON_Text (Raw, True, Max_Text_Len, Limits => False) /= Status_Ok then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  All JSONB ingest rules are checked on the whole document first, so a
      --  nested value can never be stored in a form `@>` cannot compare
      Status := Check_JSON_Text (Raw, True, Max_JSONB_Depth);
      if Status /= Status_Ok then
         return;
      end if;

      Step := First_Item (Raw, Open, '}');
      while Step.Kind = Step_Item loop
         pragma Loop_Invariant (Step.Pos in Open + 1 .. Raw.Length);
         pragma Loop_Variant (Increases => Step.Pos);

         --  Key: decoded, 1 .. Max_Ident_Len bytes
         Key_Dec := Decode_String (Raw, Step.Pos);
         if not Key_Dec.Ok or else Key_Dec.Text.Length = 0 then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         elsif Key_Dec.Text.Length > Max_Ident_Len then
            Doc    := (others => <>);
            Status := Status_Capacity_Exceeded;
            return;
         end if;
         Key_Id := (Length => Key_Dec.Text.Length, Data => [others => ' ']);
         for I in 1 .. Key_Dec.Text.Length loop
            pragma Loop_Invariant (Key_Id.Length = Key_Dec.Text.Length);
            Key_Id.Data (I) := Key_Dec.Text.Data (I);
         end loop;

         Colon := Skip_WS (Raw, Key_Dec.Next);
         if Colon > Raw.Length or else Raw.Data (Colon) /= ':' then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Val_Pos := Skip_WS (Raw, Colon + 1);
         if Val_Pos > Raw.Length then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;

         --  Value: strings are stored decoded, everything else as raw JSON text
         Val_Kind := Kind_Of (Raw.Data (Val_Pos));
         if Val_Kind = JSONB_String then
            Val_Dec := Decode_String (Raw, Val_Pos);
            if not Val_Dec.Ok then
               Doc    := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
            Val_Text := Val_Dec.Text;
            Val_End  := Val_Dec.Next;
         else
            Val_End := Value_End (Raw, Val_Pos);
            if Val_End = 0 then
               Doc    := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
            Val_Text := Slice (Raw, Val_Pos, Val_End - 1);
         end if;

         Put_Field (Doc, Key_Id, Val_Text, Val_Kind, Status);
         if Status /= Status_Ok then
            Doc := (others => <>);
            return;
         end if;

         Step := Next_Item (Raw, Val_End, '}');
      end loop;

      if Step.Kind /= Step_Close then
         Doc    := (others => <>);
         Status := Status_Invalid_Syntax;
         return;
      end if;
      Status := Status_Ok;
   end Parse_JSONB;

   -------------------------------------------------------------------------
   --  Get_Field (`->`) & Get_Field_Text (`->>`)
   -------------------------------------------------------------------------

   procedure Format_Quoted_JSON_String
     (Raw_Val : in     Bounded_Text;
      Quoted  :    out Bounded_Text)
     with Global => null,
          Always_Terminates,
          Pre    => JSON_Quoted_Length (Raw_Val) <= Max_Text_Len,
          Post   => Quoted.Length = JSON_Quoted_Length (Raw_Val)
                    and then Quoted.Data (1) = '"'
                    and then Quoted.Data (Quoted.Length) = '"'
   is
      Hex_Tab : constant array (0 .. 15) of Character :=
        ['0', '1', '2', '3', '4', '5', '6', '7',
         '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
      L       : Text_Length;
   begin
      Quoted := (Length => 1, Data => [1 => '"', others => ' ']);

      for K in 1 .. Raw_Val.Length loop
         pragma Loop_Invariant
           (Quoted.Length >= 1
            and then Quoted.Data (1) = '"'
            and then Quoted.Length + JSON_Escaped_Suffix_Length (Raw_Val, K) + 1
                       = JSON_Quoted_Length (Raw_Val));
         L := Quoted.Length;
         declare
            C : constant Character := Raw_Val.Data (K);
         begin
            case C is
               when '"' | '\' | ASCII.BS | ASCII.HT | ASCII.LF | ASCII.FF | ASCII.CR =>
                  Quoted.Data (L + 1) := '\';
                  Quoted.Data (L + 2) :=
                    (case C is
                        when ASCII.BS => 'b',
                        when ASCII.HT => 't',
                        when ASCII.LF => 'n',
                        when ASCII.FF => 'f',
                        when ASCII.CR => 'r',
                        when others   => C);
                  Quoted.Length := L + 2;
               when ASCII.NUL .. ASCII.BEL | ASCII.VT | ASCII.SO .. ASCII.US =>
                  Quoted.Data (L + 1) := '\';
                  Quoted.Data (L + 2) := 'u';
                  Quoted.Data (L + 3) := '0';
                  Quoted.Data (L + 4) := '0';
                  Quoted.Data (L + 5) := Hex_Tab (Character'Pos (C) / 16);
                  Quoted.Data (L + 6) := Hex_Tab (Character'Pos (C) mod 16);
                  Quoted.Length := L + 6;
               when others =>
                  Quoted.Data (L + 1) := C;
                  Quoted.Length := L + 1;
            end case;
         end;
      end loop;

      Quoted.Length := Quoted.Length + 1;
      Quoted.Data (Quoted.Length) := '"';
   end Format_Quoted_JSON_String;

   procedure Get_Field
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text;
      Kind  :    out JSONB_Value_Kind)
   is
      I : constant Field_Count := Find_Field (Doc, Key);
   begin
      Val   := (Length => 0, Data => [others => ' ']);
      Kind  := JSONB_Null;
      Found := I /= 0;
      if I /= 0 then
         Kind := Doc.Fields (I).Kind;
         --  PostgreSQL `->` returns valid JSON (strings wrapped in quotes & escaped).
         --  A string too long to quote is unreachable through Put_Field/Parse_JSONB
         --  (Is_Valid_Field_Value); for a hand-built document Val stays empty.
         if Kind /= JSONB_String then
            Val := Doc.Fields (I).Val;
         elsif JSON_Quoted_Length (Doc.Fields (I).Val) <= Max_Text_Len then
            Format_Quoted_JSON_String (Doc.Fields (I).Val, Val);
         end if;
      end if;
   end Get_Field;

   procedure Get_Field_Text
     (Doc     : in     JSONB_Document;
      Key     : in     Bounded_Ident;
      Found   :    out Boolean;
      Val     :    out Bounded_Text;
      Is_Null :    out Boolean)
   is
      I : constant Field_Count := Find_Field (Doc, Key);
   begin
      Val     := (Length => 0, Data => [others => ' ']);
      Found   := I /= 0;
      Is_Null := False;
      if I /= 0 then
         if Doc.Fields (I).Kind = JSONB_Null then
            Is_Null := True;
         else
            Val := Doc.Fields (I).Val;
         end if;
      end if;
   end Get_Field_Text;

   -------------------------------------------------------------------------
   --  Contains (`@>`): PostgreSQL JsonbDeepContains over raw JSON text
   -------------------------------------------------------------------------

   --  Does a member of the object containing T.Data (Key_Q) that starts after
   --  From (the end of that member's value) repeat its key? PostgreSQL keeps
   --  only the last duplicate of a key.
   function Key_Repeats_Later
     (T     : Bounded_Text;
      Key_Q : Positive;
      From  : Positive) return Boolean
     with Global => null,
          Pre    => Key_Q <= T.Length and then From <= T.Length + 1,
          Post   => (if Key_Repeats_Later'Result then T.Data (Key_Q) = '"')
   is
      Step  : Item_Step := Next_Item (T, From, '}');
      V     : Natural;
      V_End : Natural;
   begin
      while Step.Kind = Step_Item loop
         pragma Loop_Invariant (Step.Pos in From + 1 .. T.Length);
         pragma Loop_Variant (Increases => Step.Pos);
         if Equal_String_Tokens (T, Key_Q, T, Step.Pos) then
            return True;
         end if;
         V := Member_Value (T, Step.Pos);
         if V = 0 then
            return False;
         end if;
         V_End := Value_End (T, V);
         if V_End = 0 then
            return False;
         end if;
         Step := Next_Item (T, V_End, '}');
      end loop;
      return False;
   end Key_Repeats_Later;

   --  L.Data (LP) = '{': value position of L's last member whose key equals
   --  the key token R.Data (Key_Q ..), 0 if none (or if L is malformed)
   function Last_Member_Value
     (L     : Bounded_Text;
      LP    : Positive;
      R     : Bounded_Text;
      Key_Q : Positive) return Natural
     with Global => null,
          Pre    => LP <= L.Length and then Key_Q <= R.Length,
          Post   => Last_Member_Value'Result = 0
                    or else Last_Member_Value'Result in LP + 1 .. L.Length
   is
      Step  : Item_Step := First_Item (L, LP, '}');
      V     : Natural;
      V_End : Natural;
      Last  : Natural   := 0;
   begin
      while Step.Kind = Step_Item loop
         pragma Loop_Invariant (Step.Pos in LP + 1 .. L.Length);
         pragma Loop_Invariant (Last = 0 or else Last in LP + 1 .. L.Length);
         pragma Loop_Variant (Increases => Step.Pos);
         V := Member_Value (L, Step.Pos);
         if V = 0 then
            return 0;
         end if;
         V_End := Value_End (L, V);
         if V_End = 0 then
            return 0;
         end if;
         if Equal_String_Tokens (L, Step.Pos, R, Key_Q) then
            Last := V;
         end if;
         Step := Next_Item (L, V_End, '}');
      end loop;
      return (if Step.Kind = Step_Close then Last else 0);
   end Last_Member_Value;

   --  Does the JSON value starting at L.Data (LP) contain the one starting at
   --  R.Data (RP)? Fuel bounds the container nesting still to be entered; the
   --  ingest rules (Max_JSONB_Depth) guarantee it never runs out for stored
   --  values. Recursion frames hold only positions (no buffers).
   function Value_Contains
     (L    : Bounded_Text;
      LP   : Positive;
      R    : Bounded_Text;
      RP   : Positive;
      Fuel : Natural) return Boolean
     with Global             => null,
          Pre                => LP <= L.Length and then RP <= R.Length,
          Post               => (if Value_Contains'Result then
                                   Kind_Of (L.Data (LP)) = Kind_Of (R.Data (RP))),
          Subprogram_Variant => (Decreases => Fuel)
   is
      RK : constant JSONB_Value_Kind := Kind_Of (R.Data (RP));
   begin
      if Kind_Of (L.Data (LP)) /= RK then
         return False;
      end if;

      case RK is
         when JSONB_Null =>
            return True;

         when JSONB_Boolean =>
            return L.Data (LP) = R.Data (RP);

         when JSONB_Number =>
            return Equal_Number_Tokens (L, LP, R, RP);

         when JSONB_String =>
            return Equal_String_Tokens (L, LP, R, RP);

         when JSONB_Object =>
            --  Every (last-occurrence) key of R must map to a contained value
            --  under the last occurrence of the same key in L
            if Fuel = 0 then
               return False;
            end if;
            declare
               Step  : Item_Step := First_Item (R, RP, '}');
               RV    : Natural;
               R_End : Natural;
               LV    : Natural;
            begin
               while Step.Kind = Step_Item loop
                  pragma Loop_Invariant (Step.Pos in RP + 1 .. R.Length);
                  pragma Loop_Variant (Increases => Step.Pos);
                  RV := Member_Value (R, Step.Pos);
                  if RV = 0 then
                     return False;
                  end if;
                  R_End := Value_End (R, RV);
                  if R_End = 0 then
                     return False;
                  end if;
                  if not Key_Repeats_Later (R, Step.Pos, R_End) then
                     LV := Last_Member_Value (L, LP, R, Step.Pos);
                     if LV = 0 or else not Value_Contains (L, LV, R, RV, Fuel - 1) then
                        return False;
                     end if;
                  end if;
                  Step := Next_Item (R, R_End, '}');
               end loop;
               return Step.Kind = Step_Close;
            end;

         when JSONB_Array =>
            --  Every element of R must be contained in some element of L
            --  (scalars by equality, containers recursively)
            if Fuel = 0 then
               return False;
            end if;
            declare
               R_Step  : Item_Step := First_Item (R, RP, ']');
               L_Step  : Item_Step;
               R_End   : Natural;
               L_End   : Natural;
               Matched : Boolean;
            begin
               while R_Step.Kind = Step_Item loop
                  pragma Loop_Invariant (R_Step.Pos in RP + 1 .. R.Length);
                  pragma Loop_Variant (Increases => R_Step.Pos);
                  R_End := Value_End (R, R_Step.Pos);
                  if R_End = 0 then
                     return False;
                  end if;
                  Matched := False;
                  L_Step  := First_Item (L, LP, ']');
                  while L_Step.Kind = Step_Item loop
                     pragma Loop_Invariant (L_Step.Pos in LP + 1 .. L.Length and then not Matched);
                     pragma Loop_Variant (Increases => L_Step.Pos);
                     if Value_Contains (L, L_Step.Pos, R, R_Step.Pos, Fuel - 1) then
                        Matched := True;
                        exit;
                     end if;
                     L_End := Value_End (L, L_Step.Pos);
                     if L_End = 0 then
                        return False;
                     end if;
                     L_Step := Next_Item (L, L_End, ']');
                  end loop;
                  if not Matched then
                     return False;
                  end if;
                  R_Step := Next_Item (R, R_End, ']');
               end loop;
               return R_Step.Kind = Step_Close;
            end;
      end case;
   end Value_Contains;

   --  Containment of one top-level field value in another
   function Field_Value_Contains (L_Entry, R_Entry : JSONB_Entry) return Boolean
     with Global => null,
          Post   => (if Field_Value_Contains'Result then L_Entry.Kind = R_Entry.Kind)
   is
      LP : Positive;
      RP : Positive;
   begin
      if L_Entry.Kind /= R_Entry.Kind then
         return False;
      end if;

      case R_Entry.Kind is
         when JSONB_Null =>
            return True;
         when JSONB_Boolean | JSONB_String =>
            --  Booleans are normalized literals; strings are stored decoded
            return Equal_Text (L_Entry.Val, R_Entry.Val);
         when JSONB_Number | JSONB_Object | JSONB_Array =>
            --  Stored as raw JSON text (Put_Field allows surrounding whitespace)
            LP := Skip_WS (L_Entry.Val, 1);
            RP := Skip_WS (R_Entry.Val, 1);
            if LP > L_Entry.Val.Length or else RP > R_Entry.Val.Length then
               return False;
            elsif R_Entry.Kind = JSONB_Number then
               return Equal_Number_Tokens (L_Entry.Val, LP, R_Entry.Val, RP);
            else
               return Value_Contains
                 (L_Entry.Val, LP, R_Entry.Val, RP, Max_JSONB_Depth - 1);
            end if;
      end case;
   end Field_Value_Contains;

   function Contains
     (Left, Right : JSONB_Document) return Boolean
   is
      I : Field_Count;
   begin
      for R in 1 .. Right.Count loop
         pragma Loop_Invariant
           (for all J in 1 .. R - 1 =>
              (if Right.Fields (J).Active then Has_Key (Left, Right.Fields (J).Key)));
         if Right.Fields (R).Active then
            I := Find_Field (Left, Right.Fields (R).Key);
            if I = 0 or else not Field_Value_Contains (Left.Fields (I), Right.Fields (R)) then
               return False;
            end if;
         end if;
      end loop;
      return True;
   end Contains;

end Nhe_O.JSON;
