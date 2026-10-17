--  Formally verified PostgreSQL pgvector-compatible Vector Engine (BR-003 / ADR-003 / Q-003)
pragma SPARK_Mode (On);

with Interfaces;
with Nhe_O.Transaction; use Nhe_O.Transaction;

package Nhe_O.Vector is

   --  Supports all modern embedding models up to 4096 dimensions
   --  (e.g., MiniLM 384-D, bge-m3 1024-D, text-embedding-3-large 3072-D, Qwen3-Embedding-8B 4096-D)
   Max_Vector_Dim : constant := 4096;
   subtype Vector_Dim is Positive range 1 .. Max_Vector_Dim;

   type Vector_Encoding_Kind is (
      Encoding_Float32,     --  4 bytes/dim (16 KB at 4096-D, stored in TOAST overflow pages)
      Encoding_Int8_SQ8,    --  1 byte/dim  (4 KB at 4096-D, 4x RAM reduction)
      Encoding_Binary_1Bit  --  1 bit/dim   (512 B at 4096-D, 32x RAM reduction, fits inline)
   );

   --  Bounded float component preventing IEEE-754 overflow during dot/L2 sum
   Max_Component : constant := 1.0e6;
   subtype Vector_Component is Float range -Max_Component .. Max_Component;
   subtype Non_Negative_Float is Float range 0.0 .. Float'Last;

   type Vector_Array is array (Vector_Dim) of Vector_Component;

   type Vector_Value is record
      Dim      : Vector_Dim   := 1;
      Elements : Vector_Array := [others => 0.0];
   end record;

   -------------------------------------------------------------------------
   --  Scalar Quantization (Int8 / SQ8) — 4x Memory Reduction (ADR-003)
   -------------------------------------------------------------------------

   type Int8_Component is range -127 .. 127;
   type Int8_Vector_Array is array (Vector_Dim) of Int8_Component;

   type Quantized_Int8_Vector is record
      Dim      : Vector_Dim         := 1;
      Scale    : Non_Negative_Float := 1.0;
      Elements : Int8_Vector_Array  := [others => 0];
   end record;

   -------------------------------------------------------------------------
   --  Binary Quantization (1-bit Hamming) — 32x Memory Reduction (ADR-003)
   -------------------------------------------------------------------------

   Max_Binary_Words : constant := 64; --  64 * 64 bits = 4096 bits (512 bytes)
   subtype Binary_Word_Index is Positive range 1 .. Max_Binary_Words;
   type Binary_Word_Array is array (Binary_Word_Index) of Interfaces.Unsigned_64;

   type Quantized_Binary_Vector is record
      Dim   : Vector_Dim        := 1;
      Words : Binary_Word_Array := [others => 0];
   end record;

   --  Construct a 3D vector helper for testing and SQL literals
   function Make_Vector_3D
     (X, Y, Z : Vector_Component) return Vector_Value
     with Global => null,
          Post   => Make_Vector_3D'Result.Dim = 3;

   --  pgvector `<->` operator: Squared Euclidean (L2) distance
   function L2_Distance_Squared
     (A, B : Vector_Value) return Non_Negative_Float
     with Global => null,
          Pre    => A.Dim = B.Dim,
          Post   => L2_Distance_Squared'Result >= 0.0;

   --  Inner product (dot product)
   function Inner_Product
     (A, B : Vector_Value) return Float
     with Global => null,
          Pre    => A.Dim = B.Dim;

   --  pgvector `<#>` operator: Negative inner product
   function Negative_Inner_Product
     (A, B : Vector_Value) return Float
     with Global => null,
          Pre    => A.Dim = B.Dim;

   --  Newton-Raphson bounded square root in pure SPARK
   function Sqrt_Bounded (X : Non_Negative_Float) return Non_Negative_Float
     with Global => null,
          Post   => Sqrt_Bounded'Result >= 0.0;

   --  pgvector `<->` operator: Euclidean (L2) distance
   function L2_Distance
     (A, B : Vector_Value) return Non_Negative_Float
     with Global => null,
          Pre    => A.Dim = B.Dim,
          Post   => L2_Distance'Result >= 0.0;

   --  pgvector `<=>` operator: Cosine distance in [0.0 .. 2.0]
   function Cosine_Distance
     (A, B : Vector_Value) return Float
     with Global => null,
          Pre    => A.Dim = B.Dim,
          Post   => Cosine_Distance'Result in 0.0 .. 2.0;

   --  Quantize Float32 vector to Int8 (SQ8) symmetric scalar quantization
   function Quantize_To_Int8 (V : Vector_Value) return Quantized_Int8_Vector
     with Global => null,
          Post   => Quantize_To_Int8'Result.Dim = V.Dim
                    and then Quantize_To_Int8'Result.Scale > 0.0;

   --  Reconstruct approximate Float32 vector from Int8 (SQ8) quantized vector
   --  with per-component saturation to [-Max_Component .. Max_Component] (CRIT-07)
   function Dequantize_From_Int8 (Q : Quantized_Int8_Vector) return Vector_Value
     with Global => null,
          Post   => Dequantize_From_Int8'Result.Dim = Q.Dim;

   --  Squared L2 distance in Int8 quantized integer domain (guaranteed overflow-free)
   function Int8_L2_Distance_Squared
     (A, B : Quantized_Int8_Vector) return Natural
     with Global => null,
          Pre    => A.Dim = B.Dim;

   --  Scale-aware Euclidean (L2) distance between two Int8 (SQ8) vectors (CRIT-07)
   function Int8_L2_Distance
     (A, B : Quantized_Int8_Vector) return Non_Negative_Float
     with Global => null,
          Pre    => A.Dim = B.Dim,
          Post   => Int8_L2_Distance'Result >= 0.0;

   --  Inner product in Int8 quantized integer domain (guaranteed overflow-free)
   function Int8_Inner_Product
     (A, B : Quantized_Int8_Vector) return Integer
     with Global => null,
          Pre    => A.Dim = B.Dim;

   --  Quantize Float32 vector to 1-bit Binary representation (bit = 1 iff V(i) > 0.0)
   function Quantize_To_Binary (V : Vector_Value) return Quantized_Binary_Vector
     with Global => null,
          Post   => Quantize_To_Binary'Result.Dim = V.Dim;

   --  Compute exact Hamming distance (XOR + PopCount) over 1 .. A.Dim bits
   function Hamming_Distance
     (A, B : Quantized_Binary_Vector) return Natural
     with Global => null,
          Pre    => A.Dim = B.Dim,
          Post   => Hamming_Distance'Result <= A.Dim;

   --  Serialize a Float32 Vector_Value (up to 4096-D = 16,384 bytes) into a
   --  TOAST_Payload_Buffer (4 bytes per dimension) for TOAST overflow storage (Q-003)
   procedure Encode_Vector_TOAST
     (V       : in     Vector_Value;
      Payload :    out TOAST_Payload_Buffer;
      Length  :    out Valid_TOAST_Length)
     with Global => null,
          Always_Terminates,
          Post   => Length = V.Dim * 4;

   --  Deserialize a Float32 Vector_Value of dimension Dim from a TOAST_Payload_Buffer (Q-003)
   procedure Decode_Vector_TOAST
     (Payload : in     TOAST_Payload_Buffer;
      Length  : in     Valid_TOAST_Length;
      Dim     : in     Vector_Dim;
      V       :    out Vector_Value;
      Valid   :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => V.Dim = Dim;

end Nhe_O.Vector;
