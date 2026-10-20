pragma SPARK_Mode (On);

with Nhe_O.IO; use Nhe_O.IO;

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

   -------------------------------------------------------------------------
   --  Scale-Invariant Cosine Distance Helpers
   -------------------------------------------------------------------------

   --  Largest absolute component of V: 0.0 exactly for the all-zero vector,
   --  otherwise the magnitude of some component. The loop invariant tracks the
   --  arg-max index instead of quantifying over the visited prefix, so the
   --  run-time assertion cost (-gnata) stays O(1) per component at 4096-D.
   function Max_Abs_Component (V : Vector_Value) return Non_Negative_Float
     with Global => null,
          Post   => Max_Abs_Component'Result <= Max_Component
                    and then (Max_Abs_Component'Result = 0.0
                              or else (for some I in 1 .. V.Dim =>
                                         abs V.Elements (I) = Max_Abs_Component'Result))
   is
      Max_Abs : Non_Negative_Float := 0.0;
      Arg_Max : Vector_Dim         := 1;
   begin
      for I in 1 .. V.Dim loop
         pragma Loop_Invariant (Max_Abs <= Max_Component);
         pragma Loop_Invariant
           (Max_Abs = 0.0
            or else (Arg_Max < I and then abs V.Elements (Arg_Max) = Max_Abs));
         if abs V.Elements (I) > Max_Abs then
            Max_Abs := abs V.Elements (I);
            Arg_Max := I;
         end if;
      end loop;
      pragma Assert
        (Max_Abs = 0.0
         or else (Arg_Max <= V.Dim and then abs V.Elements (Arg_Max) = Max_Abs));
      return Max_Abs;
   end Max_Abs_Component;

   --  A vector whose largest absolute component is below Tiny_Magnitude has
   --  its components first multiplied by the exact power of two Tiny_Boost,
   --  so the normalizing reciprocal never exceeds Tiny_Boost (no overflow)
   Tiny_Magnitude : constant := 2.0 ** (-100);
   Tiny_Boost     : constant := 2.0 ** 100;

   subtype Unit_Float is Float range -1.0 .. 1.0;
   subtype Unit_Recip is Float range 0.0 .. Tiny_Boost;

   --  Normalization factors for a vector whose largest absolute component is
   --  M > 0: component C maps to Unit_Component (C, Boosted, Recip), i.e.
   --  C * Recip (after C * Tiny_Boost when Boosted), close to C / M.
   procedure Unit_Scale
     (M       : in     Non_Negative_Float;
      Boosted :    out Boolean;
      Recip   :    out Unit_Recip)
     with Global => null,
          Pre    => M > 0.0 and then M <= Max_Component,
          Post   => Boosted = (M < Tiny_Magnitude)
                    and then (if not Boosted then Recip > 0.0)
   is
      Den : Float;
   begin
      Boosted := M < Tiny_Magnitude;
      if Boosted then
         Den := M * Tiny_Boost;
      else
         Den := M;
      end if;

      if Den < Tiny_Magnitude then
         --  Unreachable for IEEE single precision (2**-149 * 2**100 > 2**-100);
         --  a zero factor makes the vector behave as the zero vector
         Recip := 0.0;
      else
         Recip := Float'Min (1.0 / Den, Tiny_Boost);
      end if;
   end Unit_Scale;

   --  Component C scaled into [-1.0, 1.0] with the Unit_Scale factors. For
   --  the vector's own factors the clamps only absorb last-bit rounding.
   function Unit_Component
     (C       : Vector_Component;
      Boosted : Boolean;
      Recip   : Unit_Recip) return Unit_Float
     with Global => null,
          Post   => (if C = 0.0 then Unit_Component'Result = 0.0)
   is
      Num : Float := C;
      Q   : Float;
   begin
      if Boosted then
         --  abs C <= M < 2**-100, so the exact scaling stays within [-1, 1]
         Num := Num * Tiny_Boost;
         if Num > 1.0 then
            Num := 1.0;
         elsif Num < -1.0 then
            Num := -1.0;
         end if;
      end if;

      --  Num in [-1.0e6, 1.0e6] and Recip <= 2**100 on every path: no overflow
      Q := Num * Recip;
      if Q > 1.0 then
         return 1.0;
      elsif Q < -1.0 then
         return -1.0;
      else
         return Q;
      end if;
   end Unit_Component;

   function Cosine_Distance
     (A, B : Vector_Value) return Float
   is
      Max_A   : constant Non_Negative_Float := Max_Abs_Component (A);
      Max_B   : constant Non_Negative_Float := Max_Abs_Component (B);
      Boost_A : Boolean;
      Boost_B : Boolean;
      Recip_A : Unit_Recip;
      Recip_B : Unit_Recip;
      X       : Unit_Float;
      Y       : Unit_Float;
      Dot     : Float              := 0.0;
      Sq_A    : Non_Negative_Float := 0.0;
      Sq_B    : Non_Negative_Float := 0.0;
      Norm_A  : Non_Negative_Float;
      Norm_B  : Non_Negative_Float;
      Denom   : Float;
      Sim     : Float;
      Dist    : Float;
   begin
      --  Documented convention: an exact all-zero vector has no direction
      if Max_A = 0.0 or else Max_B = 0.0 then
         return 1.0;
      end if;

      --  Cosine similarity is scale-invariant: normalize each vector by its own
      --  largest absolute component so every term lies in [-1.0, 1.0] and tiny
      --  (even subnormal) or huge vectors neither underflow nor overflow
      Unit_Scale (Max_A, Boost_A, Recip_A);
      Unit_Scale (Max_B, Boost_B, Recip_B);
      for I in 1 .. A.Dim loop
         pragma Loop_Invariant (Dot in -Float (I - 1) .. Float (I - 1));
         pragma Loop_Invariant (Sq_A <= Float (I - 1) and then Sq_B <= Float (I - 1));
         X := Unit_Component (A.Elements (I), Boost_A, Recip_A);
         Y := Unit_Component (B.Elements (I), Boost_B, Recip_B);

         Dot := Dot + X * Y;
         if Dot > Float (I) then
            Dot := Float (I);
         elsif Dot < -Float (I) then
            Dot := -Float (I);
         end if;

         Sq_A := Sq_A + X * X;
         if Sq_A > Float (I) then
            Sq_A := Float (I);
         end if;

         Sq_B := Sq_B + Y * Y;
         if Sq_B > Float (I) then
            Sq_B := Float (I);
         end if;
      end loop;

      Norm_A := Sqrt_Bounded (Sq_A);
      Norm_B := Sqrt_Bounded (Sq_B);
      Denom  := Norm_A * Norm_B;
      --  Each normalized vector has a component of magnitude 1.0 (up to one
      --  rounding), so both norms are ~>= 1.0; the guard only keeps the
      --  quotient below provably bounded
      if Denom < 0.5 then
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
      Ratio     : Float;
      Scaled    : Float;
      Quant     : Integer;
      Has_Scale : Boolean;
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

      --  Per-vector scale for every non-zero vector; only a maximum so small that
      --  Max_Abs / 127 underflows to zero (below about 1.8e-43) keeps all-zero codes
      Scale := (if Max_Abs > 0.0 then Max_Abs / 127.0 else 0.0);
      Has_Scale := Scale > 0.0;
      if not Has_Scale then
         Scale := 1.0;
      end if;
      Res.Scale := Scale;

      for I in 1 .. V.Dim loop
         if Has_Scale then
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
      Res      : Vector_Value;
      Raw_Val  : Float;
      Abs_Elem : Float;
   begin
      Res.Dim      := Q.Dim;
      Res.Elements := [others => 0.0];

      for I in 1 .. Q.Dim loop
         if Q.Elements (I) = 0 or else Q.Scale <= 0.0 then
            Raw_Val := 0.0;
         elsif Q.Scale <= Max_Component / 127.0 then
            Raw_Val := Float (Q.Elements (I)) * Q.Scale;
         else
            Abs_Elem := Float (abs Integer (Q.Elements (I)));
            if Q.Scale >= Max_Component / Abs_Elem then
               Raw_Val :=
                 (if Q.Elements (I) > 0 then Max_Component else -Max_Component);
            else
               Raw_Val := Float (Q.Elements (I)) * Q.Scale;
            end if;
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

   function Int8_L2_Distance
     (A, B : Quantized_Int8_Vector) return Non_Negative_Float
   is
      FA : constant Vector_Value := Dequantize_From_Int8 (A);
      FB : constant Vector_Value := Dequantize_From_Int8 (B);
   begin
      return L2_Distance (FA, FB);
   end Int8_L2_Distance;

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

   -------------------------------------------------------------------------
   --  4096-D Vector TOAST Serialization / Deserialization (Q-003)
   -------------------------------------------------------------------------

   VTST_Magic_0 : constant Byte := 16#56#; --  'V'
   VTST_Magic_1 : constant Byte := 16#54#; --  'T'
   VTST_Magic_2 : constant Byte := 16#53#; --  'S'
   VTST_Magic_3 : constant Byte := 16#54#; --  'T'
   VTS2_Magic_3 : constant Byte := 16#32#; --  '2' ("VTS2": exact binary32 words)
   Max_Mantissa : constant := 100_000_000;

   --  IEEE 754 binary32 bit pattern of a component, computed arithmetically (zero is
   --  encoded as +0.0). |X| <= Max_Component < 2**20, so X = M * 2**E with M an integer
   --  scaled into [2**23, 2**24), or a subnormal with E = -149.
   function Float_Bits (X : Vector_Component) return Interfaces.Unsigned_32
     with Global => null
   is
      use Interfaces;
      Two_23 : constant Long_Float := 8_388_608.0;
      M      : Long_Float;
      E      : Integer range -149 .. 0 := 0;
      Biased : Unsigned_32;
      Frac   : Unsigned_32;
   begin
      if X = 0.0 then
         return 0;
      end if;

      M := Long_Float (abs X);
      for Step in 1 .. 149 loop
         pragma Loop_Invariant (M > 0.0 and then M < 2.0 * Two_23 and then E = 1 - Step);
         exit when M >= Two_23;
         M := M * 2.0;
         E := E - 1;
      end loop;

      if M >= Two_23 then
         Biased := Unsigned_32 (E + 150);
         Frac   := Unsigned_32 (M) - 16#80_0000#;
      else
         Biased := 0;
         Frac   := Unsigned_32 (M);
      end if;
      return (if X < 0.0 then 16#8000_0000# else 0)
        or Shift_Left (Biased and 16#FF#, 23)
        or (Frac and 16#7F_FFFF#);
   end Float_Bits;

   --  Inverse of Float_Bits for any word: Valid is False for an infinity, a NaN or a
   --  magnitude above Max_Component
   procedure Bits_Float
     (Word  : in     Interfaces.Unsigned_32;
      X     :    out Vector_Component;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates
   is
      use Interfaces;
      Biased : constant Unsigned_32 := Shift_Right (Word, 23) and 16#FF#;
      Frac   : constant Unsigned_32 := Word and 16#7F_FFFF#;
      Steps  : Natural;
      V      : Long_Float;
   begin
      X     := 0.0;
      Valid := False;

      --  Biased 147 .. 255 means |value| >= 2**20 > Max_Component, an infinity or a NaN
      if Biased > 146 then
         return;
      end if;

      if Biased = 0 then
         V     := Long_Float (Frac);
         Steps := 149;
      else
         V     := Long_Float (Frac + 16#80_0000#);
         Steps := Natural (150 - Biased);
      end if;

      --  value = V * 2**(-Steps): exact halvings, far above Long_Float's normal range
      for Step in 1 .. Steps loop
         pragma Loop_Invariant (V >= 0.0 and then V <= 16_777_216.0);
         V := V / 2.0;
      end loop;

      if V > Long_Float (Max_Component) then
         return;
      end if;
      X     := (if (Word and 16#8000_0000#) /= 0 then -Float (V) else Float (V));
      Valid := True;
   end Bits_Float;

   procedure Encode_Vector_TOAST
     (V       : in     Vector_Value;
      Payload :    out TOAST_Payload_Buffer;
      Length  :    out Valid_TOAST_Length)
   is
      use Interfaces;
      Dim_U32 : constant Unsigned_32 := Unsigned_32 (V.Dim);
      Base    : TOAST_Payload_Index;
      Word    : Unsigned_32;
   begin
      Payload := [others => 0];
      Length  := Vector_TOAST_Byte_Length (V.Dim);

      --  8-byte header: "VTS2" magic (1..4) + Big-Endian Dim (5..8)
      Payload (1) := VTST_Magic_0;
      Payload (2) := VTST_Magic_1;
      Payload (3) := VTST_Magic_2;
      Payload (4) := VTS2_Magic_3;
      Payload (5) := Byte (Shift_Right (Dim_U32, 24) and 16#FF#);
      Payload (6) := Byte (Shift_Right (Dim_U32, 16) and 16#FF#);
      Payload (7) := Byte (Shift_Right (Dim_U32, 8)  and 16#FF#);
      Payload (8) := Byte (Dim_U32 and 16#FF#);

      --  One big-endian IEEE 754 binary32 word per component: the round trip is exact
      for I in 1 .. V.Dim loop
         Base := Vector_TOAST_Header_Size + (I - 1) * 4 + 1;
         Word := Float_Bits (V.Elements (I));
         Payload (Base)     := Byte (Shift_Right (Word, 24) and 16#FF#);
         Payload (Base + 1) := Byte (Shift_Right (Word, 16) and 16#FF#);
         Payload (Base + 2) := Byte (Shift_Right (Word, 8)  and 16#FF#);
         Payload (Base + 3) := Byte (Word and 16#FF#);
      end loop;
   end Encode_Vector_TOAST;

   --  Decode one legacy "VTST" scaled-decimal word (sign, 4-bit code, mantissa 0..1e8)
   procedure Decode_VTST_Word
     (Word  : in     Interfaces.Unsigned_32;
      X     :    out Vector_Component;
      Valid :    out Boolean)
     with Global => null,
          Always_Terminates
   is
      use Interfaces;
      Is_Neg   : constant Boolean     := (Word and 16#8000_0000#) /= 0;
      Exp_Code : constant Unsigned_32 := Shift_Right (Word, 27) and 16#0F#;
      Mantissa : constant Unsigned_32 := Word and 16#07FF_FFFF#;
      Val_Abs  : Float;
   begin
      X     := 0.0;
      Valid := False;

      if Mantissa > Unsigned_32 (Max_Mantissa)
        or else (Exp_Code = 0 and then (Is_Neg or else Mantissa /= 0))
      then
         return;
      end if;

      case Exp_Code is
         when 0 =>
            Val_Abs := 0.0;
         when 1 =>
            Val_Abs := Float (Mantissa) * 1.0e-28;
         when 2 =>
            Val_Abs := Float (Mantissa) * 1.0e-26;
         when 3 =>
            Val_Abs := Float (Mantissa) * 1.0e-24;
         when 4 =>
            Val_Abs := Float (Mantissa) * 1.0e-22;
         when 5 =>
            Val_Abs := Float (Mantissa) * 1.0e-20;
         when 6 =>
            Val_Abs := Float (Mantissa) * 1.0e-18;
         when 7 =>
            Val_Abs := Float (Mantissa) * 1.0e-16;
         when 8 =>
            Val_Abs := Float (Mantissa) * 1.0e-14;
         when 9 =>
            Val_Abs := Float (Mantissa) * 1.0e-12;
         when 10 =>
            Val_Abs := Float (Mantissa) * 1.0e-10;
         when 11 =>
            Val_Abs := Float (Mantissa) * 1.0e-8;
         when 12 =>
            Val_Abs := Float (Mantissa) * 1.0e-6;
         when 13 =>
            Val_Abs := Float (Mantissa) * 1.0e-4;
         when 14 =>
            Val_Abs := Float (Mantissa) * 1.0e-3;
         when others =>
            Val_Abs := Float (Mantissa) * 1.0e-2;
      end case;

      if Val_Abs > Max_Component then
         Val_Abs := Max_Component;
      elsif Val_Abs < 0.0 then
         Val_Abs := 0.0;
      end if;

      X     := (if Is_Neg then -Val_Abs else Val_Abs);
      Valid := True;
   end Decode_VTST_Word;

   procedure Decode_Vector_TOAST
     (Payload : in     TOAST_Payload_Buffer;
      Length  : in     Valid_TOAST_Length;
      Dim     : in     Vector_Dim;
      V       :    out Vector_Value;
      Valid   :    out Boolean)
   is
      use Interfaces;
      Raw_Dim : Unsigned_32;
      Base    : TOAST_Payload_Index;
      Word    : Unsigned_32;
      Exact   : Boolean;
      Comp    : Vector_Component;
      Comp_Ok : Boolean;
   begin
      V := (Dim => Dim, Elements => [others => 0.0]);

      if Length /= Vector_TOAST_Byte_Length (Dim) then
         Valid := False;
         return;
      end if;

      --  "VTS2" (exact binary32, written since 0.4) or legacy "VTST" (scaled decimal)
      if Payload (1) /= VTST_Magic_0
        or else Payload (2) /= VTST_Magic_1
        or else Payload (3) /= VTST_Magic_2
        or else (Payload (4) /= VTST_Magic_3 and then Payload (4) /= VTS2_Magic_3)
      then
         Valid := False;
         return;
      end if;
      Exact := Payload (4) = VTS2_Magic_3;

      Raw_Dim := Shift_Left (Unsigned_32 (Payload (5)), 24)
        or Shift_Left (Unsigned_32 (Payload (6)), 16)
        or Shift_Left (Unsigned_32 (Payload (7)), 8)
        or Unsigned_32 (Payload (8));

      if Raw_Dim /= Unsigned_32 (Dim) then
         Valid := False;
         return;
      end if;

      for I in 1 .. Dim loop
         pragma Loop_Invariant (V.Dim = Dim);
         Base := Vector_TOAST_Header_Size + (I - 1) * 4 + 1;
         Word := Shift_Left (Unsigned_32 (Payload (Base)), 24)
           or Shift_Left (Unsigned_32 (Payload (Base + 1)), 16)
           or Shift_Left (Unsigned_32 (Payload (Base + 2)), 8)
           or Unsigned_32 (Payload (Base + 3));

         if Exact then
            Bits_Float (Word, Comp, Comp_Ok);
         else
            Decode_VTST_Word (Word, Comp, Comp_Ok);
         end if;
         if not Comp_Ok then
            V     := (Dim => Dim, Elements => [others => 0.0]);
            Valid := False;
            return;
         end if;
         V.Elements (I) := Comp;
      end loop;

      Valid := True;
   end Decode_Vector_TOAST;

end Nhe_O.Vector;
