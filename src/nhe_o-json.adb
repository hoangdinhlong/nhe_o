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
            --  Reject raw control characters inside JSONB string values
            return (for all I in 1 .. Val.Length =>
                      Character'Pos (Val.Data (I)) >= 32);

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

         while Pos <= Raw.Length
           and then (Is_Whitespace (Raw.Data (Pos)) or else Raw.Data (Pos) = ',')
         loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos > Raw.Length or else Raw.Data (Pos) = '}' then
            Status := Status_Ok;
            return;
         end if;

         if Raw.Data (Pos) /= '"' or else Pos = Raw.Length then
            Status := Status_Invalid_Syntax;
            return;
         end if;
         Pos := Pos + 1;

         --  Extract key string
         Key_Id := (Length => 0, Data => [others => ' ']);
         Esc    := False;
         while Pos <= Raw.Length loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Invariant (Key_Id.Length <= Max_Ident_Len);
            pragma Loop_Variant (Increases => Pos);
            if Esc then
               Esc := False;
               if Key_Id.Length < Max_Ident_Len then
                  Key_Id.Length := Key_Id.Length + 1;
                  Key_Id.Data (Key_Id.Length) := Raw.Data (Pos);
               else
                  Status := Status_Invalid_Syntax;
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
                  Status := Status_Invalid_Syntax;
                  return;
               end if;
            end if;
            Pos := Pos + 1;
         end loop;

         if Key_Id.Length = 0 then
            Status := Status_Invalid_Syntax;
            return;
         end if;

         --  Skip whitespace and ':'
         while Pos <= Raw.Length
           and then (Is_Whitespace (Raw.Data (Pos)) or else Raw.Data (Pos) = ':')
         loop
            pragma Loop_Invariant (Pos in 1 .. Raw.Length);
            pragma Loop_Variant (Increases => Pos);
            Pos := Pos + 1;
         end loop;

         if Pos > Raw.Length then
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
                  if Val_Text.Length < Max_Text_Len then
                     Val_Text.Length := Val_Text.Length + 1;
                     Val_Text.Data (Val_Text.Length) := Raw.Data (Pos);
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
               end if;
               Pos := Pos + 1;
            end loop;
         end if;

         Put_Field (Doc, Key_Id, Val_Text, Val_Kind, Sub_Stat);
         if Sub_Stat /= Status_Ok then
            Status := Sub_Stat;
            return;
         end if;
      end loop;

      Status := Status_Capacity_Exceeded;
   end Parse_JSONB;

   -------------------------------------------------------------------------
   --  Get_Field (`->`) & Get_Field_Text (`->>`) (HIGH-04)
   -------------------------------------------------------------------------

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

            --  PostgreSQL `->` returns valid JSON (strings wrapped in quotes)
            if Kind = JSONB_String then
               if Raw_Val.Length >= 2
                 and then Raw_Val.Data (1) = '"'
                 and then Raw_Val.Data (Raw_Val.Length) = '"'
               then
                  Val := Raw_Val;
               elsif Raw_Val.Length <= Max_Text_Len - 2 then
                  Val.Length   := Raw_Val.Length + 2;
                  Val.Data (1) := '"';
                  for K in 1 .. Raw_Val.Length loop
                     Val.Data (K + 1) := Raw_Val.Data (K);
                  end loop;
                  Val.Data (Raw_Val.Length + 2) := '"';
               else
                  Val := Raw_Val;
               end if;
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
      Raw_Val : Bounded_Text;
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
            Raw_Val := Doc.Fields (I).Val;
            Found   := True;

            --  PostgreSQL `->>` returns unquoted text for JSONB_String
            if Doc.Fields (I).Kind = JSONB_String
              and then Raw_Val.Length >= 2
              and then Raw_Val.Data (1) = '"'
              and then Raw_Val.Data (Raw_Val.Length) = '"'
            then
               Val.Length := Raw_Val.Length - 2;
               for K in 1 .. Val.Length loop
                  Val.Data (K) := Raw_Val.Data (K + 1);
               end loop;
            else
               Val := Raw_Val;
            end if;
            return;
         end if;
      end loop;
   end Get_Field_Text;

   -------------------------------------------------------------------------
   --  Contains (`@>`)
   -------------------------------------------------------------------------

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
                 and then Left.Fields (L).Kind = Right.Fields (R).Kind
                 and then Equal_Text (Left.Fields (L).Val, Right.Fields (R).Val)
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
