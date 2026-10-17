pragma SPARK_Mode (On);

with Interfaces; use Interfaces;
with Nhe_O.SQL;  use Nhe_O.SQL;

package body Nhe_O.RAG is

   procedure Init_RAG_Engine
     (Engine :    out RAG_Engine;
      Dim    : in     Vector_Dim)
   is
   begin
      Engine.Dim           := Dim;
      Engine.Doc_Count     := 0;
      Engine.Next_TOAST_Pg := 10;
      Engine.Docs          := [others => (others => <>)];
      Init_BTree (Engine.PK_Tree);
      Init_HNSW (Engine.Vector_Graph, Dim);
   end Init_RAG_Engine;

   function Contains_Keyword
     (Text    : Bounded_Text;
      Keyword : Bounded_Text) return Boolean
   is
      Match : Boolean;
   begin
      if Keyword.Length = 0 then
         return True;
      end if;
      if Text.Length < Keyword.Length then
         return False;
      end if;

      for Start_Pos in 1 .. Text.Length - Keyword.Length + 1 loop
         Match := True;
         for Offset in 1 .. Keyword.Length loop
            if To_Lower_Char (Text.Data (Start_Pos + Offset - 1)) /=
               To_Lower_Char (Keyword.Data (Offset))
            then
               Match := False;
               exit;
            end if;
         end loop;
         if Match then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Keyword;

   procedure Ingest_Document
     (Engine         : in out RAG_Engine;
      Ctx            : in     Transaction_Context;
      DB_Path        : in     Bounded_Text;
      WAL_Path       : in     Bounded_Text;
      Staging        : in out Tx_Notification_Buffer;
      Doc_Id         : in     RAG_Doc_Slot;
      Metadata       : in     JSONB_Document;
      Summary_Text   : in     Bounded_Text;
      Embedding      : in     Vector_Value;
      Parent_Payload : in     TOAST_Payload_Buffer;
      Parent_Length  : in     Valid_TOAST_Length;
      Related_Doc_Id : in     Optional_Doc_Id;
      Layer_Hint     : in     HNSW_Layer;
      Status         :    out Engine_Status)
   is
      Ptr       : TOAST_Pointer;
      Sub_Stat  : Engine_Status;
      Notify_Ch : constant Bounded_Ident := Make_Ident ("rag.indexed");
   begin
      if Engine.Vector_Graph.Node_Count = Max_HNSW_Nodes then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      --  1. Persist parent chunk / oversized vector into 4KB TOAST overflow chain
      Write_TOAST_Chain
        (Ctx           => Ctx,
         DB_Path       => DB_Path,
         WAL_Path      => WAL_Path,
         Start_Page_Id => Engine.Next_TOAST_Pg,
         Payload       => Parent_Payload,
         Length        => Parent_Length,
         Ptr           => Ptr,
         Status        => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Status := Sub_Stat;
         return;
      end if;

      if Engine.Next_TOAST_Pg <= Max_Page_Id - Ptr.Chunk_Count then
         Engine.Next_TOAST_Pg := Engine.Next_TOAST_Pg + Ptr.Chunk_Count;
      end if;

      --  2. Index primary key in multi-page B+Tree
      Insert_Key
        (Tree   => Engine.PK_Tree,
         Key    => Integer_64 (Doc_Id),
         Ptr    => (Target_Page => 1,
                    Target_Slot => Doc_Id,
                    TOAST_Root  => Ptr.Root_Overflow_Page),
         Status => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Status := Sub_Stat;
         return;
      end if;

      --  3. Index embedding in multi-layer quantized HNSW graph
      Insert_Vector
        (Index      => Engine.Vector_Graph,
         Doc_Id     => Doc_Id,
         Vec        => Embedding,
         TOAST_Root => Ptr.Root_Overflow_Page,
         Layer_Hint => Layer_Hint,
         Status     => Sub_Stat);
      if Sub_Stat /= Status_Ok then
         Status := Sub_Stat;
         return;
      end if;

      --  4. Store MVCC document entry
      if not Engine.Docs (Doc_Id).Active and then Engine.Doc_Count < Max_RAG_Docs then
         Engine.Doc_Count := Engine.Doc_Count + 1;
      end if;

      Engine.Docs (Doc_Id) := (
         Active         => True,
         Doc_Id         => Doc_Id,
         Tuple_Hdr      => (Xmin => Ctx.Id, Xmax => 0),
         Metadata       => Metadata,
         Summary_Text   => Summary_Text,
         Toast_Ptr      => Ptr,
         Related_Doc_Id => Related_Doc_Id
      );

      --  5. Stage DURABLE notification (held until WAL Commit Barrier in Commit_Tx)
      Stage_Notify
        (Ctx     => Ctx,
         Staging => Staging,
         Channel => Notify_Ch,
         Payload => Summary_Text,
         Status  => Sub_Stat);

      Status := Sub_Stat;
   end Ingest_Document;

   procedure Insert_Hit_Sorted
     (Result : in out RAG_Query_Result;
      Max_K  : in     RAG_Hit_Index;
      Hit    : in     RAG_Search_Hit)
     with Pre  => Result.Count <= Max_K,
          Post => Result.Count <= Max_K
   is
      Pos : RAG_Hit_Index := 1;
   begin
      if Result.Count = Max_K
        and then Hit.Distance >= Result.Hits (Result.Count).Distance
      then
         return;
      end if;

      if Result.Count < Max_K then
         Result.Count := Result.Count + 1;
      end if;

      Pos := Result.Count;
      for I in 1 .. Result.Count - 1 loop
         if Hit.Distance < Result.Hits (I).Distance then
            Pos := I;
            exit;
         end if;
      end loop;

      for I in reverse Pos .. Result.Count - 1 loop
         pragma Loop_Invariant (Result.Count <= Max_K);
         Result.Hits (I + 1) := Result.Hits (I);
      end loop;

      Result.Hits (Pos) := Hit;
   end Insert_Hit_Sorted;

   procedure Execute_Hybrid_RAG_Query
     (Engine            : in     RAG_Engine;
      Snapshot          : in     Valid_Tx_Id;
      DB_Path           : in     Bounded_Text;
      SQL_Query         : in     Bounded_Text;
      Query_Vec         : in     Vector_Value;
      Encoding          : in     Vector_Encoding_Kind;
      Use_Meta_Filter   : in     Boolean;
      Filter_Meta       : in     JSONB_Document;
      Use_Keyword_Boost : in     Boolean;
      Keyword           : in     Bounded_Text;
      Top_K             : in     RAG_Hit_Index;
      Result            :    out RAG_Query_Result;
      Top_Parent_Chunk  :    out TOAST_Payload_Buffer;
      Status            :    out Engine_Status)
   is
      SQL_Desc   : Parsed_SQL_Descriptor;
      SQL_Stat   : Engine_Status;
      KNN_Res    : HNSW_Search_Result;
      Doc_Id     : Positive;
      Meta_Ok    : Boolean;
      Kw_Hit     : Boolean;
      Adj_Dist   : Non_Negative_Float;
      Toast_Stat : Engine_Status;
      Toast_Len  : TOAST_Payload_Length;
      Rel_Id     : Optional_Doc_Id;
   begin
      Result           := (others => <>);
      Top_Parent_Chunk := [others => 0];

      --  1. Parse & validate PostgreSQL RAG SQL query
      Analyze_SQL (SQL_Query, SQL_Desc, SQL_Stat);
      if SQL_Stat /= Status_Ok or else SQL_Desc.Kind /= Stmt_Select then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      --  2. Stage 1: HNSW ANN candidate retrieval in requested quantization mode
      Search_KNN
        (Index    => Engine.Vector_Graph,
         Query    => Query_Vec,
         Encoding => Encoding,
         K        => Max_KNN_Results,
         Results  => KNN_Res);

      --  3. Stage 2: Apply MVCC Snapshot Visibility, JSONB `@>` Filter, & Hybrid Keyword Boost
      for I in 1 .. KNN_Res.Count loop
         pragma Loop_Invariant (Result.Count <= Top_K);
         Doc_Id := KNN_Res.Items (I).Doc_Id;
         if Doc_Id <= Max_RAG_Docs
           and then Engine.Docs (Doc_Id).Active
           and then Is_Tuple_Visible (Engine.Docs (Doc_Id).Tuple_Hdr, Snapshot)
         then
            if Use_Meta_Filter then
               Meta_Ok := Contains (Engine.Docs (Doc_Id).Metadata, Filter_Meta);
            else
               Meta_Ok := True;
            end if;

            if Meta_Ok then
               Kw_Hit   := Contains_Keyword (Engine.Docs (Doc_Id).Summary_Text, Keyword);
               Adj_Dist := KNN_Res.Items (I).Distance;
               --  Hybrid Lexical + Vector RRF/Score boost: reduce effective distance by 50% on keyword hit
               if Use_Keyword_Boost and then Kw_Hit then
                  Adj_Dist := Adj_Dist * 0.5;
               end if;

               Insert_Hit_Sorted
                 (Result => Result,
                  Max_K  => Top_K,
                  Hit    => (Doc_Id         => Doc_Id,
                             Distance       => Adj_Dist,
                             Keyword_Match  => Kw_Hit,
                             Toast_Ptr      => Engine.Docs (Doc_Id).Toast_Ptr,
                             Summary_Text   => Engine.Docs (Doc_Id).Summary_Text,
                             Related_Doc_Id => Engine.Docs (Doc_Id).Related_Doc_Id));
            end if;
         end if;
      end loop;

      --  4. Stage 3: Fetch full Parent-Document Chunk from 4KB TOAST Overflow Pages
      --     and check 1-hop GraphRAG neighbor for the #1 ranked hit
      if Result.Count > 0
        and then Result.Hits (1).Toast_Ptr.Total_Byte_Length in 1 .. Max_TOAST_Payload_Bytes
        and then Result.Hits (1).Toast_Ptr.Chunk_Count in 1 .. Max_TOAST_Chunks
      then
         Read_TOAST_Chain
           (DB_Path => DB_Path,
            Ptr     => Result.Hits (1).Toast_Ptr,
            Payload => Top_Parent_Chunk,
            Length  => Toast_Len,
            Status  => Toast_Stat);
         if Toast_Stat /= Status_Ok then
            Status := Toast_Stat;
            return;
         end if;
         Result.Top_Parent_Bytes := Toast_Len;

         Rel_Id := Result.Hits (1).Related_Doc_Id;
         if Rel_Id in RAG_Doc_Slot
           and then Engine.Docs (Rel_Id).Active
           and then Is_Tuple_Visible (Engine.Docs (Rel_Id).Tuple_Hdr, Snapshot)
         then
            Result.Graph_Neighbor_Hit := True;
         end if;
      end if;

      Status := Status_Ok;
   end Execute_Hybrid_RAG_Query;

end Nhe_O.RAG;
