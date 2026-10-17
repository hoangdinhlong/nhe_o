pragma SPARK_Mode (On);

package body Nhe_O.BTree is

   --  Magic bytes "BTRE" (0x42, 0x54, 0x52, 0x45)
   Magic_B : constant Byte := 16#42#;
   Magic_T : constant Byte := 16#54#;
   Magic_R : constant Byte := 16#52#;
   Magic_E : constant Byte := 16#45#;

   procedure Init_BTree (Tree : out BTree_Index) is
   begin
      Tree := (
         Root_Node   => 1,
         Node_Count  => 1,
         Split_Count => 0,
         Total_Keys  => 0,
         Nodes       => [others => (others => <>)]
      );
      Tree.Nodes (1).Kind     := Node_Leaf;
      Tree.Nodes (1).Page_Id  := 1;
      Tree.Nodes (1).Num_Keys := 0;
   end Init_BTree;

   --  Insert a key and pointer into a non-full leaf node in sorted ascending order
   procedure Insert_Into_Non_Full_Leaf
     (Leaf  : in out BTree_Node;
      Key   : in     Integer_64;
      Ptr   : in     BTree_Record_Pointer;
      Added :    out Boolean)
     with Pre  => Leaf.Kind = Node_Leaf
                  and then Leaf.Num_Keys < Max_Keys_Per_Node,
          Post => Leaf.Kind = Node_Leaf
                  and then Leaf.Num_Keys in 1 .. Max_Keys_Per_Node
   is
      Insert_Pos : Key_Slot_Index := 1;
   begin
      --  Check for existing key update first
      for I in 1 .. Leaf.Num_Keys loop
         if Leaf.Keys (I) = Key then
            Leaf.Pointers (I) := Ptr;
            Added := False;
            return;
         end if;
      end loop;

      --  Find sorted insertion slot
      Insert_Pos := Leaf.Num_Keys + 1;
      for I in 1 .. Leaf.Num_Keys loop
         if Key < Leaf.Keys (I) then
            Insert_Pos := I;
            exit;
         end if;
      end loop;

      --  Shift right from Leaf.Num_Keys down to Insert_Pos
      for I in reverse Insert_Pos .. Leaf.Num_Keys loop
         pragma Loop_Invariant (I in 1 .. Max_Keys_Per_Node - 1);
         Leaf.Keys (I + 1)     := Leaf.Keys (I);
         Leaf.Pointers (I + 1) := Leaf.Pointers (I);
      end loop;

      Leaf.Keys (Insert_Pos)     := Key;
      Leaf.Pointers (Insert_Pos) := Ptr;
      Leaf.Num_Keys              := Leaf.Num_Keys + 1;
      Added                      := True;
   end Insert_Into_Non_Full_Leaf;

   --  Choose target leaf node for Key by routing through internal root if present
   function Route_To_Leaf
     (Tree : BTree_Index;
      Key  : Integer_64) return BTree_Node_Id
     with Pre  => Tree.Node_Count in 1 .. Max_BTree_Nodes
                  and then Tree.Root_Node in 1 .. Tree.Node_Count,
          Post => Route_To_Leaf'Result in 1 .. Tree.Node_Count
   is
      Root : constant BTree_Node := Tree.Nodes (Tree.Root_Node);
      Cand : BTree_Node_Id       := Tree.Root_Node;
   begin
      if Root.Kind = Node_Leaf then
         return Tree.Root_Node;
      end if;

      --  Internal root node: children 1 .. Root.Num_Keys + 1 separated by Keys 1 .. Root.Num_Keys
      Cand := Root.Children (1);
      for I in 1 .. Root.Num_Keys loop
         if Key >= Root.Keys (I) then
            Cand := Root.Children (I + 1);
         end if;
      end loop;

      if Cand in 1 .. Tree.Node_Count then
         return Cand;
      else
         return Tree.Root_Node;
      end if;
   end Route_To_Leaf;

   procedure Insert_Key
     (Tree   : in out BTree_Index;
      Key    : in     Integer_64;
      Ptr    : in     BTree_Record_Pointer;
      Status :    out Engine_Status)
   is
      Leaf_Id      : BTree_Node_Id;
      New_Leaf_Id  : BTree_Node_Id;
      New_Root_Id  : BTree_Node_Id;
      Promoted_Key : Integer_64;
      Added        : Boolean;
      Root_Slot    : Key_Slot_Index;
   begin
      Leaf_Id := Route_To_Leaf (Tree, Key);

      --  1. Check if key already exists in target leaf (in-place update)
      for I in 1 .. Tree.Nodes (Leaf_Id).Num_Keys loop
         if Tree.Nodes (Leaf_Id).Keys (I) = Key then
            Tree.Nodes (Leaf_Id).Pointers (I) := Ptr;
            Status := Status_Ok;
            return;
         end if;
      end loop;

      --  2. If target leaf has free space, insert directly
      if Tree.Nodes (Leaf_Id).Num_Keys < Max_Keys_Per_Node then
         Insert_Into_Non_Full_Leaf (Tree.Nodes (Leaf_Id), Key, Ptr, Added);
         if Added and then Tree.Total_Keys < Natural'Last then
            Tree.Total_Keys := Tree.Total_Keys + 1;
         end if;
         Status := Status_Ok;
         return;
      end if;

      --  3. Target leaf is full (Num_Keys = 4): perform deterministic B+Tree Leaf Split!
      if Tree.Nodes (Tree.Root_Node).Kind = Node_Leaf then
         --  Root itself is a full leaf: need 2 new nodes (New_Leaf + New_Internal_Root)
         if Tree.Node_Count > Max_BTree_Nodes - 2 then
            Status := Status_Capacity_Exceeded;
            return;
         end if;

         New_Leaf_Id := Tree.Node_Count + 1;
         New_Root_Id := Tree.Node_Count + 2;
         Tree.Node_Count := Tree.Node_Count + 2;

         --  Split 4 keys of Leaf_Id: keep lower 2 in Leaf_Id, move upper 2 ( slots 3, 4 ) to New_Leaf_Id
         Tree.Nodes (New_Leaf_Id) := (
            Kind      => Node_Leaf,
            Page_Id   => Valid_Page_Id (New_Leaf_Id),
            Num_Keys  => 2,
            Keys      => [1 => Tree.Nodes (Leaf_Id).Keys (3),
                          2 => Tree.Nodes (Leaf_Id).Keys (4),
                          others => 0],
            Pointers  => [1 => Tree.Nodes (Leaf_Id).Pointers (3),
                          2 => Tree.Nodes (Leaf_Id).Pointers (4),
                          others => (others => <>)],
            Children  => [others => 1],
            Next_Leaf => Tree.Nodes (Leaf_Id).Next_Leaf
         );

         Tree.Nodes (Leaf_Id).Num_Keys  := 2;
         Tree.Nodes (Leaf_Id).Next_Leaf := New_Leaf_Id;
         Promoted_Key := Tree.Nodes (New_Leaf_Id).Keys (1);

         --  Initialize new internal root node pointing to Leaf_Id and New_Leaf_Id
         Tree.Nodes (New_Root_Id) := (
            Kind      => Node_Internal,
            Page_Id   => Valid_Page_Id (New_Root_Id),
            Num_Keys  => 1,
            Keys      => [1 => Promoted_Key, others => 0],
            Pointers  => [others => (others => <>)],
            Children  => [1 => Leaf_Id, 2 => New_Leaf_Id, others => 1],
            Next_Leaf => 0
         );
         Tree.Root_Node := New_Root_Id;
         if Tree.Split_Count < Natural'Last then
            Tree.Split_Count := Tree.Split_Count + 1;
         end if;

         --  Insert the new key into the appropriate half
         if Key < Promoted_Key then
            Insert_Into_Non_Full_Leaf (Tree.Nodes (Leaf_Id), Key, Ptr, Added);
         else
            Insert_Into_Non_Full_Leaf (Tree.Nodes (New_Leaf_Id), Key, Ptr, Added);
         end if;

         if Added and then Tree.Total_Keys < Natural'Last then
            Tree.Total_Keys := Tree.Total_Keys + 1;
         end if;
         Status := Status_Ok;
         return;
      else
         --  Root is already an internal node; split Leaf_Id and promote separator into Root
         if Tree.Node_Count = Max_BTree_Nodes
           or else Tree.Nodes (Tree.Root_Node).Num_Keys = Max_Keys_Per_Node
         then
            Status := Status_Capacity_Exceeded;
            return;
         end if;

         New_Leaf_Id     := Tree.Node_Count + 1;
         Tree.Node_Count := Tree.Node_Count + 1;

         Tree.Nodes (New_Leaf_Id) := (
            Kind      => Node_Leaf,
            Page_Id   => Valid_Page_Id (New_Leaf_Id),
            Num_Keys  => 2,
            Keys      => [1 => Tree.Nodes (Leaf_Id).Keys (3),
                          2 => Tree.Nodes (Leaf_Id).Keys (4),
                          others => 0],
            Pointers  => [1 => Tree.Nodes (Leaf_Id).Pointers (3),
                          2 => Tree.Nodes (Leaf_Id).Pointers (4),
                          others => (others => <>)],
            Children  => [others => 1],
            Next_Leaf => Tree.Nodes (Leaf_Id).Next_Leaf
         );

         Tree.Nodes (Leaf_Id).Num_Keys  := 2;
         Tree.Nodes (Leaf_Id).Next_Leaf := New_Leaf_Id;
         Promoted_Key := Tree.Nodes (New_Leaf_Id).Keys (1);

         --  Insert Promoted_Key and New_Leaf_Id into internal Root node in sorted order
         Root_Slot := Tree.Nodes (Tree.Root_Node).Num_Keys + 1;
         for I in 1 .. Tree.Nodes (Tree.Root_Node).Num_Keys loop
            if Promoted_Key < Tree.Nodes (Tree.Root_Node).Keys (I) then
               Root_Slot := I;
               exit;
            end if;
         end loop;

         for I in reverse Root_Slot .. Tree.Nodes (Tree.Root_Node).Num_Keys loop
            pragma Loop_Invariant (I in 1 .. Max_Keys_Per_Node - 1);
            Tree.Nodes (Tree.Root_Node).Keys (I + 1)     := Tree.Nodes (Tree.Root_Node).Keys (I);
            Tree.Nodes (Tree.Root_Node).Children (I + 2) := Tree.Nodes (Tree.Root_Node).Children (I + 1);
         end loop;

         Tree.Nodes (Tree.Root_Node).Keys (Root_Slot)         := Promoted_Key;
         Tree.Nodes (Tree.Root_Node).Children (Root_Slot + 1) := New_Leaf_Id;
         Tree.Nodes (Tree.Root_Node).Num_Keys                 :=
           Tree.Nodes (Tree.Root_Node).Num_Keys + 1;

         if Tree.Split_Count < Natural'Last then
            Tree.Split_Count := Tree.Split_Count + 1;
         end if;

         if Key < Promoted_Key then
            Insert_Into_Non_Full_Leaf (Tree.Nodes (Leaf_Id), Key, Ptr, Added);
         else
            Insert_Into_Non_Full_Leaf (Tree.Nodes (New_Leaf_Id), Key, Ptr, Added);
         end if;

         if Added and then Tree.Total_Keys < Natural'Last then
            Tree.Total_Keys := Tree.Total_Keys + 1;
         end if;
         Status := Status_Ok;
      end if;
   end Insert_Key;

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

      for I in 1 .. Leaf.Num_Keys loop
         if Leaf.Keys (I) = Key then
            Found := True;
            Ptr   := Leaf.Pointers (I);
            return;
         end if;
      end loop;
   end Search_Key;

   procedure Range_Scan
     (Tree    : in     BTree_Index;
      Min_Key : in     Integer_64;
      Max_Key : in     Integer_64;
      Results :    out BTree_Scan_Result)
   is
      Cur_Node : Optional_Node_Id := 1;
   begin
      Results := (Count => 0, Items => [others => (others => <>)]);

      --  Find leftmost leaf node (Node 1 is always the leftmost leaf in our split protocol)
      for Step in 1 .. Max_BTree_Nodes loop
         exit when Cur_Node = 0 or else Cur_Node > Tree.Node_Count;

         for K_Idx in 1 .. Tree.Nodes (Cur_Node).Num_Keys loop
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
      Base : Page_Offset;
      K_Lo : Unsigned_32;
   begin
      Page := [others => 0];
      Page (1) := Magic_B;
      Page (2) := Magic_T;
      Page (3) := Magic_R;
      Page (4) := Magic_E;
      Page (5) := (if Node.Kind = Node_Leaf then 1 else 2);
      Page (6) := Byte (Node.Num_Keys);
      Page (7) := Byte (Node.Next_Leaf);
      Put_U32_BE (Page, 9, Unsigned_32 (Node.Page_Id));

      for I in Key_Slot_Index loop
         Base := 17 + (I - 1) * 16;
         if Node.Keys (I) >= 0 and then Node.Keys (I) <= Integer_64 (Unsigned_32'Last) then
            K_Lo := Unsigned_32 (Node.Keys (I));
         else
            K_Lo := 0;
         end if;
         Put_U32_BE (Page, Base, K_Lo);
         Put_U32_BE (Page, Base + 4, Unsigned_32 (Node.Pointers (I).Target_Page));
         Put_U32_BE (Page, Base + 8, Unsigned_32 (Node.Pointers (I).Target_Slot));
         Put_U32_BE (Page, Base + 12, Unsigned_32 (Node.Pointers (I).TOAST_Root));
      end loop;
   end Encode_Node_Page;

   procedure Decode_Node_Page
     (Page  : in     Page_Buffer;
      Node  :    out BTree_Node;
      Valid :    out Boolean)
   is
      Base     : Page_Offset;
      Raw_Page : Unsigned_32;
      Raw_Key  : Unsigned_32;
      Raw_TPage: Unsigned_32;
      Raw_TSlot: Unsigned_32;
      Raw_Toast: Unsigned_32;
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

      if Page (5) = 1 then
         Node.Kind := Node_Leaf;
      elsif Page (5) = 2 then
         Node.Kind := Node_Internal;
      else
         return;
      end if;

      if Natural (Page (6)) > Max_Keys_Per_Node
        or else Natural (Page (7)) > Max_BTree_Nodes
      then
         return;
      end if;

      Node.Num_Keys  := Key_Slot_Count (Page (6));
      Node.Next_Leaf := Optional_Node_Id (Page (7));

      Raw_Page := Get_U32_BE (Page, 9);
      if Raw_Page <= Unsigned_32 (Max_Page_Id) then
         Node.Page_Id := Valid_Page_Id (Raw_Page);
      else
         return;
      end if;

      for I in Key_Slot_Index loop
         Base      := 17 + (I - 1) * 16;
         Raw_Key   := Get_U32_BE (Page, Base);
         Raw_TPage := Get_U32_BE (Page, Base + 4);
         Raw_TSlot := Get_U32_BE (Page, Base + 8);
         Raw_Toast := Get_U32_BE (Page, Base + 12);

         Node.Keys (I) := Integer_64 (Raw_Key);
         if Raw_TPage <= Unsigned_32 (Max_Page_Id)
           and then Raw_TSlot >= 1
           and then Raw_Toast <= Unsigned_32 (Max_Page_Id)
         then
            Node.Pointers (I) := (
               Target_Page => Valid_Page_Id (Raw_TPage),
               Target_Slot => Positive (Raw_TSlot),
               TOAST_Root  => Valid_Page_Id (Raw_Toast)
            );
         end if;
      end loop;

      Valid := True;
   end Decode_Node_Page;

end Nhe_O.BTree;
