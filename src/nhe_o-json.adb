pragma SPARK_Mode (On);

package body Nhe_O.JSON is

   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean is
      Brace_Depth   : Integer := 0;
      Bracket_Depth : Integer := 0;
      In_Quotes     : Boolean := False;
      Escaped       : Boolean := False;
      First_Non_WS  : Character := ' ';
      Last_Non_WS   : Character := ' ';
   begin
      if Raw.Length < 2 then
         return False;
      end if;

      for I in 1 .. Raw.Length loop
         pragma Loop_Invariant (I in 1 .. Raw.Length);
         declare
            C : constant Character := Raw.Data (I);
         begin
            if not In_Quotes and then C /= ' ' and then C /= ASCII.HT
              and then C /= ASCII.LF and then C /= ASCII.CR
            then
               if First_Non_WS = ' ' then
                  First_Non_WS := C;
               end if;
               Last_Non_WS := C;
            end if;

            if Escaped then
               Escaped := False;
            elsif C = '\' and then In_Quotes then
               Escaped := True;
            elsif C = '"' then
               In_Quotes := not In_Quotes;
            elsif not In_Quotes then
               if C = '{' then
                  if Brace_Depth < Max_Text_Len then
                     Brace_Depth := Brace_Depth + 1;
                  else
                     return False;
                  end if;
               elsif C = '}' then
                  Brace_Depth := Brace_Depth - 1;
                  if Brace_Depth < 0 then
                     return False;
                  end if;
               elsif C = '[' then
                  if Bracket_Depth < Max_Text_Len then
                     Bracket_Depth := Bracket_Depth + 1;
                  else
                     return False;
                  end if;
               elsif C = ']' then
                  Bracket_Depth := Bracket_Depth - 1;
                  if Bracket_Depth < 0 then
                     return False;
                  end if;
               end if;
            end if;
         end;
      end loop;

      if In_Quotes or else Escaped or else Brace_Depth /= 0 or else Bracket_Depth /= 0 then
         return False;
      end if;

      return (First_Non_WS = '{' and then Last_Non_WS = '}')
        or else (First_Non_WS = '[' and then Last_Non_WS = ']');
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
         pragma Loop_Invariant (I in 1 .. Doc.Count);
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Key;

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
           (I in 1 .. Doc.Count and not Found);
         if Doc.Fields (I).Active and then Equal_Ident (Doc.Fields (I).Key, Key) then
            Val   := Doc.Fields (I).Val;
            Found := True;
            return;
         end if;
      end loop;
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
