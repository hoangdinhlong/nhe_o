pragma SPARK_Mode (On);

package body Nhe_O.JSON is

   function Is_Whitespace (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF or else C = ASCII.CR);

   -------------------------------------------------------------------------
   --  Is_Valid_JSON (RFC 8259 Objects, Arrays, and Scalar Roots, HIGH-04)
   -------------------------------------------------------------------------

   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean is
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
      String_Is_Key : Boolean      := False;
      Num_Has_Dot   : Boolean      := False;
      Num_Has_Exp   : Boolean      := False;
      Consumed      : Boolean;
   begin
      if Raw.Length < 1 then
         return False;
      end if;

      for I in 1 .. Raw.Length loop
         pragma Loop_Invariant
           (I in 1 .. Raw.Length and then Depth <= Max_Text_Len);
         declare
            C     : constant Character := Raw.Data (I);
            Is_WS : constant Boolean   := Is_Whitespace (C);
         begin
            Consumed := True;

            --  1. Handle active lexical token modes first
            if Lex = Lex_String then
               if Character'Pos (C) < 32 then
                  return False;
               elsif Hex_Needed > 0 then
                  if C in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' then
                     Hex_Needed := Hex_Needed - 1;
                  else
                     return False;
                  end if;
               elsif Escaped then
                  if C = 'u' then
                     Escaped    := False;
                     Hex_Needed := 4;
                  elsif C in '"' | '\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' then
                     Escaped := False;
                  else
                     return False;
                  end if;
               elsif C = '\' then
                  Escaped := True;
               elsif C = '"' then
                  Lex   := Lex_None;
                  State := (if String_Is_Key then St_Obj_Colon else St_After_Val);
               end if;
            elsif Lex = Lex_True_R then
               if C = 'r' then Lex := Lex_True_U; else return False; end if;
            elsif Lex = Lex_True_U then
               if C = 'u' then Lex := Lex_True_E; else return False; end if;
            elsif Lex = Lex_True_E then
               if C = 'e' then Lex := Lex_None; State := St_After_Val; else return False; end if;
            elsif Lex = Lex_False_A then
               if C = 'a' then Lex := Lex_False_L; else return False; end if;
            elsif Lex = Lex_False_L then
               if C = 'l' then Lex := Lex_False_S; else return False; end if;
            elsif Lex = Lex_False_S then
               if C = 's' then Lex := Lex_False_E; else return False; end if;
            elsif Lex = Lex_False_E then
               if C = 'e' then Lex := Lex_None; State := St_After_Val; else return False; end if;
            elsif Lex = Lex_Null_U then
               if C = 'u' then Lex := Lex_Null_L1; else return False; end if;
            elsif Lex = Lex_Null_L1 then
               if C = 'l' then Lex := Lex_Null_L2; else return False; end if;
            elsif Lex = Lex_Null_L2 then
               if C = 'l' then Lex := Lex_None; State := St_After_Val; else return False; end if;
            elsif Lex = Lex_Num_After_Minus then
               if C = '0' then
                  Lex := Lex_Num_Zero;
               elsif C in '1' .. '9' then
                  Lex := Lex_Num_Has_Digit;
               else
                  return False;
               end if;
            elsif Lex = Lex_Num_Zero then
               if C in '0' .. '9' then
                  return False;
               elsif C = '.' then
                  Num_Has_Dot := True;
                  Lex         := Lex_Num_Need_Digit;
               elsif C = 'e' or else C = 'E' then
                  Num_Has_Exp := True;
                  Lex         := Lex_Num_Exp_Sign;
               else
                  Lex      := Lex_None;
                  State    := St_After_Val;
                  Consumed := False;
               end if;
            elsif Lex = Lex_Num_Need_Digit then
               if C in '0' .. '9' then
                  Lex := Lex_Num_Has_Digit;
               else
                  return False;
               end if;
            elsif Lex = Lex_Num_Exp_Sign then
               if C = '+' or else C = '-' then
                  Lex := Lex_Num_Need_Digit;
               elsif C in '0' .. '9' then
                  Lex := Lex_Num_Has_Digit;
               else
                  return False;
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
                           return False;
                        end if;
                        Depth := Depth - 1;
                        State := St_After_Val;
                     elsif C = '"' then
                        String_Is_Key := False;
                        Escaped       := False;
                        Hex_Needed    := 0;
                        Lex           := Lex_String;
                     elsif C = '{' then
                        if Depth = Max_Text_Len then
                           return False;
                        end if;
                        Depth         := Depth + 1;
                        Stack (Depth) := '{';
                        State         := St_Obj_Key_Or_End;
                     elsif C = '[' then
                        if Depth = Max_Text_Len then
                           return False;
                        end if;
                        Depth         := Depth + 1;
                        Stack (Depth) := '[';
                        State         := St_Arr_Val_Or_End;
                     elsif C = '-' then
                        Num_Has_Dot := False;
                        Num_Has_Exp := False;
                        Lex         := Lex_Num_After_Minus;
                     elsif C = '0' then
                        Num_Has_Dot := False;
                        Num_Has_Exp := False;
                        Lex         := Lex_Num_Zero;
                     elsif C in '1' .. '9' then
                        Num_Has_Dot := False;
                        Num_Has_Exp := False;
                        Lex         := Lex_Num_Has_Digit;
                     elsif C = 't' then
                        Lex := Lex_True_R;
                     elsif C = 'f' then
                        Lex := Lex_False_A;
                     elsif C = 'n' then
                        Lex := Lex_Null_U;
                     else
                        return False;
                     end if;

                  when St_Obj_Key_Or_End =>
                     if C = '}' then
                        if Depth = 0 or else Stack (Depth) /= '{' then
                           return False;
                        end if;
                        Depth := Depth - 1;
                        State := St_After_Val;
                     elsif C = '"' then
                        String_Is_Key := True;
                        Escaped       := False;
                        Hex_Needed    := 0;
                        Lex           := Lex_String;
                     else
                        return False;
                     end if;

                  when St_Obj_Key =>
                     if C = '"' then
                        String_Is_Key := True;
                        Escaped       := False;
                        Hex_Needed    := 0;
                        Lex           := Lex_String;
                     else
                        return False;
                     end if;

                  when St_Obj_Colon =>
                     if C = ':' then
                        State := St_Val;
                     else
                        return False;
                     end if;

                  when St_After_Val =>
                     if Depth = 0 then
                        --  Root value/container already closed: reject trailing tokens
                        return False;
                     elsif C = ',' then
                        if Stack (Depth) = '{' then
                           State := St_Obj_Key;
                        else
                           State := St_Val;
                        end if;
                     elsif C = '}' then
                        if Stack (Depth) /= '{' then
                           return False;
                        end if;
                        Depth := Depth - 1;
                     elsif C = ']' then
                        if Stack (Depth) /= '[' then
                           return False;
                        end if;
                        Depth := Depth - 1;
                     else
                        return False;
                     end if;
               end case;
            end if;
         end;
      end loop;

      --  If a root scalar number ended at EOF, finalize it
      if Depth = 0
        and then (Lex = Lex_Num_Zero or else Lex = Lex_Num_Has_Digit)
      then
         Lex   := Lex_None;
         State := St_After_Val;
      end if;

      return State = St_After_Val
        and then Lex = Lex_None
        and then Depth = 0
        and then not Escaped
        and then Hex_Needed = 0;
   end Is_Valid_JSON;

   -------------------------------------------------------------------------
   --  Is_Valid_Field_Value (HIGH-04)
   -------------------------------------------------------------------------

   function First_Non_WS_Char (Val : Bounded_Text) return Character is
   begin
      for I in 1 .. Val.Length loop
         if not Is_Whitespace (Val.Data (I)) then
            return Val.Data (I);
         end if;
      end loop;
      return ' ';
   end First_Non_WS_Char;

   function Is_Valid_Field_Value
     (Val  : Bounded_Text;
      Kind : JSONB_Value_Kind) return Boolean
   is
      First_C : constant Character := First_Non_WS_Char (Val);
   begin
      case Kind is
         when JSONB_String =>
            --  Allow any decoded character except NUL (RFC 8259 escapes decoded by Parse_JSONB)
            return (for all I in 1 .. Val.Length =>
                      Character'Pos (Val.Data (I)) >= 1);

         when JSONB_Null =>
            return Val.Length = 0 or else Equal_Text (Val, Make_Text ("null"));

         when JSONB_Boolean =>
            return Equal_Text (Val, Make_Text ("true"))
              or else Equal_Text (Val, Make_Text ("false"));

         when JSONB_Number =>
            return Val.Length >= 1
              and then (First_C = '-' or else First_C in '0' .. '9')
              and then Is_Valid_JSON (Val);

         when JSONB_Object =>
            return Val.Length >= 2
              and then First_C = '{'
              and then Is_Valid_JSON (Val);

         when JSONB_Array =>
            return Val.Length >= 2
              and then First_C = '['
              and then Is_Valid_JSON (Val);
      end case;
   end Is_Valid_Field_Value;

   function Decode_Escape_Char (C : Character) return Character is
   begin
      case C is
         when 'n'    => return ASCII.LF;
         when 'r'    => return ASCII.CR;
         when 't'    => return ASCII.HT;
         when 'b'    => return ASCII.BS;
         when 'f'    => return ASCII.FF;
         when others => return C;
      end case;
   end Decode_Escape_Char;

   function Hex_Digit_Value (C : Character) return Natural
     with Post => Hex_Digit_Value'Result in 0 .. 15
   is
   begin
      if C in '0' .. '9' then
         return Character'Pos (C) - Character'Pos ('0');
      elsif C in 'a' .. 'f' then
         return 10 + (Character'Pos (C) - Character'Pos ('a'));
      elsif C in 'A' .. 'F' then
         return 10 + (Character'Pos (C) - Character'Pos ('A'));
      else
         return 0;
      end if;
   end Hex_Digit_Value;

   procedure Append_Unicode_Ident
     (H1, H2, H3, H4 : in     Character;
      Target         : in out Bounded_Ident;
      Stat           :    out Engine_Status)
     with Post => Target.Length <= Max_Ident_Len
   is
      Code : constant Natural :=
        Hex_Digit_Value (H1) * 4096 +
        Hex_Digit_Value (H2) * 256 +
        Hex_Digit_Value (H3) * 16 +
        Hex_Digit_Value (H4);
   begin
      if Code = 0 then
         Stat := Status_Invalid_Syntax;
      elsif Code <= 16#7F# then
         if Target.Length < Max_Ident_Len then
            Target.Length := Target.Length + 1;
            Target.Data (Target.Length) := Character'Val (Code);
            Stat := Status_Ok;
         else
            Stat := Status_Capacity_Exceeded;
         end if;
      elsif Code <= 16#7FF# then
         if Target.Length <= Max_Ident_Len - 2 then
            Target.Data (Target.Length + 1) := Character'Val (192 + Code / 64);
            Target.Data (Target.Length + 2) := Character'Val (128 + (Code mod 64));
            Target.Length := Target.Length + 2;
            Stat := Status_Ok;
         else
            Stat := Status_Capacity_Exceeded;
         end if;
      else
         if Target.Length <= Max_Ident_Len - 3 then
            Target.Data (Target.Length + 1) := Character'Val (224 + Code / 4096);
            Target.Data (Target.Length + 2) := Character'Val (128 + ((Code / 64) mod 64));
            Target.Data (Target.Length + 3) := Character'Val (128 + (Code mod 64));
            Target.Length := Target.Length + 3;
            Stat := Status_Ok;
         else
            Stat := Status_Capacity_Exceeded;
         end if;
      end if;
   end Append_Unicode_Ident;

   procedure Append_Unicode_Text
     (H1, H2, H3, H4 : in     Character;
      Target         : in out Bounded_Text;
      Stat           :    out Engine_Status)
     with Post => Target.Length <= Max_Text_Len
   is
      Code : constant Natural :=
        Hex_Digit_Value (H1) * 4096 +
        Hex_Digit_Value (H2) * 256 +
        Hex_Digit_Value (H3) * 16 +
        Hex_Digit_Value (H4);
   begin
      if Code = 0 then
         Stat := Status_Invalid_Syntax;
      elsif Code <= 16#7F# then
         if Target.Length < Max_Text_Len then
            Target.Length := Target.Length + 1;
            Target.Data (Target.Length) := Character'Val (Code);
            Stat := Status_Ok;
         else
            Stat := Status_Capacity_Exceeded;
         end if;
      elsif Code <= 16#7FF# then
         if Target.Length <= Max_Text_Len - 2 then
            Target.Data (Target.Length + 1) := Character'Val (192 + Code / 64);
            Target.Data (Target.Length + 2) := Character'Val (128 + (Code mod 64));
            Target.Length := Target.Length + 2;
            Stat := Status_Ok;
         else
            Stat := Status_Capacity_Exceeded;
         end if;
      else
         if Target.Length <= Max_Text_Len - 3 then
            Target.Data (Target.Length + 1) := Character'Val (224 + Code / 4096);
            Target.Data (Target.Length + 2) := Character'Val (128 + ((Code / 64) mod 64));
            Target.Data (Target.Length + 3) := Character'Val (128 + (Code mod 64));
            Target.Length := Target.Length + 3;
            Stat := Status_Ok;
         else
            Stat := Status_Capacity_Exceeded;
         end if;
      end if;
   end Append_Unicode_Text;

   -------------------------------------------------------------------------
   --  Has_Key & Put_Field
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

   procedure Put_Field
     (Doc    : in out JSONB_Document;
      Key    : in     Bounded_Ident;
      Val    : in     Bounded_Text;
      Kind   : in     JSONB_Value_Kind;
      Status :    out Engine_Status)
   is
      Norm_Val : Bounded_Text := Val;
   begin
      if not Is_Valid_Field_Value (Val, Kind) then
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
   --  Parse_JSONB (Decompose JSON object string into JSONB_Document, LOW-01)
   -------------------------------------------------------------------------

   procedure Parse_JSONB
     (Raw    : in     Bounded_Text;
      Doc    :    out JSONB_Document;
      Status :    out Engine_Status)
   is
      Pos      : Positive := 1;
      Key_Id   : Bounded_Ident;
      Val_Text : Bounded_Text;
      Val_Kind : JSONB_Value_Kind;
      Sub_Stat : Engine_Status;
      Brace_D  : Natural;
      In_Str   : Boolean;
      Esc      : Boolean;
   begin
      Doc := (others => <>);

      if not Is_Valid_JSON (Raw) or else First_Non_WS_Char (Raw) /= '{' then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  Skip leading whitespace and opening '{'
      while Pos <= Raw.Length and then Raw.Data (Pos) /= '{' loop
         pragma Loop_Invariant (Pos in 1 .. Raw.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos >= Raw.Length then
         Status := Status_Invalid_Syntax;
         return;
      end if;
      Pos := Pos + 1;

      --  Parse up to Max_JSON_Fields top-level key/value entries
      for Field_Step in 1 .. Max_JSON_Fields + 1 loop
         pragma Loop_Invariant (Pos in 1 .. Raw.Length + 1);

         while Pos <= Raw.Length and then Is_Whitespace (Raw.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos > Raw.Length then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;

         if Raw.Data (Pos) = '}' then
            Status := Status_Ok;
            return;
         end if;

         if Field_Step > 1 then
            if Raw.Data (Pos) /= ',' or else Pos = Raw.Length then
               Doc    := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
            Pos := Pos + 1;

            while Pos <= Raw.Length and then Is_Whitespace (Raw.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Raw.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;

            if Pos > Raw.Length then
               Doc    := (others => <>);
               Status := Status_Invalid_Syntax;
               return;
            end if;
         end if;

         if Raw.Data (Pos) /= '"' or else Pos = Raw.Length then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Pos := Pos + 1;

         --  Extract key string (unescaping standard RFC 8259 sequences including \uXXXX, R3-MED-01)
         Key_Id := (Length => 0, Data => [others => ' ']);
         Esc    := False;
         while Pos <= Raw.Length loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Invariant (Key_Id.Length <= Max_Ident_Len);
            pragma Loop_Variant (Increases => Pos);
            if Esc then
               Esc := False;
               if Raw.Data (Pos) = 'u' then
                  if Pos > Raw.Length - 4 then
                     Doc    := (others => <>);
                     Status := Status_Invalid_Syntax;
                     return;
                  end if;
                  Append_Unicode_Ident
                    (Raw.Data (Pos + 1), Raw.Data (Pos + 2),
                     Raw.Data (Pos + 3), Raw.Data (Pos + 4),
                     Key_Id, Sub_Stat);
                  if Sub_Stat /= Status_Ok then
                     Doc    := (others => <>);
                     Status := Sub_Stat;
                     return;
                  end if;
                  Pos := Pos + 4;
               elsif Key_Id.Length < Max_Ident_Len then
                  Key_Id.Length := Key_Id.Length + 1;
                  Key_Id.Data (Key_Id.Length) := Decode_Escape_Char (Raw.Data (Pos));
               else
                  Doc    := (others => <>);
                  Status := Status_Capacity_Exceeded;
                  return;
               end if;
            elsif Raw.Data (Pos) = '\' then
               Esc := True;
            elsif Raw.Data (Pos) = '"' then
               Pos := Pos + 1;
               exit;
            else
               if Key_Id.Length < Max_Ident_Len then
                  Key_Id.Length := Key_Id.Length + 1;
                  Key_Id.Data (Key_Id.Length) := Raw.Data (Pos);
               else
                  Doc    := (others => <>);
                  Status := Status_Capacity_Exceeded;
                  return;
               end if;
            end if;
            Pos := Pos + 1;
         end loop;

         if Key_Id.Length = 0 then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;

         --  Skip whitespace, require exactly one ':', then skip whitespace (R2-MED-02)
         while Pos <= Raw.Length and then Is_Whitespace (Raw.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos >= Raw.Length or else Raw.Data (Pos) /= ':' then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Pos := Pos + 1;

         while Pos <= Raw.Length and then Is_Whitespace (Raw.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos > Raw.Length
           or else Raw.Data (Pos) = ':'
           or else Raw.Data (Pos) = ','
           or else Raw.Data (Pos) = '}'
         then
            Doc    := (others => <>);
            Status := Status_Invalid_Syntax;
            return;
         end if;

         Val_Text := (Length => 0, Data => [others => ' ']);

         if Raw.Data (Pos) = '"' then
            Val_Kind := JSONB_String;
            if Pos < Raw.Length then
               Pos := Pos + 1;
            end if;
            Esc := False;
            while Pos <= Raw.Length loop
               pragma Loop_Invariant (Pos in 1 .. Raw.Length);
               pragma Loop_Invariant (Val_Text.Length <= Max_Text_Len);
               pragma Loop_Variant (Increases => Pos);
               if Esc then
                  Esc := False;
                  if Raw.Data (Pos) = 'u' then
                     if Pos > Raw.Length - 4 then
                        Doc    := (others => <>);
                        Status := Status_Invalid_Syntax;
                        return;
                     end if;
                     Append_Unicode_Text
                       (Raw.Data (Pos + 1), Raw.Data (Pos + 2),
                        Raw.Data (Pos + 3), Raw.Data (Pos + 4),
                        Val_Text, Sub_Stat);
                     if Sub_Stat /= Status_Ok then
                        Doc    := (others => <>);
                        Status := Sub_Stat;
                        return;
                     end if;
                     Pos := Pos + 4;
                  elsif Val_Text.Length < Max_Text_Len then
                     Val_Text.Length := Val_Text.Length + 1;
                     Val_Text.Data (Val_Text.Length) := Decode_Escape_Char (Raw.Data (Pos));
                  else
                     Doc    := (others => <>);
                     Status := Status_Capacity_Exceeded;
                     return;
                  end if;
               elsif Raw.Data (Pos) = '\' then
                  Esc := True;
               elsif Raw.Data (Pos) = '"' then
                  Pos := Pos + 1;
                  exit;
               else
                  if Val_Text.Length < Max_Text_Len then
                     Val_Text.Length := Val_Text.Length + 1;
                     Val_Text.Data (Val_Text.Length) := Raw.Data (Pos);
                  else
                     Doc    := (others => <>);
                     Status := Status_Capacity_Exceeded;
                     return;
                  end if;
               end if;
               Pos := Pos + 1;
            end loop;
         elsif Raw.Data (Pos) = '{' or else Raw.Data (Pos) = '[' then
            Val_Kind := (if Raw.Data (Pos) = '{' then JSONB_Object else JSONB_Array);
            Brace_D  := 0;
            In_Str   := False;
            Esc      := False;
            while Pos <= Raw.Length loop
               pragma Loop_Invariant (Pos in 1 .. Raw.Length);
               pragma Loop_Invariant (Val_Text.Length <= Max_Text_Len);
               pragma Loop_Invariant (Brace_D <= Max_Text_Len);
               pragma Loop_Variant (Increases => Pos);

               if Val_Text.Length < Max_Text_Len then
                  Val_Text.Length := Val_Text.Length + 1;
                  Val_Text.Data (Val_Text.Length) := Raw.Data (Pos);
               else
                  Doc    := (others => <>);
                  Status := Status_Capacity_Exceeded;
                  return;
               end if;

               if In_Str then
                  if Esc then
                     Esc := False;
                  elsif Raw.Data (Pos) = '\' then
                     Esc := True;
                  elsif Raw.Data (Pos) = '"' then
                     In_Str := False;
                  end if;
               else
                  if Raw.Data (Pos) = '"' then
                     In_Str := True;
                  elsif Raw.Data (Pos) = '{' or else Raw.Data (Pos) = '[' then
                     if Brace_D < Max_Text_Len then
                        Brace_D := Brace_D + 1;
                     end if;
                  elsif Raw.Data (Pos) = '}' or else Raw.Data (Pos) = ']' then
                     if Brace_D > 0 then
                        Brace_D := Brace_D - 1;
                     end if;
                     if Brace_D = 0 then
                        Pos := Pos + 1;
                        exit;
                     end if;
                  end if;
               end if;
               Pos := Pos + 1;
            end loop;
         else
            if Raw.Data (Pos) = 't' or else Raw.Data (Pos) = 'f' then
               Val_Kind := JSONB_Boolean;
            elsif Raw.Data (Pos) = 'n' then
               Val_Kind := JSONB_Null;
            else
               Val_Kind := JSONB_Number;
            end if;

            while Pos <= Raw.Length
              and then not Is_Whitespace (Raw.Data (Pos))
              and then Raw.Data (Pos) /= ','
              and then Raw.Data (Pos) /= '}'
            loop
               pragma Loop_Invariant (Pos in 1 .. Raw.Length);
               pragma Loop_Invariant (Val_Text.Length <= Max_Text_Len);
               pragma Loop_Variant (Increases => Pos);
               if Val_Text.Length < Max_Text_Len then
                  Val_Text.Length := Val_Text.Length + 1;
                  Val_Text.Data (Val_Text.Length) := Raw.Data (Pos);
               else
                  Doc    := (others => <>);
                  Status := Status_Capacity_Exceeded;
                  return;
               end if;
               Pos := Pos + 1;
            end loop;
         end if;

         Put_Field (Doc, Key_Id, Val_Text, Val_Kind, Sub_Stat);
         if Sub_Stat /= Status_Ok then
            Doc    := (others => <>);
            Status := Sub_Stat;
            return;
         end if;
      end loop;

      Doc    := (others => <>);
      Status := Status_Capacity_Exceeded;
   end Parse_JSONB;

   -------------------------------------------------------------------------
   --  Get_Field (`->`) & Get_Field_Text (`->>`) (HIGH-04, R3-MED-01)
   -------------------------------------------------------------------------

   procedure Format_Quoted_JSON_String
     (Raw_Val : in     Bounded_Text;
      Quoted  :    out Bounded_Text)
     with Post   => Quoted.Length in 1 .. Max_Text_Len,
          Global => null
   is
      Hex_Tab : constant array (0 .. 15) of Character :=
        ['0', '1', '2', '3', '4', '5', '6', '7',
         '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
      C       : Character;
      Esc     : Character;
      Use_Esc : Boolean;
      Code    : Natural;
   begin
      Quoted := (Length => 1, Data => [1 => '"', others => ' ']);

      for K in 1 .. Raw_Val.Length loop
         pragma Loop_Invariant (Quoted.Length in 1 .. Max_Text_Len);
         C       := Raw_Val.Data (K);
         Code    := Character'Pos (C);
         Use_Esc := False;
         Esc     := C;
         if C = '"' or else C = '\' then
            Use_Esc := True;
            Esc     := C;
         elsif C = ASCII.LF then
            Use_Esc := True;
            Esc     := 'n';
         elsif C = ASCII.CR then
            Use_Esc := True;
            Esc     := 'r';
         elsif C = ASCII.HT then
            Use_Esc := True;
            Esc     := 't';
         elsif C = ASCII.BS then
            Use_Esc := True;
            Esc     := 'b';
         elsif C = ASCII.FF then
            Use_Esc := True;
            Esc     := 'f';
         end if;

         if Use_Esc then
            if Quoted.Length <= Max_Text_Len - 3 then
               Quoted.Data (Quoted.Length + 1) := '\';
               Quoted.Data (Quoted.Length + 2) := Esc;
               Quoted.Length := Quoted.Length + 2;
            end if;
         elsif Code < 32 then
            if Quoted.Length <= Max_Text_Len - 7 then
               Quoted.Data (Quoted.Length + 1) := '\';
               Quoted.Data (Quoted.Length + 2) := 'u';
               Quoted.Data (Quoted.Length + 3) := '0';
               Quoted.Data (Quoted.Length + 4) := '0';
               Quoted.Data (Quoted.Length + 5) := Hex_Tab ((Code / 16) mod 16);
               Quoted.Data (Quoted.Length + 6) := Hex_Tab (Code mod 16);
               Quoted.Length := Quoted.Length + 6;
            end if;
         else
            if Quoted.Length <= Max_Text_Len - 2 then
               Quoted.Length := Quoted.Length + 1;
               Quoted.Data (Quoted.Length) := C;
            end if;
         end if;
      end loop;

      if Quoted.Length < Max_Text_Len then
         Quoted.Length := Quoted.Length + 1;
         Quoted.Data (Quoted.Length) := '"';
      end if;
   end Format_Quoted_JSON_String;

   procedure Get_Field
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text;
      Kind  :    out JSONB_Value_Kind)
   is
      Raw_Val : Bounded_Text;
   begin
      Val   := (Length => 0, Data => [others => ' ']);
      Kind  := JSONB_Null;
      Found := False;
      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant
           (I in 1 .. Doc.Count
            and then not Found
            and then (for all J in 1 .. I - 1 =>
                        not (Doc.Fields (J).Active
                             and then Equal_Ident (Doc.Fields (J).Key, Key))));
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            Raw_Val := Doc.Fields (I).Val;
            Kind    := Doc.Fields (I).Kind;
            Found   := True;

            --  PostgreSQL `->` returns valid JSON (strings wrapped in quotes & escaped)
            if Kind = JSONB_String then
               Format_Quoted_JSON_String (Raw_Val, Val);
            else
               Val := Raw_Val;
            end if;
            return;
         end if;
      end loop;
   end Get_Field;

   procedure Get_Field_Text
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text)
   is
   begin
      Val   := (Length => 0, Data => [others => ' ']);
      Found := False;
      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant
           (I in 1 .. Doc.Count
            and then not Found
            and then (for all J in 1 .. I - 1 =>
                        not (Doc.Fields (J).Active
                             and then Equal_Ident (Doc.Fields (J).Key, Key))));
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            Val   := Doc.Fields (I).Val;
            Found := True;
            return;
         end if;
      end loop;
   end Get_Field_Text;

   -------------------------------------------------------------------------
   --  Contains (`@>`) with Canonical Numeric, Nested Object, and Array Matching (R3-MED-01)
   -------------------------------------------------------------------------

   procedure Normalize_JSON_Number
     (Num     : in     Bounded_Text;
      Is_Zero :    out Boolean;
      Is_Neg  :    out Boolean;
      Sig     :    out Bounded_Text;
      Exp_10  :    out Integer)
     with Post   => Sig.Length <= Max_Text_Len,
          Global => null
   is
      Pos      : Positive := 1;
      Saw_Dot  : Boolean  := False;
      Dec_Exp  : Integer  := 0;
      Exp_Neg  : Boolean  := False;
      Exp_Acc  : Natural  := 0;
      Digit    : Natural;
      C        : Character;
   begin
      Is_Zero := True;
      Is_Neg  := False;
      Sig     := (Length => 0, Data => [others => ' ']);
      Exp_10  := 0;

      while Pos <= Num.Length and then Is_Whitespace (Num.Data (Pos)) loop
         pragma Loop_Invariant (Pos in 1 .. Num.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos > Num.Length then
         return;
      end if;

      if Num.Data (Pos) = '-' then
         Is_Neg := True;
         if Pos = Num.Length then
            return;
         end if;
         Pos := Pos + 1;
      end if;

      while Pos <= Num.Length loop
         pragma Loop_Invariant (Pos in 1 .. Num.Length);
         pragma Loop_Invariant (Sig.Length <= Max_Text_Len);
         pragma Loop_Invariant (Dec_Exp in -10_000 .. 10_000);
         pragma Loop_Variant (Increases => Pos);
         C := Num.Data (Pos);
         if C = '.' then
            Saw_Dot := True;
         elsif C = 'e' or else C = 'E' then
            Pos := Pos + 1;
            exit;
         elsif C in '0' .. '9' then
            if not Saw_Dot then
               if C = '0' and then Sig.Length = 0 then
                  null;
               else
                  if Sig.Length < Max_Text_Len then
                     Sig.Length := Sig.Length + 1;
                     Sig.Data (Sig.Length) := C;
                  end if;
                  if Dec_Exp < 10_000 then
                     Dec_Exp := Dec_Exp + 1;
                  end if;
               end if;
            else
               if C = '0' and then Sig.Length = 0 then
                  if Dec_Exp > -10_000 then
                     Dec_Exp := Dec_Exp - 1;
                  end if;
               else
                  if Sig.Length < Max_Text_Len then
                     Sig.Length := Sig.Length + 1;
                     Sig.Data (Sig.Length) := C;
                  end if;
               end if;
            end if;
         else
            exit;
         end if;
         Pos := Pos + 1;
      end loop;

      while Sig.Length > 0 and then Sig.Data (Sig.Length) = '0' loop
         pragma Loop_Invariant (Sig.Length in 1 .. Max_Text_Len);
         pragma Loop_Variant (Decreases => Sig.Length);
         Sig.Length := Sig.Length - 1;
      end loop;

      if Sig.Length = 0 then
         Is_Zero := True;
         Is_Neg  := False;
         Exp_10  := 0;
         return;
      end if;

      if Pos <= Num.Length and then (Num.Data (Pos) = '+' or else Num.Data (Pos) = '-') then
         Exp_Neg := (Num.Data (Pos) = '-');
         if Pos < Num.Length then
            Pos := Pos + 1;
         else
            Pos := Num.Length + 1;
         end if;
      end if;

      while Pos <= Num.Length and then Num.Data (Pos) in '0' .. '9' loop
         pragma Loop_Invariant (Pos in 1 .. Num.Length);
         pragma Loop_Invariant (Exp_Acc in 0 .. 500_000);
         pragma Loop_Variant (Increases => Pos);
         Digit := Character'Pos (Num.Data (Pos)) - Character'Pos ('0');
         if Exp_Acc <= (500_000 - Digit) / 10 then
            Exp_Acc := Exp_Acc * 10 + Digit;
         else
            Exp_Acc := 500_000;
         end if;
         Pos := Pos + 1;
      end loop;

      Is_Zero := False;
      Exp_10  := (if Exp_Neg then Dec_Exp - Exp_Acc else Dec_Exp + Exp_Acc);
   end Normalize_JSON_Number;

   function Equal_JSON_Numbers (A, B : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      AZ, AN, BZ, BN : Boolean;
      ASig, BSig     : Bounded_Text;
      AExp, BExp     : Integer;
   begin
      Normalize_JSON_Number (A, AZ, AN, ASig, AExp);
      Normalize_JSON_Number (B, BZ, BN, BSig, BExp);
      if AZ and then BZ then
         return True;
      elsif AZ /= BZ then
         return False;
      else
         return AN = BN
           and then AExp = BExp
           and then Equal_Text (ASig, BSig);
      end if;
   end Equal_JSON_Numbers;

   function Strip_JSON_Whitespace (Raw : Bounded_Text) return Bounded_Text
     with Post   => Strip_JSON_Whitespace'Result.Length <= Raw.Length,
          Global => null
   is
      Res    : Bounded_Text := (Length => 0, Data => [others => ' ']);
      In_Str : Boolean      := False;
      Esc    : Boolean      := False;
      C      : Character;
   begin
      for I in 1 .. Raw.Length loop
         pragma Loop_Invariant (Res.Length < I);
         C := Raw.Data (I);
         if In_Str then
            if Esc then
               Esc := False;
            elsif C = '\' then
               Esc := True;
            elsif C = '"' then
               In_Str := False;
            end if;
            Res.Length := Res.Length + 1;
            Res.Data (Res.Length) := C;
         else
            if C = '"' then
               In_Str := True;
               Res.Length := Res.Length + 1;
               Res.Data (Res.Length) := C;
            elsif not Is_Whitespace (C) then
               Res.Length := Res.Length + 1;
               Res.Data (Res.Length) := C;
            end if;
         end if;
      end loop;
      return Res;
   end Strip_JSON_Whitespace;

   --  Compare two scalar/leaf JSON values
   function Values_Match_Scalar
     (L_Val  : Bounded_Text;
      R_Val  : Bounded_Text;
      Kind   : JSONB_Value_Kind) return Boolean
     with Post   => True,
          Global => null
   is
   begin
      case Kind is
         when JSONB_Number =>
            return Equal_JSON_Numbers (L_Val, R_Val);
         when JSONB_String | JSONB_Boolean | JSONB_Null =>
            return Equal_Text (L_Val, R_Val);
         when JSONB_Object | JSONB_Array =>
            return Equal_Text (Strip_JSON_Whitespace (L_Val), Strip_JSON_Whitespace (R_Val));
      end case;
   end Values_Match_Scalar;

   --  Extract top-level elements of a JSON array `[e1, e2, ...]` (up to Max_JSON_Fields)
   procedure Extract_Array_Elements
     (Arr_Raw : in     Bounded_Text;
      Elems   :    out JSONB_Document)
     with Post   => Elems.Count <= Max_JSON_Fields,
          Global => null
   is
      Pos      : Positive := 1;
      Elem_Txt : Bounded_Text;
      Elem_Knd : JSONB_Value_Kind;
      Sub_Stat : Engine_Status;
      pragma Warnings (Off, Sub_Stat);
      Brace_D  : Natural;
      In_Str   : Boolean;
      Esc      : Boolean;
   begin
      Elems := (others => <>);
      while Pos <= Arr_Raw.Length and then Arr_Raw.Data (Pos) /= '[' loop
         pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length);
         pragma Loop_Variant (Increases => Pos);
         Pos := Pos + 1;
      end loop;

      if Pos >= Arr_Raw.Length then
         return;
      end if;
      Pos := Pos + 1;

      for Step in 1 .. Max_JSON_Fields loop
         pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length + 1);
         pragma Loop_Invariant (Elems.Count < Step);

         while Pos <= Arr_Raw.Length and then Is_Whitespace (Arr_Raw.Data (Pos)) loop
            pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos > Arr_Raw.Length or else Arr_Raw.Data (Pos) = ']' then
            return;
         end if;

         if Step > 1 then
            if Arr_Raw.Data (Pos) /= ',' or else Pos = Arr_Raw.Length then
               return;
            end if;
            Pos := Pos + 1;
            while Pos <= Arr_Raw.Length and then Is_Whitespace (Arr_Raw.Data (Pos)) loop
               pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length);
               pragma Loop_Variant (Increases => Pos);
               Pos := Pos + 1;
            end loop;
            if Pos > Arr_Raw.Length then
               return;
            end if;
         end if;

         Elem_Txt := (Length => 0, Data => [others => ' ']);
         if Arr_Raw.Data (Pos) = '"' then
            Elem_Knd := JSONB_String;
            if Pos < Arr_Raw.Length then
               Pos := Pos + 1;
            end if;
            Esc := False;
            while Pos <= Arr_Raw.Length loop
               pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length);
               pragma Loop_Invariant (Elem_Txt.Length <= Max_Text_Len);
               pragma Loop_Variant (Increases => Pos);
               if Esc then
                  Esc := False;
                  if Arr_Raw.Data (Pos) = 'u' and then Pos <= Arr_Raw.Length - 4 then
                     Append_Unicode_Text
                       (Arr_Raw.Data (Pos + 1), Arr_Raw.Data (Pos + 2),
                        Arr_Raw.Data (Pos + 3), Arr_Raw.Data (Pos + 4),
                        Elem_Txt, Sub_Stat);
                     Pos := Pos + 4;
                  elsif Elem_Txt.Length < Max_Text_Len then
                     Elem_Txt.Length := Elem_Txt.Length + 1;
                     Elem_Txt.Data (Elem_Txt.Length) := Decode_Escape_Char (Arr_Raw.Data (Pos));
                  end if;
               elsif Arr_Raw.Data (Pos) = '\' then
                  Esc := True;
               elsif Arr_Raw.Data (Pos) = '"' then
                  Pos := Pos + 1;
                  exit;
               else
                  if Elem_Txt.Length < Max_Text_Len then
                     Elem_Txt.Length := Elem_Txt.Length + 1;
                     Elem_Txt.Data (Elem_Txt.Length) := Arr_Raw.Data (Pos);
                  end if;
               end if;
               Pos := Pos + 1;
            end loop;
         elsif Arr_Raw.Data (Pos) = '{' or else Arr_Raw.Data (Pos) = '[' then
            Elem_Knd := (if Arr_Raw.Data (Pos) = '{' then JSONB_Object else JSONB_Array);
            Brace_D  := 0;
            In_Str   := False;
            Esc      := False;
            while Pos <= Arr_Raw.Length loop
               pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length);
               pragma Loop_Invariant (Elem_Txt.Length <= Max_Text_Len);
               pragma Loop_Invariant (Brace_D <= Max_Text_Len);
               pragma Loop_Variant (Increases => Pos);
               if Elem_Txt.Length < Max_Text_Len then
                  Elem_Txt.Length := Elem_Txt.Length + 1;
                  Elem_Txt.Data (Elem_Txt.Length) := Arr_Raw.Data (Pos);
               end if;
               if In_Str then
                  if Esc then
                     Esc := False;
                  elsif Arr_Raw.Data (Pos) = '\' then
                     Esc := True;
                  elsif Arr_Raw.Data (Pos) = '"' then
                     In_Str := False;
                  end if;
               else
                  if Arr_Raw.Data (Pos) = '"' then
                     In_Str := True;
                  elsif Arr_Raw.Data (Pos) = '{' or else Arr_Raw.Data (Pos) = '[' then
                     if Brace_D < Max_Text_Len then
                        Brace_D := Brace_D + 1;
                     end if;
                  elsif Arr_Raw.Data (Pos) = '}' or else Arr_Raw.Data (Pos) = ']' then
                     if Brace_D > 0 then
                        Brace_D := Brace_D - 1;
                     end if;
                     if Brace_D = 0 then
                        Pos := Pos + 1;
                        exit;
                     end if;
                  end if;
               end if;
               Pos := Pos + 1;
            end loop;
         else
            if Arr_Raw.Data (Pos) = 't' or else Arr_Raw.Data (Pos) = 'f' then
               Elem_Knd := JSONB_Boolean;
            elsif Arr_Raw.Data (Pos) = 'n' then
               Elem_Knd := JSONB_Null;
            else
               Elem_Knd := JSONB_Number;
            end if;
            while Pos <= Arr_Raw.Length
              and then not Is_Whitespace (Arr_Raw.Data (Pos))
              and then Arr_Raw.Data (Pos) /= ','
              and then Arr_Raw.Data (Pos) /= ']'
            loop
               pragma Loop_Invariant (Pos in 1 .. Arr_Raw.Length);
               pragma Loop_Invariant (Elem_Txt.Length <= Max_Text_Len);
               pragma Loop_Variant (Increases => Pos);
               if Elem_Txt.Length < Max_Text_Len then
                  Elem_Txt.Length := Elem_Txt.Length + 1;
                  Elem_Txt.Data (Elem_Txt.Length) := Arr_Raw.Data (Pos);
               end if;
               Pos := Pos + 1;
            end loop;
         end if;

         Elems.Count := Elems.Count + 1;
         Elems.Fields (Elems.Count) := (
            Key    => Make_Ident ("e"),
            Val    => Elem_Txt,
            Kind   => Elem_Knd,
            Active => True
         );
      end loop;
   end Extract_Array_Elements;

   function Leaf_Array_Contains (L_Arr_Raw, R_Arr_Raw : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      L_Elems : JSONB_Document;
      R_Elems : JSONB_Document;
      Found   : Boolean;
   begin
      if Equal_Text (Strip_JSON_Whitespace (L_Arr_Raw), Strip_JSON_Whitespace (R_Arr_Raw)) then
         return True;
      end if;

      Extract_Array_Elements (L_Arr_Raw, L_Elems);
      Extract_Array_Elements (R_Arr_Raw, R_Elems);

      for R in 1 .. R_Elems.Count loop
         pragma Loop_Invariant (R in 1 .. R_Elems.Count);
         Found := False;
         for L in 1 .. L_Elems.Count loop
            pragma Loop_Invariant (L in 1 .. L_Elems.Count);
            if L_Elems.Fields (L).Kind = R_Elems.Fields (R).Kind
              and then Values_Match_Scalar
                (L_Elems.Fields (L).Val,
                 R_Elems.Fields (R).Val,
                 L_Elems.Fields (L).Kind)
            then
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            return False;
         end if;
      end loop;
      return True;
   end Leaf_Array_Contains;

   function Leaf_Object_Contains (L_Obj_Raw, R_Obj_Raw : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      L_Doc  : JSONB_Document;
      R_Doc  : JSONB_Document;
      L_Stat : Engine_Status;
      R_Stat : Engine_Status;
      Found  : Boolean;
   begin
      if Equal_Text (Strip_JSON_Whitespace (L_Obj_Raw), Strip_JSON_Whitespace (R_Obj_Raw)) then
         return True;
      end if;

      Parse_JSONB (L_Obj_Raw, L_Doc, L_Stat);
      Parse_JSONB (R_Obj_Raw, R_Doc, R_Stat);
      if L_Stat /= Status_Ok or else R_Stat /= Status_Ok then
         return False;
      end if;

      for R in 1 .. R_Doc.Count loop
         pragma Loop_Invariant (R in 1 .. R_Doc.Count);
         if R_Doc.Fields (R).Active then
            Found := False;
            for L in 1 .. L_Doc.Count loop
               pragma Loop_Invariant (L in 1 .. L_Doc.Count);
               if L_Doc.Fields (L).Active
                 and then Equal_Ident (L_Doc.Fields (L).Key, R_Doc.Fields (R).Key)
                 and then L_Doc.Fields (L).Kind = R_Doc.Fields (R).Kind
               then
                  case L_Doc.Fields (L).Kind is
                     when JSONB_Array =>
                        Found := Leaf_Array_Contains (L_Doc.Fields (L).Val, R_Doc.Fields (R).Val);
                     when others =>
                        Found :=
                          Values_Match_Scalar
                            (L_Doc.Fields (L).Val,
                             R_Doc.Fields (R).Val,
                             L_Doc.Fields (L).Kind);
                  end case;
                  exit when Found;
               end if;
            end loop;
            if not Found then
               return False;
            end if;
         end if;
      end loop;
      return True;
   end Leaf_Object_Contains;

   function Inner_Array_Contains (L_Arr_Raw, R_Arr_Raw : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      L_Elems : JSONB_Document;
      R_Elems : JSONB_Document;
      Found   : Boolean;
   begin
      if Equal_Text (Strip_JSON_Whitespace (L_Arr_Raw), Strip_JSON_Whitespace (R_Arr_Raw)) then
         return True;
      end if;

      Extract_Array_Elements (L_Arr_Raw, L_Elems);
      Extract_Array_Elements (R_Arr_Raw, R_Elems);

      for R in 1 .. R_Elems.Count loop
         pragma Loop_Invariant (R in 1 .. R_Elems.Count);
         Found := False;
         for L in 1 .. L_Elems.Count loop
            pragma Loop_Invariant (L in 1 .. L_Elems.Count);
            if L_Elems.Fields (L).Kind = R_Elems.Fields (R).Kind then
               case L_Elems.Fields (L).Kind is
                  when JSONB_Object =>
                     Found := Leaf_Object_Contains (L_Elems.Fields (L).Val, R_Elems.Fields (R).Val);
                  when JSONB_Array =>
                     Found := Leaf_Array_Contains (L_Elems.Fields (L).Val, R_Elems.Fields (R).Val);
                  when others =>
                     Found :=
                       Values_Match_Scalar
                         (L_Elems.Fields (L).Val,
                          R_Elems.Fields (R).Val,
                          L_Elems.Fields (L).Kind);
               end case;
               exit when Found;
            end if;
         end loop;
         if not Found then
            return False;
         end if;
      end loop;
      return True;
   end Inner_Array_Contains;

   function Inner_Object_Contains (L_Obj_Raw, R_Obj_Raw : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      L_Doc  : JSONB_Document;
      R_Doc  : JSONB_Document;
      L_Stat : Engine_Status;
      R_Stat : Engine_Status;
      Found  : Boolean;
   begin
      if Equal_Text (Strip_JSON_Whitespace (L_Obj_Raw), Strip_JSON_Whitespace (R_Obj_Raw)) then
         return True;
      end if;

      Parse_JSONB (L_Obj_Raw, L_Doc, L_Stat);
      Parse_JSONB (R_Obj_Raw, R_Doc, R_Stat);
      if L_Stat /= Status_Ok or else R_Stat /= Status_Ok then
         return False;
      end if;

      for R in 1 .. R_Doc.Count loop
         pragma Loop_Invariant (R in 1 .. R_Doc.Count);
         if R_Doc.Fields (R).Active then
            Found := False;
            for L in 1 .. L_Doc.Count loop
               pragma Loop_Invariant (L in 1 .. L_Doc.Count);
               if L_Doc.Fields (L).Active
                 and then Equal_Ident (L_Doc.Fields (L).Key, R_Doc.Fields (R).Key)
                 and then L_Doc.Fields (L).Kind = R_Doc.Fields (R).Kind
               then
                  case L_Doc.Fields (L).Kind is
                     when JSONB_Object =>
                        Found := Leaf_Object_Contains (L_Doc.Fields (L).Val, R_Doc.Fields (R).Val);
                     when JSONB_Array =>
                        Found := Inner_Array_Contains (L_Doc.Fields (L).Val, R_Doc.Fields (R).Val);
                     when others =>
                        Found :=
                          Values_Match_Scalar
                            (L_Doc.Fields (L).Val,
                             R_Doc.Fields (R).Val,
                             L_Doc.Fields (L).Kind);
                  end case;
                  exit when Found;
               end if;
            end loop;
            if not Found then
               return False;
            end if;
         end if;
      end loop;
      return True;
   end Inner_Object_Contains;

   function Array_Contains (L_Arr_Raw, R_Arr_Raw : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      L_Elems : JSONB_Document;
      R_Elems : JSONB_Document;
      Found   : Boolean;
   begin
      if Equal_Text (Strip_JSON_Whitespace (L_Arr_Raw), Strip_JSON_Whitespace (R_Arr_Raw)) then
         return True;
      end if;

      Extract_Array_Elements (L_Arr_Raw, L_Elems);
      Extract_Array_Elements (R_Arr_Raw, R_Elems);

      for R in 1 .. R_Elems.Count loop
         pragma Loop_Invariant (R in 1 .. R_Elems.Count);
         Found := False;
         for L in 1 .. L_Elems.Count loop
            pragma Loop_Invariant (L in 1 .. L_Elems.Count);
            if L_Elems.Fields (L).Kind = R_Elems.Fields (R).Kind then
               case L_Elems.Fields (L).Kind is
                  when JSONB_Object =>
                     Found := Inner_Object_Contains (L_Elems.Fields (L).Val, R_Elems.Fields (R).Val);
                  when JSONB_Array =>
                     Found := Inner_Array_Contains (L_Elems.Fields (L).Val, R_Elems.Fields (R).Val);
                  when others =>
                     Found :=
                       Values_Match_Scalar
                         (L_Elems.Fields (L).Val,
                          R_Elems.Fields (R).Val,
                          L_Elems.Fields (L).Kind);
               end case;
               exit when Found;
            end if;
         end loop;
         if not Found then
            return False;
         end if;
      end loop;
      return True;
   end Array_Contains;

   function Object_Contains (L_Obj_Raw, R_Obj_Raw : Bounded_Text) return Boolean
     with Post   => True,
          Global => null
   is
      L_Doc  : JSONB_Document;
      R_Doc  : JSONB_Document;
      L_Stat : Engine_Status;
      R_Stat : Engine_Status;
      Found  : Boolean;
   begin
      if Equal_Text (Strip_JSON_Whitespace (L_Obj_Raw), Strip_JSON_Whitespace (R_Obj_Raw)) then
         return True;
      end if;

      Parse_JSONB (L_Obj_Raw, L_Doc, L_Stat);
      Parse_JSONB (R_Obj_Raw, R_Doc, R_Stat);
      if L_Stat /= Status_Ok or else R_Stat /= Status_Ok then
         return False;
      end if;

      for R in 1 .. R_Doc.Count loop
         pragma Loop_Invariant (R in 1 .. R_Doc.Count);
         if R_Doc.Fields (R).Active then
            Found := False;
            for L in 1 .. L_Doc.Count loop
               pragma Loop_Invariant (L in 1 .. L_Doc.Count);
               if L_Doc.Fields (L).Active
                 and then Equal_Ident (L_Doc.Fields (L).Key, R_Doc.Fields (R).Key)
                 and then L_Doc.Fields (L).Kind = R_Doc.Fields (R).Kind
               then
                  case L_Doc.Fields (L).Kind is
                     when JSONB_Object =>
                        Found := Inner_Object_Contains (L_Doc.Fields (L).Val, R_Doc.Fields (R).Val);
                     when JSONB_Array =>
                        Found := Array_Contains (L_Doc.Fields (L).Val, R_Doc.Fields (R).Val);
                     when others =>
                        Found :=
                          Values_Match_Scalar
                            (L_Doc.Fields (L).Val,
                             R_Doc.Fields (R).Val,
                             L_Doc.Fields (L).Kind);
                  end case;
                  exit when Found;
               end if;
            end loop;
            if not Found then
               return False;
            end if;
         end if;
      end loop;
      return True;
   end Object_Contains;

   function Field_Values_Contain
     (L_Entry, R_Entry : JSONB_Entry) return Boolean
     with Post   => True,
          Global => null
   is
   begin
      if L_Entry.Kind /= R_Entry.Kind then
         return False;
      end if;

      case L_Entry.Kind is
         when JSONB_Number =>
            return Equal_JSON_Numbers (L_Entry.Val, R_Entry.Val);
         when JSONB_Object =>
            return Object_Contains (L_Entry.Val, R_Entry.Val);
         when JSONB_Array =>
            return Array_Contains (L_Entry.Val, R_Entry.Val);
         when JSONB_String | JSONB_Boolean | JSONB_Null =>
            return Equal_Text (L_Entry.Val, R_Entry.Val);
      end case;
   end Field_Values_Contain;

   function Contains
     (Left, Right : JSONB_Document) return Boolean
   is
      Matched : Boolean;
   begin
      for R in 1 .. Right.Count loop
         pragma Loop_Invariant (R in 1 .. Right.Count);
         if Right.Fields (R).Active then
            Matched := False;
            for L in 1 .. Left.Count loop
               pragma Loop_Invariant (L in 1 .. Left.Count);
               if Left.Fields (L).Active
                 and then Equal_Ident (Left.Fields (L).Key, Right.Fields (R).Key)
                 and then Field_Values_Contain (Left.Fields (L), Right.Fields (R))
               then
                  Matched := True;
                  exit;
               end if;
            end loop;
            if not Matched then
               return False;
            end if;
         end if;
      end loop;
      return True;
   end Contains;

end Nhe_O.JSON;
