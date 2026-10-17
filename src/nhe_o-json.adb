pragma SPARK_Mode (On);

package body Nhe_O.JSON is

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
      if Raw.Length < 2 then
         return False;
      end if;

      for I in 1 .. Raw.Length loop
         pragma Loop_Invariant
           (I in 1 .. Raw.Length and then Depth <= Max_Text_Len);
         declare
            C     : constant Character := Raw.Data (I);
            Is_WS : constant Boolean   :=
              (C = ' ' or else C = ASCII.HT
               or else C = ASCII.LF or else C = ASCII.CR);
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
                  when St_Root =>
                     if C = '{' then
                        Depth     := 1;
                        Stack (1) := '{';
                        State     := St_Obj_Key_Or_End;
                     elsif C = '[' then
                        Depth     := 1;
                        Stack (1) := '[';
                        State     := St_Arr_Val_Or_End;
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

                  when St_Arr_Val_Or_End | St_Val =>
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

                  when St_After_Val =>
                     if Depth = 0 then
                        --  Root container already closed: reject trailing tokens or `{}{}`
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

      return State = St_After_Val
        and then Lex = Lex_None
        and then Depth = 0
        and then not Escaped
        and then Hex_Needed = 0;
   end Is_Valid_JSON;

   procedure Put_Field
     (Doc    : in out JSONB_Document;
      Key    : in     Bounded_Ident;
      Val    : in     Bounded_Text;
      Kind   : in     JSONB_Value_Kind;
      Status :    out Engine_Status)
   is
   begin
      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant (I in 1 .. Doc.Count);
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            Doc.Fields (I).Val  := Val;
            Doc.Fields (I).Kind := Kind;
            Status := Status_Ok;
            return;
         end if;
      end loop;

      if Doc.Count < Max_JSON_Fields then
         Doc.Count := Doc.Count + 1;
         Doc.Fields (Doc.Count) := (
            Key    => Key,
            Val    => Val,
            Kind   => Kind,
            Active => True
         );
         Status := Status_Ok;
      else
         Status := Status_Capacity_Exceeded;
      end if;
   end Put_Field;

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

   procedure Get_Field
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text;
      Kind  :    out JSONB_Value_Kind)
   is
   begin
      Val   := (Length => 0, Data => [others => ' ']);
      Kind  := JSONB_Null;
      Found := False;
      for I in 1 .. Doc.Count loop
         pragma Loop_Invariant
           (I in 1 .. Doc.Count and not Found);
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            Val   := Doc.Fields (I).Val;
            Kind  := Doc.Fields (I).Kind;
            Found := True;
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
      Ignored_Kind : JSONB_Value_Kind;
   begin
      Get_Field (Doc, Key, Found, Val, Ignored_Kind);
   end Get_Field_Text;

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
