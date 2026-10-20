# Binary Page, WAL Frame, TOAST Overflow & Index Format Specification

This domain specification defines the exact on-disk and in-memory binary layouts implemented by **`Nhe_O.Transaction`**, **`Nhe_O.BTree`**, **`Nhe_O.Vector`**, and **`Nhe_O.KV`** (`BR-002`, `BR-004`, `BR-006`, `ADR-003`, `ADR-006`, `ADR-007`).

All multi-byte integer fields are encoded in deterministic **Big-Endian (network byte order)** and verified with **IEEE 802.3 CRC-32** (`Polynomial = 16#EDB8_8320#`) in 100% `pragma SPARK_Mode (On);`.

---

## 1. Write-Ahead Log Frame (`WAL_Frame_Buffer` — 4,120 Bytes)

Defined in `src/nhe_o-io.ads` (`WAL_Header_Size = 24`, `WAL_Frame_Size = 4120`, `Max_WAL_Frames = 4096`) and `src/nhe_o-transaction.ad[sb]`.

| Byte Offset (1-indexed) | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"NHEO"` (`16#4E#, 16#48#, 16#45#, 16#4F#`) |
| `5 .. 8` | 4 B | `Tx_Id` | `Valid_Tx_Id` (`1 .. 8192`, `Max_Tx_Id = Max_CLOG_Entries`) |
| `9 .. 12` | 4 B | `Page_Id` | Target 4KB page index (`Valid_Page_Id`, `0 .. 1_048_575`) |
| `13 .. 16` | 4 B | `CRC32` | IEEE 802.3 CRC-32 (`Compute_WAL_CRC32`) over `Tx_Id (4B)`, `Page_Id (4B)`, `Frame_Kind (1B)`, and `Page_Payload (4096B)` |
| `17` | 1 B | `Frame_Kind` | `0 = WAL_Frame_Data`, `1 = WAL_Frame_Commit`, `2 = WAL_Frame_KV` (`ADR-006`, `ADR-007`) |
| `18 .. 24` | 7 B | `Reserved` | Zero-filled (`0`, verified by `Verify_WAL_Frame`) |
| `25 .. 4120` | 4096 B | `Page_Payload` | Complete 4096-byte page image |

- **Exact File-Size Alignment & `Max_WAL_Frames = 4096` Rule (`Read_Page`, `Write_Page`, `Append_WAL_Frame`, `Write_WAL_Frame`, `Read_WAL_Frame`)**:
  - Every `.db` page read/write verifies via `Posix_Lseek (Fd, 0, SEEK_END)` that the file size is an exact multiple of `Page_Size` (`4096` bytes), and every `.wal` frame read/write/append verifies that the `.wal` file size is an exact multiple of `WAL_Frame_Size` (`4120` bytes) and holds at most `Max_WAL_Frames = 4096` frames (`Frame_Idx < Max_WAL_Frames`). Any trailing partial byte or unaligned tail fails closed with I/O failure.
- **NO-STEAL Write & Pre-Commit Verification Rule (`Write_TOAST_Chain`, `Ingest_Document`, `Delete_Document`, `Commit_Tx`, `ADR-006`)**:
  - Active transactions (`Tx_Active`) append `WAL_Frame_Data` frames to `.wal` without mutating `.db` in-place.
  - `Commit_Tx` first pre-scans existing `.wal` frames up to `Max_WAL_Scan_Frames = 4096`, verifying `Verify_WAL_Frame` (CRC32 + `"NHEO"` magic), rejecting duplicate or post-commit frames for `Tx.Id`, and requiring `Hit_EOF` before appending `WAL_Frame_Commit`, then materializes all `WAL_Frame_Data` frames belonging to `Ctx.Id` and the final committed page to `.db`.
