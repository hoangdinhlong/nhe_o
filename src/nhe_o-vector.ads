--  Formally verified PostgreSQL pgvector-compatible Vector Engine (BR-003)
pragma SPARK_Mode (On);

package Nhe_O.Vector is

   Max_Vector_Dim : constant := 256;
   subtype Vector_Dim is Positive range 1 .. Max_Vector_Dim;

   --  Bounded float component preventing IEEE-754 overflow during dot/L2 sum
   Max_Component : constant := 1.0e6;
   subtype Vector_Component is Float range -Max_Component .. Max_Component;
   subtype Non_Negative_Float is Float range 0.0 .. Float'Last;

   type Vector_Array is array (Vector_Dim) of Vector_Component;

   type Vector_Value is record
      Dim      : Vector_Dim   := 1;
      Elements : Vector_Array := [others => 0.0];
   end record;

   --  Construct a 3D vector helper for testing and SQL literals
   function Make_Vector_3D
     (X, Y, Z : Vector_Component) return Vector_Value
     with Post => Make_Vector_3D'Result.Dim = 3;

   --  pgvector `<->` operator: Squared Euclidean (L2) distance
   function L2_Distance_Squared
     (A, B : Vector_Value) return Non_Negative_Float
     with Pre  => A.Dim = B.Dim,
          Post => L2_Distance_Squared'Result >= 0.0;

   --  Inner product (dot product)
   function Inner_Product
     (A, B : Vector_Value) return Float
     with Pre => A.Dim = B.Dim;

   --  pgvector `<#>` operator: Negative inner product
   function Negative_Inner_Product
     (A, B : Vector_Value) return Float
     with Pre => A.Dim = B.Dim;

   --  Newton-Raphson bounded square root in pure SPARK
   function Sqrt_Bounded (X : Non_Negative_Float) return Non_Negative_Float
     with Post => Sqrt_Bounded'Result >= 0.0;

   --  pgvector `<->` operator: Euclidean (L2) distance
   function L2_Distance
     (A, B : Vector_Value) return Non_Negative_Float
     with Pre  => A.Dim = B.Dim,
          Post => L2_Distance'Result >= 0.0;

   --  pgvector `<=>` operator: Cosine distance in [0.0 .. 2.0]
   function Cosine_Distance
     (A, B : Vector_Value) return Float
     with Pre  => A.Dim = B.Dim,
          Post => Cosine_Distance'Result in 0.0 .. 2.0;

end Nhe_O.Vector;
