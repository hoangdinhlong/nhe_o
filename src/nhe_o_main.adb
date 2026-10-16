--  Formally Verified Entrypoint for Nhe_O Embedded DBMS (SPARK_Mode => On)
pragma SPARK_Mode (On);

with Interfaces;       use Interfaces;
with Nhe_O;
with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.Vector;      use Nhe_O.Vector;
with Nhe_O.JSON;        use Nhe_O.JSON;
with Nhe_O.IO;          use Nhe_O.IO;
with Nhe_O.Transaction; use Nhe_O.Transaction;
with Nhe_O.KV;          use Nhe_O.KV;
with Nhe_O.PubSub;      use Nhe_O.PubSub;
with Nhe_O.SQL;         use Nhe_O.SQL;

procedure Nhe_O_Main is

   --  1. PostgreSQL SQL & Type variables
   SQL_Query : constant Bounded_Text := Make_Text (
     "SELECT id, meta->>'title', embedding <-> $1::vector AS dist " &
     "FROM documents WHERE meta @> '{""lang"":""vi""}'::jsonb ORDER BY dist LIMIT 5;"
   );
   SQL_Vec_Only : constant Bounded_Text := Make_Text (
     "SELECT id FROM embeddings ORDER BY vec <-> $3 LIMIT 10;"
   );
   SQL_Quoted_Noise : constant Bounded_Text := Make_Text (
     "SELECT returning_user FROM my_table WHERE note = '$1::jsonb -> a <-> b RETURNING';"
   );
   SQL_Create_Idx : constant Bounded_Text := Make_Text (
     "CREATE INDEX idx_vec ON my_table (vec);"
   );
   SQL_Desc   : Parsed_SQL_Descriptor;
   SQL_Status : Engine_Status;
   Resolved_T : Pg_Data_Type;
   Type_Valid : Boolean;

   --  2. Vector Database variables
   Vec_A     : constant Vector_Value := Make_Vector_3D (1.0, 0.0, 0.0);
   Vec_B     : constant Vector_Value := Make_Vector_3D (1.0, 0.0, 0.0);
   Vec_C     : constant Vector_Value := Make_Vector_3D (0.0, 3.0, 4.0);
   Vec_Max   : constant Vector_Value := Make_Vector_3D (Max_Component, 0.0, 0.0);
   Vec_Small : constant Vector_Value := Make_Vector_3D (1.0e-7, 0.0, 0.0);
   Vec_Zero  : constant Vector_Value := Make_Vector_3D (0.0, 0.0, 0.0);
   L2_AB     : Non_Negative_Float;
   L2_AC     : Non_Negative_Float;
   L2_Max    : Non_Negative_Float;
   Cos_AB    : Float;
   Cos_Max   : Float;
   Cos_Small : Float;
   NIP_AC    : Float;

   --  3. PostgreSQL JSON / JSONB variables
   Raw_JSON     : constant Bounded_Text := Make_Text (
     "{""engine"":""Nhe_O"",""verified"":true,""dims"":[3,256],""meta"":{""v"":0.1}}"
   );
   Bad_JSON_1   : constant Bounded_Text := Make_Text ("{[}]{}");
   Bad_JSON_2   : constant Bounded_Text := Make_Text ("{""a"":1}{""b"":2}");
   Bad_JSON_3   : constant Bounded_Text := Make_Text ("{:}");
   Bad_JSON_4   : constant Bounded_Text := Make_Text ("{""a"":1,}");
   Bad_JSON_5   : constant Bounded_Text := Make_Text ("{""a"" ""b""}");
   Bad_JSON_6   : constant Bounded_Text := Make_Text ("{123:456}");
   Bad_JSON_7   : constant Bounded_Text := Make_Text ("{$$$}");
   Doc_Main     : JSONB_Document;
   Doc_Filter   : JSONB_Document;
   JSON_Stat    : Engine_Status;
   Field_Hit    : Boolean;
   Field_Val    : Bounded_Text;
   Field_Kind   : JSONB_Value_Kind;

   --  4. ACID Transaction, MVCC & WAL Disk Persistence variables
   Next_Tx      : Valid_Tx_Id := 1;
   Tx_1         : Transaction_Context;
   Tuple_1      : MVCC_Tuple_Header;
   Page_Out     : constant Page_Buffer := [1 => 16#4E#, 2 => 16#48#, 3 => 16#45#, 4 => 16#4F#, others => 0];
   Page_In      : Page_Buffer := [others => 0];
   Dec_Page     : Page_Buffer := [others => 0];
   WAL_In       : WAL_Frame_Buffer := [others => 0];
   Dec_Tx       : Valid_Tx_Id;
   Dec_Page_Id  : Valid_Page_Id;
   DB_File      : constant Bounded_Text := Make_Text ("/tmp/nhe_o_verify.nhe_o");
   WAL_File     : constant Bounded_Text := Make_Text ("/tmp/nhe_o_verify.nhe_o.wal");
   NUL_Path     : Bounded_Text := Make_Text ("/tmp/nhe_o_bad");
   Tx_Status    : Engine_Status;
   Read_Ok      : Boolean;
   WAL_Read_Ok  : Boolean;
   NUL_Write_Ok : Boolean;
   CRC_Before   : Unsigned_32;
   CRC_After    : Unsigned_32;

   --  5. Redis-Compatible Key-Value Cache variables
   Cache      : KV_Store;
   KV_Val     : Bounded_Text;
   KV_Status  : Engine_Status;
   KV_Removed : Boolean;
   Counter_V  : Integer_64;

   --  6. Pub/Sub Broker variables
   Broker     : PubSub_Broker;
   Sub_Exact  : Subscriber_Id;
   Sub_Wild   : Subscriber_Id;
   Sub_Stat   : Engine_Status;
   Deliv_Cnt  : Subscriber_Count;
   Msg_Out    : PubSub_Message;
   Msg_Found  : Boolean;

begin
   Print_Line ("=====================================================================");
   Print_Line ("  Nhe_O Embedded Multi-Model Database Engine (Ada 2022 / SPARK 2022)");
   Print_Line ("  Version: " & Nhe_O.Version & " | 100% SPARK_Mode (On) — Core & POSIX I/O");
   Print_Line ("=====================================================================");
   Print_Blank_Line;

   --  1. Verify PostgreSQL SQL Syntax & Data Type Catalog
   Print_Line ("[1/6] Verifying PostgreSQL SQL Dialect & Data Types (Nhe_O.SQL / Nhe_O.Types)...");
   Analyze_SQL (SQL_Query, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Ok);
   pragma Assert (SQL_Desc.Kind = Stmt_Select);
   pragma Assert (SQL_Desc.Has_Positional_Param);
   pragma Assert (SQL_Desc.Has_Pg_Type_Cast);
   pragma Assert (SQL_Desc.Has_Vector_Operator);
   pragma Assert (SQL_Desc.Has_JSONB_Operator);

   --  Verify pure vector query `<->` does NOT falsely set Has_JSONB_Operator
   Analyze_SQL (SQL_Vec_Only, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Ok);
   pragma Assert (SQL_Desc.Kind = Stmt_Select);
   pragma Assert (SQL_Desc.Has_Positional_Param);
   pragma Assert (SQL_Desc.Has_Vector_Operator);
   pragma Assert (not SQL_Desc.Has_JSONB_Operator);

   --  Verify operators/keywords inside single quotes or identifier substrings do not false-trigger
   Analyze_SQL (SQL_Quoted_Noise, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Ok);
   pragma Assert (SQL_Desc.Kind = Stmt_Select);
   pragma Assert (not SQL_Desc.Has_Positional_Param);
   pragma Assert (not SQL_Desc.Has_Pg_Type_Cast);
   pragma Assert (not SQL_Desc.Has_Vector_Operator);
   pragma Assert (not SQL_Desc.Has_JSONB_Operator);
   pragma Assert (not SQL_Desc.Has_Returning);

   --  Verify `CREATE INDEX ... ON my_table` is not misclassified as Stmt_Create_Table
   Analyze_SQL (SQL_Create_Idx, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Invalid_Syntax);

   Resolve_Pg_Type (Make_Ident ("JSONB"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_JSONB);
   Resolve_Pg_Type (Make_Ident ("VECTOR"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_Vector);
   Resolve_Pg_Type (Make_Ident ("VECTOR(256)"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_Vector);
   Resolve_Pg_Type (Make_Ident ("NUMERIC(10,2)"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_Numeric);
   Print_Line ("  => Passed: PostgreSQL SELECT with $1::vector, <->, ->>, and @> parsed.");

   --  2. Verify Vector Database Engine (`<->`, `<=>`, `<#>`)
   Print_Line ("[2/6] Verifying Vector Similarity Engine (Nhe_O.Vector)...");
   L2_AB     := L2_Distance (Vec_A, Vec_B);
   L2_AC     := L2_Distance_Squared (Vec_A, Vec_C);
   L2_Max    := L2_Distance (Vec_Max, Vec_Zero);
   Cos_AB    := Cosine_Distance (Vec_A, Vec_B);
   Cos_Max   := Cosine_Distance (Vec_Max, Vec_Max);
   Cos_Small := Cosine_Distance (Vec_Small, Vec_Small);
   NIP_AC    := Negative_Inner_Product (Vec_A, Vec_C);
   pragma Assert (L2_AB < 0.001);
   pragma Assert (abs (L2_AC - 26.0) < 0.001);
   pragma Assert (abs (L2_Max - Max_Component) < 1.0);
   pragma Assert (Cos_AB < 0.001);
   pragma Assert (Cos_Max < 0.001);
   pragma Assert (Cos_Small < 0.001);
   pragma Assert (abs (Sqrt_Bounded (1.0e-36) - 1.0e-18) <= 1.0e-23);
   pragma Assert (abs (NIP_AC - 0.0) < 0.001);
   Print_Line ("  => Passed: L2 (<->), Cosine (<=>), and Inner Product (<#>) invariants hold.");

   --  3. Verify PostgreSQL JSON / JSONB Engine (`->`, `->>`, `@>`, `?`)
   Print_Line ("[3/6] Verifying PostgreSQL JSON/JSONB Engine (Nhe_O.JSON)...");
   pragma Assert (Is_Valid_JSON (Raw_JSON));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_1));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_2));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_3));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_4));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_5));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_6));
   pragma Assert (not Is_Valid_JSON (Bad_JSON_7));
   Put_Field (Doc_Main, Make_Ident ("engine"), Make_Text ("Nhe_O"), JSONB_String, JSON_Stat);
   pragma Assert (JSON_Stat = Status_Ok);
   Put_Field (Doc_Main, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);
   pragma Assert (JSON_Stat = Status_Ok);

   Put_Field (Doc_Filter, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);
   pragma Assert (JSON_Stat = Status_Ok);

   pragma Assert (Has_Key (Doc_Main, Make_Ident ("engine")));
   Get_Field (Doc_Main, Make_Ident ("engine"), Field_Hit, Field_Val, Field_Kind);
   pragma Assert (Field_Hit and then Field_Kind = JSONB_String);
   Get_Field_Text (Doc_Main, Make_Ident ("engine"), Field_Hit, Field_Val);
   pragma Assert (Field_Hit and then Equal_Text (Field_Val, Make_Text ("Nhe_O")));
   pragma Assert (Contains (Doc_Main, Doc_Filter));
   Print_Line ("  => Passed: JSON syntax check and JSONB `?`, `->`, `->>`, `@>` operators verified.");

   --  4. Verify ACID MVCC Visibility & Disk WAL/Page Persistence
   Print_Line ("[4/6] Verifying ACID Transactions, MVCC & Disk WAL I/O (Nhe_O.Transaction / Nhe_O.IO)...");
   Delete_File_If_Exists (DB_File);
   Delete_File_If_Exists (WAL_File);

   Begin_Tx (Next_Tx, Tx_1);
   Tuple_1 := (Xmin => Tx_1.Id, Xmax => 0);
   pragma Assert (Is_Tuple_Visible (Tuple_1, Tx_1.Snapshot));

   CRC_Before := Compute_CRC32 (Page_Out);
   Commit_Tx (Tx_1, DB_File, WAL_File, 0, Page_Out, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok and then Tx_1.State = Tx_Committed);

   Read_Page (DB_File, 0, Page_In, Read_Ok);
   CRC_After := Compute_CRC32 (Page_In);
   pragma Assert (Read_Ok and then CRC_Before = CRC_After);

   --  Verify on-disk WAL frame header + payload integrity, decoding, and tamper detection
   Read_WAL_Frame (WAL_File, 0, WAL_In, WAL_Read_Ok);
   pragma Assert (WAL_Read_Ok and then Verify_WAL_Frame (WAL_In));
   Decode_WAL_Frame (WAL_In, Dec_Tx, Dec_Page_Id, Dec_Page);
   pragma Assert (Dec_Tx = Tx_1.Id and then Dec_Page_Id = 0);
   pragma Assert (Compute_CRC32 (Dec_Page) = CRC_Before);
   WAL_In (9) := WAL_In (9) xor 16#01#; --  Flip bit in Page_Id header field
   pragma Assert (not Verify_WAL_Frame (WAL_In));

   --  Verify embedded NUL path rejection
   NUL_Path.Data (6) := ASCII.NUL;
   Write_Page (NUL_Path, 0, Page_Out, NUL_Write_Ok);
   pragma Assert (not NUL_Write_Ok);

   Delete_File_If_Exists (DB_File);
   Delete_File_If_Exists (WAL_File);
   Print_Line ("  => Passed: MVCC snapshot visibility, WAL frame append, and 4KB page CRC32 verified.");

   --  5. Verify Redis-Compatible Key-Value Cache & TTL Expiration
   Print_Line ("[5/6] Verifying Redis-Compatible Key-Value Cache & TTL (Nhe_O.KV)...");
   Set (Cache, Make_Ident ("session:42"), Make_Text ("user_long"), Now => 1000, Has_TTL => True, TTL_Sec => 60);
   pragma Assert (Exists (Cache, Make_Ident ("session:42"), Now => 1030));
   pragma Assert (Remaining_TTL (Cache, Make_Ident ("session:42"), Now => 1030) = 30);

   Get (Cache, Make_Ident ("session:42"), Now => 1030, Val => KV_Val, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Equal_Text (KV_Val, Make_Text ("user_long")));

   --  Verify expiration at Now = 1061 (BR-004)
   Get (Cache, Make_Ident ("session:42"), Now => 1061, Val => KV_Val, Status => KV_Status);
   pragma Assert (KV_Status = Status_Expired);
   pragma Assert (not Exists (Cache, Make_Ident ("session:42"), Now => 1061));

   Incr_By (Cache, Make_Ident ("metrics:hits"), 5, Now => 1062, New_Val => Counter_V, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Counter_V = 5);
   Incr_By (Cache, Make_Ident ("metrics:hits"), 10, Now => 1063, New_Val => Counter_V, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Counter_V = 15);
   Get (Cache, Make_Ident ("metrics:hits"), Now => 1063, Val => KV_Val, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Equal_Text (KV_Val, Make_Text ("15")));

   --  Verify Redis SET numeric string followed by INCRBY
   Set (Cache, Make_Ident ("metrics:seeded"), Make_Text ("10"), Now => 1064);
   Incr_By (Cache, Make_Ident ("metrics:seeded"), 5, Now => 1065, New_Val => Counter_V, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Counter_V = 15);

   Del (Cache, Make_Ident ("metrics:hits"), KV_Removed);
   pragma Assert (KV_Removed and then not Exists (Cache, Make_Ident ("metrics:hits"), Now => 1065));
   Print_Line ("  => Passed: Redis SETEX, GET, DEL, TTL lazy expiration, and atomic INCRBY verified.");

   --  6. Verify Pub/Sub Channel & Wildcard Pattern Broker
   Print_Line ("[6/6] Verifying Ring-Buffer Pub/Sub Broker (Nhe_O.PubSub)...");
   Subscribe (Broker, Make_Ident ("cache.invalidation"), Sub_Exact, Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok);
   Subscribe (Broker, Make_Ident ("cache.*"), Sub_Wild, Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok);

   Publish (Broker, Make_Ident ("cache.invalidation"), Make_Text ("key=session:42"), Deliv_Cnt);
   pragma Assert (Deliv_Cnt = 2);

   Poll_Message (Broker, Sub_Exact, Msg_Out, Msg_Found);
   pragma Assert (Msg_Found and then Equal_Text (Msg_Out.Payload, Make_Text ("key=session:42")));
   Poll_Message (Broker, Sub_Wild, Msg_Out, Msg_Found);
   pragma Assert (Msg_Found and then Equal_Text (Msg_Out.Payload, Make_Text ("key=session:42")));
   Unsubscribe (Broker, Sub_Exact);
   Unsubscribe (Broker, Sub_Wild);
   Print_Line ("  => Passed: Exact and wildcard (`cache.*`) Pub/Sub delivery verified.");

   Print_Blank_Line;
   Print_Line ("ALL Nhe_O SPARK/Ada Verification Suites Passed Successfully.");
end Nhe_O_Main;
