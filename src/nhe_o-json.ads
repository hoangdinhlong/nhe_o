--  Formally verified PostgreSQL JSON and JSONB Engine (BR-003)
pragma SPARK_Mode (On);

with Nhe_O.Types; use Nhe_O.Types;

package Nhe_O.JSON is

   Max_JSON_Fields : constant := 16;
   subtype Field_Count is Natural range 0 .. Max_JSON_Fields;
   subtype Field_Index is Positive range 1 .. Max_JSON_Fields;

   type JSONB_Value_Kind is (
      JSONB_Null,
      JSONB_Boolean,
      JSONB_Number,
      JSONB_String,
      JSONB_Object,
      JSONB_Array
   );

   type JSONB_Entry is record
      Key    : Bounded_Ident    := (Length => 0, Data => [others => ' ']);
      Val    : Bounded_Text     := (Length => 0, Data => [others => ' ']);
      Kind   : JSONB_Value_Kind := JSONB_String;
      Active : Boolean          := False;
   end record;

   type JSONB_Field_Array is array (Field_Index) of JSONB_Entry;

   type JSONB_Document is record
      Count  : Field_Count       := 0;
      Fields : JSONB_Field_Array := [others => (others => <>)];
   end record;

   --  Validate structural balanced syntax for PostgreSQL JSON / JSONB literal
   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean
     with Global => null;

   --  Put or update a field in a decomposed JSONB document (`jsonb_set`)
   procedure Put_Field
     (Doc    : in out JSONB_Document;
      Key    : in     Bounded_Ident;
      Val    : in     Bounded_Text;
      Kind   : in     JSONB_Value_Kind;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0,
          Post   => (if Status = Status_Ok then Doc.Count >= Doc.Count'Old);

   --  PostgreSQL `?` operator: Does the key exist as a top-level key in JSONB?
   function Has_Key
     (Doc : JSONB_Document;
      Key : Bounded_Ident) return Boolean
     with Global => null,
          Post   => Has_Key'Result =
                      (for some I in 1 .. Doc.Count =>
                         Doc.Fields (I).Active
                         and then Equal_Ident (Doc.Fields (I).Key, Key));

   --  PostgreSQL `->` operator: Extract JSON object field with its JSONB value kind
   procedure Get_Field
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text;
      Kind  :    out JSONB_Value_Kind)
     with Global => null,
          Always_Terminates,
          Post   => (if Found then Has_Key (Doc, Key));

   --  PostgreSQL `->>` operator: Extract JSON object field as TEXT
   procedure Get_Field_Text
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text)
     with Global => null,
          Always_Terminates,
          Post   => (if Found then Has_Key (Doc, Key));

   --  PostgreSQL `@>` operator: Does Left JSONB contain all key/value entries of Right JSONB?
   function Contains
     (Left, Right : JSONB_Document) return Boolean
     with Global => null;

end Nhe_O.JSON;
