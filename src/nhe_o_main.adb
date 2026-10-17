--  Formally Verified Entrypoint for Nhe_O Embedded DBMS (SPARK_Mode => On)
pragma SPARK_Mode (On);

with Interfaces;        use Interfaces;
with Nhe_O;
with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.Vector;      use Nhe_O.Vector;
with Nhe_O.JSON;        use Nhe_O.JSON;
with Nhe_O.IO;          use Nhe_O.IO;
with Nhe_O.Transaction; use Nhe_O.Transaction;
with Nhe_O.BTree;       use Nhe_O.BTree;
with Nhe_O.HNSW;        use Nhe_O.HNSW;
with Nhe_O.KV;          use Nhe_O.KV;
with Nhe_O.PubSub;      use Nhe_O.PubSub;
with Nhe_O.SQL;         use Nhe_O.SQL;
with Nhe_O.RAG;         use Nhe_O.RAG;

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

   --  2. Vector Database & 4096-D Quantization variables
   Vec_A      : constant Vector_Value := Make_Vector_3D (1.0, 0.0, 0.0);
   Vec_B      : constant Vector_Value := Make_Vector_3D (1.0, 0.0, 0.0);
   Vec_C      : constant Vector_Value := Make_Vector_3D (0.0, 3.0, 4.0);
   Vec_Max    : constant Vector_Value := Make_Vector_3D (Max_Component, 0.0, 0.0);
   Vec_Small  : constant Vector_Value := Make_Vector_3D (1.0e-7, 0.0, 0.0);
   Vec_Zero   : constant Vector_Value := Make_Vector_3D (0.0, 0.0, 0.0);
   Vec_4096_A : constant Vector_Value := (Dim => 4096, Elements => [1 => 1.0, 2048 => -1.0, 4096 => 0.5, others => 0.25]);
   Vec_4096_B : constant Vector_Value := (Dim => 4096, Elements => [1 => 1.0, 2048 =>  1.0, 4096 => -0.5, others => 0.25]);
   Q_Int8_A   : Quantized_Int8_Vector;
   Q_Int8_B   : Quantized_Int8_Vector;
   Deq_Vec_A  : Vector_Value;
   Q_Bin_A    : Quantized_Binary_Vector;
   Q_Bin_B    : Quantized_Binary_Vector;
   Ham_Dist   : Natural;
   Int8_Dist  : Natural;
   L2_AB      : Non_Negative_Float;
   L2_AC      : Non_Negative_Float;
   L2_Max     : Non_Negative_Float;
   Cos_AB     : Float;
   Cos_Max    : Float;
   Cos_Small  : Float;
   NIP_AC     : Float;

   --  3. PostgreSQL JSON / JSONB variables
   Raw_JSON     : constant Bounded_Text := Make_Text (
     "{""engine"":""Nhe_O"",""verified"":true,""dims"":[3,4096],""meta"":{""v"":0.2}}"
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

   --  4 & 5. ACID Transaction, MVCC, WAL Recovery & 4KB TOAST Overflow variables
   Next_Tx       : Valid_Tx_Id := 1;
   Tx_1          : Transaction_Context;
   Tx_Toast      : Transaction_Context;
   Tuple_1       : MVCC_Tuple_Header;
   Page_Out      : constant Page_Buffer := [1 => 16#4E#, 2 => 16#48#, 3 => 16#45#, 4 => 16#4F#, others => 0];
   Page_In       : Page_Buffer := [others => 0];
   Dec_Page      : Page_Buffer := [others => 0];
   WAL_In        : WAL_Frame_Buffer := [others => 0];
   Dec_Tx        : Valid_Tx_Id;
   Dec_Page_Id   : Valid_Page_Id;
   DB_File       : constant Bounded_Text := Make_Text ("/tmp/nhe_o_verify.nhe_o");
   WAL_File      : constant Bounded_Text := Make_Text ("/tmp/nhe_o_verify.nhe_o.wal");
   NUL_Path      : Bounded_Text := Make_Text ("/tmp/nhe_o_bad");
   Tx_Status     : Engine_Status;
   Read_Ok       : Boolean;
   WAL_Read_Ok   : Boolean;
   NUL_Write_Ok  : Boolean;
   CRC_Before    : Unsigned_32;
   CRC_After     : Unsigned_32;
   Toast_Out     : constant TOAST_Payload_Buffer :=
     [1 => 16#51#, 4081 => 16#57#, 8161 => 16#45#, 10000 => 16#4E#, others => 16#2A#];
   Toast_In      : TOAST_Payload_Buffer := [others => 0];
   Toast_Len_Out : TOAST_Payload_Length;
   Toast_Ptr     : TOAST_Pointer;
   Toast_Bytes   : TOAST_Pointer_Bytes;
   Toast_Dec_Ptr : TOAST_Pointer;
   Toast_Ptr_Ok  : Boolean;
   Replayed_Cnt  : Natural;
   Max_Rec_Tx    : Tx_Id;

   --  6. Multi-Page B+Tree Index variables
   Tree_Idx      : BTree_Index;
   BTree_Stat    : Engine_Status;
   BTree_Hit     : Boolean;
   BTree_Ptr     : BTree_Record_Pointer;
   BTree_Scan    : BTree_Scan_Result;
   BTree_Page    : Page_Buffer;
   BTree_Dec_Nd  : BTree_Node;
   BTree_Dec_Ok  : Boolean;

   --  7. Multi-Layer HNSW Graph Index variables
   Graph_Idx     : HNSW_Index;
   HNSW_Stat     : Engine_Status;
   KNN_Float_Res : HNSW_Search_Result;
   KNN_Int8_Res  : HNSW_Search_Result;
   KNN_Bin_Res   : HNSW_Search_Result;

   --  8. Redis-Compatible Key-Value Cache variables
   Cache      : KV_Store;
   KV_Val     : Bounded_Text;
   KV_Status  : Engine_Status;
   KV_Removed : Boolean;
   Counter_V  : Integer_64;

   --  9. Dual-Mode Pub/Sub Broker & WAL Commit Barrier variables
   Broker      : PubSub_Broker;
   Sub_Exact   : Subscriber_Id;
   Sub_Wild    : Subscriber_Id;
   Sub_Durable : Subscriber_Id;
   Sub_Stat    : Engine_Status;
   Deliv_Cnt   : Subscriber_Count;
   Total_Deliv : Natural;
   Msg_Out     : PubSub_Message;
   Msg_Found   : Boolean;
   Tx_Notify_1 : Transaction_Context;
   Tx_Notify_2 : Transaction_Context;
   Staging_Buf : Tx_Notification_Buffer;

   --  10. Universal Local LLM RAG & Hybrid SQL Query Executor variables
   RAG_Store      : RAG_Engine;
   Tx_RAG         : Transaction_Context;
   RAG_Staging    : Tx_Notification_Buffer;
   Meta_Doc_1     : JSONB_Document;
   Meta_Doc_2     : JSONB_Document;
   Meta_RAG_Query : JSONB_Document;
   Parent_Chunk_1 : constant TOAST_Payload_Buffer :=
     [1 => Character'Pos ('Q'), 2 => Character'Pos ('w'), 3 => Character'Pos ('e'), 4 => Character'Pos ('n'),
      5000 => Character'Pos ('!'), others => Character'Pos (' ')];
   Parent_Chunk_2 : constant TOAST_Payload_Buffer :=
     [1 => Character'Pos ('A'), 2 => Character'Pos ('d'), 3 => Character'Pos ('a'), others => Character'Pos ('.')];
   Fetched_Chunk  : TOAST_Payload_Buffer := [others => 0];
   RAG_Res        : RAG_Query_Result;
   RAG_Status     : Engine_Status;

begin
   Print_Line ("=====================================================================");
   Print_Line ("  Nhe_O Embedded Multi-Model Database Engine (Ada 2022 / SPARK 2022)");
   Print_Line ("  Version: " & Nhe_O.Version & " | 100% SPARK_Mode (On) — Universal Local LLM RAG");
   Print_Line ("=====================================================================");
   Print_Blank_Line;

   --  1. Verify PostgreSQL SQL Syntax & Data Type Catalog
   Print_Line ("[1/10] Verifying PostgreSQL SQL Dialect & Data Types (Nhe_O.SQL / Nhe_O.Types)...");
   Analyze_SQL (SQL_Query, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Ok);
   pragma Assert (SQL_Desc.Kind = Stmt_Select);
   pragma Assert (SQL_Desc.Has_Positional_Param);
   pragma Assert (SQL_Desc.Has_Pg_Type_Cast);
   pragma Assert (SQL_Desc.Has_Vector_Operator);
   pragma Assert (SQL_Desc.Has_JSONB_Operator);

   Analyze_SQL (SQL_Vec_Only, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Ok and then not SQL_Desc.Has_JSONB_Operator);

   Analyze_SQL (SQL_Quoted_Noise, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Ok and then not SQL_Desc.Has_Vector_Operator);

   Analyze_SQL (SQL_Create_Idx, SQL_Desc, SQL_Status);
   pragma Assert (SQL_Status = Status_Invalid_Syntax);

   Resolve_Pg_Type (Make_Ident ("JSONB"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_JSONB);
   Resolve_Pg_Type (Make_Ident ("VECTOR(4096)"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_Vector);
   Resolve_Pg_Type (Make_Ident ("NUMERIC(10,2)"), Resolved_T, Type_Valid);
   pragma Assert (Type_Valid and then Resolved_T = Pg_Numeric);
   Print_Line ("  => Passed: PostgreSQL SELECT with $1::vector, VECTOR(4096), <->, ->>, and @> parsed.");

   --  2. Verify Vector Similarity & 4096-D Int8 / Binary Quantization (`ADR-003`)
   Print_Line ("[2/10] Verifying 4096-D Vector Engine & Int8/Binary Quantization (Nhe_O.Vector)...");
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
   pragma Assert (Cos_AB < 0.001 and then Cos_Max < 0.001 and then Cos_Small < 0.001);
   pragma Assert (abs (NIP_AC - 0.0) < 0.001);

   --  Verify 4096-D Scalar (Int8) and Binary (1-bit Hamming) quantization
   Q_Int8_A  := Quantize_To_Int8 (Vec_4096_A);
   Q_Int8_B  := Quantize_To_Int8 (Vec_4096_B);
   Deq_Vec_A := Dequantize_From_Int8 (Q_Int8_A);
   Int8_Dist := Int8_L2_Distance_Squared (Q_Int8_A, Q_Int8_B);
   pragma Assert (Q_Int8_A.Dim = 4096 and then Deq_Vec_A.Dim = 4096);
   pragma Assert (Int8_Dist > 0);
   pragma Assert (Int8_Inner_Product (Q_Int8_A, Q_Int8_A) > 0);

   Q_Bin_A  := Quantize_To_Binary (Vec_4096_A);
   Q_Bin_B  := Quantize_To_Binary (Vec_4096_B);
   Ham_Dist := Hamming_Distance (Q_Bin_A, Q_Bin_B);
   --  Vec_4096_A and Vec_4096_B differ in sign at exactly indices 2048 and 4096 (2 bits)!
   pragma Assert (Ham_Dist = 2);
   pragma Assert (Hamming_Distance (Q_Bin_A, Q_Bin_A) = 0);
   Print_Line ("  => Passed: 4096-D Float32, Int8 (SQ8 4x), and Binary (1-bit Hamming 32x) verified.");

   --  3. Verify PostgreSQL JSON / JSONB Engine (`->`, `->>`, `@>`, `?`)
   Print_Line ("[3/10] Verifying PostgreSQL JSON/JSONB Engine (Nhe_O.JSON)...");
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
   Print_Line ("[4/10] Verifying ACID Transactions, MVCC & Disk WAL I/O (Nhe_O.Transaction / Nhe_O.IO)...");
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

   Read_WAL_Frame (WAL_File, 0, WAL_In, WAL_Read_Ok);
   pragma Assert (WAL_Read_Ok and then Verify_WAL_Frame (WAL_In));
   Decode_WAL_Frame (WAL_In, Dec_Tx, Dec_Page_Id, Dec_Page);
   pragma Assert (Dec_Tx = Tx_1.Id and then Dec_Page_Id = 0);
   pragma Assert (Compute_CRC32 (Dec_Page) = CRC_Before);
   WAL_In (9) := WAL_In (9) xor 16#01#;
   pragma Assert (not Verify_WAL_Frame (WAL_In));

   NUL_Path.Data (6) := ASCII.NUL;
   Write_Page (NUL_Path, 0, Page_Out, NUL_Write_Ok);
   pragma Assert (not NUL_Write_Ok);
   Print_Line ("  => Passed: MVCC snapshot visibility, WAL frame append, and 4KB page CRC32 verified.");

   --  5. Verify 4KB TOAST Overflow Page Chains & WAL Crash Recovery (`ADR-003` / `BR-006`)
   Print_Line ("[5/10] Verifying 4KB TOAST Overflow Page Chains & WAL Recovery (Nhe_O.Transaction)...");
   Begin_Tx (Next_Tx, Tx_Toast);
   --  Write a 10,000-byte payload spanning 3 linked 4KB TOAST overflow pages (pages 2, 3, 4)
   Write_TOAST_Chain
     (Ctx           => Tx_Toast,
      DB_Path       => DB_File,
      WAL_Path      => WAL_File,
      Start_Page_Id => 2,
      Payload       => Toast_Out,
      Length        => 10_000,
      Ptr           => Toast_Ptr,
      Status        => Tx_Status);
   pragma Assert (Tx_Status = Status_Ok);
   pragma Assert (Toast_Ptr.Root_Overflow_Page = 2);
   pragma Assert (Toast_Ptr.Total_Byte_Length = 10_000);
   pragma Assert (Toast_Ptr.Chunk_Count = 3);

   Encode_TOAST_Pointer (Toast_Ptr, Toast_Bytes);
   Decode_TOAST_Pointer (Toast_Bytes, Toast_Dec_Ptr, Toast_Ptr_Ok);
   pragma Assert (Toast_Ptr_Ok and then Toast_Dec_Ptr = Toast_Ptr);

   Read_TOAST_Chain (DB_File, Toast_Dec_Ptr, Toast_In, Toast_Len_Out, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok and then Toast_Len_Out = 10_000);
   pragma Assert (Toast_In (1) = 16#51# and then Toast_In (4081) = 16#57#
                  and then Toast_In (8161) = 16#45# and then Toast_In (10000) = 16#4E#);

   --  Simulate crash recovery by deleting DB_File and replaying WAL frames via Redo_WAL_Recovery
   Delete_File_If_Exists (DB_File);
   Redo_WAL_Recovery (DB_File, WAL_File, 16, Replayed_Cnt, Max_Rec_Tx, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok and then Replayed_Cnt = 4);
   pragma Assert (Max_Rec_Tx = Tx_Toast.Id);

   --  Verify the 3-page TOAST chain is completely restored after WAL redo!
   Toast_In := [others => 0];
   Read_TOAST_Chain (DB_File, Toast_Dec_Ptr, Toast_In, Toast_Len_Out, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok and then Toast_Len_Out = 10_000);
   pragma Assert (Toast_In (10000) = 16#4E#);
   Commit_Tx (Tx_Toast, DB_File, WAL_File, 0, Page_Out, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok);
   Print_Line ("  => Passed: 16-byte TOAST pointer, 3-page 4KB overflow chain, and WAL Redo verified.");

   --  6. Verify Multi-Page B+Tree Index with Deterministic Node Splitting (`Nhe_O.BTree`)
   Print_Line ("[6/10] Verifying Multi-Page B+Tree Index & Leaf Splitting (Nhe_O.BTree)...");
   Init_BTree (Tree_Idx);
   for K in 1 .. 10 loop
      Insert_Key
        (Tree   => Tree_Idx,
         Key    => Integer_64 (K * 10),
         Ptr    => (Target_Page => K,
                    Target_Slot => K,
                    TOAST_Root  => K + 100),
         Status => BTree_Stat);
      pragma Assert (BTree_Stat = Status_Ok);
   end loop;
   pragma Assert (Tree_Idx.Total_Keys = 10);
   pragma Assert (Tree_Idx.Split_Count >= 2);
   pragma Assert (Tree_Idx.Nodes (Tree_Idx.Root_Node).Kind = Node_Internal);

   Search_Key (Tree_Idx, 70, BTree_Hit, BTree_Ptr);
   pragma Assert (BTree_Hit and then BTree_Ptr.Target_Page = 7 and then BTree_Ptr.TOAST_Root = 107);

   Range_Scan (Tree_Idx, 30, 80, BTree_Scan);
   pragma Assert (BTree_Scan.Count = 6);
   pragma Assert (BTree_Scan.Items (1).Key = 30 and then BTree_Scan.Items (6).Key = 80);

   Encode_Node_Page (Tree_Idx.Nodes (1), BTree_Page);
   Decode_Node_Page (BTree_Page, BTree_Dec_Nd, BTree_Dec_Ok);
   pragma Assert (BTree_Dec_Ok and then BTree_Dec_Nd.Num_Keys = Tree_Idx.Nodes (1).Num_Keys);
   Print_Line ("  => Passed: B+Tree leaf/root splits, key lookup, range scan, and 4KB page encoding verified.");

   --  7. Verify Multi-Layer HNSW Graph Index (`Nhe_O.HNSW`)
   Print_Line ("[7/10] Verifying Multi-Layer HNSW Vector Graph Index (Nhe_O.HNSW)...");
   Init_HNSW (Graph_Idx, Dim => 3);
   Insert_Vector (Graph_Idx, Doc_Id => 1, Vec => Make_Vector_3D (1.0, 0.0, 0.0), TOAST_Root => 10, Layer_Hint => 3, Status => HNSW_Stat);
   pragma Assert (HNSW_Stat = Status_Ok);
   Insert_Vector (Graph_Idx, Doc_Id => 2, Vec => Make_Vector_3D (0.9, 0.1, 0.0), TOAST_Root => 11, Layer_Hint => 2, Status => HNSW_Stat);
   pragma Assert (HNSW_Stat = Status_Ok);
   Insert_Vector (Graph_Idx, Doc_Id => 3, Vec => Make_Vector_3D (-1.0, -1.0, -1.0), TOAST_Root => 12, Layer_Hint => 1, Status => HNSW_Stat);
   pragma Assert (HNSW_Stat = Status_Ok);

   Search_KNN (Graph_Idx, Make_Vector_3D (1.0, 0.0, 0.0), Encoding_Float32, K => 2, Results => KNN_Float_Res);
   pragma Assert (KNN_Float_Res.Count = 2 and then KNN_Float_Res.Items (1).Doc_Id = 1);

   Search_KNN (Graph_Idx, Make_Vector_3D (1.0, 0.0, 0.0), Encoding_Int8_SQ8, K => 2, Results => KNN_Int8_Res);
   pragma Assert (KNN_Int8_Res.Count = 2 and then KNN_Int8_Res.Items (1).Doc_Id = 1);

   Search_KNN (Graph_Idx, Make_Vector_3D (1.0, 0.0, 0.0), Encoding_Binary_1Bit, K => 2, Results => KNN_Bin_Res);
   pragma Assert (KNN_Bin_Res.Count = 2 and then KNN_Bin_Res.Items (1).Doc_Id in 1 .. 2);
   Print_Line ("  => Passed: Multi-layer HNSW ANN search verified across Float32, Int8, and Binary modes.");

   --  8. Verify Redis-Compatible Key-Value Cache & TTL Expiration
   Print_Line ("[8/10] Verifying Redis-Compatible Key-Value Cache & TTL (Nhe_O.KV)...");
   Set (Cache, Make_Ident ("session:42"), Make_Text ("user_long"), Now => 1000, Has_TTL => True, TTL_Sec => 60);
   pragma Assert (Exists (Cache, Make_Ident ("session:42"), Now => 1030));
   pragma Assert (Remaining_TTL (Cache, Make_Ident ("session:42"), Now => 1030) = 30);

   Get (Cache, Make_Ident ("session:42"), Now => 1030, Val => KV_Val, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Equal_Text (KV_Val, Make_Text ("user_long")));

   Get (Cache, Make_Ident ("session:42"), Now => 1061, Val => KV_Val, Status => KV_Status);
   pragma Assert (KV_Status = Status_Expired);
   pragma Assert (not Exists (Cache, Make_Ident ("session:42"), Now => 1061));

   Incr_By (Cache, Make_Ident ("metrics:hits"), 5, Now => 1062, New_Val => Counter_V, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Counter_V = 5);
   Incr_By (Cache, Make_Ident ("metrics:hits"), 10, Now => 1063, New_Val => Counter_V, Status => KV_Status);
   pragma Assert (KV_Status = Status_Ok and then Counter_V = 15);
   Del (Cache, Make_Ident ("metrics:hits"), KV_Removed);
   pragma Assert (KV_Removed);
   Print_Line ("  => Passed: Redis SETEX, GET, DEL, TTL lazy expiration, and atomic INCRBY verified.");

   --  9. Verify Dual-Mode Pub/Sub & WAL Commit Barrier (`ADR-004` / `BR-005`)
   Print_Line ("[9/10] Verifying Dual-Mode Pub/Sub & WAL Commit Barrier (Nhe_O.PubSub)...");
   Subscribe (Broker, Make_Ident ("cache.invalidation"), Sub_Exact, Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok);
   Subscribe (Broker, Make_Ident ("cache.*"), Sub_Wild, Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok);
   Subscribe (Broker, Make_Ident ("rag.*"), Sub_Durable, Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok);

   --  Mode 1: Immediate Redis-style Publish
   Publish (Broker, Make_Ident ("cache.invalidation"), Make_Text ("key=session:42"), Deliv_Cnt);
   pragma Assert (Deliv_Cnt = 2);
   Poll_Message (Broker, Sub_Exact, Msg_Out, Msg_Found);
   pragma Assert (Msg_Found and then Equal_Text (Msg_Out.Payload, Make_Text ("key=session:42")));
   Poll_Message (Broker, Sub_Wild, Msg_Out, Msg_Found);
   pragma Assert (Msg_Found);

   --  Mode 2a: Durable NOTIFY on Rolled-Back Transaction MUST NOT deliver!
   Begin_Tx (Next_Tx, Tx_Notify_1);
   Stage_Notify (Tx_Notify_1, Staging_Buf, Make_Ident ("rag.abort"), Make_Text ("phantom_doc"), Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok and then Staging_Buf.Count = 1);
   Poll_Message (Broker, Sub_Durable, Msg_Out, Msg_Found);
   pragma Assert (not Msg_Found); --  Blocked by WAL Commit Barrier!
   Rollback_Tx (Tx_Notify_1);
   Discard_Staged_Notifications (Tx_Notify_1, Staging_Buf);
   pragma Assert (Staging_Buf.Count = 0);
   Poll_Message (Broker, Sub_Durable, Msg_Out, Msg_Found);
   pragma Assert (not Msg_Found); --  Never delivered!

   --  Mode 2b: Durable NOTIFY on Committed Transaction delivers after WAL flush!
   Begin_Tx (Next_Tx, Tx_Notify_2);
   Stage_Notify (Tx_Notify_2, Staging_Buf, Make_Ident ("rag.commit"), Make_Text ("doc_id=1"), Sub_Stat);
   pragma Assert (Sub_Stat = Status_Ok);
   Commit_Tx (Tx_Notify_2, DB_File, WAL_File, 0, Page_Out, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok and then Tx_Notify_2.State = Tx_Committed);
   Flush_Committed_Notifications (Tx_Notify_2, Staging_Buf, Broker, Total_Deliv);
   pragma Assert (Total_Deliv = 1 and then Staging_Buf.Count = 0);
   Poll_Message (Broker, Sub_Durable, Msg_Out, Msg_Found);
   pragma Assert (Msg_Found and then Equal_Text (Msg_Out.Payload, Make_Text ("doc_id=1")));
   Print_Line ("  => Passed: Immediate PUBLISH and WAL-Commit-Gated DURABLE NOTIFY verified.");

   --  10. Verify Universal Local LLM RAG & Hybrid SQL Query Executor (`Nhe_O.RAG`)
   Print_Line ("[10/10] Verifying Universal Local LLM RAG & Hybrid SQL Executor (Nhe_O.RAG)...");
   Init_RAG_Engine (RAG_Store, Dim => 3);
   Put_Field (Meta_Doc_1, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);
   Put_Field (Meta_Doc_1, Make_Ident ("model"), Make_Text ("qwen-3.8-35b-a3b"), JSONB_String, JSON_Stat);
   Put_Field (Meta_Doc_2, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);
   Put_Field (Meta_RAG_Query, Make_Ident ("lang"), Make_Text ("vi"), JSONB_String, JSON_Stat);

   Begin_Tx (Next_Tx, Tx_RAG);
   --  Ingest Doc 2 (Knowledge Graph neighbor)
   Ingest_Document
     (Engine         => RAG_Store,
      Ctx            => Tx_RAG,
      DB_Path        => DB_File,
      WAL_Path       => WAL_File,
      Staging        => RAG_Staging,
      Doc_Id         => 2,
      Metadata       => Meta_Doc_2,
      Summary_Text   => Make_Text ("SPARK formal verification contracts"),
      Embedding      => Make_Vector_3D (0.7, 0.7, 0.0),
      Parent_Payload => Parent_Chunk_2,
      Parent_Length  => 4_200,
      Related_Doc_Id => 0,
      Layer_Hint     => 1,
      Status         => RAG_Status);
   pragma Assert (RAG_Status = Status_Ok);

   --  Ingest Doc 1 (Primary Qwen 3.8 RAG chunk, linked to Doc 2 via GraphRAG edge, 6000B TOAST chunk)
   Ingest_Document
     (Engine         => RAG_Store,
      Ctx            => Tx_RAG,
      DB_Path        => DB_File,
      WAL_Path       => WAL_File,
      Staging        => RAG_Staging,
      Doc_Id         => 1,
      Metadata       => Meta_Doc_1,
      Summary_Text   => Make_Text ("Qwen 3.8 35B A3B local LLM hybrid RAG guide"),
      Embedding      => Make_Vector_3D (1.0, 0.0, 0.0),
      Parent_Payload => Parent_Chunk_1,
      Parent_Length  => 6_000,
      Related_Doc_Id => 2,
      Layer_Hint     => 3,
      Status         => RAG_Status);
   pragma Assert (RAG_Status = Status_Ok and then RAG_Staging.Count = 2);

   Commit_Tx (Tx_RAG, DB_File, WAL_File, 0, Page_Out, Tx_Status);
   pragma Assert (Tx_Status = Status_Ok);
   Flush_Committed_Notifications (Tx_RAG, RAG_Staging, Broker, Total_Deliv);
   pragma Assert (Total_Deliv = 2);

   --  Execute Hybrid SQL + JSONB (`@>`) + Keyword ("Qwen") + HNSW + TOAST Parent Fetch + GraphRAG
   Execute_Hybrid_RAG_Query
     (Engine            => RAG_Store,
      Snapshot          => Tx_RAG.Id,
      DB_Path           => DB_File,
      SQL_Query         => SQL_Query,
      Query_Vec         => Make_Vector_3D (0.95, 0.05, 0.0),
      Encoding          => Encoding_Float32,
      Use_Meta_Filter   => True,
      Filter_Meta       => Meta_RAG_Query,
      Use_Keyword_Boost => True,
      Keyword           => Make_Text ("Qwen"),
      Top_K             => 2,
      Result            => RAG_Res,
      Top_Parent_Chunk  => Fetched_Chunk,
      Status            => RAG_Status);
   pragma Assert (RAG_Status = Status_Ok);
   pragma Assert (RAG_Res.Count = 2);
   pragma Assert (RAG_Res.Hits (1).Doc_Id = 1);
   pragma Assert (RAG_Res.Hits (1).Keyword_Match);
   pragma Assert (RAG_Res.Top_Parent_Bytes = 6_000);
   pragma Assert (RAG_Res.Graph_Neighbor_Hit);
   pragma Assert (Fetched_Chunk (1) = Character'Pos ('Q') and then Fetched_Chunk (5000) = Character'Pos ('!'));

   Unsubscribe (Broker, Sub_Exact);
   Unsubscribe (Broker, Sub_Wild);
   Unsubscribe (Broker, Sub_Durable);
   Delete_File_If_Exists (DB_File);
   Delete_File_If_Exists (WAL_File);
   Print_Line ("  => Passed: Hybrid SQL + JSONB `@>` + Lexical + HNSW + 6KB TOAST Chunk + GraphRAG verified.");

   Print_Blank_Line;
   Print_Line ("ALL 10 Nhe_O SPARK/Ada Verification Suites (Epic 01 & Epic 02) Passed Successfully.");
end Nhe_O_Main;
