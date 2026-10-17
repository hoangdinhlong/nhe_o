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
         pragma Loop_Invariant
           (I in 1 .. A.Dim
            and then Sum in 0.0 .. Float (I - 1) * 4.0e12);
         Diff := A.Elements (I) - B.Elements (I);
         Sq   := Diff * Diff;
         if Sq > 4.0e12 then
            Sq := 4.0e12;
         end if;
         Sum := Sum + Sq;
         if Sum > Float (I) * 4.0e12 then
            Sum := Float (I) * 4.0e12;
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
      Term1 : Non_Negative_Float;
      Term2 : Non_Negative_Float;
   begin
      if X <= 0.0 then
         return 0.0;
      elsif X >= 1.0 then
         Guess := (if X > 2.0 then X * 0.5 else 1.0);
         if Guess < 1.0 then
            Guess := 1.0;
         elsif Guess > X then
            Guess := X;
         end if;
         for Step in 1 .. 80 loop
            pragma Loop_Invariant (Guess in 1.0 .. X);
            Term1 := 0.5 * Guess;
            Term2 := 0.5 * (X / Guess);
            if Term1 > X * 0.5 then
               Term1 := X * 0.5;
            end if;
            if Term2 > X * 0.5 then
               Term2 := X * 0.5;
            end if;
            Guess := Term1 + Term2;
            if Guess < 1.0 then
               Guess := 1.0;
            elsif Guess > X then
               Guess := X;
            end if;
         end loop;
         return Guess;
      else
         Guess := 1.0;
         for Step in 1 .. 80 loop
            pragma Loop_Invariant (Guess in X .. 1.0);
            Term1 := 0.5 * Guess;
            Term2 := 0.5 * (X / Guess);
            if Term1 > 0.5 then
               Term1 := 0.5;
            end if;
            if Term2 > 0.5 then
               Term2 := 0.5;
            end if;
            Guess := Term1 + Term2;
            if Guess < X then
               Guess := X;
            elsif Guess > 1.0 then
               Guess := 1.0;
            end if;
         end loop;
         return Guess;
      end if;
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
      Norm_A : Non_Negative_Float          :=
        Sqrt_Bounded (L2_Distance_Squared (A, Vector_Value'(Dim => A.Dim, Elements => [others => 0.0])));
      Norm_B : Non_Negative_Float          :=
        Sqrt_Bounded (L2_Distance_Squared (B, Vector_Value'(Dim => B.Dim, Elements => [others => 0.0])));
      Denom  : Float;
      Sim    : Float;
      Dist   : Float;
   begin
      if Norm_A <= 1.0e-9 or else Norm_B <= 1.0e-9 then
         return 1.0;
      end if;
      if Norm_A > 1.0e9 then
         Norm_A := 1.0e9;
      end if;
      if Norm_B > 1.0e9 then
         Norm_B := 1.0e9;
      end if;
      Denom := Norm_A * Norm_B;
      if Denom <= 1.0e-18 then
         return 1.0;
      end if;
      if Dot >= Denom then
         Sim := 1.0;
      elsif Dot <= -Denom then
         Sim := -1.0;
      else
         Sim := Dot / Denom;
      end if;
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

   function Quantize_To_Int8 (V : Vector_Value) return Quantized_Int8_Vector is
      Max_Abs : Non_Negative_Float := 0.0;
      Scale   : Non_Negative_Float;
      Res     : Quantized_Int8_Vector;
      Val_Abs : Non_Negative_Float;
      Ratio   : Float;
      Scaled  : Float;
      Quant   : Integer;
   begin
      Res.Dim      := V.Dim;
      Res.Elements := [others => 0];

      for I in 1 .. V.Dim loop
         pragma Loop_Invariant (Max_Abs in 0.0 .. Max_Component);
         Val_Abs := abs V.Elements (I);
         if Val_Abs > Max_Abs then
            Max_Abs := Val_Abs;
         end if;
      end loop;

      if Max_Abs > 1.0e-12 then
         Scale := Max_Abs / 127.0;
      else
         Scale := 1.0;
      end if;
      if Scale <= 0.0 then
         Scale := 1.0;
      end if;
      Res.Scale := Scale;

      for I in 1 .. V.Dim loop
         if Max_Abs > 1.0e-12 then
            if V.Elements (I) >= Max_Abs then
               Ratio := 1.0;
            elsif V.Elements (I) <= -Max_Abs then
               Ratio := -1.0;
            else
               Ratio := V.Elements (I) / Max_Abs;
            end if;
         else
            Ratio := 0.0;
         end if;

         if Ratio > 1.0 then
            Ratio := 1.0;
         elsif Ratio < -1.0 then
            Ratio := -1.0;
         end if;
         pragma Assert (Ratio in -1.0 .. 1.0);
         Scaled := Ratio * 127.0;
         if Scaled >= 127.0 then
            Quant := 127;
         elsif Scaled <= -127.0 then
            Quant := -127;
         else
            Quant := Integer (Scaled);
            if Quant > 127 then
               Quant := 127;
            elsif Quant < -127 then
               Quant := -127;
            end if;
         end if;
         Res.Elements (I) := Int8_Component (Quant);
      end loop;

      return Res;
   end Quantize_To_Int8;

   function Dequantize_From_Int8 (Q : Quantized_Int8_Vector) return Vector_Value is
      Res     : Vector_Value;
      Raw_Val : Float;
   begin
      Res.Dim      := Q.Dim;
      Res.Elements := [others => 0.0];

      for I in 1 .. Q.Dim loop
         if Q.Scale <= Max_Component / 127.0 then
            Raw_Val := Float (Q.Elements (I)) * Q.Scale;
         else
            Raw_Val := 0.0;
         end if;

         if Raw_Val > Max_Component then
            Res.Elements (I) := Max_Component;
         elsif Raw_Val < -Max_Component then
            Res.Elements (I) := -Max_Component;
         else
            Res.Elements (I) := Raw_Val;
         end if;
      end loop;

      return Res;
   end Dequantize_From_Int8;

   function Int8_L2_Distance_Squared
     (A, B : Quantized_Int8_Vector) return Natural
   is
      Sum  : Natural := 0;
      Diff : Integer;
      Sq   : Natural;
   begin
      for I in 1 .. A.Dim loop
         --  Each diff is in -254 .. 254, Sq is in 0 .. 64_516.
         --  Over 4096 dimensions, max sum is 4096 * 64_516 = 264_257_536 < Natural'Last.
         pragma Loop_Invariant (Sum <= (I - 1) * 64_516);
         Diff := Integer (A.Elements (I)) - Integer (B.Elements (I));
         Sq   := Diff * Diff;
         Sum  := Sum + Sq;
      end loop;
      return Sum;
   end Int8_L2_Distance_Squared;

   function Int8_Inner_Product
     (A, B : Quantized_Int8_Vector) return Integer
   is
      Acc  : Integer := 0;
      Prod : Integer;
   begin
      for I in 1 .. A.Dim loop
         --  Each product is in -16_129 .. 16_129.
         --  Over 4096 dimensions, abs(Acc) <= 4096 * 16_129 = 66_064_384 < Integer'Last.
         pragma Loop_Invariant
           (Acc in (-((I - 1) * 16_129)) .. (I - 1) * 16_129);
         Prod := Integer (A.Elements (I)) * Integer (B.Elements (I));
         Acc  := Acc + Prod;
      end loop;
      return Acc;
   end Int8_Inner_Product;

   function Quantize_To_Binary (V : Vector_Value) return Quantized_Binary_Vector is
      use Interfaces;
      Res      : Quantized_Binary_Vector;
      Word_Idx : Binary_Word_Index;
      Bit_Pos  : Natural range 0 .. 63;
   begin
      Res.Dim   := V.Dim;
      Res.Words := [others => 0];

      for I in 1 .. V.Dim loop
         if V.Elements (I) > 0.0 then
            Word_Idx := ((I - 1) / 64) + 1;
            Bit_Pos  := (I - 1) mod 64;
            Res.Words (Word_Idx) :=
              Res.Words (Word_Idx) or Shift_Left (Unsigned_64 (1), Bit_Pos);
         end if;
      end loop;

      return Res;
   end Quantize_To_Binary;

   function Hamming_Distance
     (A, B : Quantized_Binary_Vector) return Natural
   is
      use Interfaces;
      Dist     : Natural := 0;
      Word_Idx : Binary_Word_Index;
      Bit_Pos  : Natural range 0 .. 63;
      Diff_W   : Unsigned_64;
   begin
      for I in 1 .. A.Dim loop
         pragma Loop_Invariant (Dist < I);
         Word_Idx := ((I - 1) / 64) + 1;
         Bit_Pos  := (I - 1) mod 64;
         Diff_W   := A.Words (Word_Idx) xor B.Words (Word_Idx);
         if (Shift_Right (Diff_W, Bit_Pos) and 1) /= 0 then
            Dist := Dist + 1;
         end if;
      end loop;
      return Dist;
   end Hamming_Distance;

end Nhe_O.Vector;

