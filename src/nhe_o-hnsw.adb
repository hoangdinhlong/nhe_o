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

   -------------------------------------------------------------------------
   --  Dequantize_Int8_Scalar (Safe per-component SQ8 reconstruction)
   -------------------------------------------------------------------------

   function Dequantize_Int8_Scalar
     (Comp  : Int8_Component;
      Scale : Non_Negative_Float) return Vector_Component
     with Global => null,
          Post   => Dequantize_Int8_Scalar'Result in -Max_Component .. Max_Component
   is
      Raw_Val  : Float;
      Abs_Elem : Float;
   begin
      if Comp = 0 or else Scale <= 0.0 then
         return 0.0;
      elsif Scale <= Max_Component / 127.0 then
         Raw_Val := Float (Comp) * Scale;
      else
         Abs_Elem := Float (abs Integer (Comp));
         if Scale >= Max_Component / Abs_Elem then
            return (if Comp > 0 then Max_Component else -Max_Component);
         else
            Raw_Val := Float (Comp) * Scale;
         end if;
      end if;

      if Raw_Val > Max_Component then
         return Max_Component;
      elsif Raw_Val < -Max_Component then
         return -Max_Component;
      else
         return Raw_Val;
      end if;
   end Dequantize_Int8_Scalar;

   -------------------------------------------------------------------------
   --  Node_Distance (Metric L2 / SQ8-Scaled L2 / Binary Hamming)
   -------------------------------------------------------------------------

   function Node_Distance
     (Node     : HNSW_Node;
      Q_Float  : Vector_Value;
      Q_Int8   : Quantized_Int8_Vector;
      Q_Binary : Quantized_Binary_Vector;
      Encoding : Vector_Encoding_Kind) return Non_Negative_Float
   is
      Max_Sq : constant Non_Negative_Float := 4.0 * Max_Component * Max_Component;
      Sum_F  : Non_Negative_Float := 0.0;
      Diff_F : Float range -2.0 * Max_Component .. 2.0 * Max_Component;
      Sq_F   : Non_Negative_Float range 0.0 .. Max_Sq;
      Node_C : Vector_Component;
      Query_C: Vector_Component;
      Ham    : Natural;
   begin
      case Encoding is
         when Encoding_Binary_1Bit =>
            Ham := Hamming_Distance (Node.Bin_Vec, Q_Binary);
            return Non_Negative_Float (Float (Ham));

         when Encoding_Int8_SQ8 =>
            for I in 1 .. Node.Prefix_Len loop
               pragma Loop_Invariant
                 (Sum_F <= Float (I - 1) * Max_Sq);
               if I <= Q_Int8.Dim then
                  Node_C  := Dequantize_Int8_Scalar (Node.Int8_Pref (I), Node.Int8_Scale);
                  Query_C := Dequantize_Int8_Scalar (Q_Int8.Elements (I), Q_Int8.Scale);
                  Diff_F  := Node_C - Query_C;
                  Sq_F    := Diff_F * Diff_F;
                  if Sq_F > Max_Sq then
                     Sq_F := Max_Sq;
                  end if;
                  Sum_F   := Sum_F + Sq_F;
                  if Sum_F > Float (I) * Max_Sq then
                     Sum_F := Float (I) * Max_Sq;
                  end if;
               end if;
            end loop;
            return Sqrt_Bounded (Sum_F);

         when Encoding_Float32 =>
            for I in 1 .. Node.Prefix_Len loop
               pragma Loop_Invariant
                 (Sum_F <= Float (I - 1) * Max_Sq);
               if I <= Q_Float.Dim then
                  Diff_F := Node.Float_Pref (I) - Q_Float.Elements (I);
                  Sq_F   := Diff_F * Diff_F;
                  if Sq_F > Max_Sq then
                     Sq_F := Max_Sq;
                  end if;
                  Sum_F  := Sum_F + Sq_F;
                  if Sum_F > Float (I) * Max_Sq then
                     Sum_F := Float (I) * Max_Sq;
                  end if;
               end if;
            end loop;
            return Sqrt_Bounded (Sum_F);
      end case;
   end Node_Distance;

   -------------------------------------------------------------------------
   --  Node_Pair_Distance & Distance-Pruned Edge Insertion
   -------------------------------------------------------------------------

   function Node_Pair_Distance
     (Index : HNSW_Index;
      A_Id  : HNSW_Node_Id;
      B_Id  : HNSW_Node_Id) return Non_Negative_Float
     with Global => null,
          Post   => Node_Pair_Distance'Result >= 0.0
   is
      Max_Sq : constant Non_Negative_Float := 4.0 * Max_Component * Max_Component;
      Len    : constant Matryoshka_Index :=
        Matryoshka_Index'Min
          (Index.Nodes (A_Id).Prefix_Len, Index.Nodes (B_Id).Prefix_Len);
      Sum_F  : Non_Negative_Float := 0.0;
      Diff_F : Float range -2.0 * Max_Component .. 2.0 * Max_Component;
      Sq_F   : Non_Negative_Float range 0.0 .. Max_Sq;
   begin
      for I in 1 .. Len loop
         pragma Loop_Invariant (Sum_F <= Float (I - 1) * Max_Sq);
         Diff_F := Index.Nodes (A_Id).Float_Pref (I) - Index.Nodes (B_Id).Float_Pref (I);
         Sq_F   := Diff_F * Diff_F;
         if Sq_F > Max_Sq then
            Sq_F := Max_Sq;
         end if;
         Sum_F  := Sum_F + Sq_F;
         if Sum_F > Float (I) * Max_Sq then
            Sum_F := Float (I) * Max_Sq;
         end if;
      end loop;
      return Sqrt_Bounded (Sum_F);
   end Node_Pair_Distance;

   --  Add a directed edge Src_Id -> Target on layer L, pruning only the farthest
   --  neighbor if Degree = Max_Neighbors and Target is closer.
   procedure Add_Edge_Pruned
     (Index  : in out HNSW_Index;
      L      : in     HNSW_Layer;
      Src_Id : in     HNSW_Node_Id;
      Target : in     HNSW_Node_Id;
      Force  : in     Boolean := False)
     with Post => Index.Dim = Index.Dim'Old
                  and then Index.Node_Count = Index.Node_Count'Old
                  and then Index.Entry_Node = Index.Entry_Node'Old
                  and then Index.Top_Layer = Index.Top_Layer'Old
   is
      Deg        : constant Neighbor_Count := Index.Nodes (Src_Id).Layers (L).Degree;
      Worst_Slot : Neighbor_Slot := 1;
      Worst_Dist : Non_Negative_Float := 0.0;
      Slot_Dist  : Non_Negative_Float;
      Cand_Dist  : Non_Negative_Float;
      Nbr_Id     : HNSW_Node_Id;
   begin
      if Src_Id = Target then
         return;
      end if;

      for I in 1 .. Deg loop
         if Index.Nodes (Src_Id).Layers (L).Neighbors (I) = Target then
            return;
         end if;
      end loop;

      for I in 1 .. Deg loop
         Nbr_Id := Index.Nodes (Src_Id).Layers (L).Neighbors (I);
         if not Index.Nodes (Nbr_Id).Active then
            Index.Nodes (Src_Id).Layers (L).Neighbors (I) := Target;
            return;
         end if;
      end loop;

      if Deg < Max_Neighbors then
         Index.Nodes (Src_Id).Layers (L).Degree := Deg + 1;
         Index.Nodes (Src_Id).Layers (L).Neighbors (Deg + 1) := Target;
      else
         for I in Neighbor_Slot loop
            Nbr_Id    := Index.Nodes (Src_Id).Layers (L).Neighbors (I);
            Slot_Dist := Node_Pair_Distance (Index, Src_Id, Nbr_Id);
            if I = 1 or else Slot_Dist > Worst_Dist then
               Worst_Dist := Slot_Dist;
               Worst_Slot := I;
            end if;
         end loop;

         Cand_Dist := Node_Pair_Distance (Index, Src_Id, Target);
         if Force or else Cand_Dist < Worst_Dist then
            Index.Nodes (Src_Id).Layers (L).Neighbors (Worst_Slot) := Target;
         end if;
      end if;
   end Add_Edge_Pruned;

   -------------------------------------------------------------------------
   --  Remove_Vector (Deactivate + Scrub Incoming Edges + Trim & Recompute)
   -------------------------------------------------------------------------

   procedure Remove_Vector
     (Index  : in out HNSW_Index;
      Doc_Id : in     Positive)
   is
      New_Neighbors : Neighbor_List;
      New_Deg       : Neighbor_Count;
      Nbr_Id        : HNSW_Node_Id;
      Found_Active  : Boolean := False;
      Best_Entry    : HNSW_Node_Id := 1;
      Best_Layer    : HNSW_Layer := 1;
   begin
      for I in 1 .. Index.Node_Count loop
         pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
         pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
         if Index.Nodes (I).Active and then Index.Nodes (I).Doc_Id = Doc_Id then
            Index.Nodes (I).Active := False;
            Index.Nodes (I).Layers := [others => (others => <>)];
         end if;
      end loop;

      --  Scrub incoming edges pointing to deactivated nodes across all layers
      for Src in 1 .. Index.Node_Count loop
         pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
         pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
         if Index.Nodes (Src).Active then
            for L in HNSW_Layer loop
               pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
               pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
               New_Neighbors := [others => 1];
               New_Deg       := 0;
               for E in 1 .. Index.Nodes (Src).Layers (L).Degree loop
                  pragma Loop_Invariant (New_Deg < E);
                  Nbr_Id := Index.Nodes (Src).Layers (L).Neighbors (E);
                  if Nbr_Id <= Index.Node_Count
                    and then Nbr_Id /= Src
                    and then Index.Nodes (Nbr_Id).Active
                  then
                     New_Deg                 := New_Deg + 1;
                     New_Neighbors (New_Deg) := Nbr_Id;
                  end if;
               end loop;
               Index.Nodes (Src).Layers (L).Degree    := New_Deg;
               Index.Nodes (Src).Layers (L).Neighbors := New_Neighbors;
            end loop;
         end if;
      end loop;

      --  Trim trailing deactivated node slots so Node_Count reflects live high-water mark
      while Index.Node_Count > 0
        and then not Index.Nodes (Index.Node_Count).Active
      loop
         pragma Loop_Variant (Decreases => Index.Node_Count);
         pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
         pragma Loop_Invariant (Index.Node_Count <= Index.Node_Count'Loop_Entry);
         Index.Node_Count := Index.Node_Count - 1;
      end loop;

      --  Recompute Entry_Node and Top_Layer from remaining active nodes
      for I in 1 .. Index.Node_Count loop
         pragma Loop_Invariant (Best_Entry in 1 .. Index.Node_Count);
         if Index.Nodes (I).Active then
            if not Found_Active or else Index.Nodes (I).Top_Level > Best_Layer then
               Found_Active := True;
               Best_Entry   := I;
               Best_Layer   := Index.Nodes (I).Top_Level;
            end if;
         end if;
      end loop;

      Index.Entry_Node := Best_Entry;
      Index.Top_Layer  := Best_Layer;
   end Remove_Vector;

   procedure Restore_Vector_Node
     (Index     : in out HNSW_Index;
      Doc_Id    : in     Positive;
      Node_Snap : in     HNSW_Node)
   is
      Target_Id       : HNSW_Node_Id := 1;
      Found_Existing  : Boolean := False;
      Reused_Inactive : Boolean := False;
      Best_Id         : HNSW_Node_Id;
      Best_Dst        : Non_Negative_Float;
      Cand_Dst        : Non_Negative_Float;
      Has_Peer        : Boolean;
      Existing_Lim    : HNSW_Node_Count;
      Found_Active    : Boolean := False;
      Best_Entry      : HNSW_Node_Id := 1;
      Best_Layer      : HNSW_Layer := 1;
   begin
      Remove_Vector (Index, Doc_Id);
      if not Node_Snap.Active then
         return;
      end if;

      for I in 1 .. Index.Node_Count loop
         if Index.Nodes (I).Active and then Index.Nodes (I).Doc_Id = Doc_Id then
            Target_Id      := I;
            Found_Existing := True;
            exit;
         end if;
      end loop;

      if not Found_Existing then
         for I in 1 .. Index.Node_Count loop
            if not Index.Nodes (I).Active then
               Target_Id       := I;
               Reused_Inactive := True;
               exit;
            end if;
         end loop;
      end if;

      if not Found_Existing and then not Reused_Inactive then
         if Index.Node_Count = Max_HNSW_Nodes then
            return;
         end if;
         Target_Id        := Index.Node_Count + 1;
         Index.Node_Count := Target_Id;
      end if;

      Index.Nodes (Target_Id) := (
         Active     => True,
         Doc_Id     => Doc_Id,
         TOAST_Root => Node_Snap.TOAST_Root,
         Top_Level  => Node_Snap.Top_Level,
         Prefix_Len => Node_Snap.Prefix_Len,
         Int8_Scale => Node_Snap.Int8_Scale,
         Float_Pref => Node_Snap.Float_Pref,
         Int8_Pref  => Node_Snap.Int8_Pref,
         Bin_Vec    => Node_Snap.Bin_Vec,
         Layers     => [others => (others => <>)]
      );

      Existing_Lim := Index.Node_Count;
      if Existing_Lim > 1 then
         for L in 1 .. Index.Nodes (Target_Id).Top_Level loop
            pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
            pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);

            Best_Id  := 1;
            Best_Dst := Float'Last;
            Has_Peer := False;

            for Existing_Id in 1 .. Existing_Lim loop
               pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
               pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);

               if Existing_Id /= Target_Id
                 and then Index.Nodes (Existing_Id).Active
                 and then Index.Nodes (Existing_Id).Top_Level >= L
                 and then Index.Nodes (Existing_Id).Bin_Vec.Dim = Index.Dim
               then
                  Cand_Dst := Node_Pair_Distance (Index, Target_Id, Existing_Id);
                  if not Has_Peer or else Cand_Dst < Best_Dst then
                     Best_Dst := Cand_Dst;
                     Best_Id  := Existing_Id;
                     Has_Peer := True;
                  end if;

                  Add_Edge_Pruned (Index, L, Target_Id, Existing_Id, Force => False);
                  Add_Edge_Pruned (Index, L, Existing_Id, Target_Id, Force => False);
               end if;
            end loop;

            if Has_Peer then
               Add_Edge_Pruned (Index, L, Target_Id, Best_Id, Force => True);
               Add_Edge_Pruned (Index, L, Best_Id, Target_Id, Force => True);
            end if;
         end loop;
      end if;

      for I in 1 .. Index.Node_Count loop
         pragma Loop_Invariant (Best_Entry in 1 .. Index.Node_Count);
         if Index.Nodes (I).Active then
            if not Found_Active or else Index.Nodes (I).Top_Level > Best_Layer then
               Found_Active := True;
               Best_Entry   := I;
               Best_Layer   := Index.Nodes (I).Top_Level;
            end if;
         end if;
      end loop;

      Index.Entry_Node := Best_Entry;
      Index.Top_Layer  := Best_Layer;
   end Restore_Vector_Node;

   -------------------------------------------------------------------------
   --  Insert_Vector (Doc_Id Deduplication + Closest-M Neighbor Selection)
   -------------------------------------------------------------------------

   procedure Insert_Vector
     (Index      : in out HNSW_Index;
      Doc_Id     : in     Positive;
      Vec        : in     Vector_Value;
      TOAST_Root : in     Valid_Page_Id;
      Layer_Hint : in     HNSW_Layer;
      Status     :    out Engine_Status)
   is
      Target_Id       : HNSW_Node_Id := 1;
      Found_Existing  : Boolean := False;
      Reused_Inactive : Boolean := False;
      Q_Int8          : constant Quantized_Int8_Vector   := Quantize_To_Int8 (Vec);
      Q_Bin           : constant Quantized_Binary_Vector := Quantize_To_Binary (Vec);
      Pref_Len        : Matryoshka_Index;
      New_Neighbors   : Neighbor_List;
      New_Deg         : Neighbor_Count;
      Nbr_Id          : HNSW_Node_Id;
      Best_Id         : HNSW_Node_Id;
      Best_Dst        : Non_Negative_Float;
      Cand_Dst        : Non_Negative_Float;
      Has_Peer        : Boolean;
      Existing_Lim    : HNSW_Node_Count;
      Best_Entry      : HNSW_Node_Id;
      Best_Layer      : HNSW_Layer;
   begin
      --  1. Check if Doc_Id already exists in Index; reuse its first active slot in-place
      --     and deactivate any duplicate slots without shrinking Node_Count
      for I in 1 .. Index.Node_Count loop
         pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
         pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
         pragma Loop_Invariant (if Found_Existing then Target_Id in 1 .. Index.Node_Count);
         if Index.Nodes (I).Active and then Index.Nodes (I).Doc_Id = Doc_Id then
            if not Found_Existing then
               Target_Id      := I;
               Found_Existing := True;
            else
               Index.Nodes (I).Active := False;
               Index.Nodes (I).Layers := [others => (others => <>)];
            end if;
         end if;
      end loop;

      --  2. Otherwise reuse any deactivated node slot before growing Node_Count
      if not Found_Existing then
         for I in 1 .. Index.Node_Count loop
            if not Index.Nodes (I).Active then
               Target_Id       := I;
               Reused_Inactive := True;
               exit;
            end if;
         end loop;
      end if;

      if not Found_Existing and then not Reused_Inactive then
         if Index.Node_Count = Max_HNSW_Nodes then
            Status := Status_Capacity_Exceeded;
            return;
         end if;
         Target_Id        := Index.Node_Count + 1;
         Index.Node_Count := Target_Id;
      end if;

      --  3. Scrub stale incoming edges to Target_Id (or deactivated slots) across all layers
      if Found_Existing or else Reused_Inactive then
         for Src in 1 .. Index.Node_Count loop
            pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
            pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
            if Src /= Target_Id and then Index.Nodes (Src).Active then
               for L in HNSW_Layer loop
                  pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
                  pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
                  New_Neighbors := [others => 1];
                  New_Deg       := 0;
                  for E in 1 .. Index.Nodes (Src).Layers (L).Degree loop
                     pragma Loop_Invariant (New_Deg < E);
                     Nbr_Id := Index.Nodes (Src).Layers (L).Neighbors (E);
                     if Nbr_Id <= Index.Node_Count
                       and then Nbr_Id /= Src
                       and then Nbr_Id /= Target_Id
                       and then Index.Nodes (Nbr_Id).Active
                     then
                        New_Deg                 := New_Deg + 1;
                        New_Neighbors (New_Deg) := Nbr_Id;
                     end if;
                  end loop;
                  Index.Nodes (Src).Layers (L).Degree    := New_Deg;
                  Index.Nodes (Src).Layers (L).Neighbors := New_Neighbors;
               end loop;
            end if;
         end loop;
      end if;

      if Vec.Dim <= Matryoshka_Dim then
         Pref_Len := Matryoshka_Index (Vec.Dim);
      else
         Pref_Len := Matryoshka_Dim;
      end if;

      Index.Nodes (Target_Id) := (
         Active     => True,
         Doc_Id     => Doc_Id,
         TOAST_Root => TOAST_Root,
         Top_Level  => Layer_Hint,
         Prefix_Len => Pref_Len,
         Int8_Scale => Q_Int8.Scale,
         Float_Pref => [others => 0.0],
         Int8_Pref  => [others => 0],
         Bin_Vec    => Q_Bin,
         Layers     => [others => (others => <>)]
      );

      for I in 1 .. Pref_Len loop
         pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
         pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);
         Index.Nodes (Target_Id).Float_Pref (I) := Vec.Elements (I);
         Index.Nodes (Target_Id).Int8_Pref (I)  := Q_Int8.Elements (I);
      end loop;

      Existing_Lim := Index.Node_Count;

      --  4. Connect distance-pruned bidirectional edges on layers 1 .. Layer_Hint
      if Existing_Lim > 1 then
         for L in 1 .. Index.Nodes (Target_Id).Top_Level loop
            pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
            pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);

            Best_Id  := 1;
            Best_Dst := Float'Last;
            Has_Peer := False;

            for Existing_Id in 1 .. Existing_Lim loop
               pragma Loop_Invariant (Index.Dim = Index.Dim'Loop_Entry);
               pragma Loop_Invariant (Index.Node_Count = Index.Node_Count'Loop_Entry);

               if Existing_Id /= Target_Id
                  and then Index.Nodes (Existing_Id).Active
                  and then Index.Nodes (Existing_Id).Top_Level >= L
                  and then Index.Nodes (Existing_Id).Bin_Vec.Dim = Vec.Dim
               then
                  Cand_Dst := Node_Pair_Distance (Index, Target_Id, Existing_Id);
                  if not Has_Peer or else Cand_Dst < Best_Dst then
                     Best_Dst := Cand_Dst;
                     Best_Id  := Existing_Id;
                     Has_Peer := True;
                  end if;

                  --  Select up to Max_Neighbors closest peers for Target_Id
                  Add_Edge_Pruned (Index, L, Target_Id, Existing_Id, Force => False);
                  --  Offer reverse edge from Existing_Id to Target_Id if within top-M
                  Add_Edge_Pruned (Index, L, Existing_Id, Target_Id, Force => False);
               end if;
            end loop;

            --  Guarantee that the single closest peer on layer L links back to Target_Id
            --  (replacing its farthest neighbor if full) so Target_Id is never orphaned.
            if Has_Peer then
               Add_Edge_Pruned (Index, L, Target_Id, Best_Id, Force => True);
               Add_Edge_Pruned (Index, L, Best_Id, Target_Id, Force => True);
            end if;
         end loop;
      end if;

      --  5. Recompute Entry_Node and Top_Layer across all active nodes
      Best_Entry := Target_Id;
      Best_Layer := Index.Nodes (Target_Id).Top_Level;
      for I in 1 .. Index.Node_Count loop
         pragma Loop_Invariant (Best_Entry in 1 .. Index.Node_Count);
         if Index.Nodes (I).Active and then Index.Nodes (I).Top_Level > Best_Layer then
            Best_Entry := I;
            Best_Layer := Index.Nodes (I).Top_Level;
         end if;
      end loop;

      Index.Entry_Node := Best_Entry;
      Index.Top_Layer  := Best_Layer;
      Status           := Status_Ok;
   end Insert_Vector;

   -------------------------------------------------------------------------
   --  Search_KNN (Upper-Layer Greedy Routing + Layer-1 Greedy & Beam Search)
   -------------------------------------------------------------------------

   procedure Insert_Candidate_Sorted
     (Results : in out HNSW_Search_Result;
      Max_K   : in     KNN_Result_Index;
      Cand    : in     HNSW_Candidate)
     with Pre  => Results.Count <= Max_K,
          Post => Results.Count <= Max_K
   is
      Pos : KNN_Result_Index;
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

      if Index.Entry_Node <= Index.Node_Count
        and then Index.Nodes (Index.Entry_Node).Active
      then
         Cur_Node := Index.Entry_Node;
      else
         Cur_Node := 1;
         for I in 1 .. Index.Node_Count loop
            if Index.Nodes (I).Active then
               Cur_Node := I;
               exit;
            end if;
         end loop;
         if not Index.Nodes (Cur_Node).Active then
            return;
         end if;
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

      --  Phase 2a: Layer-1 greedy descent to local minimum, recording visited nodes
      Visited (Cur_Node) := True;
      Results.Visited_Nodes := 1;
      Insert_Candidate_Sorted
        (Results,
         Bound_K,
         (Node_Id    => Cur_Node,
          Doc_Id     => Index.Nodes (Cur_Node).Doc_Id,
          TOAST_Root => Index.Nodes (Cur_Node).TOAST_Root,
          Distance   => Cur_Dist));

      for Hop in 1 .. Max_HNSW_Nodes loop
         pragma Loop_Invariant (Results.Count <= Bound_K);
         Improved := False;
         for N_Idx in 1 .. Index.Nodes (Cur_Node).Layers (1).Degree loop
            pragma Loop_Invariant (Results.Count <= Bound_K);
            Nbr_Id := Index.Nodes (Cur_Node).Layers (1).Neighbors (N_Idx);
            if Nbr_Id in 1 .. Index.Node_Count
              and then Index.Nodes (Nbr_Id).Active
              and then Index.Nodes (Nbr_Id).Bin_Vec.Dim = Query.Dim
            then
               Nbr_Dist :=
                 Node_Distance
                   (Index.Nodes (Nbr_Id), Query, Q_Int8, Q_Binary, Encoding);
               if not Visited (Nbr_Id) then
                  Visited (Nbr_Id) := True;
                  if Results.Visited_Nodes < Natural'Last then
                     Results.Visited_Nodes := Results.Visited_Nodes + 1;
                  end if;
                  Insert_Candidate_Sorted
                    (Results,
                     Bound_K,
                     (Node_Id    => Nbr_Id,
                      Doc_Id     => Index.Nodes (Nbr_Id).Doc_Id,
                      TOAST_Root => Index.Nodes (Nbr_Id).TOAST_Root,
                      Distance   => Nbr_Dist));
               end if;
               if Nbr_Dist < Cur_Dist then
                  Cur_Dist := Nbr_Dist;
                  Cur_Node := Nbr_Id;
                  Improved := True;
               end if;
            end if;
         end loop;
         exit when not Improved;
      end loop;

      --  Phase 2b: Multi-wave small-world beam expansion on Layer 1
      for Wave in 1 .. 4 loop
         pragma Loop_Invariant (Results.Count <= Bound_K);
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

      --  If any disconnected node remains and Results.Count < Bound_K, inspect it
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
