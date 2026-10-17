# Binary Page, WAL Frame, TOAST Overflow & Index Format Specification

This domain specification defines the exact on-disk and in-memory binary layouts implemented by **`Nhe_O.Transaction`**, **`Nhe_O.BTree`**, **`Nhe_O.Vector`**, and **`Nhe_O.KV`** (`BR-002`, `BR-004`, `BR-006`, `ADR-003`, `ADR-006`, `ADR-007`).

All multi-byte integer fields are encoded in deterministic **Big-Endian (network byte order)** and verified with **IEEE 802.3 CRC-32** (`Polynomial = 16#EDB8_8320#`) in 100% `pragma SPARK_Mode (On);`.

---

## 1. Write-Ahead Log Frame (`WAL_Frame_Buffer` — 4,120 Bytes)

Defined in `src/nhe_o-io.ads` (`WAL_Header_Size = 24`, `WAL_Frame_Size = 4120`) and `src/nhe_o-transaction.ad[sb]`.

| Byte Offset (1-indexed) | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"NHEO"` (`16#4E#, 16#48#, 16#45#, 16#4F#`) |
| `5 .. 8` | 4 B | `Tx_Id` | `Valid_Tx_Id` (`1 .. 1_000_000_000`) |
| `9 .. 12` | 4 B | `Page_Id` | Target 4KB page index (`Valid_Page_Id`, `0 .. 1_048_576`) |
| `13 .. 16` | 4 B | `CRC32` | IEEE 802.3 CRC-32 over header bytes `1..12`, `17..24`, and payload `25..4120` |
| `17` | 1 B | `Frame_Kind` | `0 = WAL_Frame_Data`, `1 = WAL_Frame_Commit`, `2 = WAL_Frame_KV` (`CRIT-05`, `Q-004`) |
| `18 .. 24` | 7 B | `Reserved` | Zero-filled (`0`) |
| `25 .. 4120` | 4096 B | `Page_Payload` | Complete 4096-byte page image |

- **2-Pass Recovery Rule (`Redo_WAL_Recovery`, `CRIT-05`)**:
  - **Pass 1 (Analysis)**: Scans sequential frames `0 .. Max_Frames - 1`, verifies `Verify_WAL_Frame`, and marks `CLOG (Tx_Id) := Tx_Committed` iff `Frame_Kind = WAL_Frame_Commit`.
  - **Pass 2 (Redo)**: Replays `WAL_Frame_Data` and `WAL_Frame_Commit` pages to `.db` iff `Is_Tx_Committed (CLOG, Tx_Id)`.

---

## 2. Primary 4096-Byte Slotted Page (`Slotted_Page` — `"SLOT"`, 4,096 Bytes)

Defined in `src/nhe_o-transaction.ad[sb]` (`Encode_Slotted_Page` / `Decode_Slotted_Page`, `CRIT-01`).

| Byte Offset (1-indexed) | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"SLOT"` (`16#53#, 16#4C#, 16#4F#, 16#54#`) |
| `5 .. 8` | 4 B | `Page_Id` | `Valid_Page_Id` (`0 .. 1_048_576`) |
| `9 .. 12` | 4 B | `Page_LSN_Tx` | Last committing `Valid_Tx_Id` |
| `13 .. 16` | 4 B | `Slot_Count` | Active tuple slots (`0 .. 16`) |
| `17 .. 20` | 4 B | `Free_Lower` | End of line pointer directory (`24 + Slot_Count * 8`) |
| `21 .. 24` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over bytes `1..20` and `25..4096` |
| `25 .. 152` | 128 B | `Slot_Dir (1..16)` | Sixteen 8-byte line pointers (`Offset: U16`, `Length: U16 = 240`, `Occupied: U8`, `Inline_Len: U8`, `Reserved: U16`) |
| `153 .. 3992` | 3840 B | `Tuples (1..16)` | Sixteen 240-byte tuple cells (`Row_Id: 4B`, `Xmin: 4B`, `Xmax: 4B`, `Related_Id: 4B`, `TOAST_Pointer: 16B`, `Inline_Data: 208B`) |
| `3993 .. 4096` | 104 B | `Reserved_Tail` | Zero-padded free space |

---

## 3. Inline 16-Byte TOAST Pointer & 4096-Byte TOAST Overflow Page (`"TOAS"`)

Defined in `src/nhe_o-transaction.ad[sb]` (`Encode_TOAST_Pointer`, `Decode_TOAST_Pointer`, `Write_TOAST_Chain`, `Read_TOAST_Chain`, `BR-006`).