- **2-Pass Recovery Rule (`Redo_WAL_Recovery`, `BR-002`, `ADR-006`)**:
  - **Pass 1 (Analysis)**: Scans sequential frames `0 .. Max_Frames - 1` (up to `Max_WAL_Scan_Frames = 4096`), verifies `Verify_WAL_Frame`, and marks `CLOG (Tx_Id) := Tx_Committed` iff `Frame_Kind = WAL_Frame_Commit`.
  - **Pass 2 (Redo)**: Replays `WAL_Frame_Data` and `WAL_Frame_Commit` pages to `.db` iff `Is_Tx_Committed (CLOG, Tx_Id)`.

---

## 2. Primary 4096-Byte Slotted Page (`Slotted_Page` — `"SLOT"`, 4,096 Bytes)

Defined in `src/nhe_o-transaction.ad[sb]` (`Encode_Slotted_Page` / `Decode_Slotted_Page`, `BR-006`, `ADR-006`).

| Byte Offset (1-indexed) | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"SLOT"` (`16#53#, 16#4C#, 16#4F#, 16#54#`) |
| `5 .. 8` | 4 B | `Page_Id` | `Valid_Page_Id` (`0 .. 1_048_575`) |
| `9 .. 12` | 4 B | `Slot_Count` | Active occupied tuple slots (`0 .. 16`, verified equal to count of `Occupied` slots by `Decode_Slotted_Page`) |
| `13 .. 14` | 2 B | `Free_Lower` | End of line pointer directory (`152 = 24 + 16 * 8`, verified on decode) |
| `15 .. 16` | 2 B | `Free_Upper` | End of active tuple region (`153 + Slot_Count * 240`, verified on decode) |
| `17 .. 20` | 4 B | `Page_LSN_Tx` | Last committing `Valid_Tx_Id` |
| `21 .. 24` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over the 4096-byte page with bytes `21 .. 24` zeroed |
| `25 .. 152` | 128 B | `Slot_Dir (1..16)` | Sixteen 8-byte line pointers (`Tuple_Offset: U32 = 153 + (Slot-1)*240`, `Occupied: U8`, `Inline_Len: U8`, `Reserved: U16 = 0`; unoccupied slots must have `Inline_Len = 0` and zeroed `Row_Id`/`Xmax`/`Toast_Ptr`) |
| `153 .. 3992` | 3840 B | `Tuples (1..16)` | Sixteen 240-byte tuple cells (`Row_Id: 4B`, `Xmin: 4B`, `Xmax: 4B`, `Related_Id: 4B`, `TOAST_Pointer: 16B`, `Inline_Data: 208B`) |
| `3993 .. 4096` | 104 B | `Reserved_Tail` | Zero-padded free space (`0`, verified by `Decode_Slotted_Page`) |

