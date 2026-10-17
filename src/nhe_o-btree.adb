--  Formally verified Multi-Page B+Tree Index with Multi-Level Node Splitting
--  (CRIT-02, CRIT-03, MED-03)
pragma SPARK_Mode (On);

with Nhe_O.Transaction;

package body Nhe_O.BTree is

   Magic_B  : constant Byte        := 16#42#; --  'B'
   Magic_T  : constant Byte        := 16#54#; --  'T'
   Magic_R  : constant Byte        := 16#52#; --  'R'
   Magic_E  : constant Byte        := 16#45#; --  'E'
   Half_U64 : constant Unsigned_64 := 16#8000_0000_0000_0000#;

   -------------------------------------------------------------------------
   --  Bijective 64-bit Key <-> (Hi, Lo) Serialization Helpers (CRIT-03)
   -------------------------------------------------------------------------

   procedure Key_To_Words
     (K  : in     Integer_64;
      Hi :    out Unsigned_32;
      Lo :    out Unsigned_32)
   is
      U : Unsigned_64;
   begin
      if K >= 0 then
         U := Half_U64 + Unsigned_64 (K);
      else
         U := (Half_U64 - 1) - Unsigned_64 (-(K + 1));
      end if;
      Hi := Unsigned_32 (Shift_Right (U, 32));
      Lo := Unsigned_32 (U and 16#FFFF_FFFF#);
   end Key_To_Words;

   function Words_To_Key
     (Hi : Unsigned_32;
      Lo : Unsigned_32) return Integer_64
   is
      U : constant Unsigned_64 :=
        Shift_Left (Unsigned_64 (Hi), 32) or Unsigned_64 (Lo);
   begin
      if U >= Half_U64 then
         return Integer_64 (U - Half_U64);
      else
         return -1 - Integer_64 ((Half_U64 - 1) - U);
      end if;
   end Words_To_Key;

   -------------------------------------------------------------------------
   --  Init_BTree
   -------------------------------------------------------------------------

   procedure Init_BTree (Tree : out BTree_Index) is
   begin
      Tree := (
         Root_Node   => 1,
         Node_Count  => 1,
         Split_Count => 0,
         Total_Keys  => 0,
         Nodes       => [others => (others => <>)]
      );
      Tree.Nodes (1).Kind    := Node_Leaf;
      Tree.Nodes (1).Page_Id := 1;
   end Init_BTree;

   -------------------------------------------------------------------------
   --  Multi-Level Internal Node Routing (CRIT-02)
   -------------------------------------------------------------------------

   function Find_Child_Slot
     (Node : BTree_Node;
      Key  : Integer_64) return Child_Slot_Index
     with Pre  => Node.Kind = Node_Internal and then Node.Num_Keys > 0,
          Post => Find_Child_Slot'Result <= Node.Num_Keys + 1
   is
   begin
      for I in 1 .. Node.Num_Keys loop
         if Key < Node.Keys (I) then
            return I;
         end if;
      end loop;
      return Node.Num_Keys + 1;
   end Find_Child_Slot;

   function Route_To_Leaf
     (Tree : BTree_Index;
      Key  : Integer_64) return BTree_Node_Id
     with Pre  => Tree.Node_Count in 1 .. Max_BTree_Nodes
                  and then Tree.Root_Node in 1 .. Tree.Node_Count,
          Post => Route_To_Leaf'Result in 1 .. Tree.Node_Count
   is
      Cur_Id    : BTree_Node_Id := Tree.Root_Node;
      Next_Slot : Child_Slot_Index;
      Next_Id   : BTree_Node_Id;
   begin
      for Depth in 1 .. Max_BTree_Depth loop
         pragma Loop_Invariant (Cur_Id in 1 .. Tree.Node_Count);
         exit when Tree.Nodes (Cur_Id).Kind = Node_Leaf
           or else Tree.Nodes (Cur_Id).Num_Keys = 0;

         Next_Slot := Find_Child_Slot (Tree.Nodes (Cur_Id), Key);
         Next_Id   := Tree.Nodes (Cur_Id).Children (Next_Slot);

         if Next_Id <= Tree.Node_Count then
            Cur_Id := Next_Id;
         else
            exit;
         end if;
      end loop;

      return Cur_Id;
   end Route_To_Leaf;

   -------------------------------------------------------------------------
   --  Non-Full Node Insertion Helpers
   -------------------------------------------------------------------------

   procedure Insert_Into_Non_Full_Leaf
     (Node  : in out BTree_Node;
      Key   : in     Integer_64;
      Ptr   : in     BTree_Record_Pointer;
      Added :    out Boolean)
     with Pre  => Node.Kind = Node_Leaf
                  and then Node.Num_Keys < Max_Keys_Per_Node,
          Post => Node.Kind = Node_Leaf
                  and then Node.Num_Keys in Node.Num_Keys'Old .. Node.Num_Keys'Old + 1
   is
      Insert_Pos : Key_Slot_Index;
   begin
      for I in 1 .. Node.Num_Keys loop
         if Node.Keys (I) = Key then
            Node.Pointers (I) := Ptr;
            Added := False;
            return;
         end if;
      end loop;

      Insert_Pos := Node.Num_Keys + 1;
      for I in 1 .. Node.Num_Keys loop
         if Key < Node.Keys (I) then
            Insert_Pos := I;
            exit;
         end if;
      end loop;

      for I in reverse Insert_Pos .. Node.Num_Keys loop
         pragma Loop_Invariant (I in 1 .. Max_Keys_Per_Node - 1);
         Node.Keys (I + 1)     := Node.Keys (I);
         Node.Pointers (I + 1) := Node.Pointers (I);
      end loop;

      Node.Keys (Insert_Pos)     := Key;
      Node.Pointers (Insert_Pos) := Ptr;
      Node.Num_Keys              := Node.Num_Keys + 1;
      Added := True;
   end Insert_Into_Non_Full_Leaf;

   procedure Insert_Into_Non_Full_Internal
     (Node        : in out BTree_Node;
      Insert_Slot : in     Child_Slot_Index;
      Promo_Key   : in     Integer_64;
      Right_Child : in     BTree_Node_Id)
     with Pre  => Node.Kind = Node_Internal
                  and then Node.Num_Keys < Max_Keys_Per_Node
                  and then Insert_Slot <= Node.Num_Keys + 1,
          Post => Node.Kind = Node_Internal
                  and then Node.Num_Keys = Node.Num_Keys'Old + 1
   is
      Nk : constant Key_Slot_Count := Node.Num_Keys;
   begin
      for I in reverse Insert_Slot .. Nk loop
         pragma Loop_Invariant (I in 1 .. Max_Keys_Per_Node - 1);
         Node.Keys (I + 1)     := Node.Keys (I);
         Node.Children (I + 2) := Node.Children (I + 1);
      end loop;

      Node.Keys (Insert_Slot)         := Promo_Key;
      Node.Children (Insert_Slot + 1) := Right_Child;
      Node.Num_Keys                   := Nk + 1;
   end Insert_Into_Non_Full_Internal;

   -------------------------------------------------------------------------
   --  Insert_Key (Multi-Level Split Propagation & Root Promotion, CRIT-02)
   -------------------------------------------------------------------------

   procedure Insert_Key
     (Tree   : in out BTree_Index;
      Key    : in     Integer_64;
      Ptr    : in     BTree_Record_Pointer;
      Status :    out Engine_Status)
   is
      subtype Path_Index is Positive range 1 .. Max_BTree_Depth;
      type Path_Node_Array is array (Path_Index) of BTree_Node_Id;
      type Path_Slot_Array is array (Path_Index) of Child_Slot_Index;

      Path_Nodes : Path_Node_Array := [others => 1];
      Path_Slots : Path_Slot_Array := [others => 1];
      Path_Len   : Natural range 0 .. Max_BTree_Depth := 0;

      Cur_Id     : BTree_Node_Id := Tree.Root_Node;
      Next_Id    : BTree_Node_Id;
      Leaf_Node  : BTree_Node;
      Added      : Boolean;

      subtype Split_Key_Index is Positive range 1 .. Max_Keys_Per_Node + 1;
      subtype Split_Child_Index is Positive range 1 .. Max_Children_Per_Node + 1;

      Temp_Keys    : array (Split_Key_Index) of Integer_64 := [others => 0];
      Temp_Ptrs    : array (Split_Key_Index) of BTree_Record_Pointer :=
        [others => (others => <>)];
      ITemp_Keys   : array (Split_Key_Index) of Integer_64 := [others => 0];
      ITemp_Childs : array (Split_Child_Index) of BTree_Node_Id := [others => 1];

      Inserted     : Boolean := False;
      Write_Idx    : Split_Key_Index := 1;
      Needed_Nodes : Positive range 1 .. Max_BTree_Depth + 2;
      Root_Splits  : Boolean;

      Promo_Key    : Integer_64;
      Promo_Child  : BTree_Node_Id;
      Propagating  : Boolean;
      Right_Id     : BTree_Node_Id;
      New_Root_Id  : BTree_Node_Id;
   begin
      --  Step 1: Route from Root_Node down to target leaf, recording ancestor path.
      for Depth in Path_Index loop
         pragma Loop_Invariant (Cur_Id in 1 .. Tree.Node_Count);
         pragma Loop_Invariant (Path_Len = Depth - 1);
         pragma Loop_Invariant
           (for all P in 1 .. Path_Len => Path_Nodes (P) in 1 .. Tree.Node_Count);

         Path_Len           := Depth;
         Path_Nodes (Depth) := Cur_Id;

         if Tree.Nodes (Cur_Id).Kind = Node_Leaf then
            exit;
         elsif Tree.Nodes (Cur_Id).Num_Keys > 0 then
            Path_Slots (Depth) := Find_Child_Slot (Tree.Nodes (Cur_Id), Key);
            Next_Id            := Tree.Nodes (Cur_Id).Children (Path_Slots (Depth));
            if Next_Id <= Tree.Node_Count then
               Cur_Id := Next_Id;
            else
               Status := Status_Invalid_Syntax;
               return;
            end if;
         else
            Status := Status_Invalid_Syntax;
            return;
         end if;
      end loop;

      if Tree.Nodes (Cur_Id).Kind /= Node_Leaf then
         Status := Status_Invalid_Syntax;
         return;
      end if;

      Leaf_Node := Tree.Nodes (Cur_Id);

      --  Step 2: Update existing key in-place if present in leaf.
      for I in 1 .. Leaf_Node.Num_Keys loop
         if Leaf_Node.Keys (I) = Key then
            Tree.Nodes (Cur_Id).Pointers (I) := Ptr;
            Status := Status_Ok;
            return;
         end if;
      end loop;

      --  Step 3: If target leaf has spare capacity, insert directly.
      if Leaf_Node.Num_Keys < Max_Keys_Per_Node then
         Insert_Into_Non_Full_Leaf (Tree.Nodes (Cur_Id), Key, Ptr, Added);
         if Added and then Tree.Total_Keys < Natural'Last then
            Tree.Total_Keys := Tree.Total_Keys + 1;
         end if;
         Status := Status_Ok;
         return;
      end if;

      --  Step 4: Target leaf is full (4 keys). Compute exact number of new nodes
      --  required for bottom-up split propagation so capacity failure is atomic.
      Needed_Nodes := 1; --  1 right sibling leaf
      Root_Splits  := (Path_Len = 1);

      if Path_Len > 1 then
         Root_Splits := True;
         for Level in reverse 1 .. Path_Len - 1 loop
            pragma Loop_Invariant (Needed_Nodes <= (Path_Len - Level));
            if Tree.Nodes (Path_Nodes (Level)).Kind /= Node_Internal then
               Status := Status_Invalid_Syntax;
               return;
            end if;
            if Tree.Nodes (Path_Nodes (Level)).Num_Keys = Max_Keys_Per_Node then
               Needed_Nodes := Needed_Nodes + 1;
            else
               Root_Splits := False;
               exit;
            end if;
         end loop;
      end if;

      if Root_Splits then
         Needed_Nodes := Needed_Nodes + 1; --  1 new root internal node
      end if;

      if Tree.Node_Count + Needed_Nodes > Max_BTree_Nodes then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      Right_Id        := Tree.Node_Count + 1;
      Tree.Node_Count := Right_Id;

      --  Step 5: Merge 4 existing leaf keys + new key into Temp_Keys (1..5).
      for I in 1 .. Max_Keys_Per_Node loop
         pragma Loop_Invariant
           (if Inserted then Write_Idx = I + 1 else Write_Idx = I);
         if not Inserted and then Key < Leaf_Node.Keys (I) then
            Temp_Keys (Write_Idx) := Key;
            Temp_Ptrs (Write_Idx) := Ptr;
            Inserted              := True;
            Write_Idx             := Write_Idx + 1;
         end if;
         Temp_Keys (Write_Idx) := Leaf_Node.Keys (I);
         Temp_Ptrs (Write_Idx) := Leaf_Node.Pointers (I);
         if I < Max_Keys_Per_Node then
            Write_Idx := Write_Idx + 1;
         end if;
      end loop;

      if not Inserted then
         Temp_Keys (Max_Keys_Per_Node + 1) := Key;
         Temp_Ptrs (Max_Keys_Per_Node + 1) := Ptr;
      end if;

      --  Right sibling leaf receives keys 3..5 (3 keys)
      Tree.Nodes (Right_Id) := (
         Kind      => Node_Leaf,
         Page_Id   => Valid_Page_Id (Right_Id),
         Num_Keys  => 3,
         Keys      => [1 => Temp_Keys (3),
                       2 => Temp_Keys (4),
                       3 => Temp_Keys (5),
                       others => 0],
         Pointers  => [1 => Temp_Ptrs (3),
                       2 => Temp_Ptrs (4),
                       3 => Temp_Ptrs (5),
                       others => (others => <>)],
         Children  => [others => 1],
         Next_Leaf => Leaf_Node.Next_Leaf
      );

      --  Left leaf keeps keys 1..2 (2 keys) and links to Right_Id
      Tree.Nodes (Cur_Id) := (
         Kind      => Node_Leaf,
         Page_Id   => Leaf_Node.Page_Id,
         Num_Keys  => 2,
         Keys      => [1 => Temp_Keys (1),
                       2 => Temp_Keys (2),
                       others => 0],
         Pointers  => [1 => Temp_Ptrs (1),
                       2 => Temp_Ptrs (2),
                       others => (others => <>)],
         Children  => [others => 1],
         Next_Leaf => Right_Id
      );

      if Tree.Split_Count < Natural'Last then
         Tree.Split_Count := Tree.Split_Count + 1;
      end if;

      Promo_Key   := Temp_Keys (3);
      Promo_Child := Right_Id;
      Propagating := True;

      --  Step 6: Propagate promoted separator key bottom-up through ancestors.
      if Path_Len > 1 then
         for Level in reverse 1 .. Path_Len - 1 loop
            pragma Loop_Invariant (Tree.Node_Count in 1 .. Max_BTree_Nodes);
            pragma Loop_Invariant (Tree.Root_Node in 1 .. Tree.Node_Count);
            pragma Loop_Invariant
              (for all P in 1 .. Level => Path_Nodes (P) in 1 .. Tree.Node_Count);

            declare
               P_Id   : constant BTree_Node_Id    := Path_Nodes (Level);
               P_Slot : constant Child_Slot_Index := Path_Slots (Level);
               P_Node : BTree_Node                := Tree.Nodes (P_Id);
               R_Id   : BTree_Node_Id;
            begin
               if P_Node.Kind /= Node_Internal then
                  Status := Status_Invalid_Syntax;
                  return;
               end if;

               if P_Node.Num_Keys < Max_Keys_Per_Node
                 and then P_Slot <= P_Node.Num_Keys + 1
               then
                  Insert_Into_Non_Full_Internal
                    (Node        => P_Node,
                     Insert_Slot => P_Slot,
                     Promo_Key   => Promo_Key,
                     Right_Child => Promo_Child);
                  Tree.Nodes (P_Id) := P_Node;
                  Propagating       := False;
                  exit;
               elsif P_Node.Num_Keys = Max_Keys_Per_Node then
                  if Tree.Node_Count = Max_BTree_Nodes then
                     Status := Status_Capacity_Exceeded;
                     return;
                  end if;

                  --  Build 5 keys and 6 children in ITemp_Keys / ITemp_Childs
                  ITemp_Childs (1) := P_Node.Children (1);
                  for K in 1 .. Max_Keys_Per_Node loop
                     if K < P_Slot then
                        ITemp_Keys (K)       := P_Node.Keys (K);
                        ITemp_Childs (K + 1) := P_Node.Children (K + 1);
                     elsif K = P_Slot then
                        ITemp_Keys (K)       := Promo_Key;
                        ITemp_Childs (K + 1) := Promo_Child;
                     else
                        ITemp_Keys (K)       := P_Node.Keys (K - 1);
                        ITemp_Childs (K + 1) := P_Node.Children (K);
                     end if;
                  end loop;

                  if P_Slot = Max_Children_Per_Node then
                     ITemp_Keys (5)   := Promo_Key;
                     ITemp_Childs (6) := Promo_Child;
                  else
                     ITemp_Keys (5)   := P_Node.Keys (4);
                     ITemp_Childs (6) := P_Node.Children (5);
                  end if;

                  R_Id            := Tree.Node_Count + 1;
                  Tree.Node_Count := R_Id;

                  --  Left internal node keeps keys 1..2 and children 1..3
                  Tree.Nodes (P_Id) := (
                     Kind      => Node_Internal,
                     Page_Id   => P_Node.Page_Id,
                     Num_Keys  => 2,
                     Keys      => [1 => ITemp_Keys (1),
                                   2 => ITemp_Keys (2),
                                   others => 0],
                     Pointers  => [others => (others => <>)],
                     Children  => [1 => ITemp_Childs (1),
                                   2 => ITemp_Childs (2),
                                   3 => ITemp_Childs (3),
                                   others => 1],
                     Next_Leaf => 0
                  );

                  --  Right internal node receives keys 4..5 and children 4..6
                  Tree.Nodes (R_Id) := (
                     Kind      => Node_Internal,
                     Page_Id   => Valid_Page_Id (R_Id),
                     Num_Keys  => 2,
                     Keys      => [1 => ITemp_Keys (4),
                                   2 => ITemp_Keys (5),
                                   others => 0],
                     Pointers  => [others => (others => <>)],
                     Children  => [1 => ITemp_Childs (4),
                                   2 => ITemp_Childs (5),
                                   3 => ITemp_Childs (6),
                                   others => 1],
                     Next_Leaf => 0
                  );

                  if Tree.Split_Count < Natural'Last then
                     Tree.Split_Count := Tree.Split_Count + 1;
                  end if;

                  --  Middle key (ITemp_Keys (3)) is promoted up to parent
                  Promo_Key   := ITemp_Keys (3);
                  Promo_Child := R_Id;
               else
                  Status := Status_Invalid_Syntax;
                  return;
               end if;
            end;
         end loop;
      end if;

      --  Step 7: If split propagated above Root_Node, allocate a new root node.
      if Propagating then
         if Tree.Node_Count = Max_BTree_Nodes then
            Status := Status_Capacity_Exceeded;
            return;
         end if;

         New_Root_Id     := Tree.Node_Count + 1;
         Tree.Node_Count := New_Root_Id;

         Tree.Nodes (New_Root_Id) := (
            Kind      => Node_Internal,
            Page_Id   => Valid_Page_Id (New_Root_Id),
            Num_Keys  => 1,
            Keys      => [1 => Promo_Key, others => 0],
            Pointers  => [others => (others => <>)],
            Children  => [1 => Tree.Root_Node, 2 => Promo_Child, others => 1],
            Next_Leaf => 0
         );
         Tree.Root_Node := New_Root_Id;

         if Tree.Split_Count < Natural'Last then
            Tree.Split_Count := Tree.Split_Count + 1;
         end if;
      end if;

      if Tree.Total_Keys < Natural'Last then
         Tree.Total_Keys := Tree.Total_Keys + 1;
      end if;
      Status := Status_Ok;
   end Insert_Key;

   -------------------------------------------------------------------------
   --  Search_Key
   -------------------------------------------------------------------------

   procedure Search_Key
     (Tree  : in     BTree_Index;
      Key   : in     Integer_64;
      Found :    out Boolean;
      Ptr   :    out BTree_Record_Pointer)
   is
      Leaf_Id : constant BTree_Node_Id := Route_To_Leaf (Tree, Key);
      Leaf    : constant BTree_Node    := Tree.Nodes (Leaf_Id);
   begin
      Found := False;
      Ptr   := (others => <>);

      if Leaf.Kind /= Node_Leaf then
         return;
      end if;

      for I in 1 .. Leaf.Num_Keys loop
         if Leaf.Keys (I) = Key then
            Found := True;
            Ptr   := Leaf.Pointers (I);
            return;
         end if;
      end loop;
   end Search_Key;

   -------------------------------------------------------------------------
   --  Range_Scan (Leftmost-Leaf Descent + Leaf Chain Verification, CRIT-02)
   -------------------------------------------------------------------------

   procedure Range_Scan
     (Tree    : in     BTree_Index;
      Min_Key : in     Integer_64;
      Max_Key : in     Integer_64;
      Results :    out BTree_Scan_Result)
   is
      Start_Id : BTree_Node_Id := Tree.Root_Node;
      Child_Id : BTree_Node_Id;
      Cur_Node : Optional_Node_Id;
   begin
      Results := (Count => 0, Items => [others => (others => <>)]);

      --  Descend via leftmost child (Children (1)) from Root_Node to first leaf
      for Depth in 1 .. Max_BTree_Depth loop
         pragma Loop_Invariant (Start_Id in 1 .. Tree.Node_Count);
         exit when Tree.Nodes (Start_Id).Kind = Node_Leaf;
         Child_Id := Tree.Nodes (Start_Id).Children (1);
         if Child_Id <= Tree.Node_Count then
            Start_Id := Child_Id;
         else
            return;
         end if;
      end loop;

      if Tree.Nodes (Start_Id).Kind /= Node_Leaf then
         return;
      end if;

      Cur_Node := Start_Id;

      for Step in 1 .. Max_BTree_Nodes loop
         pragma Loop_Invariant (Results.Count <= Max_Scan_Results);
         exit when Cur_Node = 0 or else Cur_Node > Tree.Node_Count;
         exit when Tree.Nodes (Cur_Node).Kind /= Node_Leaf;

         for K_Idx in 1 .. Tree.Nodes (Cur_Node).Num_Keys loop
            pragma Loop_Invariant (Results.Count <= Max_Scan_Results);
            if Tree.Nodes (Cur_Node).Keys (K_Idx) >= Min_Key
              and then Tree.Nodes (Cur_Node).Keys (K_Idx) <= Max_Key
            then
               if Results.Count < Max_Scan_Results then
                  Results.Count := Results.Count + 1;
                  Results.Items (Results.Count) := (
                     Key => Tree.Nodes (Cur_Node).Keys (K_Idx),
                     Ptr => Tree.Nodes (Cur_Node).Pointers (K_Idx)
                  );
               end if;
            end if;
         end loop;

         Cur_Node := Tree.Nodes (Cur_Node).Next_Leaf;
      end loop;
   end Range_Scan;

   -------------------------------------------------------------------------
   --  Encode_Node_Page & Decode_Node_Page (Full 64-Bit Keys, Children, CRC32)
   -------------------------------------------------------------------------

   procedure Put_U32_BE
     (Page   : in out Page_Buffer;
      Offset : in     Page_Offset;
      Val    : in     Unsigned_32)
     with Pre => Offset <= Nhe_O.Page_Size - 3
   is
   begin
      Page (Offset)     := Byte (Shift_Right (Val, 24) and 16#FF#);
      Page (Offset + 1) := Byte (Shift_Right (Val, 16) and 16#FF#);
      Page (Offset + 2) := Byte (Shift_Right (Val, 8)  and 16#FF#);
      Page (Offset + 3) := Byte (Val and 16#FF#);
   end Put_U32_BE;

   function Get_U32_BE
     (Page   : Page_Buffer;
      Offset : Page_Offset) return Unsigned_32
     with Pre => Offset <= Nhe_O.Page_Size - 3
   is
   begin
      return Shift_Left (Unsigned_32 (Page (Offset)), 24)
        or Shift_Left (Unsigned_32 (Page (Offset + 1)), 16)
        or Shift_Left (Unsigned_32 (Page (Offset + 2)), 8)
        or Unsigned_32 (Page (Offset + 3));
   end Get_U32_BE;

   procedure Encode_Node_Page
     (Node : in     BTree_Node;
      Page :    out Page_Buffer)
   is
      Base     : Page_Offset;
      C_Base   : Page_Offset;
      K_Hi     : Unsigned_32;
      K_Lo     : Unsigned_32;
      Page_CRC : Unsigned_32;
   begin
      Page := [others => 0];
      Page (1) := Magic_B;
      Page (2) := Magic_T;
      Page (3) := Magic_R;
      Page (4) := Magic_E;
      Page (5) := (if Node.Kind = Node_Leaf then 1 else 2);
      Page (6) := Byte (Node.Num_Keys);
      Page (7) := (if Node.Kind = Node_Leaf then Byte (Node.Next_Leaf) else 0);
      Page (8) := 0;
      Put_U32_BE (Page, 9, Unsigned_32 (Node.Page_Id));
      --  Bytes 13..16 reserved for IEEE 802.3 CRC32 (filled after payload)

      --  Bytes 17..96: 4 x 20-byte key/pointer entries (64-bit key Hi+Lo + 3xU32 pointer)
      for I in Key_Slot_Index loop
         Base := 17 + (I - 1) * 20;
         Key_To_Words (Node.Keys (I), K_Hi, K_Lo);
         Put_U32_BE (Page, Base,      K_Hi);
         Put_U32_BE (Page, Base + 4,  K_Lo);
         Put_U32_BE (Page, Base + 8,  Unsigned_32 (Node.Pointers (I).Target_Page));
         Put_U32_BE (Page, Base + 12, Unsigned_32 (Node.Pointers (I).Target_Slot));
         Put_U32_BE (Page, Base + 16, Unsigned_32 (Node.Pointers (I).TOAST_Root));
      end loop;

      --  Bytes 97..116: 5 x 4-byte internal child node IDs (Children (1..5))
      for C in Child_Slot_Index loop
         C_Base := 97 + (C - 1) * 4;
         Put_U32_BE (Page, C_Base, Unsigned_32 (Node.Children (C)));
      end loop;

      --  Bytes 13..16: Page CRC32 computed with bytes 13..16 zeroed
      Page_CRC := Nhe_O.Transaction.Compute_CRC32 (Page);
      Put_U32_BE (Page, 13, Page_CRC);
   end Encode_Node_Page;

   procedure Decode_Node_Page
     (Page  : in     Page_Buffer;
      Node  :    out BTree_Node;
      Valid :    out Boolean)
   is
      Zeroed_Page : Page_Buffer := Page;
      Stored_CRC  : Unsigned_32;
      Base        : Page_Offset;
      C_Base      : Page_Offset;
      Raw_Page    : Unsigned_32;
      Raw_K_Hi    : Unsigned_32;
      Raw_K_Lo    : Unsigned_32;
      Raw_TPage   : Unsigned_32;
      Raw_TSlot   : Unsigned_32;
      Raw_Toast   : Unsigned_32;
      Raw_Child   : Unsigned_32;
      Temp_Node   : BTree_Node := (others => <>);
   begin
      Node  := (others => <>);
      Valid := False;

      if Page (1) /= Magic_B
        or else Page (2) /= Magic_T
        or else Page (3) /= Magic_R
        or else Page (4) /= Magic_E
      then
         return;
      end if;

      --  Verify IEEE 802.3 CRC32 checksum over the page (CRIT-03)
      Stored_CRC       := Get_U32_BE (Page, 13);
      Zeroed_Page (13) := 0;
      Zeroed_Page (14) := 0;
      Zeroed_Page (15) := 0;
      Zeroed_Page (16) := 0;
      if Nhe_O.Transaction.Compute_CRC32 (Zeroed_Page) /= Stored_CRC then
         return;
      end if;

      if Page (5) = 1 then
         Temp_Node.Kind := Node_Leaf;
      elsif Page (5) = 2 then
         Temp_Node.Kind := Node_Internal;
      else
         return;
      end if;

      if Natural (Page (6)) > Max_Keys_Per_Node
        or else Natural (Page (7)) > Max_BTree_Nodes
      then
         return;
      end if;

      if Temp_Node.Kind = Node_Internal and then Page (7) /= 0 then
         return;
      end if;

      Temp_Node.Num_Keys  := Key_Slot_Count (Page (6));
      Temp_Node.Next_Leaf := Optional_Node_Id (Page (7));

      Raw_Page := Get_U32_BE (Page, 9);
      if Raw_Page <= Unsigned_32 (Max_Page_Id) then
         Temp_Node.Page_Id := Valid_Page_Id (Raw_Page);
      else
         return;
      end if;

      for I in Key_Slot_Index loop
         Base      := 17 + (I - 1) * 20;
         Raw_K_Hi  := Get_U32_BE (Page, Base);
         Raw_K_Lo  := Get_U32_BE (Page, Base + 4);
         Raw_TPage := Get_U32_BE (Page, Base + 8);
         Raw_TSlot := Get_U32_BE (Page, Base + 12);
         Raw_Toast := Get_U32_BE (Page, Base + 16);

         if Raw_TPage > Unsigned_32 (Max_Page_Id)
           or else Raw_TSlot = 0
           or else Raw_TSlot > Unsigned_32 (Positive'Last)
           or else Raw_Toast > Unsigned_32 (Max_Page_Id)
         then
            return;
         end if;

         Temp_Node.Keys (I)     := Words_To_Key (Raw_K_Hi, Raw_K_Lo);
         Temp_Node.Pointers (I) := (
            Target_Page => Valid_Page_Id (Raw_TPage),
            Target_Slot => Positive (Raw_TSlot),
            TOAST_Root  => Valid_Page_Id (Raw_Toast)
         );
      end loop;

      for C in Child_Slot_Index loop
         C_Base    := 97 + (C - 1) * 4;
         Raw_Child := Get_U32_BE (Page, C_Base);
         if Raw_Child < 1 or else Raw_Child > Unsigned_32 (Max_BTree_Nodes) then
            return;
         end if;
         Temp_Node.Children (C) := BTree_Node_Id (Raw_Child);
      end loop;

      Node  := Temp_Node;
      Valid := True;
   end Decode_Node_Page;

end Nhe_O.BTree;
