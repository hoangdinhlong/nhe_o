pragma SPARK_Mode (On);

package body Nhe_O.Vector is

   function Make_Vector_3D
     (X, Y, Z : Vector_Component) return Vector_Value
   is
      V : Vector_Value;
   begin
      V.Dim := 3;
      V.Elements (1) := X;
      V.Elements (2) := Y;
      V.Elements (3) := Z;
      return V;
   end Make_Vector_3D;

   function L2_Distance_Squared
     (A, B : Vector_Value) return Non_Negative_Float
   is
      Sum  : Non_Negative_Float := 0.0;
      Diff : Float;
      Sq   : Non_Negative_Float;
   begin
      for I in 1 .. A.Dim loop
         pragma Loop_Invariant (I in 1 .. A.Dim and Sum >= 0.0);
         Diff := A.Elements (I) - B.Elements (I);
         Sq   := Diff * Diff;
         if Sum <= Float'Last - Sq then
            Sum := Sum + Sq;
         else
            Sum := Float'Last;
         end if;
      end loop;
      return Sum;
   end L2_Distance_Squared;

   function Inner_Product
     (A, B : Vector_Value) return Float
   is
      Acc  : Float := 0.0;
      Prod : Float;
   begin
      for I in 1 .. A.Dim loop
         pragma Loop_Invariant (I in 1 .. A.Dim);
         Prod := A.Elements (I) * B.Elements (I);
         if Prod >= 0.0 and then Acc <= Float'Last - Prod then
            Acc := Acc + Prod;
         elsif Prod < 0.0 and then Acc >= Float'First - Prod then
            Acc := Acc + Prod;
         end if;
      end loop;
      return Acc;
   end Inner_Product;

   function Negative_Inner_Product
     (A, B : Vector_Value) return Float
   is
      Dot : constant Float := Inner_Product (A, B);
   begin
      if Dot = Float'First then
         return Float'Last;
      else
         return -Dot;
      end if;
   end Negative_Inner_Product;

   function Sqrt_Bounded (X : Non_Negative_Float) return Non_Negative_Float is
      Guess : Non_Negative_Float;
   begin
      if X <= 0.0 then
         return 0.0;
      end if;
      Guess := (if X > 1.0 then X * 0.5 else 1.0);
      for Step in 1 .. 16 loop
         pragma Loop_Invariant (Guess >= 0.0);
         exit when Guess <= 1.0e-18;
         Guess := 0.5 * (Guess + (X / Guess));
      end loop;
      return Guess;
   end Sqrt_Bounded;

   function L2_Distance
     (A, B : Vector_Value) return Non_Negative_Float
   is
   begin
      return Sqrt_Bounded (L2_Distance_Squared (A, B));
   end L2_Distance;

   function Cosine_Distance
     (A, B : Vector_Value) return Float
   is
      Dot    : constant Float              := Inner_Product (A, B);
      Norm_A : constant Non_Negative_Float := Sqrt_Bounded (L2_Distance_Squared (A, Vector_Value'(Dim => A.Dim, Elements => [others => 0.0])));
      Norm_B : constant Non_Negative_Float := Sqrt_Bounded (L2_Distance_Squared (B, Vector_Value'(Dim => B.Dim, Elements => [others => 0.0])));
      Denom  : Float;
      Sim    : Float;
      Dist   : Float;
   begin
      if Norm_A <= 1.0e-12 or else Norm_B <= 1.0e-12 then
         return 1.0;
      end if;
      Denom := Norm_A * Norm_B;
      if Denom <= 1.0e-12 then
         return 1.0;
      end if;
      Sim := Dot / Denom;
      if Sim > 1.0 then
         Sim := 1.0;
      elsif Sim < -1.0 then
         Sim := -1.0;
      end if;
      Dist := 1.0 - Sim;
      if Dist < 0.0 then
         return 0.0;
      elsif Dist > 2.0 then
         return 2.0;
      else
         return Dist;
      end if;
   end Cosine_Distance;

end Nhe_O.Vector;
