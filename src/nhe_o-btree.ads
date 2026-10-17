--  Formally verified Multi-Page B+Tree Index with Multi-Level Node Splitting
--  (CRIT-02, CRIT-03, MED-03)
pragma SPARK_Mode (On);

with Interfaces; use Interfaces;
with Nhe_O.Types; use Nhe_O.Types;
with Nhe_O.IO;    use Nhe_O.IO;

package Nhe_O.BTree is

   Max_Keys_Per_Node : constant := 4;
   subtype Key_Slot_Index is Positive range 1 .. Max_Keys_Per_Node;
   subtype Key_Slot_Count is Natural range 0 .. Max_Keys_Per_Node;

   Max_Children_Per_Node : constant := Max_Keys_Per_Node + 1;
   subtype Child_Slot_Index is Positive range 1 .. Max_Children_Per_Node;

   Max_BTree_Nodes : constant := 32;
   Max_BTree_Depth : constant := 8;
   subtype BTree_Node_Id is Positive range 1 .. Max_BTree_Nodes;
   subtype BTree_Node_Count is Natural range 0 .. Max_BTree_Nodes;
   subtype Optional_Node_Id is Natural range 0 .. Max_BTree_Nodes;

   type BTree_Node_Kind is (Node_Leaf, Node_Internal);

   type BTree_Record_Pointer is record
      Target_Page : Valid_Page_Id := 0;
      Target_Slot : Positive      := 1;
      TOAST_Root  : Valid_Page_Id := 0;
   end record;

   type Key_Array is array (Key_Slot_Index) of Integer_64;
   type Pointer_Array is array (Key_Slot_Index) of BTree_Record_Pointer;
   type Child_Array is array (Child_Slot_Index) of BTree_Node_Id;

   type BTree_Node is record
      Kind      : BTree_Node_Kind  := Node_Leaf;
      Page_Id   : Valid_Page_Id    := 0;
      Num_Keys  : Key_Slot_Count   := 0;
      Keys      : Key_Array        := [others => 0];
      Pointers  : Pointer_Array    := [others => (others => <>)];
      Children  : Child_Array      := [others => 1];
      Next_Leaf : Optional_Node_Id := 0;
   end record;

   type BTree_Node_Pool is array (BTree_Node_Id) of BTree_Node;

   type BTree_Index is record
      Root_Node   : BTree_Node_Id    := 1;
      Node_Count  : BTree_Node_Count := 1;
      Split_Count : Natural          := 0;
      Total_Keys  : Natural          := 0;
      Nodes       : BTree_Node_Pool  := [others => (others => <>)];
   end record;

   --  Structural invariant functions for B+Tree nodes and index (MED-03)
   function Is_Valid_Node (Node : BTree_Node) return Boolean is
     (if Node.Kind = Node_Internal then Node.Next_Leaf = 0 else True);

   function Is_Valid_Tree (Tree : BTree_Index) return Boolean is
     (Tree.Node_Count >= 1 and then Tree.Root_Node <= Tree.Node_Count);

   Max_Scan_Results : constant := 64;
   subtype Scan_Result_Index is Positive range 1 .. Max_Scan_Results;
   subtype Scan_Result_Count is Natural range 0 .. Max_Scan_Results;

   type BTree_Scan_Entry is record
      Key : Integer_64           := 0;
      Ptr : BTree_Record_Pointer := (others => <>);
   end record;

   type BTree_Scan_Array is array (Scan_Result_Index) of BTree_Scan_Entry;

   type BTree_Scan_Result is record
      Count : Scan_Result_Count := 0;
      Items : BTree_Scan_Array  := [others => (others => <>)];
   end record;

   --  Initialize an empty B+Tree with a single root leaf node
   procedure Init_BTree (Tree : out BTree_Index)
     with Global => null,
          Always_Terminates,
          Post   => Tree.Node_Count = 1
                    and then Tree.Root_Node = 1
                    and then Tree.Total_Keys = 0
                    and then Tree.Split_Count = 0
                    and then Is_Valid_Tree (Tree);

   --  Insert or update a key -> record pointer in the B+Tree, splitting leaf
   --  and internal nodes bottom-up and promoting a new root when full (CRIT-02)
   procedure Insert_Key
     (Tree   : in out BTree_Index;
      Key    : in     Integer_64;
      Ptr    : in     BTree_Record_Pointer;
      Status :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Tree.Root_Node in 1 .. Tree.Node_Count,
          Post   => Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Tree.Root_Node in 1 .. Tree.Node_Count;

   --  Exact key lookup traversing internal separator keys down to the leaf node
   procedure Search_Key
     (Tree  : in     BTree_Index;
      Key   : in     Integer_64;
      Found :    out Boolean;
      Ptr   :    out BTree_Record_Pointer)
     with Global => null,
          Always_Terminates,
          Pre    => Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Tree.Root_Node in 1 .. Tree.Node_Count;

   --  Ordered range scan [Min_Key .. Max_Key] across linked leaf nodes
   procedure Range_Scan
     (Tree    : in     BTree_Index;
      Min_Key : in     Integer_64;
      Max_Key : in     Integer_64;
      Results :    out BTree_Scan_Result)
     with Global => null,
          Always_Terminates,
          Pre    => Tree.Node_Count in 1 .. Max_BTree_Nodes
                    and then Tree.Root_Node in 1 .. Tree.Node_Count
                    and then Min_Key <= Max_Key,
          Post   => Results.Count <= Max_Scan_Results;

   --  Serialize a B+Tree node into a 4096-byte Slotted Page buffer with Magic "BTRE",
   --  full 64-bit keys, internal child pointers, and IEEE 802.3 CRC32 (CRIT-03)
   procedure Encode_Node_Page
     (Node : in     BTree_Node;
      Page :    out Page_Buffer)
     with Global => null,
          Always_Terminates;

   --  Deserialize and CRC32-verify a B+Tree node from a 4096-byte Slotted Page buffer
   procedure Decode_Node_Page
     (Page  : in     Page_Buffer;
      Node  :    out BTree_Node;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Valid then Is_Valid_Node (Node));

end Nhe_O.BTree;
