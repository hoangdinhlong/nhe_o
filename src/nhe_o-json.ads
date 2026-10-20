--  Formally verified PostgreSQL JSON and JSONB Engine (BR-003)
pragma SPARK_Mode (On);

with Nhe_O.Types; use Nhe_O.Types;

package Nhe_O.JSON is

   Max_JSON_Fields : constant := 16;
   subtype Field_Count is Natural range 0 .. Max_JSON_Fields;
   subtype Field_Index is Positive range 1 .. Max_JSON_Fields;

   --  Maximum container nesting of a JSONB document, counting the root object
   --  as level 1 (a stored field value may therefore nest Max_JSONB_Depth - 1
   --  levels). Enforced at ingest so that `@>` never runs out of depth.
   Max_JSONB_Depth : constant := 64;

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

   --  Length of byte C once escaped inside a JSON string literal by `->`
   --  (`\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, `\u00XX` for other controls)
   function JSON_Escape_Length (C : Character) return Positive is
     (case C is
         when '"' | '\' | ASCII.BS | ASCII.HT | ASCII.LF | ASCII.FF | ASCII.CR => 2,
         when ASCII.NUL .. ASCII.BEL | ASCII.VT | ASCII.SO .. ASCII.US       => 6,
         when others                                                         => 1);

   --  Escaped length of Val.Data (From .. Val.Length)
   function JSON_Escaped_Suffix_Length
     (Val  : Bounded_Text;
      From : Positive) return Natural
   is
     (if From > Val.Length then 0
      else JSON_Escape_Length (Val.Data (From))
           + JSON_Escaped_Suffix_Length (Val, From + 1))
     with Global             => null,
          Pre                => From <= Val.Length + 1,
          Post               => JSON_Escaped_Suffix_Length'Result
                                  in Val.Length + 1 - From .. 6 * (Val.Length + 1 - From),
          Subprogram_Variant => (Decreases => Val.Length + 1 - From);

   --  Length of the quoted JSON string literal produced by `->` for Val
   function JSON_Quoted_Length (Val : Bounded_Text) return Positive is
     (2 + JSON_Escaped_Suffix_Length (Val, 1))
     with Global => null;

   --  Validate RFC 8259 syntax for PostgreSQL JSON / JSONB literal (objects,
   --  arrays, and scalar roots: strings, numbers, booleans, null). Strings must
   --  be well-formed UTF-8, `\uXXXX` UTF-16 surrogates must form a high/low
   --  pair, and U+0000 (raw or escaped) is rejected as in PostgreSQL jsonb.
   function Is_Valid_JSON (Raw : Bounded_Text) return Boolean
     with Global => null;

   --  Validate that a field value is well-formed for its declared JSONB_Value_Kind.
   --  JSONB_String: decoded bytes, well-formed UTF-8 without NUL, whose quoted
   --  `->` form fits in Max_Text_Len. JSONB_Number / JSONB_Object / JSONB_Array:
   --  one RFC 8259 value obeying the JSONB ingest rules (numbers within the
   --  PostgreSQL numeric range, object keys of 1 .. Max_Ident_Len decoded bytes
   --  at every depth, nesting of at most Max_JSONB_Depth - 1 levels).
   function Is_Valid_Field_Value
     (Val  : Bounded_Text;
      Kind : JSONB_Value_Kind) return Boolean
     with Global => null,
          Post   => (if Is_Valid_Field_Value'Result and then Kind = JSONB_String then
                       JSON_Quoted_Length (Val) <= Max_Text_Len);

   --  PostgreSQL `?` operator: Does the key exist as a top-level key in JSONB?
   function Has_Key
     (Doc : JSONB_Document;
      Key : Bounded_Ident) return Boolean
     with Global => null,
          Post   => Has_Key'Result =
                      (for some I in 1 .. Doc.Count =>
                         Doc.Fields (I).Active
                         and then Equal_Ident (Doc.Fields (I).Key, Key));

   --  Index of the first active top-level field whose key is Key (0 if none)
   function Find_Field
     (Doc : JSONB_Document;
      Key : Bounded_Ident) return Field_Count
     with Global => null,
          Post   => (Find_Field'Result = 0) = not Has_Key (Doc, Key)
                    and then (if Find_Field'Result /= 0 then
                                Find_Field'Result <= Doc.Count
                                and then Doc.Fields (Find_Field'Result).Active
                                and then Equal_Ident (Doc.Fields (Find_Field'Result).Key, Key)
                                and then (for all J in 1 .. Find_Field'Result - 1 =>
                                            not (Doc.Fields (J).Active
                                                 and then Equal_Ident (Doc.Fields (J).Key, Key))));

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
   --  (duplicate keys: the last occurrence wins, at every depth as in PostgreSQL).
   --  Status_Invalid_Syntax: not Is_Valid_JSON (incl. ill-formed UTF-8, lone or
   --  reversed `\u` surrogates, U+0000), not an object root, or an empty object
   --  key at any depth. Syntax is checked first, so text that is not valid JSON
   --  is Status_Invalid_Syntax even when it also breaks an ingest limit.
   --  Status_Capacity_Exceeded: more than Max_JSON_Fields distinct top-level
   --  keys, a key longer than Max_Ident_Len decoded bytes (any depth), nesting
   --  deeper than Max_JSONB_Depth, or a number outside the PostgreSQL numeric
   --  range ("value overflows numeric format": |exponent| > 1073741823, display
   --  scale > 16383, or magnitude >= 10**131072).
   procedure Parse_JSONB
     (Raw    : in     Bounded_Text;
      Doc    :    out JSONB_Document;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Post   => (if Status /= Status_Ok then Doc.Count = 0)
                    and then (if not Is_Valid_JSON (Raw) then Status = Status_Invalid_Syntax);

   --  PostgreSQL `->` operator: Extract JSON object field as a valid JSON value
   --  (e.g., string values are returned quoted as `"val"`, never truncated).
   --  Strings, booleans and null come back as PostgreSQL prints them; numbers,
   --  objects and arrays come back as their stored input literal (spelling,
   --  whitespace, key order and duplicate keys kept), which is jsonb-equal to
   --  PostgreSQL's value but not always the same text (`1e2` for `100`), so a
   --  returned container must be read with jsonb rules (the last duplicate key
   --  wins)
   procedure Get_Field
     (Doc   : in     JSONB_Document;
      Key   : in     Bounded_Ident;
      Found :    out Boolean;
      Val   :    out Bounded_Text;
      Kind  :    out JSONB_Value_Kind)
     with Global => null,
          Always_Terminates,
          Post   => Found = Has_Key (Doc, Key)
                    and then (if not Found then Val.Length = 0)
                    and then (if Found then
                                Kind = Doc.Fields (Find_Field (Doc, Key)).Kind
                                and then
                                  (if Kind = JSONB_String
                                     and then JSON_Quoted_Length
                                                (Doc.Fields (Find_Field (Doc, Key)).Val)
                                              <= Max_Text_Len
                                   then
                                     Val.Length =
                                       JSON_Quoted_Length
                                         (Doc.Fields (Find_Field (Doc, Key)).Val)));

   --  PostgreSQL `->>` operator: Extract JSON object field as unquoted TEXT.
   --  A JSON null yields SQL NULL (Is_Null) instead of the text "null".
   --  Strings yield their decoded bytes as in PostgreSQL; numbers, objects and
   --  arrays yield their stored input literal (see Get_Field)
   procedure Get_Field_Text
     (Doc     : in     JSONB_Document;
      Key     : in     Bounded_Ident;
      Found   :    out Boolean;
      Val     :    out Bounded_Text;
      Is_Null :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => Found = Has_Key (Doc, Key)
                    and then (if not Found then Val.Length = 0)
                    and then Is_Null =
                               (Found
                                and then Doc.Fields (Find_Field (Doc, Key)).Kind = JSONB_Null)
                    and then (if Is_Null then Val.Length = 0);

   --  PostgreSQL `@>` operator (JsonbDeepContains): Does Left contain Right?
   --  Every top-level key of Right must exist in Left with a contained value:
   --  scalars compare exactly (numbers by value, strings by decoded bytes), an
   --  object contains an object whose every key maps to a contained value, an
   --  array contains an array whose every element is contained in some element
   --  of the same kind (a scalar never matches a container), at every depth.
   function Contains
     (Left, Right : JSONB_Document) return Boolean
     with Global => null,
          Post   => (if Right.Count = 0 then Contains'Result)
                    and then (if Contains'Result then
                                (for all I in 1 .. Right.Count =>
                                   (if Right.Fields (I).Active then
                                      Has_Key (Left, Right.Fields (I).Key))));

end Nhe_O.JSON;