### 2.1 RAG Tuple `Inline_Data (1 .. 208)` Layout (`Build_RAG_Slotted_Page`, `BR-006`)
| Inline Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 16` | 16 B | `Vec_Toast_Ptr` | Inline 16-byte `TOAST_Pointer` to the `"VTST"` 4096-D `Float32` vector TOAST chain |
| `17` | 1 B | `Summary_Len` | Inline byte length of `Summary_Text` (`0 .. 63`) |
| `18 .. 80` | 63 B | `Summary_Text` | Up to 63 inline fast-path bytes of document summary text (`17 + 1 .. 17 + Summary_Len`) |
| `81 .. 96` | 16 B | `Meta_Toast_Ptr` | Inline 16-byte `TOAST_Pointer` to the `"RMET"` extended summary (`> 63 B`) & JSONB metadata TOAST chain (zeroed when inline-only) |
| `97` | 1 B | `Meta_Count` | `0 .. 16` inline fast-path `JSONB_Document` fields |
| `98 .. 208` | 111 B | `Packed_JSONB` | Sequential `[Key_Len: 1B (1..64), Val_Len: 1B (0..108), Kind_Code: 1B, Key_Bytes, Val_Bytes]` inline fast-path entries |

---

## 3. Inline 16-Byte TOAST Pointer, 4096-Byte `"TOAS"` Page, `"VTST"` Vector & `"RMET"` Metadata Payloads

Defined in `src/nhe_o-transaction.ad[sb]` (`Encode_TOAST_Pointer`, `Decode_TOAST_Pointer`, `Write_TOAST_Chain`, `Read_TOAST_Chain`, `BR-006`), `src/nhe_o-vector.ad[sb]` (`Encode_Vector_TOAST`, `Decode_Vector_TOAST`, `ADR-006`), and `src/nhe_o-rag.adb` (`Encode_Meta_TOAST`, `Decode_Meta_TOAST`, `ADR-006`).

### 3.1 16-Byte Inline `TOAST_Pointer`
| Byte Offset | Size | Field | Invariant |
|---|---|---|---|
| `1 .. 4` | 4 B | `Root_Overflow_Page` | `Valid_Page_Id` (`<= Max_Page_Id - Chunk_Count + 1`) |
| `5 .. 8` | 4 B | `Total_Byte_Length` | `1 .. 16_392` (`Max_TOAST_Payload_Bytes`, accommodating `8B` `"VTST"` header + `4096 * 4B`) |
| `9 .. 12` | 4 B | `Chunk_Count` | `((Total_Byte_Length - 1) / 4080) + 1` (`1 .. 5`) |
| `13 .. 16` | 4 B | `Payload_CRC32` | IEEE 802.3 CRC-32 across all `1 .. Total_Byte_Length` bytes |

### 3.2 4096-Byte TOAST Overflow Page (`"TOAS"`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"TOAS"` (`16#54#, 16#4F#, 16#41#, 16#53#`) |
| `5 .. 8` | 4 B | `Next_Page_Id` | Next contiguous overflow page ID (`Cur_Page_Id + 1` on non-terminal chunks, `0` on terminal chunk, verified by `Read_TOAST_Chain`) |
| `9 .. 12` | 4 B | `Chunk_Bytes` | Active payload bytes in this page (`4080` on non-terminal chunks, `1 .. 4080` on terminal chunk) |
| `13 .. 16` | 4 B | `Chunk_CRC32` | IEEE 802.3 CRC-32 over payload bytes `17 .. 16 + Chunk_Bytes` |
| `17 .. 4096` | 4080 B | `Chunk_Data` | Raw slice of oversized parent chunk, `"VTST"` 4096-D `Float32` vector, or `"RMET"` extended summary/JSONB metadata (trailing unused bytes `17 + Chunk_Bytes .. 4096` verified zeroed) |

### 3.3 `"VTST"` Vector TOAST Payload (`Encode_Vector_TOAST`, `ADR-006`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"VTST"` (`16#56#, 16#54#, 16#53#, 16#54#`) |
| `5 .. 8` | 4 B | `Dim` | Embedding dimension (`1 .. 4096`, 32-bit Big-Endian) |
| `9 .. 8 + Dim*4` | `Dim * 4` B | `Elements (1..Dim)` | 32-bit Big-Endian 15-tier scientific Float32 words (`Encode_Vector_TOAST` / `Decode_Vector_TOAST`: `Bit 31 = Sign`, `Bits 27..30 = Exp_Code 0..14` stepping by $10^1$ per tier from $10^5$ down to $10^{-8}$ with `14 = 0.0`, `Bits 0..26 = Mantissa 0..10^8` retaining 7–8 significant decimal digits across all magnitudes) |