### 3.1 16-Byte Inline `TOAST_Pointer`
| Byte Offset | Size | Field | Invariant |
|---|---|---|---|
| `1 .. 4` | 4 B | `Root_Overflow_Page` | `Valid_Page_Id` (`<= Max_Page_Id - Chunk_Count + 1`) |
| `5 .. 8` | 4 B | `Total_Byte_Length` | `1 .. 16_384` (`Max_TOAST_Payload_Bytes`) |
| `9 .. 12` | 4 B | `Chunk_Count` | `((Total_Byte_Length - 1) / 4080) + 1` (`1 .. 5`, `LOW-01`) |
| `13 .. 16` | 4 B | `Payload_CRC32` | IEEE 802.3 CRC-32 across all `1 .. Total_Byte_Length` bytes |

### 3.2 4096-Byte TOAST Overflow Page (`"TOAS"`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"TOAS"` (`16#54#, 16#4F#, 16#41#, 16#53#`) |
| `5 .. 8` | 4 B | `Next_Page_Id` | Next overflow page ID (`0` on terminal chunk) |
| `9 .. 12` | 4 B | `Chunk_Bytes` | Active payload bytes in this page (`1 .. 4080`) |
| `13 .. 16` | 4 B | `Chunk_CRC32` | IEEE 802.3 CRC-32 over payload bytes `17 .. 16 + Chunk_Bytes` |
| `17 .. 4096` | 4080 B | `Chunk_Data` | Raw slice of oversized parent chunk or 4096-D `Float32` vector (`Encode_Vector_TOAST`) |

---

## 4. B+Tree 4096-Byte Node Page (`"BTRE"`, `CRIT-03`)

Defined in `src/nhe_o-btree.ad[sb]` (`Encode_Node_Page` / `Decode_Node_Page`).

| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"BTRE"` (`16#42#, 16#54#, 16#52#, 16#45#`) |
| `5` | 1 B | `Node_Kind` | `0 = Node_Leaf`, `1 = Node_Internal` |
| `6` | 1 B | `Num_Keys` | `0 .. 4` (`Max_Keys_Per_Node`) |
| `7 .. 8` | 2 B | `Next_Leaf` | `0 .. 32` (`0` for internal nodes) |
| `9 .. 12` | 4 B | `Page_Id` | `Valid_Page_Id` |
| `13 .. 92` | 80 B | `Key_Slots (1..4)` | Four 20-byte slots (`Key_Hi: 4B`, `Key_Lo: 4B` for full 64-bit `Integer_64`, `Target_Page: 4B`, `Target_Slot: 4B`, `TOAST_Root: 4B`) |
| `93 .. 112` | 20 B | `Children (1..5)` | Five 4-byte `BTree_Node_Id` child links (`1 .. 32`) |
| `113 .. 4092` | 3980 B | `Reserved` | Zero-filled |
| `4093 .. 4096` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over bytes `1 .. 4092` |

---

## 5. Durable KV 4096-Byte WAL Page (`"KVMG"`, `Q-004`)

Defined in `src/nhe_o-kv.ad[sb]` (`Encode_KV_Wal_Page` / `Decode_KV_Wal_Page`).

| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"KVMG"` (`16#4B#, 16#56#, 16#4D#, 16#47#`) |
| `5` | 1 B | `Op_Code` | `1 = KV_Op_Set`, `2 = KV_Op_Del` |
| `6` | 1 B | `Flags` | Bit 0: `Has_TTL`, Bit 1: `Is_Numeric` |
| `7 .. 8` | 2 B | `Key_Length` | `1 .. 64` (`Max_Ident_Len`) |
| `9 .. 12` | 4 B | `Val_Length` | `0 .. 512` (`Max_Text_Len`) |
| `13 .. 20` | 8 B | `Expires_At` | 64-bit `Epoch_Seconds` (`Hi: 4B`, `Lo: 4B`) |
| `21 .. 28` | 8 B | `Int_Val` | 64-bit `Integer_64` (`Hi: 4B`, `Lo: 4B`) |
| `29 .. 92` | 64 B | `Key_Data` | Raw `Bounded_Ident` bytes |
| `93 .. 604` | 512 B | `Val_Data` | Raw `Bounded_Text` bytes |
| `605 .. 4092` | 3488 B | `Reserved` | Zero-filled |
| `4093 .. 4096` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over bytes `1 .. 4092` |
