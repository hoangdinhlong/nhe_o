pragma SPARK_Mode (On);

package body Nhe_O.JSON is

   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean is
      Stack        : String (1 .. Max_Text_Len) := [others => ' '];
      Depth        : Natural range 0 .. Max_Text_Len := 0;
      In_Quotes    : Boolean := False;
      Escaped      : Boolean := False;
      Root_Started : Boolean := False;
      Root_Closed  : Boolean := False;
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
            if In_Quotes then
               if Escaped then
                  Escaped := False;
               elsif C = '\' then
                  Escaped := True;
               elsif C = '"' then
                  In_Quotes := False;
               end if;
            elsif not Is_WS then
               if Root_Closed then
                  --  Reject trailing non-whitespace tokens or concatenated roots (e.g. `{}{}`)
                  return False;
               elsif not Root_Started then
                  if C /= '{' and then C /= '[' then
                     return False;
                  end if;
                  Root_Started := True;
                  Depth        := 1;
                  Stack (1)    := C;
               elsif C = '"' then
                  In_Quotes := True;
               elsif C = '{' or else C = '[' then
                  if Depth < Max_Text_Len then
                     Depth         := Depth + 1;
                     Stack (Depth) := C;
                  else
                     return False;
                  end if;
               elsif C = '}' then
                  if Depth = 0 or else Stack (Depth) /= '{' then
                     return False;
                  end if;
                  Depth := Depth - 1;
                  if Depth = 0 then
                     Root_Closed := True;
                  end if;
               elsif C = ']' then
                  if Depth = 0 or else Stack (Depth) /= '[' then
                     return False;
                  end if;
                  Depth := Depth - 1;
                  if Depth = 0 then
                     Root_Closed := True;
                  end if;
               end if;
            end if;
         end;
      end loop;

      return Root_Started
        and then Root_Closed
        and then Depth = 0
        and then not In_Quotes
        and then not Escaped;
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