### 3.4 `"RMET"` Extended Summary & JSONB Metadata TOAST Payload (`Encode_Meta_TOAST`, `ADR-006`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"RMET"` (`16#52#, 16#4D#, 16#45#, 16#54#`) |
| `5 .. 6` | 2 B | `Summary_Length` | Exact byte length of full `Summary_Text` (`0 .. 512`, 16-bit Big-Endian) |
| `7 .. 6 + Summary_Length` | `0 .. 512` B | `Summary_Bytes` | Full `Summary_Text` (`Bounded_Text.Data (1 .. Summary_Length)`) |
| `7 + Summary_Length` | 1 B | `Meta_Count` | Number of active `JSONB_Document` fields (`0 .. 16`) |
| `8 + Summary_Length .. Total` | Variable | `JSONB_Entries` | `Meta_Count` sequential entries: `[Key_Len: 1B (1..64), Val_Len_Hi: 1B, Val_Len_Lo: 1B (0..512), Kind_Code: 1B, Key_Bytes (1..Key_Len), Val_Bytes (1..Val_Len)]` |

---

## 4. B+Tree 4096-Byte Node Page (`"BTRE"`)

Defined in `src/nhe_o-btree.ad[sb]` (`Encode_Node_Page` / `Decode_Node_Page`).

| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"BTRE"` (`16#42#, 16#54#, 16#52#, 16#45#`) |
| `5` | 1 B | `Node_Kind` | `1 = Node_Leaf`, `2 = Node_Internal` |
| `6` | 1 B | `Num_Keys` | `0 .. 4` (`Max_Keys_Per_Node`; `>= 1` for `Node_Internal` and `>= 2` for non-root leaves `Page_Id > 1`) |
| `7` | 1 B | `Next_Leaf` | `0 .. 32` (`0` for internal nodes) |
| `8` | 1 B | `Reserved_Hdr` | Zero (`0`) |
| `9 .. 12` | 4 B | `Page_Id` | `Valid_Page_Id` |
| `13 .. 16` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over the 4096-byte page with bytes `13 .. 16` zeroed |
| `17 .. 96` | 80 B | `Key_Slots (1..4)` | Four 20-byte slots (`Key_Hi: 4B`, `Key_Lo: 4B` for full 64-bit `Integer_64`, `Target_Page: 4B`, `Target_Slot: 4B`, `TOAST_Root: 4B`) |
| `97 .. 116` | 20 B | `Children (1..5)` | Five 4-byte `BTree_Node_Id` child links (`1 .. 32`) |
| `117 .. 4096` | 3980 B | `Reserved` | Zero-filled |

---

## 5. Durable KV 4096-Byte WAL Page (`"KVMG"`, `Q-004`, `BR-004`, `ADR-007`)

Defined in `src/nhe_o-kv.ad[sb]` (`Encode_KV_Wal_Page` / `Decode_KV_Wal_Page`).

| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"KVMG"` (`16#4B#, 16#56#, 16#4D#, 16#47#`) |
| `5` | 1 B | `Op_Code` | `1 = KV_Op_Set`, `2 = KV_Op_Del` |
| `6` | 1 B | `Has_TTL` | `1 = True`, `0 = False` (`0` required when `Op_Code = KV_Op_Del`) |
| `7` | 1 B | `Key_Length` | `1 .. 64` (`Max_Ident_Len`) |
| `8` | 1 B | `Reserved_Hdr` | Zero (`0`) |
| `9 .. 12` | 4 B | `Val_Length` | `0 .. 512` (`Max_Text_Len`; `0` required when `Op_Code = KV_Op_Del`) |
| `13 .. 20` | 8 B | `Expires_At` | 64-bit `Epoch_Seconds` (`Hi: 4B`, `Lo: 4B`; `0` required when `Op_Code = KV_Op_Del`) |
| `21 .. 28` | 8 B | `Last_Access` | 64-bit `Epoch_Seconds` (`Hi: 4B`, `Lo: 4B`) |
| `29 .. 32` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over the 4096-byte page with bytes `29 .. 32` zeroed |
| `33 .. 96` | 64 B | `Key_Data` | Raw `Bounded_Ident` bytes (`1 .. Key_Length`) |
| `97 .. 608` | 512 B | `Val_Data` | Raw `Bounded_Text` bytes (`1 .. Val_Length`) |
| `609 .. 4096` | 3488 B | `Reserved` | Zero-filled |
