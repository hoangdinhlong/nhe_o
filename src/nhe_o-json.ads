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

   --  Validate RFC 8259 syntax for PostgreSQL JSON / JSONB literal (objects,
   --  arrays, and scalar roots: strings, numbers, booleans, null)
   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean
     with Global => null;

   --  Validate that a field value is well-formed for its declared JSONB_Value_Kind
   function Is_Valid_Field_Value
     (Val  : Bounded_Text;
      Kind : JSONB_Value_Kind) return Boolean
     with Global => null;

   --  PostgreSQL `?` operator: Does the key exist as a top-level key in JSONB?
   function Has_Key
     (Doc : JSONB_Document;
      Key : Bounded_Ident) return Boolean
     with Global => null,
          Post   => Has_Key'Result =
                      (for some I in 1 .. Doc.Count =>
                         Doc.Fields (I).Active
                         and then Equal_Ident (Doc.Fields (I).Key, Key));

   --  Put or update a field in a decomposed JSONB document (`jsonb_set`),
   --  validating Val against Kind
   procedure Put_Field
     (Doc    : in out JSONB_Document;
      Key    : in     Bounded_Ident;
      Val    : in     Bounded_Text;
      Kind   : in     JSONB_Value_Kind;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Key.Length > 0,
          Post   => (if Status = Status_Ok then
                       Doc.Count >= Doc.Count'Old
                       and then Has_Key (Doc, Key)
                     else
                       Doc.Count = Doc.Count'Old);

   --  Parse a JSON object string (`{"k":"v", "n":42, ...}`) into a JSONB_Document
   procedure Parse_JSONB
     (Raw    : in     Bounded_Text;
      Doc    :    out JSONB_Document;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates;

   --  PostgreSQL `->` operator: Extract JSON object field as a valid JSON value
   --  (e.g., string values are returned quoted as `"val"`)
   procedure Get_Field
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text;
      Kind  :    out JSONB_Value_Kind)
     with Global => null,
          Always_Terminates,
          Post   => (if Found then Has_Key (Doc, Key));

   --  PostgreSQL `->>` operator: Extract JSON object field as unquoted TEXT
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
