pragma SPARK_Mode (On);

package body Nhe_O.HNSW is

   procedure Init_HNSW
     (Index :    out HNSW_Index;
      Dim   : in     Vector_Dim)
   is
   begin
      Index := (
         Dim        => Dim,
         Node_Count => 0,
         Entry_Node => 1,
         Top_Layer  => 1,
         Nodes      => [others => (others => <>)]
      );
   end Init_HNSW;

   function Node_Distance
     (Node     : HNSW_Node;
      Q_Float  : Vector_Value;
      Q_Int8   : Quantized_Int8_Vector;
      Q_Binary : Quantized_Binary_Vector;
      Encoding : Vector_Encoding_Kind) return Non_Negative_Float
   is
      Sum_F  : Non_Negative_Float := 0.0;
      Diff_F : Float;
      Sq_F   : Non_Negative_Float;
      Sum_I  : Natural := 0;
      Diff_I : Integer;
      Sq_I   : Natural;
      Ham    : Natural;
   begin
      case Encoding is
         when Encoding_Binary_1Bit =>
            Ham := Hamming_Distance (Node.Bin_Vec, Q_Binary);
            return Non_Negative_Float (Float (Ham));

         when Encoding_Int8_SQ8 =>
            for I in 1 .. Node.Prefix_Len loop
               pragma Loop_Invariant (Sum_I <= (I - 1) * 64_516);
               if I <= Q_Int8.Dim then
                  Diff_I := Integer (Node.Int8_Pref (I)) - Integer (Q_Int8.Elements (I));
                  Sq_I   := Diff_I * Diff_I;
                  Sum_I  := Sum_I + Sq_I;
               end if;
            end loop;
            return Non_Negative_Float (Float (Sum_I));

         when Encoding_Float32 =>
            for I in 1 .. Node.Prefix_Len loop
               pragma Loop_Invariant (Sum_F >= 0.0);
               if I <= Q_Float.Dim then
                  Diff_F := Node.Float_Pref (I) - Q_Float.Elements (I);
                  Sq_F   := Diff_F * Diff_F;
                  if Sum_F <= Float'Last - Sq_F then
                     Sum_F := Sum_F + Sq_F;
                  else
                     Sum_F := Float'Last;
                  end if;
               end if;
            end loop;
            return Sum_F;
      end case;
   end Node_Distance;

   procedure Add_Directed_Edge
     (Adj    : in out Layer_Adjacency;
      Target : in     HNSW_Node_Id)
   is
   begin
      for I in 1 .. Adj.Degree loop
         if Adj.Neighbors (I) = Target then
            return;
         end if;
      end loop;

      if Adj.Degree < Max_Neighbors then
         Adj.Degree := Adj.Degree + 1;
         Adj.Neighbors (Adj.Degree) := Target;
      else
         --  Replace last neighbor slot if full
         Adj.Neighbors (Max_Neighbors) := Target;
      end if;
   end Add_Directed_Edge;

   procedure Insert_Vector
     (Index      : in out HNSW_Index;
      Doc_Id     : in     Positive;
      Vec        : in     Vector_Value;
      TOAST_Root : in     Valid_Page_Id;
      Layer_Hint : in     HNSW_Layer;
      Status     :    out Engine_Status)
   is
      New_Id   : HNSW_Node_Id;
      Q_Int8   : constant Quantized_Int8_Vector   := Quantize_To_Int8 (Vec);
      Q_Bin    : constant Quantized_Binary_Vector := Quantize_To_Binary (Vec);
      Pref_Len : Matryoshka_Index;
      Best_Id  : HNSW_Node_Id := 1;
      Best_Dst : Non_Negative_Float := Float'Last;
      Cand_Dst : Non_Negative_Float;
   begin
      if Index.Node_Count = Max_HNSW_Nodes then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      New_Id := Index.Node_Count + 1;
      if Vec.Dim <= Matryoshka_Dim then
         Pref_Len := Matryoshka_Index (Vec.Dim);
      else
         Pref_Len := Matryoshka_Dim;
      end if;

      Index.Nodes (New_Id) := (
         Active     => True,
         Doc_Id     => Doc_Id,
         TOAST_Root => TOAST_Root,
         Top_Level  => Layer_Hint,
         Prefix_Len => Pref_Len,
         Float_Pref => [others => 0.0],
         Int8_Pref  => [others => 0],
         Bin_Vec    => Q_Bin,
         Layers     => [others => (others => <>)]
      );

      for I in 1 .. Pref_Len loop
         Index.Nodes (New_Id).Float_Pref (I) := Vec.Elements (I);
         Index.Nodes (New_Id).Int8_Pref (I)  := Q_Int8.Elements (I);
      end loop;

      --  Connect bidirectional edges on layers 1 .. Layer_Hint
      if Index.Node_Count > 0 then
         for L in 1 .. Layer_Hint loop
            Best_Id  := 1;
            Best_Dst := Float'Last;

            for Existing_Id in 1 .. Index.Node_Count loop
               if Index.Nodes (Existing_Id).Active
                 and then Index.Nodes (Existing_Id).Top_Level >= L
                 and then Index.Nodes (Existing_Id).Bin_Vec.Dim = Vec.Dim
               then
                  Cand_Dst :=
                    Node_Distance
                      (Index.Nodes (Existing_Id), Vec, Q_Int8, Q_Bin, Encoding_Float32);
                  if Cand_Dst < Best_Dst then
                     Best_Dst := Cand_Dst;
                     Best_Id  := Existing_Id;
                  end if;

                  if Index.Nodes (New_Id).Layers (L).Degree < Max_Neighbors then
                     Add_Directed_Edge (Index.Nodes (New_Id).Layers (L), Existing_Id);
                     Add_Directed_Edge (Index.Nodes (Existing_Id).Layers (L), New_Id);
                  end if;
               end if;
            end loop;

            --  Ensure at least the closest neighbor on layer L is linked
            if Index.Nodes (Best_Id).Active then
               Add_Directed_Edge (Index.Nodes (New_Id).Layers (L), Best_Id);
               Add_Directed_Edge (Index.Nodes (Best_Id).Layers (L), New_Id);
            end if;
         end loop;
      end if;

      Index.Node_Count := New_Id;
      if Index.Node_Count = 1 or else Layer_Hint > Index.Top_Layer then
         Index.Entry_Node := New_Id;
         Index.Top_Layer  := Layer_Hint;
      end if;

      Status := Status_Ok;
   end Insert_Vector;

   --  Insert a candidate into Results in sorted ascending distance order
   procedure Insert_Candidate_Sorted
     (Results : in out HNSW_Search_Result;
      Max_K   : in     KNN_Result_Index;
      Cand    : in     HNSW_Candidate)
     with Pre  => Results.Count <= Max_K,
          Post => Results.Count <= Max_K
   is
      Pos : KNN_Result_Index := 1;
   begin
      --  Avoid duplicate Node_Id
      for I in 1 .. Results.Count loop
         if Results.Items (I).Node_Id = Cand.Node_Id then
            return;
         end if;
      end loop;

      if Results.Count = Max_K
        and then Cand.Distance >= Results.Items (Results.Count).Distance
      then
         return;
      end if;

      if Results.Count < Max_K then
         Results.Count := Results.Count + 1;
      end if;

      Pos := Results.Count;
      for I in 1 .. Results.Count - 1 loop
         if Cand.Distance < Results.Items (I).Distance then
            Pos := I;
            exit;
         end if;
      end loop;

      for I in reverse Pos .. Results.Count - 1 loop
         pragma Loop_Invariant (Results.Count <= Max_K);
         Results.Items (I + 1) := Results.Items (I);
      end loop;

      Results.Items (Pos) := Cand;
   end Insert_Candidate_Sorted;

   procedure Search_KNN
     (Index    : in     HNSW_Index;
      Query    : in     Vector_Value;
      Encoding : in     Vector_Encoding_Kind;
      K        : in     KNN_Result_Index;
      Results  :    out HNSW_Search_Result)
   is
      type Visited_Array is array (HNSW_Node_Id) of Boolean;
      Visited   : Visited_Array := [others => False];
      Q_Int8    : constant Quantized_Int8_Vector   := Quantize_To_Int8 (Query);
      Q_Binary  : constant Quantized_Binary_Vector := Quantize_To_Binary (Query);
      Cur_Node  : HNSW_Node_Id;
      Cur_Dist  : Non_Negative_Float;
      Nbr_Id    : HNSW_Node_Id;
      Nbr_Dist  : Non_Negative_Float;
      Improved  : Boolean;
      Bound_K   : KNN_Result_Index;
   begin
      Results := (
         Count         => 0,
         Visited_Nodes => 0,
         Items         => [others => (others => <>)]
      );

      if Index.Node_Count = 0 then
         return;
      end if;

      if K <= Index.Node_Count then
         Bound_K := K;
      else
         Bound_K := Index.Node_Count;
      end if;

      if Index.Entry_Node <= Index.Node_Count then
         Cur_Node := Index.Entry_Node;
      else
         Cur_Node := 1;
      end if;

      if Index.Nodes (Cur_Node).Bin_Vec.Dim /= Query.Dim then
         return;
      end if;

      Cur_Dist :=
        Node_Distance (Index.Nodes (Cur_Node), Query, Q_Int8, Q_Binary, Encoding);

      --  Phase 1: Upper-layer greedy routing (Top_Layer down to layer 2)
      if Index.Top_Layer >= 2 then
         for L in reverse 2 .. Index.Top_Layer loop
            for Hop in 1 .. Max_HNSW_Nodes loop
               Improved := False;
               for N_Idx in 1 .. Index.Nodes (Cur_Node).Layers (L).Degree loop
                  Nbr_Id := Index.Nodes (Cur_Node).Layers (L).Neighbors (N_Idx);
                  if Nbr_Id in 1 .. Index.Node_Count
                    and then Index.Nodes (Nbr_Id).Active
                    and then Index.Nodes (Nbr_Id).Bin_Vec.Dim = Query.Dim
                  then
                     Nbr_Dist :=
                       Node_Distance
                         (Index.Nodes (Nbr_Id), Query, Q_Int8, Q_Binary, Encoding);
                     if Nbr_Dist < Cur_Dist then
                        Cur_Dist := Nbr_Dist;
                        Cur_Node := Nbr_Id;
                        Improved := True;
                     end if;
                  end if;
               end loop;
               exit when not Improved;
            end loop;
         end loop;
      end if;

      --  Phase 2: Layer-1 neighborhood expansion starting from Cur_Node
      Visited (Cur_Node) := True;
      Results.Visited_Nodes := 1;
      Insert_Candidate_Sorted
        (Results,
         Bound_K,
         (Node_Id    => Cur_Node,
          Doc_Id     => Index.Nodes (Cur_Node).Doc_Id,
          TOAST_Root => Index.Nodes (Cur_Node).TOAST_Root,
          Distance   => Cur_Dist));

      --  Expand 2 hops of small-world neighbors on Layer 1
      for Wave in 1 .. 2 loop
         for N_Id in 1 .. Index.Node_Count loop
            pragma Loop_Invariant (Results.Count <= Bound_K);
            if Visited (N_Id) and then Index.Nodes (N_Id).Active then
               for Edge_Idx in 1 .. Index.Nodes (N_Id).Layers (1).Degree loop
                  pragma Loop_Invariant (Results.Count <= Bound_K);
                  Nbr_Id := Index.Nodes (N_Id).Layers (1).Neighbors (Edge_Idx);
                  if Nbr_Id in 1 .. Index.Node_Count
                    and then not Visited (Nbr_Id)
                    and then Index.Nodes (Nbr_Id).Active
                    and then Index.Nodes (Nbr_Id).Bin_Vec.Dim = Query.Dim
                  then
                     Visited (Nbr_Id) := True;
                     if Results.Visited_Nodes < Natural'Last then
                        Results.Visited_Nodes := Results.Visited_Nodes + 1;
                     end if;
                     Nbr_Dist :=
                       Node_Distance
                         (Index.Nodes (Nbr_Id), Query, Q_Int8, Q_Binary, Encoding);
                     Insert_Candidate_Sorted
                       (Results,
                        Bound_K,
                        (Node_Id    => Nbr_Id,
                         Doc_Id     => Index.Nodes (Nbr_Id).Doc_Id,
                         TOAST_Root => Index.Nodes (Nbr_Id).TOAST_Root,
                         Distance   => Nbr_Dist));
                  end if;
               end loop;
            end if;
         end loop;
      end loop;

      --  Ensure we fill up to Bound_K if any unvisited component remains
      if Results.Count < Bound_K then
         for N_Id in 1 .. Index.Node_Count loop
            pragma Loop_Invariant (Results.Count <= Bound_K);
            if not Visited (N_Id)
              and then Index.Nodes (N_Id).Active
              and then Index.Nodes (N_Id).Bin_Vec.Dim = Query.Dim
            then
               Visited (N_Id) := True;
               if Results.Visited_Nodes < Natural'Last then
                  Results.Visited_Nodes := Results.Visited_Nodes + 1;
               end if;
               Nbr_Dist :=
                 Node_Distance
                   (Index.Nodes (N_Id), Query, Q_Int8, Q_Binary, Encoding);
               Insert_Candidate_Sorted
                 (Results,
                  Bound_K,
                  (Node_Id    => N_Id,
                   Doc_Id     => Index.Nodes (N_Id).Doc_Id,
                   TOAST_Root => Index.Nodes (N_Id).TOAST_Root,
                   Distance   => Nbr_Dist));
            end if;
         end loop;
      end if;
   end Search_KNN;

end Nhe_O.HNSW;
